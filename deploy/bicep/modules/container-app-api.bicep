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
param serviceBusQueueName string = 'gateway-provisioning'

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

@description('Tags to apply to the resource.')
param tags object = {}

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
          env: [
            {
              name: 'ConnectionStrings__GatewayDb'
              value: 'Server=tcp:${sqlServerFqdn},1433;Database=${sqlDatabaseName};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;'
            }
            {
              name: 'ServiceBus__ConnectionString'
              value: serviceBusNamespace
            }
            {
              name: 'ServiceBus__QueueName'
              value: serviceBusQueueName
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
              name: 'KeyVault__VaultUri'
              value: keyVaultUri
            }
            {
              name: 'Agent365__TenantId'
              value: entraIdTenantId
            }
            {
              name: 'Purview__Enabled'
              value: 'true'
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
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health/checks'
                port: targetPort
              }
              periodSeconds: 10
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health/checks'
                port: targetPort
              }
              periodSeconds: 15
              initialDelaySeconds: 5
            }
            {
              type: 'Startup'
              httpGet: {
                path: '/health/checks'
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

@description('FQDN of the Container App ingress.')
output fqdn string = containerApp.properties.configuration.ingress.fqdn
