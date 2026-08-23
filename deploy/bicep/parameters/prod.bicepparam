using '../main.bicep'

param environment = 'prod'
param location = 'koreacentral'
param projectName = 'a365gw'

param entraIdTenantId = 'ff8b1e46-ff0f-4bc2-ab02-caf2b92da496'
param entraIdClientId = readEnvironmentVariable('ENTRA_CLIENT_ID', '00000000-0000-0000-0000-000000000000')
param entraIdAudience = readEnvironmentVariable('ENTRA_AUDIENCE', 'api://a365-gateway')

param sqlAdminLogin = 'gatewayadmin'
param sqlAdminPassword = readEnvironmentVariable('SQL_ADMIN_PASSWORD', '')
param entraAdminObjectId = readEnvironmentVariable('ENTRA_ADMIN_OBJECT_ID', '00000000-0000-0000-0000-000000000000')
param entraAdminLogin = readEnvironmentVariable('ENTRA_ADMIN_LOGIN', 'gateway-admin@contoso.com')

param apiContainerImage = readEnvironmentVariable('API_IMAGE', 'mcr.microsoft.com/dotnet/aspnet:10.0')
param workerContainerImage = readEnvironmentVariable('WORKER_IMAGE', 'mcr.microsoft.com/dotnet/runtime:10.0')

param alertEmail = readEnvironmentVariable('ALERT_EMAIL', 'gateway-prod-alerts@contoso.com')

// Prod: production-grade SKUs, full HA
param logRetentionInDays = 90
param acrSku = 'Standard'
param sqlSkuName = 'S2'
param sqlSkuTier = 'Standard'
param serviceBusSku = 'Standard'
param storageSku = 'Standard_GRS'

param apiCpu = '1.0'
param apiMemory = '2Gi'
param apiMinReplicas = 2
param apiMaxReplicas = 10
param workerCpu = '0.5'
param workerMemory = '1Gi'
param workerMaxReplicas = 5

param zoneRedundant = true
param keyVaultPurgeProtection = true
