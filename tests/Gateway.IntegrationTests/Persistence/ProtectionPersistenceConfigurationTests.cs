using FluentAssertions;
using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Metadata;

namespace Gateway.IntegrationTests.Persistence;

public sealed class ProtectionPersistenceConfigurationTests
{
    private static readonly Type[] ProtectionEntityTypes =
    [
        typeof(ProtectionCapability),
        typeof(PurviewTenantConnection),
        typeof(PurviewSensitiveInformationTypeSnapshotGeneration),
        typeof(PurviewSensitiveInformationTypeSnapshot),
        typeof(PurviewKnowYourDataConfiguration),
        typeof(PurviewDlpProfile),
        typeof(ProtectionAdminOperation),
        typeof(ProtectionAdminOperationStep),
    ];

    [Fact]
    public void Model_MapsEveryProtectionAggregateWithStrongIdsAndConcurrencyTokens()
    {
        using var context = CreateSqlServerContext();

        foreach (var entityType in ProtectionEntityTypes)
            context.Model.FindEntityType(entityType).Should().NotBeNull();

        AssertGuidConversion<PurviewDlpProfile, PurviewDlpProfileId>(
            context,
            nameof(PurviewDlpProfile.Id));
        AssertGuidConversion<PurviewDlpProfile, BlueprintApplicationId>(
            context,
            nameof(PurviewDlpProfile.BlueprintApplicationId));
        AssertGuidConversion<PurviewDlpProfile, SensitiveInformationTypeSnapshotGenerationId>(
            context,
            nameof(PurviewDlpProfile.InventoryGenerationId));
        AssertGuidConversion<PurviewDlpProfile, SensitiveInformationTypeId>(
            context,
            nameof(PurviewDlpProfile.SensitiveInformationTypeId));

        AssertRowVersion<ProtectionCapability>(context);
        AssertRowVersion<PurviewTenantConnection>(context);
        AssertRowVersion<PurviewKnowYourDataConfiguration>(context);
        AssertRowVersion<PurviewDlpProfile>(context);
        AssertRowVersion<ProtectionAdminOperation>(context);
    }

    [Fact]
    public void Model_EnforcesIndependentKydSingleBlueprintDlpAndOrderedSteps()
    {
        using var context = CreateSqlServerContext();

        var kyd = context.Model.FindEntityType(typeof(PurviewKnowYourDataConfiguration))!;
        kyd.GetIndexes().Should().Contain(index =>
            index.IsUnique &&
            index.Properties.Select(property => property.Name)
                .SequenceEqual(new[]
                {
                    nameof(PurviewKnowYourDataConfiguration.PurviewTenantConnectionId),
                }));

        var dlp = context.Model.FindEntityType(typeof(PurviewDlpProfile))!;
        dlp.GetIndexes().Should().Contain(index =>
            index.IsUnique &&
            index.Properties.Select(property => property.Name)
                .SequenceEqual(new[] { nameof(PurviewDlpProfile.BlueprintApplicationId) }));
        dlp.FindProperty(nameof(PurviewDlpProfile.Activities))!
            .GetColumnName().Should().Be("ActivitiesJson");
        dlp.FindProperty(nameof(PurviewDlpProfile.Actions))!
            .GetColumnName().Should().Be("ActionsJson");

        var steps = context.Model.FindEntityType(typeof(ProtectionAdminOperationStep))!;
        steps.GetIndexes().Should().Contain(index =>
            index.IsUnique &&
            index.Properties.Select(property => property.Name).SequenceEqual(new[]
            {
                nameof(ProtectionAdminOperationStep.ProtectionAdminOperationId),
                nameof(ProtectionAdminOperationStep.OrderIndex),
            }));
    }

    [Fact]
    public void GeneratedSqlSchema_ContainsOnlyVerifierMetadataAndExplicitOutboxDestination()
    {
        using var context = CreateSqlServerContext();

        var sql = context.Database.GenerateCreateScript();

        sql.Should().Contain("[ConfirmationVerifierJson] nvarchar(2048) NULL");
        sql.Should().Contain("[Destination] nvarchar(128) NOT NULL");
        sql.Should().NotContain("[ConfirmationToken] ");
        sql.Should().NotContain("[ProviderBody]");
        sql.Should().NotContain("[CertificateBytes]");
        sql.Should().NotContain("[Content]");
    }

