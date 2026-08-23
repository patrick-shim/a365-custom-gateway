// ============================================================================
// Module: Application Insights
// Purpose: Application performance monitoring for the A365 Custom Gateway
// ============================================================================

@description('Name of the Application Insights resource.')
param appInsightsName string

@description('Azure region for the resource.')
param location string

@description('Resource ID of the Log Analytics workspace to link for data storage.')
param logAnalyticsWorkspaceId string

@description('Tags to apply to the resource.')
param tags object = {}

// ============================================================================
// Resources
// ============================================================================

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    RetentionInDays: 90
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the Application Insights resource.')
output appInsightsId string = appInsights.id

@description('Name of the Application Insights resource.')
output appInsightsName string = appInsights.name

@description('Connection string for Application Insights SDK configuration.')
output connectionString string = appInsights.properties.ConnectionString

@description('Instrumentation key for Application Insights (legacy, prefer connection string).')
output instrumentationKey string = appInsights.properties.InstrumentationKey
