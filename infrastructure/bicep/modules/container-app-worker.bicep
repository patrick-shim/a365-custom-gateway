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

@description('Resource ID of the dedicated user-assigned identity authorized to pull runtime images from the exact ACR. Empty is retained only for the historical public-image blue/green identity bootstrap.')
param imagePullIdentityResourceId string = ''

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

@description('Maximum concurrent Service Bus callbacks in one replica. SQL session-owned job locks provide distributed ownership.')
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

@description('Object/principal ID of this worker managed identity, injected after identity bootstrap so provisioning can fail closed if the Graph caller changes.')
param agent365ProvisioningManagedIdentityPrincipalId string = ''

@description('Microsoft first-party application IDs independently accepted for Agent 365 blueprint managerApplications.')
@maxLength(10)
param agent365ManagerApplicationIds array = []

@description('Enable shared Service Bus processing, including the existing observability subjects.')
param processingEnabled bool = true

@description('Enable Microsoft-side provisioning execution. Disabled by default and independent from shared observability processing.')
param provisioningExecutionEnabled bool = false

@description('Enable the Purview runtime and policy-provisioning module.')
param purviewEnabled bool = false

@description('Enable app-only Security & Compliance PowerShell policy provisioning for new blueprints.')
param purviewPolicyProvisioningEnabled bool = false

@description('Microsoft 365 organization domain used by Connect-IPPSSession app-only authentication.')
param purviewPolicyProvisioningOrganization string = ''

@description('Application/client ID of the certificate-authenticated Purview automation application.')
param purviewPolicyProvisioningApplicationId string = ''

@description('Versionless Key Vault secret URI containing the base64 PKCS#12 automation certificate.')
param purviewPolicyProvisioningCertificateSecretUri string = ''

@description('Sensitive information type used by the reviewed default DLP rule template.')
param purviewDefaultSensitiveInformationType string = 'Credit Card Number'

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
  // The empty branch preserves only the historical public-image blue/green
  // identity bootstrap. Clean and current deployments always provide the
  // foundation-owned pull identity before this Container App is created.
  identity: empty(imagePullIdentityResourceId)
    ? {
        type: 'SystemAssigned'
      }
    : {
        type: 'SystemAssigned, UserAssigned'
        userAssignedIdentities: {
          '${imagePullIdentityResourceId}': {}
        }
      }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        {
          server: acrLoginServer
          identity: empty(imagePullIdentityResourceId) ? 'system' : imagePullIdentityResourceId
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
              name: 'Purview__Enabled'
              value: string(purviewEnabled)
            }
            {
              name: 'Purview__PolicyProvisioningEnabled'
              value: string(purviewPolicyProvisioningEnabled)
            }
            {
              name: 'Purview__PolicyProvisioningOrganization'
              value: purviewPolicyProvisioningOrganization
            }
            {
              name: 'Purview__PolicyProvisioningApplicationId'
              value: purviewPolicyProvisioningApplicationId
            }
            {
              name: 'Purview__PolicyProvisioningCertificateSecretUri'
              value: purviewPolicyProvisioningCertificateSecretUri
            }
            {
              name: 'Purview__DefaultSensitiveInformationType'
              value: purviewDefaultSensitiveInformationType
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

@description('Effective maximum number of worker replicas.')
output maxReplicas int = maxReplicas

@description('Effective maximum concurrent Service Bus callbacks per replica.')
output maxConcurrentCalls int = maxConcurrentCalls
