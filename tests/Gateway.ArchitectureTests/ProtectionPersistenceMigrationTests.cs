using FluentAssertions;

namespace Gateway.ArchitectureTests;

public sealed class ProtectionPersistenceMigrationTests
{
    private const string MigrationName = "20260905_protection_governance_v1.sql";

    [Fact]
    public void Migration_IsOrderedIdempotentFailClosedAndPreservesLegacyEvidence()
    {
        var migration = ReadRepositoryFile("infrastructure", "sql", MigrationName);
        var orderedMigrationNames = Directory
            .EnumerateFiles(Path.Combine(FindRepositoryRoot(), "infrastructure", "sql"), "*.sql")
            .Select(Path.GetFileName)
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();

        Array.IndexOf(orderedMigrationNames, MigrationName).Should().BeGreaterThan(
            Array.IndexOf(orderedMigrationNames, "20260905_active_agent_identity_uniqueness.sql"));
        migration.Should().Contain("SET XACT_ABORT ON");
        migration.Should().Contain("sys.sp_getapplock");
        migration.Should().Contain("@LockOwner = N'Transaction'");
        migration.Should().Contain("OBJECT_ID(N'dbo.PurviewPolicyProfiles', N'U')");
        migration.Should().Contain("ISJSON([BlueprintApplicationIdsJson])");
        migration.Should().Contain("OPENJSON");
        migration.Should().Contain("[LegacyProtectionPolicyCandidates]");
        migration.Should().Contain("[BindingStatus]");
        migration.Should().Contain("N'Unbound'");
        migration.Should().Contain("ReviewRequired");
        migration.Should().Contain("[CollectionPolicyProviderId]");
        migration.Should().Contain("[DlpPolicyProviderId]");
        migration.Should().Contain("[DlpRuleProviderId]");
        migration.Should().Contain("[LegacySourceProfileId]");
        migration.Should().Contain("CROSS APPLY OPENJSON");
        migration.Should().Contain(
            "profiles.[DlpPolicyId], profiles.[DlpRuleId]");
        migration.Should().NotContain(
            "NEWID(), NEWID(), N'NotConnected'");
        migration.Should().NotContain(
            "Legacy Purview profiles overlap a blueprint application");
        migration.Should().NotContain(
            "INSERT INTO [dbo].[PurviewTenantConnections]");
        migration.Should().NotContain(
            "INSERT INTO [dbo].[PurviewSensitiveInformationTypeSnapshotGenerations]");
        migration.Should().NotContain(
            "INSERT INTO [dbo].[PurviewSensitiveInformationTypeSnapshots]");
        migration.Should().NotContain(
            "INSERT INTO [dbo].[PurviewKnowYourDataConfigurations]");
        migration.Should().NotContain(
            "INSERT INTO [dbo].[PurviewDlpProfiles]");
        migration.Should().NotContain(
            "CREATE UNIQUE INDEX [IX_LegacyProtectionPolicyCandidates_BlueprintApplicationId]");
        migration.Should().NotContain(
            "CREATE UNIQUE INDEX [IX_PurviewDlpProfiles_DlpPolicyProviderId]");
        migration.Should().Contain("[Destination]");
        migration.Should().Contain("gateway-provisioning-v3");
        migration.Should().Contain("no data was changed");
        migration.Should().Contain(
            "Legacy combined rows are retained unchanged");
        migration.Should().NotMatchRegex(@"(?im)^\s*DELETE\s+FROM\s+");
        migration.Should().NotContain("Connect-IPPSSession");
        migration.Should().NotContain("Invoke-");
    }

    [Fact]
    public void Migration_CreatesIndependentFixedKydAndOneBlueprintDlpTables()
    {
        var migration = ReadRepositoryFile("infrastructure", "sql", MigrationName);

        migration.Should().Contain("[PurviewKnowYourDataConfigurations]");
        migration.Should().Contain("[PurviewDlpProfiles]");
        migration.Should().Contain("[BlueprintApplicationId] uniqueidentifier NOT NULL");
        migration.Should().Contain("CREATE UNIQUE INDEX [IX_PurviewDlpProfiles_BlueprintApplicationId]");
        migration.Should().NotContain("[BlueprintApplicationIdsJson] nvarchar");
        migration.Should().Contain("ee1680d0-702f-4090-b26c-c49091e86531");
    }

    [Fact]
    public void ProtectionLocksAndOutbox_KeepTheirRequiredOwnershipAndQueueBoundaries()
    {
        var locks = ReadRepositoryFile(
            "src",
            "Gateway.Infrastructure",
            "Services",
            "ProtectionAdminOperationLockProvider.cs");
        var routing = ReadRepositoryFile(
            "src",
            "Gateway.Infrastructure",
            "Outbox",
            "OutboxRouting.cs");
        var outbox = ReadRepositoryFile(
            "src",
            "Gateway.Infrastructure",
            "Persistence",
            "Repositories",
            "OutboxRepository.cs");

        locks.Should().Contain("sys.sp_getapplock");
        locks.Should().Contain("\"Transaction\"");
        locks.Should().Contain("\"Session\"");
        locks.Should().Contain("BeginTransactionAsync");
        locks.Should().Contain("SHA256.HashData");
        locks.Should().NotContain("tenantId.ToString()");
        locks.Should().NotContain("idempotencyKey.ToString()");

        routing.Should().Contain("gateway-provisioning-v3");
        routing.Should().Contain("ProtectionAdminQueueContract.QueueName");
        routing.Should().Contain("nameof(ProtectionAdminOperationMessage)");
        outbox.Should().Contain("[Destination]");
        outbox.Should().Contain("gateway-protection-admin-v1");
        outbox.Should().Contain("gateway-provisioning-v3");
        outbox.Should().Contain("BEGIN TRANSACTION");
        outbox.Should().Contain("PROTECTION_ADMIN_OUTBOX_PUBLISH_FAILED");
        outbox.Should().Contain("ReviewOperationFailure");
        outbox.Should().Contain("ProtectionAdminOperations");
    }

    private static string ReadRepositoryFile(params string[] segments) =>
        File.ReadAllText(Path.Combine([FindRepositoryRoot(), .. segments]));

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "AGENTS.md")))
            directory = directory.Parent;

        return directory?.FullName
            ?? throw new DirectoryNotFoundException("Repository root not found.");
    }
}
