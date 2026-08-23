using '../main.bicep'

param environment = 'dev'
param location = 'koreacentral'
param projectName = 'a365gw'

param entraIdTenantId = 'ff8b1e46-ff0f-4bc2-ab02-caf2b92da496'
param entraIdClientId = readEnvironmentVariable('ENTRA_CLIENT_ID', '00000000-0000-0000-0000-000000000000')
param entraIdAudience = readEnvironmentVariable('ENTRA_AUDIENCE', 'api://a365-gateway-dev')

param sqlAdminLogin = 'gatewayadmin'
param sqlAdminPassword = readEnvironmentVariable('SQL_ADMIN_PASSWORD', '')
param entraAdminObjectId = readEnvironmentVariable('ENTRA_ADMIN_OBJECT_ID', '00000000-0000-0000-0000-000000000000')
param entraAdminLogin = readEnvironmentVariable('ENTRA_ADMIN_LOGIN', 'gateway-admin@contoso.com')

param apiContainerImage = readEnvironmentVariable('API_IMAGE', 'mcr.microsoft.com/dotnet/aspnet:10.0')
param workerContainerImage = readEnvironmentVariable('WORKER_IMAGE', 'mcr.microsoft.com/dotnet/runtime:10.0')

param alertEmail = readEnvironmentVariable('ALERT_EMAIL', 'gateway-dev-alerts@contoso.com')

// Dev: smallest SKUs, no HA
param logRetentionInDays = 30
param acrSku = 'Basic'
param sqlSkuName = 'Basic'
param sqlSkuTier = 'Basic'
param serviceBusSku = 'Basic'
param storageSku = 'Standard_LRS'

param apiCpu = '0.5'
param apiMemory = '1Gi'
param apiMinReplicas = 0
param apiMaxReplicas = 3
param workerCpu = '0.25'
param workerMemory = '0.5Gi'
param workerMaxReplicas = 3

param zoneRedundant = false
param keyVaultPurgeProtection = true
