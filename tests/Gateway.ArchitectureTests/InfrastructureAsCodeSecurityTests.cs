using FluentAssertions;
using System.Text.Json;
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
    [Fact]
    public void AdminUiContainerBuild_ShouldIncludeCentralReleaseVersionMetadata()
    {
        var dockerfile = ReadRepositoryFile("src", "Gateway.AdminUi", "Dockerfile");

        dockerfile.Should().Contain("COPY [\"Directory.Build.props\", \"./\"]");
        dockerfile.IndexOf("COPY [\"Directory.Build.props\", \"./\"]", StringComparison.Ordinal)
            .Should().BeLessThan(
                dockerfile.IndexOf(
                    "RUN dotnet restore \"src/Gateway.AdminUi/Gateway.AdminUi.csproj\"",
                    StringComparison.Ordinal));
    }

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
        var bootstrapAzure = ReadRepositoryFile("bootstrap", "modules", "Azure.psm1");

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
        bootstrapAzure.Should().Contain("'Microsoft.Network'");
    }

    [Fact]
    public void ApiDeployment_Should_PreserveExistingSecretsByDefault()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var apiModule = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-api.bicep");
        var bootstrapAzure = ReadRepositoryFile("bootstrap", "modules", "Azure.psm1");

        main.Should().Contain("param preserveExistingApiSecrets bool = true");
        main.Should().Contain("existingApiContainerApp.listSecrets().value");
        main.Should().Contain(
            "preservedConfigurationSecrets: preservedApiConfigurationSecrets");

        apiModule.Should().MatchRegex(
            @"@secure\(\)\s+@description\([^\r\n]+\)\s+param preservedConfigurationSecrets object");
        apiModule.Should().Contain(
            "secrets: preservedConfigurationSecrets.?value ?? []");

        bootstrapAzure.Should().Contain("preserveExistingApiSecrets = -not $Initial");
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
    public void CleanBootstrap_Should_PreAuthorizeOneDedicatedRuntimeImagePullIdentity()
    {
        var subscription = ReadRepositoryFile(
            "bootstrap", "infra", "subscription.bicep");
        var foundation = ReadRepositoryFile(
            "bootstrap", "infra", "foundation.bicep");
        var pullIdentity = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "runtime-image-pull-identity.bicep");
        var pullContract = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "runtime-image-pull-contract.bicep");
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var api = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-api.bicep");
        var worker = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-worker.bicep");
        var roles = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "role-assignments.bicep");
        var registry = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-registry.bicep");
        var bootstrapAzure = ReadRepositoryFile("bootstrap", "modules", "Azure.psm1");
        var sharedParameterFiles = new[] { "dev", "staging", "prod" }
            .Select(environment => ReadRepositoryFile(
                "infrastructure", "bicep", "parameters", $"{environment}.bicepparam"))
            .ToArray();

        subscription.Should().Contain("param bootstrapSourceFingerprint string");
        subscription.Should().Contain(
            "runtimeImagePullIdentityId string = foundation.outputs.runtimeImagePullIdentityId");
        foundation.Should().Contain(
            "module runtimeImagePullIdentity '../../infrastructure/bicep/modules/runtime-image-pull-identity.bicep'");
        foundation.Should().Contain("identityName: 'id-gateway-runtime-pull-${environment}'");
        foundation.Should().Contain("bootstrapSourceFingerprint: bootstrapSourceFingerprint");

        pullIdentity.Should().Contain(
            "resource imagePullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@");
        pullIdentity.Should().Contain(
            "resource acrPull 'Microsoft.Authorization/roleAssignments@");
        pullIdentity.Should().Contain("scope: containerRegistry");
        pullIdentity.Should().Contain("principalId: imagePullIdentity.properties.principalId");
        pullIdentity.Should().Contain("acrPullRoleDefinitionGuid = '7f951dda-4ed3-4680-a7ca-43fe172d538d'");

        main.Should().Contain("param runtimeImagePullIdentityId string");
        main.Should().Contain("param runtimeImagePullIdentityPrincipalId string");
        main.Should().Contain("param runtimeImagePullAcrPullRoleAssignmentId string");
        main.Should().Contain("param allowLegacySystemAssignedImagePull bool = false");
        main.Should().Contain(
            "var runtimeImagePullIdentityInputsAreEmpty = empty(runtimeImagePullIdentityId) && empty(runtimeImagePullIdentityPrincipalId) && empty(runtimeImagePullAcrPullRoleAssignmentId)");
        main.Should().Contain(
            "var runtimeImagePullIdentityInputsArePopulated = !empty(runtimeImagePullIdentityId) && !empty(runtimeImagePullIdentityPrincipalId) && !empty(runtimeImagePullAcrPullRoleAssignmentId)");
        main.Should().Contain("'InvalidPartialOrBootstrapIdentityEvidence'");
        main.Should().Contain(
            "runtimeImagePullAcrRoleAssignmentPrefix = '${toLower(acr.outputs.registryId)}/providers/microsoft.authorization/roleassignments/'");
        main.Should().Contain(
            "var runtimeImagesAreDeploymentAcrDigests = startsWith(toLower(apiContainerImage), '${toLower(acr.outputs.loginServer)}/')");
        main.Should().Contain(
            "enableLegacySystemAssignedAcrPull: runtimeImagePullIdentityInputsAreEmpty && allowLegacySystemAssignedImagePull && !bootstrapOwnedDeployment");
        pullContract.Should().Contain("'DedicatedUserAssignedIdentity'");
        pullContract.Should().Contain("'LegacySystemAssignedIdentity'");
        Regex.Matches(
                main,
                "imagePullIdentityResourceId: runtimeImagePullIdentityId",
                RegexOptions.CultureInvariant)
            .Count.Should().Be(2);
        api.Should().Contain("type: 'SystemAssigned, UserAssigned'");
        api.Should().Contain("type: 'SystemAssigned'");
        api.Should().Contain(
            "identity: empty(imagePullIdentityResourceId) ? 'system' : imagePullIdentityResourceId");
        worker.Should().Contain("type: 'SystemAssigned, UserAssigned'");
        worker.Should().Contain(
            "identity: empty(imagePullIdentityResourceId) ? 'system' : imagePullIdentityResourceId");

        roles.Should().Contain(
            "resource apiAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableLegacySystemAssignedAcrPull)");
        roles.Should().Contain(
            "resource workerAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableLegacySystemAssignedAcrPull)");
        roles.Should().Contain(
            "name: guid(subscription().id, apiPrincipalId, containerRegistry.id, acrPullRoleId)");
        roles.Should().Contain(
            "name: guid(subscription().id, workerPrincipalId, containerRegistry.id, acrPullRoleId)");
        registry.Should().Contain("azureADAuthenticationAsArmPolicy:");
        registry.Should().Contain("status: 'enabled'");

        sharedParameterFiles.Should().OnlyContain(parameterFile =>
            parameterFile.Contains("RUNTIME_IMAGE_PULL_IDENTITY_ID", StringComparison.Ordinal) &&
            parameterFile.Contains("RUNTIME_IMAGE_PULL_IDENTITY_PRINCIPAL_ID", StringComparison.Ordinal) &&
            parameterFile.Contains("RUNTIME_IMAGE_PULL_ACR_PULL_ROLE_ASSIGNMENT_ID", StringComparison.Ordinal) &&
            parameterFile.Contains("ALLOW_LEGACY_SYSTEM_ASSIGNED_IMAGE_PULL", StringComparison.Ordinal));
        bootstrapAzure.Should().Contain(
            "function Assert-GatewayRuntimeImagePullFoundationEvidence");
        bootstrapAzure.Should().Contain(
            "runtimeImagePullIdentityId = [string]$pullEvidence.identityId");
        bootstrapAzure.Should().Contain(
            "runtimeImagePullIdentityPrincipalId = [string]$pullEvidence.principalId");
        bootstrapAzure.Should().Contain(
            "runtimeImagePullAcrPullRoleAssignmentId = [string]$pullEvidence.roleAssignmentId");
        bootstrapAzure.Should().Contain(
            "Assert-GatewayExactPartialRegistryEnvelope");
    }

    [Fact]
    public void ProvisioningFailureAlert_Should_TargetHistoricalAndNewWorkers()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var alerts = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "monitoring-alerts.bicep");
        var bootstrapAzure = ReadRepositoryFile("bootstrap", "modules", "Azure.psm1");

        main.Should().Contain(
            "historicalWorkerContainerAppName: historicalWorkerContainerAppName");
        main.Should().Contain("targetWorkerContainerAppName: names.workerApp");
        main.Should().Contain("output provisioningAlertWorkerContainerAppNames array");

        alerts.Should().Contain("cloud_RoleName == \"${historicalWorkerContainerAppName}\"");
        alerts.Should().Contain("cloud_RoleName == \"${targetWorkerContainerAppName}\"");

        bootstrapAzure.Should().Contain(
            "historicalWorkerContainerAppName = \"ca-gateway-worker-$($Config.environment)\"");
    }

    [Fact]
    public void Agent365Observability_Should_Not_ConfigureSharedWorkerExporterIdentity()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var worker = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-worker.bicep");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");
        var bootstrapAzure = ReadRepositoryFile("bootstrap", "modules", "Azure.psm1");

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
    public void ActiveAgentIdentityUniquenessMigration_ShouldFailClosedWithoutRewritingRegistrations()
    {
        const string migrationName = "20260905_active_agent_identity_uniqueness.sql";
        var migration = ReadRepositoryFile("infrastructure", "sql", migrationName);
        var sqlDirectory = Path.Combine(FindRepositoryRoot(), "infrastructure", "sql");
        var orderedMigrationNames = Directory
            .EnumerateFiles(sqlDirectory, "*.sql")
            .Select(Path.GetFileName)
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();

        migration.Should().Contain("OBJECT_ID(N'dbo.AgentRegistrations', N'U') IS NULL");
        migration.Should().Contain(
            "COL_LENGTH(N'dbo.AgentRegistrations', N'AgentIdentityObjectId') IS NULL");
        migration.Should().Contain(
            "COL_LENGTH(N'dbo.AgentRegistrations', N'IsDeleted') IS NULL");
        migration.Should().Contain("WITH (UPDLOCK, HOLDLOCK)");
        migration.Should().Contain("sys.sp_getapplock");
        migration.Should().Contain("@LockOwner = N'Transaction'");
        migration.IndexOf("sys.sp_getapplock", StringComparison.Ordinal).Should().BeLessThan(
            migration.IndexOf("DECLARE @ExistingIndexId", StringComparison.Ordinal));
        migration.Should().Contain("GROUP BY [AgentIdentityObjectId]");
        migration.Should().Contain("HAVING COUNT_BIG(*) > 1");
        migration.Should().Contain(
            "CREATE UNIQUE INDEX [IX_AgentRegistrations_AgentIdentityObjectId]");
        migration.Should().MatchRegex(
            @"WHERE \[AgentIdentityObjectId\] IS NOT NULL\s+AND \[IsDeleted\] = 0;");
        migration.Should().Contain("no data was changed");
        migration.Should().NotMatchRegex(@"(?im)^\s*(DELETE|UPDATE|DROP)\s+");
        migration.Should().NotContain("[ExternalClientId]");
        Array.IndexOf(orderedMigrationNames, migrationName).Should().BeGreaterThan(
            Array.IndexOf(
                orderedMigrationNames,
                "20260903_prompt_evaluation_agent_identity.sql"));
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
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");
        var bootstrapAzure = ReadRepositoryFile("bootstrap", "modules", "Azure.psm1");

        main.Should().Contain("agent365ProvisioningManagedIdentityPrincipalId");
        main.Should().Contain("!empty(agent365ProvisioningManagedIdentityPrincipalId)");
        worker.Should().Contain(
            "Agent365__ProvisioningManagedIdentityPrincipalId");
        bootstrapAzure.Should().Contain(
            "agent365ProvisioningManagedIdentityPrincipalId = $WorkerPrincipalId");
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
            "provisioningExecutionEnabled: effectiveContinuousDevelopmentProvisioningEnabled");
        main.Should().Contain(
            "agent365DelegatedRegistryEnabled: effectiveContinuousDevelopmentProvisioningEnabled");
        main.Should().Contain("minReplicas: apiMinReplicas");
        main.Should().Contain("maxReplicas: apiMaxReplicas");
        // The worker scale range still comes from the parameter, but Registry
        // preview provisioning pins it to a single replica taking a single
        // Service Bus callback, because the preview dependency is not safe to
        // call concurrently.
        main.Should().Contain(
            "maxReplicas: effectiveWorkerProvisioningExecutionEnabled ? 1 : workerMaxReplicas");
        main.Should().Contain(
            "maxConcurrentCalls: effectiveWorkerProvisioningExecutionEnabled ? 1 : 5");
        main.Should().Contain("output apiMinReplicas int = apiMinReplicas");
        main.Should().Contain("output apiMaxReplicas int = apiMaxReplicas");
        main.Should().NotContain("effectiveApiBoundedActionEnabled");
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
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        main.Should().Contain("param serviceBusQueueName string = 'gateway-provisioning-v3'");
        main.Should().Contain("serviceBusQueueName: serviceBus.outputs.queueName");
        roleAssignments.Should().Contain(
            "resource serviceBusQueue 'Microsoft.ServiceBus/namespaces/queues@");
        roleAssignments.Should().Contain("scope: serviceBusQueue");
        roleAssignments.Should().NotContain("workerServiceBusDataSender");
        roleAssignments.Should().Contain("apiServiceBusDataSender");
        roleAssignments.Should().Contain("serviceBusDataSenderRoleId");
        api.Should().Contain("gateway-provisioning-v3");
        worker.Should().Contain("gateway-provisioning-v3");
        preflight.Should().Contain("ExpectedServiceBusQueueName");
        preflight.Should().Contain("The deployed API does not publish to the intended workflow-v3 Service Bus queue.");
    }

    [Fact]
    public void WorkflowV3_ShouldNotDeployOrConfigureALegacyWorkerCredentialVault()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var roles = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "role-assignments.bicep");
        var worker = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-worker.bicep");

        main.Should().NotContain("provisioningKeyVault");
        main.Should().NotContain("-prov'");
        roles.Should().NotContain("workerCredentialKeyVault");
        roles.Should().NotContain("Key Vault Secrets Officer");
        worker.Should().NotContain("Agent365__CredentialKeyVaultUri");
    }

    [Fact]
    public void WorkflowV3_ApiAccess_ShouldBeClosedOrExplicitlyContinuousDevelopment()
    {
        var main = ReadRepositoryFile("infrastructure", "bicep", "main.bicep");
        var api = ReadRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-api.bicep");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        main.Should().Contain("effectiveContinuousDevelopmentProvisioningEnabled");
        main.Should().Contain("provisioningExecutionEnabled: effectiveContinuousDevelopmentProvisioningEnabled");
        main.Should().Contain("agent365DelegatedRegistryEnabled: effectiveContinuousDevelopmentProvisioningEnabled");
        api.Should().Contain("Provisioning__AllowContinuousDevelopmentAccess");
        api.Should().Contain("Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess");
        preflight.Should().Contain("Test-DeployedProvisioningAccessConfiguration");
        preflight.Should().Contain("ExpectedContinuousDevelopmentAccess");
        main.Should().NotContain("provisioningAuthorizedExternalAgentId");
        main.Should().NotContain("agent365DelegatedRegistryAuthorizedOperationId");
        api.Should().NotContain("RequireExactAdmissionBinding");
        api.Should().NotContain("RequireExactActionBinding");
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
        preflight.Should().Contain("& $azPython -IBm azure.cli @effectiveArguments");
        preflight.Should().Contain("--only-show-errors");
        preflight.Should().Contain("Assert-ActiveAzureAccountBoundary");
        preflight.Should().Contain("Get-SubscriptionPinnedAzArguments");
        preflight.Should().Contain("function ConvertFrom-AzJsonPreservingStrings");
        preflight.Should().Contain("ConvertFrom-Json -Depth 100 -DateKind String");
        preflight.Should().Contain("[System.Text.Json.JsonDocument]::Parse");
        preflight.Should().Contain("ConvertFrom-AzJsonPreservingStrings -RawJson $json");
        preflight.Should().Contain("Test-DeployedDelegatedRegistryConfiguration");
        preflight.Should().Contain("ExpectedContinuousDevelopmentAccess");
        preflight.Should().NotContain("Test-EquivalentOptionalUtcInstant");
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
        var bootstrapAzure = ReadRepositoryFile("bootstrap", "modules", "Azure.psm1");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        main.Should().Contain("param agent365DelegatedRegistryEnabled bool = false");
        main.Should().Contain("effectiveDelegatedRegistryEnabled");
        api.Should().Contain("SignedAssertionFromManagedIdentity");
        api.Should().Contain("api://AzureADTokenExchange");
        api.Should().Contain("Agent365__DelegatedRegistry__Enabled");
        bootstrapAzure.Should().Contain(
            "agent365DelegatedRegistryEnabled = [bool]$enablePreview");

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
        script.Should().Contain("'--enable-public-network', 'false'");
        script.Should().Contain("'firewall-rule', 'delete'");
        script.Should().Contain("Invoke-AzCommand -Arguments @(");
        script.Should().Contain("'sql', 'server', 'firewall-rule', 'list'");
        script.Should().Contain("Azure SQL firewall-rule discovery was unavailable; absence was not proven.");
        script.Should().Contain("$publicNetworkPropagationMaximumAttempts = 36");
        script.Should().Contain("$publicNetworkPropagationPollIntervalSeconds = 5");
        script.Should().Contain("function Wait-SqlPublicNetworkAccessState");
        Regex.Matches(
                script,
                @"Wait-SqlPublicNetworkAccessState\s+`",
                RegexOptions.CultureInvariant)
            .Count.Should().BeGreaterThanOrEqualTo(2);
        script.Should().Contain("-ExpectedState 'Enabled'");
        script.Should().Contain("-ExpectedState 'Disabled'");
        script.Should().Contain("$currentState -eq $ExpectedState");
        script.Should().Contain(
            "-ErrorMessage 'Azure SQL public-network state polling failed.'");
        script.Should().Contain("if ($attempt -lt $MaximumAttempts)");
        script.Should().Contain("if ($publicNetworkRestoreRequired)");
        script.Should().Contain("$publicNetworkRestored = Wait-SqlPublicNetworkAccessState");
        script.Should().Contain("if (-not $publicNetworkRestored) { throw 'restore not proven' }");
        script.Should().Contain("function Save-SqlNetworkRecoveryRecord");
        script.Should().Contain("$NetworkOperationId.ToString('D')");
        script.Should().Contain("$hash.Substring(0, 24)");
        script.Should().Contain("The safe recovery record was preserved");
        script.Should().Contain("if ($cleanupFailures.Count -eq 0)");
        var restoreRequired = script.IndexOf(
            "$publicNetworkRestoreRequired = $originalPublicNetworkAccess -eq 'Disabled'",
            StringComparison.Ordinal);
        var recoveryRecord = script.IndexOf(
            "Save-SqlNetworkRecoveryRecord -Path $recoveryPath",
            StringComparison.Ordinal);
        var enableMutation = script.IndexOf(
            "'--enable-public-network', 'true'",
            StringComparison.Ordinal);
        restoreRequired.Should().BeGreaterThan(-1);
        restoreRequired.Should().BeLessThan(enableMutation);
        recoveryRecord.Should().BeGreaterThan(-1);
        recoveryRecord.Should().BeLessThan(enableMutation);
        script.Should().NotContain("dotnet ef migrations add");
        script.Should().NotContain("dotnet add");

        runner.Should().Contain("AzureCliCredential");
        runner.Should().Contain("20260824_agent_identity_workflow_v2.sql");
        runner.Should().Contain("20260829_purview_policy_profiles.sql");
        runner.Should().Contain("20260829_prompt_protection.sql");
        runner.Should().Contain("20260903_prompt_evaluation_agent_identity.sql");

        var purviewMigration = ReadRepositoryFile(
            "infrastructure", "sql", "20260829_purview_policy_profiles.sql");
        purviewMigration.Should().Contain("[BlueprintApplicationIdsJson] nvarchar(max) NOT NULL");
        purviewMigration.Should().NotContain("nvarchar(8000)");
        runner.Should().Contain("20260825_scoped_idempotency_finalize.sql");
        runner.Should().Contain("SHA256.HashData");
        runner.Should().NotContainEquivalentOf("password");
    }

    [Fact]
    public void ApiContainerBuild_ShouldRestoreEveryDirectProjectDependency()
    {
        var project = ReadRepositoryFile("src", "Gateway.Api", "Gateway.Api.csproj");
        var dockerfile = ReadRepositoryFile("src", "Gateway.Api", "Dockerfile");

        var projectReferences = Regex.Matches(
                project,
                "<ProjectReference Include=\"(?<path>[^\"]+)\"",
                RegexOptions.CultureInvariant)
            .Select(match => Path.GetFileName(match.Groups["path"].Value.Replace('\\', '/')))
            .ToArray();

        foreach (var projectFile in projectReferences)
            dockerfile.Should().Contain(projectFile);
    }

    [Fact]
    public void LiveVerification_ShouldKeepTemporaryCredentialsInMemoryAndRevokeThem()
    {
        var source = ReadRepositoryFile("tools", "Gateway.LiveVerification", "Program.cs");
        var tokenValidator = ReadRepositoryFile(
            "tools", "Gateway.LiveVerification", "ControlTokenValidator.cs");
        var evidenceValidator = ReadRepositoryFile(
            "tools", "Gateway.LiveVerification", "VerificationEvidenceValidator.cs");
        var wrapper = ReadRepositoryFile(
            "operations", "verify-first-registration.ps1");
        var durableState = ReadRepositoryFile(
            "operations", "FirstRegistrationVerificationState.psm1");
        var dockerfile = ReadRepositoryFile("tools", "Gateway.LiveVerification", "Dockerfile");

        source.Should().Contain("credentialKey = string.Empty");
        source.Should().Contain("credentials/{credentialId:D}");
        source.Should().Contain("$\"{options.ApiScopeBaseUri}/access_as_user\"");
        source.Should().Contain("InteractiveBrowserCredential");
        source.Should().Contain("InteractiveBrowserUser");
        source.Should().Contain("VerificationOperationMode.RevokeOnly");
        source.Should().Contain("credentialId = options.RecoveryCredentialId!.Value");
        source.Should().Contain("ControlTokenValidator.Validate(");
        source.Should().Contain("access_as_user");
        tokenValidator.Should().Contain("Gateway.Administrator");
        tokenValidator.Should().Contain("parsedAudience != apiApplicationClientId");
        tokenValidator.Should().Contain("parsedUserObjectId != expectedUserObjectId");
        tokenValidator.Should().Contain("expectedClientApplicationId");
        tokenValidator.Should().Contain("ReadRequiredStringClaim(root, \"azp\")");
        evidenceValidator.Should().Contain("response.AgentId != expectedAgentRegistrationId");
        evidenceValidator.Should().Contain("response.Credential.KeyId != expectedCredentialId");
        evidenceValidator.Should().Contain("response.Credential.RevokedAtUtc is null");
        evidenceValidator.Should().Contain("NonBlockingPurviewDecisions");
        evidenceValidator.Should().Contain("expectPromptShieldEnabled ? \"Allowed\" : \"Disabled\"");
        evidenceValidator.Should().Contain("\"PurviewDisabled\"");
        evidenceValidator.Should().Contain("parsedHeader is null");
        source.Should().Contain("$\"{options.ApiScopeBaseUri}/.default\"");
        source.Should().Contain("Required(values, \"api-scope-base-uri\")");
        source.Should().NotContain("$\"api://{options.ApiApplicationClientId:D}/.default\"");
        source.Should().Contain("exitCode = 1;");
        source.Should().Contain("The response body was deliberately not rendered.");
        source.Should().Contain("provider details were suppressed");
        source.Should().NotContain("exception.Message");
        source.Should().NotContain("Console.WriteLine(credentialKey");
        source.Should().NotContain("Console.WriteLine(token.Token");
        source.Should().Contain("bool ExpectPromptShieldEnabled");
        source.Should().Contain("bool ExpectPurviewEnabled");
        source.Should().Contain("RequiredBoolean(values, \"expect-prompt-shield-enabled\")");
        source.Should().Contain("RequiredBoolean(values, \"expect-purview-enabled\")");
        source.Should().Contain("if (options.ExpectPromptShieldEnabled)");
        source.Should().Contain("Prompt Shields injection-block proof was not attempted");
        source.Should().Contain("[PASS] Live Gateway verification completed.");
        var allowedEvaluation = source.IndexOf(
            "ValidateAllowedEvaluation(await EvaluateAsync(",
            StringComparison.Ordinal);
        var activityIngestion = source.IndexOf(
            "\"api/v1/agent-activities\"",
            StringComparison.Ordinal);
        var interactionIngestion = source.IndexOf(
            "\"api/v1/ai-interactions\"",
            StringComparison.Ordinal);
        var promptShieldProof = source.IndexOf(
            "if (options.ExpectPromptShieldEnabled)",
            StringComparison.Ordinal);
        allowedEvaluation.Should().BeGreaterThan(-1);
        activityIngestion.Should().BeGreaterThan(allowedEvaluation);
        interactionIngestion.Should().BeGreaterThan(activityIngestion);
        promptShieldProof.Should().BeGreaterThan(interactionIngestion);
        wrapper.Should().Contain("ApplicationCreateStarted");
        wrapper.Should().Contain("OwnerAddStarted");
        wrapper.Should().Contain("ServicePrincipalCreateStarted");
        wrapper.Should().Contain("GrantCreateStarted");
        wrapper.Should().Contain("ArmStarted");
        wrapper.Should().Contain("ChildLaunchStarted");
        wrapper.Should().Contain("Test-FirstRegistrationVerificationStateRequiresPreservation");
        wrapper.Should().Contain("wrapperSha256");
        wrapper.Should().Contain("helperBundleSha256");
        wrapper.Should().Contain("verificationBundleSha256");
        wrapper.Should().Contain("[switch]$ExpectPromptShieldEnabled");
        wrapper.Should().Contain("[switch]$ExpectPurviewEnabled");
        wrapper.Should().Contain("promptShieldExpected = ([bool]$ExpectPromptShieldEnabled).ToString().ToLowerInvariant()");
        wrapper.Should().Contain("purviewExpected = ([bool]$ExpectPurviewEnabled).ToString().ToLowerInvariant()");
        wrapper.Should().Contain("'--expect-prompt-shield-enabled'");
        wrapper.Should().Contain("'--expect-purview-enabled'");
        wrapper.Should().Contain("Get-ExactVerificationApplicationById");
        wrapper.Should().Contain("Wait-ExactVerificationObjectAbsent");
        wrapper.Should().Contain("& dotnet @verificationArguments");
        wrapper.Should().NotContain("'run', '--project'");
        durableState.Should().Contain("Completed = @()");
        durableState.Should().Contain("'promptShieldExpected'");
        durableState.Should().Contain("'purviewExpected'");
        durableState.Should().Contain("'^(true|false)$'");
        durableState.Should().Contain("Convert-VerificationParsedJsonDatesToStrings");
        durableState.Should().Contain("$stream.Flush($true)");
        durableState.Should().Contain("[IO.File]::Move($temporary, $fullPath, $true)");
        dockerfile.Should().Contain("USER $APP_UID");
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
        var adminUiCredential = ReadRepositoryFile("bootstrap", "infra", "admin-ui-credential.bicep");
        var subscription = ReadRepositoryFile("bootstrap", "infra", "subscription.bicep");
        var foundation = ReadRepositoryFile("bootstrap", "infra", "foundation.bicep");
        var sqlPrivate = ReadRepositoryFile("bootstrap", "infra", "sql-private-endpoint.bicep");
        var migrator = ReadRepositoryFile("tools", "Gateway.DatabaseMigrator", "Program.cs");
        var dockerIgnore = ReadRepositoryFile(".dockerignore");

        entry.Should().Contain(
            "[ValidateSet('Init', 'Doctor', 'Plan', 'Apply', 'Resume', 'Status', 'Verify', 'Open', 'Diagnose', 'Up', 'RecoverDatabase', 'RepairDatabase')]");
        entry.Should().Contain("Enter-BootstrapLock");
        entry.Should().Contain(
            "Clean bootstrap requires the target resource group to be absent. Refusing to adopt an existing unowned resource group or its deterministic resources.");
        entry.Should().Contain("-AlwaysRun -Action");
        entry.Should().Contain("Agent Registration is development-only");
        common.Should().Contain("[IO.File]::Move($temporary, $fullPath, $true)");
        common.Should().Contain("$stream.Flush($true)");
        common.Should().NotContain("$Path.tmp");
        common.Should().Contain("configurationFingerprint");
        common.Should().Contain("Assert-BootstrapAcceptedPlan");
        common.Should().Contain("Another bootstrap process holds");
        common.Should().NotContain("message = $_.Exception.Message");
        common.Should().Contain("Review the local terminal output, correct the cause, and run Resume.");
        azure.Should().Contain("Invoke-ArmDeploymentWithSecureParameters");
        azure.Should().Contain("'deployment', 'group', 'create', '--subscription', $canonicalSubscriptionIdText");
        azure.Should().Contain("Deploy-GatewayAdminUiCredentialSecret");
        azure.Should().Contain("Remove-Item -LiteralPath $temporary -Force");
        azure.Should().Contain("preserveExistingApiSecrets = -not $Initial");
        azure.Should().Contain("public-network-access', 'Disabled'");
        entra.Should().Contain("configure-workflow-v3-entra.ps1");
        workflowV3Entra.Should().Contain("api://AzureADTokenExchange");
        entra.Should().Contain("AgentRegistration.ReadWrite.All");
        entra.Should().Contain("ProtectionScopes.Compute.User");
        entra.Should().NotContain("Write-Host $secretText");
        entra.Should().Contain("Get-BootstrapDeterministicRoleAssignmentName");
        entra.Should().NotContain("$temporaryRoleAssignmentName");
        entra.Should().NotContain("'role', 'assignment', 'create'");
        entra.Should().Contain("Deploy-GatewayAdminUiCredentialSecret");
        entra.Should().Contain("'role', 'assignment', 'delete', '--ids', $assignmentId");
        entra.Should().Contain("could not be proven removed");
        entra.Should().NotContain(
            "'role', 'assignment', 'delete', '--assignee-object-id', $UserObjectId");
        adminUiCredential.Should().Contain("@secure()");
        adminUiCredential.Should().Contain("Microsoft.KeyVault/vaults/secrets@2023-07-01");
        adminUiCredential.Should().NotContain("output secretValue");
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

    [Fact]
    public void Bootstrap_StartedExternalMutations_ShouldRequireExactReadbackBeforeReuse()
    {
        var entry = ReadRepositoryFile("bootstrap", "bootstrap.ps1");
        var common = ReadRepositoryFile("bootstrap", "modules", "Common.psm1");
        var entra = ReadRepositoryFile("bootstrap", "modules", "Entra.psm1");
        var agent365 = ReadRepositoryFile("bootstrap", "modules", "Agent365.psm1");

        common.Should().Contain("$existing.status -in @('Running', 'Failed')");
        common.Should().Contain("[switch]$NoAutomaticReplayAfterStart");
        common.Should().Contain("Reconciler must return exactly one typed disposition.");
        common.Should().Contain("No mutation was repeated");
        common.Should().Contain("reconciledAtUtc");
        common.Should().Contain(
            "Completed bootstrap step '$Name' no longer matches exact provider readback and is not safe to replay automatically.");

        entry.Should().Contain("function Invoke-GatewayExactReconciliation");
        entry.Should().Contain("Ensure-GatewayApiApplication");
        entry.Should().Contain("Ensure-AdminUiApplication");
        entry.Should().Contain("Ensure-Agent365SeedBlueprint");
        entry.Should().Contain("Get-GatewayWorkloadIdentityEvidence");
        entry.Should().Contain("Resolve-AdminUiCredentialAfterStartedOutcome");
        entra.Should().Contain("Get-AdminUiCredentialEvidenceFromMetadata");
        entry.Should().Contain("Get-BootstrapPurviewPolicyEvidence");
        Regex.Matches(entry, "-ReconcileOnly", RegexOptions.CultureInvariant)
            .Count.Should().BeGreaterThanOrEqualTo(3);
        Regex.Matches(entry, "-NoAutomaticReplayAfterStart", RegexOptions.CultureInvariant)
            .Count.Should().BeGreaterThanOrEqualTo(6);

        entra.Should().Contain("[switch]$ReconcileOnly");
        entra.Should().Contain("read-only reconciliation");
        agent365.Should().Contain("[switch]$ReconcileOnly");
        agent365.Should().Contain("must not be repeated automatically");
    }

    [Fact]
    public void Bootstrap_AcrBuild_ShouldStageOnlyRegularAllowlistedSource()
    {
        var azure = ReadRepositoryFile("bootstrap", "modules", "Azure.psm1");
        var dockerIgnore = ReadRepositoryFile(".dockerignore");

        azure.Should().Contain("function Get-GatewayAcrBuildSourceFiles");
        azure.Should().Contain("function New-GatewayAcrBuildContext");
        azure.Should().Contain("[IO.Directory]::CreateTempSubdirectory('a365gw-acr-build-')");
        azure.Should().Contain("Assert-BootstrapSourcePathIsRegular");
        azure.Should().Contain("function Assert-GatewayCredentialFreeNuGetConfig");
        azure.Should().Contain("[Xml.DtdProcessing]::Prohibit");
        azure.Should().Contain("$document.XmlResolver = $null");
        azure.Should().Contain("$sections[0].Name -cne 'packageSources'");
        azure.Should().Contain("unreviewed-source-host");
        azure.Should().Contain(
            "The ACR build refuses NuGet configuration outside the exact credential-free HTTPS source allowlist. No configuration value was rendered.");
        azure.Should().Contain("'src/Gateway.Api/Dockerfile'");
        azure.Should().Contain("'src/Gateway.Provisioning.Worker/Dockerfile'");
        azure.Should().Contain("'src/Gateway.AdminUi/Dockerfile'");
        azure.Should().Contain("$buildContext = New-GatewayAcrBuildContext");
        azure.Should().Contain("function Assert-GatewayAcrCompletedBuildContract");
        azure.Should().Contain("$buildContext, '--no-logs'");
        azure.Should().Contain("Invoke-AzJson -CaptureStdoutOnly");
        azure.Should().NotContain("$buildContext, '--no-wait'");
        azure.Should().Contain("Remove-Item -LiteralPath $buildContext -Recurse -Force");

        dockerIgnore.Should().Contain("**/.secrets.*");
        dockerIgnore.Should().Contain("**/.env.*");
        dockerIgnore.Should().Contain("**/*.pfx");
        dockerIgnore.Should().Contain("**/*credentials*.json");
    }

    [Fact]
    public void Bootstrap_StateTenantObjectsAndPurview_ShouldUseExactOwnedReadback()
    {
        var common = ReadRepositoryFile("bootstrap", "modules", "Common.psm1");
        var entra = ReadRepositoryFile("bootstrap", "modules", "Entra.psm1");
        var experience = ReadRepositoryFile("bootstrap", "modules", "Experience.psm1");
        var purview = ReadRepositoryFile("bootstrap", "modules", "Purview.psm1");
        var sourceGate = ReadRepositoryFile("tools", "Test-BootstrapSource.ps1");

        common.Should().Contain("deploymentOwnershipId = [guid]::NewGuid().ToString('D')");
        common.Should().Contain("State deploymentOwnershipId");
        common.Should().Contain("must not contain symbolic links or reparse points");
        entra.Should().Contain("A365GatewayOwnership:");
        entra.Should().Contain("Test-ExactStringSet -Actual");
        entra.Should().Contain("must have exactly the pinned bootstrap operator as owner");
        experience.Should().Contain("$Evidence.deploymentOwnershipId");
        experience.Should().Contain("$Evidence.networkRecoveryRecordCleared -ne $true");

        purview.Should().Contain("function Get-BootstrapPurviewPolicyEvidence");
        purview.Should().Contain("Assert-BootstrapPurviewCollectionObject");
        purview.Should().Contain("Assert-BootstrapPurviewPolicyObject");
        purview.Should().Contain("Assert-BootstrapPurviewRuleObject");
        purview.Should().Contain("exactTypedReadback = $true");
        purview.Should().Contain("propagationStatus = 'PendingLiveVerification'");
        experience.Should().Contain("$Evidence.exactTypedReadback -ne $true");

        sourceGate.Should().Contain("$result.FailedCount -gt 0 -or $failedContainerCount -gt 0");
        sourceGate.Should().Contain("Bootstrap/runtime Pester failed:");
        sourceGate.Should().Contain("operations/FirstRegistrationVerificationState.psm1");
        sourceGate.Should().Contain("operations/verify-first-registration.ps1");
    }

    [Fact]
    public void GatewayLaunchersAndSetupUi_ShouldPreserveArgumentsAndLoopbackSessionBoundary()
    {
        var launcher = ReadRepositoryFile("gateway");
        var windowsLauncher = ReadRepositoryFile("gateway.cmd");
        var setupProgram = ReadRepositoryFile("tools", "Gateway.Setup", "Program.cs");
        var setupCommand = ReadRepositoryFile(
            "tools", "Gateway.Setup", "Services", "BootstrapCommand.cs");
        var setupLoader = ReadRepositoryFile(
            "tools", "Gateway.Setup", "Services", "BootstrapConfigLoader.cs");

        launcher.Should().Contain("set -euo pipefail");
        launcher.Should().Contain("pwsh_args=(");
        launcher.Should().Contain("exec pwsh \"${pwsh_args[@]}\"");
        launcher.Should().NotContain("eval ");
        windowsLauncher.Should().Contain("DisableDelayedExpansion");
        windowsLauncher.Should().Contain("Values supplied by the caller cross into PowerShell through environment");
        windowsLauncher.Should().Contain("@p;");

        setupProgram.Should().Contain("SessionNonceGate.Create()");
        setupProgram.Should().Contain("AddAntiforgery");
        setupProgram.Should().Contain("app.UseAntiforgery()");
        setupProgram.Should().Contain("http://127.0.0.1:");
        setupCommand.Should().Contain("startInfo.ArgumentList.Add(argument)");
        setupLoader.Should().Contain("bootstrap/config.json is a symbolic link");
        setupLoader.Should().Contain("It will not overwrite the file");
    }

    [Fact]
    public void Bootstrap_ShouldNamespaceTenantObjectsAndKeepOptionalPaidPreviewFeaturesOff()
    {
        var azure = ReadRepositoryFile("bootstrap", "modules", "Azure.psm1");
        var entra = ReadRepositoryFile("bootstrap", "modules", "Entra.psm1");
        var verification = ReadRepositoryFile("bootstrap", "modules", "Verification.psm1");
        var subscription = ReadRepositoryFile("bootstrap", "infra", "subscription.bicep");
        var example = ReadRepositoryFile("bootstrap", "config.example.json");

        entra.Should().Contain(
            "A365 Gateway API - $($Config.projectName)-$($Config.environment)");
        entra.Should().Contain(
            "api://a365-gateway-$($Config.projectName)-$($Config.environment)");
        entra.Should().Contain(
            "A365 Gateway Admin UI - $($Config.projectName)-$($Config.environment)");
        entra.Should().Contain(
            "a365gw-$($Config.projectName)-api-obo-$($Config.environment)");
        verification.Should().Contain(
            "a365gw-$($Config.projectName)-api-obo-$($Config.environment)");
        subscription.Should().Contain(
            "name: 'bootstrap-foundation-${projectName}-${environment}'");
        subscription.Should().Contain("deploymentId: '${projectName}-${environment}'");

        azure.Should().NotContain("$Foundation.keyVaultUri");
        azure.Should().Contain(
            "kv-$($Config.projectName)-$($Config.environment).vault.azure.net");

        using var document = JsonDocument.Parse(example);
        document.RootElement.GetProperty("agent365")
            .GetProperty("allowDevelopmentRegistryPreview").GetBoolean().Should().BeFalse();
        document.RootElement.GetProperty("promptShield")
            .GetProperty("enabled").GetBoolean().Should().BeFalse();
    }

    [Fact]
    public void Bootstrap_ShouldKeepCustomScopeUriSeparateFromV2TokenAudience()
    {
        var azure = ReadRepositoryFile("bootstrap", "modules", "Azure.psm1");
        var entra = ReadRepositoryFile("bootstrap", "modules", "Entra.psm1");
        var experience = ReadRepositoryFile("bootstrap", "modules", "Experience.psm1");
        var preflight = ReadRepositoryFile(
            "operations", "test-provisioning-prerequisites.ps1");

        entra.Should().Contain("gatewayApiScopeBaseUri = $audience");
        entra.Should().Contain("gatewayApiTokenAudience = [string]$application.appId");
        azure.Should().Contain("entraIdAudience = [string]$Identity.gatewayApiTokenAudience");
        azure.Should().Contain(
            "adminUiGatewayApiScope = \"$($Identity.gatewayApiScopeBaseUri)/access_as_user\"");
        experience.Should().Contain(
            "'EntraId__Audience' = [string]$Identity.gatewayApiTokenAudience");
        experience.Should().Contain(
            "'GatewayApi__Scopes__0' = \"$($Identity.gatewayApiScopeBaseUri)/access_as_user\"");
        preflight.Should().Contain("-Audience $gatewayApiClientId");
        preflight.Should().Contain("$select=id,appId,api");
        preflight.Should().Contain("requestedAccessTokenVersion -ne 2");

        var liveVerification = ReadRepositoryFile("tools", "Gateway.LiveVerification", "Program.cs");
        liveVerification.Should().Contain("$\"{options.ApiScopeBaseUri}/access_as_user\"");
        liveVerification.Should().Contain("InteractiveBrowserCredential");
        liveVerification.Should().NotContain("$\"api://{options.ApiApplicationClientId:D}/.default\"");
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
