targetScope = 'resourceGroup'

@description('Existing bootstrap deployment ownership GUID; never creates or adopts a resource group.')
param deploymentOwnershipId string
@description('Preserved original bootstrap source fingerprint.')
param bootstrapSourceFingerprint string
@description('Reviewed executor implementation source fingerprint.')
param executionSourceFingerprint string
param location string
@minLength(2)
@maxLength(8)
param projectName string
@allowed(['dev', 'staging', 'prod'])
param environmentName string
param virtualNetworkName string
param privateEndpointSubnetId string
@description('Dedicated, unused App Service integration address range within the Gateway VNet.')
param executorSubnetPrefix string = '10.42.3.0/26'
param storageAccountName string
param keyVaultName string
param certificateName string
param executorApplicationId string
param workerApplicationId string
param workerPrincipalId string
@description('Runtime remains disabled until package, certificate and caller roles are independently ready.')
param enableRuntime bool = false
@description('Content-addressed package SHA256 without prefix. No SAS or other query string is accepted by orchestration.')
param packageSha256 string
param runtimeManifestDigest string
@description('Exact separately reviewed execution binding, excluding executorPrincipalId which is derived from the deployed system identity.')
param executionBinding object
param organization string

var suffix = '${projectName}-${environmentName}'
var executorName = 'app-${suffix}-purview-${take(uniqueString(resourceGroup().id), 6)}'
var tags = {
  application: 'a365-custom-gateway'
  managedBy: 'bootstrap'
  projectName: projectName
  environment: environmentName
  bootstrapOwnershipId: deploymentOwnershipId
  bootstrapSourceFingerprint: bootstrapSourceFingerprint
  purviewExecutionSourceFingerprint: executionSourceFingerprint
  workload: 'purview-windows-executor'
}
var binding = union(executionBinding, {
  DeploymentOwnershipId: deploymentOwnershipId
  TenantId: tenant().tenantId
  BootstrapSourceFingerprint: bootstrapSourceFingerprint
  ExecutionSourceFingerprint: executionSourceFingerprint
  PackageDigest: 'sha256:${packageSha256}'
  ExecutorApplicationId: executorApplicationId
  ExecutorPrincipalId: executor.identity.principalId
  GatewayWorkerPrincipalId: workerPrincipalId
  CallerApplicationId: workerApplicationId
  KeyVaultResourceId: vault.id
  CertificateName: certificateName
  CertificateSecretUri: 'https://${keyVaultName}.vault.azure.net/secrets/${certificateName}'
})

resource network 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: virtualNetworkName
}
resource integration 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: network
  name: 'snet-purview-executor'
  properties: {
    addressPrefix: executorSubnetPrefix
    delegations: [{
      name: 'Microsoft.Web.serverFarms'
      properties: { serviceName: 'Microsoft.Web/serverFarms' }
    }]
  }
}
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storage
  name: 'default'
}
resource packages 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: 'purview-executor-packages'
  properties: { publicAccess: 'None' }
}
resource claims 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: 'purview-executor-claims'
  properties: { publicAccess: 'None' }
}
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}
resource certificateSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = {
  parent: vault
  name: certificateName
}
resource plan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: 'asp-${suffix}-purview'
  location: location
  tags: tags
  kind: 'app'
  sku: { name: 'B1', tier: 'Basic', capacity: 1 }
  properties: { reserved: false, perSiteScaling: false, zoneRedundant: false }
}
resource executor 'Microsoft.Web/sites@2024-11-01' = {
  name: executorName
  location: location
  tags: tags
  kind: 'app'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    enabled: enableRuntime
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    clientAffinityEnabled: false
    virtualNetworkSubnetId: integration.id
    outboundVnetRouting: { allTraffic: true }
    siteConfig: {
      alwaysOn: true
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'
      remoteDebuggingEnabled: false
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      scmType: 'None'
      scmIpSecurityRestrictionsUseMain: true
      httpLoggingEnabled: false
      detailedErrorLoggingEnabled: false
      requestTracingEnabled: false
      numberOfWorkers: 1
    }
  }
}
resource auth 'Microsoft.Web/sites/config@2024-11-01' = {
  parent: executor
  name: 'authsettingsV2'
  properties: {
    platform: { enabled: true, runtimeVersion: '~1' }
    globalValidation: { requireAuthentication: true, unauthenticatedClientAction: 'Return401' }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: executorApplicationId
          openIdIssuer: 'https://login.microsoftonline.com/${tenant().tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [executorApplicationId]
          defaultAuthorizationPolicy: {
            allowedApplications: [workerApplicationId]
            allowedPrincipals: { identities: [workerPrincipalId] }
          }
        }
      }
    }
    login: { tokenStore: { enabled: false } }
    httpSettings: { requireHttps: true }
  }
}
resource publishingPolicies 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-11-01' = [for name in ['ftp', 'scm']: {
  parent: executor
  name: name
  properties: { allow: false }
}]
resource packageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(packages.id, executor.id, 'package-reader')
  scope: packages
  properties: {
    principalId: executor.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
  }
}
resource claimWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(claims.id, executor.id, 'claim-writer')
  scope: claims
  properties: {
    principalId: executor.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}
