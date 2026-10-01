using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Messages;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.IntegrationTests.Fixtures;
using Gateway.TestSupport;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

[Collection(SqlServerCollection.Name)]
[Trait("Category", "SqlServer")]
public sealed partial class M4ProtectionAdministrationTests(SqlServerFixture fixture)
{
    [Theory]
    [InlineData("Enforce")]
    [InlineData("SimulationWithTips")]
    [InlineData("SimulationWithoutTips")]
    [InlineData("Disabled")]
    public async Task Reviewed_modes_and_each_threshold_round_trip_without_rewriting_children(string mode)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var seed = await SeedAsync(database);
        var (review, request) = await ReviewAsync(database, seed, mode);
        Assert.True(review.Review.AffectsAllBlueprintAgents);
        Assert.Equal("Individual", review.Review.ScopeType);
        Assert.Equal(2, review.Review.SensitiveInformationTypes!.Count);
        var confirmation = await ConfirmAsync(database, seed, review);
        var start = new StartPurviewDlpProfileOperationRequest(confirmation.ConfirmationTokenId,
            confirmation.ConfirmationToken, Guid.NewGuid(), request.ExpectedRowVersion);
        await using (var context = database.CreateContext())
        await using (var transaction = await context.Database.BeginTransactionAsync())
        {
            var accepted = await Mutations(context).Handle(new StartPurviewDlpProfileCommand(seed.Actor, start), default);
            Assert.Equal(review.ReviewTokenId, accepted.OperationId);
            await transaction.CommitAsync();
        }
        await using (var replayContext = database.CreateContext())
        {
            var replay = await Mutations(replayContext).Handle(new StartPurviewDlpProfileCommand(seed.Actor, start), default);
            Assert.Equal(review.ReviewTokenId, replay.OperationId);
        }
        await using var verify = database.CreateContext();
        var profile = await verify.PurviewDlpProfiles.SingleAsync();
        Assert.Equal(mode, profile.EffectivePolicyMode.ToString());
        Assert.Equal(PurviewDlpProfileStatus.Pending, profile.Status);
        Assert.Null(profile.RuntimeBehaviorVerifiedUntilUtc);
        Assert.Null(profile.RuntimeBehaviorSuiteHash);
        Assert.False(profile.Readiness.IsReady);
        Assert.Collection(profile.NormalizedSensitiveInformationTypes,
            first => Assert.Equal(new PurviewSelectedSensitiveInformationType(seed.FirstType, "First synthetic classifier", 2, 3, 80, 100), first),
            second => Assert.Equal(new PurviewSelectedSensitiveInformationType(seed.SecondType, "Second synthetic classifier", 1, -1, 1, 100), second));
        Assert.Equal(2, await verify.AgentRegistrations.CountAsync(agent => agent.FeatureConfiguration.PromptShieldEnabled));
        var publication = Assert.Single(await verify.OutboxMessages
            .Where(message => message.MessageType == nameof(ProtectionAdminOperationMessage)).ToArrayAsync());
        var queued = JsonSerializer.Deserialize<ProtectionAdminOperationMessage>(
            publication.Payload, new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
        Assert.Equal(review.ReviewTokenId, queued.OperationId);
        Assert.Equal(0, queued.ExpectedStepIndex);
        Assert.Equal(0, queued.ExpectedStepAttemptCount);
    }

