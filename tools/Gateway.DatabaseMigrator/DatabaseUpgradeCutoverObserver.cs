using Microsoft.Data.SqlClient;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;

namespace Gateway.DatabaseMigrator;

/// <summary>
/// Observes existing durable contracts, not the new schema or operator-supplied checkpoint flags.
/// Successful historical work is retained; uncertain work is never replayed or repaired here.
/// </summary>
public static class DatabaseUpgradeCutoverObserver
{
    public static Task AssertSafeAsync(SqlConnection connection, SqlTransaction transaction) =>
        AssertSafeCoreAsync(connection, transaction, postUpgrade: false, forRollback: false);

    internal static Task AssertPostUpgradeSafeAsync(SqlConnection connection, SqlTransaction transaction, bool forRollback = true) =>
        AssertSafeCoreAsync(connection, transaction, postUpgrade: true, forRollback);

    private static async Task AssertSafeCoreAsync(SqlConnection connection, SqlTransaction transaction, bool postUpgrade, bool forRollback)
    {
        if (transaction.Connection != connection ||
            transaction.IsolationLevel != System.Data.IsolationLevel.Serializable)
            throw new InvalidOperationException("The durable cutover observer requires the active serializable preservation transaction.");

        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandTimeout = 60;
        command.CommandText = ObservationSql;
        command.Parameters.AddWithValue("@postUpgrade", postUpgrade);
        command.Parameters.AddWithValue("@forRollback", forRollback);
        try
        {
            var blocker = await command.ExecuteScalarAsync();
            if (blocker is not string classification || classification != "SafeTerminal")
                throw new InvalidOperationException(
                    $"UpgradeCutoverManualReconciliationRequired: {blocker ?? "MissingObservation"}. " +
                    "No upgrade SQL was started; no replay, deletion, or checkpoint repair is authorized.");
            await AssertProvisioningCheckpointsAsync(connection, transaction);
            if (postUpgrade)
                await DatabaseUpgradePostCutoverObserver.AssertRetainedContractsAsync(connection, transaction);
            else
                await AssertAdditiveContractsAsync(connection, transaction);
        }
        catch (SqlException)
        {
            throw new InvalidOperationException(
                "UpgradeCutoverObservationUnavailable: required durable SQL contracts could not be read exactly. " +
                "Manual reconciliation is required; no upgrade SQL was started.");
        }
    }

    public static async Task AssertAdditiveContractsAsync(SqlConnection connection, SqlTransaction transaction)
    {
        if (transaction.Connection != connection || transaction.IsolationLevel != System.Data.IsolationLevel.Serializable)
            throw new InvalidOperationException("The additive cutover observer requires the active serializable preservation transaction.");
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandTimeout = 60;
        command.CommandText = """
            SET NOCOUNT ON;
            DECLARE @blocked bit=0;
            IF COL_LENGTH(N'dbo.PromptEvaluationRecords',N'ProtectionRevision') IS NOT NULL
                EXEC sys.sp_executesql N'
                    IF EXISTS (SELECT 1 FROM dbo.PromptEvaluationRecords WITH (TABLOCKX,HOLDLOCK)
                        WHERE ProtectionRevision IS NOT NULL OR ProtectionContextHash IS NOT NULL
                            OR PromptShieldRequired IS NOT NULL OR EvaluatedPurviewPolicyMode IS NOT NULL)
                        SET @blocked=1;', N'@blocked bit OUTPUT', @blocked OUTPUT;
            IF COL_LENGTH(N'dbo.ProtectionAdminOperations',N'DeferredConfigurationJson') IS NOT NULL
                EXEC sys.sp_executesql N'
                    IF EXISTS (SELECT 1 FROM dbo.ProtectionAdminOperations WITH (TABLOCKX,HOLDLOCK)
                        WHERE DeferredConfigurationJson IS NOT NULL)
                        SET @blocked=1;', N'@blocked bit OUTPUT', @blocked OUTPUT;
            IF COL_LENGTH(N'dbo.ProtectionAdminOperations',N'RuntimeTestConsentJson') IS NOT NULL
                EXEC sys.sp_executesql N'
                    IF EXISTS (SELECT 1 FROM dbo.ProtectionAdminOperations WITH (TABLOCKX,HOLDLOCK)
                        WHERE RuntimeTestConsentJson IS NOT NULL OR RuntimeTestResultJson IS NOT NULL
                            OR RuntimeTestSuiteHash IS NOT NULL OR RuntimeTestConfigurationFingerprint IS NOT NULL)
                        SET @blocked=1;', N'@blocked bit OUTPUT', @blocked OUTPUT;
            SELECT @blocked;
            """;
        if (await command.ExecuteScalarAsync() is not bool blocked || blocked)
            throw new InvalidOperationException(
                "UpgradeCutoverManualReconciliationRequired: additive prompt/configuration/runtime-test work has no approved old-contract classification. " +
                "Records were retained; no replay, deletion, or rollback admission is authorized.");
    }

