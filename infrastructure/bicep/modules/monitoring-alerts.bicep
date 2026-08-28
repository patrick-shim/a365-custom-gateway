// ============================================================================
// Module: Monitoring Alerts
// Purpose: Operational alerting for the A365 Custom Gateway
// ============================================================================

@description('Resource ID of the Application Insights instance.')
param appInsightsId string

@description('Name of the alert action group.')
param actionGroupName string = 'ag-gateway-alerts'

@description('Email address for alert notifications.')
param actionGroupEmail string

@description('Name of the API Container App.')
param apiContainerAppName string

@description('Name of the historical Worker Container App retained during a blue/green migration.')
param historicalWorkerContainerAppName string

@description('Name of the newly deployed or current target Worker Container App.')
param targetWorkerContainerAppName string

@description('Name of the Service Bus namespace.')
param serviceBusNamespaceName string

@description('Name of the SQL Server.')
param sqlServerName string

@description('Name of the SQL database for metric scoping.')
param sqlDatabaseName string = 'GatewayDb'

@description('Name of the Key Vault for availability monitoring.')
param keyVaultName string

@description('Deployment environment (dev, test, prod).')
@allowed([
  'dev'
  'staging'
  'prod'
])
param environment string

@description('Azure region for the resources.')
param location string

@description('Tags to apply to the resources.')
param tags object = {}

// ============================================================================
// Variables
// ============================================================================

// Environment-adjusted thresholds: tighter for prod, relaxed for dev/test
var sqlConnectionFailedThreshold = environment == 'prod' ? 3 : 5
var keyVaultAvailabilityThreshold = environment == 'prod' ? 99 : 95
var serviceBusQueueDepthThreshold = environment == 'prod' ? 50 : 100
var apiServerErrorsThreshold = environment == 'prod' ? 5 : 10
var apiAuthFailuresThreshold = environment == 'prod' ? 20 : 50
var apiLatencyThreshold = environment == 'prod' ? 1500 : 2000

// ============================================================================
// Existing Resources
// ============================================================================

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' existing = {
  name: sqlServerName
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' existing = {
  parent: sqlServer
  name: sqlDatabaseName
}

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' existing = {
  name: serviceBusNamespaceName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// ============================================================================
// Action Group
// ============================================================================

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'gw-alerts'
    enabled: true
    emailReceivers: [
      {
        name: 'gateway-admin'
        emailAddress: actionGroupEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// ============================================================================
// Metric Alerts
// ============================================================================

// 1. SQL Connection Failed — Sev 1
resource sqlConnectionFailedAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-sql-connection-failed-${environment}'
  location: 'global'
  tags: tags
  properties: {
    severity: 1
    enabled: true
    scopes: [
      sqlDatabase.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'SqlConnectionFailed'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'connection_failed'
          metricNamespace: 'Microsoft.Sql/servers/databases'
          operator: 'GreaterThan'
          threshold: sqlConnectionFailedThreshold
          timeAggregation: 'Total'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// 2. Service Bus Server Errors — Sev 2
resource serviceBusServerErrorsAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-servicebus-server-errors-${environment}'
  location: 'global'
  tags: tags
  properties: {
    severity: 2
    enabled: true
    scopes: [
      serviceBusNamespace.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'ServiceBusServerErrors'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'ServerErrors'
          metricNamespace: 'Microsoft.ServiceBus/namespaces'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// 3. Key Vault Availability Drop — Sev 2
resource keyVaultAvailabilityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-keyvault-availability-drop-${environment}'
  location: 'global'
  tags: tags
  properties: {
    severity: 2
    enabled: true
    scopes: [
      keyVault.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'KeyVaultAvailability'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'Availability'
          metricNamespace: 'Microsoft.KeyVault/vaults'
          operator: 'LessThan'
          threshold: keyVaultAvailabilityThreshold
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// 4. Service Bus Queue Depth High — Sev 2
resource serviceBusQueueDepthAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-servicebus-queue-depth-high-${environment}'
  location: 'global'
  tags: tags
  properties: {
    severity: 2
    enabled: true
    scopes: [
      serviceBusNamespace.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'ServiceBusActiveMessages'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'ActiveMessages'
          metricNamespace: 'Microsoft.ServiceBus/namespaces'
          operator: 'GreaterThan'
          threshold: serviceBusQueueDepthThreshold
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// 5. Service Bus Dead Letter Queue Depth — Sev 1
resource serviceBusDeadletterAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-servicebus-deadletter-depth-${environment}'
  location: 'global'
  tags: tags
  properties: {
    severity: 1
    enabled: true
    scopes: [
      serviceBusNamespace.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'ServiceBusDeadletteredMessages'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'DeadletteredMessages'
          metricNamespace: 'Microsoft.ServiceBus/namespaces'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// ============================================================================
// Scheduled Query Rules (KQL-based Alerts)
// ============================================================================

// 6. API Server Errors (5xx responses) — Sev 1
resource apiServerErrorsAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-api-server-errors-${environment}'
  location: location
  tags: tags
  properties: {
    severity: 1
    enabled: true
    scopes: [
      appInsightsId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'requests | where cloud_RoleName == "${apiContainerAppName}" and toint(resultCode) >= 500'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: apiServerErrorsThreshold
          failingPeriods: {
            minFailingPeriodsToAlert: 1
            numberOfEvaluationPeriods: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// 7. API Auth Failures (401/403 responses) — Sev 2
resource apiAuthFailuresAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-api-auth-failures-${environment}'
  location: location
  tags: tags
  properties: {
    severity: 2
    enabled: true
    scopes: [
      appInsightsId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'requests | where cloud_RoleName == "${apiContainerAppName}" and resultCode in ("401", "403")'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: apiAuthFailuresThreshold
          failingPeriods: {
            minFailingPeriodsToAlert: 1
            numberOfEvaluationPeriods: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// 8. API Response Latency High (p95 > threshold) — Sev 2
resource apiLatencyAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-api-response-latency-high-${environment}'
  location: location
  tags: tags
  properties: {
    severity: 2
    enabled: true
    scopes: [
      appInsightsId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'requests | where cloud_RoleName == "${apiContainerAppName}" | summarize p95_duration = percentile(duration, 95) by bin(timestamp, 5m)'
          timeAggregation: 'Average'
          metricMeasureColumn: 'p95_duration'
          operator: 'GreaterThan'
          threshold: apiLatencyThreshold
          failingPeriods: {
            minFailingPeriodsToAlert: 1
            numberOfEvaluationPeriods: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// 9. Identity Mismatch (AGENT_IDENTITY_MISMATCH) — Sev 1
resource identityMismatchAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-identity-mismatch-${environment}'
  location: location
  tags: tags
  properties: {
    severity: 1
    enabled: true
    scopes: [
      appInsightsId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'traces | where cloud_RoleName == "${apiContainerAppName}" and message contains "AGENT_IDENTITY_MISMATCH"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            minFailingPeriodsToAlert: 1
            numberOfEvaluationPeriods: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// 10. Provisioning Failed — Sev 2
resource provisioningFailedAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-provisioning-failed-${environment}'
  location: location
  tags: tags
  properties: {
    severity: 2
    enabled: true
    scopes: [
      appInsightsId
    ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: 'traces | where (cloud_RoleName == "${historicalWorkerContainerAppName}" or cloud_RoleName == "${targetWorkerContainerAppName}") and message contains "provisioning" and message contains "Failed"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            minFailingPeriodsToAlert: 1
            numberOfEvaluationPeriods: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}
