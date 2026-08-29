// ============================================================================
// A365 provisioning worker blue/green bootstrap
//
// This template intentionally scopes the first deployment to a NEW, inert worker,
// its dedicated credential vault, and Azure RBAC. It treats every shared Gateway
// resource as existing and cannot update the historical worker, API, SQL, Service
// Bus, storage, ACR, shared Key Vault, or Container Apps environment.
// ============================================================================

targetScope = 'resourceGroup'

@description('The only environment currently authorized for a real provisioning canary.')
@allowed([
  'dev'
])
param environment string = 'dev'

@description('Project name used by the existing main deployment.')
param projectName string = 'a365gw'

@description('Approved existing VNet-integrated Container Apps environment.')
@minLength(1)
param containerAppsEnvironmentName string

@description('New blue/green worker name. It must not be the historical worker name.')
@allowed([
  'ca-gateway-worker-dev-vnet'
])
param workerContainerAppName string = 'ca-gateway-worker-dev-vnet'

@description('Public, non-operational image used only to create the system identity before AcrPull exists.')
param workerBootstrapImage string = 'mcr.microsoft.com/dotnet/runtime:10.0'

@description('Microsoft Entra tenant ID.')
@minLength(1)
param entraIdTenantId string

@description('Existing Gateway API application/client ID used for ExternalAgent role assignment and the exact v2 token audience.')
@minLength(1)
param gatewayApiApplicationClientId string

@description('Enable purge protection on the dedicated provisioning credential vault.')
param keyVaultPurgeProtection bool = true

@description('Legacy-only Key Vault Secrets Officer grant. Workflow v3 bootstrap defaults this off.')
param enableLegacyWorkerCredentialKeyVaultSecretsOfficer bool = false

var suffix = '${projectName}-${environment}'
var uniqueSuffix = uniqueString(resourceGroup().id, projectName, environment)
var names = {
  logAnalytics: 'log-${suffix}'
  appInsights: 'ai-${suffix}'
  acr: 'acr${replace(suffix, '-', '')}${take(uniqueSuffix, 6)}'
  sharedKeyVault: 'kv-${suffix}'
  provisioningKeyVault: 'kv-${suffix}-prov'
  sqlServer: 'sql-${suffix}'
  sqlDatabase: 'GatewayDb'
  serviceBus: 'sb-${suffix}'
  apiApp: 'ca-gateway-api-${environment}'
}

var tags = {
  project: 'a365-gateway'
  environment: environment
  managedBy: 'bicep'
  rollout: 'provisioning-blue-green-bootstrap'
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: names.logAnalytics
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: names.appInsights
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: names.acr
}

resource sharedKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: names.sharedKeyVault
}

resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' existing = {
  name: names.sqlServer
}

resource serviceBus 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' existing = {
  name: names.serviceBus
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

resource apiApp 'Microsoft.App/containerApps@2024-03-01' existing = {
  name: names.apiApp
}

module provisioningKeyVault './modules/key-vault.bicep' = {
  name: 'bootstrap-provisioning-key-vault'
  params: {
    vaultName: names.provisioningKeyVault
    location: containerAppsEnvironment.location
    tenantId: entraIdTenantId
    enablePurgeProtection: keyVaultPurgeProtection
    tags: union(tags, {
      workload: 'provisioning-credentials'
    })
    logAnalyticsWorkspaceId: logAnalytics.id
  }
}

module workerApp './modules/container-app-worker.bicep' = {
  name: 'bootstrap-provisioning-worker'
  params: {
    appName: workerContainerAppName
    location: containerAppsEnvironment.location
    environmentId: containerAppsEnvironment.id
    containerImage: workerBootstrapImage
    acrLoginServer: acr.properties.loginServer
    cpu: '0.25'
    memory: '0.5Gi'
    minReplicas: 0
    maxReplicas: 1
    maxConcurrentCalls: 1
    serviceBusNamespace: '${serviceBus.name}.servicebus.windows.net'
    serviceBusNamespaceName: serviceBus.name
    sqlServerFqdn: sqlServer.properties.fullyQualifiedDomainName
    sqlDatabaseName: names.sqlDatabase
    keyVaultUri: sharedKeyVault.properties.vaultUri
    appInsightsConnectionString: appInsights.properties.ConnectionString
    entraIdTenantId: entraIdTenantId
    agent365ObservabilityServerAddress: apiApp.properties.configuration.ingress.fqdn
    agent365GatewayApiApplicationClientId: gatewayApiApplicationClientId
    agent365GatewayApiAudience: gatewayApiApplicationClientId
    agent365GatewayApiBaseUrl: 'https://${apiApp.properties.configuration.ingress.fqdn}/'
    agent365CredentialKeyVaultUri: provisioningKeyVault.outputs.vaultUri
    agent365ManagerApplicationIds: []
    processingEnabled: false
    provisioningExecutionEnabled: false
    agent365RegistryProvider: 'Disabled'
    agent365DirectRegistryPreviewEnabled: false
    tags: union(tags, {
      workload: 'provisioning-worker'
    })
  }
}

module roleAssignments './modules/role-assignments-worker-bootstrap.bicep' = {
  name: 'bootstrap-provisioning-worker-role-assignments'
  params: {
    workerPrincipalId: workerApp.outputs.principalId
    workerCredentialKeyVaultName: names.provisioningKeyVault
    enableWorkerCredentialKeyVaultSecretsOfficer: enableLegacyWorkerCredentialKeyVaultSecretsOfficer
    containerRegistryName: acr.name
  }
}

@description('New worker name. The historical worker is not changed by this template.')
output workerContainerAppName string = workerApp.outputs.appName

@description('New worker managed-identity object ID.')
output workerPrincipalId string = workerApp.outputs.principalId

@description('Dedicated provisioning credential vault URI.')
output provisioningKeyVaultUri string = provisioningKeyVault.outputs.vaultUri

@description('Bootstrap invariant: shared processing is disabled.')
output workerProcessingEnabled bool = false

@description('Bootstrap invariant: Microsoft-side provisioning is disabled.')
output provisioningExecutionEnabled bool = false
