// ============================================================================
// Module: Runtime image-pull identity
// Purpose: Establish ACR pull authorization before runtime Container Apps exist
// ============================================================================

@description('Name of the dedicated user-assigned identity used only for runtime ACR image pulls.')
@minLength(3)
@maxLength(128)
param identityName string

@description('Azure region for the user-assigned identity.')
param location string

@description('Name of the exact Azure Container Registry that stores runtime images.')
@minLength(5)
param containerRegistryName string

@description('Canonical source fingerprint accepted by the bootstrap plan and stamped on the runtime image-pull identity.')
@minLength(71)
@maxLength(71)
param bootstrapSourceFingerprint string

@description('Tags to apply to the user-assigned identity.')
param tags object = {}

var acrPullRoleDefinitionGuid = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var acrPullRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  acrPullRoleDefinitionGuid
)

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: containerRegistryName
}

resource imagePullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: union(tags, {
    bootstrapSourceFingerprint: bootstrapSourceFingerprint
  })
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, imagePullIdentity.id, acrPullRoleDefinitionGuid)
  scope: containerRegistry
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: imagePullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Resource ID of the dedicated runtime image-pull identity.')
output runtimeImagePullIdentityId string = imagePullIdentity.id

@description('Principal ID of the dedicated runtime image-pull identity.')
output runtimeImagePullIdentityPrincipalId string = imagePullIdentity.properties.principalId

@description('Resource ID of the exact AcrPull role assignment.')
output runtimeImagePullAcrPullRoleAssignmentId string = acrPull.id
