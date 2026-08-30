targetScope = 'resourceGroup'

@description('Azure region for the database bootstrap Container Apps Job.')
param location string

@description('Deployment environment used in the deterministic job name and ownership tags.')
@allowed([
  'dev'
  'staging'
  'prod'
])
param environment string

@description('Short project name used in the deterministic job name and ownership tags.')
@minLength(2)
@maxLength(8)
param projectName string

@description('Resource ID of the existing VNet-integrated Container Apps environment.')
@minLength(1)
param containerAppsEnvironmentId string

@description('Canonical immutable SHA-256 digest of the reviewed gateway-db-migrator image.')
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

@description('Random bootstrap-state ownership GUID propagated to the job and the database initialization marker.')
@minLength(36)
@maxLength(36)
param deploymentOwnershipId string

@description('Canonical accepted-source fingerprint propagated to the job and the database initialization marker.')
@minLength(71)
@maxLength(71)
param bootstrapSourceFingerprint string

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

@description('Maximum duration, in seconds, of the single manually started database bootstrap execution.')
@minValue(300)
@maxValue(3600)
param replicaTimeoutSeconds int = 1800

var jobName = 'job-${projectName}-db-init-${environment}'
var containerName = 'database-bootstrap'
var databaseName = 'GatewayDb'
var databaseMigratorImage = '${acrLoginServer}/gateway-db-migrator@${databaseMigratorImageDigest}'
var tags = {
  application: 'a365-custom-gateway'
  environment: environment
  managedBy: 'bootstrap'
  projectName: projectName
  deploymentId: '${projectName}-${environment}'
  bootstrapOwnershipId: deploymentOwnershipId
  bootstrapSourceFingerprint: bootstrapSourceFingerprint
  workload: 'database-bootstrap'
}

// Microsoft.App/jobs@2025-01-01 is a stable GA ARM contract. The job is a
// persistent, dormant execution surface inside the existing VNet-integrated
// environment. Creating or updating it never starts a database migration.
resource databaseBootstrapJob 'Microsoft.App/jobs@2025-01-01' = {
  name: jobName
  location: location
  tags: tags
  identity: {
    // The system identity is the SQL execution identity. The attached UAMI is
    // referenced only by the private-registry configuration below.
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
          image: databaseMigratorImage
          command: [
            'dotnet'
            'Gateway.DatabaseMigrator.dll'
          ]
          args: [
            '--server'
            sqlServerFqdn
            '--database'
            databaseName
            '--phase'
            'bootstrap'
            '--repeat'
            '1'
            '--repository-root'
            '/app'
            '--deployment-ownership-id'
            deploymentOwnershipId
            '--accepted-source-fingerprint'
            bootstrapSourceFingerprint
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
          env: []
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

output databaseBootstrapJobId string = databaseBootstrapJob.id
output databaseBootstrapJobName string = databaseBootstrapJob.name
output databaseBootstrapJobSystemPrincipalId string = databaseBootstrapJob.identity.principalId
output databaseMigratorImage string = databaseMigratorImage
output deploymentOwnershipId string = deploymentOwnershipId
output bootstrapSourceFingerprint string = bootstrapSourceFingerprint
