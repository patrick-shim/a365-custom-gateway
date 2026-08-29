using '../main.bicep'

param environment = 'prod'
param location = 'koreacentral'
param projectName = 'a365gw'
param containerAppsEnvironmentName = readEnvironmentVariable('CONTAINER_APPS_ENVIRONMENT_NAME', 'cae-a365gw-prod-vnet')
param virtualNetworkName = readEnvironmentVariable('VIRTUAL_NETWORK_NAME', 'vnet-a365gw-prod')
param privateEndpointSubnetName = readEnvironmentVariable('PRIVATE_ENDPOINT_SUBNET_NAME', 'snet-private-endpoints')
// Existing-environment compatibility is the explicit all-empty triple. Supply
// all three foundation receipts together to use the dedicated pull identity.
param runtimeImagePullIdentityId = readEnvironmentVariable('RUNTIME_IMAGE_PULL_IDENTITY_ID', '')
param runtimeImagePullIdentityPrincipalId = readEnvironmentVariable('RUNTIME_IMAGE_PULL_IDENTITY_PRINCIPAL_ID', '')
param runtimeImagePullAcrPullRoleAssignmentId = readEnvironmentVariable('RUNTIME_IMAGE_PULL_ACR_PULL_ROLE_ASSIGNMENT_ID', '')
param allowLegacySystemAssignedImagePull = readEnvironmentVariable('ALLOW_LEGACY_SYSTEM_ASSIGNED_IMAGE_PULL', 'false') == 'true'

param entraIdTenantId = 'ff8b1e46-ff0f-4bc2-ab02-caf2b92da496'
param entraIdClientId = readEnvironmentVariable('ENTRA_CLIENT_ID', '00000000-0000-0000-0000-000000000000')
// Microsoft identity platform v2 access tokens use the bare API client ID as aud.
param entraIdAudience = readEnvironmentVariable('ENTRA_AUDIENCE', readEnvironmentVariable('ENTRA_CLIENT_ID', '00000000-0000-0000-0000-000000000000'))

param entraAdminObjectId = readEnvironmentVariable('ENTRA_ADMIN_OBJECT_ID', '00000000-0000-0000-0000-000000000000')
param entraAdminLogin = readEnvironmentVariable('ENTRA_ADMIN_LOGIN', 'gateway-admin@contoso.com')

param apiContainerImage = readEnvironmentVariable('API_IMAGE', 'mcr.microsoft.com/dotnet/aspnet:10.0')
param workerContainerImage = readEnvironmentVariable('WORKER_IMAGE', 'mcr.microsoft.com/dotnet/runtime:10.0')
param historicalWorkerContainerAppName = 'ca-gateway-worker-prod'
param preserveExistingApiSecrets = true
param workerProcessingEnabled = false
param enableLegacyWorkerCredentialKeyVaultSecretsOfficer = false
param provisioningExecutionEnabled = false
param continuousDevelopmentProvisioningEnabled = false
param provisioningAuthorizedExternalAgentId = ''
param provisioningAuthorizedRetryAgentId = ''
param agent365RegistryProvider = 'Disabled'
param agent365DirectRegistryPreviewEnabled = false
param agent365DelegatedRegistryEnabled = false
param agent365DelegatedRegistryActionExpiresAtUtc = ''
param agent365DelegatedRegistryAuthorizedOperationId = ''
param agent365ManagerApplicationsPreflightConfirmed = false
param agent365ManagerApplicationIds = json(readEnvironmentVariable('AGENT365_MANAGER_APPLICATION_IDS_JSON', '[]'))
param purviewEnabled = false
param promptShieldEnabled = false
// Admin UI is opt-in here so the existing API/worker deployment remains unchanged.
param deployAdminUi = readEnvironmentVariable('DEPLOY_ADMIN_UI', 'false') == 'true'
param adminUiContainerImage = readEnvironmentVariable('ADMIN_UI_IMAGE', '')
param adminUiEntraClientId = readEnvironmentVariable('ADMIN_UI_ENTRA_CLIENT_ID', '')
param adminUiEntraClientSecretKeyVaultSecretUri = readEnvironmentVariable('ADMIN_UI_CLIENT_SECRET_KEY_VAULT_URI', '')
param adminUiGatewayApiScope = readEnvironmentVariable('ADMIN_UI_GATEWAY_API_SCOPE', '')

param alertEmail = readEnvironmentVariable('ALERT_EMAIL', 'gateway-prod-alerts@contoso.com')

// Prod: production-grade SKUs, full HA
param logRetentionInDays = 90
param acrSku = 'Standard'
param sqlSkuName = 'S2'
param sqlSkuTier = 'Standard'
param serviceBusSku = 'Standard'
param serviceBusQueueName = readEnvironmentVariable('PROVISIONING_QUEUE_NAME', 'gateway-provisioning-v3')
param storageSku = 'Standard_GRS'

param apiCpu = '1.0'
param apiMemory = '2Gi'
param apiMinReplicas = 2
param apiMaxReplicas = 10
param workerCpu = '0.5'
param workerMemory = '1Gi'
param workerMaxReplicas = 5
param adminUiCpu = '1.0'
param adminUiMemory = '2Gi'
param adminUiMinReplicas = 1
param adminUiMaxReplicas = 1

param keyVaultPurgeProtection = true
