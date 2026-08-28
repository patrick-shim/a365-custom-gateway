// ============================================================================
// A365 Custom Gateway — Main Deployment Orchestrator
// ============================================================================

targetScope = 'resourceGroup'

// ============================================================================
// Parameters
// ============================================================================

@description('Deployment environment.')
@allowed([
  'dev'
  'staging'
  'prod'
])
param environment string

@description('Azure region for all resources.')
param location string

@description('Project name used in resource naming.')
param projectName string = 'a365gw'

@description('Name of the approved existing VNet-integrated Container Apps environment shared by the API, worker, and Admin UI.')
@minLength(1)
param containerAppsEnvironmentName string

@description('Name of the existing virtual network used by the Container Apps environment and private dependencies.')
@minLength(1)
param virtualNetworkName string = 'vnet-${projectName}-${environment}'

@description('Name of the existing subnet dedicated to private endpoints.')
@minLength(1)
param privateEndpointSubnetName string = 'snet-private-endpoints'

@description('Entra ID tenant ID.')
param entraIdTenantId string

@description('Entra ID client (application) ID for the Gateway API.')
param entraIdClientId string

@description('Entra ID audience for token validation.')
param entraIdAudience string

@description('Entra ID object ID for the SQL AD administrator.')
param entraAdminObjectId string

@description('Entra ID display name for the SQL AD administrator.')
param entraAdminLogin string

@description('Container image for the Gateway API.')
param apiContainerImage string

@description('Container image for the Provisioning Worker.')
param workerContainerImage string

@description('Optional Provisioning Worker Container App name. Use a new name for a non-destructive VNet migration; empty preserves the conventional name.')
param workerContainerAppName string = ''

@description('Object/principal ID of the target worker system-assigned managed identity. Required before the provisioning execution gate can become effective and injected so the worker can verify its own Graph caller identity.')
param agent365ProvisioningManagedIdentityPrincipalId string = ''

@description('Historical Provisioning Worker Container App name retained during a blue/green migration. Provisioning-failure alerts cover this app and the target worker independently.')
param historicalWorkerContainerAppName string = 'ca-gateway-worker-${environment}'

@description('Preserve existing API Container App secrets during the full ARM create-or-update operation. Keep true for every update; set false explicitly only when creating the API app for the first time.')
param preserveExistingApiSecrets bool = true

@description('Enable Service Bus processing on the current workflow worker. Keep false for inert-first deployment and enable only through the bounded canary controller.')
param workerProcessingEnabled bool = false

@description('Legacy-only switch granting the worker Key Vault Secrets Officer on the provisioning credential vault. Workflow v3 defaults this off.')
param enableLegacyWorkerCredentialKeyVaultSecretsOfficer bool = false

@description('Allow Microsoft-side provisioning messages to execute. Keep false until the read-only identity, permission, provider, network, and legacy-job preflight succeeds.')
param provisioningExecutionEnabled bool = false

@description('Development-only mode that keeps authenticated registration and delegated completion available without per-request deployment windows. Ignored outside dev.')
param continuousDevelopmentProvisioningEnabled bool = false

@description('Explicit UTC ISO-8601 deadline for API registration admission. Required in addition to provisioningExecutionEnabled; the API independently rejects missing, malformed, non-UTC, or expired values.')
param provisioningAdmissionExpiresAtUtc string = ''

@description('Exact external agent ID authorized for initial registration. Mutually exclusive with retry and delegated-completion bindings.')
param provisioningAuthorizedExternalAgentId string = ''

@description('Exact Gateway registration ID authorized for a reviewed retry window. Keep empty unless exact-bound retry is intended.')
param provisioningAuthorizedRetryAgentId string = ''

@description('Agent 365 registry provider. DirectRegistryPreview is development-only and must be combined with both explicit execution gates.')
@allowed([
  'Disabled'
  'DirectRegistryPreview'
])
param agent365RegistryProvider string = 'Disabled'

@description('Explicit acknowledgement that the unsupported-for-production Microsoft Graph beta registry provider may run in development.')
param agent365DirectRegistryPreviewEnabled bool = false

@description('Acknowledge the user-delegated Registry completion capability. The effective API action still requires its own operation binding and expiry.')
param agent365DelegatedRegistryEnabled bool = false

@description('Independent UTC expiry for the delegated Registry completion action.')
param agent365DelegatedRegistryActionExpiresAtUtc string = ''

