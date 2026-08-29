$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Experience.psm1') -Force

Describe 'Exact live Container App configuration contracts' {
    InModuleScope Experience {
        BeforeEach {
            $script:runtimePullIdentityId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-runtime-pull-dev'
            $attachedIdentities = [pscustomobject]@{}
            $attachedIdentities | Add-Member -NotePropertyName $script:runtimePullIdentityId -NotePropertyValue ([pscustomobject]@{})
            $script:runtimeContainerApp = [pscustomobject]@{
                name = 'ca-gateway-api-dev'; location = 'koreacentral'
                identity = [pscustomobject]@{
                    type = 'SystemAssigned, UserAssigned'
                    principalId = 'principal'
                    userAssignedIdentities = $attachedIdentities
                }
                properties = [pscustomobject]@{
                    provisioningState = 'Succeeded'; managedEnvironmentId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/cae'
                    configuration = [pscustomobject]@{
                        activeRevisionsMode = 'Single'; secrets = @()
                        registries = @([pscustomobject]@{ server = 'safe.azurecr.io'; identity = $script:runtimePullIdentityId })
                        ingress = [pscustomobject]@{ external = $true; allowInsecure = $false; targetPort = 8080; transport = 'auto'; fqdn = 'api.example.test' }
                    }
                    template = [pscustomobject]@{
                        containers = @([pscustomobject]@{ name = 'ca-gateway-api-dev'; image = "safe.azurecr.io/gateway-api@sha256:$('a' * 64)" })
                    }
                }
            }
        }

        It 'accepts only the exact value and secret-reference environment sets' {
            $entries = @(
                [pscustomobject]@{ name = 'Tenant'; value = 'expected' },
                [pscustomobject]@{ name = 'Credential'; secretRef = 'reviewed-secret' }
            )
            Assert-GatewayExactContainerEnvironment -Entries $entries `
                -ExpectedValues ([ordered]@{ Tenant = 'expected' }) `
                -ExpectedSecretRefs ([ordered]@{ Credential = 'reviewed-secret' }) |
                Should -BeTrue
        }

        It 'rejects duplicate, additional, or secret-backed value entries' {
            { Assert-GatewayExactContainerEnvironment -Entries @(
                    [pscustomobject]@{ name = 'Tenant'; value = 'expected' },
                    [pscustomobject]@{ name = 'Tenant'; value = 'expected' }
                ) -ExpectedValues ([ordered]@{ Tenant = 'expected' }) } |
                Should -Throw '*cardinality*'

            { Assert-GatewayExactContainerEnvironment -Entries @(
                    [pscustomobject]@{ name = 'Tenant'; secretRef = 'fallback' }
                ) -ExpectedValues ([ordered]@{ Tenant = 'expected' }) } |
                Should -Throw '*value contract*'

            { Assert-GatewayExactContainerEnvironment -Entries @(
                    [pscustomobject]@{ name = 'Tenant'; value = 'expected' },
                    [pscustomobject]@{ name = 'ClientSecret'; secretRef = 'fallback' }
                ) -ExpectedValues ([ordered]@{ Tenant = 'expected' }) } |
                Should -Throw '*cardinality*'
        }

        It 'rejects registry password fallbacks and any additional registry' {
            { Assert-GatewayExactContainerRegistry -Registries @(
                    [pscustomobject]@{ server = 'safe.azurecr.io'; identity = 'system'; passwordSecretRef = 'fallback' }
                ) -ExpectedServer 'safe.azurecr.io' -ExpectedIdentity 'system' } |
                Should -Throw '*managed-identity-backed*'

            { Assert-GatewayExactContainerRegistry -Registries @(
                    [pscustomobject]@{ server = 'safe.azurecr.io'; identity = 'system' },
                    [pscustomobject]@{ server = 'other.azurecr.io'; identity = 'system' }
                ) -ExpectedServer 'safe.azurecr.io' -ExpectedIdentity 'system' } |
                Should -Throw '*managed-identity-backed*'
        }

        It 'accepts an HTTPS-only dual-identity envelope and rejects insecure ingress' {
            Assert-GatewayExactSystemContainerAppEnvelope -App $script:runtimeContainerApp -ExpectedName 'ca-gateway-api-dev' `
                -ExpectedLocation 'koreacentral' -ExpectedPrincipalId 'principal' `
                -ExpectedImagePullIdentityResourceId $script:runtimePullIdentityId `
                -ExpectedManagedEnvironmentId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/cae' `
                -ExpectedRegistryServer 'safe.azurecr.io' -ExpectedImage "safe.azurecr.io/gateway-api@sha256:$('a' * 64)" `
                -ExternalIngress $true -ExpectedFqdn 'api.example.test' | Should -BeTrue

            $script:runtimeContainerApp.properties.configuration.ingress.allowInsecure = $true
            { Assert-GatewayExactSystemContainerAppEnvelope -App $script:runtimeContainerApp -ExpectedName 'ca-gateway-api-dev' `
                    -ExpectedLocation 'koreacentral' -ExpectedPrincipalId 'principal' `
                    -ExpectedImagePullIdentityResourceId $script:runtimePullIdentityId `
                    -ExpectedManagedEnvironmentId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/cae' `
                    -ExpectedRegistryServer 'safe.azurecr.io' -ExpectedImage "safe.azurecr.io/gateway-api@sha256:$('a' * 64)" `
                    -ExternalIngress $true -ExpectedFqdn 'api.example.test' } |
                Should -Throw '*HTTPS-only*'
        }

        It 'rejects a system-only fallback, an extra attached UAMI, and wrong registry identity' {
            $baseArguments = @{
                App = $script:runtimeContainerApp
                ExpectedName = 'ca-gateway-api-dev'
                ExpectedLocation = 'koreacentral'
                ExpectedPrincipalId = 'principal'
                ExpectedImagePullIdentityResourceId = $script:runtimePullIdentityId
                ExpectedManagedEnvironmentId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/cae'
                ExpectedRegistryServer = 'safe.azurecr.io'
                ExpectedImage = "safe.azurecr.io/gateway-api@sha256:$('a' * 64)"
                ExternalIngress = $true
                ExpectedFqdn = 'api.example.test'
            }

            $script:runtimeContainerApp.identity.type = 'SystemAssigned'
            $script:runtimeContainerApp.identity.userAssignedIdentities = [pscustomobject]@{}
            $script:runtimeContainerApp.properties.configuration.registries[0].identity = 'system'
            { Assert-GatewayExactSystemContainerAppEnvelope @baseArguments } |
                Should -Throw '*identity*'

            $script:runtimeContainerApp.identity.type = 'SystemAssigned, UserAssigned'
            $attachedIdentities = [pscustomobject]@{}
            $attachedIdentities | Add-Member -NotePropertyName $script:runtimePullIdentityId -NotePropertyValue ([pscustomobject]@{})
            $attachedIdentities | Add-Member -NotePropertyName '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/unreviewed' -NotePropertyValue ([pscustomobject]@{})
            $script:runtimeContainerApp.identity.userAssignedIdentities = $attachedIdentities
            $script:runtimeContainerApp.properties.configuration.registries[0].identity = $script:runtimePullIdentityId
            { Assert-GatewayExactSystemContainerAppEnvelope @baseArguments } |
                Should -Throw '*identity*'

            $attachedIdentities.PSObject.Properties.Remove('/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/unreviewed')
            $script:runtimeContainerApp.properties.configuration.registries[0].identity = 'system'
            { Assert-GatewayExactSystemContainerAppEnvelope @baseArguments } |
                Should -Throw '*managed-identity-backed*'
        }
    }
}