    private static async Task AssertProvisioningCheckpointsAsync(SqlConnection connection, SqlTransaction transaction)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandTimeout = 60;
        command.CommandText = """
            SELECT ProvisioningJobId,OrderIndex,ResultData FROM dbo.ProvisioningJobSteps
            ORDER BY ProvisioningJobId,OrderIndex;
            """;
        await using var reader = await command.ExecuteReaderAsync();
        Guid? previousJob = null;
        Agent365ProvisioningState? previousState = null;
        while (await reader.ReadAsync())
        {
            var job = reader.GetGuid(0);
            if (job != previousJob) previousState = null;
            var step = ProvisioningWorkflow.CurrentSteps[reader.GetInt32(1)];
            Agent365ProvisioningStepResult? result;
            try
            {
                var json = reader.GetString(2);
                if (json.Length > 4000) throw new JsonException();
                using var document = JsonDocument.Parse(json);
                AssertUniqueProperties(document.RootElement);
                result = JsonSerializer.Deserialize<Agent365ProvisioningStepResult>(json, new JsonSerializerOptions
                {
                    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, MaxDepth = 8
                });
            }
            catch (JsonException) { throw AmbiguousProvisioning(); }
            if (result is null || result.StepType != step || result.State is null ||
                string.IsNullOrWhiteSpace(result.CompletionEvidence) || result.CompletionEvidence.Length > 64 ||
                !result.CompletionEvidence.All(c => char.IsLetterOrDigit(c) || c is '-' or '_') ||
                !StepComplete(step, result.State))
                throw AmbiguousProvisioning();
            if (previousState is not null)
            {
                var before = JsonSerializer.SerializeToElement(previousState);
                var after = JsonSerializer.SerializeToElement(result.State);
                if (before.EnumerateObject().Any(property => property.Value.ValueKind != JsonValueKind.Null &&
                    property.Value.ToString() != after.GetProperty(property.Name).ToString()))
                    throw AmbiguousProvisioning();
            }
            previousJob = job;
            previousState = result.State;
        }
    }

    private static InvalidOperationException AmbiguousProvisioning() => new(
        "UpgradeCutoverManualReconciliationRequired: ProvisioningResultNotExact. No SQL replay or checkpoint repair is authorized.");

    private static void AssertUniqueProperties(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in element.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new JsonException();
                AssertUniqueProperties(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
            foreach (var item in element.EnumerateArray()) AssertUniqueProperties(item);
    }

    private static bool StepComplete(ProvisioningStepType step, Agent365ProvisioningState state)
    {
        static bool Has(string? value) => !string.IsNullOrWhiteSpace(value);
        static bool Id(string? value) => Guid.TryParse(value, out var id) && id != Guid.Empty;
        return step switch
        {
            ProvisioningStepType.ResolveBlueprint => Has(state.BlueprintObjectId) && Has(state.BlueprintClientId),
            ProvisioningStepType.EnsureBlueprintPrincipal => Has(state.BlueprintPrincipalObjectId),
            ProvisioningStepType.ConfigureGatewayFederation => Has(state.GatewayManagedIdentityPrincipalId) && Has(state.GatewayFederatedCredentialId),
            ProvisioningStepType.CreateAgentIdentity => Has(state.AgentIdentityObjectId) && Has(state.AgentIdentityClientId) && Has(state.BlueprintClientId),
            ProvisioningStepType.AssignAgent365Access => Has(state.ObservabilityAppRoleAssignmentId) && Has(state.AgentIdentityClientId),
            ProvisioningStepType.RegisterAgent => Id(state.Agent365RegistrationId) && Id(state.RegistryCreatedByObjectId) &&
                state.RegistryAuthenticationMode == "DelegatedAdministrator" &&
                (state.Agent365RegistrationAcceptedAtUtc is not null || state.Agent365RegistrationVerifiedAtUtc is not null),
            ProvisioningStepType.VerifyAgent365Connection => state.Agent365ConnectionVerifiedAtUtc is not null &&
                ProvisioningWorkflow.CurrentSteps.Where(candidate => candidate != ProvisioningStepType.VerifyAgent365Connection)
                    .All(candidate => StepComplete(candidate, state)),
            _ => false
        };
    }

    // Table locks survive the observation through the schema commit, including empty tables.
    // A maintenance applock alone cannot fence application writers. The independent prelaunch
    // ingress/queue/zero-old-writer readback is bound by the manifest, not inferred from these locks.
    private const string ObservationSql = """
        SET NOCOUNT ON;
        DECLARE @count bigint;
        SELECT @count=COUNT_BIG(*) FROM dbo.AgentRegistrations WITH (TABLOCKX,HOLDLOCK);
        SELECT @count=COUNT_BIG(*) FROM dbo.ProvisioningJobs WITH (TABLOCKX,HOLDLOCK);
        SELECT @count=COUNT_BIG(*) FROM dbo.ProvisioningJobSteps WITH (TABLOCKX,HOLDLOCK);
        SELECT @count=COUNT_BIG(*) FROM dbo.ProtectionAdminOperations WITH (TABLOCKX,HOLDLOCK);
        SELECT @count=COUNT_BIG(*) FROM dbo.ProtectionAdminOperationSteps WITH (TABLOCKX,HOLDLOCK);
        SELECT @count=COUNT_BIG(*) FROM dbo.ActivityReceipts WITH (TABLOCKX,HOLDLOCK);
        SELECT @count=COUNT_BIG(*) FROM dbo.AiInteractionRecords WITH (TABLOCKX,HOLDLOCK);
        SELECT @count=COUNT_BIG(*) FROM dbo.OutboxMessages WITH (TABLOCKX,HOLDLOCK);

        IF EXISTS (SELECT 1 FROM (
            SELECT Status AS Value FROM dbo.AgentRegistrations
            UNION ALL SELECT Status FROM dbo.ProvisioningJobs
            UNION ALL SELECT Type FROM dbo.ProvisioningJobs
            UNION ALL SELECT Status FROM dbo.ProvisioningJobSteps
            UNION ALL SELECT StepType FROM dbo.ProvisioningJobSteps
            UNION ALL SELECT Status FROM dbo.ProtectionAdminOperations
            UNION ALL SELECT Type FROM dbo.ProtectionAdminOperations
            UNION ALL SELECT RetryDisposition FROM dbo.ProtectionAdminOperations
            UNION ALL SELECT Status FROM dbo.ProtectionAdminOperationSteps
            UNION ALL SELECT StepType FROM dbo.ProtectionAdminOperationSteps
            UNION ALL SELECT RetryDisposition FROM dbo.ProtectionAdminOperationSteps
            UNION ALL SELECT ProcessingStatus FROM dbo.ActivityReceipts
            UNION ALL SELECT ProcessingStatus FROM dbo.AiInteractionRecords
            UNION ALL SELECT ObservabilityStatus FROM dbo.AiInteractionRecords
            UNION ALL SELECT Status FROM dbo.OutboxMessages
            UNION ALL SELECT MessageType FROM dbo.OutboxMessages
            ) checkpoints WHERE DATALENGTH(Value)<>DATALENGTH(RTRIM(Value)))
            SELECT N'NoncanonicalCheckpoint';
        ELSE IF EXISTS (SELECT 1 FROM dbo.AgentRegistrations
            WHERE Status COLLATE Latin1_General_100_BIN2 NOT IN (N'Draft',N'Active',N'Disabled',N'Deleted')
                OR Status IS NULL)
            SELECT N'AgentLifecycleNotTerminal';
        ELSE IF EXISTS (SELECT 1 FROM dbo.ProvisioningJobs j
            WHERE j.Status COLLATE Latin1_General_100_BIN2 <> N'Completed' OR j.Status IS NULL
                OR j.CompletedAtUtc IS NULL OR j.PercentComplete <> 100
                OR j.ErrorCode IS NOT NULL OR j.ErrorSummary IS NOT NULL
                OR j.Type COLLATE Latin1_General_100_BIN2 NOT IN (N'ProvisionAgent',N'RetryProvisioning',N'DeleteAgent')
                OR NOT EXISTS (SELECT 1 FROM dbo.AgentRegistrations a WHERE a.Id=j.AgentRegistrationId)
                OR (j.Type=N'DeleteAgent' AND (
                    NOT EXISTS (SELECT 1 FROM dbo.AgentRegistrations a WHERE a.Id=j.AgentRegistrationId
                        AND a.Status COLLATE Latin1_General_100_BIN2=N'Deleted' AND a.IsDeleted=1 AND a.DeletedAtUtc IS NOT NULL)
                    OR EXISTS (SELECT 1 FROM dbo.ProvisioningJobSteps s WHERE s.ProvisioningJobId=j.Id)))
                OR (j.Type<>N'DeleteAgent' AND (
                    j.WorkflowVersion<>3 OR
                    (SELECT COUNT_BIG(*) FROM dbo.ProvisioningJobSteps s WHERE s.ProvisioningJobId=j.Id)<>7)))
            SELECT N'ProvisioningJobNotProvenComplete';
        ELSE IF EXISTS (SELECT 1 FROM dbo.ProvisioningJobSteps s
            LEFT JOIN dbo.ProvisioningJobs j ON j.Id=s.ProvisioningJobId
            WHERE j.Id IS NULL OR s.Status COLLATE Latin1_General_100_BIN2<>N'Completed' OR s.Status IS NULL
                OR s.CompletedAtUtc IS NULL OR s.StartedAtUtc IS NULL
                OR s.ErrorCode IS NOT NULL OR s.ErrorMessage IS NOT NULL
                OR ISJSON(s.ResultData)<>1 OR s.ResultData IS NULL
                OR s.OrderIndex NOT BETWEEN 0 AND 6
                OR s.StepType COLLATE Latin1_General_100_BIN2 <>
                    CASE s.OrderIndex WHEN 0 THEN N'ResolveBlueprint' WHEN 1 THEN N'EnsureBlueprintPrincipal'
                    WHEN 2 THEN N'ConfigureGatewayFederation' WHEN 3 THEN N'CreateAgentIdentity'
                    WHEN 4 THEN N'AssignAgent365Access' WHEN 5 THEN N'RegisterAgent'
                    WHEN 6 THEN N'VerifyAgent365Connection' ELSE N'' END)
            OR EXISTS (SELECT 1 FROM dbo.ProvisioningJobSteps GROUP BY ProvisioningJobId,OrderIndex HAVING COUNT_BIG(*)<>1)
            SELECT N'ProvisioningCheckpointAmbiguous';
        ELSE IF EXISTS (SELECT 1 FROM dbo.ProtectionAdminOperations o
            WHERE o.Status COLLATE Latin1_General_100_BIN2<>N'Completed' OR o.Status IS NULL
                OR o.WorkflowVersion<>1 OR o.CompletedAtUtc IS NULL
                OR o.Type COLLATE Latin1_General_100_BIN2 NOT IN
                    (N'ConnectPurviewTenant',N'RefreshSensitiveInformationTypes',N'CreateOrUpdateKnowYourData',
                     N'CreateOrUpdateDlpProfile',N'ReconcileDlpProfile',N'ValidateDlpRuntime',
                     N'UpdateProtectionDefaults',N'CompletePurviewTenantConnection',N'TestDlpRuntime',
                     N'VerifyPurviewTenantConnection') OR o.Type IS NULL
                OR o.RetryDisposition COLLATE Latin1_General_100_BIN2<>N'NotApplicable' OR o.RetryDisposition IS NULL
                OR o.NextAttemptAtUtc IS NOT NULL OR o.LastFailureCode IS NOT NULL
                OR ((@postUpgrade=0 OR o.Type<>N'TestDlpRuntime') AND
                    (SELECT COUNT_BIG(*) FROM dbo.ProtectionAdminOperationSteps s WHERE s.ProtectionAdminOperationId=o.Id)<>8)
                OR (@postUpgrade=1 AND o.Type=N'TestDlpRuntime' AND
                    EXISTS (SELECT 1 FROM dbo.ProtectionAdminOperationSteps s WHERE s.ProtectionAdminOperationId=o.Id)))
            SELECT N'ProtectionOperationNotProvenComplete';
        ELSE IF EXISTS (SELECT 1 FROM dbo.ProtectionAdminOperationSteps s
            LEFT JOIN dbo.ProtectionAdminOperations o ON o.Id=s.ProtectionAdminOperationId
            WHERE o.Id IS NULL OR s.Status COLLATE Latin1_General_100_BIN2 NOT IN (N'Completed',N'Skipped')
                OR s.Status IS NULL OR s.CompletedAtUtc IS NULL
                OR s.RetryDisposition COLLATE Latin1_General_100_BIN2<>N'NotApplicable' OR s.RetryDisposition IS NULL
                OR s.NextAttemptAtUtc IS NOT NULL OR s.FailureCode IS NOT NULL
                OR s.OrderIndex NOT BETWEEN 0 AND 7
                OR (s.OrderIndex=7 AND s.Status COLLATE Latin1_General_100_BIN2<>N'Completed')
                OR s.StepType COLLATE Latin1_General_100_BIN2 <>
                    CASE s.OrderIndex WHEN 0 THEN N'ValidateReviewedIntent' WHEN 1 THEN N'DiscoverProviderState'
                    WHEN 2 THEN N'ApplyReviewedMutation' WHEN 3 THEN N'RecordExactReadback'
                    WHEN 4 THEN N'VerifyPropagation' WHEN 5 THEN N'AttestTokenRoles'
                    WHEN 6 THEN N'ValidateRuntimeVerdict' WHEN 7 THEN N'Complete' ELSE N'' END)
            OR EXISTS (SELECT 1 FROM dbo.ProtectionAdminOperationSteps GROUP BY ProtectionAdminOperationId,OrderIndex HAVING COUNT_BIG(*)<>1)
            SELECT N'ProtectionCheckpointAmbiguous';
        ELSE IF EXISTS (SELECT 1 FROM dbo.ActivityReceipts
            WHERE ProcessingStatus COLLATE Latin1_General_100_BIN2<>N'Processed'
                OR ProcessingStatus IS NULL OR ProcessedAtUtc IS NULL)
            SELECT N'ActivityEffectNotProvenComplete';
        ELSE IF EXISTS (SELECT 1 FROM dbo.AiInteractionRecords
            WHERE ProcessingStatus COLLATE Latin1_General_100_BIN2<>N'Processed' OR ProcessingStatus IS NULL
                OR ProcessedAtUtc IS NULL
                OR ObservabilityStatus COLLATE Latin1_General_100_BIN2 NOT IN (N'Completed',N'Disabled')
                OR ObservabilityStatus IS NULL)
            SELECT N'InteractionEffectNotProvenComplete';
        ELSE IF EXISTS (SELECT 1 FROM dbo.OutboxMessages
            WHERE Status COLLATE Latin1_General_100_BIN2<>N'Published' OR Status IS NULL
                OR PublishedAtUtc IS NULL OR NextRetryAtUtc IS NOT NULL
                OR MessageType COLLATE Latin1_General_100_BIN2 NOT IN
                    (N'ProvisionAgent',N'RetryProvisioning',N'DeleteAgent',N'ExportInteraction',N'ProcessActivity',N'ProtectionAdminOperationMessage')
                OR MessageType IS NULL OR ISJSON(Payload)<>1 OR Payload IS NULL)
            SELECT N'OutboxEffectNotProvenPublished';
        ELSE IF EXISTS (SELECT 1 FROM dbo.OutboxMessages
            WHERE Destination COLLATE Latin1_General_100_BIN2 <>
                CASE WHEN MessageType=N'ProtectionAdminOperationMessage' THEN N'gateway-protection-admin-v1'
                    ELSE N'gateway-provisioning-v3' END
                OR Destination IS NULL OR DATALENGTH(Destination)<>DATALENGTH(RTRIM(Destination)))
            SELECT N'OutboxDestinationNotExact';
        ELSE IF EXISTS (SELECT 1 FROM dbo.OutboxMessages m
            WHERE (m.MessageType IN (N'ProvisionAgent',N'RetryProvisioning',N'DeleteAgent') AND
                NOT EXISTS (SELECT 1 FROM dbo.ProvisioningJobs j
                    WHERE j.Id=TRY_CONVERT(uniqueidentifier,JSON_VALUE(m.Payload,'$.JobId'))
                        AND j.AgentRegistrationId=TRY_CONVERT(uniqueidentifier,JSON_VALUE(m.Payload,'$.AgentRegistrationId'))))
                OR (m.MessageType=N'ProcessActivity' AND
                    NOT EXISTS (SELECT 1 FROM dbo.ActivityReceipts r
                        WHERE r.Id=TRY_CONVERT(uniqueidentifier,JSON_VALUE(m.Payload,'$.ReceiptId'))
                            AND r.AgentRegistrationId=TRY_CONVERT(uniqueidentifier,JSON_VALUE(m.Payload,'$.AgentId'))))
                OR (m.MessageType=N'ExportInteraction' AND
                    NOT EXISTS (SELECT 1 FROM dbo.AiInteractionRecords r
                        WHERE r.Id=TRY_CONVERT(uniqueidentifier,JSON_VALUE(m.Payload,'$.RecordId'))
                            AND r.AgentRegistrationId=TRY_CONVERT(uniqueidentifier,JSON_VALUE(m.Payload,'$.AgentId'))))
                OR (m.MessageType=N'ProtectionAdminOperationMessage' AND
                    NOT EXISTS (SELECT 1 FROM dbo.ProtectionAdminOperations o
                        WHERE o.Id=TRY_CONVERT(uniqueidentifier,COALESCE(JSON_VALUE(m.Payload,'$.OperationId'),JSON_VALUE(m.Payload,'$.operationId'))))))
            SELECT N'OutboxCheckpointNotCorrelated';
        ELSE IF @forRollback=1 AND EXISTS (SELECT 1 FROM dbo.ProtectionAdminOperations
            WHERE Type COLLATE Latin1_General_100_BIN2=N'VerifyPurviewTenantConnection')
            SELECT N'ProtectionOperationNotRollbackCompatible';
        ELSE SELECT N'SafeTerminal';
        """;
}
