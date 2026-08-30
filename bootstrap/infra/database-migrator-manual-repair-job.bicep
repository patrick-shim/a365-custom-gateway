targetScope = 'resourceGroup'

param location string

@allowed([
  'dev'
  'staging'
  'prod'
])
param environment string

@minLength(2)
@maxLength(8)
param projectName string

@minLength(1)
param containerAppsEnvironmentId string

@minLength(71)
@maxLength(71)
param databaseMigratorImageDigest string

@minLength(1)
param acrLoginServer string

@minLength(1)
param imagePullIdentityResourceId string

@minLength(1)
param sqlServerFqdn string

@minLength(7)
@maxLength(15)
param expectedPrivateEndpointIp string

@minLength(36)
@maxLength(36)
param deploymentOwnershipId string

@minLength(71)
@maxLength(71)
param originalAcceptedSourceFingerprint string

@minLength(71)
@maxLength(71)
param manualDatabaseRepairSourceFingerprint string

@minLength(71)
@maxLength(71)
param manualDatabaseRepairPlanFingerprint string

@minLength(36)
@maxLength(36)
param manualRepairExecutionIntentId string

@minLength(71)
@maxLength(71)
param originalFailedDatabaseBoundaryFingerprint string

@minLength(71)
@maxLength(71)
param firstFailedRecoveryBoundaryFingerprint string

@minLength(71)
@maxLength(71)
param secondFailedRecoveryBoundaryFingerprint string

@minLength(1)
@maxLength(128)
param apiDatabasePrincipalName string

@minLength(36)
@maxLength(36)
param apiDatabasePrincipalClientId string

@minLength(1)
@maxLength(128)
param workerDatabasePrincipalName string

@minLength(36)
@maxLength(36)
param workerDatabasePrincipalClientId string

@minValue(300)
@maxValue(3600)
param replicaTimeoutSeconds int = 1800

var jobName = 'job-${projectName}-db-repair-${environment}'
var databaseName = 'GatewayDb'
var databaseRepairJobImage = '${acrLoginServer}/gateway-db-migrator@${databaseMigratorImageDigest}'

// This is a new, dedicated, dormant one-shot repair surface. It neither updates
// nor starts nor deletes the original initialization Job or either recovery Job.
resource databaseRepairJob 'Microsoft.App/jobs@2025-01-01' = {
  name: jobName
  location: location
  tags: {
    application: 'a365-custom-gateway'
    environment: environment
    managedBy: 'bootstrap'
    projectName: projectName
    deploymentId: '${projectName}-${environment}'
    bootstrapOwnershipId: deploymentOwnershipId
    bootstrapSourceFingerprint: originalAcceptedSourceFingerprint
    manualDatabaseRepairSourceFingerprint: manualDatabaseRepairSourceFingerprint
    manualDatabaseRepairPlanFingerprint: manualDatabaseRepairPlanFingerprint
    workload: 'database-bootstrap-manual-repair'
    originalFailedDatabaseBoundaryFingerprint: originalFailedDatabaseBoundaryFingerprint
    firstFailedRecoveryBoundaryFingerprint: firstFailedRecoveryBoundaryFingerprint
    secondFailedRecoveryBoundaryFingerprint: secondFailedRecoveryBoundaryFingerprint
  }
  identity: {
    type: 'SystemAssigned,UserAssigned'
    userAssignedIdentities: {
      '${imagePullIdentityResourceId}': {}
    }
  }
  properties: {
    environmentId: containerAppsEnvironmentId
    configuration: {
      identitySettings: [
        {
          identity: 'system'
          lifecycle: 'Main'
        }
        {
          identity: imagePullIdentityResourceId
          lifecycle: 'None'
        }
      ]
      triggerType: 'Manual'
      replicaTimeout: replicaTimeoutSeconds
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      registries: [
        {
          server: acrLoginServer
          identity: imagePullIdentityResourceId
        }
      ]
      secrets: []
    }
    template: {
      containers: [
        {
          name: 'database-manual-repair'
          image: databaseRepairJobImage
          command: [
            'dotnet'
            'Gateway.DatabaseMigrator.dll'
          ]
          args: [
            '--server'
            sqlServerFqdn
            '--expected-private-endpoint-ip'
            expectedPrivateEndpointIp
            '--database'
            databaseName
            '--phase'
            'bootstrap'
            '--required-recovery-mode'
            'ResumeAfterSchemaCompleted'
            '--repeat'
            '1'
            '--repository-root'
            '/app'
            '--deployment-ownership-id'
            deploymentOwnershipId
            '--accepted-source-fingerprint'
            originalAcceptedSourceFingerprint
            '--expected-api-principal-name'
            apiDatabasePrincipalName
            '--expected-api-principal-client-id'
            apiDatabasePrincipalClientId
            '--expected-worker-principal-name'
            workerDatabasePrincipalName
            '--expected-worker-principal-client-id'
            workerDatabasePrincipalClientId
            '--evidence-stdout'
            'true'
          ]
          env: [
            {
              name: 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'
              value: manualRepairExecutionIntentId
            }
          ]
          probes: []
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
    }
  }
}

output databaseRepairJobId string = databaseRepairJob.id
output databaseRepairJobName string = databaseRepairJob.name
output databaseRepairJobPrincipalId string = databaseRepairJob.identity.principalId
output databaseRepairJobImage string = databaseRepairJobImage
output deploymentOwnershipId string = deploymentOwnershipId
output originalAcceptedSourceFingerprint string = originalAcceptedSourceFingerprint
output manualDatabaseRepairSourceFingerprint string = manualDatabaseRepairSourceFingerprint
output manualDatabaseRepairPlanFingerprint string = manualDatabaseRepairPlanFingerprint
output manualRepairExecutionIntentId string = manualRepairExecutionIntentId
output originalFailedDatabaseBoundaryFingerprint string = originalFailedDatabaseBoundaryFingerprint
output firstFailedRecoveryBoundaryFingerprint string = firstFailedRecoveryBoundaryFingerprint
output secondFailedRecoveryBoundaryFingerprint string = secondFailedRecoveryBoundaryFingerprint