resource certificateReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(certificateSecret.id, executor.id, 'certificate-reader')
  scope: certificateSecret
  properties: {
    principalId: executor.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}
resource dns 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
  tags: tags
}
resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dns
  name: 'link-${suffix}-purview'
  location: 'global'
  properties: { registrationEnabled: false, virtualNetwork: { id: network.id } }
}
resource endpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${suffix}-purview'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [{
      name: 'purview-executor'
      properties: { privateLinkServiceId: executor.id, groupIds: ['sites'] }
    }]
  }
}
// Azure creates both app and SCM records in this private zone group.
resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: endpoint
  name: 'purviewExecutorDnsGroup'
  properties: {
    privateDnsZoneConfigs: [{ name: 'sites', properties: { privateDnsZoneId: dns.id } }]
  }
}
resource settings 'Microsoft.Web/sites/config@2024-11-01' = if (enableRuntime) {
  parent: executor
  name: 'appsettings'
  properties: union({
    WEBSITE_RUN_FROM_PACKAGE: '${storage.properties.primaryEndpoints.blob}${packages.name}/${packageSha256}.zip'
    WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID: 'SystemAssigned'
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'false'
    DOTNET_EnableDiagnostics: '0'
    ASPNETCORE_ENVIRONMENT: 'Production'
    Executor__ClaimsContainerUri: '${storage.properties.primaryEndpoints.blob}${claims.name}'
    Executor__RuntimeManifestDigest: runtimeManifestDigest
    Executor__OperationTimeoutSeconds: '195'
    Purview__PolicyProvisioningEnabled: 'true'
    Purview__PolicyProvisioningOrganization: organization
    Purview__PolicyProvisioningApplicationId: string(binding.AutomationApplicationId)
    Purview__PolicyProvisioningCertificateSecretUri: string(binding.CertificateSecretUri)
    Purview__PolicyProvisioningTimeoutSeconds: '180'
  }, toObject(items(binding), item => 'Executor__Binding__${item.key}', item => string(item.value)))
  dependsOn: [packageReader, claimWriter, certificateReader, auth, dnsGroup, dnsLink]
}

output executorId string = executor.id
output executorPrincipalId string = executor.identity.principalId
output executorEndpoint string = 'https://${executor.properties.defaultHostName}'
output executorBinding object = binding
output packageContainerId string = packages.id
output packageContainerUri string = '${storage.properties.primaryEndpoints.blob}${packages.name}'
output claimsContainerId string = claims.id
output privateEndpointId string = endpoint.id
output privateDnsZoneId string = dns.id
output integrationSubnetId string = integration.id
output packageReaderRoleId string = packageReader.id
output claimWriterRoleId string = claimWriter.id
output certificateReaderRoleId string = certificateReader.id