    [Fact]
    public void Model_MapsLegacyEvidenceAsUnboundCandidatesWithoutTenantOrGlobalBlueprintUniqueness()
    {
        using var context = CreateSqlServerContext();

        var candidate = context.Model.GetEntityTypes()
            .SingleOrDefault(entity =>
                entity.ClrType.Name == "LegacyProtectionPolicyCandidate");

        candidate.Should().NotBeNull();
        candidate!.GetTableName().Should().Be("LegacyProtectionPolicyCandidates");
        candidate.FindProperty("BindingStatus")!.GetDefaultValue().Should().Be("Unbound");
        candidate.FindProperty("ReviewStatus")!.GetDefaultValue().Should().Be("ReviewRequired");
        candidate.FindProperty("TenantId").Should().BeNull();
        candidate.GetIndexes().Should().NotContain(index =>
            index.IsUnique &&
            index.Properties.Select(property => property.Name)
                .SequenceEqual(new[] { "BlueprintApplicationId" }));
    }

    [Fact]
    public void UpgradeMigration_DeclaresEveryProtectionModelColumnIndexConstraintAndRelationship()
    {
        using var context = CreateSqlServerContext();
        var migration = File.ReadAllText(Path.Combine(
            FindRepositoryRoot(),
            "infrastructure",
            "sql",
            "20260905_protection_governance_v1.sql"));
        var relationalModel = context.GetService<IDesignTimeModel>().Model.GetRelationalModel();
        var targetTables = ProtectionEntityTypes
            .Select(type => context.Model.FindEntityType(type)!)
            .Select(type => StoreObjectIdentifier.Create(type, StoreObjectType.Table)!.Value)
            .Select(storeObject => (storeObject.Schema ?? "dbo", storeObject.Name))
            .ToHashSet();
        targetTables.Add(("dbo", "LegacyProtectionPolicyCandidates"));

        foreach (var table in relationalModel.Tables.Where(table =>
                     targetTables.Contains((table.Schema ?? "dbo", table.Name))))
        {
            migration.Should().Contain($"CREATE TABLE [dbo].[{table.Name}]");
            foreach (var column in table.Columns)
            {
                migration.Should().Contain(
                    $"[{column.Name}] {column.StoreType} {(column.IsNullable ? "NULL" : "NOT NULL")}");
            }

            foreach (var index in table.Indexes)
                migration.Should().Contain($"INDEX [{index.Name}]");
            foreach (var foreignKey in table.ForeignKeyConstraints)
                migration.Should().Contain($"CONSTRAINT [{foreignKey.Name}]");
            foreach (var checkConstraint in table.CheckConstraints)
                migration.Should().Contain($"CONSTRAINT [{checkConstraint.Name}]");
        }
    }

    private static GatewayDbContext CreateSqlServerContext()
    {
        var options = new DbContextOptionsBuilder<GatewayDbContext>()
            .UseSqlServer(
                "Server=localhost;Database=ProtectionSchemaTests;Integrated Security=true;TrustServerCertificate=true")
            .Options;
        return new GatewayDbContext(options);
    }

    private static void AssertGuidConversion<TEntity, TProperty>(
        GatewayDbContext context,
        string propertyName)
        where TEntity : class
    {
        var property = context.Model.FindEntityType(typeof(TEntity))!.FindProperty(propertyName);

        property.Should().NotBeNull();
        property!.ClrType.Should().Be(typeof(TProperty));
        property.GetValueConverter().Should().NotBeNull();
        property.GetValueConverter()!.ProviderClrType.Should().Be(typeof(Guid));
    }

    private static void AssertRowVersion<TEntity>(GatewayDbContext context)
        where TEntity : class
    {
        var property = context.Model.FindEntityType(typeof(TEntity))!
            .FindProperty("RowVersion");

        property.Should().NotBeNull();
        property!.IsConcurrencyToken.Should().BeTrue();
        property.ValueGenerated.Should().Be(ValueGenerated.OnAddOrUpdate);
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "AGENTS.md")))
            directory = directory.Parent;

        return directory?.FullName
            ?? throw new DirectoryNotFoundException("Repository root not found.");
    }
}
