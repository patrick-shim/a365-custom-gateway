// ============================================================================
// A365 Custom Gateway - Admin UI-only deployment
// Deploys no API, worker, data, or messaging resources.
// ============================================================================

targetScope = 'resourceGroup'

@description('Deployment environment.')
@allowed([
  'dev'
  'staging'
  'prod'
])
param environment string

@description('Project name used by the existing main deployment.')
param projectName string = 'a365gw'

@description('Random bootstrap-state ownership GUID used for exact deployment and resource adoption checks.')
@minLength(36)
@maxLength(36)
param deploymentOwnershipId string

@description('Canonical SHA-256 fingerprint of the content-addressed source snapshot accepted by the bootstrap plan. This is provenance metadata, not a credential.')
@minLength(71)
@maxLength(71)
param bootstrapSourceFingerprint string

@description('Optional canonical SHA-256 fingerprint of a separately accepted Admin UI-only upgrade. When set, it is applied only to Admin UI resources and does not replace the original bootstrap source provenance.')
@minLength(0)
@maxLength(71)
param adminUiUpgradeSourceFingerprint string = ''

@description('Name of the existing Container Apps environment that hosts the deployed Gateway API (for example, cae-a365gw-dev-vnet).')
@minLength(1)
param containerAppsEnvironmentName string

@description('Container image for the Admin UI.')
@minLength(1)
param adminUiContainerImage string

@description('Microsoft Entra tenant ID for the single-tenant Admin UI application.')
@minLength(1)
param entraIdTenantId string

@description('Microsoft Entra client/application ID for the Admin UI application registration.')
@minLength(1)
param adminUiEntraClientId string

@description('Versionless Key Vault secret URI containing the Admin UI Entra client secret.')
@secure()
@minLength(1)
param adminUiEntraClientSecretKeyVaultSecretUri string

@description('Delegated Gateway API scope requested by the Admin UI.')
@minLength(1)
param adminUiGatewayApiScope string

@description('Create a Key Vault private endpoint for a vault that disables public network access.')
param deployKeyVaultPrivateEndpoint bool = false

@description('Resource ID of a subnet dedicated to private endpoints. Required when deployKeyVaultPrivateEndpoint is true.')
param keyVaultPrivateEndpointSubnetId string = ''

@description('Resource ID of the virtual network used by the Container Apps environment. Required when deployKeyVaultPrivateEndpoint is true.')
param keyVaultPrivateDnsVirtualNetworkId string = ''

@description('CPU cores allocated to the Admin UI Container App.')
param adminUiCpu string = '0.5'

@description('Memory allocated to the Admin UI Container App.')
param adminUiMemory string = '1Gi'

@description('Minimum number of Admin UI replicas.')
@minValue(1)
param adminUiMinReplicas int = 1

@description('Maximum number of Admin UI replicas. Keep at one until shared Data Protection keys are configured.')
@minValue(1)
param adminUiMaxReplicas int = 1

var suffix = '${projectName}-${environment}'
var uniqueSuffix = uniqueString(resourceGroup().id, projectName, environment)
var names = {
  acr: 'acr${replace(suffix, '-', '')}${take(uniqueSuffix, 6)}'
  keyVault: 'kv-${suffix}'
  apiApp: 'ca-gateway-api-${environment}'
  adminUiApp: 'ca-gateway-admin-${environment}'
  adminUiIdentity: 'id-gateway-admin-${environment}'
}

var tags = {
  project: 'a365-gateway'
  environment: environment
  managedBy: 'bicep'
  projectName: projectName
  deploymentId: '${projectName}-${environment}'
  workload: 'admin-ui'
  bootstrapOwnershipId: deploymentOwnershipId
  bootstrapSourceFingerprint: bootstrapSourceFingerprint
}

var adminUiTags = union(tags, empty(adminUiUpgradeSourceFingerprint) ? {} : {
  adminUiUpgradeSourceFingerprint: adminUiUpgradeSourceFingerprint
})

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: names.acr
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: names.keyVault
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

resource apiApp 'Microsoft.App/containerApps@2024-03-01' existing = {
  name: names.apiApp
}

module keyVaultPrivateEndpoint './modules/key-vault-private-endpoint.bicep' = if (deployKeyVaultPrivateEndpoint) {
  name: 'deploy-admin-ui-key-vault-private-endpoint'
  params: {
    privateEndpointName: 'pe-${names.keyVault}'
    location: containerAppsEnvironment.location
    keyVaultName: keyVault.name
    subnetId: keyVaultPrivateEndpointSubnetId
    virtualNetworkId: keyVaultPrivateDnsVirtualNetworkId
    virtualNetworkLinkName: 'link-${projectName}-${environment}-key-vault'
    tags: tags
  }
}

module adminUiApp './modules/container-app-admin-ui.bicep' = {
  name: 'deploy-admin-ui-app'
  params: {
    appName: names.adminUiApp
    identityName: names.adminUiIdentity
    location: containerAppsEnvironment.location
    environmentId: containerAppsEnvironment.id
    containerImage: adminUiContainerImage
    acrLoginServer: acr.properties.loginServer
    containerRegistryName: acr.name
    keyVaultName: keyVault.name
    entraClientSecretKeyVaultSecretUri: adminUiEntraClientSecretKeyVaultSecretUri
    entraTenantId: entraIdTenantId
    entraClientId: adminUiEntraClientId
    gatewayApiScope: adminUiGatewayApiScope
    gatewayApiBaseUrl: 'https://${apiApp.properties.configuration.ingress.fqdn}/'
    cpu: adminUiCpu
    memory: adminUiMemory
    minReplicas: adminUiMinReplicas
    maxReplicas: adminUiMaxReplicas
    tags: adminUiTags
  }
  dependsOn: [
    keyVaultPrivateEndpoint
  ]
}

@description('FQDN of the Admin UI Container App.')
output adminUiFqdn string = adminUiApp.outputs.fqdn

@description('HTTPS URL of the Admin UI.')
output adminUiUrl string = adminUiApp.outputs.url

@description('Required Entra redirect URI for sign-in.')
output adminUiSignInRedirectUri string = adminUiApp.outputs.signInRedirectUri

@description('Required Entra redirect URI for signed-out callbacks.')
output adminUiSignedOutCallbackUri string = adminUiApp.outputs.signedOutCallbackUri

@description('Principal ID of the Admin UI deployment identity.')
output adminUiPrincipalId string = adminUiApp.outputs.principalId

@description('Random bootstrap-state ownership GUID echoed for exact recovery binding.')
output deploymentOwnershipId string = deploymentOwnershipId

@description('Accepted bootstrap source fingerprint echoed for exact deployment recovery.')
output bootstrapSourceFingerprint string = bootstrapSourceFingerprint

@description('Immutable Admin UI image reference supplied by the accepted bootstrap plan.')
output adminUiContainerImage string = adminUiContainerImage

@description('Separate Admin UI-only upgrade source fingerprint, or an empty string for the original bootstrap deployment.')
output adminUiUpgradeSourceFingerprint string = adminUiUpgradeSourceFingerprint
