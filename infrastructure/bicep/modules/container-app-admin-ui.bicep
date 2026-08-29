// ============================================================================
// Module: Container App - Gateway Admin UI
// Purpose: Interactive Server Blazor management portal for the A365 Gateway
// ============================================================================

@description('Name of the Admin UI Container App.')
@minLength(2)
@maxLength(32)
param appName string

@description('Name of the user-assigned identity used for ACR and Key Vault access.')
@minLength(3)
@maxLength(128)
param identityName string

@description('Azure region for the resources.')
param location string

@description('Resource ID of the existing Container Apps environment.')
param environmentId string

@description('Container image reference for the Admin UI.')
@minLength(1)
param containerImage string

@description('Login server URL of the existing Azure Container Registry.')
@minLength(1)
param acrLoginServer string

@description('Name of the existing Azure Container Registry.')
@minLength(5)
param containerRegistryName string

@description('Name of the existing Azure Key Vault.')
@minLength(1)
param keyVaultName string

@description('Versionless Key Vault secret URI containing the Admin UI Entra application client secret. The secret value is never passed to Bicep.')
@secure()
@minLength(1)
param entraClientSecretKeyVaultSecretUri string

@description('Microsoft Entra tenant ID for the single-tenant Admin UI application.')
@minLength(1)
param entraTenantId string

@description('Microsoft Entra client/application ID for the Admin UI application registration.')
@minLength(1)
param entraClientId string

@description('Delegated Gateway API scope requested by the Admin UI.')
@minLength(1)
param gatewayApiScope string

@description('HTTPS base URL of the deployed Gateway API, including a trailing slash.')
@minLength(1)
param gatewayApiBaseUrl string

@description('CPU cores allocated to the Admin UI container.')
param cpu string = '0.5'

@description('Memory allocated to the Admin UI container.')
param memory string = '1Gi'

@description('Minimum number of Admin UI replicas.')
@minValue(1)
param minReplicas int = 1

@description('Maximum number of Admin UI replicas. Keep at one until shared ASP.NET Core Data Protection keys are configured.')
@minValue(1)
param maxReplicas int = 1

@description('Gateway API request timeout in seconds.')
@minValue(5)
@maxValue(120)
param gatewayApiTimeoutSeconds int = 120

@description('Target port exposed by the Admin UI container.')
param targetPort int = 8080

@description('Tags to apply to the resources.')
param tags object = {}

// Built-in role definition IDs.
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var entraClientSecretName = 'admin-ui-entra-client-secret'

// ============================================================================
// Existing resources
// ============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource adminUiClientSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = {
  parent: keyVault
  name: entraClientSecretName
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: containerRegistryName
}

// ============================================================================
// Identity and least-privilege access
// ============================================================================

resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(adminUiClientSecret.id, deploymentIdentity.id, keyVaultSecretsUserRoleId)
  scope: adminUiClientSecret
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, deploymentIdentity.id, acrPullRoleId)
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// Admin UI Container App
// ============================================================================

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deploymentIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
        allowInsecure: false
        stickySessions: {
          affinity: 'sticky'
        }
      }
      registries: [
        {
          server: acrLoginServer
          identity: deploymentIdentity.id
        }
      ]
      secrets: [
        {
          name: entraClientSecretName
          keyVaultUrl: entraClientSecretKeyVaultSecretUri
          identity: deploymentIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: appName
          image: containerImage
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: [
            {
              name: 'ASPNETCORE_ENVIRONMENT'
              value: 'Production'
            }
            {
              name: 'ASPNETCORE_HTTP_PORTS'
              value: string(targetPort)
            }
            {
              name: 'ASPNETCORE_FORWARDEDHEADERS_ENABLED'
              value: 'true'
            }
            {
              name: 'EntraId__Instance'
              value: environment().authentication.loginEndpoint
            }
            {
              name: 'EntraId__TenantId'
              value: entraTenantId
            }
            {
              name: 'EntraId__ClientId'
              value: entraClientId
            }
            {
              name: 'EntraId__ClientSecret'
              secretRef: entraClientSecretName
            }
            {
              name: 'EntraId__CallbackPath'
              value: '/signin-oidc'
            }
            {
              name: 'EntraId__SignedOutCallbackPath'
              value: '/signout-callback-oidc'
            }
            {
              name: 'GatewayApi__BaseUrl'
              value: gatewayApiBaseUrl
            }
            {
              name: 'GatewayApi__Scopes__0'
              value: gatewayApiScope
            }
            {
              name: 'GatewayApi__TimeoutSeconds'
              value: string(gatewayApiTimeoutSeconds)
            }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: targetPort
              }
              periodSeconds: 15
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health'
                port: targetPort
              }
              periodSeconds: 10
              initialDelaySeconds: 5
              failureThreshold: 3
            }
            {
              type: 'Startup'
              httpGet: {
                path: '/health'
                port: targetPort
              }
              periodSeconds: 5
              failureThreshold: 30
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-requests'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [
    acrPull
    keyVaultSecretsUser
  ]
}

// ============================================================================
// Outputs (no secrets)
// ============================================================================

@description('Resource ID of the Admin UI Container App.')
output appId string = containerApp.id

@description('FQDN of the Admin UI Container App ingress.')
output fqdn string = containerApp.properties.configuration.ingress.fqdn

@description('HTTPS URL of the Admin UI.')
output url string = 'https://${containerApp.properties.configuration.ingress.fqdn}'

@description('Required Entra redirect URI for sign-in.')
output signInRedirectUri string = 'https://${containerApp.properties.configuration.ingress.fqdn}/signin-oidc'

@description('Required Entra redirect URI for signed-out callbacks.')
output signedOutCallbackUri string = 'https://${containerApp.properties.configuration.ingress.fqdn}/signout-callback-oidc'

@description('Principal ID of the Admin UI deployment identity.')
output principalId string = deploymentIdentity.properties.principalId
