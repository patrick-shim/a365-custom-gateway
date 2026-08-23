// ============================================================================
// Module: Azure Key Vault
// Purpose: Secrets management for the A365 Custom Gateway
// ============================================================================

@description('Name of the Key Vault. Must be globally unique.')
param vaultName string

@description('Azure region for the resource.')
param location string

@description('Entra ID tenant ID for the Key Vault.')
param tenantId string

@description('Use RBAC authorization instead of access policies.')
param enableRbacAuthorization bool = true

@description('Enable soft delete for the Key Vault.')
param enableSoftDelete bool = true

@description('Number of days to retain soft-deleted vaults (7-90).')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

@description('Enable purge protection to prevent permanent deletion during retention period.')
param enablePurgeProtection bool = true

@description('SKU name for the Key Vault.')
@allowed([
  'standard'
  'premium'
])
param skuName string = 'standard'

@description('Tags to apply to the resource.')
param tags object = {}

@description('Resource ID of the Log Analytics workspace for diagnostic settings.')
param logAnalyticsWorkspaceId string

// ============================================================================
// Resources
// ============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: skuName
    }
    enableRbacAuthorization: enableRbacAuthorization
    enableSoftDelete: enableSoftDelete
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: enablePurgeProtection
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${vaultName}-diag'
  scope: keyVault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
        retentionPolicy: {
          days: 90
          enabled: true
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          days: 90
          enabled: true
        }
      }
    ]
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the Key Vault.')
output vaultId string = keyVault.id

@description('URI of the Key Vault.')
output vaultUri string = keyVault.properties.vaultUri

@description('Name of the Key Vault.')
output vaultName string = keyVault.name
