// ============================================================================
// Module: Azure Container Registry
// Purpose: Container image registry for the A365 Custom Gateway workloads
// ============================================================================

@description('Name of the Container Registry. Must be globally unique and alphanumeric.')
param registryName string

@description('Azure region for the resource.')
param location string

@description('SKU for the Container Registry.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param sku string = 'Basic'

@description('Enable admin user for the registry. Should be false when using managed identity.')
param adminUserEnabled bool = false

@description('Tags to apply to the resource.')
param tags object = {}

@description('Resource ID of the Log Analytics workspace for diagnostic settings.')
param logAnalyticsWorkspaceId string

// ============================================================================
// Resources
// ============================================================================

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    adminUserEnabled: adminUserEnabled
    policies: {
      azureADAuthenticationAsArmPolicy: {
        status: 'enabled'
      }
      quarantinePolicy: {
        status: 'disabled'
      }
      retentionPolicy: {
        status: sku == 'Premium' ? 'enabled' : 'disabled'
        days: sku == 'Premium' ? 30 : 7
      }
    }
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${registryName}-diag'
  scope: containerRegistry
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'ContainerRegistryRepositoryEvents'
        enabled: true
      }
      {
        category: 'ContainerRegistryLoginEvents'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the Container Registry.')
output registryId string = containerRegistry.id

@description('Login server URL for the Container Registry.')
output loginServer string = containerRegistry.properties.loginServer

@description('Name of the Container Registry.')
output registryName string = containerRegistry.name
