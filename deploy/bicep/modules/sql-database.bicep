// ============================================================================
// Module: Azure SQL Server and Database
// Purpose: Persistent storage for the A365 Custom Gateway (EF Core)
// ============================================================================

@description('Name of the SQL Server.')
param serverName string

@description('Name of the SQL database.')
param databaseName string = 'GatewayDb'

@description('Azure region for the resource.')
param location string

@description('SQL administrator login name.')
param administratorLogin string

@description('SQL administrator login password.')
@secure()
param administratorLoginPassword string

@description('Entra ID object ID for the AD administrator.')
param entraAdminObjectId string

@description('Entra ID display name or UPN for the AD administrator.')
param entraAdminLogin string

@description('SKU name for the SQL database.')
@allowed([
  'Basic'
  'S0'
  'S1'
  'S2'
  'S3'
  'P1'
  'P2'
  'GP_S_Gen5_1'
  'GP_S_Gen5_2'
])
param skuName string = 'Basic'

@description('SKU tier for the SQL database.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
  'GeneralPurpose'
])
param skuTier string = 'Basic'

@description('Maximum database size in bytes (default 2 GB).')
param maxSizeBytes int = 2147483648

@description('Tags to apply to the resource.')
param tags object = {}

@description('Resource ID of the Log Analytics workspace for diagnostic settings.')
param logAnalyticsWorkspaceId string

// ============================================================================
// Resources
// ============================================================================

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: serverName
  location: location
  tags: tags
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'User'
      login: entraAdminLogin
      sid: entraAdminObjectId
      tenantId: tenant().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: databaseName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    maxSizeBytes: maxSizeBytes
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    catalogCollation: 'SQL_Latin1_General_CP1_CI_AS'
    zoneRedundant: false
    readScale: 'Disabled'
    requestedBackupStorageRedundancy: 'Local'
  }
}

resource databaseDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${databaseName}-diag'
  scope: sqlDatabase
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'SQLSecurityAuditEvents'
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

@description('Resource ID of the SQL Server.')
output serverId string = sqlServer.id

@description('Fully qualified domain name of the SQL Server.')
output serverFqdn string = sqlServer.properties.fullyQualifiedDomainName

@description('Name of the SQL database.')
output databaseName string = sqlDatabase.name
