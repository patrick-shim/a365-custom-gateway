using '../modules/container-app-worker.bicep'

param appName = 'ca-gateway-worker-dev-vnet'
param location = 'koreacentral'
param environmentId = readEnvironmentVariable('CONTAINER_APPS_ENVIRONMENT_ID')
param containerImage = readEnvironmentVariable('WORKER_IMAGE')
param acrLoginServer = 'acra365gwdevs4a3t2.azurecr.io'
param cpu = '0.25'
param memory = '0.5Gi'
param minReplicas = 0
param maxReplicas = 1
param maxConcurrentCalls = 1

param serviceBusNamespace = 'sb-a365gw-dev.servicebus.windows.net'
param serviceBusNamespaceName = 'sb-a365gw-dev'
param serviceBusQueueName = 'gateway-provisioning-v3'
param sqlServerFqdn = 'sql-a365gw-dev.database.windows.net'
param sqlDatabaseName = 'GatewayDb'
param keyVaultUri = 'https://kv-a365gw-dev.vault.azure.net/'
param appInsightsConnectionString = readEnvironmentVariable('APPLICATIONINSIGHTS_CONNECTION_STRING')
param entraIdTenantId = 'ff8b1e46-ff0f-4bc2-ab02-caf2b92da496'

param agent365ObservabilityServerAddress = 'ca-gateway-api-dev.mangodune-074310c6.koreacentral.azurecontainerapps.io'
param agent365GatewayApiApplicationClientId = 'a6f2a2af-6af6-4b46-9d93-a4aeb477bd83'
param agent365GatewayApiAudience = 'a6f2a2af-6af6-4b46-9d93-a4aeb477bd83'
param agent365GatewayApiBaseUrl = 'https://ca-gateway-api-dev.mangodune-074310c6.koreacentral.azurecontainerapps.io/'
param agent365CredentialKeyVaultUri = 'https://kv-a365gw-dev-prov.vault.azure.net/'
param agent365ProvisioningManagedIdentityPrincipalId = '05324839-0af7-43fc-ae4c-10c498abcabb'
param agent365ManagerApplicationIds = [
  'e8be65d6-d430-4289-a665-51bf2a194bda'
]

// Inert runtime baseline. Continuous development or an exact-bound rollout must
// explicitly enable processing through the reviewed deployment/controller path.
param processingEnabled = false
param provisioningExecutionEnabled = false
param agent365RegistryProvider = 'Disabled'
param agent365DirectRegistryPreviewEnabled = false
