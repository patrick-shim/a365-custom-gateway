using FluentAssertions;
using System.Text.RegularExpressions;

namespace Gateway.ArchitectureTests;

/// <summary>
/// Guards deployment properties whose accidental reversal would weaken the live
/// environment or erase state that is intentionally managed outside a revision.
/// These tests are source-contract checks; Bicep compilation remains a separate
/// validation gate.
/// </summary>
public class InfrastructureAsCodeSecurityTests
{
    private static readonly string RepositoryRoot = FindRepositoryRoot();

    [Fact]
    public void ServiceBus_Should_DisableLocalAuthentication()
    {
        var source = ReadRepositoryFile("infrastructure", "bicep", "modules", "service-bus.bicep");

        source.Should().Contain("disableLocalAuth: true");
        source.Should().NotContain("disableLocalAuth: false");
    }

    [Fact]
    public void Storage_Should_DisableSharedKeyAuthentication()
    {
        var source = ReadRepositoryFile("infrastructure", "bicep", "modules", "storage-account.bicep");

        source.Should().Contain("allowSharedKeyAccess: false");
        source.Should().NotContain("allowSharedKeyAccess: true");
    }

    [Fact]
    public void Storage_Should_UsePrivateBlobNetworkingAndDenyPublicAccess()
    {
        var storage = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "storage-account.bicep");
        var privateEndpoint = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "storage-private-endpoint.bicep");
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var deployScript = ReadRepositoryFile("operations", "deploy.ps1");

        storage.Should().Contain("publicNetworkAccess: 'Disabled'");
        storage.Should().Contain("defaultAction: 'Deny'");
        storage.Should().Contain("bypass: 'None'");

        privateEndpoint.Should().Contain("'privatelink.blob.${environment().suffixes.storage}'");
        privateEndpoint.Should().Contain("groupIds:");
        privateEndpoint.Should().Contain("'blob'");
        privateEndpoint.Should().Contain("registrationEnabled: false");
        privateEndpoint.Should().Contain("privateDnsZoneId: privateDnsZone.id");

        main.Should().Contain("resource virtualNetwork 'Microsoft.Network/virtualNetworks@");
        main.Should().Contain("resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@");
        main.Should().Contain("module storagePrivateEndpoint './modules/storage-private-endpoint.bicep'");
        main.Should().Contain("subnetId: privateEndpointSubnet.id");
        main.Should().Contain("virtualNetworkId: virtualNetwork.id");
        main.Should().Contain("storagePrivateEndpoint");
        deployScript.Should().Contain("'Microsoft.Network'");
    }

    [Fact]
    public void ApiDeployment_Should_PreserveExistingSecretsByDefault()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var apiModule = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-api.bicep");
        var deployScript = ReadRepositoryFile("operations", "deploy.ps1");

        main.Should().Contain("param preserveExistingApiSecrets bool = true");
        main.Should().Contain("existingApiContainerApp.listSecrets().value");
        main.Should().Contain(
            "preservedConfigurationSecrets: preservedApiConfigurationSecrets");

        apiModule.Should().MatchRegex(
            @"@secure\(\)\s+@description\([^\r\n]+\)\s+param preservedConfigurationSecrets object");
        apiModule.Should().Contain(
            "secrets: preservedConfigurationSecrets.?value ?? []");

        deployScript.Should().Contain("[switch]$ApiContainerAppIsNew");
        deployScript.Should().Contain("preserveExistingApiSecrets=$((-not $ApiContainerAppIsNew.IsPresent)");
    }

    [Fact]
    public void ApiDeployment_Should_KeepAtLeastOneReplica()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var development = ReadRepositoryFile(
            "infrastructure", "bicep", "parameters", "dev.bicepparam");

        main.Should().MatchRegex(@"@minValue\(1\)\s+param apiMinReplicas int = 1");
        development.Should().Contain("param apiMinReplicas = 1");
    }

    [Fact]
    public void ProvisioningFailureAlert_Should_TargetHistoricalAndNewWorkers()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var alerts = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "monitoring-alerts.bicep");
        var deployScript = ReadRepositoryFile("operations", "deploy.ps1");

        main.Should().Contain(
            "historicalWorkerContainerAppName: historicalWorkerContainerAppName");
        main.Should().Contain("targetWorkerContainerAppName: names.workerApp");
        main.Should().Contain("output provisioningAlertWorkerContainerAppNames array");

        alerts.Should().Contain("cloud_RoleName == \"${historicalWorkerContainerAppName}\"");
        alerts.Should().Contain("cloud_RoleName == \"${targetWorkerContainerAppName}\"");

        deployScript.Should().Contain("[string]$HistoricalWorkerContainerAppName");
        deployScript.Should().Contain(
            "historicalWorkerContainerAppName=$HistoricalWorkerContainerAppName");
    }

    [Fact]
    public void Agent365Observability_Should_Not_ConfigureSharedWorkerExporterIdentity()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var worker = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-worker.bicep");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        main.Should().NotContain("agent365ObservabilityExporterClientId");
        worker.Should().NotContain("Agent365__ObservabilityExporterClientId");
        preflight.Should().Contain(
            "Workflow v3 assigns it to each provisioned Agent Identity");
    }

    [Fact]
    public void AgentIdentityWorkflowV2Migration_Should_BeAdditiveAndPreserveLegacyJobs()
    {
        var migration = ReadRepositoryFile(
            "infrastructure", "sql", "20260824_agent_identity_workflow_v2.sql");

        migration.Should().Contain("COL_LENGTH");
        migration.Should().Contain("[BlueprintSelectionMode]");
        migration.Should().Contain("[AgentIdentityObjectId]");
        migration.Should().Contain("[BlueprintObjectId]");
        migration.Should().Contain("[RequestedBlueprintObjectId]");
        migration.Should().Contain("[RequestedBlueprintDisplayName]");
        migration.Should().NotContain("[RuntimeManagedIdentityPrincipalId]");
        migration.Should().Contain("[WorkflowVersion]");
        migration.Should().Contain("DEFAULT 1 WITH VALUES");
        migration.Should().NotContainEquivalentOf("DROP ");
        migration.Should().NotContainEquivalentOf("DELETE ");
    }

    [Fact]
    public void AgentIngressCredentialMigration_Should_StoreOnlyHashMaterial()
    {
        var migration = ReadRepositoryFile(
            "infrastructure", "sql", "20260825_agent_ingress_credentials.sql");

        migration.Should().Contain("[AgentIngressCredentials]");
        migration.Should().Contain("[SecretSalt] varbinary(64) NOT NULL");
        migration.Should().Contain("[SecretHash] varbinary(64) NOT NULL");
        migration.Should().Contain("[ExpiresAtUtc] datetime2 NOT NULL");
        migration.Should().Contain("ON DELETE CASCADE");
        migration.Should().NotContain("[ApiKey]");
        migration.Should().NotContain("[Secret] nvarchar");
    }

    [Fact]
    public void ScopedIdempotencyMigration_ShouldRetainLegacyRowsAndFilterThemFromUniqueness()
    {
        var prepareMigration = ReadRepositoryFile(
            "infrastructure", "sql", "20260825_scoped_idempotency.sql");
        var finalizeMigration = ReadRepositoryFile(
            "infrastructure", "sql", "20260825_scoped_idempotency_finalize.sql");

        prepareMigration.Should().Contain("[AgentRegistrationId] uniqueidentifier NULL");
        prepareMigration.Should().Contain(
            "([AgentRegistrationId], [Endpoint], [IdempotencyKey])");
        prepareMigration.Should().Contain("WHERE [AgentRegistrationId] IS NOT NULL");
        prepareMigration.Should().Contain("FOREIGN KEY ([AgentRegistrationId])");
        prepareMigration.Should().NotMatchRegex(@"(?im)^\s*DELETE\s+FROM\s+");
        prepareMigration.Should().NotContain("sole key column is IdempotencyKey");
        prepareMigration.Should().NotContain("@DropLegacyIndexSql");

        finalizeMigration.Should().Contain("FINALIZE ONLY");
        finalizeMigration.Should().Contain("zero traffic");
        finalizeMigration.Should().Contain("DROP INDEX");
        finalizeMigration.Should().Contain("sole key column is IdempotencyKey");
        finalizeMigration.Should().NotMatchRegex(@"(?im)^\s*DELETE\s+FROM\s+");
    }

    [Fact]
    public void IngressRateLimitMigration_ShouldProvideOneAtomicBucketPerScope()
    {
        var migration = ReadRepositoryFile(
            "infrastructure", "sql", "20260825_ingress_rate_limit_buckets.sql");
        var limiter = ReadRepositoryFile(
            "src", "Gateway.Infrastructure", "Services", "SqlIngressRateLimiter.cs");
        var program = ReadRepositoryFile("src", "Gateway.Api", "Program.cs");

        migration.Should().Contain("[IngressRateLimitBuckets]");
        migration.Should().Contain("PRIMARY KEY CLUSTERED ([ScopeType], [ScopeId])");
        migration.Should().Contain("CHECK ([ScopeType] IN (0, 1, 2))");
        limiter.Should().Contain("IsolationLevel.Serializable");
        limiter.Should().Contain("WITH (UPDLOCK, HOLDLOCK)");
        limiter.Should().Contain("SYSUTCDATETIME()");
        program.Should().Contain("UseMiddleware<IngressRateLimitMiddleware>()");
    }

    [Fact]
    public void ProvisioningWorker_ShouldOwnEachJobAcrossReplicas()
    {
        var provider = ReadRepositoryFile(
            "src", "Gateway.Infrastructure", "Services", "ProvisioningExecutionLockProvider.cs");
        var handler = ReadRepositoryFile(
            "src", "Gateway.Provisioning.Worker", "ProvisioningMessageHandler.cs");

        provider.Should().Contain("sys.sp_getapplock");
        provider.Should().Contain("@LockMode = 'Exclusive'");
        provider.Should().Contain("@LockOwner = 'Session'");
        provider.Should().Contain("a365gw:provisioning:job:");
        handler.Should().Contain("_provisioningExecutionLockProvider.AcquireAsync(message.JobId, ct)");
    }

    [Fact]
    public void ProvisioningWorker_Should_PinItsManagedIdentityBeforeActivation()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var worker = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-worker.bicep");
        var deployScript = ReadRepositoryFile("operations", "deploy.ps1");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        main.Should().Contain("agent365ProvisioningManagedIdentityPrincipalId");
        main.Should().Contain("!empty(agent365ProvisioningManagedIdentityPrincipalId)");
        worker.Should().Contain(
            "Agent365__ProvisioningManagedIdentityPrincipalId");
        deployScript.Should().Contain(
            "Resolve-ProvisioningManagedIdentityPrincipalId");
        preflight.Should().Contain(
            "The deployed worker managed-identity principal ID is pinned.");
    }

    [Fact]
    public void DevelopmentProvisioning_ShouldSupportContinuousDevWhileRemainingClosedByDefaultElsewhere()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var devParameters = ReadRepositoryFile(
            "infrastructure", "bicep", "parameters", "dev.bicepparam");

        main.Should().Contain("param workerProcessingEnabled bool = false");
        main.Should().Contain("param provisioningExecutionEnabled bool = false");
        main.Should().Contain("param agent365DelegatedRegistryEnabled bool = false");
        main.Should().Contain("param continuousDevelopmentProvisioningEnabled bool = false");
        devParameters.Should().Contain("param workerProcessingEnabled = true");
        devParameters.Should().Contain("param provisioningExecutionEnabled = true");
        devParameters.Should().Contain("param agent365DelegatedRegistryEnabled = true");
        devParameters.Should().Contain("param continuousDevelopmentProvisioningEnabled = true");
        main.Should().Contain(
            "var effectiveContinuousDevelopmentProvisioningEnabled = effectiveWorkerProvisioningExecutionEnabled && continuousDevelopmentProvisioningEnabled");
        main.Should().Contain(
            "var effectiveApiProvisioningAdmissionEnabled = effectiveWorkerProvisioningExecutionEnabled && (effectiveContinuousDevelopmentProvisioningEnabled ||");
        main.Should().Contain(
            "var effectiveApiDelegatedRegistryActionEnabled = effectiveWorkerProvisioningExecutionEnabled");
        main.Should().Contain(
            "var effectiveApiBoundedActionEnabled = effectiveApiProvisioningAdmissionEnabled || effectiveApiDelegatedRegistryActionEnabled");
        main.Should().Contain(
            "var effectiveApiMinReplicas = effectiveApiBoundedActionEnabled ? 1 : apiMinReplicas");
        main.Should().Contain(
            "var effectiveApiMaxReplicas = effectiveApiBoundedActionEnabled ? 1 : apiMaxReplicas");
        main.Should().Contain("minReplicas: effectiveApiMinReplicas");
        main.Should().Contain("maxReplicas: effectiveApiMaxReplicas");
        main.Should().Contain("output apiMinReplicas int = effectiveApiMinReplicas");
        main.Should().Contain("output apiMaxReplicas int = effectiveApiMaxReplicas");
    }

    [Fact]
    public void DevelopmentCanaryController_ShouldBeWorkerFirstBoundedAndFailClosed()
    {
        var script = ReadRepositoryFile(
            "operations", "invoke-development-canary.ps1");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        script.Should().Contain("'Status', 'Arm', 'OpenAdmission', 'OpenDelegatedCompletion', 'Deactivate'");
        script.Should().Contain("$ApiContainerAppName = 'ca-gateway-api-dev'");
        script.Should().Contain("$WorkerContainerAppName = 'ca-gateway-worker-dev-vnet'");
        script.Should().Contain("$HistoricalWorkerContainerAppName = 'ca-gateway-worker-dev'");
        script.Should().Contain("$WorkflowV3QueueName = 'gateway-provisioning-v3'");
        script.Should().Contain("$WorkflowV2QueueName = 'gateway-provisioning-v2'");
        script.Should().Contain("$HistoricalQueueName = 'gateway-provisioning'");
        script.Should().Contain("$ExpectedHistoricalDeadLetterCount = 2L");
        script.Should().Contain("[ValidateRange(30, 300)]");
        script.Should().Contain("LivePrepareEvidencePath");
        script.Should().Contain("LiveStateEvidencePath");
        script.Should().Contain("LiveFinalizeEvidencePath");
        script.Should().Contain("RecoveryBaselineEvidencePath");
        script.Should().Contain("ReviewedCanaryFailureEvidencePaths");
        script.Should().Contain("[Alias('ReviewedCanaryFailureEvidencePath')]");
        script.Should().Contain("[long]$ExpectedWorkflowV2DeadLetterCount = 0");
        script.Should().Contain("[long]$ExpectedWorkflowV3DeadLetterCount = 0");
        script.Should().Contain("function Assert-ReviewedCanaryFailureEvidence");
        script.Should().Contain("function Assert-QueueBaseline");
        script.Should().Contain("function Assert-RetainedWorkflowV2QueueBaseline");
        script.Should().Contain("$ExpectedWorkflowV2DeadLetterCount -eq 0");
        script.Should().Contain("terminalMessageState");
        script.Should().Contain("microsoftResourcesCreated");
        script.Should().Contain("oneTimeGatewayApiKeyIncluded");
        script.Should().Contain("a365gw_v1_[0-9a-fA-F]{32}");
        script.Should().Contain("workerLogMutationMethodsBeforeFailure");
        script.Should().Contain("Exactly one reviewed canary failure evidence file is required for every retained workflow-v2 DLQ message");
        script.Should().Contain("BlueprintFederatedIdentityCredential");
        script.Should().Contain("RetainAndReuseVerifiedFederation");
        script.Should().Contain("exactly one FIC POST and no later Microsoft mutation");
        script.Should().Contain("$retainedRegistryAmbiguityExceptionCount");
        script.Should().Contain("$knownRegistryAmbiguityRegistrationId");
        script.Should().Contain("$knownRegistryAmbiguityOperationId");
        script.Should().Contain("$knownRegistryAmbiguityMessageId");
        script.Should().Contain("$knownRegistryAmbiguityBlueprintId");
        script.Should().Contain("$knownRegistryAmbiguityChildId");
        script.Should().Contain("agentRegistrationPostHttpStatus");
        script.Should().Contain("agentRegistrationKnownIdGetCount");
        script.Should().Contain("registrationReplayAllowed");
        script.Should().Contain("newRegistrationAllowedBeforeReconciliation");
        script.Should().Contain("Do not issue another Registry create call for this registration.");
        script.Should().Contain("workflowV2QueueAfterFailClosed.queueName");
        script.Should().Contain(
            "no message is received, peeked, settled, replayed, or purged");
        script.Should().Contain("zero active and scheduled messages before activation or admission");
        script.Should().Contain("dead-letter count changed during the admission window");
        script.Should().Contain(
            "Read-Evidence -Path $LivePrepareEvidencePath -Label 'Live prepare'");
        script.Should().Contain(
            "Read-Evidence -Path $LiveStateEvidencePath -Label 'Live state'");
        script.Should().Contain(
            "Read-Evidence -Path $RecoveryBaselineEvidencePath -Label 'Recovery baseline'");
        script.Should().NotContain(
            "Read-Evidence -Path $LiveFinalizeEvidencePath");
        script.Should().Contain("$commands = @(");
        script.Should().Contain("$arguments = @(");
        script.Should().Contain("$rules = @(");
        script.Should().Contain("[switch]$RequireExpectedMatch");
        script.Should().Contain("-RequireExpectedMatch:$armed");
        script.Should().Contain(
            "-ContainerApp $Resources.Worker `");
        script.Should().Contain(
            "independently verified manager application ID is required for activation");
        script.Should().Contain("empty or secret-backed manager application ID");
        script.Should().Contain("duplicate manager application IDs");
        script.Should().Contain("function Test-RevisionReadyRunningState");
        script.Should().Contain("'RunningAtMaxScale'");
        script.Should().Contain("'ScaleToZero'");
        script.Should().Contain("ExpectedMinimumReplicas -ne 0");
        script.Should().Contain("'ActivationFailed'");
        script.Should().Contain("'Degraded'");
        script.Should().Contain("'Failed'");
        script.Should().Contain("'Unknown'");
        script.Should().Contain("'Unhealthy'");
        script.Should().Contain("-ExpectedMinimumReplicas ([int]$minimumReplicas)");
        script.Should().Contain("-ExpectedMinimumReplicas 1");
        script.Should().Contain("$activeRevisionCount -eq 1");
        script.Should().Contain("during single-revision convergence");
        script.Should().Contain("Last observation: $lastObservation");
        script.Should().NotContain(
            "does not have exactly one active revision");
        script.Should().Contain(
            "$null -ne $commandProperty -and $null -ne $commandProperty.Value");
        script.Should().Contain(
            "$null -ne $argumentsProperty -and $null -ne $argumentsProperty.Value");
        script.Should().Contain(
            "$null -ne $rulesProperty -and $null -ne $rulesProperty.Value");
        script.Should().NotContain("$commands = if (");
        script.Should().NotContain("$arguments = if (");
        script.Should().NotContain("$rules = if (");
        script.Should().Contain("PendingProvisioningOutboxVerifiedEmpty");
        script.Should().Contain("ContainedSqlAccessVerified");
        script.Should().Contain("DATABASE_MIGRATOR_");
        script.Should().Contain("is not a clean runtime template");
        script.Should().Contain("exactly one queue-scoped API Sender and one queue-scoped current-worker Receiver");
        script.Should().Contain("no inherited, Data Owner, reversed, or third-party data-plane assignment");
        script.Should().Contain("Invoke-FailClosedRecovery");
        script.Should().Contain("$Action -ne 'Status'");
        script.Should().Contain("finally {");
        script.Should().NotContain("servicebus queue receive");
        script.Should().NotContain("servicebus queue purge");
        script.Should().NotContain(".secrets");
        script.Should().Contain(
            "The live finalize phase must remain unapplied until the bounded canary");
        script.Should().Contain(
            "LegacyGlobalIdempotencyUniqueIndexCount -ne 1");

        var queueRoleCheckStart = script.IndexOf(
            "function Assert-ExactQueueDataRoles", StringComparison.Ordinal);
        var evidenceCheckStart = script.IndexOf(
            "function Read-Evidence", StringComparison.Ordinal);
        queueRoleCheckStart.Should().BeGreaterThan(-1);
        evidenceCheckStart.Should().BeGreaterThan(queueRoleCheckStart);
        var queueRoleCheck = script[queueRoleCheckStart..evidenceCheckStart];
        queueRoleCheck.Should().Contain("'--scope', [string]$Queue.id");
        queueRoleCheck.Should().Contain("'--include-inherited'");
        queueRoleCheck.Should().NotContain("'--all'");
        queueRoleCheck.Should().Contain("$ServiceBusDataOwnerRoleId");
        queueRoleCheck.Should().Contain("$effectiveDataPlaneAssignments.Count -ne 2");

        var armBlockStart = script.IndexOf("'Arm' {", StringComparison.Ordinal);
        var openBlockStart = script.IndexOf("'OpenAdmission' {", StringComparison.Ordinal);
        armBlockStart.Should().BeGreaterThan(-1);
        openBlockStart.Should().BeGreaterThan(armBlockStart);
        var armBlock = script[armBlockStart..openBlockStart];
        armBlock.IndexOf("Set-WorkerMode", StringComparison.Ordinal)
            .Should().BeLessThan(armBlock.IndexOf("Set-ApiAdmission", StringComparison.Ordinal));
        armBlock.Should().Contain("-Enabled $false");

        var recoveryStart = script.IndexOf(
            "function Invoke-FailClosedRecovery", StringComparison.Ordinal);
        var statusStart = script.IndexOf("function Show-Status", StringComparison.Ordinal);
        var recoveryBlock = script[recoveryStart..statusStart];
        recoveryBlock.IndexOf("Set-ApiAdmission", StringComparison.Ordinal)
            .Should().BeLessThan(recoveryBlock.IndexOf("Set-WorkerMode", StringComparison.Ordinal));

        preflight.Should().Contain("[switch]$ExpectApiAdmissionClosed");
        preflight.Should().Contain("[switch]$ExpectDelegatedRegistryActionOpen");
        preflight.Should().Contain(
            "The worker-first staging state keeps API registration admission closed.");
    }

    [Fact]
    public void DevelopmentCanaryController_ShouldSeparatePrepareProvenanceFromFreshLiveState()
    {
        var script = ReadRepositoryFile(
            "operations", "invoke-development-canary.ps1");
        var timestampValidation = ReadPowerShellFunction(
            script,
            "Assert-EvidenceTimestampValid",
            "Assert-ScriptEvidence");
        var databaseEvidence = ReadPowerShellFunction(
            script,
            "Assert-DatabaseEvidence",
            "Assert-OperationalConfirmations");

        databaseEvidence.Should().Contain(
            "Read-Evidence -Path $LivePrepareEvidencePath -Label 'Live prepare'");
        databaseEvidence.Should().Contain(
            "Read-Evidence -Path $LiveStateEvidencePath -Label 'Live state'");
        databaseEvidence.Should().Contain(
            "Assert-EvidenceTimestampValid -Evidence $prepare -Label 'Live prepare'");
        databaseEvidence.Should().NotContain(
            "Assert-EvidenceFresh -Evidence $prepare");
        databaseEvidence.Should().Contain(
            "Assert-EvidenceFresh -Evidence $liveState -Label 'Live state'");
        databaseEvidence.Should().Contain(
            "Assert-EvidenceFresh -Evidence $recovery -Label 'Recovery baseline'");

        timestampValidation.Should().Contain(
            "$verifiedAt.ToUniversalTime() -gt [datetimeoffset]::UtcNow.AddMinutes(5)");
        timestampValidation.Should().Contain("evidence is future-dated");
        timestampValidation.Should().NotContain("MaximumDatabaseEvidenceAgeMinutes");
        timestampValidation.Should().NotContain("FromMinutes($MaximumDatabaseEvidenceAgeMinutes)");

        databaseEvidence.Should().Contain(
            "Assert-ScriptEvidence -Evidence $prepare -ExpectedScripts @(");
        databaseEvidence.Should().Contain(
            "'20260824_agent_identity_workflow_v2.sql'");
        databaseEvidence.Should().Contain(
            "'20260825_agent_ingress_credentials.sql'");
        databaseEvidence.Should().Contain(
            "'20260825_scoped_idempotency.sql'");
        databaseEvidence.Should().Contain(
            "'20260825_ingress_rate_limit_buckets.sql'");
        databaseEvidence.Should().Contain(
            "Assert-ScriptEvidence -Evidence $liveState -ExpectedScripts @() -Label 'Live state'");
    }

    [Fact]
    public void DevelopmentCanaryController_ShouldRequireExactReadOnlyLiveAndRecoveryEvidence()
    {
        var script = ReadRepositoryFile(
            "operations", "invoke-development-canary.ps1");
        var databaseEvidence = ReadPowerShellFunction(
            script,
            "Assert-DatabaseEvidence",
            "Assert-OperationalConfirmations");
        var operationalConfirmations = ReadPowerShellFunction(
            script,
            "Assert-OperationalConfirmations",
            "Assert-NoContainerCommandOverride");

        databaseEvidence.Should().Contain("[string]$liveState.Server");
        databaseEvidence.Should().Contain("$SqlServerFqdn");
        databaseEvidence.Should().Contain("[string]$liveState.Database");
        databaseEvidence.Should().Contain("$SqlDatabaseName");
        databaseEvidence.Should().Contain("[string]$liveState.Phase -ne 'verify'");
        databaseEvidence.Should().Contain("[int]$liveState.Repeat -ne 1");
        databaseEvidence.Should().Contain(
            "$liveState.Verification.WorkflowV2Ready -ne $true");
        databaseEvidence.Should().Contain(
            "[int]$liveState.Verification.LegacyGlobalIdempotencyUniqueIndexCount -ne 1");
        databaseEvidence.Should().Contain(
            "[long]$liveState.Verification.PublishableOutboxMessageCount -ne 0");
        databaseEvidence.Should().Contain(
            "[long]$liveState.Verification.ActiveWorkflowV3JobCount -ne");
        databaseEvidence.Should().Contain(
            "$ExpectedRetainedManualWorkflowV3JobCount");
        databaseEvidence.Should().Contain(
            "[long]$liveState.Verification.AwaitingAdministratorActionWorkflowV3JobCount -ne 0");
        var migrator = ReadRepositoryFile(
            "tools", "Gateway.DatabaseMigrator", "Program.cs");
        migrator.Should().Contain("AS ActiveWorkflowV3JobCount");
        migrator.Should().Contain("AS AwaitingAdministratorActionWorkflowV3JobCount");
        migrator.Should().Contain("N'AwaitingAdministratorAction'");
        databaseEvidence.Should().Contain(
            "$liveStateVerifiedAt = ([datetimeoffset]$liveState.VerifiedAtUtc).ToUniversalTime()");
        databaseEvidence.Should().NotContain(
            "[datetimeoffset]::Parse([string]$liveState.VerifiedAtUtc)");
        databaseEvidence.Should().Contain("return $liveStateVerifiedAt");

        databaseEvidence.Should().Contain(
            "Assert-EvidenceFresh -Evidence $recovery -Label 'Recovery baseline'");
        databaseEvidence.Should().Contain("[string]$recovery.Database");
        databaseEvidence.Should().Contain("[string]$recovery.Phase -ne 'baseline'");
        databaseEvidence.Should().Contain(
            "$recovery.Verification.WorkflowV2Ready -ne $false");
        databaseEvidence.Should().Contain(
            "[int]$recovery.Verification.LegacyGlobalIdempotencyUniqueIndexCount -ne 1");

        operationalConfirmations.Should().Contain(
            "$ProvisioningOutboxVerifiedAtUtc.ToUniversalTime() -ne");
        operationalConfirmations.Should().Contain(
            "$ExpectedOutboxVerifiedAtUtc.ToUniversalTime()");
        operationalConfirmations.Should().Contain("MaximumOutboxEvidenceAgeMinutes");

        databaseEvidence.Should().Contain(
            "-not [string]::IsNullOrWhiteSpace($LiveFinalizeEvidencePath)");
        databaseEvidence.Should().Contain(
            "The live finalize phase must remain unapplied until the bounded canary");
        databaseEvidence.Should().NotContain(
            "Read-Evidence -Path $LiveFinalizeEvidencePath");
    }

    [Fact]
    public void DevelopmentCanaryController_ShouldEnforceDurableApiAdmissionExpiry()
    {
        var script = ReadRepositoryFile(
            "operations", "invoke-development-canary.ps1");

        script.Should().Contain(
            "$AdmissionExpirySettingName = 'Provisioning__AdmissionExpiresAtUtc'");
        script.Should().MatchRegex(
            @"\[ValidateRange\(30, 300\)\]\s*\r?\n\s*\[int\]\$AdmissionDurationSeconds = 120,");
        script.Should().MatchRegex(
            @"\[ValidateRange\(60, 300\)\]\s*\r?\n\s*\[int\]\$RevisionDeploymentAllowanceSeconds = 300,");
        script.Should().Contain("$MaximumAdmissionExposureSeconds = 600");

        var assertApiState = ReadPowerShellFunction(
            script, "Assert-ApiState", "Assert-WorkerState");
        assertApiState.Should().Contain(
            "[Nullable[datetimeoffset]]$ExpectedAdmissionExpiresAtUtc");
        assertApiState.Should().Contain(
            "-Name $AdmissionExpirySettingName `");
        assertApiState.Should().Contain("-AllowMissing");
        assertApiState.Should().Contain("if ($AdmissionEnabled) {");
        assertApiState.Should().Contain(
            "$admissionExpiryValue.EndsWith('Z', [System.StringComparison]::Ordinal)");
        assertApiState.Should().Contain(
            "$parsedExpiry.ToUniversalTime() -le [datetimeoffset]::UtcNow");
        assertApiState.Should().Contain(
            "$ExpectedAdmissionExpiresAtUtc.ToUniversalTime()).TotalSeconds) -gt 1");
        assertApiState.Should().Contain(
            "Closed API admission must not retain an expiry, external-agent binding, or retry binding.");

        var setApiAdmission = ReadPowerShellFunction(
            script, "Set-ApiAdmission", "Invoke-ExecutionPreflight");
        setApiAdmission.Should().Contain(
            "[Nullable[datetimeoffset]]$AdmissionExpiresAtUtc");
        setApiAdmission.Should().Contain("if ($Enabled) {");
        setApiAdmission.Should().Contain("$null -eq $AdmissionExpiresAtUtc");
        setApiAdmission.Should().Contain(
            "$AdmissionExpiresAtUtc.ToUniversalTime() -le [datetimeoffset]::UtcNow");
        setApiAdmission.Should().Contain(
            "Closed API admission must not carry an expiry or registration/retry binding.");
        setApiAdmission.Should().Contain(
            "$settingsToRemove += $dynamicSettingName");
        setApiAdmission.Should().Contain(
            "'yyyy-MM-ddTHH:mm:ss.fffffffZ'");
        setApiAdmission.Should().Contain(
            "$arguments += \"$AdmissionExpirySettingName=$expiryValue\"");

        var openAdmissionStart = script.IndexOf(
            "'OpenAdmission' {", StringComparison.Ordinal);
        var deactivateStart = script.IndexOf(
            "'Deactivate' {", StringComparison.Ordinal);
        openAdmissionStart.Should().BeGreaterThan(-1);
        deactivateStart.Should().BeGreaterThan(openAdmissionStart);
        var openAdmission = script[openAdmissionStart..deactivateStart];
        openAdmission.Should().Contain(
            "$maximumExposureSeconds = [math]::Min(");
        openAdmission.Should().Contain("$MaximumAdmissionExposureSeconds,");
        openAdmission.Should().Contain(
            "$RevisionDeploymentAllowanceSeconds + $AdmissionDurationSeconds)");
        openAdmission.Should().Contain(
            "$admissionExpiresAtUtc = [datetimeoffset]::UtcNow.AddSeconds(");
        openAdmission.Should().Contain("$maximumExposureSeconds)");
        Regex.Matches(
                openAdmission,
                @"-AdmissionExpiresAtUtc \$admissionExpiresAtUtc",
                RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        Regex.Matches(
                openAdmission,
                @"-ExpectedAdmissionExpiresAtUtc \$admissionExpiresAtUtc",
                RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        openAdmission.Should().Contain(
            "$operatorDeadline = [datetimeoffset]::UtcNow.AddSeconds(");
        openAdmission.Should().Contain("$AdmissionDurationSeconds)");
        openAdmission.Should().Contain(
            "$deadline = if ($operatorDeadline -lt $admissionExpiresAtUtc)");
        openAdmission.Should().MatchRegex(
            @"\$deadline = if \(\$operatorDeadline -lt \$admissionExpiresAtUtc\) \{\s*\$operatorDeadline\s*\}\s*else \{\s*\$admissionExpiresAtUtc\s*\}");
        openAdmission.Should().Contain(
            "if ($deadline -le [datetimeoffset]::UtcNow)");
        openAdmission.Should().Contain(
            "The API-enforced admission deadline was consumed before the operator window could begin.");
        openAdmission.Should().Contain(
            "while ([datetimeoffset]::UtcNow -lt $deadline)");

        var hardDeadlineStart = openAdmission.IndexOf(
            "$maximumExposureSeconds = [math]::Min(", StringComparison.Ordinal);
        var tryStart = openAdmission.IndexOf(
            "try {", hardDeadlineStart, StringComparison.Ordinal);
        var updateStart = openAdmission.IndexOf(
            "$openedApi = Set-ApiAdmission", StringComparison.Ordinal);
        var readinessStart = openAdmission.IndexOf(
            "Wait-ApiHealth -Api $openedApi", updateStart, StringComparison.Ordinal);
        var operatorDeadlineStart = openAdmission.IndexOf(
            "$operatorDeadline = [datetimeoffset]::UtcNow.AddSeconds(",
            readinessStart,
            StringComparison.Ordinal);
        var clippedDeadlineStart = openAdmission.IndexOf(
            "$deadline = if ($operatorDeadline -lt $admissionExpiresAtUtc)",
            operatorDeadlineStart,
            StringComparison.Ordinal);
        var consumedDeadlineStop = openAdmission.IndexOf(
            "if ($deadline -le [datetimeoffset]::UtcNow)",
            clippedDeadlineStart,
            StringComparison.Ordinal);
        var boundedLoopStart = openAdmission.IndexOf(
            "while ([datetimeoffset]::UtcNow -lt $deadline)",
            consumedDeadlineStop,
            StringComparison.Ordinal);
        var finallyStart = openAdmission.IndexOf("finally {", StringComparison.Ordinal);
        hardDeadlineStart.Should().BeGreaterThan(-1);
        tryStart.Should().BeGreaterThan(hardDeadlineStart);
        updateStart.Should().BeGreaterThan(tryStart);
        readinessStart.Should().BeGreaterThan(updateStart);
        operatorDeadlineStart.Should().BeGreaterThan(readinessStart);
        clippedDeadlineStart.Should().BeGreaterThan(operatorDeadlineStart);
        consumedDeadlineStop.Should().BeGreaterThan(clippedDeadlineStart);
        boundedLoopStart.Should().BeGreaterThan(consumedDeadlineStop);
        finallyStart.Should().BeGreaterThan(boundedLoopStart);
        openAdmission[finallyStart..].Should().Contain("Set-ApiAdmission `");
        openAdmission[finallyStart..].Should().Contain("-Enabled $false `");
        openAdmission[finallyStart..].Should().Contain(
            "-AdmissionEnabled $false `");
        openAdmission[finallyStart..].Should().Contain("Wait-ApiHealth -Api $closedApi");
    }

    [Fact]
    public void DevelopmentCanaryController_ShouldPreserveAzureJsonDateStringsAcrossPowerShellVersions()
    {
        var script = ReadRepositoryFile(
            "operations", "invoke-development-canary.ps1");
        var elementConverter = ReadPowerShellFunction(
            script,
            "ConvertFrom-JsonElementPreservingStrings",
            "ConvertFrom-AzJsonPreservingStrings");
        var azureJsonConverter = ReadPowerShellFunction(
            script,
            "ConvertFrom-AzJsonPreservingStrings",
            "Invoke-AzJson");
        var invokeAzJson = ReadPowerShellFunction(
            script, "Invoke-AzJson", "Invoke-AzNoOutput");

        azureJsonConverter.Should().Contain(
            "$convertFromJson.Parameters.ContainsKey('DateKind')");
        azureJsonConverter.Should().Contain(
            "ConvertFrom-Json -Depth 100 -DateKind String");
        azureJsonConverter.Should().Contain(
            "[System.Text.Json.JsonDocument]::Parse($RawJson, $options)");
        azureJsonConverter.Should().Contain("$document.Dispose()");
        elementConverter.Should().Contain(
            "[System.Text.Json.JsonValueKind]::String");
        elementConverter.Should().Contain("return $Element.GetString()");

        invokeAzJson.Should().Contain(
            "ConvertFrom-AzJsonPreservingStrings -RawJson $json");
        invokeAzJson.Should().NotContain("ConvertFrom-Json");

        var assertApiState = ReadPowerShellFunction(
            script, "Assert-ApiState", "Assert-WorkerState");
        assertApiState.Should().Contain(
            "$admissionExpiryValue.EndsWith('Z', [System.StringComparison]::Ordinal)");
        assertApiState.Should().Contain(
            "-not [datetimeoffset]::TryParse($admissionExpiryValue, [ref]$parsedExpiry)");
        assertApiState.Should().Contain(
            "$parsedExpiry.ToUniversalTime() -le [datetimeoffset]::UtcNow");
        assertApiState.Should().Contain(
            "$ExpectedAdmissionExpiresAtUtc.ToUniversalTime()).TotalSeconds) -gt 1");
    }

    [Fact]
    public void DevelopmentCanaryController_ShouldStrictlyValidateRetainedFailureEvidence()
    {
        var script = ReadRepositoryFile(
            "operations", "invoke-development-canary.ps1");
        var booleanReader = ReadPowerShellFunction(
            script,
            "Get-RequiredEvidenceBoolean",
            "Assert-ReviewedCanaryFailureEvidence");
        var evidenceCheck = ReadPowerShellFunction(
            script,
            "Assert-ReviewedCanaryFailureEvidence",
            "Assert-EvidenceFresh");

        booleanReader.Should().Contain("$value -isnot [bool]");
        booleanReader.Should().Contain("must be a JSON Boolean");
        foreach (var booleanField in new[]
                 {
                     "microsoftResourcesCreated",
                     "gatewayCredentialRevoked",
                     "oneTimeGatewayApiKeyIncluded",
                     "apiAdmissionClosed",
                     "workerProcessingEnabled",
                     "workerProvisioningExecutionEnabled",
                     "workerDirectRegistryPreviewEnabled",
                     "historicalQueueOrDeadLetterTouched",
                     "agentIdentityCreated",
                     "agent365RegistrationCreated"
                 })
        {
            evidenceCheck.Should().Contain($"-Name '{booleanField}'");
        }

        foreach (var guidField in new[]
                 {
                     "canary.agentRegistrationId",
                     "canary.operationId",
                     "canary.serviceBusMessageId",
                     "canary.selectedBlueprintObjectId",
                     "reconciliation.blueprintObjectId",
                     "reconciliation.federatedCredentialId"
                 })
        {
            evidenceCheck.Should().Contain(guidField);
        }
        Regex.Matches(
                evidenceCheck,
                @"\[guid\]::TryParse\(",
                RegexOptions.CultureInvariant)
            .Count.Should().BeGreaterThanOrEqualTo(6);
        evidenceCheck.Should().Contain("$registrationId -eq [guid]::Empty");
        evidenceCheck.Should().Contain("$operationId -eq [guid]::Empty");
        evidenceCheck.Should().Contain("$messageId -eq [guid]::Empty");
        evidenceCheck.Should().Contain("$selectedBlueprintObjectId -eq [guid]::Empty");
        evidenceCheck.Should().Contain("-not $operationIds.Add(");
        evidenceCheck.Should().Contain("-not $messageIds.Add(");
        evidenceCheck.Should().Contain(
            "[string]$request -cnotmatch $canonicalGraphRequestPattern");
        evidenceCheck.Should().Contain(
            "[string]$_ -cnotmatch '\\AGET https://graph\\.microsoft\\.com/'");

        evidenceCheck.Should().Contain("$checkpointCaptureTimes = @{}");
        evidenceCheck.Should().Contain(
            "$checkpointCaptureTimes.ContainsKey($recordedDeadLetterCount)");
        evidenceCheck.Should().Contain(
            "$checkpointCaptureTimes[$recordedDeadLetterCount] = $capturedAt.ToUniversalTime()");
        evidenceCheck.Should().Contain(
            "for ($checkpoint = 1L; $checkpoint -le $ExpectedWorkflowV2DeadLetterCount; $checkpoint++)");
        evidenceCheck.Should().Contain(
            "-not $checkpointCaptureTimes.ContainsKey($checkpoint)");
        evidenceCheck.Should().Contain("$captureTime -le $previousCaptureTime");

        evidenceCheck.Should().Contain("$reconciledFederationExceptionCount++");
        evidenceCheck.Should().Contain("$reconciledFederationExceptionCount -gt 1");
        evidenceCheck.Should().Contain("$retainedRegistryAmbiguityExceptionCount++");
        evidenceCheck.Should().Contain("$retainedRegistryAmbiguityExceptionCount -gt 1");
        evidenceCheck.Should().Contain("$registrationId -ne $knownRegistryAmbiguityRegistrationId");
        evidenceCheck.Should().Contain("$operationId -ne $knownRegistryAmbiguityOperationId");
        evidenceCheck.Should().Contain("$messageId -ne $knownRegistryAmbiguityMessageId");
        evidenceCheck.Should().Contain("$selectedBlueprintObjectId -ne $knownRegistryAmbiguityBlueprintId");
        evidenceCheck.Should().Contain("$createdAgentIdentityObjectId -ne $knownRegistryAmbiguityChildId");
        evidenceCheck.Should().Contain("$createdAgentIdentityClientId -ne $knownRegistryAmbiguityChildId");
        evidenceCheck.Should().Contain("$rawEvidence.Replace(\"`r`n\", \"`n\")");
        evidenceCheck.Should().Contain("[System.Security.Cryptography.SHA256]::HashData");
        evidenceCheck.Should().Contain("$knownRegistryAmbiguityEvidenceSha256");
        evidenceCheck.Should().Contain("$knownRegistryAmbiguityDeadLetterCheckpoint");
        evidenceCheck.Should().Contain("agentRegistrationPostCount");
        evidenceCheck.Should().Contain("agentRegistrationPostHttpStatus");
        evidenceCheck.Should().Contain("agentRegistrationKnownIdGetCount");
        evidenceCheck.Should().Contain("registrationReplayAllowed");
        evidenceCheck.Should().Contain("newRegistrationAllowedBeforeReconciliation");
        evidenceCheck.Should().Contain("$ExpectedWorkflowV2DeadLetterCount -ge 3");
        evidenceCheck.Should().Contain("$retainedRegistryAmbiguityExceptionCount -ne 1");
        evidenceCheck.Should().Contain("$mutations.Count -ne 1");
        evidenceCheck.Should().Contain(
            "POST https://graph.microsoft.com/v1.0/applications/$($selectedBlueprintObjectId.ToString('D'))/federatedIdentityCredentials");
        evidenceCheck.Should().Contain(
            "$mutationObservedAt.ToUniversalTime() -gt $verifiedAt.ToUniversalTime()");
        evidenceCheck.Should().Contain(
            "$verifiedAt.ToUniversalTime() -gt $capturedAt.ToUniversalTime()");
        evidenceCheck.Should().Contain(
            "$reconciledBlueprintObjectId -ne $selectedBlueprintObjectId");
        evidenceCheck.Should().Contain(
            "GET https://graph.microsoft.com/v1.0/applications/$($selectedBlueprintObjectId.ToString('D'))/federatedIdentityCredentials/$($ficId.ToString('D'))");
        evidenceCheck.Should().Contain("'--method', 'GET'");
        evidenceCheck.Should().Contain(
            "'--uri', $expectedReadOnlyVerificationRequest.Substring(4)");
        evidenceCheck.Should().Contain(
            "The live selected-blueprint FIC no longer matches the reviewed reconciled resource.");
    }

    [Fact]
    public void DevelopmentCanaryController_ShouldSourcePinNormalizedRegistryAmbiguityEvidence()
    {
        var script = ReadRepositoryFile(
            "operations", "invoke-development-canary.ps1");
        var evidence = ReadRepositoryFile(
            "docs", "operations", "evidence", "canary-registry-failure-20260826.json");
        var digestAssignment = Regex.Match(
            script,
            @"(?m)^\s*\$knownRegistryAmbiguityEvidenceSha256\s*=\s*\r?\n\s*'(?<digest>[0-9a-f]{64})'\s*$",
            RegexOptions.CultureInvariant);

        digestAssignment.Success.Should().BeTrue(
            "the one retained Registry ambiguity must be pinned in source");
        var normalizedEvidence = evidence.Replace("\r\n", "\n", StringComparison.Ordinal);
        var normalizedDigest = Convert.ToHexString(
                System.Security.Cryptography.SHA256.HashData(
                    System.Text.Encoding.UTF8.GetBytes(normalizedEvidence)))
            .ToLowerInvariant();
        var crlfEquivalentDigest = Convert.ToHexString(
                System.Security.Cryptography.SHA256.HashData(
                    System.Text.Encoding.UTF8.GetBytes(
                        normalizedEvidence.Replace("\n", "\r\n", StringComparison.Ordinal)
                            .Replace("\r\n", "\n", StringComparison.Ordinal))))
            .ToLowerInvariant();

        normalizedDigest.Should().Be(digestAssignment.Groups["digest"].Value);
        crlfEquivalentDigest.Should().Be(normalizedDigest);
        script.Should().Contain("$recordedDeadLetterCount -ne $knownRegistryAmbiguityDeadLetterCheckpoint");
    }

    [Fact]
    public void DevelopmentCanaryController_ShouldReadEvidenceTimestampsFromRawJson()
    {
        var script = ReadRepositoryFile(
            "operations", "invoke-development-canary.ps1");
        var rawJsonStringReader = ReadPowerShellFunction(
            script, "Get-RequiredRawJsonString", "Get-RequiredEvidenceValue");
        var evidenceCheck = ReadPowerShellFunction(
            script,
            "Assert-ReviewedCanaryFailureEvidence",
            "Assert-EvidenceFresh");

        rawJsonStringReader.Should().Contain(
            "$document = [System.Text.Json.JsonDocument]::Parse($RawJson)");
        rawJsonStringReader.Should().Contain("$element = $document.RootElement");
        rawJsonStringReader.Should().Contain("foreach ($segment in $Path)");
        rawJsonStringReader.Should().Contain("$element = $element.GetProperty($segment)");
        rawJsonStringReader.Should().Contain(
            "$element.ValueKind -ne [System.Text.Json.JsonValueKind]::String");
        rawJsonStringReader.Should().Contain("$value = $element.GetString()");
        rawJsonStringReader.Should().Contain("$document.Dispose()");
        rawJsonStringReader.Should().NotContain("ConvertFrom-Json");

        evidenceCheck.Should().Contain(
            "$rawEvidence = Get-Content -Raw -LiteralPath $path");
        Regex.Matches(
                evidenceCheck,
                @"Get-RequiredRawJsonString\s+`",
                RegexOptions.CultureInvariant)
            .Count.Should().Be(3);
        evidenceCheck.Should().Contain("$capturedAtValue = Get-RequiredRawJsonString `");
        evidenceCheck.Should().Contain("-RawJson $rawEvidence `");
        evidenceCheck.Should().Contain("-Path @('capturedAtUtc') `");
        evidenceCheck.Should().Contain(
            "$mutationObservedAtValue = Get-RequiredRawJsonString `");
        evidenceCheck.Should().Contain(
            "-Path @('outcome', 'mutationObservedAtUtc') `");
        evidenceCheck.Should().Contain("$verifiedAtValue = Get-RequiredRawJsonString `");
        evidenceCheck.Should().Contain(
            "-Path @('reconciliation', 'readOnlyVerifiedAtUtc') `");

        evidenceCheck.Should().Contain(
            "$capturedAtValue.EndsWith('Z', [System.StringComparison]::Ordinal)");
        evidenceCheck.Should().Contain(
            "$mutationObservedAtValue.EndsWith('Z', [System.StringComparison]::Ordinal)");
        evidenceCheck.Should().Contain(
            "$verifiedAtValue.EndsWith('Z', [System.StringComparison]::Ordinal)");
        evidenceCheck.Should().MatchRegex(
            @"-not \[datetimeoffset\]::TryParse\(\r?\n\s*\$capturedAtValue,");
        evidenceCheck.Should().MatchRegex(
            @"-not \[datetimeoffset\]::TryParse\(\r?\n\s*\$mutationObservedAtValue,");
        evidenceCheck.Should().MatchRegex(
            @"-not \[datetimeoffset\]::TryParse\(\r?\n\s*\$verifiedAtValue,");
    }

    [Fact]
    public void DevelopmentCanaryController_GraphEvidencePattern_ShouldRejectNonCanonicalRequests()
    {
        var script = ReadRepositoryFile(
            "operations", "invoke-development-canary.ps1");
        var assignment = Regex.Match(
            script,
            @"(?m)^\s*\$canonicalGraphRequestPattern\s*=\s*\r?\n\s*'(?<pattern>[^'\r\n]+)'\s*$",
            RegexOptions.CultureInvariant);
        assignment.Success.Should().BeTrue(
            "the controller should declare one literal canonical Graph request pattern");

        var requestPattern = new Regex(
            assignment.Groups["pattern"].Value,
            RegexOptions.CultureInvariant);
        var validRequests = new[]
        {
            "GET https://graph.microsoft.com/v1.0/applications/00000000-0000-0000-0000-000000000001",
            "POST https://graph.microsoft.com/v1.0/applications/00000000-0000-0000-0000-000000000001/federatedIdentityCredentials",
            "GET https://graph.microsoft.com/beta/copilot/agentRegistrations/00000000-0000-0000-0000-000000000002?%24select=id%2CsourceAgentId"
        };
        var invalidRequests = new[]
        {
            "get https://graph.microsoft.com/v1.0/applications/00000000-0000-0000-0000-000000000001",
            "GET  https://graph.microsoft.com/v1.0/applications/00000000-0000-0000-0000-000000000001",
            "GET https://graph.microsoft.com.evil.example/v1.0/applications/00000000-0000-0000-0000-000000000001",
            "GET https://graph.microsoft.com/v2.0/applications/00000000-0000-0000-0000-000000000001",
            "GET https://graph.microsoft.com/v1.0/applications/id#fragment",
            "OPTIONS https://graph.microsoft.com/v1.0/applications/id",
            "GET https://graph.microsoft.com/v1.0/applications/id\r\nDELETE https://graph.microsoft.com/v1.0/applications/id"
        };

        validRequests.Should().OnlyContain(request => requestPattern.IsMatch(request));
        invalidRequests.Should().OnlyContain(request => !requestPattern.IsMatch(request));
    }

    [Fact]
    public void DevelopmentCanaryController_ShouldNeverConsumeOrDisposeQueueMessages()
    {
        var script = ReadRepositoryFile(
            "operations", "invoke-development-canary.ps1");
        var queueRuntime = ReadPowerShellFunction(
            script, "Get-QueueRuntime", "Assert-QueueBaseline");

        queueRuntime.Should().Contain("'servicebus', 'queue', 'show'");
        queueRuntime.Should().Contain("return Invoke-AzJson");
        queueRuntime.Should().NotContain("Invoke-AzNoOutput");

        var queueCommands = Regex.Matches(
            script,
            @"(?m)^\s*'servicebus'\s*,\s*'queue'\s*,\s*'(?<verb>[^']+)'\s*,",
            RegexOptions.CultureInvariant);
        queueCommands.Count.Should().Be(2);
        queueCommands.Cast<Match>().Should().OnlyContain(
            command => command.Groups["verb"].Value == "show");
        queueRuntime.Should().Contain("$WorkflowV3QueueName");
        queueRuntime.Should().Contain("$WorkflowV2QueueName");
        script.Should().NotMatchRegex(
            @"(?im)^\s*(?:Receive|Peek|Complete|Settle|Replay|Purge|DeadLetter|Abandon|Defer)-(?:Az)?ServiceBus");
        script.Should().NotMatchRegex(
            @"(?i)\.(?:ReceiveMessages?|PeekMessages?|CompleteMessage|DeadLetterMessage|AbandonMessage|DeferMessage|ReplayMessages?|PurgeMessages?)(?:Async)?\s*\(");
        script.Should().NotContain("ServiceBusReceiver");
        script.Should().NotContain("CreateReceiver");
        script.Should().NotContain("servicebus.windows.net");
        script.Should().NotContain("/$DeadLetterQueue");
    }

    [Fact]
    public void DevelopmentCanaryController_ShouldPinApiManagerApplicationsOnEveryRevision()
    {
        var script = ReadRepositoryFile(
            "operations", "invoke-development-canary.ps1");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        var setApiStart = script.IndexOf(
            "function Set-ApiAdmission", StringComparison.Ordinal);
        var preflightStart = script.IndexOf(
            "function Invoke-ExecutionPreflight", StringComparison.Ordinal);
        setApiStart.Should().BeGreaterThan(-1);
        preflightStart.Should().BeGreaterThan(setApiStart);
        var setApiBlock = script[setApiStart..preflightStart];

        setApiBlock.Should().Contain(
            "[AllowEmptyCollection()][string[]]$ManagerApplicationIds");
        setApiBlock.Should().Contain("$ManagerApplicationSettingPrefix$index");
        setApiBlock.Should().Contain("$staleSettingNames");
        setApiBlock.Should().Contain("'--remove-env-vars'");
        setApiBlock.Should().Contain("$arguments += $managerEnvironmentArguments");

        var updateCalls = Regex.Matches(
            script,
            @"(?ms)^\s*(?:\$\w+\s*=\s*)?Set-ApiAdmission\s+`.*?-RevisionSuffix[^\r\n]+",
            RegexOptions.CultureInvariant);
        updateCalls.Count.Should().Be(7);
        updateCalls.Cast<Match>().Should().OnlyContain(
            match => match.Value.Contains(
                "-ManagerApplicationIds", StringComparison.Ordinal));

        script.Should().Contain("-RequireExpectedManagerApplications");
        script.Should().Contain(
            "-RequireApiManagerConfiguration:($Action -ne 'Arm')");
        preflight.Should().Contain(
            "Test-DeployedManagerApplicationConfiguration `");
        preflight.Should().Contain("-ContainerApp $apiApp `");
        preflight.Should().Contain("-Label 'API' `");
        preflight.Should().Contain(
            "manager application settings are not an exact contiguous indexed collection");
    }

    [Fact]
    public void WorkflowV3_ShouldUseANewQueueAndPreserveHistoricalIsolation()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var roleAssignments = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "role-assignments.bicep");
        var api = ReadRepositoryFile(
            "src", "Gateway.Infrastructure", "ServiceBus", "ServiceBusOptions.cs");
        var worker = ReadRepositoryFile(
            "src", "Gateway.Provisioning.Worker", "ProvisioningWorkerOptions.cs");
        var deployScript = ReadRepositoryFile("operations", "deploy.ps1");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        main.Should().Contain("param serviceBusQueueName string = 'gateway-provisioning-v3'");
        main.Should().Contain("serviceBusQueueName: serviceBus.outputs.queueName");
        roleAssignments.Should().Contain(
            "resource serviceBusQueue 'Microsoft.ServiceBus/namespaces/queues@");
        roleAssignments.Should().Contain("scope: serviceBusQueue");
        roleAssignments.Should().Contain("workerServiceBusDataSender");
        roleAssignments.Should().Contain("serviceBusDataSenderRoleId");
        api.Should().Contain("gateway-provisioning-v3");
        worker.Should().Contain("gateway-provisioning-v3");
        deployScript.Should().Contain("[string]$ServiceBusQueueName = 'gateway-provisioning-v3'");
        preflight.Should().Contain("ExpectedServiceBusQueueName");
        preflight.Should().Contain("The deployed API does not publish to the intended workflow-v3 Service Bus queue.");
    }

    [Fact]
    public void WorkflowV3_ShouldDefaultLegacyWorkerCredentialVaultAccessOff()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var roles = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "role-assignments.bicep");
        var bootstrap = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "role-assignments-worker-bootstrap.bicep");

        main.Should().Contain(
            "param enableLegacyWorkerCredentialKeyVaultSecretsOfficer bool = false");
        main.Should().Contain(
            "enableWorkerCredentialKeyVaultSecretsOfficer: enableLegacyWorkerCredentialKeyVaultSecretsOfficer");
        roles.Should().Contain(
            "param enableWorkerCredentialKeyVaultSecretsOfficer bool = false");
        roles.Should().Contain(
            "= if (enableWorkerCredentialKeyVaultSecretsOfficer)");
        bootstrap.Should().Contain(
            "param enableWorkerCredentialKeyVaultSecretsOfficer bool = false");
        bootstrap.Should().Contain(
            "= if (enableWorkerCredentialKeyVaultSecretsOfficer)");
    }

    [Fact]
    public void WorkflowV3_ApiActions_ShouldBeIndependentExactBoundWindows()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var api = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-api.bicep");
        var controller = ReadRepositoryFile(
            "operations", "invoke-development-canary.ps1");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        main.Should().Contain("effectiveApiProvisioningAdmissionEnabled");
        main.Should().Contain("effectiveApiDelegatedRegistryActionEnabled");
        main.Should().Contain("empty(provisioningAuthorizedExternalAgentId)");
        main.Should().Contain("!empty(agent365DelegatedRegistryAuthorizedOperationId)");
        api.Should().Contain("Provisioning__RequireExactAdmissionBinding");
        api.Should().Contain("Agent365__DelegatedRegistry__RequireExactActionBinding");
        controller.Should().Contain("'OpenDelegatedCompletion'");
        controller.Should().Contain("Registration and retry bindings are valid only for OpenAdmission.");
        controller.Should().Contain("AuthorizedOperationId is valid only for OpenDelegatedCompletion.");
        controller.Should().Contain("$settingsToRemove += $dynamicSettingName");
        controller.Should().NotContain("$AuthorizedOperationId.Value");
        controller.Should().NotContain("$ExpectedAuthorizedOperationId.Value");
        controller.Should().Contain("([guid]$AuthorizedOperationId).ToString('D')");
        preflight.Should().Contain("Provisioning__RequireExactAdmissionBinding");
        preflight.Should().Contain("Agent365__DelegatedRegistry__RequireExactActionBinding");
    }

    [Fact]
    public void AgentRegistryVerification_ShouldUseApiDelegatedConsentNotWorkerApplicationRoles()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        main.Should().Contain("'AgentRegistration.Read.All'");
        main.Should().Contain("'AgentRegistration.ReadWrite.All'");
        preflight.Should().Contain("'AgentRegistration.Read.All'");
        preflight.Should().Contain("'AgentRegistration.ReadWrite.All'");
        preflight.Should().Contain("Test-GatewayApiDelegatedRegistryConsent");
        preflight.Should().Contain("consentType");
        preflight.Should().Contain("& $azPython -IBm azure.cli @Arguments");
        preflight.Should().Contain("--only-show-errors");
        preflight.Should().Contain("function ConvertFrom-AzJsonPreservingStrings");
        preflight.Should().Contain("ConvertFrom-Json -Depth 100 -DateKind String");
        preflight.Should().Contain("[System.Text.Json.JsonDocument]::Parse");
        preflight.Should().Contain("ConvertFrom-AzJsonPreservingStrings -RawJson $json");
        preflight.Should().Contain("function Test-EquivalentOptionalUtcInstant");
        preflight.Should().Contain("$actualInstant.ToUniversalTime().Ticks -eq");
        preflight.Should().Contain("$expectedInstant.ToUniversalTime().Ticks");
        preflight.Should().Contain("-Actual ([string]$deployedAdmissionExpiresAtUtc)");
        preflight.Should().Contain("-Actual ([string]$deployedActionExpiresAtUtc)");
        preflight.Should().Contain("AllPrincipals");

        var mainWorkerRoles = main[
            main.IndexOf("var requiredWorkerGraphApplicationPermissions", StringComparison.Ordinal)..main.IndexOf("var requiredApiGraphApplicationPermissions", StringComparison.Ordinal)];
        mainWorkerRoles.Should().NotContain("AgentRegistration.");

        var preflightWorkerRoles = preflight[
            preflight.IndexOf("$RequiredGraphApplicationPermissions", StringComparison.Ordinal)..preflight.IndexOf("$ProhibitedWorkerGraphApplicationPermissions", StringComparison.Ordinal)];
        preflightWorkerRoles.Should().NotContain("AgentRegistration.");
        preflight.Should().Contain("Test-ProhibitedApplicationRoles");
    }

    [Fact]
    public void DelegatedRegistryDeployment_ShouldRequireExactManagedIdentityOboFederation()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var api = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-api.bicep");
        var deployScript = ReadRepositoryFile("operations", "deploy.ps1");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        main.Should().Contain("param agent365DelegatedRegistryEnabled bool = false");
        main.Should().Contain("effectiveDelegatedRegistryEnabled");
        api.Should().Contain("SignedAssertionFromManagedIdentity");
        api.Should().Contain("api://AzureADTokenExchange");
        api.Should().Contain("Agent365__DelegatedRegistry__Enabled");
        deployScript.Should().Contain("[switch]$EnableDelegatedRegistry");
        deployScript.Should().Contain(
            "agent365DelegatedRegistryEnabled=$($EnableDelegatedRegistry.IsPresent.ToString().ToLowerInvariant())");

        preflight.Should().Contain("function Test-GatewayApiFederatedCredential");
        preflight.Should().Contain("a365gw-api-obo-dev");
        preflight.Should().Contain("https://login.microsoftonline.com/");
        preflight.Should().Contain("$ManagedIdentityPrincipalId.ToString('D')");
        preflight.Should().Contain("@($_.audiences).Count -eq 1");
        preflight.Should().Contain("$TokenExchangeAudience");
        preflight.Should().Contain("Agent365__DelegatedRegistry__Enabled");
    }

    [Fact]
    public void DatabaseMigrationTool_ShouldApplyOnlyReviewedSqlAndRestoreNetworkState()
    {
        var script = ReadRepositoryFile("tools", "apply-migrations.ps1");
        var runner = ReadRepositoryFile(
            "tools", "Gateway.DatabaseMigrator", "Program.cs");

        script.Should().Contain("[switch]$AllowLiveDatabase");
        script.Should().Contain("[switch]$TemporarilyEnablePublicNetwork");
        script.Should().Contain("--enable-public-network false");
        script.Should().Contain("firewall-rule delete");
        script.Should().Contain("$publicNetworkPropagationMaximumAttempts = 36");
        script.Should().Contain("$publicNetworkPropagationPollIntervalSeconds = 5");
        script.Should().Contain("function Wait-SqlPublicNetworkAccessState");
        Regex.Matches(
                script,
                @"Wait-SqlPublicNetworkAccessState\s+`",
                RegexOptions.CultureInvariant)
            .Count.Should().Be(2);
        script.Should().Contain("-ExpectedState 'Enabled'");
        script.Should().Contain("-ExpectedState 'Disabled'");
        script.Should().Contain(
            "$LASTEXITCODE -eq 0 -and $currentState -eq $ExpectedState");
        script.Should().Contain("if ($attempt -lt $MaximumAttempts)");
        script.Should().Contain("if ($publicNetworkRestoreRequired)");
        script.Should().Contain("if (-not $publicNetworkRestored)");
        script.Should().Contain(
            "Azure SQL public network access was not verified as Disabled after the bounded cleanup wait.");
        var restoreRequired = script.IndexOf(
            "$publicNetworkRestoreRequired = $true",
            StringComparison.Ordinal);
        var enableMutation = script.IndexOf(
            "'--enable-public-network', 'true'",
            StringComparison.Ordinal);
        restoreRequired.Should().BeGreaterThan(-1);
        restoreRequired.Should().BeLessThan(enableMutation);
        script.Should().NotContain("dotnet ef migrations add");
        script.Should().NotContain("dotnet add");

        runner.Should().Contain("AzureCliCredential");
        runner.Should().Contain("20260824_agent_identity_workflow_v2.sql");
        runner.Should().Contain("20260825_scoped_idempotency_finalize.sql");
        runner.Should().Contain("SHA256.HashData");
        runner.Should().NotContainEquivalentOf("password");
    }

    [Fact]
    public void BlueprintCatalog_Should_DeclareAndPreflightLeastPrivilegeApiPermission()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        main.Should().Contain("requiredApiGraphApplicationPermissions");
        main.Should().Contain("'AgentIdentityBlueprint.Read.All'");
        preflight.Should().Contain("$RequiredApiGraphApplicationPermissions");
        preflight.Should().Contain("-PrincipalLabel 'API managed identity'");
    }

    [Fact]
    public void BlueprintCatalog_ShouldReceiveTheSameReviewedManagerApplicationsAsTheWorker()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var api = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-api.bicep");
        var worker = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-worker.bicep");

        main.Should().Contain(
            "agent365ManagerApplicationIds: agent365ManagerApplicationIds");
        Regex.Matches(
                main,
                "agent365ManagerApplicationIds: agent365ManagerApplicationIds",
                RegexOptions.CultureInvariant)
            .Count.Should().Be(2);
        api.Should().Contain("param agent365ManagerApplicationIds array = []");
        api.Should().Contain("Agent365__ManagerApplicationIds__${index}");
        worker.Should().Contain("Agent365__ManagerApplicationIds__${index}");
    }

    [Fact]
    public void ApiProbes_ShouldSeparateProcessLivenessFromDatabaseReadiness()
    {
        var api = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-api.bicep");

        api.Should().Contain("type: 'Liveness'");
        api.Should().Contain("type: 'Readiness'");
        api.Should().Contain("type: 'Startup'");
        Regex.Matches(api, "path: '/health'", RegexOptions.CultureInvariant)
            .Count.Should().Be(2);
        api.Should().Contain("path: '/health/ready'");
    }

    [Fact]
    public void PurviewDeployment_ShouldDefaultFailClosedUntilTenantPrerequisitesAreVerified()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var api = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-api.bicep");

        main.Should().Contain("param purviewEnabled bool = false");
        api.Should().Contain("param purviewEnabled bool = false");
        api.Should().Contain("value: string(purviewEnabled)");
        api.Should().NotContain("name: 'Purview__Enabled'\n              value: 'true'");
    }

    [Fact]
    public void Bootstrap_ShouldBeResumableSecretSafeAndFailClosed()
    {
        var entry = ReadRepositoryFile("bootstrap", "bootstrap.ps1");
        var common = ReadRepositoryFile("bootstrap", "modules", "Common.psm1");
        var azure = ReadRepositoryFile("bootstrap", "modules", "Azure.psm1");
        var entra = ReadRepositoryFile("bootstrap", "modules", "Entra.psm1");
        var workflowV3Entra = ReadRepositoryFile("tools", "configure-workflow-v3-entra.ps1");
        var agent365 = ReadRepositoryFile("bootstrap", "modules", "Agent365.psm1");
        var purview = ReadRepositoryFile("bootstrap", "modules", "Purview.psm1");
        var subscription = ReadRepositoryFile("bootstrap", "infra", "subscription.bicep");
        var foundation = ReadRepositoryFile("bootstrap", "infra", "foundation.bicep");
        var sqlPrivate = ReadRepositoryFile("bootstrap", "infra", "sql-private-endpoint.bicep");
        var migrator = ReadRepositoryFile("tools", "Gateway.DatabaseMigrator", "Program.cs");
        var dockerIgnore = ReadRepositoryFile(".dockerignore");

        entry.Should().Contain("[ValidateSet('Plan', 'Apply', 'Resume', 'Verify')]");
        entry.Should().Contain("Enter-BootstrapLock");
        entry.Should().Contain("Recorded resource group");
        entry.Should().Contain("-AlwaysRun -Action");
        entry.Should().Contain("Agent Registration is development-only");
        common.Should().Contain("Move-Item -LiteralPath $temporary -Destination $Path -Force");
        common.Should().Contain("Another bootstrap process holds");
        common.Should().NotContain("message = $_.Exception.Message");
        common.Should().Contain("Review the local terminal output, correct the cause, and run Resume.");
        azure.Should().Contain("Invoke-ArmDeploymentWithSecureParameters");
        azure.Should().Contain("Remove-Item -LiteralPath $temporary -Force");
        azure.Should().Contain("preserveExistingApiSecrets = -not $Initial");
        azure.Should().Contain("public-network-access', 'Disabled'");
        entra.Should().Contain("configure-workflow-v3-entra.ps1");
        workflowV3Entra.Should().Contain("api://AzureADTokenExchange");
        entra.Should().Contain("AgentRegistration.ReadWrite.All");
        entra.Should().Contain("ProtectionScopes.Compute.User");
        entra.Should().NotContain("Write-Host $secretText");
        agent365.Should().Contain("applications/microsoft.graph.agentIdentityBlueprint");
        agent365.Should().Contain("managerApplications");
        agent365.Should().NotContain("--show-secret");
        purview.Should().Contain("EnforcementPlanes = @('Application')");
        purview.Should().Contain("LocationType = 'Individual'");
        subscription.Should().Contain("targetScope = 'subscription'");
        subscription.Should().Contain("Microsoft.Resources/resourceGroups");
        foundation.Should().Contain("Microsoft.App/environments");
        foundation.Should().Contain("privateEndpointNetworkPolicies: 'Disabled'");
        sqlPrivate.Should().Contain("groupIds:");
        sqlPrivate.Should().Contain("'sqlServer'");
        migrator.Should().Contain("EnsureEmptyDatabaseInitializedAsync");
        migrator.Should().Contain("if (tableCount > 0)");
        migrator.Should().Contain("EnsureCreatedAsync");
        dockerIgnore.Should().Contain(".bootstrap/**");
        dockerIgnore.Should().Contain("bootstrap/config.json");
    }

    private static string ReadRepositoryFile(params string[] pathSegments)
    {
        var path = pathSegments.Aggregate(RepositoryRoot, Path.Combine);
        File.Exists(path).Should().BeTrue($"expected repository file {path} to exist");
        return File.ReadAllText(path);
    }

    private static string ReadPowerShellFunction(
        string script,
        string functionName,
        string nextFunctionName)
    {
        var start = script.IndexOf($"function {functionName}", StringComparison.Ordinal);
        var end = script.IndexOf($"function {nextFunctionName}", StringComparison.Ordinal);
        start.Should().BeGreaterThan(-1, $"expected PowerShell function {functionName}");
        end.Should().BeGreaterThan(start, $"expected {nextFunctionName} after {functionName}");
        return script[start..end];
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (Directory.Exists(Path.Combine(directory.FullName, "infrastructure")) &&
                Directory.Exists(Path.Combine(directory.FullName, "operations")) &&
                Directory.Exists(Path.Combine(directory.FullName, "src")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        throw new DirectoryNotFoundException(
            "Could not resolve the repository root from the architecture test output directory.");
    }
}
