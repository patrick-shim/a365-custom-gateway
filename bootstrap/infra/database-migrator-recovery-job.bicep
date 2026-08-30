targetScope = 'resourceGroup'

@description('Azure region for the database recovery Container Apps Job.')
param location string

@description('Deployment environment used in the deterministic recovery job name and ownership tags.')
@allowed([
  'dev'
  'staging'
  'prod'
])
param environment string

@description('Short project name used in the deterministic recovery job name and ownership tags.')
@minLength(2)
@maxLength(8)
param projectName string

@description('Resource ID of the existing VNet-integrated Container Apps environment.')
@minLength(1)
param containerAppsEnvironmentId string

@description('Canonical immutable SHA-256 digest of the reviewed corrected gateway-db-migrator image.')
@minLength(71)
@maxLength(71)
param databaseMigratorImageDigest string

@description('Login server of the existing Azure Container Registry that contains gateway-db-migrator.')
@minLength(1)
param acrLoginServer string

@description('Resource ID of the existing user-assigned identity authorized only to pull images from the deployment ACR.')
@minLength(1)
param imagePullIdentityResourceId string

@description('Fully qualified domain name of the private Azure SQL logical server.')
@minLength(1)
param sqlServerFqdn string

@description('Canonical IPv4 address of the sole SQL private-endpoint NIC and exact private-DNS A-record target.')
@minLength(7)
@maxLength(15)
param expectedPrivateEndpointIp string

@description('Original bootstrap-state ownership GUID retained by the database initialization marker.')
@minLength(36)
@maxLength(36)
param deploymentOwnershipId string

@description('Canonical accepted-source fingerprint from the original deployment, retained as the database marker binding.')
@minLength(71)
@maxLength(71)
param originalAcceptedSourceFingerprint string

@description('Canonical fingerprint of the reviewed corrected source used only for recovery provenance.')
@minLength(71)
@maxLength(71)
param recoverySourceFingerprint string

@description('Canonical fingerprint of the accepted one-time database recovery plan.')
@minLength(71)
@maxLength(71)
param recoveryPlanFingerprint string

@description('Canonical lowercase non-empty GUID that binds this distinct recovery job to its sole authorized execution.')
@minLength(36)
@maxLength(36)
param recoveryExecutionIntentId string

@description('Exact Azure SQL contained-principal name for the Gateway API managed identity.')
@minLength(1)
@maxLength(128)
param apiDatabasePrincipalName string

@description('Exact application/client ID used as the SID of the Gateway API contained principal.')
@minLength(36)
@maxLength(36)
param apiDatabasePrincipalClientId string

@description('Exact Azure SQL contained-principal name for the provisioning worker managed identity.')
@minLength(1)
@maxLength(128)
param workerDatabasePrincipalName string

@description('Exact application/client ID used as the SID of the provisioning worker contained principal.')
@minLength(36)
@maxLength(36)
param workerDatabasePrincipalClientId string

@description('Maximum duration, in seconds, of the single manually started database recovery execution.')
@minValue(300)
@maxValue(3600)
param replicaTimeoutSeconds int = 1800

var jobName = 'job-${projectName}-db-recover-${environment}'
var containerName = 'database-recovery'
var databaseName = 'GatewayDb'
var databaseRecoveryJobImage = '${acrLoginServer}/gateway-db-migrator@${databaseMigratorImageDigest}'
var tags = {
  application: 'a365-custom-gateway'
  environment: environment
  managedBy: 'bootstrap'
  projectName: projectName
  deploymentId: '${projectName}-${environment}'
  bootstrapOwnershipId: deploymentOwnershipId
  bootstrapSourceFingerprint: originalAcceptedSourceFingerprint
  recoverySourceFingerprint: recoverySourceFingerprint
  recoveryPlanFingerprint: recoveryPlanFingerprint
  workload: 'database-bootstrap-recovery'
}

// This is a distinct, dormant recovery surface. Deploying or updating it does
// not start the migrator and cannot replay the retained failed bootstrap job.
resource databaseRecoveryJob 'Microsoft.App/jobs@2025-01-01' = {
  name: jobName
  location: location
  tags: tags
  identity: {
    // The system identity is elevated to singular SQL Entra administrator only
    // for the bounded execution. The UAMI is used only for private ACR pull.
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
          name: containerName
          image: databaseRecoveryJobImage
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
              value: recoveryExecutionIntentId
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

output databaseRecoveryJobId string = databaseRecoveryJob.id
output databaseRecoveryJobName string = databaseRecoveryJob.name
output databaseRecoveryJobPrincipalId string = databaseRecoveryJob.identity.principalId
output databaseRecoveryJobImage string = databaseRecoveryJobImage
output deploymentOwnershipId string = deploymentOwnershipId
output originalAcceptedSourceFingerprint string = originalAcceptedSourceFingerprint
output recoverySourceFingerprint string = recoverySourceFingerprint
output recoveryPlanFingerprint string = recoveryPlanFingerprint
output recoveryExecutionIntentId string = recoveryExecutionIntentId
