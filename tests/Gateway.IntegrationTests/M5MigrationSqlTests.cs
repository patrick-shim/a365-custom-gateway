using System.Security.Cryptography;
using Gateway.DatabaseMigrator;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence;
using Gateway.IntegrationTests.Fixtures;
using Gateway.TestSupport;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

[Collection(SqlServerCollection.Name)]
[Trait("Category", "SqlServer")]
public sealed class M5MigrationSqlTests(SqlServerFixture fixture)
{
    [Fact]
    public async Task RealEmptyAndForeignDatabasesHaveDifferentInitializationAdmission()
    {
        await using var database = await fixture.CreateEmptyDatabaseAsync();
        await using var context = database.CreateContext();
        Assert.Equal(0, await UserTables(context));
        const string expectedMarker = "synthetic-exact-initialization-marker";
        Assert.Equal(DatabaseInitializationRecoveryMode.Fresh,
            DatabaseBootstrapRecoveryContract.Classify(await UserTables(context), null, expectedMarker, false));
        Assert.True(await context.Database.EnsureCreatedAsync());
        Assert.True(await UserTables(context) > 0);
        Assert.Throws<InvalidOperationException>(() =>
            DatabaseBootstrapRecoveryContract.Classify(1, null, expectedMarker, false));
        Assert.Equal(DatabaseInitializationRecoveryMode.ResumeAfterSchemaCompleted,
            DatabaseBootstrapRecoveryContract.Classify(1, expectedMarker, expectedMarker, true));
        Assert.Throws<InvalidOperationException>(() =>
            DatabaseBootstrapRecoveryContract.Classify(1, expectedMarker, expectedMarker, false));
        Assert.False(await context.Database.EnsureCreatedAsync());
    }