    [Fact]
    public async Task A_concurrent_profile_edit_rejects_the_reviewed_row_version_before_queueing()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var seed = await SeedAsync(database);
        var (review, request) = await ReviewAsync(database, seed, "Enforce");
        var confirmation = await ConfirmAsync(database, seed, review);
        await using (var change = database.CreateContext())
        {
            (await change.PurviewDlpProfiles.SingleAsync()).DisplayName = "Changed by another administrator";
            await change.SaveChangesAsync();
        }
        await using (var context = database.CreateContext())
        await using (var transaction = await context.Database.BeginTransactionAsync())
        {
            var error = await Assert.ThrowsAsync<PreconditionFailedException>(() => Mutations(context).Handle(
                new StartPurviewDlpProfileCommand(seed.Actor, new(confirmation.ConfirmationTokenId,
                    confirmation.ConfirmationToken, Guid.NewGuid(), request.ExpectedRowVersion)), default));
            Assert.Equal(ErrorCodes.CONCURRENCY_CONFLICT, error.ErrorCode);
            await transaction.RollbackAsync();
        }
        await using var verify = database.CreateContext();
        Assert.Empty(await verify.OutboxMessages.ToArrayAsync());
        Assert.Equal("Changed by another administrator", (await verify.PurviewDlpProfiles.SingleAsync()).DisplayName);
        Assert.Null((await verify.ProtectionAdminOperations.SingleAsync()).ConfirmationVerifier!.ConsumedAtUtc);
    }

    [Fact]
    public async Task Expired_review_at_equality_and_wrong_actor_cannot_authorize()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var seed = await SeedAsync(database);
        var (review, _) = await ReviewAsync(database, seed, "Enforce");
        await using (var context = database.CreateContext())
        {
            await Assert.ThrowsAsync<NotFoundException>(() => Reviews(context, seed).Handle(
                new ConfirmProtectionOperationReviewCommand(new(seed.Actor.TenantId, TestData.Owner),
                    new(review.ReviewTokenId, review.ReviewToken)), default));
        }
        await using (var context = database.CreateContext())
        {
            var expired = await Assert.ThrowsAsync<DomainException>(() =>
                Reviews(context, seed, new FixedTimeProvider(review.ExpiresAtUtc)).Handle(
                    new ConfirmProtectionOperationReviewCommand(seed.Actor, new(review.ReviewTokenId, review.ReviewToken)), default));
            Assert.Equal(ErrorCodes.PROTECTION_REVIEW_EXPIRED, expired.ErrorCode);
        }
        await using var verify = database.CreateContext();
        Assert.Empty(await verify.OutboxMessages.ToArrayAsync());
    }

    [Theory]
    [InlineData("exact")]
    [InlineData("external-id")]
    [InlineData("blueprint-name")]
    [InlineData("actor")]
    [InlineData("conflict")]
    [InlineData("expired-inventory")]
    public async Task Deferred_consent_binds_only_its_reviewed_new_registration(string outcome)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var seed = await SeedAsync(database);
        var deferred = new PurviewDeferredBlueprintDto("m4-deferred-agent", "Reviewed new blueprint");
        var (review, request) = await ReviewAsync(database, seed, "Enforce", deferred);
        var confirmation = await ConfirmAsync(database, seed, review);
        var agent = TestData.Agent(purview: true);
        agent.Status = AgentStatus.Draft;
        agent.ExternalAgentId = new(deferred.ExternalAgentId);
        agent.BlueprintSelectionMode = "CreateNew";
        agent.RequestedBlueprintDisplayName = deferred.DisplayName;
        agent.BlueprintId = null;
        agent.BlueprintObjectId = null;
        await using (var context = database.CreateContext())
        await using (var transaction = await context.Database.BeginTransactionAsync())
        {
            context.Add(agent);
            var accepted = await Mutations(context).Handle(new StartPurviewDlpProfileCommand(seed.Actor,
                new(confirmation.ConfirmationTokenId, confirmation.ConfirmationToken, Guid.NewGuid(), request.ExpectedRowVersion),
                Registration: agent), default);
            Assert.Equal("AwaitingBlueprint", accepted.Status);
            Assert.Equal(review.ReviewTokenId, agent.PurviewConfigurationOperationId);
            await context.SaveChangesAsync();
            await transaction.CommitAsync();
        }
        await using (var provision = database.CreateContext())
        {
            var saved = await provision.AgentRegistrations.SingleAsync(item => item.Id == agent.Id);
            saved.Status = AgentStatus.Active;
            saved.BlueprintId = (outcome == "conflict" ? seed.BlueprintId : Guid.NewGuid()).ToString("D");
            saved.BlueprintObjectId = Guid.NewGuid().ToString("D");
            if (outcome == "external-id") saved.ExternalAgentId = new("different-external-agent");
            if (outcome == "blueprint-name") saved.RequestedBlueprintDisplayName = "Unreviewed blueprint";
            if (outcome == "actor") saved.CreatedByObjectId = TestData.Owner;
            await provision.SaveChangesAsync();
        }
        var clock = new FixedTimeProvider(outcome == "expired-inventory" ? TestData.Now.AddHours(2) : TestData.Now);
        await using (var context = database.CreateContext())
        await using (var transaction = await context.Database.BeginTransactionAsync())
        {
            var handler = Resolver(context, clock);
            if (outcome is "external-id" or "blueprint-name" or "actor")
            {
                var error = await Assert.ThrowsAsync<DomainException>(() => handler.Handle(new(agent.Id), default));
                Assert.Equal(ErrorCodes.PROTECTION_CONFIRMATION_INVALID, error.ErrorCode);
                await transaction.RollbackAsync();
            }
            else
            {
                await handler.Handle(new(agent.Id), default);
                await context.SaveChangesAsync();
                await transaction.CommitAsync();
            }
        }
        await using var verify = database.CreateContext();
        var operation = await verify.ProtectionAdminOperations.SingleAsync();
        Assert.Equal(outcome == "exact" ? ProtectionAdminOperationStatus.Pending :
            outcome is "conflict" or "expired-inventory" ? ProtectionAdminOperationStatus.RequiresManualIntervention :
            ProtectionAdminOperationStatus.AwaitingBlueprint, operation.Status);
        Assert.Equal(outcome == "exact" ? 2 : 1, await verify.PurviewDlpProfiles.CountAsync());
        Assert.Equal(outcome == "exact" ? 1 : 0, await verify.OutboxMessages.CountAsync());
        if (outcome == "exact")
        {
            await Resolver(verify, clock).Handle(new(agent.Id), default);
            await verify.SaveChangesAsync();
            Assert.Equal(1, await verify.OutboxMessages.CountAsync());
            Assert.Equal(2, await verify.PurviewDlpProfiles.CountAsync());
            var queued = JsonSerializer.Deserialize<ProtectionAdminOperationMessage>(
                (await verify.OutboxMessages.SingleAsync()).Payload, new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
            Assert.Equal(operation.Id, queued.OperationId);
            Assert.Equal(0, queued.ExpectedStepIndex);
            Assert.Equal(0, queued.ExpectedStepAttemptCount);
        }
    }

    private static async Task<Seed> SeedAsync(LocalSqlDatabase database)
    {
        var profile = await PersistenceInvariantTests.SeedProfileAsync(database);
        await using var context = database.CreateContext();
        profile = await context.PurviewDlpProfiles.SingleAsync();
        var connection = await context.PurviewTenantConnections.SingleAsync();
        var generation = await context.Set<PurviewSensitiveInformationTypeSnapshotGeneration>().Include(item => item.Items).SingleAsync();
        var firstId = Guid.Parse("11111111-1111-4111-8111-111111111111");
        var secondId = Guid.Parse("22222222-2222-4222-8222-222222222222");
        generation.Items.First().SensitiveInformationTypeId = new(firstId);
        generation.Items.First().ExactName = "First synthetic classifier";
        var additionalType = new PurviewSensitiveInformationTypeSnapshot { Id = Guid.NewGuid(), GenerationId = generation.Id,
            SensitiveInformationTypeId = new(secondId), ExactName = "Second synthetic classifier", SortOrder = 1 };
        generation.Items.Add(additionalType);
        context.Entry(additionalType).State = EntityState.Added;
        generation.ItemCount = 2;
        profile.SensitiveInformationTypeId = new(firstId);
        profile.SensitiveInformationTypeName = "First synthetic classifier";
        profile.SensitiveInformationTypes = [new(firstId, "First synthetic classifier", 1, -1, 75, 100)];
        var first = TestData.Agent(promptShield: true, purview: true);
        var second = TestData.Agent(promptShield: true, purview: true);
        first.BlueprintId = second.BlueprintId = profile.BlueprintApplicationId.Value.ToString("D");
        context.AddRange(first, second, new ProtectionCapability
        {
            Id = Guid.NewGuid(), Kind = ProtectionCapabilityKind.Purview, Status = ProtectionCapabilityStatus.Installed,
            LastReadbackAtUtc = TestData.Now, CreatedAtUtc = TestData.Now, UpdatedAtUtc = TestData.Now
        });
        await context.SaveChangesAsync();
        return new(profile.Id.Value, profile.BlueprintApplicationId.Value, connection.Id, generation.Id.Value,
            new(connection.TenantId.Value, TestData.Caller), firstId, secondId);
    }

    private static async Task<(ProtectionOperationReviewResponse Review, ReviewPurviewDlpProfileOperationRequest Request)> ReviewAsync(
        LocalSqlDatabase database, Seed seed, string mode, PurviewDeferredBlueprintDto? deferred = null)
    {
        await using var context = database.CreateContext();
        var profile = await context.PurviewDlpProfiles.SingleAsync();
        var request = new ReviewPurviewDlpProfileOperationRequest(deferred is null ? seed.ProfileId : null,
            seed.ConnectionId, deferred is null ? seed.BlueprintId : Guid.Empty, "Reviewed shared policy", null,
            mode == "Enforce" ? "Enforce" : "AuditOnly", ["UploadText", "DownloadText"], [new("UploadText", "Block")],
            deferred is null ? Convert.ToBase64String(profile.RowVersion) : "*",
            [new(seed.InventoryId, seed.FirstType, "First synthetic classifier", 2, 3, 80, 100),
             new(seed.InventoryId, seed.SecondType, "Second synthetic classifier", 1, -1, 1, 100)],
            mode, AcknowledgeSharedPolicyImpact: true, DeferredBlueprint: deferred);
        var review = await Reviews(context, seed).Handle(new ReviewPurviewDlpProfileCommand(seed.Actor, request, Guid.NewGuid()), default);
        return (review, request);
    }

    private static async Task<ProtectionOperationConfirmationResponse> ConfirmAsync(
        LocalSqlDatabase database, Seed seed, ProtectionOperationReviewResponse review)
    {
        await using var context = database.CreateContext();
        return await Reviews(context, seed).Handle(new ConfirmProtectionOperationReviewCommand(seed.Actor,
            new(review.ReviewTokenId, review.ReviewToken)), default);
    }

    private static ProtectionReviewHandler Reviews(GatewayDbContext context, Seed seed, TimeProvider? clock = null)
    {
        clock ??= new FixedTimeProvider(TestData.Now);
        var catalog = new OfflineBlueprintCatalog { MaximumCalls = 1,
            Items = [new(Guid.NewGuid(), seed.BlueprintId, "Shared fixture blueprint", true, null)] };
        return new(new ProtectionCapabilityRepository(context), new PurviewTenantConnectionRepository(context),
            new PurviewSensitiveInformationTypeSnapshotRepository(context), new PurviewKnowYourDataConfigurationRepository(context),
            new PurviewDlpProfileRepository(context), new ProtectionAdminOperationRepository(context), catalog,
            new AuditEventRepository(context), new UnitOfWork(context), new(clock), clock);
    }

    private static ProtectionMutationHandler Mutations(GatewayDbContext context)
    {
        var clock = new FixedTimeProvider(TestData.Now);
        return new(new ProtectionCapabilityRepository(context), new PurviewTenantConnectionRepository(context),
            new PurviewSensitiveInformationTypeSnapshotRepository(context), new PurviewKnowYourDataConfigurationRepository(context),
            new PurviewDlpProfileRepository(context), new ProtectionAdminOperationRepository(context),
            new OutboxRepository(context), new AuditEventRepository(context), new UnitOfWork(context), new(clock), clock);
    }

    private static ResolveDeferredPurviewConfigurationHandler Resolver(GatewayDbContext context, TimeProvider clock) =>
        new(new AgentRegistrationRepository(context), new ProtectionAdminOperationRepository(context),
            new PurviewDlpProfileRepository(context), new PurviewTenantConnectionRepository(context),
            new PurviewSensitiveInformationTypeSnapshotRepository(context), new OutboxRepository(context),
            new AuditEventRepository(context), clock);

    private sealed record Seed(Guid ProfileId, Guid BlueprintId, Guid ConnectionId, Guid InventoryId,
        ProtectionActor Actor, Guid FirstType, Guid SecondType);
}
