// ============================================================================
// Module: Container App - Gateway API
// Purpose: ASP.NET Core Web API for the A365 Custom Gateway control and data plane
// ============================================================================

@description('Name of the Container App.')
param appName string

@description('Azure region for the resource.')
param location string

@description('Resource ID of the Container Apps environment.')
param environmentId string

@description('Container image reference (e.g., myacr.azurecr.io/gateway-api:latest).')
param containerImage string

@description('Login server URL of the Azure Container Registry.')
param acrLoginServer string

@description('Resource ID of the foundation workload identity authorized for the exact ACR and, when Purview is selected, API Purview tokens. Empty is retained only for the guarded historical system-identity deployment path.')
param imagePullIdentityResourceId string = ''

@description('CPU cores allocated to the container (e.g., 0.25, 0.5, 1.0).')
param cpu string = '0.5'

@description('Memory allocated to the container (e.g., 0.5Gi, 1Gi, 2Gi).')
param memory string = '1Gi'

@description('Minimum number of replicas.')
@minValue(0)
param minReplicas int = 0

@description('Maximum number of replicas.')
@minValue(1)
param maxReplicas int = 3

@description('Target port for the container.')
param targetPort int = 8080

@description('Fully qualified domain name of the Azure SQL Server.')
param sqlServerFqdn string

@description('Name of the Azure SQL database.')
param sqlDatabaseName string

@description('Fully qualified namespace of the Azure Service Bus (e.g., myns.servicebus.windows.net).')
param serviceBusNamespace string

@description('Name of the Service Bus queue for provisioning messages.')
param serviceBusQueueName string = 'gateway-provisioning-v3'

@description('Expose whether new provisioning registrations may be accepted. Must match the worker execution gate.')
param provisioningExecutionEnabled bool = false

@description('Keep authenticated development registration available without an expiring exact binding. Must remain false outside development.')
param continuousDevelopmentProvisioningEnabled bool = false

@description('Enable the development-only delegated administrator Agent 365 Registry action.')
param agent365DelegatedRegistryEnabled bool = false

@description('Keep authenticated delegated Registry completion available in continuous development mode.')
param agent365DelegatedRegistryContinuousDevelopmentAccess bool = false

@description('URI of the Azure Key Vault.')
param keyVaultUri string

@description('Strict non-secret bootstrap capability evidence. Enabled=false is allowed only for the inert identity deployment.')
param bootstrapCapabilities object

@description('Connection string for Application Insights.')
param appInsightsConnectionString string

@description('Blob storage endpoint URI.')
param blobStorageEndpoint string

@description('Name of the blob storage container.')
param blobStorageContainerName string = 'a365-gateway-interactions'

@description('Entra ID tenant ID.')
param entraIdTenantId string

@description('Entra ID client (application) ID.')
param entraIdClientId string

@description('Bare Gateway API client ID required by the Microsoft identity platform v2 aud claim.')
param entraIdAudience string

@description('Microsoft first-party application IDs required for an existing blueprint to be compatible with Agent 365 through this deployment.')
@maxLength(10)
param agent365ManagerApplicationIds array = []

@description('Enable the Microsoft Purview Graph adapter only after tenant permissions, policy, licensing, token roles, and runtime prerequisites are verified.')
param purviewEnabled bool = false

@description('Resource ID of the API-owned user-assigned identity used for Purview protected traffic and worker readiness.')
param purviewRuntimeIdentityResourceId string = ''

@description('Client ID of the API-owned user-assigned identity used for Purview Graph tokens.')
param purviewRuntimeIdentityClientId string = ''

@description('Principal ID expected in every Purview Graph token acquired by this host.')
param purviewRuntimeIdentityPrincipalId string = ''

@description('Enable Azure AI Content Safety Prompt Shields for registration-level prompt evaluation.')
param promptShieldEnabled bool = false

@description('Azure AI Content Safety endpoint used by Prompt Shields.')
param promptShieldEndpoint string = ''

