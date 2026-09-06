$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Experience.psm1') -Force

Describe 'Exact live Container App configuration contracts' {
    InModuleScope Experience {
        BeforeAll {
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                (Get-Module Experience).Path, [ref]$tokens, [ref]$parseErrors)
            $parseErrors.Count | Should -Be 0
            $groupVerifier = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq 'Test-GatewayGroupDeploymentEvidence'
            }, $true)
            $environment = $groupVerifier.Body.Find({ param($node)
                $node -is [Management.Automation.Language.HashtableAst] -and
                    @($node.KeyValuePairs | Where-Object { $_.Item1.Value -ceq 'BootstrapCapabilities__Enabled' }).Count -eq 1
            }, $true)
            $expression = @($environment.KeyValuePairs | Where-Object {
                $_.Item1.Value -ceq 'BootstrapCapabilities__Enabled'
            })[0].Item2.Extent.Text
            $script:capabilityBooleanExpectation = [scriptblock]::Create(
                "param(`$expectedCapabilities); Set-StrictMode -Version Latest; $expression")
        }

        BeforeEach {
            $script:runtimePullIdentityId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-runtime-pull-dev'
            $attachedIdentities = [pscustomobject]@{}
            $attachedIdentities | Add-Member -NotePropertyName $script:runtimePullIdentityId -NotePropertyValue ([pscustomobject]@{})
            $script:runtimeContainerApp = [pscustomobject]@{
                name = 'ca-gateway-api-dev'; location = 'Korea Central'
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
                        ingress = [pscustomobject]@{ external = $true; allowInsecure = $false; targetPort = 8080; transport = 'Auto'; fqdn = 'api.example.test' }
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

        It 'verifies the capability flag using exact ARM Boolean text for enabled=<Enabled>' -TestCases @(
            @{ Enabled = $false; ArmValue = 'False'; OppositeValue = 'True' },
            @{ Enabled = $true; ArmValue = 'True'; OppositeValue = 'False' }
        ) {
            param($Enabled, $ArmValue, $OppositeValue)
            $expectation = & $script:capabilityBooleanExpectation ([pscustomobject]@{ enabled = $Enabled })
            $expectation | Should -BeExactly $ArmValue
            $expected = [ordered]@{ BootstrapCapabilities__Enabled = $expectation }
            Assert-GatewayExactContainerEnvironment -Entries @(
                [pscustomobject]@{ name = 'BootstrapCapabilities__Enabled'; value = $ArmValue }
            ) -ExpectedValues $expected | Should -BeTrue

            foreach ($invalidValue in @($OppositeValue, $ArmValue.ToLowerInvariant())) {
                { Assert-GatewayExactContainerEnvironment -Entries @(
                    [pscustomobject]@{ name = 'BootstrapCapabilities__Enabled'; value = $invalidValue }
                ) -ExpectedValues $expected } | Should -Throw '*exact reviewed value contract*'
            }
            { Assert-GatewayExactContainerEnvironment -Entries @(
                [pscustomobject]@{ name = 'BootstrapCapabilities__Enabled'; value = $ArmValue; secretRef = 'unexpected' }
            ) -ExpectedValues $expected } | Should -Throw '*exact reviewed value contract*'
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

        It 'accepts equivalent managed-identity resource ID casing and rejects a different identity' {
            $providerCasedIdentity = $script:runtimePullIdentityId.ToUpperInvariant()

            Assert-GatewayExactContainerRegistry -Registries @(
                [pscustomobject]@{ server = 'safe.azurecr.io'; identity = $providerCasedIdentity }
            ) -ExpectedServer 'safe.azurecr.io' -ExpectedIdentity $script:runtimePullIdentityId |
                Should -BeTrue

            $differentIdentity = $script:runtimePullIdentityId.Replace(
                'id-gateway-runtime-pull-dev',
                'id-gateway-runtime-pull-other')
            { Assert-GatewayExactContainerRegistry -Registries @(
                    [pscustomobject]@{ server = 'safe.azurecr.io'; identity = $differentIdentity }
                ) -ExpectedServer 'safe.azurecr.io' -ExpectedIdentity $script:runtimePullIdentityId } |
                Should -Throw '*managed-identity-backed*'
        }

        It 'normalizes only nonempty ASCII alphanumeric Container App region names and display forms' {
            foreach ($actual in @('koreacentral', 'Korea Central', 'KOREA CENTRAL', 'K o r e a C e n t r a l')) {
                Test-GatewayContainerAppLocationEquivalent -ActualLocation $actual -ExpectedLocation 'koreacentral' |
                    Should -BeTrue
            }
            foreach ($actual in @('', '   ', 'Korea-Central', 'Korea_Central', "Korea`tCentral", "Korea$([char]0x00a0)Central", 'Korea South')) {
                Test-GatewayContainerAppLocationEquivalent -ActualLocation $actual -ExpectedLocation 'koreacentral' |
                    Should -BeFalse
            }
            Test-GatewayContainerAppLocationEquivalent -ActualLocation 'Korea Central' -ExpectedLocation 'korea-central' |
                Should -BeFalse
        }

        It 'uses display-name normalization only at API/worker and Admin Container App readback checks' {
            $source = Get-Content -LiteralPath (Get-Module Experience).Path -Raw

            ([regex]::Matches($source, 'Test-GatewayContainerAppLocationEquivalent\s+-ActualLocation')).Count |
                Should -Be 2
            $source | Should -Match 'ActualLocation \(\[string\]\$App\.location\) -ExpectedLocation \$ExpectedLocation'
            $source | Should -Match 'ActualLocation \(\[string\]\$admin\.location\) -ExpectedLocation \(\[string\]\$Config\.location\)'
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

        It 'accepts provider-cased Auto but rejects a different ingress transport' {
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

            $script:runtimeContainerApp.properties.configuration.ingress.transport = 'Auto'
            Assert-GatewayExactSystemContainerAppEnvelope @baseArguments | Should -BeTrue

            foreach ($transport in @('http', 'tcp', 'other')) {
                $script:runtimeContainerApp.properties.configuration.ingress.transport = $transport
                { Assert-GatewayExactSystemContainerAppEnvelope @baseArguments } |
                    Should -Throw '*HTTPS-only*'
            }

            $source = Get-Content -LiteralPath (Get-Module Experience).Path -Raw
            ([regex]::Matches($source, "transport\)\.Equals\('auto', \[StringComparison\]::OrdinalIgnoreCase\)")).Count |
                Should -Be 2
        }

        It 'accepts null or explicit-empty API/worker secrets and rejects one reported secret' {
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

            $script:runtimeContainerApp.properties.configuration.secrets = @()
            Assert-GatewayExactSystemContainerAppEnvelope @baseArguments | Should -BeTrue

            $script:runtimeContainerApp.properties.configuration.secrets = $null
            Assert-GatewayExactSystemContainerAppEnvelope @baseArguments | Should -BeTrue

            $script:runtimeContainerApp.properties.configuration.secrets = @(
                [pscustomobject]@{ name = 'unreviewed-secret' }
            )
            { Assert-GatewayExactSystemContainerAppEnvelope @baseArguments } |
                Should -Throw '*envelope*'
        }

        It 'keeps the Admin Container App secret collection at exact-one' {
            $source = Get-Content -LiteralPath (Get-Module Experience).Path -Raw

            $source | Should -Match '\$adminSecrets = @\(\$admin\.properties\.configuration\.secrets\)'
            $source | Should -Match '\$adminSecrets\.Count -ne 1'
        }

        It 'rejects punctuation, non-ASCII spacing, empty values, and a different Container App region' {
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
            foreach ($invalidLocation in @('', '   ', 'Korea-Central', 'Korea_Central', "Korea`tCentral", "Korea$([char]0x00a0)Central", 'Korea South')) {
                $script:runtimeContainerApp.location = $invalidLocation
                { Assert-GatewayExactSystemContainerAppEnvelope @baseArguments } |
                    Should -Throw '*envelope*'
            }
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
