targetScope = 'resourceGroup'
param namespaceName string
param apiPrincipalId string
param workerPrincipalId string
param keyVaultName string
param apiSenderRoleName string
param workerReceiverRoleName string
param workerCertificateRoleName string

resource serviceBus 'Microsoft.ServiceBus/namespaces@2024-01-01' existing = { name: namespaceName }
resource queue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: serviceBus
  name: 'gateway-protection-admin-v1'
  properties: {
    lockDuration: 'PT5M'
    maxSizeInMegabytes: 1024
    requiresDuplicateDetection: false
    requiresSession: false
    defaultMessageTimeToLive: 'P7D'
    deadLetteringOnMessageExpiration: true
    maxDeliveryCount: 10
    enablePartitioning: false
    enableBatchedOperations: true
  }
}
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: keyVaultName }
resource certificate 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = { parent: vault, name: 'purview-automation-certificate' }
resource sender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: apiSenderRoleName
  scope: queue
  properties: {
    principalId: apiPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39')
  }
}
resource receiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: workerReceiverRoleName
  scope: queue
  properties: {
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0')
  }
}
resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: workerCertificateRoleName
  scope: certificate
  properties: {
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}
output queueId string = queue.id
output senderRoleId string = sender.id
output receiverRoleId string = receiver.id
output certificateRoleId string = reader.id
