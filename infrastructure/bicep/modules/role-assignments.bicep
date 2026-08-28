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

@description('Name of the dedicated Key Vault that stores generated provisioning credentials.')
param workerCredentialKeyVaultName string

@description('Legacy-only switch granting the worker Key Vault Secrets Officer on the provisioning credential vault. Workflow v3 does not require it.')
param enableWorkerCredentialKeyVaultSecretsOfficer bool = false

@description('Name of the Azure Storage Account.')
param storageAccountName string

@description('Name of the Azure Service Bus namespace.')
param serviceBusNamespaceName string

@description('Name of the isolated provisioning queue. Data-plane roles are scoped to this queue, not the namespace.')
param serviceBusQueueName string

@description('Name of the Azure Container Registry.')
param containerRegistryName string

// ============================================================================
// Variables
// ============================================================================

// Built-in role definition GUIDs
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var keyVaultSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
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

resource workerCredentialKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: workerCredentialKeyVaultName
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

// API -> Key Vault: Key Vault Secrets User
resource apiKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, apiPrincipalId, keyVault.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: apiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

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

// API -> ACR: AcrPull
resource apiAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
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

// Legacy-only worker credential-vault access. Workflow v3 defaults this off.
resource workerKeyVaultSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableWorkerCredentialKeyVaultSecretsOfficer) {
  name: guid(subscription().id, workerPrincipalId, workerCredentialKeyVault.id, keyVaultSecretsOfficerRoleId)
  scope: workerCredentialKeyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsOfficerRoleId)
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

// Worker -> Service Bus: Azure Service Bus Data Sender. The workflow-v3 worker
// persists continuation messages to the SQL outbox and its relay publishes them
// back to the same isolated queue.
resource workerServiceBusDataSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, workerPrincipalId, serviceBusQueue.id, serviceBusDataSenderRoleId)
  scope: serviceBusQueue
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', serviceBusDataSenderRoleId)
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Worker -> ACR: AcrPull
resource workerAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, workerPrincipalId, containerRegistry.id, acrPullRoleId)
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
  }
}
