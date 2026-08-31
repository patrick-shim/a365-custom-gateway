// ============================================================================
// Module: RBAC Role Assignments
// Purpose: Managed identity permissions for A365 Custom Gateway workloads
// ============================================================================

@description('Principal ID of the API Container App system-assigned managed identity.')
param apiPrincipalId string

@description('Principal ID of the Worker Container App system-assigned managed identity.')
param workerPrincipalId string

@description('Name of the Azure Key Vault.')
param keyVaultName string

@description('Grant the worker read-only secret access to the shared Key Vault for certificate-based Purview policy automation.')
param enableWorkerKeyVaultSecretsUser bool = false

@description('Exact shared-vault secret name containing the Purview automation certificate. Required only when worker certificate access is enabled.')
param workerPurviewCertificateSecretName string = ''

@description('Name of the Azure Storage Account.')
param storageAccountName string

@description('Name of the Azure Service Bus namespace.')
param serviceBusNamespaceName string

@description('Name of the isolated provisioning queue. Data-plane roles are scoped to this queue, not the namespace.')
param serviceBusQueueName string

@description('Name of the Azure Container Registry. Used only by the guarded historical system-identity image-pull path.')
param containerRegistryName string

@description('Restore the deterministic historical API and worker system-identity AcrPull assignments. Clean bootstrap leaves this false and uses its pre-authorized dedicated pull identity.')
param enableLegacySystemAssignedAcrPull bool = false

// ============================================================================
// Variables
// ============================================================================

// Built-in role definition GUIDs
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var serviceBusDataSenderRoleId = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
var serviceBusDataReceiverRoleId = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// ============================================================================
// Existing Resources
// ============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource workerPurviewCertificateSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = if (enableWorkerKeyVaultSecretsUser) {
  parent: keyVault
  name: workerPurviewCertificateSecretName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' existing = {
  name: serviceBusNamespaceName
}

resource serviceBusQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' existing = {
  parent: serviceBusNamespace
  name: serviceBusQueueName
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: containerRegistryName
}

// ============================================================================
// API Role Assignments
// ============================================================================

// API -> Storage: Storage Blob Data Contributor
resource apiStorageBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, apiPrincipalId, storageAccount.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: apiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// API -> Service Bus: Azure Service Bus Data Sender
resource apiServiceBusDataSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, apiPrincipalId, serviceBusQueue.id, serviceBusDataSenderRoleId)
  scope: serviceBusQueue
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceBusDataSenderRoleId)
    principalId: apiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Historical API -> ACR: AcrPull. This post-compute assignment is safe only for
// updates to an already bootstrapped system-identity deployment or for the
// explicitly guarded public-image identity bootstrap.
resource apiAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableLegacySystemAssignedAcrPull) {
  name: guid(subscription().id, apiPrincipalId, containerRegistry.id, acrPullRoleId)
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: apiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// Worker Role Assignments
// ============================================================================

// Worker -> one exact shared-vault certificate secret. Vault-wide access would
// also expose the unrelated Admin UI client credential and is forbidden.
resource workerKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableWorkerKeyVaultSecretsUser) {
  name: guid(subscription().id, workerPrincipalId, workerPurviewCertificateSecret!.id, keyVaultSecretsUserRoleId)
  scope: workerPurviewCertificateSecret!
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Worker -> Storage: Storage Blob Data Contributor
resource workerStorageBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, workerPrincipalId, storageAccount.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Worker -> Service Bus: Azure Service Bus Data Receiver
resource workerServiceBusDataReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, workerPrincipalId, serviceBusQueue.id, serviceBusDataReceiverRoleId)
  scope: serviceBusQueue
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceBusDataReceiverRoleId)
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Historical worker -> ACR: AcrPull. See the API assignment above.
resource workerAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableLegacySystemAssignedAcrPull) {
  name: guid(subscription().id, workerPrincipalId, containerRegistry.id, acrPullRoleId)
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
  }
}