@description('Exact provisioning operation ID authorized for delegated Registry completion.')
param agent365DelegatedRegistryAuthorizedOperationId string = ''

@description('Operator confirmation that the independent Agent 365 managerApplications platform prerequisite was verified. This is a deployment acknowledgement, not a tenant permission grant.')
param agent365ManagerApplicationsPreflightConfirmed bool = false

@description('Microsoft first-party application IDs accepted by Agent 365 in blueprint managerApplications. Supply only IDs verified through the provider/bootstrap preflight; never invent one.')
@maxLength(10)
param agent365ManagerApplicationIds array = []

@description('Enable the globally configured Microsoft Purview Graph adapter. Keep false until tenant licensing, policies, all three Graph app roles, and a synthetic canary are verified.')
param purviewEnabled bool = false

@description('Deploy the Admin UI Container App. Disabled by default so existing API/worker deployments are unchanged.')
param deployAdminUi bool = false

@description('Container image for the Admin UI. Required when deployAdminUi is true.')
param adminUiContainerImage string = ''

@description('Entra ID client (application) ID for the Admin UI app registration. Required when deployAdminUi is true.')
param adminUiEntraClientId string = ''

@description('Versionless Key Vault secret URI containing the Admin UI Entra client secret. Required when deployAdminUi is true.')
@secure()
param adminUiEntraClientSecretKeyVaultSecretUri string = ''

@description('Delegated Gateway API scope requested by the Admin UI. Required when deployAdminUi is true.')
param adminUiGatewayApiScope string = ''

@description('Email address for alert notifications.')
param alertEmail string

@description('Log Analytics data retention in days.')
param logRetentionInDays int = 30

@description('Container Registry SKU.')
param acrSku string = 'Basic'

@description('SQL database SKU name.')
param sqlSkuName string = 'Basic'

@description('SQL database SKU tier.')
param sqlSkuTier string = 'Basic'

@description('Service Bus namespace SKU.')
param serviceBusSku string = 'Basic'

@description('Service Bus queue used exclusively by the current N:N workflow. Keep historical workers on their legacy queue during a blue/green cutover.')
param serviceBusQueueName string = 'gateway-provisioning-v3'

@description('Storage account SKU.')
param storageSku string = 'Standard_LRS'

@description('API Container App CPU cores.')
param apiCpu string = '0.5'

@description('API Container App memory.')
param apiMemory string = '1Gi'

@description('API Container App minimum replicas.')
@minValue(1)
param apiMinReplicas int = 1

@description('API Container App maximum replicas.')
param apiMaxReplicas int = 3

@description('Worker Container App CPU cores.')
param workerCpu string = '0.25'

@description('Worker Container App memory.')
param workerMemory string = '0.5Gi'

@description('Worker Container App maximum replicas.')
param workerMaxReplicas int = 3

@description('Admin UI Container App CPU cores.')
param adminUiCpu string = '0.5'

@description('Admin UI Container App memory.')
param adminUiMemory string = '1Gi'

@description('Admin UI Container App minimum replicas.')
@minValue(1)
param adminUiMinReplicas int = 1

@description('Admin UI Container App maximum replicas. Keep at one until shared Data Protection keys are configured.')
@minValue(1)
param adminUiMaxReplicas int = 1

@description('Enable purge protection on Key Vault.')
param keyVaultPurgeProtection bool = true

// ============================================================================
// Variables — Naming Convention
// ============================================================================

var suffix = '${projectName}-${environment}'
var uniqueSuffix = uniqueString(resourceGroup().id, projectName, environment)

var names = {
  logAnalytics: 'log-${suffix}'
  appInsights: 'ai-${suffix}'
  acr: 'acr${replace(suffix, '-', '')}${take(uniqueSuffix, 6)}'
  keyVault: 'kv-${suffix}'
  provisioningKeyVault: 'kv-${suffix}-prov'
  storage: 'st${replace(suffix, '-', '')}${take(uniqueSuffix, 6)}'
  sqlServer: 'sql-${suffix}'
  sqlDatabase: 'GatewayDb'
  serviceBus: 'sb-${suffix}'
  cae: 'cae-${suffix}'
  apiApp: 'ca-gateway-api-${environment}'
  workerApp: empty(workerContainerAppName) ? 'ca-gateway-worker-${environment}' : workerContainerAppName
  adminUiApp: 'ca-gateway-admin-${environment}'
  adminUiIdentity: 'id-gateway-admin-${environment}'
}

