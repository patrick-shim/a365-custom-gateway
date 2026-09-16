using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace Gateway.DatabaseMigrator;

internal static class DatabaseUpgradePostCutoverObserver
{
    internal static async Task AssertRetainedContractsAsync(SqlConnection connection, SqlTransaction transaction)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandTimeout = 60;
        command.CommandText = """
            SET NOCOUNT ON;
            DECLARE @count bigint;
            SELECT @count=COUNT_BIG(*) FROM dbo.PromptEvaluationRecords WITH (TABLOCKX,HOLDLOCK);
            IF EXISTS (SELECT 1 FROM dbo.PromptEvaluationRecords
                WHERE Outcome COLLATE Latin1_General_100_BIN2 NOT IN (N'Allowed',N'Blocked')
                   OR DATALENGTH(Outcome)<>DATALENGTH(RTRIM(Outcome))
                   OR CreatedAtUtc IS NULL OR ExpiresAtUtc IS NULL OR ExpiresAtUtc<=CreatedAtUtc
                   OR (ConsumedAtUtc IS NOT NULL AND ConsumedAtUtc<CreatedAtUtc)
                   OR ((ProtectionRevision IS NOT NULL OR ProtectionContextHash IS NOT NULL
                         OR PromptShieldRequired IS NOT NULL OR EvaluatedPurviewPolicyMode IS NOT NULL)
                       AND (ProtectionRevision IS NULL OR ProtectionRevision='00000000-0000-0000-0000-000000000000'
                         OR ProtectionContextHash IS NULL OR DATALENGTH(ProtectionContextHash)<>64
                         OR ProtectionContextHash COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
                         OR PromptShieldRequired IS NULL OR EvaluatedPurviewPolicyMode IS NULL
                         OR EvaluatedPurviewPolicyMode COLLATE Latin1_General_100_BIN2 NOT IN
                             (N'Disabled',N'SimulationWithTips',N'SimulationWithoutTips',N'Enforce')
                         OR DATALENGTH(EvaluatedPurviewPolicyMode)<>DATALENGTH(RTRIM(EvaluatedPurviewPolicyMode))
                         OR (Outcome=N'Allowed' AND
                            ((PromptShieldRequired=1 AND PromptShieldDecision COLLATE Latin1_General_100_BIN2<>N'Allowed')
                             OR (EvaluatedPurviewPolicyMode=N'Enforce' AND PurviewDecision COLLATE Latin1_General_100_BIN2<>N'Allowed'))))))
                SELECT N'PromptEvaluationNotTerminalOrBound';
            ELSE IF EXISTS (SELECT 1 FROM dbo.ProtectionAdminOperations
                WHERE DeferredConfigurationJson IS NOT NULL AND
                    (ISJSON(DeferredConfigurationJson)<>1 OR LEFT(LTRIM(DeferredConfigurationJson),1)<>N'{'))
                SELECT N'CompletedConfigurationMetadataInvalid';
            ELSE IF EXISTS (SELECT 1 FROM dbo.ProtectionAdminOperations
                WHERE (RuntimeTestConsentJson IS NOT NULL OR RuntimeTestResultJson IS NOT NULL
                       OR RuntimeTestSuiteHash IS NOT NULL OR RuntimeTestConfigurationFingerprint IS NOT NULL)
                  AND (Type COLLATE Latin1_General_100_BIN2<>N'TestDlpRuntime'
                       OR RuntimeTestConsentJson IS NULL OR RuntimeTestResultJson IS NULL
                       OR ISJSON(RuntimeTestConsentJson)<>1 OR ISJSON(RuntimeTestResultJson)<>1
                       OR RuntimeTestSuiteHash IS NULL OR RuntimeTestConfigurationFingerprint IS NULL
                       OR DATALENGTH(RuntimeTestSuiteHash)<>142 OR DATALENGTH(RuntimeTestConfigurationFingerprint)<>142
                       OR LEFT(RuntimeTestSuiteHash,7) COLLATE Latin1_General_100_BIN2<>N'sha256:'
                       OR LEFT(RuntimeTestConfigurationFingerprint,7) COLLATE Latin1_General_100_BIN2<>N'sha256:'
                       OR SUBSTRING(RuntimeTestSuiteHash,8,64) COLLATE Latin1_General_100_BIN2 LIKE N'%[^0-9a-f]%'
                       OR SUBSTRING(RuntimeTestConfigurationFingerprint,8,64) COLLATE Latin1_General_100_BIN2 LIKE N'%[^0-9a-f]%'))
                SELECT N'RuntimeMetadataIncomplete';
            ELSE SELECT N'SafeRetainedContracts';
            """;
        if (await command.ExecuteScalarAsync() is not string result || result != "SafeRetainedContracts")
            throw Unsafe();
        command.CommandText = """
            SELECT Id,RuntimeTestResultJson,RuntimeTestSuiteHash,RuntimeTestConfigurationFingerprint
            FROM dbo.ProtectionAdminOperations WHERE Type=N'TestDlpRuntime' ORDER BY Id;
            """;
        await using var reader = await command.ExecuteReaderAsync();
        var batches = new List<(string Suite, string Configuration, string Mode, string Outcome)>();
        while (await reader.ReadAsync())
        {
            if (reader.IsDBNull(1) || reader.IsDBNull(2) || reader.IsDBNull(3)) throw Unsafe();
            var json = reader.GetString(1);
            if (json.Length > 65536) throw Unsafe();
            try
            {
                using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 12 });
                var root = document.RootElement;
                DatabaseUpgradeExecution.AssertNoDuplicateProperties(root);
                if (!root.TryGetProperty("report", out var report) ||
                    Text(report, "operationId") != reader.GetGuid(0).ToString("D") ||
                    Text(report, "status") != "Completed" ||
                    Text(report, "outcome") is not ("EnforcementBehaviorVerified" or "SimulationExercised" or "Partial" or "SubmissionAccepted") ||
                    Text(report, "suiteHash") != reader.GetString(2) ||
                    Text(report, "configurationFingerprint") != reader.GetString(3) ||
                    !IsNull(report, "failureCode") ||
                    !report.TryGetProperty("completedAtUtc", out var completed) ||
                    completed.ValueKind != JsonValueKind.String || !completed.TryGetDateTimeOffset(out var at) ||
                    at.Offset != TimeSpan.Zero ||
                    !report.TryGetProperty("outstandingSensitiveInformationTypeIds", out var outstanding) ||
                    outstanding.ValueKind != JsonValueKind.Array ||
                    !root.TryGetProperty("evidence", out var evidence) ||
                    evidence.ValueKind != JsonValueKind.Array || evidence.GetArrayLength() == 0)
                    throw Unsafe();
                var mode = Text(report, "policyMode");
                var outcome = Text(report, "outcome")!;
                var simulation = mode is "SimulationWithTips" or "SimulationWithoutTips";
                if (mode is not ("Enforce" or "SimulationWithTips" or "SimulationWithoutTips") ||
                    (outcome == "EnforcementBehaviorVerified" && mode != "Enforce") ||
                    (outcome is "SimulationExercised" or "SubmissionAccepted" && !simulation) ||
                    (outcome is "EnforcementBehaviorVerified" or "SimulationExercised" && outstanding.GetArrayLength() != 0))
                    throw Unsafe();
                foreach (var item in evidence.EnumerateArray())
                    if (Text(item, "operationId") != reader.GetGuid(0).ToString("D") ||
                        Text(item, "suiteHash") != reader.GetString(2) ||
                        Text(item, "configurationFingerprint") != reader.GetString(3) ||
                        Text(item, "behavior") is not ("BehaviorObserved" or "SubmissionAccepted") ||
                        !item.TryGetProperty("observation", out var observation) || !IsNull(observation, "failureCode"))
                        throw Unsafe();
                batches.Add((reader.GetString(2), reader.GetString(3), mode, outcome));
                // Historical certification expiry does not turn completed work into an in-flight effect.
                // This admits preservation only, never current policy readiness or receipt consumption.
            }
            catch (JsonException) { throw Unsafe(); }
            catch (ArgumentException) { throw Unsafe(); }
        }
        var completedSuites = batches
            .Where(batch => batch.Outcome is "EnforcementBehaviorVerified" or "SimulationExercised")
            .Select(batch => (batch.Suite, batch.Configuration, batch.Mode)).ToHashSet();
        if (batches.Any(batch => batch.Outcome == "Partial" &&
            !completedSuites.Contains((batch.Suite, batch.Configuration, batch.Mode))))
            throw Unsafe();
    }

    private static string? Text(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var property) &&
        property.ValueKind == JsonValueKind.String ? property.GetString() : null;

    private static bool IsNull(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var property) &&
        property.ValueKind == JsonValueKind.Null;

    private static InvalidOperationException Unsafe() => new(
        "UpgradeCutoverManualReconciliationRequired: current retained contracts are incomplete, ambiguous, or nonterminal. No record was deleted, consumed, backfilled, or replayed.");
}
