using '../modules/container-app-api.bicep'

param appName = 'ca-gateway-api-dev'
param location = 'koreacentral'
param environmentId = readEnvironmentVariable('CONTAINER_APPS_ENVIRONMENT_ID')
param containerImage = readEnvironmentVariable('API_IMAGE')
param acrLoginServer = 'acra365gwdevs4a3t2.azurecr.io'
param cpu = '0.5'
param memory = '1Gi'
param minReplicas = 1
param maxReplicas = 1
param targetPort = 8080

param sqlServerFqdn = 'sql-a365gw-dev.database.windows.net'
param sqlDatabaseName = 'GatewayDb'
param serviceBusNamespace = 'sb-a365gw-dev.servicebus.windows.net'
param serviceBusQueueName = 'gateway-provisioning-v3'
param provisioningExecutionEnabled = false
param provisioningAuthorizedExternalAgentId = ''
param provisioningAuthorizedRetryAgentId = ''
param agent365DelegatedRegistryEnabled = false
param agent365DelegatedRegistryActionExpiresAtUtc = ''
param agent365DelegatedRegistryAuthorizedOperationId = ''
param keyVaultUri = 'https://kv-a365gw-dev.vault.azure.net/'
param appInsightsConnectionString = readEnvironmentVariable('APPLICATIONINSIGHTS_CONNECTION_STRING')
param blobStorageEndpoint = 'https://sta365gwdevs4a3t2.blob.core.windows.net/'
param blobStorageContainerName = 'a365-gateway-interactions'

param entraIdTenantId = 'ff8b1e46-ff0f-4bc2-ab02-caf2b92da496'
param entraIdClientId = 'a6f2a2af-6af6-4b46-9d93-a4aeb477bd83'
param entraIdAudience = 'a6f2a2af-6af6-4b46-9d93-a4aeb477bd83'
param agent365ManagerApplicationIds = [
  'e8be65d6-d430-4289-a665-51bf2a194bda'
]

// Fail-closed runtime baseline. A reviewed deployment/controller invocation must
// explicitly enable Purview after tenant policy, licensing, and Graph roles pass.
param purviewEnabled = false
param preservedConfigurationSecrets = {}
