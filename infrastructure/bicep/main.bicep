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

@description('Opaque bootstrap-run ownership identifier. The supported bootstrap supplies a random GUID and verifies this value on the deployment and every tagged workload resource before adopting prior work.')
param deploymentOwnershipId string = ''

@description('Canonical SHA-256 fingerprint of the content-addressed source snapshot accepted by the bootstrap plan. This is provenance metadata, not a credential.')
param bootstrapSourceFingerprint string = ''

@description('Enable bounded read-only runtime verification of the exact bootstrap database contract.')
param databaseAttestationEnabled bool = false

@description('Exact current reviewed GatewayDb schema fingerprint from bootstrap initialization.')
param databaseAttestationExpectedSchemaFingerprint string = ''

@description('Exact Gateway API database principal name.')
param databaseAttestationApiPrincipalName string = ''

@description('Exact Gateway API managed-identity client ID stored as the database principal SID.')
param databaseAttestationApiPrincipalClientId string = ''

@description('Exact Gateway worker database principal name.')
param databaseAttestationWorkerPrincipalName string = ''

@description('Exact Gateway worker managed-identity client ID stored as the database principal SID.')
param databaseAttestationWorkerPrincipalClientId string = ''

@description('Name of the approved existing VNet-integrated Container Apps environment shared by the API, worker, and Admin UI.')
@minLength(1)
param containerAppsEnvironmentName string

@description('Exact resource ID of the foundation-owned user-assigned identity used by API and worker for ACR image pulls. The all-empty value set is retained only for the guarded historical system-identity deployment path.')
param runtimeImagePullIdentityId string = ''

@description('Exact principal ID of the foundation-owned runtime image-pull identity.')
param runtimeImagePullIdentityPrincipalId string = ''

@description('Exact resource ID of the foundation-created AcrPull assignment for the runtime image-pull identity and ACR.')
param runtimeImagePullAcrPullRoleAssignmentId string = ''

@description('Explicitly authorize the retained system-assigned identity image-pull path for an independently verified existing deployment. Never enable this for clean bootstrap or a fresh private-image deployment.')
param allowLegacySystemAssignedImagePull bool = false

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

@description('Bare Gateway API client ID required by the Microsoft identity platform v2 aud claim.')
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

@description('Enable Service Bus processing on the current workflow worker after exact identity, network, queue, and database verification.')
param workerProcessingEnabled bool = false

@description('Allow Microsoft-side provisioning messages to execute. Keep false until the read-only identity, permission, provider, network, and legacy-job preflight succeeds.')
param provisioningExecutionEnabled bool = false

@description('Development-only mode that keeps authenticated registration and delegated completion available without per-request deployment windows. Ignored outside dev.')
param continuousDevelopmentProvisioningEnabled bool = false

@description('Acknowledge the user-delegated Registry completion capability in explicit continuous-development mode.')
param agent365DelegatedRegistryEnabled bool = false

@description('Operator confirmation that the independent Agent 365 managerApplications platform prerequisite was verified. This is a deployment acknowledgement, not a tenant permission grant.')
param agent365ManagerApplicationsPreflightConfirmed bool = false

@description('Microsoft first-party application IDs accepted by Agent 365 in blueprint managerApplications. Supply only IDs verified through the provider/bootstrap preflight; never invent one.')
@maxLength(10)
param agent365ManagerApplicationIds array = []

@description('Enable the Microsoft Purview Graph adapter only after tenant licensing, policy readback, token roles, and approved runtime verification succeed.')
param purviewEnabled bool = false

@description('Provision and enable Azure AI Content Safety Prompt Shields for synchronous prompt evaluation.')
param promptShieldEnabled bool = false

@allowed([
  'F0'
  'S0'
])
@description('Azure AI Content Safety SKU. Use S0 for normal deployments; F0 is development-only and subject to availability.')
param promptShieldSkuName string = 'S0'

@description('Enable automated Purview policy assignment: fixed tenant-wide Know Your Data Group plus blueprint-specific Individual DLP locations. Requires the reviewed app-only Security & Compliance PowerShell identity.')
param purviewPolicyProvisioningEnabled bool = false

@description('Microsoft 365 organization domain used by Purview policy automation.')
param purviewPolicyProvisioningOrganization string = ''

@description('Application/client ID of the certificate-authenticated Purview policy automation application.')
param purviewPolicyProvisioningApplicationId string = ''

@description('Versionless Key Vault secret URI containing the base64 PKCS#12 Purview automation certificate.')
param purviewPolicyProvisioningCertificateSecretUri string = ''

