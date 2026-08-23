// ============================================================================
// Module: Log Analytics Workspace
// Purpose: Centralized logging and diagnostics for the A365 Custom Gateway
// ============================================================================

@description('Name of the Log Analytics workspace.')
param workspaceName string

@description('Azure region for the resource.')
param location string

@description('SKU for the Log Analytics workspace.')
@allowed([
  'PerGB2018'
  'Free'
  'Standalone'
  'PerNode'
])
param sku string = 'PerGB2018'

@description('Data retention in days (7-730).')
@minValue(7)
@maxValue(730)
param retentionInDays int = 30

@description('Tags to apply to the resource.')
param tags object = {}

// ============================================================================
// Resources
// ============================================================================

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${workspaceName}-diag'
  scope: logAnalyticsWorkspace
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        category: 'Audit'
        enabled: true
        retentionPolicy: {
          days: retentionInDays
          enabled: true
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          days: retentionInDays
          enabled: true
        }
      }
    ]
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the Log Analytics workspace.')
output workspaceId string = logAnalyticsWorkspace.id

@description('Name of the Log Analytics workspace.')
output workspaceName string = logAnalyticsWorkspace.name

@description('Customer ID (workspace ID) for agent configuration.')
output customerId string = logAnalyticsWorkspace.properties.customerId

@description('Primary shared key for the Log Analytics workspace.')
@secure()
output sharedKey string = logAnalyticsWorkspace.listKeys().primarySharedKey
