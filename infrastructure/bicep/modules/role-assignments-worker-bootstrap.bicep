// ============================================================================
// Module: blue/green provisioning worker bootstrap role assignments
// Purpose: grant only the new worker's Azure data-plane roles. This module does
// not reference or change the API or the historical worker.
// ============================================================================

@description('Principal ID of the new worker system-assigned managed identity.')
param workerPrincipalId string

@description('Name of the dedicated provisioning credential Key Vault.')
param workerCredentialKeyVaultName string

@description('Legacy-only switch granting Key Vault Secrets Officer. Workflow v3 bootstrap defaults this off.')
param enableWorkerCredentialKeyVaultSecretsOfficer bool = false

@description('Name of the existing Azure Container Registry.')
param containerRegistryName string

var keyVaultSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource workerCredentialKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: workerCredentialKeyVaultName
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: containerRegistryName
}

resource workerKeyVaultSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableWorkerCredentialKeyVaultSecretsOfficer) {
  name: guid(subscription().id, workerPrincipalId, workerCredentialKeyVault.id, keyVaultSecretsOfficerRoleId)
  scope: workerCredentialKeyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsOfficerRoleId)
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource workerAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, workerPrincipalId, containerRegistry.id, acrPullRoleId)
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: workerPrincipalId
    principalType: 'ServicePrincipal'
  }
}
