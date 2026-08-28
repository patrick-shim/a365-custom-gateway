targetScope = 'resourceGroup'

@description('Deployment environment.')
@allowed([
  'dev'
  'staging'
  'prod'
])
param environment string

@description('Azure region for the foundation resources.')
param location string

@description('Short project name used in resource names.')
@minLength(2)
@maxLength(8)
param projectName string = 'a365gw'

@description('Address prefix for the dedicated Gateway virtual network.')
param virtualNetworkAddressPrefix string = '10.42.0.0/16'

@description('Address prefix for Container Apps infrastructure. /23 is the minimum supported size for workload profiles.')
param containerAppsInfrastructureSubnetPrefix string = '10.42.0.0/23'

@description('Address prefix for private endpoints.')
param privateEndpointSubnetPrefix string = '10.42.2.0/24'

var suffix = '${projectName}-${environment}'
var uniqueSuffix = uniqueString(resourceGroup().id, projectName, environment)
var tags = {
  application: 'a365-custom-gateway'
  environment: environment
  managedBy: 'bootstrap'
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-${suffix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        virtualNetworkAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-container-apps'
        properties: {
          addressPrefix: containerAppsInfrastructureSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

module containerRegistry '../../infrastructure/bicep/modules/container-registry.bicep' = {
  name: 'bootstrap-container-registry'
  params: {
    registryName: 'acr${replace(suffix, '-', '')}${take(uniqueSuffix, 6)}'
    location: location
    sku: 'Basic'
    adminUserEnabled: false
    logAnalyticsWorkspaceId: logAnalytics.id
    tags: tags
  }
}

module containerAppsEnvironment '../../infrastructure/bicep/modules/container-apps-environment.bicep' = {
  name: 'bootstrap-container-apps-environment'
  params: {
    environmentName: 'cae-${suffix}-vnet'
    location: location
    logAnalyticsCustomerId: logAnalytics.properties.customerId
    logAnalyticsSharedKey: logAnalytics.listKeys().primarySharedKey
    infrastructureSubnetId: virtualNetwork.properties.subnets[0].id
    internalEnvironment: false
    tags: tags
  }
}

output containerAppsEnvironmentName string = containerAppsEnvironment.outputs.environmentName
output containerAppsEnvironmentId string = containerAppsEnvironment.outputs.environmentId
output virtualNetworkName string = virtualNetwork.name
output virtualNetworkId string = virtualNetwork.id
output privateEndpointSubnetName string = 'snet-private-endpoints'
output privateEndpointSubnetId string = virtualNetwork.properties.subnets[1].id
output logAnalyticsWorkspaceName string = logAnalytics.name
output acrLoginServer string = containerRegistry.outputs.loginServer
output acrName string = containerRegistry.outputs.registryName
