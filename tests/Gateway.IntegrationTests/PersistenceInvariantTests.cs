using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.IntegrationTests.Fixtures;
using Gateway.TestSupport;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

[Collection(SqlServerCollection.Name)]
[Trait("Category", "SqlServer")]
public sealed class PersistenceInvariantTests(SqlServerFixture fixture)
{
    [Theory]
    [InlineData("external-id")]
    [InlineData("external-client")]
    [InlineData("child-identity")]
    public async Task SQL_uniqueness_prevents_two_active_registrations_from_claiming_one_identity(string duplicate)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var first = TestData.Agent();
        first.ExternalClientId = Guid.NewGuid().ToString("D");
        first.AgentIdentityObjectId = Guid.NewGuid().ToString("D");
        await using (var seed = database.CreateContext())
        {
            seed.Add(first);
            await seed.SaveChangesAsync();
        }
        var second = TestData.Agent();
        if (duplicate == "external-id") second.ExternalAgentId = first.ExternalAgentId;
        if (duplicate == "external-client") second.ExternalClientId = first.ExternalClientId;
        if (duplicate == "child-identity") second.AgentIdentityObjectId = first.AgentIdentityObjectId;
        await using (var insert = database.CreateContext())
        {
            insert.Add(second);
            var error = await Assert.ThrowsAsync<DbUpdateException>(() => insert.SaveChangesAsync());
            Assert.Contains(Assert.IsType<SqlException>(error.InnerException).Number, new[] { 2601, 2627 });
        }
        await using var verify = database.CreateContext();
        Assert.Equal(1, await verify.AgentRegistrations.CountAsync());
    }

    [Fact]
    public async Task Blueprint_reuse_allows_distinct_children_and_soft_delete_releases_only_the_active_external_ID()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        var first = TestData.Agent();
        var sibling = TestData.Agent();
        sibling.BlueprintId = first.BlueprintId;
        first.AgentIdentityObjectId = Guid.NewGuid().ToString("D");
        sibling.AgentIdentityObjectId = Guid.NewGuid().ToString("D");
        context.AddRange(first, sibling);
        await context.SaveChangesAsync();
        Assert.Equal(2, await context.AgentRegistrations.CountAsync());
        first.IsDeleted = true;
        first.Status = AgentStatus.Deleted;
        await context.SaveChangesAsync();
        Assert.False(await new AgentRegistrationRepository(context).ExistsAsync(first.ExternalAgentId.Value, default));
        var replacement = TestData.Agent();
        replacement.ExternalAgentId = first.ExternalAgentId;
        context.Add(replacement);
        await context.SaveChangesAsync();
        Assert.Equal(2, await context.AgentRegistrations.CountAsync());
        Assert.Equal(3, await context.AgentRegistrations.IgnoreQueryFilters().CountAsync());
    }

    [Fact]
    public async Task SQL_rowversion_rejects_stale_writes_and_only_security_changes_advance_protection_revision()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = TestData.Agent();
        await using (var seed = database.CreateContext())
        {
            seed.Add(agent);
            await seed.SaveChangesAsync();
        }
        await using var first = database.CreateContext();
        await using var stale = database.CreateContext();
        var current = await first.AgentRegistrations.SingleAsync();
        var outdated = await stale.AgentRegistrations.SingleAsync();
        var revision = current.ProtectionRevision;
        var rowVersion = current.RowVersion.ToArray();
        current.Name = "Metadata-only rename";
        await new UnitOfWork(first).SaveChangesAsync(default);
        Assert.Equal(revision, current.ProtectionRevision);
        Assert.NotEqual(rowVersion, current.RowVersion);
        outdated.Name = "Stale rename";
        var conflict = await Assert.ThrowsAsync<ConflictException>(() => new UnitOfWork(stale).SaveChangesAsync(default));
        Assert.Equal(ErrorCodes.CONCURRENCY_CONFLICT, conflict.ErrorCode);

        await using var featureWriter = database.CreateContext();
        var saved = await featureWriter.AgentRegistrations.Include(item => item.FeatureConfiguration).SingleAsync();
        var before = await new PromptEvaluationRepository(featureWriter).GetProtectionContextAsync(saved.Id, default);
        saved.FeatureConfiguration.PromptShieldEnabled = true;
        await featureWriter.SaveChangesAsync();
        Assert.NotEqual(revision, saved.ProtectionRevision);
        Assert.Equal("Metadata-only rename", saved.Name);
        var repository = new PromptEvaluationRepository(featureWriter);
        await Assert.ThrowsAsync<InvalidOperationException>(() => repository.IsProtectionContextCurrentAsync(before!, default));
        await using var transaction = await featureWriter.Database.BeginTransactionAsync();
        Assert.False(await repository.IsProtectionContextCurrentAsync(before!, default));
    }

    [Fact]
    public async Task SQL_rejects_empty_registration_protection_revision()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        context.Add(TestData.Agent());
        await context.SaveChangesAsync();
        var error = await Assert.ThrowsAsync<SqlException>(() => context.Database.ExecuteSqlRawAsync(
            "UPDATE dbo.AgentRegistrations SET ProtectionRevision = '00000000-0000-0000-0000-000000000000';"));
        Assert.Equal(547, error.Number);
    }

    [Theory]
    [InlineData("digest")]
    [InlineData("revision")]
    [InlineData("shield")]
    [InlineData("purview")]
    public async Task SQL_rejects_partial_or_untrusted_allowed_receipt_bindings(string mutation)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = await PromptWorkflowTests.SeedProtectedAgentAsync(database);
        await using var context = database.CreateContext();
        await new GatewaySqlHarness(context, GatewaySqlHarness.AllowingShield()).Evaluate()
            .Handle(GatewaySqlHarness.Evaluation(agent), default);
        var sql = mutation switch
        {
            "digest" => "UPDATE dbo.PromptEvaluationRecords SET ProtectionContextHash = 'not-a-binding';",
            "revision" => "UPDATE dbo.PromptEvaluationRecords SET ProtectionRevision = NULL;",
            "shield" => "UPDATE dbo.PromptEvaluationRecords SET PromptShieldDecision = N'Disabled';",
            "purview" => "UPDATE dbo.PromptEvaluationRecords SET EvaluatedPurviewPolicyMode = N'Enforce', PurviewDecision = N'Blocked';",
            _ => throw new ArgumentOutOfRangeException(nameof(mutation))
        };
        var error = await Assert.ThrowsAsync<SqlException>(() => context.Database.ExecuteSqlRawAsync(sql));
        Assert.Equal(547, error.Number);
    }

    [Theory]
    [InlineData("scope")]
    [InlineData("plane")]
    [InlineData("mode")]
    [InlineData("classifiers")]
    public async Task SQL_enforces_shared_DLP_scope_plane_mode_and_classifier_shape(string mutation)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await SeedProfileAsync(database);
        await using var context = database.CreateContext();
        var sql = mutation switch
        {
            "scope" => "UPDATE dbo.PurviewDlpProfiles SET ScopeType = N'Group';",
            "plane" => "UPDATE dbo.PurviewDlpProfiles SET EnforcementPlane = N'Tenant';",
            "mode" => "UPDATE dbo.PurviewDlpProfiles SET PolicyMode = N'Disabled';",
            "classifiers" => "UPDATE dbo.PurviewDlpProfiles SET SensitiveInformationTypesJson = @json;",
            _ => throw new ArgumentOutOfRangeException(nameof(mutation))
        };
        object[] parameters = mutation == "classifiers" ? [new SqlParameter("@json", "{}")] : [];
        var error = await Assert.ThrowsAsync<SqlException>(() => context.Database.ExecuteSqlRawAsync(sql, parameters));
        Assert.Equal(547, error.Number);
    }

    [Fact]
    public async Task DLP_profile_is_unique_per_blueprint_not_per_child_registration()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var first = await SeedProfileAsync(database);
        var duplicate = TestData.ReadyProfile();
        duplicate.BlueprintApplicationId = first.BlueprintApplicationId;
        duplicate.InventoryGenerationId = first.InventoryGenerationId;
        duplicate.PurviewTenantConnectionId = first.PurviewTenantConnectionId;
        await using var context = database.CreateContext();
        context.Add(duplicate);
        var error = await Assert.ThrowsAsync<DbUpdateException>(() => context.SaveChangesAsync());
        Assert.Contains(Assert.IsType<SqlException>(error.InnerException).Number, new[] { 2601, 2627 });
    }

    internal static async Task<PurviewDlpProfile> SeedProfileAsync(LocalSqlDatabase database)
    {
        await using var context = database.CreateContext();
        var profile = TestData.ReadyProfile();
        var connection = new PurviewTenantConnection
        {
            Id = Guid.NewGuid(), TenantId = new(Guid.NewGuid()), Status = PurviewTenantConnectionStatus.Connected,
            LastVerifiedAtUtc = TestData.Now, ExpiresAtUtc = TestData.Now.AddHours(2),
            CreatedAtUtc = TestData.Now, UpdatedAtUtc = TestData.Now, CreatedByObjectId = TestData.Caller
        };
        var inventory = new PurviewSensitiveInformationTypeSnapshotGeneration
        {
            Id = profile.InventoryGenerationId, PurviewTenantConnectionId = connection.Id, TenantId = connection.TenantId,
            RetrievedAtUtc = TestData.Now, CreatedAtUtc = TestData.Now,
            ExpiresAtUtc = profile.SensitiveInformationTypeSnapshotExpiresAtUtc, ItemCount = 1,
            Items =
            [
                new()
                {
                    Id = Guid.NewGuid(), GenerationId = profile.InventoryGenerationId,
                    SensitiveInformationTypeId = profile.SensitiveInformationTypeId,
                    ExactName = profile.SensitiveInformationTypeName
                }
            ]
        };
        profile.PurviewTenantConnectionId = connection.Id;
        await using var transaction = await context.Database.BeginTransactionAsync();
        context.Add(connection);
        await context.SaveChangesAsync();
        context.AddRange(inventory, profile);
        await context.SaveChangesAsync();
        connection.ActiveInventoryGenerationId = inventory.Id;
        await context.SaveChangesAsync();
        await transaction.CommitAsync();
        return profile;
    }
}