var tags = {
  project: 'a365-gateway'
  environment: environment
  managedBy: 'bicep'
}

var requiredWorkerGraphApplicationPermissions = [
  'Application.Read.All'
  'AppRoleAssignment.ReadWrite.All'
  'AgentIdentityBlueprint.Create'
  'AgentIdentityBlueprint.AddRemoveCreds.All'
  'AgentIdentityBlueprintPrincipal.Create'
  'AgentIdentityBlueprint.Read.All'
  'AgentIdentity.Create.All'
  'AgentIdentity.Read.All'
]

var requiredApiGraphApplicationPermissions = [
  'AgentIdentityBlueprint.Read.All'
]

var legacyWorkerKeyVaultRoleName = 'Key Vault Secrets Officer'

// Fail closed even when main.bicep is invoked outside the guarded deployment
// scripts. Provisioning becomes effective only for the explicitly acknowledged
// development preview combination; shared observability remains independent.
var effectiveDelegatedRegistryEnabled = environment == 'dev' && agent365RegistryProvider == 'DirectRegistryPreview' && agent365DirectRegistryPreviewEnabled && agent365DelegatedRegistryEnabled
var effectiveWorkerProvisioningExecutionEnabled = provisioningExecutionEnabled && environment == 'dev' && workerProcessingEnabled && !empty(entraIdClientId) && !empty(agent365ProvisioningManagedIdentityPrincipalId) && length(agent365ManagerApplicationIds) > 0 && effectiveDelegatedRegistryEnabled && agent365ManagerApplicationsPreflightConfirmed
var effectiveContinuousDevelopmentProvisioningEnabled = effectiveWorkerProvisioningExecutionEnabled && continuousDevelopmentProvisioningEnabled
var hasRegistrationBinding = !empty(provisioningAuthorizedExternalAgentId) && empty(provisioningAuthorizedRetryAgentId)
var hasRetryBinding = empty(provisioningAuthorizedExternalAgentId) && !empty(provisioningAuthorizedRetryAgentId)
var effectiveApiProvisioningAdmissionEnabled = effectiveWorkerProvisioningExecutionEnabled && (effectiveContinuousDevelopmentProvisioningEnabled || (!empty(provisioningAdmissionExpiresAtUtc) && (hasRegistrationBinding || hasRetryBinding) && empty(agent365DelegatedRegistryActionExpiresAtUtc) && empty(agent365DelegatedRegistryAuthorizedOperationId)))
var effectiveApiDelegatedRegistryActionEnabled = effectiveWorkerProvisioningExecutionEnabled && effectiveDelegatedRegistryEnabled && (effectiveContinuousDevelopmentProvisioningEnabled || (empty(provisioningAdmissionExpiresAtUtc) && empty(provisioningAuthorizedExternalAgentId) && empty(provisioningAuthorizedRetryAgentId) && !empty(agent365DelegatedRegistryActionExpiresAtUtc) && !empty(agent365DelegatedRegistryAuthorizedOperationId)))
var effectiveApiBoundedActionEnabled = effectiveApiProvisioningAdmissionEnabled || effectiveApiDelegatedRegistryActionEnabled

// Workflow v3 has SQL-backed distributed ingress, idempotency, and per-job
// execution ownership. The beta Registry development canary remains at one API
// replica as a rollout containment choice, not as the concurrency correctness
// mechanism.
var effectiveApiMinReplicas = effectiveApiBoundedActionEnabled ? 1 : apiMinReplicas
var effectiveApiMaxReplicas = effectiveApiBoundedActionEnabled ? 1 : apiMaxReplicas

// ============================================================================
// Tier 1 — Foundation Resources (no dependencies)
// ============================================================================

module logAnalytics './modules/log-analytics.bicep' = {
  name: 'deploy-log-analytics'
  params: {
    workspaceName: names.logAnalytics
    location: location
    retentionInDays: logRetentionInDays
    tags: tags
  }
}

