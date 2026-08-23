// ============================================================================
// Module: Azure Storage Account
// Purpose: Blob storage for interaction payloads in the A365 Custom Gateway
// ============================================================================

@description('Name of the Storage Account. Must be globally unique, 3-24 chars, lowercase alphanumeric.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Azure region for the resource.')
param location string

@description('SKU for the Storage Account.')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_ZRS'
  'Standard_RAGRS'
  'Premium_LRS'
])
param sku string = 'Standard_LRS'

@description('Kind of storage account.')
@allowed([
  'StorageV2'
  'BlobStorage'
])
param kind string = 'StorageV2'

@description('Name of the blob container to create.')
param containerName string = 'a365-gateway-interactions'

@description('Tags to apply to the resource.')
param tags object = {}

@description('Resource ID of the Log Analytics workspace for diagnostic settings.')
param logAnalyticsWorkspaceId string

// ============================================================================
// Resources
// ============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: sku
  }
  kind: kind
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

resource blobDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${storageAccountName}-blob-diag'
  scope: blobService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
      {
        category: 'StorageDelete'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the Storage Account.')
output storageAccountId string = storageAccount.id

@description('Name of the Storage Account.')
output storageAccountName string = storageAccount.name

@description('Primary blob endpoint URL.')
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
