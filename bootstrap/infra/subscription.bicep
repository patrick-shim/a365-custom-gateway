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

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    application: 'a365-custom-gateway'
    environment: environment
    managedBy: 'bootstrap'
  }
}

module foundation './foundation.bicep' = {
  name: 'bootstrap-foundation-${environment}'
  scope: resourceGroup
  params: {
    environment: environment
    location: location
    projectName: projectName
  }
}

output resourceGroupId string = resourceGroup.id
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
