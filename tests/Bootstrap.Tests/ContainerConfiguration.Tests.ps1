$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Experience.psm1') -Force

Describe 'Exact live Container App configuration contracts' {
    InModuleScope Experience {
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

        It 'accepts an HTTPS-only system-identity envelope and rejects insecure ingress' {
            $app = [pscustomobject]@{
                name = 'ca-gateway-api-dev'; location = 'koreacentral'
                identity = [pscustomobject]@{ type = 'SystemAssigned'; principalId = 'principal' }
                properties = [pscustomobject]@{
                    provisioningState = 'Succeeded'; managedEnvironmentId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/cae'
                    configuration = [pscustomobject]@{
                        activeRevisionsMode = 'Single'; secrets = @()
                        registries = @([pscustomobject]@{ server = 'safe.azurecr.io'; identity = 'system' })
                        ingress = [pscustomobject]@{ external = $true; allowInsecure = $false; targetPort = 8080; transport = 'auto'; fqdn = 'api.example.test' }
                    }
                    template = [pscustomobject]@{
                        containers = @([pscustomobject]@{ name = 'ca-gateway-api-dev'; image = "safe.azurecr.io/gateway-api@sha256:$('a' * 64)" })
                    }
                }
            }
            Assert-GatewayExactSystemContainerAppEnvelope -App $app -ExpectedName 'ca-gateway-api-dev' `
                -ExpectedLocation 'koreacentral' -ExpectedPrincipalId 'principal' `
                -ExpectedManagedEnvironmentId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/cae' `
                -ExpectedRegistryServer 'safe.azurecr.io' -ExpectedImage "safe.azurecr.io/gateway-api@sha256:$('a' * 64)" `
                -ExternalIngress $true -ExpectedFqdn 'api.example.test' | Should -BeTrue

            $app.properties.configuration.ingress.allowInsecure = $true
            { Assert-GatewayExactSystemContainerAppEnvelope -App $app -ExpectedName 'ca-gateway-api-dev' `
                    -ExpectedLocation 'koreacentral' -ExpectedPrincipalId 'principal' `
                    -ExpectedManagedEnvironmentId '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/cae' `
                    -ExpectedRegistryServer 'safe.azurecr.io' -ExpectedImage "safe.azurecr.io/gateway-api@sha256:$('a' * 64)" `
                    -ExternalIngress $true -ExpectedFqdn 'api.example.test' } |
                Should -Throw '*HTTPS-only*'
        }
    }
}