    [Theory]
    [InlineData("Enforce", "Enforce")]
    [InlineData("AuditOnly", "SimulationWithoutTips")]
    public async Task AuthoredMigrationPreservesLegacyModeAndDoesNotInventThresholdsOrBehavior(string legacy, string expected)
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var profile = await PersistenceInvariantTests.SeedProfileAsync(database);
        await using (var context = database.CreateContext())
        {
            var saved = await context.PurviewDlpProfiles.SingleAsync();
            saved.Mode = Enum.Parse<PurviewMode>(legacy);
            saved.PolicyMode = legacy == "Enforce" ? PurviewPolicyMode.Enforce : PurviewPolicyMode.SimulationWithTips;
            await context.SaveChangesAsync();
        }
        await RemoveAdditiveProfileColumns(database);
        var scripts = CurrentScripts();
        await Execute(database, scripts["20260910_purview_configuration_intent.sql"]);
        await Execute(database, scripts["20260910_purview_runtime_tests.sql"]);
        await using var verify = database.CreateContext();
        var migrated = await verify.PurviewDlpProfiles.AsNoTracking().SingleAsync();
        Assert.Equal(legacy, migrated.Mode.ToString());
        Assert.Equal(expected, migrated.PolicyMode!.Value.ToString());
        Assert.Equal(profile.BlueprintApplicationId, migrated.BlueprintApplicationId);
        Assert.Equal(profile.SensitiveInformationTypeId, migrated.SensitiveInformationTypeId);
        var selected = Assert.Single(migrated.SensitiveInformationTypes);
        Assert.Equal(profile.SensitiveInformationTypeId.Value, selected.Id);
        Assert.Equal(profile.SensitiveInformationTypeName, selected.ExactName);
        Assert.Null(selected.MinCount);
        Assert.Null(selected.MaxCount);
        Assert.Null(selected.MinConfidence);
        Assert.Null(selected.MaxConfidence);
        Assert.Null(migrated.RuntimeBehaviorSuiteHash);
        Assert.Null(migrated.RuntimeBehaviorVerifiedUntilUtc);
        Assert.Null(migrated.RuntimeBehaviorCertificationOperationId);
        if (legacy == "Enforce")
        {
            Assert.Null(migrated.RuntimeAllowVerifiedAtUtc);
            Assert.Null(migrated.RuntimeBlockVerifiedAtUtc);
            Assert.Equal("PURVIEW_RUNTIME_SAMPLES_REQUIRED", migrated.LastFailureCode);
        }
        else
        {
            Assert.Equal(profile.RuntimeAllowVerifiedAtUtc, migrated.RuntimeAllowVerifiedAtUtc);
            Assert.Equal(profile.RuntimeBlockVerifiedAtUtc, migrated.RuntimeBlockVerifiedAtUtc);
        }
    }

    [Fact]
    public async Task HistoricalPromptReceiptsRemainUnboundAfterActualAdditiveMigration()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = await PromptWorkflowTests.SeedProtectedAgentAsync(database);
        await using (var context = database.CreateContext())
        {
            await new GatewaySqlHarness(context, GatewaySqlHarness.AllowingShield()).Evaluate()
                .Handle(GatewaySqlHarness.Evaluation(agent), default);
        }
        await Execute(database, """
            ALTER TABLE dbo.PromptEvaluationRecords DROP CONSTRAINT CK_PromptEvaluationRecords_ProtectionBinding;
            ALTER TABLE dbo.PromptEvaluationRecords DROP COLUMN
                ProtectionRevision, ProtectionContextHash, PromptShieldRequired, EvaluatedPurviewPolicyMode;
            """);
        await Execute(database, CurrentScripts()["20260911_prompt_receipt_protection_context.sql"]);
        await using var verify = database.CreateContext();
        var receipt = await verify.PromptEvaluationRecords.AsNoTracking().SingleAsync();
        Assert.Null(receipt.ProtectionRevision);
        Assert.Null(receipt.ProtectionContextHash);
        Assert.Null(receipt.PromptShieldRequired);
        Assert.Null(receipt.EvaluatedPurviewPolicyMode);
        Assert.Equal(agent.Id, receipt.AgentRegistrationId);
        var error = await Assert.ThrowsAsync<SqlException>(() => verify.Database.ExecuteSqlRawAsync(
            "UPDATE dbo.PromptEvaluationRecords SET PromptShieldRequired=1;"));
        Assert.Equal(547, error.Number);
    }

    [Fact]
    public async Task CurrentMigrationsPreserveRegistrationsOutboxAndTheReplayedSchema()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = TestData.Agent();
        var message = new OutboxMessage { Id = Guid.NewGuid(), MessageType = "SyntheticPreservedMessage",
            Payload = "{\"synthetic\":true}", Status = OutboxMessageStatus.Pending, CreatedAtUtc = TestData.Now };
        await using (var context = database.CreateContext())
        {
            context.AddRange(agent, message);
            await context.SaveChangesAsync();
        }
        var scripts = CurrentScripts();
        foreach (var name in DatabaseUpgradeMigrationAdmission.RequiredCurrentScripts)
            await Execute(database, scripts[name]);
        string firstFingerprint;
        await using (var connection = new SqlConnection(database.ConnectionString))
        {
            await connection.OpenAsync();
            firstFingerprint = await ReadRelationalCatalogFingerprint(connection);
        }
        foreach (var name in DatabaseUpgradeMigrationAdmission.RequiredCurrentScripts)
            await Execute(database, scripts[name]);
        await using var verify = database.CreateContext();
        var preserved = await verify.AgentRegistrations.AsNoTracking().SingleAsync();
        Assert.Equal(agent.Id, preserved.Id);
        Assert.Equal(agent.ExternalAgentId, preserved.ExternalAgentId);
        Assert.Equal(agent.Agent365AgentId, preserved.Agent365AgentId);
        Assert.Equal(agent.BlueprintId, preserved.BlueprintId);
        Assert.Equal(agent.ProtectionRevision, preserved.ProtectionRevision);
        var pending = await verify.OutboxMessages.AsNoTracking().SingleAsync();
        Assert.Equal(message.Id, pending.Id);
        Assert.Equal(message.Payload, pending.Payload);
        Assert.Equal(OutboxMessageStatus.Pending, pending.Status);
        await using var current = new SqlConnection(database.ConnectionString);
        await current.OpenAsync();
        Assert.Equal(firstFingerprint, await ReadRelationalCatalogFingerprint(current));
    }

    [Fact]
    public async Task MissingPrerequisiteMigrationFailsBeforeCreatingTables()
    {
        await using var database = await fixture.CreateEmptyDatabaseAsync();
        var exception = await Assert.ThrowsAsync<SqlException>(() =>
            Execute(database, CurrentScripts()["20260910_capability_preparation_receipts.sql"]));
        Assert.Equal(50001, exception.Number);
        await using var verify = database.CreateContext();
        Assert.Equal(0, await UserTables(verify));
    }

    [Fact]
    public async Task ActualMigrationWaitsForItsTransactionOwnedApplicationLock()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var holder = new SqlConnection(database.ConnectionString);
        await holder.OpenAsync();
        await using var transaction = (SqlTransaction)await holder.BeginTransactionAsync();
        await using var command = holder.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            DECLARE @result int;
            EXEC @result=sys.sp_getapplock @Resource=N'A365Gateway:Migration:PurviewRuntimeTests',
                @LockMode=N'Exclusive', @LockOwner=N'Transaction', @LockTimeout=0;
            SELECT @result;
            """;
        Assert.True(Convert.ToInt32(await command.ExecuteScalarAsync()) >= 0);
        var waiting = Execute(database, CurrentScripts()["20260910_purview_runtime_tests.sql"]);
        await database.WaitForApplicationLockWaitAsync();
        Assert.False(waiting.IsCompleted);
        await transaction.CommitAsync();
        await waiting;
    }

    [Fact]
    public void MigrationAdmissionAndLoaderRejectReorderingDuplicatesAndChangedChecksums()
    {
        var names = DatabaseUpgradeMigrationAdmission.RequiredCurrentScripts;
        Assert.Throws<ArgumentException>(() => DatabaseUpgradeMigrationAdmission.AssertRequiredScripts(names.Reverse()));
        Assert.Throws<ArgumentException>(() => DatabaseUpgradeMigrationAdmission.AssertRequiredScripts(names.Concat([names[0]])));
        var manifest = Manifest();
        var changed = manifest with { Scripts = [manifest.Scripts[0] with { Sha256 = Hash('0') }, .. manifest.Scripts.Skip(1)] };
        Assert.Throws<ArgumentException>(() => DatabaseUpgradeExecution.LoadScripts(changed, SqlDirectory()));
        Assert.Equal(4, CurrentScripts().Count);
    }

    private static Task<int> UserTables(GatewayDbContext context) =>
        context.Database.SqlQueryRaw<int>("SELECT COUNT(*) AS [Value] FROM sys.tables WHERE is_ms_shipped=0").SingleAsync();

    private static async Task<string> ReadRelationalCatalogFingerprint(SqlConnection connection)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT CONVERT(nvarchar(max), (
                SELECT
                    (SELECT t.name AS tableName, c.name AS columnName, c.column_id, c.system_type_id,
                        c.max_length, c.precision, c.scale, c.is_nullable, c.is_identity, d.definition AS defaultDefinition
                     FROM sys.tables t JOIN sys.columns c ON c.object_id=t.object_id
                     LEFT JOIN sys.default_constraints d ON d.object_id=c.default_object_id
                     WHERE t.is_ms_shipped=0 ORDER BY t.name,c.column_id FOR JSON PATH) AS columns,
                    (SELECT t.name AS tableName, i.name, i.type, i.is_unique, i.filter_definition,
                        ic.index_column_id, ic.column_id, ic.key_ordinal, ic.is_descending_key, ic.is_included_column
                     FROM sys.tables t JOIN sys.indexes i ON i.object_id=t.object_id
                     JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id
                     WHERE t.is_ms_shipped=0 ORDER BY t.name,i.name,ic.index_column_id FOR JSON PATH) AS indexes,
                    (SELECT OBJECT_NAME(parent_object_id) AS tableName, name, definition, is_disabled, is_not_trusted
                     FROM sys.check_constraints ORDER BY tableName,name FOR JSON PATH) AS checks
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            ));
            """;
        var metadata = (string)(await command.ExecuteScalarAsync()
            ?? throw new InvalidOperationException("Owned SQL catalog readback was empty."));
        return DatabaseUpgradeAttestation.Fingerprint(metadata);
    }

    private static async Task Execute(LocalSqlDatabase database, string sql)
    {
        await using var connection = new SqlConnection(database.ConnectionString);
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandTimeout = 90;
        command.CommandText = sql;
        await command.ExecuteNonQueryAsync();
    }

    private static Task RemoveAdditiveProfileColumns(LocalSqlDatabase database) => Execute(database, """
        ALTER TABLE dbo.PurviewDlpProfiles DROP CONSTRAINT CK_PurviewDlpProfiles_PolicyModeCompatibility;
        ALTER TABLE dbo.PurviewDlpProfiles DROP CONSTRAINT CK_PurviewDlpProfiles_SensitiveInformationTypesJson;
        DECLARE @drop nvarchar(max)=N'';
        SELECT @drop=@drop+N'ALTER TABLE dbo.PurviewDlpProfiles DROP CONSTRAINT '+QUOTENAME(d.name)+N';'
        FROM sys.default_constraints d JOIN sys.columns c ON c.object_id=d.parent_object_id AND c.column_id=d.parent_column_id
        WHERE d.parent_object_id=OBJECT_ID(N'dbo.PurviewDlpProfiles') AND c.name IN (N'PolicyMode',N'SensitiveInformationTypesJson');
        IF @drop<>N'' EXEC sys.sp_executesql @drop;
        ALTER TABLE dbo.PurviewDlpProfiles DROP COLUMN PolicyMode, SensitiveInformationTypesJson,
            RuntimeBehaviorSuiteHash, RuntimeBehaviorVerifiedUntilUtc, RuntimeBehaviorCertificationOperationId;
        """);

    private static IReadOnlyDictionary<string, string> CurrentScripts()
    {
        DatabaseUpgradeMigrationAdmission.AssertRequiredScripts(DatabaseUpgradeMigrationAdmission.RequiredCurrentScripts);
        return DatabaseUpgradeExecution.LoadScripts(Manifest(), SqlDirectory());
    }

    private static DatabaseUpgradeManifest Manifest()
    {
        var scripts = DatabaseUpgradeMigrationAdmission.RequiredCurrentScripts.Select(name =>
        {
            var bytes = File.ReadAllBytes(Path.Combine(SqlDirectory(), name));
            return new DatabaseUpgradeScript(name, "sha256:" + Convert.ToHexStringLower(SHA256.HashData(bytes)));
        }).ToArray();
        return new(1, Hash('a'), Hash('b'), Hash('c'), Guid.NewGuid().ToString("D"), Guid.NewGuid().ToString("D"),
            "synthetic.database.windows.net", "GatewayDb", "https://synthetic.blob.core.windows.net/gateway-upgrade-evidence",
            Hash('d'), Hash('e'), null, scripts);
    }

    private static string Hash(char character) => "sha256:" + new string(character, 64);
    private static string SqlDirectory()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (directory.Name == "Gateway.IntegrationTests" && directory.Parent?.Name == "tests")
                return Path.Combine(directory.Parent.Parent!.FullName, "infrastructure", "sql");
        throw new InvalidOperationException("The migration tests require their own authored source tree.");
    }
}
