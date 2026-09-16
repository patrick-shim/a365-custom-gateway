targetScope = 'resourceGroup'

param executorName string
@secure()
param appSettings object

resource executor 'Microsoft.Web/sites@2024-11-01' existing = {
  name: executorName
}
resource settings 'Microsoft.Web/sites/config@2024-11-01' = {
  parent: executor
  name: 'appsettings'
  properties: appSettings
}