@description('Enable the bounded read-only bootstrap database attestation endpoint.')
param databaseAttestationEnabled bool = false

@description('Exact bootstrap deployment ownership identifier expected in the durable database marker.')
param databaseAttestationDeploymentOwnershipId string = ''

@description('Exact accepted deployment-source fingerprint expected in the durable database marker.')
param databaseAttestationAcceptedSourceFingerprint string = ''

@description('Exact current reviewed schema fingerprint captured after bootstrap initialization.')
param databaseAttestationExpectedSchemaFingerprint string = ''

@description('Exact Azure SQL server FQDN bound into the durable database marker.')
param databaseAttestationSqlServerFqdn string = ''

@description('Exact database name bound into the durable database marker.')
param databaseAttestationDatabaseName string = ''

@description('Exact Gateway API database principal name.')
param databaseAttestationApiPrincipalName string = ''

@description('Exact Gateway API managed-identity client ID stored as the database principal SID.')
param databaseAttestationApiPrincipalClientId string = ''

@description('Exact Gateway worker database principal name.')
param databaseAttestationWorkerPrincipalName string = ''

@description('Exact Gateway worker managed-identity client ID stored as the database principal SID.')
param databaseAttestationWorkerPrincipalClientId string = ''

@secure()
@description('Existing application-scoped Container Apps secrets to preserve unchanged during a full ARM PUT. Values must come directly from the resource provider listSecrets operation and must never be logged or output.')
param preservedConfigurationSecrets object = {}

@description('Tags to apply to the resource.')
param tags object = {}

var managerApplicationEnvironmentVariables = [for (managerApplicationId, index) in agent365ManagerApplicationIds: {
  name: 'Agent365__ManagerApplicationIds__${index}'
  value: string(managerApplicationId)
}]
var userAssignedIdentities = union(
  empty(imagePullIdentityResourceId)
    ? {}
    : {
        '${imagePullIdentityResourceId}': {}
      },
  empty(purviewRuntimeIdentityResourceId)
    ? {}
    : {
        '${purviewRuntimeIdentityResourceId}': {}
      })
var hasUserAssignedIdentity = !empty(imagePullIdentityResourceId) || !empty(purviewRuntimeIdentityResourceId)

