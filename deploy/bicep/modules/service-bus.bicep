// ============================================================================
// Module: Azure Service Bus
// Purpose: Async messaging for provisioning operations in the A365 Custom Gateway
// ============================================================================

@description('Name of the Service Bus namespace. Must be globally unique.')
param namespaceName string

@description('Azure region for the resource.')
param location string

@description('SKU for the Service Bus namespace.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param sku string = 'Basic'

@description('Name of the provisioning queue.')
param queueName string = 'gateway-provisioning-v3'

@description('Maximum number of delivery attempts before dead-lettering.')
@minValue(1)
@maxValue(2000)
param maxDeliveryCount int = 10

@description('Lock duration in seconds (5-300).')
@minValue(5)
@maxValue(300)
param lockDurationSeconds int = 300

@description('Maximum queue size in megabytes.')
@allowed([
  1024
  2048
  5120
])
param maxSizeInMegabytes int = 1024

@description('Tags to apply to the resource.')
param tags object = {}

@description('Resource ID of the Log Analytics workspace for diagnostic settings.')
param logAnalyticsWorkspaceId string

// ============================================================================
// Variables
// ============================================================================

// Convert lock duration seconds to ISO 8601 duration format (PTnMnS)
var lockMinutes = lockDurationSeconds / 60
var lockRemainingSeconds = lockDurationSeconds % 60
var lockDuration = lockRemainingSeconds > 0
  ? 'PT${lockMinutes}M${lockRemainingSeconds}S'
  : 'PT${lockMinutes}M'

// ============================================================================
// Resources
// ============================================================================

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: namespaceName
  location: location
  tags: tags
  sku: {
    name: sku
    tier: sku
  }
  properties: {
    minimumTlsVersion: '1.2'
    disableLocalAuth: true
  }
}

resource provisioningQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBusNamespace
  name: queueName
  properties: {
    lockDuration: lockDuration
    maxSizeInMegabytes: maxSizeInMegabytes
    requiresDuplicateDetection: false
    requiresSession: false
    defaultMessageTimeToLive: 'P7D'
    deadLetteringOnMessageExpiration: true
    maxDeliveryCount: maxDeliveryCount
    enablePartitioning: false
    enableBatchedOperations: true
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${namespaceName}-diag'
  scope: serviceBusNamespace
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'OperationalLogs'
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

@description('Resource ID of the Service Bus namespace.')
output namespaceId string = serviceBusNamespace.id

@description('Name of the Service Bus namespace.')
output namespaceName string = serviceBusNamespace.name

@description('Fully qualified domain name of the Service Bus namespace.')
output namespaceFqdn string = '${serviceBusNamespace.name}.servicebus.windows.net'

@description('Name of the provisioning queue.')
output queueName string = provisioningQueue.name
