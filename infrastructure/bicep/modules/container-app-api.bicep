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

@description('Optional explicit UTC ISO-8601 deadline for provisioning admission. The API fails closed when this is missing, malformed, non-UTC, or expired.')
param provisioningAdmissionExpiresAtUtc string = ''

@description('Exact external agent ID authorized during the bounded initial-registration window.')
param provisioningAuthorizedExternalAgentId string = ''

@description('Exact Gateway registration ID authorized for an administrative retry window. Keep empty unless exact-bound retry is intended.')
param provisioningAuthorizedRetryAgentId string = ''

@description('Enable the development-only delegated administrator Agent 365 Registry action. This remains independently fail-closed from registration admission.')
param agent365DelegatedRegistryEnabled bool = false

@description('Keep authenticated delegated Registry completion available in continuous development mode.')
param agent365DelegatedRegistryContinuousDevelopmentAccess bool = false

@description('Independent UTC expiry for the delegated Registry completion action.')
param agent365DelegatedRegistryActionExpiresAtUtc string = ''

@description('Exact provisioning operation ID authorized for delegated Registry completion.')
param agent365DelegatedRegistryAuthorizedOperationId string = ''

@description('URI of the Azure Key Vault.')
param keyVaultUri string

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

@description('Entra ID audience for token validation.')
param entraIdAudience string

@description('Microsoft first-party application IDs required for an existing blueprint to be compatible with Agent 365 through this deployment.')
@maxLength(10)
param agent365ManagerApplicationIds array = []

@description('Enable the Microsoft Purview Graph adapter only after its tenant permissions, policy, licensing, and canary prerequisites are verified.')
param purviewEnabled bool = false

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

var admissionExpiryEnvironmentVariables = empty(provisioningAdmissionExpiresAtUtc) ? [] : [
  {
    name: 'Provisioning__AdmissionExpiresAtUtc'
    value: provisioningAdmissionExpiresAtUtc
  }
]

var provisioningBindingEnvironmentVariables = concat(
  empty(provisioningAuthorizedExternalAgentId) ? [] : [
    {
      name: 'Provisioning__AuthorizedExternalAgentId'
      value: provisioningAuthorizedExternalAgentId
    }
  ],
  empty(provisioningAuthorizedRetryAgentId) ? [] : [
    {
      name: 'Provisioning__AuthorizedRetryAgentId'
      value: provisioningAuthorizedRetryAgentId
    }
  ])

var delegatedRegistryActionEnvironmentVariables = concat(
  empty(agent365DelegatedRegistryActionExpiresAtUtc) ? [] : [
    {
      name: 'Agent365__DelegatedRegistry__ActionExpiresAtUtc'
      value: agent365DelegatedRegistryActionExpiresAtUtc
    }
  ],
  empty(agent365DelegatedRegistryAuthorizedOperationId) ? [] : [
    {
      name: 'Agent365__DelegatedRegistry__AuthorizedOperationId'
      value: agent365DelegatedRegistryAuthorizedOperationId
    }
  ])

// ============================================================================
// Resources
// ============================================================================

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
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
          identity: 'system'
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
              name: 'Provisioning__RequireExactAdmissionBinding'
              value: string(!continuousDevelopmentProvisioningEnabled)
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
              name: 'Agent365__TenantId'
              value: entraIdTenantId
            }
            {
              name: 'Agent365__DelegatedRegistry__Enabled'
              value: string(agent365DelegatedRegistryEnabled)
            }
            {
              name: 'Agent365__DelegatedRegistry__RequireExactActionBinding'
              value: string(!agent365DelegatedRegistryContinuousDevelopmentAccess)
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
          ], managerApplicationEnvironmentVariables, admissionExpiryEnvironmentVariables, provisioningBindingEnvironmentVariables, delegatedRegistryActionEnvironmentVariables)
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
