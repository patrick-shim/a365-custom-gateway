targetScope = 'resourceGroup'
param jobName string
param location string
param deploymentOwnershipId string
param bootstrapSourceFingerprint string
param executionSourceFingerprint string
param upgradePlanFingerprint string
param executionIntentId string
param containerAppsEnvironmentId string
param imagePullIdentityResourceId string
param acrLoginServer string
param publisherImageDigest string
param packageDigest string
param packageBytes int
param storageAccountName string
param expectedStoragePrivateEndpointIp string
param writerRoleName string

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: storageAccountName }
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = { parent: storage, name: 'default' }
resource packages 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = { parent: blobs, name: 'purview-executor-packages' }
resource job 'Microsoft.App/jobs@2025-01-01' = {
  name: jobName
  location: location
  tags: {
    application: 'a365-custom-gateway'
    workload: 'purview-package-publisher'
    bootstrapOwnershipId: deploymentOwnershipId
    bootstrapSourceFingerprint: bootstrapSourceFingerprint
    gatewayUpgradePlanFingerprint: upgradePlanFingerprint
    gatewayUpgradeSourceFingerprint: executionSourceFingerprint
  }
  identity: {
    type: 'SystemAssigned,UserAssigned'
    userAssignedIdentities: { '${imagePullIdentityResourceId}': {} }
  }
  properties: {
    environmentId: containerAppsEnvironmentId
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 660
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
        name: 'purview-package-publisher'
        image: '${acrLoginServer}/gateway-purview-package-publisher@${publisherImageDigest}'
        env: [
          { name: 'PUBLISHER_DEPLOYMENT_OWNERSHIP_ID', value: deploymentOwnershipId }
          { name: 'PUBLISHER_EXECUTION_INTENT_ID', value: executionIntentId }
          { name: 'PUBLISHER_EXECUTION_SOURCE_FINGERPRINT', value: executionSourceFingerprint }
          { name: 'PUBLISHER_PACKAGE_DIGEST', value: packageDigest }
          { name: 'PUBLISHER_PACKAGE_BYTES', value: string(packageBytes) }
          { name: 'PUBLISHER_CONTAINER_URI', value: '${storage.properties.primaryEndpoints.blob}${packages.name}' }
          { name: 'PUBLISHER_PRIVATE_ENDPOINT_IP', value: expectedStoragePrivateEndpointIp }
        ]
        probes: []
        resources: { cpu: json('0.5'), memory: '1Gi' }
      }]
    }
  }
}
resource writer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: writerRoleName
  scope: packages
  properties: {
    principalId: job.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}
output jobId string = job.id
output jobName string = job.name
output jobPrincipalId string = job.identity.principalId
output packageWriterRoleId string = writer.id
