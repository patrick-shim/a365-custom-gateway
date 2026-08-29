targetScope = 'subscription'

@description('Resource group that will contain the Gateway.')
@minLength(1)
param resourceGroupName string

@description('Azure region for the resource group and foundation.')
param location string

@description('Deployment environment.')
@allowed([
  'dev'
  'staging'
  'prod'
])
param environment string

@description('Short project name used in resource names.')
param projectName string = 'a365gw'

@description('Random bootstrap-state ownership GUID used to reject adoption of pre-existing resources.')
@minLength(36)
@maxLength(36)
param deploymentOwnershipId string

@description('Canonical source fingerprint accepted by the bootstrap plan and propagated to the resource group and foundation resources.')
@minLength(71)
@maxLength(71)
param bootstrapSourceFingerprint string

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    application: 'a365-custom-gateway'
    environment: environment
    managedBy: 'bootstrap'
    projectName: projectName
    deploymentId: '${projectName}-${environment}'
    bootstrapOwnershipId: deploymentOwnershipId
    bootstrapSourceFingerprint: bootstrapSourceFingerprint
  }
}

module foundation './foundation.bicep' = {
  name: 'bootstrap-foundation-${projectName}-${environment}'
  scope: resourceGroup
  params: {
    environment: environment
    location: location
    projectName: projectName
    deploymentOwnershipId: deploymentOwnershipId
    bootstrapSourceFingerprint: bootstrapSourceFingerprint
  }
}

output resourceGroupId string = resourceGroup.id
output deploymentOwnershipId string = deploymentOwnershipId
output bootstrapSourceFingerprint string = bootstrapSourceFingerprint
output resourceGroupName string = resourceGroup.name
output containerAppsEnvironmentName string = foundation.outputs.containerAppsEnvironmentName
output containerAppsEnvironmentId string = foundation.outputs.containerAppsEnvironmentId
output virtualNetworkName string = foundation.outputs.virtualNetworkName
output virtualNetworkId string = foundation.outputs.virtualNetworkId
output privateEndpointSubnetName string = foundation.outputs.privateEndpointSubnetName
output privateEndpointSubnetId string = foundation.outputs.privateEndpointSubnetId
output logAnalyticsWorkspaceName string = foundation.outputs.logAnalyticsWorkspaceName
output acrLoginServer string = foundation.outputs.acrLoginServer
output acrName string = foundation.outputs.acrName
output runtimeImagePullIdentityId string = foundation.outputs.runtimeImagePullIdentityId
output runtimeImagePullIdentityPrincipalId string = foundation.outputs.runtimeImagePullIdentityPrincipalId
output runtimeImagePullAcrPullRoleAssignmentId string = foundation.outputs.runtimeImagePullAcrPullRoleAssignmentId
