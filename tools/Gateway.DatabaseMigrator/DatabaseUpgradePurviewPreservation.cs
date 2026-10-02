using System.Buffers.Binary;
using System.Data;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Persistence;
using Microsoft.Data.SqlClient;

namespace Gateway.DatabaseMigrator;

internal sealed record DatabaseUpgradePurviewScope(Guid[] OperationIds, Guid[] ConnectionIds)
{
    internal string OperationIdsJson => JsonSerializer.Serialize(OperationIds);
}

internal static class DatabaseUpgradePurviewPreservation
{
    // Inspect every identifier property: JSON_VALUE alone can hide work behind a duplicate key.
    private const string OutboxCorrelationSql = """
        EXISTS (SELECT 1 FROM OPENJSON(CASE WHEN ISJSON(m.Payload)=1 THEN m.Payload ELSE N'{}' END) field
            WHERE (field.[key] COLLATE Latin1_General_100_BIN2 IN (N'OperationId',N'operationId')
                AND TRY_CONVERT(uniqueidentifier,field.value)=o.Id)
                OR (field.[key] COLLATE Latin1_General_100_BIN2 IN (N'CorrelationId',N'correlationId')
                AND TRY_CONVERT(uniqueidentifier,field.value)=o.CorrelationId))
        """;

    private static readonly JsonSerializerOptions StrictJson = new()
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        MaxDepth = 12
    };

    internal static async Task<(DatabaseUpgradePurviewScope? Scope, Dictionary<Guid, string> Rejections)> ReadScopeAsync(
        SqlConnection connection, SqlTransaction transaction)
    {
        AssertTransaction(connection, transaction);
        var json = await ReadJsonAsync(connection, transaction, $"""
            DECLARE @count bigint;
            SELECT @count=COUNT_BIG(*) FROM dbo.ProtectionAdminOperations WITH (TABLOCKX,HOLDLOCK);
            SELECT @count=COUNT_BIG(*) FROM dbo.ProtectionAdminOperationSteps WITH (TABLOCKX,HOLDLOCK);
            SELECT @count=COUNT_BIG(*) FROM dbo.OutboxMessages WITH (TABLOCKX,HOLDLOCK);
            SELECT @count=COUNT_BIG(*) FROM dbo.PurviewTenantConnections WITH (TABLOCKX,HOLDLOCK);
            SELECT COALESCE((SELECT TOP (1001) o.*,
                JSON_QUERY(COALESCE((SELECT s.* FROM dbo.ProtectionAdminOperationSteps s
                    WHERE s.ProtectionAdminOperationId=o.Id ORDER BY s.OrderIndex,s.Id
                    FOR JSON PATH,INCLUDE_NULL_VALUES),N'[]')) AS steps,
                JSON_QUERY(COALESCE((SELECT c.* FROM dbo.PurviewTenantConnections c
                    WHERE c.Id=TRY_CONVERT(uniqueidentifier,o.TargetIdentifier)
                    ORDER BY c.Id FOR JSON PATH,INCLUDE_NULL_VALUES),N'[]')) AS connections,
                (SELECT COUNT_BIG(*) FROM dbo.OutboxMessages m
                    WHERE {OutboxCorrelationSql})
                    AS outboxCount
                FROM dbo.ProtectionAdminOperations o
                WHERE o.Status COLLATE Latin1_General_100_BIN2=N'AwaitingAdministrator'
                ORDER BY o.Id FOR JSON PATH,INCLUDE_NULL_VALUES),N'[]');
            """);
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.GetArrayLength() > 1000)
            throw new InvalidOperationException("UpgradeCutoverManualReconciliationRequired: PurviewHumanWaitInventoryExceedsBound.");
        var ids = new List<Guid>();
        var connections = new HashSet<Guid>();
        var rejections = new Dictionary<Guid, string>();
        var now = DateTime.UtcNow;
        foreach (var row in document.RootElement.EnumerateArray())
        {
            var id = row.GetProperty("Id").GetGuid();
            try
            {
                var target = ValidateHumanWait(row, now);
                ids.Add(id);
                connections.Add(target);
            }
            catch (HumanWaitInvalid exception) { rejections.Add(id, exception.Code); }
            catch (Exception exception) when (exception is JsonException or FormatException or KeyNotFoundException or
                InvalidOperationException or ArgumentException or DomainException)
            {
                rejections.Add(id, "MalformedHumanWaitBinding");
            }
        }
        return (ids.Count == 0 ? null : new(ids.Order().ToArray(), connections.Order().ToArray()), rejections);
    }

    private static Guid ValidateHumanWait(JsonElement row, DateTime now)
    {
        Require(Text(row, "Type") == "ConnectPurviewTenant" && Number(row, "WorkflowVersion") == 1 &&
            Text(row, "Status") == "AwaitingAdministrator" &&
            Text(row, "RequiredAction") == "CompletePurviewTenantConnection" &&
            Text(row, "TargetType") == "PurviewTenantConnection", "NotLegacyConnectionHumanWait");
        Require(Number(row, "AttemptCount") == 0 && Number(row, "MaximumAttempts") == 5 &&
            Text(row, "RetryDisposition") == "Retryable" &&
            Null(row, "CompletedAtUtc", "NextAttemptAtUtc", "ReadbackReferenceId", "LastFailureCode",
                "DeferredConfigurationJson", "RuntimeTestConsentJson", "RuntimeTestResultJson",
                "RuntimeTestSuiteHash", "RuntimeTestConfigurationFingerprint") &&
            Number(row, "outboxCount") == 0, "HumanWaitHasExecutionEvidence");
        var id = Id(row, "Id");
        var tenant = Id(row, "TenantId");
        var actor = CanonicalId(row, "ActorObjectId");
        var target = CanonicalId(row, "TargetIdentifier");
        _ = Id(row, "IdempotencyKey");
        var correlation = Id(row, "CorrelationId");
        Require(Bytes(row, "RowVersion").Length == 8 && Bytes(row, "ExpectedRowVersion").Length is 0 or 8 &&
            DatabaseUpgradeAttestation.IsFingerprint(Text(row, "AcceptedRequestHash")) &&
            Text(row, "ReviewedPayloadHash") == DatabaseUpgradeAttestation.Fingerprint(
                JsonSerializer.Serialize(new { tenantId = tenant })), "HumanWaitReviewBindingInvalid");
        var created = DatabaseUtc(row, "CreatedAtUtc");
        var started = DatabaseUtc(row, "StartedAtUtc");
        Require(created <= started && started <= now && DatabaseUtc(row, "UpdatedAtUtc") == started,
            "HumanWaitTimestampsInvalid");
        var confirmationJson = Text(row, "ConfirmationVerifierJson");
        Require(confirmationJson.Length is > 0 and <= 2048, "HumanWaitConfirmationInvalid");
        using (var confirmation = JsonDocument.Parse(confirmationJson))
        {
            var value = confirmation.RootElement;
            DatabaseUpgradeExecution.AssertNoDuplicateProperties(value);
            ExactProperties(value, ["reviewTokenId", "confirmationTokenId", "formatVersion", "hashAlgorithm",
                "verifierSalt", "verifierHash", "expiresAtUtc", "consumedAtUtc"]);
            Require(CanonicalId(value, "reviewTokenId") == id && CanonicalId(value, "confirmationTokenId") == id &&
                Number(value, "formatVersion") == 1 && Text(value, "hashAlgorithm") == "PBKDF2-SHA256-210000" &&
                Bytes(value, "verifierSalt").Length == 32 && Bytes(value, "verifierHash").Length == 32 &&
                JsonUtc(value, "consumedAtUtc") == started && JsonUtc(value, "expiresAtUtc") > started,
                "HumanWaitConfirmationInvalid");
        }
        var steps = row.GetProperty("steps");
        Require(steps.GetArrayLength() == 8, "HumanWaitStepCountInvalid");
        var stepIds = new HashSet<Guid>();
        for (var index = 0; index < 8; index++)
        {
            var step = steps[index];
            Require(stepIds.Add(Id(step, "Id")) && Id(step, "ProtectionAdminOperationId") == id &&
                Number(step, "OrderIndex") == index &&
                Text(step, "StepType") == ProtectionAdminWorkflow.CurrentSteps[index].ToString() &&
                Text(step, "Status") == (index == 0 ? "Completed" : index == 1 ? "AwaitingAdministrator" : "Pending") &&
                Number(step, "AttemptCount") == 0 && Text(step, "RetryDisposition") == "NotApplicable" &&
                Null(step, "NextAttemptAtUtc", "ReadbackReferenceId", "FailureCode") &&
                (index == 0 ? DatabaseUtc(step, "StartedAtUtc") == started && DatabaseUtc(step, "CompletedAtUtc") == started
                    : Null(step, "StartedAtUtc", "CompletedAtUtc")), "HumanWaitStepNotPristine");
        }
        var linked = row.GetProperty("connections");
        Require(linked.GetArrayLength() == 1, "HumanWaitConnectionIdentityInvalid");
        var connection = linked[0];
        Require(Id(connection, "Id") == target && Id(connection, "TenantId") == tenant &&
            CanonicalId(connection, "CreatedByObjectId") == actor &&
            DatabaseUtc(connection, "CreatedAtUtc") <= started && Bytes(connection, "RowVersion").Length == 8,
            "HumanWaitConnectionIdentityInvalid");
        var resultJson = Text(row, "ResultJson");
        Require(resultJson.Length is > 0 and <= 4000, "HumanWaitLaunchInvalid");
        using var result = JsonDocument.Parse(resultJson);
        DatabaseUpgradeExecution.AssertNoDuplicateProperties(result.RootElement);
        Require(CanonicalId(result.RootElement, "OperationId") == id &&
            CanonicalId(result.RootElement, "CorrelationId") == correlation &&
            CanonicalId(result.RootElement.GetProperty("CompanionLaunch"), "OperationId") == id,
            "HumanWaitLaunchInvalid");
        _ = CanonicalId(result.RootElement.GetProperty("CompanionLaunch"), "InventoryGenerationId");
        var accepted = JsonSerializer.Deserialize<ProtectionOperationAcceptedResponse>(resultJson, StrictJson);
        Require(accepted is not null && accepted.OperationId == id && accepted.CorrelationId == correlation &&
            accepted.Status == "AwaitingAdministrator" && accepted.CompanionLaunch is not null, "HumanWaitLaunchInvalid");
        var operation = new ProtectionAdminOperation
        {
            Id = id, TenantId = new EntraTenantId(tenant), ActorObjectId = actor.ToString("D"), ResultJson = resultJson
        };
        var launch = PurviewCompanionLaunchContract.Read(operation);
        Require(launch.ExpiresAtUtc.UtcDateTime > started && launch.ExpiresAtUtc.UtcDateTime <= now,
            "HumanWaitLaunchNotExpired");
        return target;
    }

    internal static async Task<string> FingerprintAsync(
        SqlConnection connection, SqlTransaction transaction, DatabaseUpgradePurviewScope scope)
    {
        AssertTransaction(connection, transaction);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Append(hash, "PurviewHumanWaitPreservation/v1");
        Append(hash, scope.OperationIdsJson);
        Append(hash, JsonSerializer.Serialize(scope.ConnectionIds));
        foreach (var (table, predicate) in new[]
        {
            ("ProtectionAdminOperations", "m.Id IN (SELECT value FROM OPENJSON(@operations))"),
            ("ProtectionAdminOperationSteps", "m.ProtectionAdminOperationId IN (SELECT value FROM OPENJSON(@operations))"),
            ("PurviewTenantConnections", "m.Id IN (SELECT value FROM OPENJSON(@connections))"),
            ("OutboxMessages", $"""
                EXISTS (SELECT 1 FROM dbo.ProtectionAdminOperations o
                    WHERE o.Id IN (SELECT value FROM OPENJSON(@operations)) AND {OutboxCorrelationSql})
                """)
        })
        {
            var metadata = await ReadJsonAsync(connection, transaction, """
                SELECT COALESCE((SELECT name,column_id,system_type_id,user_type_id,max_length,precision,scale,
                    is_nullable,collation_name,is_computed,generated_always_type
                    FROM sys.columns WHERE object_id=OBJECT_ID(@table,N'U')
                    ORDER BY column_id FOR JSON PATH,INCLUDE_NULL_VALUES),N'[]');
                """, ("@table", "dbo." + table));
            using var columns = JsonDocument.Parse(metadata);
            Require(columns.RootElement.GetArrayLength() is > 0 and <= 128, "PurviewPreservationColumnsUnavailable");
            var names = columns.RootElement.EnumerateArray().Select(column => Text(column, "name")).ToArray();
            Require(names.Contains("Id", StringComparer.Ordinal), "PurviewPreservationIdentityUnavailable");
            // Binary projection preserves raw UTF-16 JSON, trailing spaces, nulls and rowversions.
            var projection = string.Join(",", names.Select(name =>
                $"CONVERT(varbinary(max),m.[{name.Replace("]", "]]", StringComparison.Ordinal)}]) AS [{name.Replace("]", "]]", StringComparison.Ordinal)}]"));
            var rows = await ReadJsonAsync(connection, transaction, $"""
                SELECT COALESCE((SELECT {projection} FROM dbo.[{table}] m WITH (TABLOCKX,HOLDLOCK)
                    WHERE {predicate} ORDER BY m.Id FOR JSON PATH,INCLUDE_NULL_VALUES),N'[]');
                """, ("@operations", scope.OperationIdsJson), ("@connections", JsonSerializer.Serialize(scope.ConnectionIds)));
            Append(hash, table);
            Append(hash, metadata);
            Append(hash, rows);
        }
        return "sha256:" + Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    internal static async Task<string> DiagnosticsAsync(SqlConnection connection, SqlTransaction transaction,
        IReadOnlySet<Guid> admitted, IReadOnlyDictionary<Guid, string>? rejections)
    {
        var json = await ReadJsonAsync(connection, transaction, $"""
            SELECT COALESCE((SELECT o.Id,o.Type,o.WorkflowVersion,o.Status,o.RetryDisposition,o.AttemptCount,
                o.CompletedAtUtc,o.NextAttemptAtUtc,
                CAST(CASE WHEN o.LastFailureCode IS NULL THEN 0 ELSE 1 END AS bit) AS hasFailure,
                CAST(CASE WHEN o.ReadbackReferenceId IS NULL THEN 0 ELSE 1 END AS bit) AS hasReadback,
                CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.OutboxMessages m
                    WHERE {OutboxCorrelationSql}
                    AND (m.Status COLLATE Latin1_General_100_BIN2<>N'Published' OR m.Status IS NULL OR
                        m.PublishedAtUtc IS NULL OR m.NextRetryAtUtc IS NOT NULL))
                    THEN 1 ELSE 0 END AS bit) AS hasOutboxWork,
                JSON_QUERY(COALESCE((SELECT s.Id,s.OrderIndex,s.StepType,s.Status,s.RetryDisposition,s.AttemptCount,
                    s.CompletedAtUtc,s.NextAttemptAtUtc,
                    CAST(CASE WHEN s.FailureCode IS NULL THEN 0 ELSE 1 END AS bit) AS hasFailure
                    FROM dbo.ProtectionAdminOperationSteps s WHERE s.ProtectionAdminOperationId=o.Id
                    ORDER BY s.OrderIndex,s.Id FOR JSON PATH,INCLUDE_NULL_VALUES),N'[]')) AS steps
                FROM dbo.ProtectionAdminOperations o ORDER BY o.Id FOR JSON PATH,INCLUDE_NULL_VALUES),N'[]');
            """);
        using var document = JsonDocument.Parse(json);
        var blockers = new List<object>();
        foreach (var row in document.RootElement.EnumerateArray())
        {
            var id = row.GetProperty("Id").GetGuid();
            if (admitted.Contains(id)) continue;
            var steps = row.GetProperty("steps").EnumerateArray().ToArray();
            var type = SafeEnum<ProtectionAdminOperationType>(row, "Type");
            var status = SafeEnum<ProtectionAdminOperationStatus>(row, "Status");
            var retry = SafeEnum<ProtectionRetryDisposition>(row, "RetryDisposition");
            var validSteps = steps.Length == (type == "TestDlpRuntime" ? 0 : 8) &&
                steps.Select((step, index) => Number(step, "OrderIndex") == index &&
                    SafeEnum<ProtectionAdminStepType>(step, "StepType") == ProtectionAdminWorkflow.CurrentSteps[index].ToString() &&
                    SafeEnum<ProtectionAdminStepStatus>(step, "Status") is "Completed" or "Skipped" &&
                    (index != 7 || Text(step, "Status") == "Completed") &&
                    SafeEnum<ProtectionRetryDisposition>(step, "RetryDisposition") == "NotApplicable" &&
                    !Null(step, "CompletedAtUtc") && Null(step, "NextAttemptAtUtc") && !step.GetProperty("hasFailure").GetBoolean()).All(value => value);
            if (type != "Unknown" && status == "Completed" && Number(row, "WorkflowVersion") == 1 &&
                retry == "NotApplicable" && !Null(row, "CompletedAtUtc") && Null(row, "NextAttemptAtUtc") &&
                !row.GetProperty("hasFailure").GetBoolean() && !row.GetProperty("hasOutboxWork").GetBoolean() && validSteps) continue;
            blockers.Add(new
            {
                operationId = id, type, workflowVersion = Number(row, "WorkflowVersion"), status, retry,
                attempts = Number(row, "AttemptCount"), scheduled = !Null(row, "NextAttemptAtUtc"),
                failure = row.GetProperty("hasFailure").GetBoolean(), readback = row.GetProperty("hasReadback").GetBoolean(),
                outboxWork = row.GetProperty("hasOutboxWork").GetBoolean(),
                classification = rejections is not null && rejections.TryGetValue(id, out var reason) ? reason
                    : status == "Completed" ? "ProtectionCheckpointOrBindingInvalid" : "ProtectionOperationNotProvenComplete",
                steps = steps.Select(step => new
                {
                    order = Number(step, "OrderIndex"), type = SafeEnum<ProtectionAdminStepType>(step, "StepType"),
                    status = SafeEnum<ProtectionAdminStepStatus>(step, "Status"),
                    retry = SafeEnum<ProtectionRetryDisposition>(step, "RetryDisposition"),
                    attempts = Number(step, "AttemptCount"),
                    scheduled = !Null(step, "NextAttemptAtUtc"), failure = step.GetProperty("hasFailure").GetBoolean()
                }).ToArray()
            });
        }
        return JsonSerializer.Serialize(blockers);
    }

    internal static void AssertTransaction(SqlConnection connection, SqlTransaction transaction)
    {
        if (transaction.Connection != connection || transaction.IsolationLevel != IsolationLevel.Serializable)
            throw new InvalidOperationException("Purview preservation requires the active serializable preservation transaction.");
    }

    private static async Task<string> ReadJsonAsync(SqlConnection connection, SqlTransaction transaction, string sql,
        params (string Name, string Value)[] parameters)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandTimeout = 60;
        command.CommandText = sql;
        foreach (var (name, value) in parameters) command.Parameters.Add(name, SqlDbType.NVarChar, -1).Value = value;
        return await command.ExecuteScalarAsync() as string
            ?? throw new InvalidOperationException("Purview preservation metadata could not be read exactly.");
    }

    private static void Append(IncrementalHash hash, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        try
        {
            Span<byte> length = stackalloc byte[sizeof(int)];
            BinaryPrimitives.WriteInt32LittleEndian(length, bytes.Length);
            hash.AppendData(length);
            hash.AppendData(bytes);
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    private static string SafeEnum<T>(JsonElement value, string name) where T : struct, Enum =>
        value.GetProperty(name).ValueKind == JsonValueKind.String &&
        Enum.TryParse<T>(Text(value, name), out var parsed) && Enum.IsDefined(parsed) &&
        parsed.ToString() == Text(value, name) ? parsed.ToString() : "Unknown";

    private static string Text(JsonElement value, string name) => value.GetProperty(name).GetString() ?? throw new HumanWaitInvalid("MissingHumanWaitValue");
    private static int Number(JsonElement value, string name) => value.GetProperty(name).GetInt32();
    private static bool Null(JsonElement value, params string[] names) => names.All(name => value.GetProperty(name).ValueKind == JsonValueKind.Null);
    private static Guid Id(JsonElement value, string name)
    {
        var id = value.GetProperty(name).GetGuid();
        Require(id != Guid.Empty, "HumanWaitIdentityInvalid");
        return id;
    }
    private static Guid CanonicalId(JsonElement value, string name)
    {
        Require(DatabaseUpgradeAttestation.IsCanonicalGuid(Text(value, name)), "HumanWaitIdentityInvalid");
        return Id(value, name);
    }
    private static byte[] Bytes(JsonElement value, string name)
    {
        var text = Text(value, name);
        var bytes = Convert.FromBase64String(text);
        Require(Convert.ToBase64String(bytes) == text, "HumanWaitBinaryBindingInvalid");
        return bytes;
    }
    private static DateTime DatabaseUtc(JsonElement value, string name)
    {
        var date = value.GetProperty(name).GetDateTime();
        return date.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(date, DateTimeKind.Utc) : date.ToUniversalTime();
    }
    private static DateTime JsonUtc(JsonElement value, string name)
    {
        var date = value.GetProperty(name).GetDateTime();
        Require(date.Kind == DateTimeKind.Utc, "HumanWaitConfirmationInvalid");
        return date;
    }
    private static void ExactProperties(JsonElement value, string[] names) =>
        Require(value.ValueKind == JsonValueKind.Object && value.EnumerateObject().Count() == names.Length &&
            value.EnumerateObject().All(property => names.Contains(property.Name, StringComparer.Ordinal)), "HumanWaitMetadataShapeInvalid");
    private static void Require(bool condition, string code)
    {
        if (!condition) throw new HumanWaitInvalid(code);
    }
    private sealed class HumanWaitInvalid(string code) : Exception(code)
    {
        internal string Code { get; } = code;
    }
}
