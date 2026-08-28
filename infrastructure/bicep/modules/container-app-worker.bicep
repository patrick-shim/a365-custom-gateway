// ============================================================================
// Module: Container App - Provisioning Worker
// Purpose: Background worker for async provisioning operations in the A365 Custom Gateway
// ============================================================================

@description('Name of the Container App.')
param appName string

@description('Azure region for the resource.')
param location string

@description('Resource ID of the Container Apps environment.')
param environmentId string

@description('Container image reference (e.g., myacr.azurecr.io/gateway-worker:latest).')
param containerImage string

@description('Login server URL of the Azure Container Registry.')
param acrLoginServer string

@description('CPU cores allocated to the container (e.g., 0.25, 0.5, 1.0).')
param cpu string = '0.25'

@description('Memory allocated to the container (e.g., 0.5Gi, 1Gi, 2Gi).')
param memory string = '0.5Gi'

@description('Minimum number of replicas.')
@minValue(0)
param minReplicas int = 0

@description('Maximum number of replicas.')
@minValue(1)
param maxReplicas int = 3

@description('Maximum concurrent Service Bus callbacks in one replica. Provisioning canaries use one as rollout containment; SQL session-owned job locks provide distributed ownership.')
@minValue(1)
param maxConcurrentCalls int = 5

@description('Fully qualified namespace of the Azure Service Bus (e.g., myns.servicebus.windows.net).')
param serviceBusNamespace string

@description('Bare Azure Service Bus namespace name used by the KEDA scaler (e.g., myns).')
param serviceBusNamespaceName string

@description('Name of the Service Bus queue for provisioning messages.')
param serviceBusQueueName string = 'gateway-provisioning-v3'

@description('Fully qualified domain name of the Azure SQL Server.')
param sqlServerFqdn string

@description('Name of the Azure SQL database.')
param sqlDatabaseName string

@description('URI of the Azure Key Vault.')
param keyVaultUri string

@description('Connection string for Application Insights.')
param appInsightsConnectionString string

@description('Entra ID tenant ID.')
param entraIdTenantId string

@description('Gateway service hostname emitted as the server.address observability attribute.')
param agent365ObservabilityServerAddress string

@description('Client/application ID of the Gateway API whose ExternalAgent app role is assigned to provisioned external-agent service principals.')
param agent365GatewayApiApplicationClientId string

@description('Configured token audience of the Gateway API.')
param agent365GatewayApiAudience string

@description('HTTPS base URL used for the post-provisioning Agent Identity access proof.')
param agent365GatewayApiBaseUrl string

@description('HTTPS URI of the Key Vault that receives generated external-agent credentials.')
param agent365CredentialKeyVaultUri string

@description('Object/principal ID of this worker managed identity, injected after identity bootstrap so provisioning can fail closed if the Graph caller changes.')
param agent365ProvisioningManagedIdentityPrincipalId string = ''

@description('Microsoft first-party application IDs independently accepted for Agent 365 blueprint managerApplications.')
@maxLength(10)
param agent365ManagerApplicationIds array = []

@description('Enable shared Service Bus processing, including the existing observability subjects.')
param processingEnabled bool = true

@description('Enable Microsoft-side provisioning execution. Disabled by default and independent from shared observability processing.')
param provisioningExecutionEnabled bool = false

@description('Agent 365 registry provider selected by the provisioning adapter.')
@allowed([
  'Disabled'
  'DirectRegistryPreview'
])
param agent365RegistryProvider string = 'Disabled'

@description('Explicit development-only gate for the unsupported-for-production Microsoft Graph beta registry provider.')
param agent365DirectRegistryPreviewEnabled bool = false

@description('Tags to apply to the resource.')
param tags object = {}

var managerApplicationEnvironmentVariables = [for (managerApplicationId, index) in agent365ManagerApplicationIds: {
  name: 'Agent365__ManagerApplicationIds__${index}'
  value: string(managerApplicationId)
}]

// ============================================================================
// Resources
// ============================================================================

resource containerApp 'Microsoft.App/containerApps@2025-01-01' = {
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
      registries: [
        {
          server: acrLoginServer
          identity: 'system'
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
              name: 'OutboxRelay__Enabled'
              value: 'false'
            }
            {
              name: 'Observability__ApplicationInsightsConnectionString'
              value: appInsightsConnectionString
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
              name: 'Agent365__ObservabilityServerAddress'
              value: agent365ObservabilityServerAddress
            }
            {
              name: 'Agent365__GatewayApiApplicationClientId'
              value: agent365GatewayApiApplicationClientId
            }
            {
              name: 'Agent365__GatewayApiAudience'
              value: agent365GatewayApiAudience
            }
            {
              name: 'Agent365__GatewayApiBaseUrl'
              value: agent365GatewayApiBaseUrl
            }
            {
              name: 'Agent365__CredentialKeyVaultUri'
              value: agent365CredentialKeyVaultUri
            }
            {
              name: 'Agent365__ProvisioningManagedIdentityPrincipalId'
              value: agent365ProvisioningManagedIdentityPrincipalId
            }
            {
              name: 'ProvisioningWorker__QueueName'
              value: serviceBusQueueName
            }
            {
              name: 'ProvisioningWorker__MaxConcurrentCalls'
              value: string(maxConcurrentCalls)
            }
            {
              name: 'ProvisioningWorker__ProcessingEnabled'
              value: string(processingEnabled)
            }
            {
              name: 'ProvisioningWorker__ProvisioningExecutionEnabled'
              value: string(provisioningExecutionEnabled)
            }
            {
              name: 'Agent365__RegistryProvider'
              value: agent365RegistryProvider
            }
            {
              name: 'Agent365__DirectRegistryPreviewEnabled'
              value: string(agent365DirectRegistryPreviewEnabled)
            }
            {
              name: 'DOTNET_ENVIRONMENT'
              value: 'Production'
            }
          ], managerApplicationEnvironmentVariables)
        }
      ]
      scale: {
        minReplicas: processingEnabled ? minReplicas : 0
        maxReplicas: maxReplicas
        rules: processingEnabled ? [
          {
            name: 'service-bus-queue-rule'
            custom: {
              type: 'azure-servicebus'
              metadata: {
                queueName: serviceBusQueueName
                namespace: serviceBusNamespaceName
                messageCount: '5'
              }
              auth: []
              identity: 'system'
            }
          }
        ] : []
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

@description('Effective shared worker processing gate. This remains independent from provisioning execution.')
output processingEnabled bool = processingEnabled

@description('Effective provisioning-specific execution gate.')
output provisioningExecutionEnabled bool = provisioningExecutionEnabled

@description('Effective registry provider.')
output agent365RegistryProvider string = agent365RegistryProvider

@description('Effective DirectRegistryPreview acknowledgement gate.')
output agent365DirectRegistryPreviewEnabled bool = agent365DirectRegistryPreviewEnabled

@description('Effective maximum number of worker replicas.')
output maxReplicas int = maxReplicas

@description('Effective maximum concurrent Service Bus callbacks per replica.')
output maxConcurrentCalls int = maxConcurrentCalls
