// ============================================================================
// Module: Container Apps Environment
// Purpose: Managed hosting environment for Container Apps in the A365 Custom Gateway
// ============================================================================

@description('Name of the Container Apps environment.')
param environmentName string

@description('Azure region for the resource.')
param location string

@description('Log Analytics workspace customer ID for application logging.')
param logAnalyticsCustomerId string

@description('Log Analytics workspace shared key for application logging.')
@secure()
param logAnalyticsSharedKey string

@description('Enable zone redundancy for the environment.')
param zoneRedundant bool = false

@description('Resource ID of the delegated infrastructure subnet. A non-VNet Container Apps environment is not supported because SQL and Key Vault use private endpoints.')
@minLength(1)
param infrastructureSubnetId string

@description('Create an internal-only Container Apps environment.')
param internalEnvironment bool = false

@description('Tags to apply to the resource.')
param tags object = {}

// ============================================================================
// Resources
// ============================================================================

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    zoneRedundant: zoneRedundant
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnetId
      internal: internalEnvironment
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the Container Apps environment.')
output environmentId string = containerAppsEnvironment.id

@description('Name of the Container Apps environment.')
output environmentName string = containerAppsEnvironment.name

@description('Default domain of the Container Apps environment.')
output defaultDomain string = containerAppsEnvironment.properties.defaultDomain

@description('Infrastructure subnet configured for private dependency access.')
output infrastructureSubnetId string = containerAppsEnvironment.properties.vnetConfiguration.infrastructureSubnetId
