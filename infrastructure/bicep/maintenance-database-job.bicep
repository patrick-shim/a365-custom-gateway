targetScope = 'resourceGroup'

param jobName string
param location string
param containerAppsEnvironmentId string
param imagePullIdentityResourceId string
param acrLoginServer string
param migratorImageDigest string
param deploymentOwnershipId string
param bootstrapSourceFingerprint string
param upgradeSourceFingerprint string
param upgradePlanFingerprint string
param executionIntentId string
param sqlServerFqdn string
param expectedPrivateEndpointIp string
param apiPrincipalName string
param apiPrincipalClientId string
param workerPrincipalName string
param workerPrincipalClientId string
param storageAccountName string
param evidenceRoleAssignmentName string
param upgradeManifestJson string
param upgradeManifestFingerprint string
param cutoverApiName string
param cutoverWorkerName string
param cutoverNamespaceName string
@minLength(4)
@maxLength(4)
param cutoverReaderRoleNames array

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storage
  name: 'default'
}
resource evidence 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: 'gateway-upgrade-evidence'
  properties: { publicAccess: 'None' }
}

resource job 'Microsoft.App/jobs@2025-01-01' = {
  name: jobName
  location: location
  tags: {
    application: 'a365-custom-gateway'
    workload: 'database-upgrade'
    bootstrapOwnershipId: deploymentOwnershipId
    bootstrapSourceFingerprint: bootstrapSourceFingerprint
    gatewayUpgradeSourceFingerprint: upgradeSourceFingerprint
    gatewayUpgradePlanFingerprint: upgradePlanFingerprint
  }
  identity: {
    type: 'SystemAssigned,UserAssigned'
    userAssignedIdentities: { '${imagePullIdentityResourceId}': {} }
  }
  properties: {
    environmentId: containerAppsEnvironmentId
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 1800
      replicaRetryLimit: 0
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      identitySettings: [
        { identity: 'system', lifecycle: 'Main' }
        { identity: imagePullIdentityResourceId, lifecycle: 'None' }
      ]
      registries: [{ server: acrLoginServer, identity: imagePullIdentityResourceId }]
      secrets: []
    }
    template: {
      containers: [{
        name: 'database-upgrade'
        image: '${acrLoginServer}/gateway-db-migrator@${migratorImageDigest}'
        command: ['dotnet', 'Gateway.DatabaseMigrator.dll']
        args: [
          '--server'
          sqlServerFqdn
          '--database'
          'GatewayDb'
          '--phase'
          'upgrade'
          '--repository-root'
          '/app'
          '--deployment-ownership-id'
          deploymentOwnershipId
          '--accepted-source-fingerprint'
          bootstrapSourceFingerprint
          '--expected-private-endpoint-ip'
          expectedPrivateEndpointIp
          '--execution-intent-id'
          executionIntentId
          '--expected-api-principal-name'
          apiPrincipalName
          '--expected-api-principal-client-id'
          apiPrincipalClientId
          '--expected-worker-principal-name'
          workerPrincipalName
          '--expected-worker-principal-client-id'
          workerPrincipalClientId
          '--upgrade-plan-fingerprint'
          upgradePlanFingerprint
        ]
        env: [
          { name: 'DATABASE_MIGRATOR_UPGRADE_MANIFEST_JSON', value: upgradeManifestJson }
          { name: 'DATABASE_MIGRATOR_UPGRADE_MANIFEST_FINGERPRINT', value: upgradeManifestFingerprint }
          { name: 'DOTNET_EnableDiagnostics', value: '0' }
        ]
        resources: { cpu: json('0.5'), memory: '1Gi' }
      }]
    }
  }
}

resource evidenceWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: evidenceRoleAssignmentName
  scope: evidence
  properties: {
    principalId: job.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}
resource cutoverApi 'Microsoft.App/containerApps@2025-01-01' existing = {
    name: cutoverApiName
  }
  resource cutoverWorker 'Microsoft.App/containerApps@2025-01-01' existing = {
    name: cutoverWorkerName
  }
  resource cutoverNamespace 'Microsoft.ServiceBus/namespaces@2024-01-01' existing = {
    name: cutoverNamespaceName
  }
  resource provisioningQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' existing = {
    parent: cutoverNamespace
    name: 'gateway-provisioning-v3'
  }
  resource protectionQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' existing = {
    parent: cutoverNamespace
    name: 'gateway-protection-admin-v1'
  }
  var readerRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  resource apiObserver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
    name: cutoverReaderRoleNames[0]
    scope: cutoverApi
    properties: { principalId: job.identity.principalId, principalType: 'ServicePrincipal', roleDefinitionId: readerRole }
  }
  resource workerObserver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
    name: cutoverReaderRoleNames[1]
    scope: cutoverWorker
    properties: { principalId: job.identity.principalId, principalType: 'ServicePrincipal', roleDefinitionId: readerRole }
  }
  resource provisioningObserver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
    name: cutoverReaderRoleNames[2]
    scope: provisioningQueue
    properties: { principalId: job.identity.principalId, principalType: 'ServicePrincipal', roleDefinitionId: readerRole }
  }
  resource protectionObserver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
    name: cutoverReaderRoleNames[3]
    scope: protectionQueue
    properties: { principalId: job.identity.principalId, principalType: 'ServicePrincipal', roleDefinitionId: readerRole }
  }

output jobId string = job.id
output jobPrincipalId string = job.identity.principalId
output evidenceContainerId string = evidence.id
output evidenceRoleAssignmentId string = evidenceWriter.id
