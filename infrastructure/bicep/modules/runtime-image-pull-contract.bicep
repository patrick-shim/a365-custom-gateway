// ============================================================================
// Module: Runtime Image-Pull Contract Validation
// Purpose: Reject partial dedicated identity evidence before workload deployment
// ============================================================================

targetScope = 'resourceGroup'

@description('Accepted runtime image-pull mode. The parent computes this from the exact three-value receipt contract.')
@allowed([
  'DedicatedUserAssignedIdentity'
  'LegacySystemAssignedIdentity'
])
param mode string

@description('Validated runtime image-pull mode.')
output mode string = mode
