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

@description('Entra ID tenant ID.')
param entraIdTenantId string

@description('Entra ID client (application) ID for the Gateway API.')
param entraIdClientId string

@description('Entra ID audience for token validation.')
param entraIdAudience string

@description('SQL administrator login name (deploy-time only).')
param sqlAdminLogin string

@description('SQL administrator login password (deploy-time only).')
@secure()
param sqlAdminPassword string

@description('Entra ID object ID for the SQL AD administrator.')
param entraAdminObjectId string

@description('Entra ID display name for the SQL AD administrator.')
param entraAdminLogin string

@description('Container image for the Gateway API.')
param apiContainerImage string

@description('Container image for the Provisioning Worker.')
param workerContainerImage string

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

@description('Storage account SKU.')
param storageSku string = 'Standard_LRS'

@description('API Container App CPU cores.')
param apiCpu string = '0.5'

@description('API Container App memory.')
param apiMemory string = '1Gi'

@description('API Container App minimum replicas.')
param apiMinReplicas int = 0

@description('API Container App maximum replicas.')
param apiMaxReplicas int = 3

@description('Worker Container App CPU cores.')
param workerCpu string = '0.25'

@description('Worker Container App memory.')
param workerMemory string = '0.5Gi'

@description('Worker Container App maximum replicas.')
param workerMaxReplicas int = 3

@description('Enable zone redundancy for the Container Apps environment.')
param zoneRedundant bool = false

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
  workerApp: 'ca-gateway-worker-${environment}'
}

var tags = {
  project: 'a365-gateway'
  environment: environment
  managedBy: 'bicep'
}

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
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
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

module cae './modules/container-apps-environment.bicep' = {
  name: 'deploy-cae'
  params: {
    environmentName: names.cae
    location: location
    logAnalyticsCustomerId: logAnalytics.outputs.customerId
    logAnalyticsSharedKey: logAnalytics.outputs.sharedKey
    zoneRedundant: zoneRedundant
    tags: tags
  }
}

// ============================================================================
// Tier 3 — Container Apps (depend on Tier 1 + Tier 2)
// ============================================================================

module apiApp './modules/container-app-api.bicep' = {
  name: 'deploy-api-app'
  params: {
    appName: names.apiApp
    location: location
    environmentId: cae.outputs.environmentId
    containerImage: apiContainerImage
    acrLoginServer: acr.outputs.loginServer
    cpu: apiCpu
    memory: apiMemory
    minReplicas: apiMinReplicas
    maxReplicas: apiMaxReplicas
    sqlServerFqdn: sqlDb.outputs.serverFqdn
    sqlDatabaseName: sqlDb.outputs.databaseName
    serviceBusNamespace: serviceBus.outputs.namespaceFqdn
    keyVaultUri: keyVault.outputs.vaultUri
    appInsightsConnectionString: appInsights.outputs.connectionString
    blobStorageEndpoint: storage.outputs.blobEndpoint
    entraIdTenantId: entraIdTenantId
    entraIdClientId: entraIdClientId
    entraIdAudience: entraIdAudience
    tags: tags
  }
}

module workerApp './modules/container-app-worker.bicep' = {
  name: 'deploy-worker-app'
  params: {
    appName: names.workerApp
    location: location
    environmentId: cae.outputs.environmentId
    containerImage: workerContainerImage
    acrLoginServer: acr.outputs.loginServer
    cpu: workerCpu
    memory: workerMemory
    maxReplicas: workerMaxReplicas
    serviceBusNamespace: serviceBus.outputs.namespaceFqdn
    sqlServerFqdn: sqlDb.outputs.serverFqdn
    sqlDatabaseName: sqlDb.outputs.databaseName
    keyVaultUri: keyVault.outputs.vaultUri
    appInsightsConnectionString: appInsights.outputs.connectionString
    entraIdTenantId: entraIdTenantId
    tags: tags
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
    storageAccountName: names.storage
    serviceBusNamespaceName: names.serviceBus
    containerRegistryName: names.acr
  }
}

module alerts './modules/monitoring-alerts.bicep' = {
  name: 'deploy-monitoring-alerts'
  params: {
    appInsightsId: appInsights.outputs.appInsightsId
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    actionGroupEmail: alertEmail
    apiContainerAppName: names.apiApp
    workerContainerAppName: names.workerApp
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

@description('ACR login server URL.')
output acrLoginServer string = acr.outputs.loginServer

@description('Key Vault URI.')
output keyVaultUri string = keyVault.outputs.vaultUri

@description('SQL Server FQDN.')
output sqlServerFqdn string = sqlDb.outputs.serverFqdn