// ============================================================================
// Resources
// ============================================================================

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: tags
  // The empty branch preserves only the guarded historical system-identity
  // deployment path. Clean bootstrap always supplies the pre-authorized UAMI.
  identity: !hasUserAssignedIdentity
    ? {
        type: 'SystemAssigned'
      }
    : {
        type: 'SystemAssigned, UserAssigned'
        userAssignedIdentities: userAssignedIdentities
      }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Single'
      // Container Apps create-or-update owns this collection. Carry the
      // write-only values through a secure nested-deployment parameter so an
      // unrelated API revision cannot silently delete existing app secrets.
      secrets: preservedConfigurationSecrets.?value ?? []
      registries: [
        {
          server: acrLoginServer
          identity: empty(imagePullIdentityResourceId) ? 'system' : imagePullIdentityResourceId
        }
      ]
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
        allowInsecure: false
      }
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
          env: concat([
            {
              name: 'ConnectionStrings__GatewayDb'
              value: 'Server=tcp:${sqlServerFqdn},1433;Database=${sqlDatabaseName};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;'
            }
            {
              name: 'ServiceBus__FullyQualifiedNamespace'
              value: serviceBusNamespace
            }
            {
              name: 'ServiceBus__QueueName'
              value: serviceBusQueueName
            }
            {
              name: 'Provisioning__ExecutionEnabled'
              value: string(provisioningExecutionEnabled)
            }
            {
              name: 'Provisioning__AllowContinuousDevelopmentAccess'
              value: string(continuousDevelopmentProvisioningEnabled)
            }
            {
              name: 'BlobStorage__ServiceUri'
              value: blobStorageEndpoint
            }
            {
              name: 'BlobStorage__ContainerName'
              value: blobStorageContainerName
            }
            {
              name: 'Observability__ApplicationInsightsConnectionString'
              value: appInsightsConnectionString
            }
            {
              name: 'EntraId__TenantId'
              value: entraIdTenantId
            }
            {
              name: 'EntraId__ClientId'
              value: entraIdClientId
            }
            {
              name: 'EntraId__Audience'
              value: entraIdAudience
            }
            {
              name: 'EntraId__ClientCredentials__0__SourceType'
              value: 'SignedAssertionFromManagedIdentity'
            }
            {
              name: 'EntraId__ClientCredentials__0__TokenExchangeUrl'
              value: 'api://AzureADTokenExchange'
            }
            {
              name: 'KeyVault__VaultUri'
              value: keyVaultUri
            }
            {
              name: 'BootstrapCapabilities__Enabled'
              value: string(bootstrapCapabilities.enabled)
            }
            {
              name: 'BootstrapCapabilities__AttestedAtUtc'
              value: bootstrapCapabilities.readbackAtUtc
            }
            {
              name: 'BootstrapCapabilities__DeploymentOwnershipId'
              value: bootstrapCapabilities.deploymentOwnershipId
            }
            {
              name: 'BootstrapCapabilities__AcceptedSourceFingerprint'
              value: bootstrapCapabilities.sourceFingerprint
            }
            {
              name: 'BootstrapCapabilities__Agent365RegistrationBeta__Status'
              value: bootstrapCapabilities.agent365RegistrationBeta.status
            }
            {
              name: 'BootstrapCapabilities__Agent365RegistrationBeta__Agent365RegistryApiApplicationId'
              value: bootstrapCapabilities.agent365RegistrationBeta.registryApiApplicationId
            }
            {
              name: 'BootstrapCapabilities__PromptShields__Status'
              value: bootstrapCapabilities.promptShields.status
            }
            {
              name: 'BootstrapCapabilities__PromptShields__ContentSafetyAccountResourceId'
              value: bootstrapCapabilities.promptShields.contentSafetyAccountResourceId
            }
            {
              name: 'BootstrapCapabilities__PromptShields__ContentSafetyEndpoint'
              value: bootstrapCapabilities.promptShields.contentSafetyEndpoint
            }
            {
              name: 'BootstrapCapabilities__PromptShields__GatewayApiManagedIdentityPrincipalObjectId'
              value: bootstrapCapabilities.promptShields.gatewayApiManagedIdentityPrincipalObjectId
            }
            {
              name: 'BootstrapCapabilities__Purview__Status'
              value: bootstrapCapabilities.purview.status
            }
            {
              name: 'BootstrapCapabilities__Purview__GatewayApiManagedIdentityPrincipalObjectId'
              value: bootstrapCapabilities.purview.gatewayApiManagedIdentityPrincipalObjectId
            }
            {
              name: 'BootstrapCapabilities__Purview__PurviewRuntimeManagedIdentityPrincipalObjectId'
              value: bootstrapCapabilities.purview.purviewRuntimeManagedIdentityPrincipalObjectId
            }
            {
              name: 'BootstrapCapabilities__Purview__PurviewAutomationApplicationId'
              value: bootstrapCapabilities.purview.automationApplicationId
            }
            {
              name: 'BootstrapCapabilities__Purview__PurviewAutomationServicePrincipalObjectId'
              value: bootstrapCapabilities.purview.automationServicePrincipalObjectId
            }
            {
              name: 'BootstrapCapabilities__Purview__KeyVaultResourceId'
              value: bootstrapCapabilities.purview.keyVaultResourceId
            }
            {
              name: 'BootstrapCapabilities__Purview__KeyVaultHost'
              value: bootstrapCapabilities.purview.keyVaultHost
            }
            {
              name: 'BootstrapCapabilities__Purview__CertificateName'
              value: bootstrapCapabilities.purview.certificateName
            }
            {
              name: 'BootstrapCapabilities__Purview__CertificateSecretUri'
              value: bootstrapCapabilities.purview.certificateSecretUri
            }
            {
              name: 'Agent365__TenantId'
              value: entraIdTenantId
            }
            {
              name: 'Agent365__DelegatedRegistry__Enabled'
              value: string(agent365DelegatedRegistryEnabled)
            }
            {
              name: 'Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess'
              value: string(agent365DelegatedRegistryContinuousDevelopmentAccess)
            }
            {
              name: 'Agent365__DelegatedRegistry__Scopes__0'
              value: 'https://graph.microsoft.com/AgentRegistration.ReadWrite.All'
            }
            {
              name: 'Agent365__DelegatedRegistry__Scopes__1'
              value: 'https://graph.microsoft.com/AgentRegistration.Read.All'
            }
            {
              name: 'Purview__Enabled'
              value: string(purviewEnabled)
            }
            {
              name: 'PurviewRuntimeIdentity__ManagedIdentityClientId'
              value: purviewRuntimeIdentityClientId
            }
            {
              name: 'PurviewRuntimeIdentity__ManagedIdentityPrincipalObjectId'
              value: purviewRuntimeIdentityPrincipalId
            }
            {
              name: 'PromptShield__Enabled'
              value: string(promptShieldEnabled)
            }
            {
              name: 'PromptShield__Endpoint'
              value: promptShieldEndpoint
            }
            {
              name: 'PromptShield__ApiVersion'
              value: '2024-09-01'
            }
            {
              name: 'DatabaseAttestation__Enabled'
              value: string(databaseAttestationEnabled)
            }
            {
              name: 'DatabaseAttestation__DeploymentOwnershipId'
              value: databaseAttestationDeploymentOwnershipId
            }
            {
              name: 'DatabaseAttestation__AcceptedSourceFingerprint'
              value: databaseAttestationAcceptedSourceFingerprint
            }
            {
              name: 'DatabaseAttestation__ExpectedSchemaFingerprint'
              value: databaseAttestationExpectedSchemaFingerprint
            }
            {
              name: 'DatabaseAttestation__SqlServerFqdn'
              value: databaseAttestationSqlServerFqdn
            }
            {
              name: 'DatabaseAttestation__DatabaseName'
              value: databaseAttestationDatabaseName
            }
            {
              name: 'DatabaseAttestation__ApiPrincipalName'
              value: databaseAttestationApiPrincipalName
            }
            {
              name: 'DatabaseAttestation__ApiPrincipalClientId'
              value: databaseAttestationApiPrincipalClientId
            }
            {
              name: 'DatabaseAttestation__WorkerPrincipalName'
              value: databaseAttestationWorkerPrincipalName
            }
            {
              name: 'DatabaseAttestation__WorkerPrincipalClientId'
              value: databaseAttestationWorkerPrincipalClientId
            }
            {
              name: 'OutboxRelay__PollingIntervalSeconds'
              value: '5'
            }
            {
              name: 'OutboxRelay__BatchSize'
              value: '10'
            }
            {
              name: 'ASPNETCORE_ENVIRONMENT'
              value: 'Production'
            }
          ], managerApplicationEnvironmentVariables)
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: targetPort
              }
              periodSeconds: 10
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health/ready'
                port: targetPort
              }
              periodSeconds: 15
              initialDelaySeconds: 5
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
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the Container App.')
output appId string = containerApp.id

@description('Name of the Container App.')
output appName string = containerApp.name

@description('Principal ID of the system-assigned managed identity.')
output principalId string = containerApp.identity.principalId

@description('Effective delegated administrator Registry action gate.')
output agent365DelegatedRegistryEnabled bool = agent365DelegatedRegistryEnabled

@description('FQDN of the Container App ingress.')
output fqdn string = containerApp.properties.configuration.ingress.fqdn