module acr './modules/container-registry.bicep' = {
  name: 'deploy-acr'
  params: {
    registryName: names.acr
    location: location
    sku: acrSku
    tags: tags
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

module keyVault './modules/key-vault.bicep' = {
  name: 'deploy-key-vault'
  params: {
    vaultName: names.keyVault
    location: location
    tenantId: entraIdTenantId
    enablePurgeProtection: keyVaultPurgeProtection
    tags: tags
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

module provisioningKeyVault './modules/key-vault.bicep' = {
  name: 'deploy-provisioning-key-vault'
  params: {
    vaultName: names.provisioningKeyVault
    location: location
    tenantId: entraIdTenantId
    enablePurgeProtection: keyVaultPurgeProtection
    tags: union(tags, {
      workload: 'provisioning-credentials'
    })
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

module storage './modules/storage-account.bicep' = {
  name: 'deploy-storage'
  params: {
    storageAccountName: names.storage
    location: location
    sku: storageSku
    tags: tags
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

module sqlDb './modules/sql-database.bicep' = {
  name: 'deploy-sql'
  params: {
    serverName: names.sqlServer
    databaseName: names.sqlDatabase
    location: location
    entraAdminObjectId: entraAdminObjectId
    entraAdminLogin: entraAdminLogin
    skuName: sqlSkuName
    skuTier: sqlSkuTier
    tags: tags
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

module serviceBus './modules/service-bus.bicep' = {
  name: 'deploy-service-bus'
  params: {
    namespaceName: names.serviceBus
    location: location
    sku: serviceBusSku
    queueName: serviceBusQueueName
    tags: tags
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

// ============================================================================
// Tier 2 — Depends on Log Analytics
// ============================================================================

module appInsights './modules/app-insights.bicep' = {
  name: 'deploy-app-insights'
  params: {
    appInsightsName: names.appInsights
    location: location
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    tags: tags
  }
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: virtualNetworkName
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: virtualNetwork
  name: privateEndpointSubnetName
}

module storagePrivateEndpoint './modules/storage-private-endpoint.bicep' = {
  name: 'deploy-storage-private-endpoint'
  dependsOn: [
    storage
  ]
  params: {
    privateEndpointName: 'pe-${names.storage}-blob'
    location: location
    storageAccountName: names.storage
    subnetId: privateEndpointSubnet.id
    virtualNetworkId: virtualNetwork.id
    virtualNetworkLinkName: 'link-${projectName}-${environment}-storage'
    tags: union(tags, {
      workload: 'interaction-content'
    })
  }
}

// Container Apps secrets are application-scoped and their values are write-only
// on ordinary GET operations. A full ARM PUT can otherwise clear the collection.
// listSecrets is evaluated only when preservation is enabled, and its result is
// passed directly to a secure module parameter without becoming an output.
resource existingApiContainerApp 'Microsoft.App/containerApps@2024-03-01' existing = {
  name: names.apiApp
}

var preservedApiConfigurationSecrets = preserveExistingApiSecrets
  ? {
      value: existingApiContainerApp.listSecrets().value
    }
  : {}

// ============================================================================
// Tier 3 — Container Apps (depend on Tier 1 + Tier 2)
// ============================================================================

module apiApp './modules/container-app-api.bicep' = {
  name: 'deploy-api-app'
  dependsOn: [
    workerApp
    storagePrivateEndpoint
  ]
  params: {
    appName: names.apiApp
    location: containerAppsEnvironment.location
    environmentId: containerAppsEnvironment.id
    containerImage: apiContainerImage
    acrLoginServer: acr.outputs.loginServer
    cpu: apiCpu
    memory: apiMemory
    minReplicas: effectiveApiMinReplicas
    maxReplicas: effectiveApiMaxReplicas
    sqlServerFqdn: sqlDb.outputs.serverFqdn
    sqlDatabaseName: sqlDb.outputs.databaseName
    serviceBusNamespace: serviceBus.outputs.namespaceFqdn
    serviceBusQueueName: serviceBus.outputs.queueName
    provisioningExecutionEnabled: effectiveApiProvisioningAdmissionEnabled
    continuousDevelopmentProvisioningEnabled: effectiveContinuousDevelopmentProvisioningEnabled
    provisioningAdmissionExpiresAtUtc: effectiveApiProvisioningAdmissionEnabled ? provisioningAdmissionExpiresAtUtc : ''
    provisioningAuthorizedExternalAgentId: effectiveApiProvisioningAdmissionEnabled ? provisioningAuthorizedExternalAgentId : ''
    provisioningAuthorizedRetryAgentId: effectiveApiProvisioningAdmissionEnabled ? provisioningAuthorizedRetryAgentId : ''
    agent365DelegatedRegistryEnabled: effectiveApiDelegatedRegistryActionEnabled
    agent365DelegatedRegistryContinuousDevelopmentAccess: effectiveContinuousDevelopmentProvisioningEnabled
    agent365DelegatedRegistryActionExpiresAtUtc: effectiveApiDelegatedRegistryActionEnabled ? agent365DelegatedRegistryActionExpiresAtUtc : ''
    agent365DelegatedRegistryAuthorizedOperationId: effectiveApiDelegatedRegistryActionEnabled ? agent365DelegatedRegistryAuthorizedOperationId : ''
    keyVaultUri: keyVault.outputs.vaultUri
    blobStorageEndpoint: storage.outputs.blobEndpoint
    appInsightsConnectionString: appInsights.outputs.connectionString
    entraIdTenantId: entraIdTenantId
    entraIdClientId: entraIdClientId
    entraIdAudience: entraIdAudience
    agent365ManagerApplicationIds: agent365ManagerApplicationIds
    purviewEnabled: purviewEnabled
    preservedConfigurationSecrets: preservedApiConfigurationSecrets
    tags: tags
  }
}

module workerApp './modules/container-app-worker.bicep' = {
  name: 'deploy-worker-app'
  params: {
    appName: names.workerApp
    location: containerAppsEnvironment.location
    environmentId: containerAppsEnvironment.id
    containerImage: workerContainerImage
    acrLoginServer: acr.outputs.loginServer
    cpu: workerCpu
    memory: workerMemory
    // Duplicate detection is unavailable on the current Basic Service Bus tier.
    // Contain the bounded development canary to one message callback at a time.
    maxReplicas: effectiveWorkerProvisioningExecutionEnabled ? 1 : workerMaxReplicas
    maxConcurrentCalls: effectiveWorkerProvisioningExecutionEnabled ? 1 : 5
    serviceBusNamespace: serviceBus.outputs.namespaceFqdn
    serviceBusNamespaceName: serviceBus.outputs.namespaceName
    serviceBusQueueName: serviceBus.outputs.queueName
    sqlServerFqdn: sqlDb.outputs.serverFqdn
    sqlDatabaseName: sqlDb.outputs.databaseName
    keyVaultUri: keyVault.outputs.vaultUri
    appInsightsConnectionString: appInsights.outputs.connectionString
    entraIdTenantId: entraIdTenantId
    agent365ObservabilityServerAddress: '${names.apiApp}.${containerAppsEnvironment.properties.defaultDomain}'
    agent365GatewayApiApplicationClientId: entraIdClientId
    agent365GatewayApiAudience: entraIdAudience
    agent365GatewayApiBaseUrl: 'https://${names.apiApp}.${containerAppsEnvironment.properties.defaultDomain}/'
    agent365CredentialKeyVaultUri: provisioningKeyVault.outputs.vaultUri
    agent365ProvisioningManagedIdentityPrincipalId: agent365ProvisioningManagedIdentityPrincipalId
    agent365ManagerApplicationIds: agent365ManagerApplicationIds
    processingEnabled: workerProcessingEnabled
    provisioningExecutionEnabled: effectiveWorkerProvisioningExecutionEnabled
    agent365RegistryProvider: agent365RegistryProvider
    agent365DirectRegistryPreviewEnabled: agent365DirectRegistryPreviewEnabled
    tags: tags
  }
}

module adminUiApp './modules/container-app-admin-ui.bicep' = if (deployAdminUi) {
  name: 'deploy-admin-ui-app'
  params: {
    appName: names.adminUiApp
    identityName: names.adminUiIdentity
    location: containerAppsEnvironment.location
    environmentId: containerAppsEnvironment.id
    containerImage: adminUiContainerImage
    acrLoginServer: acr.outputs.loginServer
    containerRegistryName: acr.outputs.registryName
    keyVaultName: keyVault.outputs.vaultName
    entraClientSecretKeyVaultSecretUri: adminUiEntraClientSecretKeyVaultSecretUri
    entraTenantId: entraIdTenantId
    entraClientId: adminUiEntraClientId
    gatewayApiScope: adminUiGatewayApiScope
    gatewayApiBaseUrl: 'https://${apiApp.outputs.fqdn}/'
    cpu: adminUiCpu
    memory: adminUiMemory
    minReplicas: adminUiMinReplicas
    maxReplicas: adminUiMaxReplicas
    tags: union(tags, {
      workload: 'admin-ui'
    })
  }
}

// ============================================================================
// Tier 4 — Post-compute (depend on managed identity principal IDs)
// ============================================================================

module roleAssignments './modules/role-assignments.bicep' = {
  name: 'deploy-role-assignments'
  params: {
    apiPrincipalId: apiApp.outputs.principalId
    workerPrincipalId: workerApp.outputs.principalId
    keyVaultName: names.keyVault
    workerCredentialKeyVaultName: names.provisioningKeyVault
    enableWorkerCredentialKeyVaultSecretsOfficer: enableLegacyWorkerCredentialKeyVaultSecretsOfficer
    storageAccountName: names.storage
    serviceBusNamespaceName: names.serviceBus
    serviceBusQueueName: serviceBus.outputs.queueName
    containerRegistryName: names.acr
  }
}

module alerts './modules/monitoring-alerts.bicep' = {
  name: 'deploy-monitoring-alerts'
  dependsOn: [
    sqlDb
    serviceBus
    keyVault
  ]
  params: {
    appInsightsId: appInsights.outputs.appInsightsId
    actionGroupEmail: alertEmail
    apiContainerAppName: names.apiApp
    historicalWorkerContainerAppName: historicalWorkerContainerAppName
    targetWorkerContainerAppName: names.workerApp
    serviceBusNamespaceName: names.serviceBus
    sqlServerName: names.sqlServer
    keyVaultName: names.keyVault
    environment: environment
    location: location
    tags: tags
  }
}

// ============================================================================
// Outputs (no secrets)
// ============================================================================

@description('FQDN of the Gateway API Container App.')
output apiFqdn string = apiApp.outputs.fqdn

@description('Principal ID of the API managed identity.')
output apiPrincipalId string = apiApp.outputs.principalId

@description('Principal ID of the Worker managed identity.')
output workerPrincipalId string = workerApp.outputs.principalId

@description('Approved Container Apps environment used by the API, worker, and optional Admin UI.')
output containerAppsEnvironmentName string = containerAppsEnvironment.name

@description('True when the approved existing Container Apps environment reports an infrastructure subnet.')
output containerAppsEnvironmentVnetIntegrated bool = !empty(containerAppsEnvironment.properties.vnetConfiguration.infrastructureSubnetId)

@description('Resource ID of the private endpoint used for Blob interaction-content access.')
output storageBlobPrivateEndpointId string = storagePrivateEndpoint.outputs.privateEndpointId

@description('Resource ID of the Blob private DNS zone linked to the Gateway virtual network.')
output storageBlobPrivateDnsZoneId string = storagePrivateEndpoint.outputs.privateDnsZoneId

@description('Public network access state for the Gateway Storage Account.')
output storagePublicNetworkAccess string = storage.outputs.publicNetworkAccess

@description('True when shared worker processing, including observability, remains active.')
output workerProcessingEnabled bool = workerApp.outputs.processingEnabled

@description('True only when the provisioning-specific execution gate was explicitly enabled for this deployment.')
output provisioningExecutionEnabled bool = workerApp.outputs.provisioningExecutionEnabled

@description('True only when API provisioning admission is enabled with a non-empty server-enforced expiry input. The API additionally validates UTC syntax and freshness at request time.')
output provisioningAdmissionEnabled bool = effectiveApiProvisioningAdmissionEnabled

@description('Effective Agent 365 registry provider configuration.')
output agent365RegistryProvider string = workerApp.outputs.agent365RegistryProvider

@description('True only when the explicit DirectRegistryPreview acknowledgement was enabled for this deployment.')
output agent365DirectRegistryPreviewEnabled bool = workerApp.outputs.agent365DirectRegistryPreviewEnabled

@description('True only when the API delegated administrator Registry action is armed inside the bounded development admission window.')
output agent365DelegatedRegistryEnabled bool = apiApp.outputs.agent365DelegatedRegistryEnabled

@description('True only when the operator explicitly confirmed the independent managerApplications platform prerequisite for this deployment.')
output agent365ManagerApplicationsPreflightConfirmed bool = agent365ManagerApplicationsPreflightConfirmed

@description('Effective minimum number of API replicas. The beta Registry development canary is deliberately forced to one.')
output apiMinReplicas int = effectiveApiMinReplicas

@description('Effective maximum number of API replicas. The beta Registry development canary is deliberately forced to one after distributed controls are in place.')
output apiMaxReplicas int = effectiveApiMaxReplicas

@description('Effective maximum number of worker replicas.')
output workerMaxReplicas int = workerApp.outputs.maxReplicas

@description('Effective maximum concurrent Service Bus callbacks per worker replica.')
output workerMaxConcurrentCalls int = workerApp.outputs.maxConcurrentCalls

@description('Microsoft Graph application permissions that a tenant administrator must verify on the worker managed identity before enabling provisioning. Registry permissions are deliberately excluded because Registry creation uses API OBO.')
output requiredWorkerGraphApplicationPermissions array = requiredWorkerGraphApplicationPermissions

@description('Microsoft Graph delegated scopes that require admin consent on the Gateway API for user-delegated Registry completion.')
output requiredApiGraphDelegatedRegistryScopes array = [
  'AgentRegistration.ReadWrite.All'
  'AgentRegistration.Read.All'
]

@description('Microsoft Graph application permissions that a tenant administrator must verify on the API managed identity before the reusable-blueprint inventory can load.')
output requiredApiGraphApplicationPermissions array = requiredApiGraphApplicationPermissions

@description('Legacy worker Key Vault role. Workflow v3 does not deploy or require it unless the explicit legacy switch is enabled.')
output requiredWorkerKeyVaultRole string = enableLegacyWorkerCredentialKeyVaultSecretsOfficer ? legacyWorkerKeyVaultRoleName : 'Not required for workflow v3'

@description('True only when the explicit legacy worker credential-vault role switch is enabled.')
output legacyWorkerCredentialKeyVaultRoleEnabled bool = enableLegacyWorkerCredentialKeyVaultSecretsOfficer

@description('Provisioning remains blocked until a tenant administrator verifies worker Graph application roles, Gateway API delegated Registry consent and OBO federation, and managerApplications.')
output provisioningTenantAdminAction string = 'Verify the listed worker Graph application roles, grant tenant-wide delegated Registry consent to the Gateway API, configure its exact managed-identity OBO FIC, and confirm managerApplications. This deployment does not mutate Entra tenant configuration.'

@description('Provisioning canaries are constrained to one replica and one callback as rollout containment. SQL session-owned application locks provide cross-replica ownership of each workflow-v3 job.')
output provisioningConcurrencyCaveat string = effectiveWorkerProvisioningExecutionEnabled
  ? 'Development canary constrained to one replica and one callback; SQL session-owned application locks serialize each workflow-v3 job across replicas.'
  : 'Provisioning execution disabled; SQL session-owned application locks remain active when workflow-v3 processing is enabled.'

@description('Service Bus queue used by the current N:N API outbox publisher and worker. Historical workers must remain on their legacy queue during cutover.')
output serviceBusQueueName string = serviceBus.outputs.queueName

@description('Dead-letter queue recovery remains a separate, explicitly authorized operation after topology, code, identity, and canary validation.')
output deadLetterQueueRecoveryGate string = 'Do not receive, peek, settle, replay, or purge retained workflow-v2 or historical provisioning messages during deployment.'

@description('Worker Container Apps covered by provisioning-failure monitoring during the blue/green transition.')
output provisioningAlertWorkerContainerAppNames array = union([
  historicalWorkerContainerAppName
], [
  names.workerApp
])

@description('FQDN of the Admin UI Container App when deployAdminUi is true.')
output adminUiFqdn string = adminUiApp.?outputs.fqdn ?? ''

@description('Required Admin UI Entra sign-in redirect URI when deployAdminUi is true.')
output adminUiSignInRedirectUri string = adminUiApp.?outputs.signInRedirectUri ?? ''

@description('Required Admin UI Entra signed-out callback URI when deployAdminUi is true.')
output adminUiSignedOutCallbackUri string = adminUiApp.?outputs.signedOutCallbackUri ?? ''

@description('ACR login server URL.')
output acrLoginServer string = acr.outputs.loginServer

@description('Key Vault URI.')
output keyVaultUri string = keyVault.outputs.vaultUri

@description('SQL Server FQDN.')
output sqlServerFqdn string = sqlDb.outputs.serverFqdn