@description('Sensitive information type used by the reviewed default protection-profile rule.')
param purviewDefaultSensitiveInformationType string = 'Credit Card Number'

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
  storage: 'st${replace(suffix, '-', '')}${take(uniqueSuffix, 6)}'
  sqlServer: 'sql-${suffix}'
  sqlDatabase: 'GatewayDb'
  serviceBus: 'sb-${suffix}'
  cae: 'cae-${suffix}'
  apiApp: 'ca-gateway-api-${environment}'
  workerApp: empty(workerContainerAppName) ? 'ca-gateway-worker-${environment}' : workerContainerAppName
  adminUiApp: 'ca-gateway-admin-${environment}'
  adminUiIdentity: 'id-gateway-admin-${environment}'
  contentSafety: 'cs-${suffix}-${take(uniqueSuffix, 6)}'
}

var tags = {
  project: 'a365-gateway'
  environment: environment
  managedBy: 'bicep'
  projectName: projectName
  deploymentId: '${projectName}-${environment}'
  bootstrapOwnershipId: deploymentOwnershipId
  bootstrapSourceFingerprint: bootstrapSourceFingerprint
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

var purviewCertificateSecretName = empty(purviewPolicyProvisioningCertificateSecretUri)
  ? ''
  : last(split(purviewPolicyProvisioningCertificateSecretUri, '/'))

// Shared existing-environment deployments may retain the historical system-
// identity image-pull path only by supplying the explicit all-empty triple.
// Clean bootstrap always supplies all three foundation receipts. Any partial
// identity/role receipt set is ambiguous and blocks either workload Container App.
var runtimeImagePullIdentityInputsAreEmpty = empty(runtimeImagePullIdentityId) && empty(runtimeImagePullIdentityPrincipalId) && empty(runtimeImagePullAcrPullRoleAssignmentId)
var runtimeImagePullIdentityInputsArePopulated = !empty(runtimeImagePullIdentityId) && !empty(runtimeImagePullIdentityPrincipalId) && !empty(runtimeImagePullAcrPullRoleAssignmentId)
var bootstrapOwnedDeployment = !empty(deploymentOwnershipId) || !empty(bootstrapSourceFingerprint)
var runtimeImagePullAcrRoleAssignmentPrefix = '${toLower(acr.outputs.registryId)}/providers/microsoft.authorization/roleassignments/'
var runtimeImagesAreDeploymentAcrDigests = startsWith(toLower(apiContainerImage), '${toLower(acr.outputs.loginServer)}/') && contains(toLower(apiContainerImage), '@sha256:') && length(last(split(toLower(apiContainerImage), '@sha256:'))) == 64 && startsWith(toLower(workerContainerImage), '${toLower(acr.outputs.loginServer)}/') && contains(toLower(workerContainerImage), '@sha256:') && length(last(split(toLower(workerContainerImage), '@sha256:'))) == 64
var runtimeImagePullIdentityInputsAreTyped = runtimeImagePullIdentityInputsArePopulated && contains(toLower(runtimeImagePullIdentityId), '/providers/microsoft.managedidentity/userassignedidentities/') && startsWith(toLower(runtimeImagePullAcrPullRoleAssignmentId), runtimeImagePullAcrRoleAssignmentPrefix) && length(last(split(runtimeImagePullAcrPullRoleAssignmentId, '/'))) == 36 && length(runtimeImagePullIdentityPrincipalId) == 36 && runtimeImagesAreDeploymentAcrDigests
var runtimeImagePullContractMode = runtimeImagePullIdentityInputsAreEmpty && allowLegacySystemAssignedImagePull && !bootstrapOwnedDeployment && runtimeImagesAreDeploymentAcrDigests
  ? 'LegacySystemAssignedIdentity'
  : runtimeImagePullIdentityInputsAreTyped
    ? 'DedicatedUserAssignedIdentity'
    : 'InvalidPartialOrBootstrapIdentityEvidence'

// Fail closed even when main.bicep is invoked outside the guarded deployment
// scripts. Provisioning becomes effective only for the explicitly acknowledged
// development preview combination; shared observability remains independent.
var effectiveDelegatedRegistryEnabled = environment == 'dev' && agent365DelegatedRegistryEnabled
var effectiveWorkerProvisioningExecutionEnabled = provisioningExecutionEnabled && environment == 'dev' && workerProcessingEnabled && !empty(entraIdClientId) && !empty(agent365ProvisioningManagedIdentityPrincipalId) && length(agent365ManagerApplicationIds) > 0 && effectiveDelegatedRegistryEnabled && agent365ManagerApplicationsPreflightConfirmed
var effectiveContinuousDevelopmentProvisioningEnabled = effectiveWorkerProvisioningExecutionEnabled && continuousDevelopmentProvisioningEnabled
// Workflow v3 uses SQL-backed distributed ingress, idempotency, and per-job
// execution ownership. Registration/Registry admission does not override the
// configured API scale range.

// ============================================================================
// Tier 1 — Foundation Resources (no dependencies)
// ============================================================================

// This nested validation deployment has no provider resources. Its allowed-value
// contract blocks either workload Container App when receipts or immutable image
// hosts do not bind to the exact deployment ACR, when bootstrap attempts legacy
// mode, or when empty legacy mode lacks explicit authorization. Other independent
// foundation resources may deploy in parallel; the ACR output is validated first.
module runtimeImagePullContract './modules/runtime-image-pull-contract.bicep' = {
  name: 'validate-runtime-image-pull-contract'
  params: {
    // any() intentionally preserves runtime evaluation so the child template's
    // allowed-values contract remains the authoritative ARM validation boundary.
    mode: any(runtimeImagePullContractMode)
  }
}

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

module contentSafety './modules/content-safety.bicep' = if (promptShieldEnabled) {
  name: 'deploy-content-safety'
  params: {
    accountName: names.contentSafety
    location: location
    skuName: promptShieldSkuName
    tags: union(tags, {
      workload: 'prompt-protection'
    })
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
    runtimeImagePullContract
    workerApp
    storagePrivateEndpoint
  ]
  params: {
    appName: names.apiApp
    location: containerAppsEnvironment.location
    environmentId: containerAppsEnvironment.id
    containerImage: apiContainerImage
    acrLoginServer: acr.outputs.loginServer
    imagePullIdentityResourceId: runtimeImagePullIdentityId
    cpu: apiCpu
    memory: apiMemory
    minReplicas: apiMinReplicas
    maxReplicas: apiMaxReplicas
    sqlServerFqdn: sqlDb.outputs.serverFqdn
    sqlDatabaseName: sqlDb.outputs.databaseName
    serviceBusNamespace: serviceBus.outputs.namespaceFqdn
    serviceBusQueueName: serviceBus.outputs.queueName
    provisioningExecutionEnabled: effectiveContinuousDevelopmentProvisioningEnabled
    continuousDevelopmentProvisioningEnabled: effectiveContinuousDevelopmentProvisioningEnabled
    agent365DelegatedRegistryEnabled: effectiveContinuousDevelopmentProvisioningEnabled
    agent365DelegatedRegistryContinuousDevelopmentAccess: effectiveContinuousDevelopmentProvisioningEnabled
    keyVaultUri: keyVault.outputs.vaultUri
    blobStorageEndpoint: storage.outputs.blobEndpoint
    appInsightsConnectionString: appInsights.outputs.connectionString
    entraIdTenantId: entraIdTenantId
    entraIdClientId: entraIdClientId
    entraIdAudience: entraIdAudience
    agent365ManagerApplicationIds: agent365ManagerApplicationIds
    purviewEnabled: purviewEnabled
    promptShieldEnabled: promptShieldEnabled
    promptShieldEndpoint: promptShieldEnabled ? contentSafety!.outputs.endpoint : ''
    databaseAttestationEnabled: databaseAttestationEnabled
    databaseAttestationDeploymentOwnershipId: databaseAttestationEnabled ? deploymentOwnershipId : ''
    databaseAttestationAcceptedSourceFingerprint: databaseAttestationEnabled ? bootstrapSourceFingerprint : ''
    databaseAttestationExpectedSchemaFingerprint: databaseAttestationEnabled ? databaseAttestationExpectedSchemaFingerprint : ''
    databaseAttestationSqlServerFqdn: databaseAttestationEnabled ? sqlDb.outputs.serverFqdn : ''
    databaseAttestationDatabaseName: databaseAttestationEnabled ? sqlDb.outputs.databaseName : ''
    databaseAttestationApiPrincipalName: databaseAttestationEnabled ? databaseAttestationApiPrincipalName : ''
    databaseAttestationApiPrincipalClientId: databaseAttestationEnabled ? databaseAttestationApiPrincipalClientId : ''
    databaseAttestationWorkerPrincipalName: databaseAttestationEnabled ? databaseAttestationWorkerPrincipalName : ''
    databaseAttestationWorkerPrincipalClientId: databaseAttestationEnabled ? databaseAttestationWorkerPrincipalClientId : ''
    preservedConfigurationSecrets: preservedApiConfigurationSecrets
    tags: tags
  }
}

module workerApp './modules/container-app-worker.bicep' = {
  name: 'deploy-worker-app'
  dependsOn: [
    runtimeImagePullContract
  ]
  params: {
    appName: names.workerApp
    location: containerAppsEnvironment.location
    environmentId: containerAppsEnvironment.id
    containerImage: workerContainerImage
    acrLoginServer: acr.outputs.loginServer
    imagePullIdentityResourceId: runtimeImagePullIdentityId
    cpu: workerCpu
    memory: workerMemory
    // SQL session-owned job locks and idempotent provider discovery protect
    // duplicate delivery across the configured worker scale range.
    maxReplicas: workerMaxReplicas
    maxConcurrentCalls: 5
    serviceBusNamespace: serviceBus.outputs.namespaceFqdn
    serviceBusNamespaceName: serviceBus.outputs.namespaceName
    serviceBusQueueName: serviceBus.outputs.queueName
    sqlServerFqdn: sqlDb.outputs.serverFqdn
    sqlDatabaseName: sqlDb.outputs.databaseName
    keyVaultUri: keyVault.outputs.vaultUri
    appInsightsConnectionString: appInsights.outputs.connectionString
    entraIdTenantId: entraIdTenantId
    agent365ObservabilityServerAddress: '${names.apiApp}.${containerAppsEnvironment.properties.defaultDomain}'
    agent365ProvisioningManagedIdentityPrincipalId: agent365ProvisioningManagedIdentityPrincipalId
    agent365ManagerApplicationIds: agent365ManagerApplicationIds
    processingEnabled: workerProcessingEnabled
    provisioningExecutionEnabled: effectiveWorkerProvisioningExecutionEnabled
    purviewEnabled: purviewEnabled
    purviewPolicyProvisioningEnabled: purviewEnabled && purviewPolicyProvisioningEnabled
    purviewPolicyProvisioningOrganization: purviewPolicyProvisioningOrganization
    purviewPolicyProvisioningApplicationId: purviewPolicyProvisioningApplicationId
    purviewPolicyProvisioningCertificateSecretUri: purviewPolicyProvisioningCertificateSecretUri
    purviewDefaultSensitiveInformationType: purviewDefaultSensitiveInformationType
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
    enableWorkerKeyVaultSecretsUser: purviewEnabled && purviewPolicyProvisioningEnabled
    workerPurviewCertificateSecretName: purviewCertificateSecretName
    storageAccountName: names.storage
    serviceBusNamespaceName: names.serviceBus
    serviceBusQueueName: serviceBus.outputs.queueName
    containerRegistryName: names.acr
    enableLegacySystemAssignedAcrPull: runtimeImagePullIdentityInputsAreEmpty && allowLegacySystemAssignedImagePull && !bootstrapOwnedDeployment
  }
}

resource deployedContentSafety 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = if (promptShieldEnabled) {
  name: names.contentSafety
}

resource promptShieldCognitiveServicesUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (promptShieldEnabled) {
  name: guid(deployedContentSafety!.id, names.apiApp, 'Cognitive Services User')
  scope: deployedContentSafety
  properties: {
    principalId: apiApp.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'a97b65f3-24c7-4388-baec-2e87135dc908')
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

@description('Opaque bootstrap-run ownership identifier echoed for exact recovery binding.')
output deploymentOwnershipId string = deploymentOwnershipId

@description('Accepted bootstrap source fingerprint echoed for exact deployment recovery.')
output bootstrapSourceFingerprint string = bootstrapSourceFingerprint

@description('Whether the API runtime is configured for exact read-only bootstrap database attestation.')
output databaseAttestationEnabled bool = databaseAttestationEnabled

@description('Exact reviewed GatewayDb schema fingerprint supplied to runtime attestation.')
output databaseAttestationExpectedSchemaFingerprint string = databaseAttestationEnabled ? databaseAttestationExpectedSchemaFingerprint : ''

@description('Exact API database principal name supplied to runtime attestation.')
output databaseAttestationApiPrincipalName string = databaseAttestationEnabled ? databaseAttestationApiPrincipalName : ''

@description('Exact API database principal client ID supplied to runtime attestation.')
output databaseAttestationApiPrincipalClientId string = databaseAttestationEnabled ? databaseAttestationApiPrincipalClientId : ''

@description('Exact worker database principal name supplied to runtime attestation.')
output databaseAttestationWorkerPrincipalName string = databaseAttestationEnabled ? databaseAttestationWorkerPrincipalName : ''

@description('Exact worker database principal client ID supplied to runtime attestation.')
output databaseAttestationWorkerPrincipalClientId string = databaseAttestationEnabled ? databaseAttestationWorkerPrincipalClientId : ''

@description('Exact database name supplied to runtime attestation.')
output databaseAttestationDatabaseName string = databaseAttestationEnabled ? sqlDb.outputs.databaseName : ''

@description('Immutable Gateway API image reference supplied by the accepted bootstrap plan.')
output apiContainerImage string = apiContainerImage

@description('Immutable workflow-v3 worker image reference supplied by the accepted bootstrap plan.')
output workerContainerImage string = workerContainerImage

@description('FQDN of the Gateway API Container App.')
output apiFqdn string = apiApp.outputs.fqdn

@description('Principal ID of the API managed identity.')
output apiPrincipalId string = apiApp.outputs.principalId

@description('Principal ID of the Worker managed identity.')
output workerPrincipalId string = workerApp.outputs.principalId

@description('Resource ID of the dedicated user-assigned identity used by API and worker for ACR image pulls.')
output runtimeImagePullIdentityId string = runtimeImagePullIdentityId

@description('Principal ID of the dedicated user-assigned runtime image-pull identity.')
output runtimeImagePullIdentityPrincipalId string = runtimeImagePullIdentityPrincipalId

@description('Resource ID of the exact AcrPull assignment established before API and worker creation.')
output runtimeImagePullAcrPullRoleAssignmentId string = runtimeImagePullAcrPullRoleAssignmentId

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

@description('True only when the API delegated administrator Registry action is enabled in explicit continuous-development mode.')
output agent365DelegatedRegistryEnabled bool = apiApp.outputs.agent365DelegatedRegistryEnabled

@description('True only when the operator explicitly confirmed the independent managerApplications platform prerequisite for this deployment.')
output agent365ManagerApplicationsPreflightConfirmed bool = agent365ManagerApplicationsPreflightConfirmed

@description('Configured minimum number of API replicas.')
output apiMinReplicas int = apiMinReplicas

@description('Configured maximum number of API replicas.')
output apiMaxReplicas int = apiMaxReplicas

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

@description('Provisioning remains blocked until a tenant administrator verifies worker Graph application roles, Gateway API delegated Registry consent and OBO federation, and managerApplications.')
output provisioningTenantAdminAction string = 'Verify the listed worker Graph application roles, grant tenant-wide delegated Registry consent to the Gateway API, configure its exact managed-identity OBO FIC, and confirm managerApplications. This deployment does not mutate Entra tenant configuration.'

@description('Provisioning concurrency is protected by SQL session-owned job locks and duplicate-safe provider discovery across replicas.')
output provisioningConcurrencyCaveat string = effectiveWorkerProvisioningExecutionEnabled
  ? 'Provisioning execution enabled with SQL session-owned job locks and duplicate-safe provider discovery across replicas.'
  : 'Provisioning execution disabled; SQL session-owned job locks remain active when workflow-v3 processing is enabled.'

@description('Service Bus queue used by the current N:N API outbox publisher and worker. Historical workers must remain on their legacy queue during cutover.')
output serviceBusQueueName string = serviceBus.outputs.queueName

@description('Dead-letter queue recovery remains a separate, explicitly authorized operation after topology, code, and identity validation.')
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

@description('Resource ID of the exact ACR used by the runtime identities.')
output containerRegistryId string = acr.outputs.registryId

@description('Key Vault URI.')
output keyVaultUri string = keyVault.outputs.vaultUri

@description('Resource ID of the shared Key Vault used for exact role-assignment verification.')
output sharedKeyVaultId string = keyVault.outputs.vaultId

@description('Resource ID of the interaction-content Storage Account used by the runtime identities.')
output storageAccountId string = storage.outputs.storageAccountId

@description('Resource ID of the exact workflow-v3 queue used by the runtime identities.')
output serviceBusQueueId string = serviceBus.outputs.queueId

@description('Azure AI Content Safety endpoint when Prompt Shields is enabled.')
output promptShieldEndpoint string = promptShieldEnabled ? contentSafety!.outputs.endpoint : ''

@description('Azure AI Content Safety resource ID when Prompt Shields is enabled.')
output promptShieldAccountId string = promptShieldEnabled ? contentSafety!.outputs.accountId : ''

@description('Azure AI Content Safety account name when Prompt Shields is enabled.')
output promptShieldAccountName string = promptShieldEnabled ? contentSafety!.outputs.accountName : ''

@description('SQL Server FQDN.')
output sqlServerFqdn string = sqlDb.outputs.serverFqdn
