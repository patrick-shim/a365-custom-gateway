$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Entra.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Agent365.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Experience.psm1') -Force
& (Get-Module Experience) {
    function Get-GatewayInertWhatIfRecoveryBoundary {
        param($Config, $Foundation, $Identity, [string]$ApiImage, [string]$WorkerImage,
            [string]$DeploymentOwnershipId, [string]$SourceFingerprint,
            [System.Collections.IDictionary]$AdditionalTypeInventoryResourceIds)
        throw 'Test placeholder must be mocked.'
    }
}

Describe 'Experience database Job execution-intent propagation' {
    It 'passes the recorded canonical intent into the live dormant Job validator' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Get-Module Experience).Path, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0
        $function = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Test-GatewayDatabaseEvidence'
        }, $true)
        $function.Extent.Text | Should -Match 'Get-GatewayDatabaseBootstrapJobEvidence(?s:.*?)-ExecutionIntentId \(\[string\]\$Evidence\.databaseBootstrapExecutionIntentId\)'
    }
}

Describe 'Experience API correction image boundary' {
    It 'keeps the original deployment receipt immutable while allowing one exact digest-pinned live API supersession' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Get-Module Experience).Path, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0
        $function = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Test-GatewayGroupDeploymentEvidence'
        }, $true)
        $source = $function.Extent.Text

        $source | Should -Match '\[System\.Collections\.IDictionary\]\$ApiImageSupersession'
        $source | Should -Match 'receiptFingerprint\|targetApiImage\|targetRevisionName'
        $source | Should -Match 'gateway-api@sha256:\[0-9a-f\]\{64\}'
        $source | Should -Match 'ApiImageSupersession\.targetApiImage -ceq \$ApiImage'
        $source | Should -Match 'deployment\.parameters\.apiContainerImage\.value -cne \$ApiImage'
        $source | Should -Match 'deployment\.outputs\.apiContainerImage\.value -cne \$ApiImage'
        $source | Should -Match 'api\.properties\.template\.containers\[0\]\.image -cne \$effectiveApiImage'
        $source | Should -Match '-ExpectedImage \$effectiveApiImage -ExternalIngress'
        $source | Should -Match 'latestReadyRevisionName -cne \$supersedingApiRevision'
        $source | Should -Match "containerapp', 'revision', 'list'"
        $source | Should -Not -Match 'deployment\.parameters\.apiContainerImage\.value -cne \$effectiveApiImage'
    }
}

Describe 'Experience strict-mode array cardinality boundaries' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Get-Module Experience).Path, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0
        $groupFunction = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Test-GatewayGroupDeploymentEvidence'
        }, $true)
        $applicationFunction = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Test-GatewayApplicationEvidence'
        }, $true)
        $script:managerAssignment = $groupFunction.Body.Find({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                [string]$node.Left -ceq '$expectedManagerIds'
        }, $true).Extent.Text
        $script:grantAssignment = $applicationFunction.Body.Find({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                [string]$node.Left -ceq '$grantScopes'
        }, $true).Extent.Text
        $script:grantValidation = @($applicationFunction.Body.FindAll({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text.Contains('$grantScopes.Count', [StringComparison]::Ordinal)
        }, $true) | Sort-Object { $_.Extent.Text.Length })[0].Extent.Text
    }

    It 'preserves inert zero and runtime one manager IDs as arrays under StrictMode' {
        $runner = [scriptblock]::Create("param(`$isRuntime,`$Config); Set-StrictMode -Version Latest; $script:managerAssignment; return ,`$expectedManagerIds")
        $managerId = '66666666-6666-4666-8666-666666666666'
        $config = [pscustomobject]@{ agent365 = [pscustomobject]@{ reviewedManagerApplicationIds = @($managerId) } }
        $inert = & $runner $false $config
        $runtime = & $runner $true $config
        $inert -is [array] | Should -BeTrue
        $inert.Count | Should -Be 0
        $runtime -is [array] | Should -BeTrue
        $runtime.Count | Should -Be 1
        $runtime[0] | Should -BeExactly $managerId
    }

    It 'preserves exact delegated-scope cardinality and rejects missing or extra scopes' {
        $countRunner = [scriptblock]::Create("param(`$grants); Set-StrictMode -Version Latest; $script:grantAssignment; return ,`$grantScopes")
        $validationRunner = [scriptblock]::Create("param(`$grants,`$gatewayPrincipals); Set-StrictMode -Version Latest; $script:grantAssignment; $script:grantValidation; return `$true")
        $resourceId = '77777777-7777-4777-8777-777777777777'
        $principal = @([pscustomobject]@{ id = $resourceId })
        $zero = & $countRunner -grants @()
        $valid = @([pscustomobject]@{ resourceId = $resourceId; consentType = 'AllPrincipals'; scope = 'access_as_user' })
        $one = & $countRunner -grants $valid
        $zero -is [array] | Should -BeTrue
        $zero.Count | Should -Be 0
        $one -is [array] | Should -BeTrue
        $one.Count | Should -Be 1
        & $validationRunner -grants $valid -gatewayPrincipals $principal | Should -BeTrue
        foreach ($scope in @('', 'access_as_user unexpected')) {
            $invalid = @([pscustomobject]@{ resourceId = $resourceId; consentType = 'AllPrincipals'; scope = $scope })
            { & $validationRunner -grants $invalid -gatewayPrincipals $principal } | Should -Throw '*mismatch*'
        }
    }
}

Describe 'Experience Azure resource-provider readback boundary' {
    InModuleScope Experience {
        BeforeEach {
            $script:readProviders = [Collections.Generic.List[string]]::new()
            Mock Invoke-AzTsv {
                param([string[]]$Arguments)
                $script:readProviders.Add([string]$Arguments[3])
                return 'Registered'
            }
        }

        It 'revalidates the exact provider set including AlertsManagement before Resume' {
            Test-GatewayResourceProviderEvidence | Should -BeTrue

            $expected = @(
                'Microsoft.AlertsManagement',
                'Microsoft.App',
                'Microsoft.ContainerRegistry',
                'Microsoft.EventGrid',
                'Microsoft.Insights',
                'Microsoft.KeyVault',
                'Microsoft.ManagedIdentity',
                'Microsoft.Network',
                'Microsoft.OperationalInsights',
                'Microsoft.ServiceBus',
                'Microsoft.Sql',
                'Microsoft.Storage'
            )
            @($script:readProviders) | Should -Be $expected
            Should -Invoke Invoke-AzTsv -Times 12 -Exactly
        }

        It 'keeps Doctor and Resume on the same exact provider set' {
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                (Get-Module Experience).Path, [ref]$tokens, [ref]$parseErrors)
            $parseErrors.Count | Should -Be 0
            $functions = @{}
            foreach ($name in @('Get-GatewayDoctorReport', 'Test-GatewayResourceProviderEvidence')) {
                $functions[$name] = $ast.Find({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -ceq $name
                }, $true).Extent.Text
            }
            foreach ($provider in @(
                'Microsoft.AlertsManagement', 'Microsoft.App', 'Microsoft.ContainerRegistry',
                'Microsoft.EventGrid', 'Microsoft.Insights', 'Microsoft.KeyVault',
                'Microsoft.ManagedIdentity', 'Microsoft.Network',
                'Microsoft.OperationalInsights', 'Microsoft.ServiceBus', 'Microsoft.Sql',
                'Microsoft.Storage'
            )) {
                foreach ($name in $functions.Keys) {
                    ([regex]::Matches($functions[$name], [regex]::Escape("'$provider'"))).Count |
                        Should -Be 1 -Because "$name must contain the provider exactly once"
                }
            }
        }
    }
}

Describe 'ACR ARM-audience authoritative readback boundary' {
    It 'uses the exact ARM resource API for every bootstrap policy readback' {
        $experiencePath = (Get-Module Experience).Path
        $verificationPath = Join-Path (Split-Path $experiencePath -Parent) 'Verification.psm1'
        $experienceSource = Get-Content -LiteralPath $experiencePath -Raw
        $verificationSource = Get-Content -LiteralPath $verificationPath -Raw
        $armReadPattern = "(?s)'resource', 'show'.{0,350}'--api-version', '2023-11-01-preview'.{0,350}properties\.policies\.azureADAuthenticationAsArmPolicy\.status"

        ([regex]::Matches($experienceSource, $armReadPattern)).Count | Should -Be 2
        ([regex]::Matches($verificationSource, $armReadPattern)).Count | Should -Be 1
        $experienceSource | Should -Not -Match "(?s)'acr', 'show'.{0,350}azureADAuthenticationAsArmPolicy"
        $verificationSource | Should -Not -Match "(?s)'acr', 'show'.{0,350}azureADAuthenticationAsArmPolicy"
    }
}

Describe 'Plan input stability boundary' {
    InModuleScope Experience {
        BeforeEach {
            $script:first = "sha256:$('a' * 64)"
            $script:second = "sha256:$('b' * 64)"
        }

        It 'accepts only identical source and configuration fingerprints across compilation and What-If' {
            Assert-GatewayStablePlanInputs `
                -SourceFingerprintBefore $script:first `
                -SourceFingerprintAfter $script:first `
                -ConfigurationFingerprintBefore $script:second `
                -ConfigurationFingerprintAfter $script:second | Should -BeTrue
        }

        It 'rejects a source edit during Plan' {
            { Assert-GatewayStablePlanInputs `
                -SourceFingerprintBefore $script:first `
                -SourceFingerprintAfter $script:second `
                -ConfigurationFingerprintBefore $script:first `
                -ConfigurationFingerprintAfter $script:first } |
                Should -Throw '*changed while Plan was compiling*'
        }

        It 'rejects a configuration change during Plan' {
            { Assert-GatewayStablePlanInputs `
                -SourceFingerprintBefore $script:first `
                -SourceFingerprintAfter $script:first `
                -ConfigurationFingerprintBefore $script:first `
                -ConfigurationFingerprintAfter $script:second } |
                Should -Throw '*changed while Plan was compiling*'
        }
    }
}

Describe 'Plan exact-account context boundary' {
    It 'sets the configured subscription and tenant before ARM What-If and Graph collision checks' {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $source = Get-Content -LiteralPath (
            Join-Path $repositoryRoot 'bootstrap/bootstrap.ps1') -Raw
        $planStart = $source.IndexOf('function Invoke-GatewayPlanWorkflow', [StringComparison]::Ordinal)
        $planEnd = $source.IndexOf("`nSet-BootstrapStructuredOutput", $planStart, [StringComparison]::Ordinal)
        $planSource = $source.Substring($planStart, $planEnd - $planStart)

        $clearIndex = $planSource.IndexOf('Clear-BootstrapAzureSubscriptionContext', [StringComparison]::Ordinal)
        $setIndex = $planSource.IndexOf('Set-BootstrapAzureSubscriptionContext', [StringComparison]::Ordinal)
        $whatIfIndex = $planSource.IndexOf('Invoke-GatewayFoundationWhatIf', [StringComparison]::Ordinal)
        $graphIndex = $planSource.IndexOf('Assert-GatewaySeedBlueprintPlanBoundary', [StringComparison]::Ordinal)

        $planStart | Should -BeGreaterOrEqual 0
        $clearIndex | Should -BeGreaterOrEqual 0
        $setIndex | Should -BeGreaterThan $clearIndex
        $whatIfIndex | Should -BeGreaterThan $setIndex
        $graphIndex | Should -BeGreaterThan $whatIfIndex
        $planSource | Should -Match 'Set-BootstrapAzureSubscriptionContext\s+`\s+-SubscriptionId \(\[string\]\$Configuration\.subscriptionId\)\s+`\s+-TenantId \(\[string\]\$Configuration\.tenantId\)'
        $planSource | Should -Match 'Invoke-GatewayFoundationWhatIf[^\r\n]+-State \$State'
        $source | Should -Match 'Invoke-GatewayFoundationWhatIf[^\r\n]+-State \$state'
    }
}

Describe 'Verified endpoint result contract' {
    It 'emits the validated Admin UI, API base, and API health URLs for Apply and Verify' {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $source = Get-Content -LiteralPath (
            Join-Path $repositoryRoot 'bootstrap/bootstrap.ps1') -Raw

        ([regex]::Matches($source, "category = 'deploymentVerified'")).Count | Should -Be 2
        ([regex]::Matches($source, 'adminUiUrl = \[string\]\$adminUi\.adminUiUrl')).Count | Should -Be 2
        ([regex]::Matches($source, 'apiUrl = "https://\$\(\$runtime\.apiFqdn\)"')).Count | Should -Be 2
        ([regex]::Matches($source, 'apiHealthUrl = "https://\$\(\$runtime\.apiFqdn\)/health/checks"')).Count | Should -Be 2
    }
}

Describe 'Plan fingerprint recovery-Ignore binding' {
    BeforeAll {
        $bootstrapPath = [IO.Path]::GetFullPath((Join-Path (Split-Path (Get-Module Experience).Path -Parent) '../bootstrap.ps1'))
        $script:planContractBootstrapPath = $bootstrapPath
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($bootstrapPath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-GatewayPlanContractFingerprint'
        }, $true)
        Invoke-Expression $definition.Extent.Text
    }

    It 'changes authorization when the deterministic recovery boundary changes' {
        $sourceFingerprint = "sha256:$('a' * 64)"
        $configurationFingerprint = "sha256:$('b' * 64)"
        $whatIf = [ordered]@{
            executed = $true
            applyReady = $true
            changes = @([ordered]@{ changeType = 'Ignore'; resourceId = '/subscriptions/safe/resourceGroups/safe/providers/safe/type/name' })
            recoveryIgnoreBoundary = [ordered]@{
                schemaVersion = 1
                boundaryFingerprint = "sha256:$('c' * 64)"
            }
        }
        $first = Get-GatewayPlanContractFingerprint `
            -Descriptor ([ordered]@{ deploymentId = 'safe' }) `
            -WhatIf $whatIf `
            -ConfigurationFingerprint $configurationFingerprint `
            -SourceFingerprint $sourceFingerprint
        $whatIf.recoveryIgnoreBoundary.boundaryFingerprint = "sha256:$('d' * 64)"
        $second = Get-GatewayPlanContractFingerprint `
            -Descriptor ([ordered]@{ deploymentId = 'safe' }) `
            -WhatIf $whatIf `
            -ConfigurationFingerprint $configurationFingerprint `
            -SourceFingerprint $sourceFingerprint

        $first | Should -Not -Be $second
        (Get-Content -LiteralPath $script:planContractBootstrapPath -Raw) |
            Should -Match 'contractVersion = 3'
    }
}

Describe 'Workload deployment output mapping' {
    InModuleScope Experience {
        It 'maps the real Agent 365 Registry and runtime image-pull ARM outputs to evidence' {
            $identityId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-runtime-pull-dev'
            $assignmentId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev/providers/Microsoft.ContainerRegistry/registries/acrsafe/providers/Microsoft.Authorization/roleAssignments/44444444-4444-4444-8444-444444444444'
            $outputs = [pscustomobject]@{
                agent365RegistryProvider = [pscustomobject]@{ value = 'DirectRegistryPreview' }
                runtimeImagePullIdentityId = [pscustomobject]@{ value = $identityId }
                runtimeImagePullIdentityPrincipalId = [pscustomobject]@{ value = '33333333-3333-4333-8333-333333333333' }
                runtimeImagePullAcrPullRoleAssignmentId = [pscustomobject]@{ value = $assignmentId }
            }
            $evidence = [pscustomobject]@{
                registryProvider = 'DirectRegistryPreview'
                runtimeImagePullIdentityId = $identityId
                runtimeImagePullIdentityPrincipalId = '33333333-3333-4333-8333-333333333333'
                runtimeImagePullAcrPullRoleAssignmentId = $assignmentId
            }

            Assert-GatewayDeploymentOutputEvidenceMap `
                -Outputs $outputs `
                -Evidence $evidence `
                -OutputToEvidenceName ([ordered]@{
                    agent365RegistryProvider = 'registryProvider'
                    runtimeImagePullIdentityId = 'runtimeImagePullIdentityId'
                    runtimeImagePullIdentityPrincipalId = 'runtimeImagePullIdentityPrincipalId'
                    runtimeImagePullAcrPullRoleAssignmentId = 'runtimeImagePullAcrPullRoleAssignmentId'
                }) |
                Should -BeTrue

            $outputs.PSObject.Properties.Name | Should -Not -Contain 'registryProvider'
        }

        It 'rejects a different normalized Registry provider value' {
            $outputs = [pscustomobject]@{
                agent365RegistryProvider = [pscustomobject]@{ value = 'Disabled' }
            }
            $evidence = [pscustomobject]@{ registryProvider = 'DirectRegistryPreview' }

            { Assert-GatewayDeploymentOutputEvidenceMap `
                -Outputs $outputs `
                -Evidence $evidence `
                -OutputToEvidenceName ([ordered]@{ agent365RegistryProvider = 'registryProvider' }) } |
                Should -Throw '*output-to-evidence contract*'
        }

        It 'accepts only the exact source-bound runtime image-pull identity and AcrPull receipt' {
            $subscriptionId = '11111111-1111-4111-8111-111111111111'
            $ownershipId = '22222222-2222-4222-8222-222222222222'
            $principalId = '33333333-3333-4333-8333-333333333333'
            $sourceFingerprint = "sha256:$('a' * 64)"
            $registryId = "/subscriptions/$subscriptionId/resourceGroups/rg-safe-dev/providers/Microsoft.ContainerRegistry/registries/acrsafe"
            $identityId = "/subscriptions/$subscriptionId/resourceGroups/rg-safe-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-runtime-pull-dev"
            $assignmentId = "$registryId/providers/Microsoft.Authorization/roleAssignments/44444444-4444-4444-8444-444444444444"
            $script:pullSubscriptionId = $subscriptionId
            $script:pullOwnershipId = $ownershipId
            $script:pullPrincipalId = $principalId
            $script:pullSourceFingerprint = $sourceFingerprint
            $script:pullRegistryId = $registryId
            $script:pullIdentityId = $identityId
            $script:pullAssignmentId = $assignmentId
            $config = [pscustomobject]@{
                subscriptionId = $subscriptionId
                resourceGroupName = 'rg-safe-dev'
                environment = 'dev'
            }
            $evidence = [pscustomobject]@{
                runtimeImagePullIdentityId = $identityId
                runtimeImagePullIdentityPrincipalId = $principalId
                runtimeImagePullAcrPullRoleAssignmentId = $assignmentId
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ($Arguments[0] -eq 'identity') {
                    return [pscustomobject]@{
                        id = $script:pullIdentityId
                        name = 'id-gateway-runtime-pull-dev'
                        principalId = $script:pullPrincipalId
                        type = 'Microsoft.ManagedIdentity/userAssignedIdentities'
                        ownershipId = $script:pullOwnershipId
                        sourceFingerprint = $script:pullSourceFingerprint
                    }
                }
                if ($Arguments[0] -eq 'resource') {
                    return [pscustomobject]@{
                        id = $script:pullRegistryId
                        name = 'acrsafe'
                        adminUserEnabled = $false
                        armAudienceStatus = 'enabled'
                        ownershipId = $script:pullOwnershipId
                        sourceFingerprint = $script:pullSourceFingerprint
                    }
                }
                throw 'Unexpected mocked Azure readback.'
            }
            Mock Invoke-AzJsonArray {
                return @([pscustomobject]@{
                    id = $script:pullAssignmentId
                    principalId = $script:pullPrincipalId
                    principalType = 'ServicePrincipal'
                    scope = $script:pullRegistryId
                    roleDefinitionId = "/subscriptions/$script:pullSubscriptionId/providers/Microsoft.Authorization/roleDefinitions/7f951dda-4ed3-4680-a7ca-43fe172d538d"
                    condition = $null
                    conditionVersion = $null
                    delegatedManagedIdentityResourceId = $null
                })
            }

            Assert-GatewayRuntimeImagePullIdentityEvidence `
                -Config $config -Evidence $evidence -ExpectedRegistryId $registryId `
                -DeploymentOwnershipId $ownershipId -SourceFingerprint $sourceFingerprint |
                Should -BeTrue

            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'resource' -and
                [string]$Arguments[1] -ceq 'show' -and
                [Array]::IndexOf([object[]]$Arguments, '--ids') -ge 0 -and
                [string]$Arguments[[Array]::IndexOf([object[]]$Arguments, '--ids') + 1] -ceq $script:pullRegistryId -and
                [Array]::IndexOf([object[]]$Arguments, '--api-version') -ge 0 -and
                [string]$Arguments[[Array]::IndexOf([object[]]$Arguments, '--api-version') + 1] -ceq '2023-11-01-preview' -and
                [string]$Arguments[-1] -like '*properties.policies.azureADAuthenticationAsArmPolicy.status*'
            }
        }

        It 'rejects malformed pull-identity IDs, role receipts, and source tags' {
            $subscriptionId = '11111111-1111-4111-8111-111111111111'
            $ownershipId = '22222222-2222-4222-8222-222222222222'
            $principalId = '33333333-3333-4333-8333-333333333333'
            $sourceFingerprint = "sha256:$('a' * 64)"
            $registryId = "/subscriptions/$subscriptionId/resourceGroups/rg-safe-dev/providers/Microsoft.ContainerRegistry/registries/acrsafe"
            $identityId = "/subscriptions/$subscriptionId/resourceGroups/rg-safe-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-runtime-pull-dev"
            $assignmentId = "$registryId/providers/Microsoft.Authorization/roleAssignments/44444444-4444-4444-8444-444444444444"
            $script:adversarialPullIdentityId = $identityId
            $script:adversarialPullPrincipalId = $principalId
            $script:adversarialPullOwnershipId = $ownershipId
            $config = [pscustomobject]@{ subscriptionId = $subscriptionId; resourceGroupName = 'rg-safe-dev'; environment = 'dev' }
            $evidence = [pscustomobject]@{
                runtimeImagePullIdentityId = $identityId
                runtimeImagePullIdentityPrincipalId = $principalId
                runtimeImagePullAcrPullRoleAssignmentId = $assignmentId
            }
            $script:identitySourceTag = "sha256:$('b' * 64)"
            Mock Invoke-AzJson {
                return [pscustomobject]@{
                    id = $script:adversarialPullIdentityId
                    name = 'id-gateway-runtime-pull-dev'
                    principalId = $script:adversarialPullPrincipalId
                    type = 'Microsoft.ManagedIdentity/userAssignedIdentities'
                    ownershipId = $script:adversarialPullOwnershipId
                    sourceFingerprint = $script:identitySourceTag
                }
            }
            Mock Invoke-AzJsonArray { throw 'Role readback should not be reached for wrong identity tags.' }

            { Assert-GatewayRuntimeImagePullIdentityEvidence `
                -Config $config -Evidence $evidence -ExpectedRegistryId $registryId `
                -DeploymentOwnershipId $ownershipId -SourceFingerprint $sourceFingerprint } |
                Should -Throw '*unavailable or mismatched*'

            $evidence.runtimeImagePullIdentityId = "$identityId/extra"
            { Assert-GatewayRuntimeImagePullIdentityEvidence `
                -Config $config -Evidence $evidence -ExpectedRegistryId $registryId `
                -DeploymentOwnershipId $ownershipId -SourceFingerprint $sourceFingerprint } |
                Should -Throw '*unavailable or mismatched*'

            $evidence.runtimeImagePullIdentityId = $identityId
            $evidence.runtimeImagePullAcrPullRoleAssignmentId = "$registryId/providers/Microsoft.Authorization/roleAssignments/not-a-guid"
            { Assert-GatewayRuntimeImagePullIdentityEvidence `
                -Config $config -Evidence $evidence -ExpectedRegistryId $registryId `
                -DeploymentOwnershipId $ownershipId -SourceFingerprint $sourceFingerprint } |
                Should -Throw '*unavailable or mismatched*'
        }
    }
}

Describe 'Database attestation deployment readback boundary' {
    InModuleScope Experience {
        BeforeEach {
            $script:attestationExpected = [ordered]@{
                databaseAttestationExpectedSchemaFingerprint = ''
                databaseAttestationApiPrincipalName = ''
                databaseAttestationApiPrincipalClientId = ''
                databaseAttestationWorkerPrincipalName = ''
                databaseAttestationWorkerPrincipalClientId = ''
                databaseAttestationDatabaseName = ''
            }
            $script:attestationParameters = [ordered]@{}
            $script:attestationOutputs = [ordered]@{}
            $script:attestationEvidence = [ordered]@{}
            foreach ($entry in $script:attestationExpected.GetEnumerator()) {
                $script:attestationOutputs[$entry.Key] = [pscustomobject]@{ value = [string]$entry.Value }
                $script:attestationEvidence[$entry.Key] = [string]$entry.Value
                if ([string]$entry.Key -cne 'databaseAttestationDatabaseName') {
                    $script:attestationParameters[$entry.Key] = [pscustomobject]@{ value = [string]$entry.Value }
                }
            }
        }

        It 'accepts the exact <Mode> contract when the top-level derived database-name parameter is absent under StrictMode' -TestCases @(
            @{ Mode = 'inert'; DatabaseName = '' }
            @{ Mode = 'runtime'; DatabaseName = 'GatewayDb' }
        ) {
            param([string]$Mode, [string]$DatabaseName)
            Set-StrictMode -Version Latest
            $script:attestationExpected.databaseAttestationDatabaseName = $DatabaseName
            $script:attestationOutputs.databaseAttestationDatabaseName.value = $DatabaseName
            $script:attestationEvidence.databaseAttestationDatabaseName = $DatabaseName

            Assert-GatewayDatabaseAttestationDeploymentContract `
                -Parameters $script:attestationParameters `
                -Outputs $script:attestationOutputs `
                -Evidence $script:attestationEvidence `
                -ExpectedValues $script:attestationExpected |
                Should -BeTrue

            $script:attestationParameters.Contains('databaseAttestationDatabaseName') | Should -BeFalse
        }

        It 'rejects a missing or wrong derived database-name output' -TestCases @(
            @{ Mutation = 'Missing' }
            @{ Mutation = 'Wrong' }
        ) {
            param([string]$Mutation)
            if ($Mutation -eq 'Missing') {
                $script:attestationOutputs.Remove('databaseAttestationDatabaseName')
            }
            else {
                $script:attestationOutputs.databaseAttestationDatabaseName.value = 'GatewayDb'
            }

            { Assert-GatewayDatabaseAttestationDeploymentContract `
                -Parameters $script:attestationParameters `
                -Outputs $script:attestationOutputs `
                -Evidence $script:attestationEvidence `
                -ExpectedValues $script:attestationExpected } |
                Should -Throw '*mismatch*'
        }

        It 'rejects missing or wrong derived database-name evidence' -TestCases @(
            @{ Mutation = 'Missing' }
            @{ Mutation = 'Wrong' }
        ) {
            param([string]$Mutation)
            if ($Mutation -eq 'Missing') {
                $script:attestationEvidence.Remove('databaseAttestationDatabaseName')
            }
            else {
                $script:attestationEvidence.databaseAttestationDatabaseName = 'GatewayDb'
            }

            { Assert-GatewayDatabaseAttestationDeploymentContract `
                -Parameters $script:attestationParameters `
                -Outputs $script:attestationOutputs `
                -Evidence $script:attestationEvidence `
                -ExpectedValues $script:attestationExpected } |
                Should -Throw '*mismatch*'
        }

        It 'still rejects a <Mutation> top-level <Field> parameter' -TestCases @(
            foreach ($field in @(
                'databaseAttestationExpectedSchemaFingerprint',
                'databaseAttestationApiPrincipalName',
                'databaseAttestationApiPrincipalClientId',
                'databaseAttestationWorkerPrincipalName',
                'databaseAttestationWorkerPrincipalClientId'
            )) {
                foreach ($mutation in @('Missing', 'Wrong')) {
                    @{ Field = $field; Mutation = $mutation }
                }
            }
        ) {
            param([string]$Field, [string]$Mutation)
            if ($Mutation -eq 'Missing') {
                $script:attestationParameters.Remove($Field)
            }
            else {
                $script:attestationParameters[$Field].value = 'unexpected'
            }

            { Assert-GatewayDatabaseAttestationDeploymentContract `
                -Parameters $script:attestationParameters `
                -Outputs $script:attestationOutputs `
                -Evidence $script:attestationEvidence `
                -ExpectedValues $script:attestationExpected } |
                Should -Throw '*mismatch*'
        }
    }
}

Describe 'Plan-time Agent ID blueprint collision boundary' {
    InModuleScope Experience {
        BeforeEach {
            $script:ownershipId = '11111111-1111-4111-8111-111111111111'
            $script:sourceFingerprint = "sha256:$('a' * 64)"
            $script:ownerObjectId = '22222222-2222-4222-8222-222222222222'
            $script:workerPrincipalId = '33333333-3333-4333-8333-333333333333'
            $script:config = [pscustomobject]@{}
            $script:state = [ordered]@{ steps = [ordered]@{} }
            $script:descriptor = [ordered]@{
                agent365SeedBlueprint = [pscustomobject]@{
                    displayName = 'Reviewed Blueprint [a365gw:owned:source]'
                    deploymentOwnershipId = $script:ownershipId
                    sourceFingerprint = $script:sourceFingerprint
                    planDisposition = 'FreshCreate'
                    providerMutationAuthorized = $true
                    credentialCreation = $false
                    preexistingObjectAdoption = $false
                }
            }
        }

        It 'passes only when the exact planned name is absent' {
            Mock Get-Agent365BlueprintByName { return $null }

            Assert-GatewaySeedBlueprintPlanBoundary `
                -Descriptor $script:descriptor `
                -Config $script:config `
                -State $script:state | Should -BeTrue
            Should -Invoke Get-Agent365BlueprintByName -Times 1 -Exactly -ParameterFilter {
                $DisplayName -eq 'Reviewed Blueprint [a365gw:owned:source]'
            }
        }

        It 'rejects a tenant collision before Apply authorization' {
            Mock Get-Agent365BlueprintByName { return [pscustomobject]@{ id = 'collision' } }

            { Assert-GatewaySeedBlueprintPlanBoundary `
                -Descriptor $script:descriptor `
                -Config $script:config `
                -State $script:state } |
                Should -Throw '*refuses a tenant-object collision*'
        }

        It 'issues a GET-only plan after a create intent started even when Graph has not exposed an object' {
            $script:state.steps['Gateway API identity'] = [ordered]@{
                status = 'Completed'; evidence = [ordered]@{ ownerObjectId = $script:ownerObjectId }
            }
            $script:state.steps['Inert identity deployment'] = [ordered]@{
                status = 'Completed'; evidence = [ordered]@{ workerPrincipalId = $script:workerPrincipalId }
            }
            $script:state.steps['Agent 365 seed blueprint'] = [ordered]@{ status = 'Running' }
            $script:descriptor.agent365SeedBlueprint.planDisposition = 'GetOnlyReconciliation'
            $script:descriptor.agent365SeedBlueprint.providerMutationAuthorized = $false
            Mock Get-Agent365BlueprintByName { return $null }
            Mock Assert-Agent365SeedBlueprintSurface { throw 'must not be called' }

            Assert-GatewaySeedBlueprintPlanBoundary `
                -Descriptor $script:descriptor `
                -Config $script:config `
                -State $script:state | Should -BeTrue
            Should -Invoke Assert-Agent365SeedBlueprintSurface -Times 0 -Exactly
        }

        It 'requires exact provider authority readback for an observable started outcome' {
            $script:state.steps['Gateway API identity'] = [ordered]@{
                status = 'Completed'; evidence = [ordered]@{ ownerObjectId = $script:ownerObjectId }
            }
            $script:state.steps['Inert identity deployment'] = [ordered]@{
                status = 'Completed'; evidence = [ordered]@{ workerPrincipalId = $script:workerPrincipalId }
            }
            $script:state.steps['Agent 365 seed blueprint'] = [ordered]@{ status = 'Failed' }
            $script:descriptor.agent365SeedBlueprint.planDisposition = 'GetOnlyReconciliation'
            $script:descriptor.agent365SeedBlueprint.providerMutationAuthorized = $false
            Mock Get-Agent365BlueprintByName { return [pscustomobject]@{ id = 'provider-object' } }
            Mock Assert-Agent365SeedBlueprintSurface {
                return [ordered]@{
                    objectId = '44444444-4444-4444-8444-444444444444'
                    applicationId = '55555555-5555-4555-8555-555555555555'
                }
            }

            Assert-GatewaySeedBlueprintPlanBoundary `
                -Descriptor $script:descriptor `
                -Config $script:config `
                -State $script:state | Should -BeTrue
            Should -Invoke Assert-Agent365SeedBlueprintSurface -Times 1 -Exactly -ParameterFilter {
                $SponsorObjectId -eq $script:ownerObjectId -and
                $GatewayManagedIdentityPrincipalId -eq $script:workerPrincipalId
            }
        }

        It 'revalidates completed persisted evidence and advertises no additional POST' {
            $persistedEvidence = [ordered]@{ objectId = '44444444-4444-4444-8444-444444444444' }
            $script:state.steps['Gateway API identity'] = [ordered]@{
                status = 'Completed'; evidence = [ordered]@{ ownerObjectId = $script:ownerObjectId }
            }
            $script:state.steps['Inert identity deployment'] = [ordered]@{
                status = 'Completed'; evidence = [ordered]@{ workerPrincipalId = $script:workerPrincipalId }
            }
            $script:state.steps['Agent 365 seed blueprint'] = [ordered]@{
                status = 'Completed'; evidence = $persistedEvidence
            }
            $script:descriptor.agent365SeedBlueprint.planDisposition = 'ReadOnlyRevalidation'
            $script:descriptor.agent365SeedBlueprint.providerMutationAuthorized = $false
            Mock Get-Agent365BlueprintByName { return [pscustomobject]@{ id = 'provider-object' } }
            Mock Test-GatewayBlueprintEvidence { return $true }

            Assert-GatewaySeedBlueprintPlanBoundary `
                -Descriptor $script:descriptor `
                -Config $script:config `
                -State $script:state | Should -BeTrue
            Should -Invoke Test-GatewayBlueprintEvidence -Times 1 -Exactly -ParameterFilter {
                $Evidence -eq $persistedEvidence -and
                $SponsorObjectId -eq $script:ownerObjectId -and
                $GatewayManagedIdentityPrincipalId -eq $script:workerPrincipalId
            }
        }

        It 'rejects a plan disposition that could repeat POST after the step started' {
            $script:state.steps['Agent 365 seed blueprint'] = [ordered]@{ status = 'Failed' }
            Mock Get-Agent365BlueprintByName { throw 'must not be called' }

            { Assert-GatewaySeedBlueprintPlanBoundary `
                -Descriptor $script:descriptor `
                -Config $script:config `
                -State $script:state } |
                Should -Throw '*does not match durable state*'

            Should -Invoke Get-Agent365BlueprintByName -Times 0 -Exactly
        }
    }
}

Describe 'Deleted resource-group recovery boundary' {
    InModuleScope Experience {
        It 'preserves state and fails before replay when a completed foundation was deleted' {
            $foundation = [ordered]@{ status = 'Completed'; evidence = [ordered]@{ safe = $true } }

            { Assert-GatewayResourceGroupRecoveryBoundary `
                -ResourceGroupExists false `
                -FoundationStep $foundation } |
                Should -Throw '*Automatic rebuild is intentionally unsupported*State was preserved*'

            $foundation.status | Should -Be 'Completed'
            $foundation.evidence.safe | Should -BeTrue
        }

        It 'allows a genuinely fresh deployment with no durable foundation' {
            Assert-GatewayResourceGroupRecoveryBoundary `
                -ResourceGroupExists false `
                -FoundationStep $null | Should -BeTrue
        }

        It 'allows normal resume when the recorded resource group still exists' {
            Assert-GatewayResourceGroupRecoveryBoundary `
                -ResourceGroupExists true `
                -FoundationStep ([ordered]@{ status = 'Completed' }) | Should -BeTrue
        }
    }
}

Describe 'Retired SQL public-bootstrap metadata' {
    InModuleScope Experience {
        It 'uses a fixed unused sentinel without any public address discovery' {
            Get-GatewayBootstrapClientIpv4 | Should -Be '0.0.0.0'
            (Get-Command Invoke-GatewayBoundedPublicTextRequest -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }
    }
}

Describe 'Persisted bootstrap readiness truth' {
    BeforeAll {
        function New-TestGatewayStatusState {
            param(
                [Parameter(Mandatory)][bool]$AdmissionReady,
                [Parameter(Mandatory)][string]$RegistrationMode,
                [Parameter(Mandatory)][string]$ProvisioningPreflight,
                [string]$VerificationStepStatus = 'Completed',
                [string]$OutputVerifiedAtUtc = '2026-08-29T00:00:00.0000000+00:00',
                [string]$EvidenceVerifiedAtUtc = '2026-08-29T00:00:00.0000000+00:00'
            )

            $steps = [ordered]@{}
            foreach ($name in Get-GatewayBootstrapStepNames) {
                $steps[$name] = [ordered]@{
                    status = 'Completed'
                    completedAtUtc = '2026-08-29T00:00:00.0000000+00:00'
                    evidence = [ordered]@{}
                }
            }
            $steps['Network hardening'].evidence = [ordered]@{ exactPostMutationReadback = $true }
            $steps['End-to-end deployment verification'] = [ordered]@{
                status = $VerificationStepStatus
                completedAtUtc = '2026-08-29T00:00:00.0000000+00:00'
                evidence = [ordered]@{ verifiedAtUtc = $EvidenceVerifiedAtUtc }
            }

            return [ordered]@{
                deploymentKey = '11111111-1111-4111-8111-111111111111/rg-safe-dev/dev'
                steps = $steps
                outputs = [ordered]@{
                    adminUiUrl = 'https://admin.example.test'
                    apiUrl = 'https://api.example.test'
                    verification = [ordered]@{
                        verifiedAtUtc = $OutputVerifiedAtUtc
                        provisioningAdmissionReady = $AdmissionReady
                        registrationMode = $RegistrationMode
                        provisioningPreflight = $ProvisioningPreflight
                    }
                }
            }
        }

        $script:config = [ordered]@{ projectName = 'safe'; environment = 'dev' }
    }

    It 'keeps closed staging or production admission distinct from a verified deployment' {
        $state = New-TestGatewayStatusState `
            -AdmissionReady $false `
            -RegistrationMode 'ClosedUnsupportedForProduction' `
            -ProvisioningPreflight 'ConfigurationVerifiedAdmissionClosed'

        $status = Get-GatewayBootstrapStatus -Config $script:config -State $state -StatePath '/safe/state.json'

        $status.overallStatus | Should -Be 'Verified'
        $status.readiness.ProvisioningReady | Should -BeFalse
        $status.readiness.ProvisioningAdmission | Should -Be 'ClosedOrNotVerified'
    }

    It 'reports provisioning ready only for a current execution-ready development verification' {
        $state = New-TestGatewayStatusState `
            -AdmissionReady $true `
            -RegistrationMode 'ContinuousDevelopmentPreview' `
            -ProvisioningPreflight 'ExecutionReadyPassed'

        $status = Get-GatewayBootstrapStatus -Config $script:config -State $state -StatePath '/safe/state.json'

        $status.readiness.ProvisioningReady | Should -BeTrue
        $status.readiness.ProvisioningAdmission | Should -Be 'OpenDevelopmentPreview'
    }

    It 'does not trust stale verification output after the verification step fails' {
        $state = New-TestGatewayStatusState `
            -AdmissionReady $true `
            -RegistrationMode 'ContinuousDevelopmentPreview' `
            -ProvisioningPreflight 'ExecutionReadyPassed' `
            -VerificationStepStatus 'Failed'

        $status = Get-GatewayBootstrapStatus -Config $script:config -State $state -StatePath '/safe/state.json'

        $status.overallStatus | Should -Be 'NeedsAttention'
        $status.readiness.ProvisioningReady | Should -BeFalse
        $status.readiness.ControlPlaneReady | Should -BeFalse
    }

    It 'does not claim control-plane readiness from an unverified hardening checkpoint' {
        $state = New-TestGatewayStatusState `
            -AdmissionReady $false `
            -RegistrationMode 'ClosedUnsupportedForProduction' `
            -ProvisioningPreflight 'ConfigurationVerifiedAdmissionClosed' `
            -VerificationStepStatus 'Pending'
        $state.outputs.adminUiUrl = 'https://admin.example.test'
        $state.steps['Network hardening'].evidence = [ordered]@{ exactPostMutationReadback = $true }

        $status = Get-GatewayBootstrapStatus -Config $script:config -State $state -StatePath '/safe/state.json'

        $status.readiness.ControlPlaneReady | Should -BeFalse
        $status.liveReadbackPerformed | Should -BeFalse
    }

    It 'does not trust output whose timestamp differs from the completed verification evidence' {
        $state = New-TestGatewayStatusState `
            -AdmissionReady $true `
            -RegistrationMode 'ContinuousDevelopmentPreview' `
            -ProvisioningPreflight 'ExecutionReadyPassed' `
            -OutputVerifiedAtUtc '2026-08-29T00:00:01.0000000+00:00'

        $status = Get-GatewayBootstrapStatus -Config $script:config -State $state -StatePath '/safe/state.json'

        $status.readiness.ProvisioningReady | Should -BeFalse
    }
}

Describe 'Admin UI open readiness boundary' {
    InModuleScope Experience {
        BeforeEach { Mock Start-Process {} }

        It 'refuses a stale HTTPS endpoint when current control-plane evidence is false' {
            $status = [pscustomobject]@{
                readiness = [pscustomobject]@{ ControlPlaneReady = $false }
                endpoints = [pscustomobject]@{ adminUi = 'https://admin.example.test' }
            }

            { Open-GatewayAdminUi -Status $status } | Should -Throw '*Run gateway verify first*'
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'opens only an HTTPS endpoint carrying current control-plane readiness' {
            $status = [pscustomobject]@{
                readiness = [pscustomobject]@{ ControlPlaneReady = $true }
                endpoints = [pscustomobject]@{ adminUi = 'https://admin.example.test' }
            }

            (Open-GatewayAdminUi -Status $status).opened | Should -BeTrue
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'https://admin.example.test' }
        }
    }
}

Describe 'Azure What-If result boundary' {
    InModuleScope Experience {
        BeforeEach {
            $script:whatIfResult = [pscustomobject]@{
                status = 'Succeeded'
                error = $null
                properties = [pscustomobject]@{ changes = @() }
            }
            Mock Invoke-GatewayAzJson {
                return [pscustomobject]@{
                    id = '11111111-1111-4111-8111-111111111111'
                    tenantId = '22222222-2222-4222-8222-222222222222'
                }
            }
            Mock Invoke-AzJson { return $script:whatIfResult }
            $script:config = [pscustomobject]@{
                subscriptionId = '11111111-1111-4111-8111-111111111111'
                tenantId = '22222222-2222-4222-8222-222222222222'
                projectName = 'safe'
                environment = 'dev'
                location = 'koreacentral'
                resourceGroupName = 'rg-safe-dev'
            }
            $script:whatIfSourceFingerprint = "sha256:$('a' * 64)"
            $script:whatIfOwnershipId = '33333333-3333-4333-8333-333333333333'
            $baseResourceId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourcegroups/rg-safe-dev/providers'
            [string[]]$resourceIds = @(
                "$baseResourceId/microsoft.network/networkinterfaces/pe-safe.nic.1234"
                "$baseResourceId/microsoft.network/privateendpoints/pe-safe"
                "$baseResourceId/microsoft.sql/servers/sql-safe"
                "$baseResourceId/microsoft.sql/servers/sql-safe/databases/master"
                "$baseResourceId/microsoft.alertsmanagement/smartdetectoralertrules/failure anomalies - ai-safe-dev"
                0..20 | ForEach-Object { "$baseResourceId/microsoft.test/resources/resource-$('{0:d2}' -f $_)" }
            )
            [Array]::Sort($resourceIds, [StringComparer]::Ordinal)
            $script:recoveryBoundary = [ordered]@{
                schemaVersion = 2
                phase = 'InertIdentityDeployment'
                deploymentName = 'a365gw-safe-bootstrap-inert-dev'
                deploymentOwnershipId = $script:whatIfOwnershipId
                sourceFingerprint = $script:whatIfSourceFingerprint
                resourceIds = $resourceIds
                generatedNicBinding = [ordered]@{
                    nicId = "$baseResourceId/microsoft.network/networkinterfaces/pe-safe.nic.1234"
                    privateEndpointId = "$baseResourceId/microsoft.network/privateendpoints/pe-safe"
                    subnetId = "$baseResourceId/microsoft.network/virtualnetworks/vnet-safe/subnets/snet-private-endpoints"
                }
                masterDatabaseBinding = [ordered]@{
                    databaseId = "$baseResourceId/microsoft.sql/servers/sql-safe/databases/master"
                    sqlServerId = "$baseResourceId/microsoft.sql/servers/sql-safe"
                }
            }
            $script:recoveryBoundary['boundaryFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $script:recoveryBoundary
            $script:recoveryResult = [ordered]@{
                evidence = [ordered]@{
                    deploymentName = 'a365gw-safe-bootstrap-inert-dev'
                    storageAccountId = "$baseResourceId/microsoft.storage/storageaccounts/stsafe"
                }
                boundary = $script:recoveryBoundary
            }
            $sqlPrivateEndpointId = "$baseResourceId/microsoft.network/privateendpoints/pe-sql-safe-dev"
            $sqlNicId = "$baseResourceId/microsoft.network/networkinterfaces/pe-sql-safe-dev.nic.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            $sqlZoneId = "$baseResourceId/microsoft.network/privatednszones/privatelink.database.windows.net"
            $sqlLinkId = "$sqlZoneId/virtualnetworklinks/link-safe-dev-sql"
            [string[]]$sqlResourceIds = @($sqlNicId, $sqlZoneId, $sqlLinkId, $sqlPrivateEndpointId)
            [Array]::Sort($sqlResourceIds, [StringComparer]::Ordinal)
            $script:sqlPrivateEndpointExtension = [ordered]@{
                schemaVersion = 1
                phase = 'SqlPrivateEndpoint'
                deploymentName = 'a365gw-safe-bootstrap-sql-private-dev'
                deploymentOwnershipId = $script:whatIfOwnershipId
                sourceFingerprint = $script:whatIfSourceFingerprint
                resourceIds = $sqlResourceIds
                typeInventoryResourceIds = [ordered]@{
                    'Microsoft.Network/networkInterfaces' = @($sqlNicId)
                    'Microsoft.Network/privateDnsZones' = @($sqlZoneId)
                    'Microsoft.Network/privateDnsZones/virtualNetworkLinks' = @($sqlLinkId)
                    'Microsoft.Network/privateEndpoints' = @($sqlPrivateEndpointId)
                }
                generatedNicBinding = [ordered]@{
                    nicId = $sqlNicId
                    privateEndpointId = $sqlPrivateEndpointId
                    subnetId = "$baseResourceId/microsoft.network/virtualnetworks/vnet-safe/subnets/snet-private-endpoints"
                }
                privateDnsBinding = [ordered]@{
                    zoneId = $sqlZoneId
                    virtualNetworkLinkId = $sqlLinkId
                    zoneGroupId = "$sqlPrivateEndpointId/privatednszonegroups/sqldnsgroup"
                }
            }
            $script:sqlPrivateEndpointExtension['boundaryFingerprint'] =
                Get-BootstrapObjectFingerprint -InputObject $script:sqlPrivateEndpointExtension
            $script:defenderStorageTopicId =
                "$baseResourceId/microsoft.eventgrid/systemtopics/stsafe-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            $script:defenderStorageEventSubscriptionId =
                "$($script:defenderStorageTopicId)/eventsubscriptions/storageantimalwaresubscription"
            $script:defenderStoragePresentExtension = [ordered]@{
                schemaVersion = 2
                phase = 'DefenderStorageSystemTopic'
                present = $true
                deploymentOwnershipId = $script:whatIfOwnershipId
                sourceFingerprint = $script:whatIfSourceFingerprint
                resourceIds = @($script:defenderStorageTopicId)
                typeInventoryResourceIds = [ordered]@{
                    'Microsoft.EventGrid/systemTopics' = @($script:defenderStorageTopicId)
                }
                systemTopicBinding = [ordered]@{
                    systemTopicId = $script:defenderStorageTopicId
                    name = 'stsafe-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
                    location = 'koreacentral'
                    provisioningState = 'Succeeded'
                    storageAccountId = "$baseResourceId/microsoft.storage/storageaccounts/stsafe"
                    topicType = 'Microsoft.Storage.StorageAccounts'
                    identityPresent = $false
                    tagsPresent = $false
                }
                eventSubscriptionBinding = [ordered]@{
                    eventSubscriptionId = $script:defenderStorageEventSubscriptionId
                    systemTopicId = $script:defenderStorageTopicId
                    name = 'StorageAntimalwareSubscription'
                    provisioningState = 'Succeeded'
                    destinationEndpointType = 'WebHook'
                    eventDeliverySchema = 'EventGridSchema'
                    includedEventTypes = @(
                        'Microsoft.Storage.BlobCreated',
                        'Microsoft.Storage.BlobRenamed'
                    )
                    subjectBeginsWith = ''
                    subjectEndsWith = ''
                    isSubjectCaseSensitive = $null
                    advancedFilter = [ordered]@{
                        key = 'data.blobType'
                        operatorType = 'StringContains'
                        values = @('BlockBlob')
                    }
                    retryPolicy = [ordered]@{
                        eventTimeToLiveInMinutes = 1440
                        maxDeliveryAttempts = 30
                    }
                    deadLetterDestinationPresent = $false
                    deliveryWithResourceIdentityPresent = $false
                    deadLetterWithResourceIdentityPresent = $false
                }
            }
            $script:defenderStoragePresentExtension['boundaryFingerprint'] =
                Get-BootstrapObjectFingerprint -InputObject $script:defenderStoragePresentExtension
            $script:defenderStorageAbsentExtension = [ordered]@{
                schemaVersion = 2
                phase = 'DefenderStorageSystemTopic'
                present = $false
                deploymentOwnershipId = $script:whatIfOwnershipId
                sourceFingerprint = $script:whatIfSourceFingerprint
                resourceIds = @()
                typeInventoryResourceIds = [ordered]@{
                    'Microsoft.EventGrid/systemTopics' = @()
                }
                systemTopicBinding = $null
                eventSubscriptionBinding = $null
            }
            $script:defenderStorageAbsentExtension['boundaryFingerprint'] =
                Get-BootstrapObjectFingerprint -InputObject $script:defenderStorageAbsentExtension
            $script:defenderStorageProviderExtension = $script:defenderStorageAbsentExtension
            $script:recoveryState = [ordered]@{
                deploymentOwnershipId = $script:whatIfOwnershipId
                configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $script:config
                source = [ordered]@{
                    created = [ordered]@{ bootstrapSourceFingerprint = $script:whatIfSourceFingerprint }
                    lastWritten = [ordered]@{ bootstrapSourceFingerprint = $script:whatIfSourceFingerprint }
                }
                steps = [ordered]@{
                    'Prerequisites' = [ordered]@{
                        status = 'Completed'
                        sourceFingerprint = $script:whatIfSourceFingerprint
                        evidence = [ordered]@{ ready = $true }
                    }
                    'Azure authentication' = [ordered]@{
                        status = 'Completed'
                        sourceFingerprint = $script:whatIfSourceFingerprint
                        evidence = [ordered]@{ tenantId = '22222222-2222-4222-8222-222222222222' }
                    }
                    'Azure provider registration' = [ordered]@{
                        status = 'Completed'
                        sourceFingerprint = $script:whatIfSourceFingerprint
                        evidence = [ordered]@{ registered = $true }
                    }
                    'Azure foundation' = [ordered]@{
                        status = 'Completed'
                        sourceFingerprint = $script:whatIfSourceFingerprint
                        evidence = [ordered]@{ deploymentOwnershipId = $script:whatIfOwnershipId }
                    }
                    'Gateway API identity' = [ordered]@{
                        status = 'Completed'
                        sourceFingerprint = $script:whatIfSourceFingerprint
                        evidence = [ordered]@{ gatewayApiClientId = '44444444-4444-4444-8444-444444444444' }
                    }
                    'Immutable workload images' = [ordered]@{
                        status = 'Completed'
                        sourceFingerprint = $script:whatIfSourceFingerprint
                        evidence = [ordered]@{
                            api = "safe.azurecr.io/api@sha256:$('1' * 64)"
                            worker = "safe.azurecr.io/worker@sha256:$('2' * 64)"
                            databaseMigrator = "safe.azurecr.io/gateway-db-migrator@sha256:$('3' * 64)"
                        }
                    }
                    'Inert identity deployment' = [ordered]@{
                        status = 'Failed'
                        sourceFingerprint = $script:whatIfSourceFingerprint
                    }
                }
            }
            function Set-TestRecoveryWhatIf {
                param([Parameter(Mandatory)][string[]]$IgnoreIds)
                [object[]]$changes = @(
                    [pscustomobject]@{
                        changeType = 'Deploy'
                        resourceId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev'
                    }
                    $IgnoreIds | ForEach-Object {
                        [pscustomobject]@{ changeType = 'Ignore'; resourceId = $_ }
                    }
                )
                $script:whatIfResult = [pscustomobject]@{
                    status = 'Succeeded'
                    error = $null
                    properties = [pscustomobject]@{ changes = $changes }
                }
            }
            function Set-TestEarlyRecoveryState {
                $script:recoveryState.steps['Inert identity deployment'].status = 'Completed'
                $script:recoveryState.steps['Inert identity deployment'].evidence = [ordered]@{
                    sqlServerFqdn = 'sql-safe-dev.database.windows.net'
                }
                $script:recoveryState.steps['Agent 365 seed blueprint'] = [ordered]@{
                    status = 'Running'
                    sourceFingerprint = $script:whatIfSourceFingerprint
                }
            }
            function Set-TestLaterRecoveryState {
                $script:recoveryState.steps['Inert identity deployment'].status = 'Completed'
                $script:recoveryState.steps['Inert identity deployment'].evidence = [ordered]@{
                    sqlServerFqdn = 'sql-safe-dev.database.windows.net'
                }
                foreach ($stepName in @('Agent 365 seed blueprint', 'Workflow v3 Entra configuration')) {
                    $script:recoveryState.steps[$stepName] = [ordered]@{
                        status = 'Completed'
                        sourceFingerprint = $script:whatIfSourceFingerprint
                        evidence = [ordered]@{ verified = $true }
                    }
                }
                $script:recoveryState.steps['SQL private endpoint'] = [ordered]@{
                    status = 'Completed'
                    sourceFingerprint = $script:whatIfSourceFingerprint
                    evidence = [ordered]@{ deploymentName = 'a365gw-safe-bootstrap-sql-private-dev' }
                }
                $script:recoveryState.steps['Gateway database'] = [ordered]@{
                    status = 'Failed'
                    sourceFingerprint = $script:whatIfSourceFingerprint
                }
            }
            Mock Get-GatewayInertWhatIfRecoveryBoundary { return $script:recoveryResult }
            Mock Get-GatewaySqlPrivateEndpointWhatIfRecoveryExtension { return $script:sqlPrivateEndpointExtension }
            Mock Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension {
                return $script:defenderStorageProviderExtension
            }
            Mock Test-GatewayGroupDeploymentEvidence { return $true }
        }

        It 'accepts an explicit empty changes array' {
            $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333' -SourceFingerprint $script:whatIfSourceFingerprint

            $result.executed | Should -BeTrue
            $result.applyReady | Should -BeTrue
            $result.changes.Count | Should -Be 0
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                $formatIndex = [Array]::IndexOf([object[]]$Arguments, '--result-format')
                $Arguments -contains '--no-pretty-print' -and
                    $Arguments -contains "bootstrapSourceFingerprint=$script:whatIfSourceFingerprint" -and
                    $formatIndex -ge 0 -and
                    $formatIndex + 1 -lt $Arguments.Count -and
                    $Arguments[$formatIndex + 1] -ceq 'ResourceIdOnly'
            }
        }

        It 'accepts the current Azure CLI top-level changes contract' {
            $script:whatIfResult = [pscustomobject]@{
                status = 'Succeeded'
                error = $null
                changes = @([pscustomobject]@{
                    changeType = 'Create'
                    resourceId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev'
                })
            }

            $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333' -SourceFingerprint $script:whatIfSourceFingerprint

            $result.executed | Should -BeTrue
            $result.applyReady | Should -BeTrue
            $result.changeCounts['Create'] | Should -Be 1
        }

        It 'accepts Deploy as the only other ResourceIdOnly mutation prediction' {
            $script:whatIfResult = [pscustomobject]@{
                status = 'Succeeded'
                error = $null
                changes = @([pscustomobject]@{
                    changeType = 'Deploy'
                    resourceId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev'
                })
            }

            $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333' -SourceFingerprint $script:whatIfSourceFingerprint

            $result.applyReady | Should -BeTrue
            $result.changeCounts['Deploy'] | Should -Be 1
        }

        It 'accepts Ignore only for the exact source-owned inert recovery graph' {
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds

            $result = Invoke-GatewayFoundationWhatIf `
                -Config $script:config `
                -RepositoryRoot '/safe/source' `
                -DeploymentOwnershipId $script:whatIfOwnershipId `
                -SourceFingerprint $script:whatIfSourceFingerprint `
                -State $script:recoveryState

            $result.applyReady | Should -BeTrue
            $result.changeCounts['Ignore'] | Should -Be 26
            @($result.changes | Where-Object changeType -eq 'Ignore').Count | Should -Be 26
            $result.recoveryIgnoreBoundary.schemaVersion | Should -Be 4
            $result.recoveryIgnoreBoundary.phase |
                Should -BeExactly 'InertIdentityDeployment+DefenderStorageSystemTopic'
            $result.recoveryIgnoreBoundary.defenderStoragePresent | Should -BeFalse
            $result.recoveryIgnoreBoundary.resourceIds.Count | Should -Be 26
            $result.recoveryIgnoreBoundary.baseBoundaryFingerprint |
                Should -BeExactly $script:recoveryBoundary.boundaryFingerprint
            $result.recoveryIgnoreBoundary.defenderStorageBoundaryFingerprint |
                Should -BeExactly $script:defenderStorageAbsentExtension.boundaryFingerprint
            $result.recoveryIgnoreBoundary.boundaryFingerprint | Should -Match '^sha256:[0-9a-f]{64}$'
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 1 -Exactly -ParameterFilter {
                $Foundation -eq $script:recoveryState.steps['Azure foundation'].evidence -and
                $Identity -eq $script:recoveryState.steps['Gateway API identity'].evidence -and
                $ApiImage -eq $script:recoveryState.steps['Immutable workload images'].evidence.api -and
                $WorkerImage -eq $script:recoveryState.steps['Immutable workload images'].evidence.worker -and
                $DeploymentOwnershipId -eq $script:whatIfOwnershipId -and
                $SourceFingerprint -eq $script:whatIfSourceFingerprint
            }
            Should -Invoke Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension -Times 1 -Exactly -ParameterFilter {
                $StorageAccountId -ceq $script:recoveryResult.evidence.storageAccountId -and
                $DeploymentOwnershipId -ceq $script:whatIfOwnershipId -and
                $SourceFingerprint -ceq $script:whatIfSourceFingerprint
            }
            Should -Invoke Test-GatewayGroupDeploymentEvidence -Times 1 -Exactly
        }

        It 'rejects Ignore when the required state prefix is not completed' {
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds
            $script:recoveryState.steps['Azure foundation'].status = 'Failed'

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly
        }

        It 'rejects Ignore when state source provenance differs' {
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds
            $script:recoveryState.source.lastWritten.bootstrapSourceFingerprint = "sha256:$('b' * 64)"

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly
        }

        It 'rejects Ignore when state ownership differs' {
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds
            $script:recoveryState.deploymentOwnershipId = '55555555-5555-4555-8555-555555555555'

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly
        }

        It 'accepts the exact inert Ignore graph after a contiguous tenant-only phase starts' {
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds
            $script:recoveryState.steps['Inert identity deployment'].status = 'Completed'
            $script:recoveryState.steps['Inert identity deployment'].evidence = [ordered]@{ sqlServerFqdn = 'sql-safe-dev.database.windows.net' }
            $script:recoveryState.steps['Agent 365 seed blueprint'] = [ordered]@{
                status = 'Running'
                sourceFingerprint = $script:whatIfSourceFingerprint
            }

            $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState

            $result.applyReady | Should -BeTrue
            $result.recoveryIgnoreBoundary.schemaVersion | Should -Be 4
            $result.recoveryIgnoreBoundary.defenderStoragePresent | Should -BeFalse
            $result.recoveryIgnoreBoundary.resourceIds.Count | Should -Be 26
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 1 -Exactly
            Should -Invoke Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension -Times 1 -Exactly
        }

        It 'accepts exactly 27 Ignore resources when one Defender Storage topic extends the early inert recovery boundary' {
            $script:recoveryState.steps['Inert identity deployment'].status = 'Completed'
            $script:recoveryState.steps['Inert identity deployment'].evidence = [ordered]@{
                sqlServerFqdn = 'sql-safe-dev.database.windows.net'
            }
            $script:recoveryState.steps['Agent 365 seed blueprint'] = [ordered]@{
                status = 'Running'
                sourceFingerprint = $script:whatIfSourceFingerprint
            }
            Set-TestRecoveryWhatIf -IgnoreIds @(
                $script:recoveryBoundary.resourceIds + $script:defenderStorageTopicId)
            $script:defenderStorageProviderExtension = $script:defenderStoragePresentExtension

            $result = Invoke-GatewayFoundationWhatIf `
                -Config $script:config -RepositoryRoot '/safe/source' `
                -DeploymentOwnershipId $script:whatIfOwnershipId `
                -SourceFingerprint $script:whatIfSourceFingerprint `
                -State $script:recoveryState

            $result.applyReady | Should -BeTrue
            $result.changeCounts['Ignore'] | Should -Be 27
            $result.recoveryIgnoreBoundary.schemaVersion | Should -Be 4
            $result.recoveryIgnoreBoundary.phase |
                Should -BeExactly 'InertIdentityDeployment+DefenderStorageSystemTopic'
            $result.recoveryIgnoreBoundary.resourceIds.Count | Should -Be 27
            $result.recoveryIgnoreBoundary.defenderStoragePresent | Should -BeTrue
            $result.recoveryIgnoreBoundary.defenderStorageBoundaryFingerprint |
                Should -BeExactly $script:defenderStoragePresentExtension.boundaryFingerprint
            Should -Invoke Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension -Times 1 -Exactly -ParameterFilter {
                $StorageAccountId -ceq $script:recoveryResult.evidence.storageAccountId -and
                $DeploymentOwnershipId -ceq $script:whatIfOwnershipId -and
                $SourceFingerprint -ceq $script:whatIfSourceFingerprint
            }
        }

        It 'accepts only the exact 30-resource graph after completed SQL private endpoint and a later failure' {
            $script:recoveryState.steps['Inert identity deployment'].status = 'Completed'
            $script:recoveryState.steps['Inert identity deployment'].evidence = [ordered]@{ sqlServerFqdn = 'sql-safe-dev.database.windows.net' }
            foreach ($stepName in @('Agent 365 seed blueprint', 'Workflow v3 Entra configuration')) {
                $script:recoveryState.steps[$stepName] = [ordered]@{
                    status = 'Completed'
                    sourceFingerprint = $script:whatIfSourceFingerprint
                    evidence = [ordered]@{ verified = $true }
                }
            }
            $script:recoveryState.steps['SQL private endpoint'] = [ordered]@{
                status = 'Completed'
                sourceFingerprint = $script:whatIfSourceFingerprint
                evidence = [ordered]@{ deploymentName = 'a365gw-safe-bootstrap-sql-private-dev' }
            }
            $script:recoveryState.steps['Gateway database'] = [ordered]@{
                status = 'Failed'
                sourceFingerprint = $script:whatIfSourceFingerprint
            }
            Set-TestRecoveryWhatIf -IgnoreIds @(
                $script:recoveryBoundary.resourceIds + $script:sqlPrivateEndpointExtension.resourceIds)

            $result = Invoke-GatewayFoundationWhatIf `
                -Config $script:config -RepositoryRoot '/safe/source' `
                -DeploymentOwnershipId $script:whatIfOwnershipId `
                -SourceFingerprint $script:whatIfSourceFingerprint `
                -State $script:recoveryState

            $result.applyReady | Should -BeTrue
            $result.changeCounts['Ignore'] | Should -Be 30
            $result.recoveryIgnoreBoundary.schemaVersion | Should -Be 4
            $result.recoveryIgnoreBoundary.phase |
                Should -BeExactly 'InertIdentityDeployment+SqlPrivateEndpoint+DefenderStorageSystemTopic'
            $result.recoveryIgnoreBoundary.defenderStoragePresent | Should -BeFalse
            $result.recoveryIgnoreBoundary.resourceIds.Count | Should -Be 30
            $result.recoveryIgnoreBoundary.boundaryFingerprint | Should -Match '^sha256:[0-9a-f]{64}$'
            $result.recoveryIgnoreBoundary.defenderStorageBoundaryFingerprint |
                Should -BeExactly $script:defenderStorageAbsentExtension.boundaryFingerprint
            Should -Invoke Get-GatewaySqlPrivateEndpointWhatIfRecoveryExtension -Times 1 -Exactly
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 1 -Exactly -ParameterFilter {
                $AdditionalTypeInventoryResourceIds -eq $script:sqlPrivateEndpointExtension.typeInventoryResourceIds
            }
            Should -Invoke Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension -Times 1 -Exactly
        }

        It 'accepts exactly 31 Ignore resources only when one exact Defender Storage topic extends the 30-resource state boundary' {
            $script:recoveryState.steps['Inert identity deployment'].status = 'Completed'
            $script:recoveryState.steps['Inert identity deployment'].evidence = [ordered]@{ sqlServerFqdn = 'sql-safe-dev.database.windows.net' }
            foreach ($stepName in @('Agent 365 seed blueprint', 'Workflow v3 Entra configuration')) {
                $script:recoveryState.steps[$stepName] = [ordered]@{
                    status = 'Completed'
                    sourceFingerprint = $script:whatIfSourceFingerprint
                    evidence = [ordered]@{ verified = $true }
                }
            }
            $script:recoveryState.steps['SQL private endpoint'] = [ordered]@{
                status = 'Completed'
                sourceFingerprint = $script:whatIfSourceFingerprint
                evidence = [ordered]@{ deploymentName = 'a365gw-safe-bootstrap-sql-private-dev' }
            }
            $script:recoveryState.steps['Gateway database'] = [ordered]@{
                status = 'Failed'
                sourceFingerprint = $script:whatIfSourceFingerprint
            }
            Set-TestRecoveryWhatIf -IgnoreIds @(
                $script:recoveryBoundary.resourceIds +
                $script:sqlPrivateEndpointExtension.resourceIds +
                $script:defenderStorageTopicId)
            $script:defenderStorageProviderExtension = $script:defenderStoragePresentExtension

            $result = Invoke-GatewayFoundationWhatIf `
                -Config $script:config -RepositoryRoot '/safe/source' `
                -DeploymentOwnershipId $script:whatIfOwnershipId `
                -SourceFingerprint $script:whatIfSourceFingerprint `
                -State $script:recoveryState

            $result.applyReady | Should -BeTrue
            $result.changeCounts['Ignore'] | Should -Be 31
            $result.recoveryIgnoreBoundary.schemaVersion | Should -Be 4
            $result.recoveryIgnoreBoundary.phase |
                Should -BeExactly 'InertIdentityDeployment+SqlPrivateEndpoint+DefenderStorageSystemTopic'
            $result.recoveryIgnoreBoundary.resourceIds.Count | Should -Be 31
            $result.recoveryIgnoreBoundary.defenderStoragePresent | Should -BeTrue
            $result.recoveryIgnoreBoundary.boundaryFingerprint | Should -Match '^sha256:[0-9a-f]{64}$'
            Should -Invoke Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension -Times 1 -Exactly -ParameterFilter {
                $StorageAccountId -ceq $script:recoveryResult.evidence.storageAccountId -and
                $DeploymentOwnershipId -ceq $script:whatIfOwnershipId -and
                $SourceFingerprint -ceq $script:whatIfSourceFingerprint
            }
        }

        It 'rejects a 26-resource What-If when independent provider inventory contains one Defender Storage topic' {
            Set-TestEarlyRecoveryState
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds
            $script:defenderStorageProviderExtension = $script:defenderStoragePresentExtension

            $result = Invoke-GatewayFoundationWhatIf `
                -Config $script:config -RepositoryRoot '/safe/source' `
                -DeploymentOwnershipId $script:whatIfOwnershipId `
                -SourceFingerprint $script:whatIfSourceFingerprint `
                -State $script:recoveryState

            $result.applyReady | Should -BeFalse
            $result.recoveryIgnoreBoundary | Should -BeNullOrEmpty
            Should -Invoke Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension -Times 1 -Exactly
        }

        It 'rejects a 27-resource What-If when independent provider inventory reports typed absence' {
            Set-TestEarlyRecoveryState
            Set-TestRecoveryWhatIf -IgnoreIds @(
                $script:recoveryBoundary.resourceIds + $script:defenderStorageTopicId)

            $result = Invoke-GatewayFoundationWhatIf `
                -Config $script:config -RepositoryRoot '/safe/source' `
                -DeploymentOwnershipId $script:whatIfOwnershipId `
                -SourceFingerprint $script:whatIfSourceFingerprint `
                -State $script:recoveryState

            $result.applyReady | Should -BeFalse
            $result.recoveryIgnoreBoundary | Should -BeNullOrEmpty
            Should -Invoke Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension -Times 1 -Exactly
        }

        It 'rejects a 30-resource What-If when independent provider inventory contains one Defender Storage topic' {
            Set-TestLaterRecoveryState
            Set-TestRecoveryWhatIf -IgnoreIds @(
                $script:recoveryBoundary.resourceIds + $script:sqlPrivateEndpointExtension.resourceIds)
            $script:defenderStorageProviderExtension = $script:defenderStoragePresentExtension

            $result = Invoke-GatewayFoundationWhatIf `
                -Config $script:config -RepositoryRoot '/safe/source' `
                -DeploymentOwnershipId $script:whatIfOwnershipId `
                -SourceFingerprint $script:whatIfSourceFingerprint `
                -State $script:recoveryState

            $result.applyReady | Should -BeFalse
            $result.recoveryIgnoreBoundary | Should -BeNullOrEmpty
            Should -Invoke Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension -Times 1 -Exactly
        }

        It 'rejects a 31-resource What-If when independent provider inventory reports typed absence' {
            Set-TestLaterRecoveryState
            Set-TestRecoveryWhatIf -IgnoreIds @(
                $script:recoveryBoundary.resourceIds +
                $script:sqlPrivateEndpointExtension.resourceIds +
                $script:defenderStorageTopicId)

            $result = Invoke-GatewayFoundationWhatIf `
                -Config $script:config -RepositoryRoot '/safe/source' `
                -DeploymentOwnershipId $script:whatIfOwnershipId `
                -SourceFingerprint $script:whatIfSourceFingerprint `
                -State $script:recoveryState

            $result.applyReady | Should -BeFalse
            $result.recoveryIgnoreBoundary | Should -BeNullOrEmpty
            Should -Invoke Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension -Times 1 -Exactly
        }

        It 'rejects a 29-resource later-state Ignore graph instead of treating a missing SQL resource as optional' {
            $script:recoveryState.steps['Inert identity deployment'].status = 'Completed'
            $script:recoveryState.steps['Inert identity deployment'].evidence = [ordered]@{ sqlServerFqdn = 'sql-safe-dev.database.windows.net' }
            foreach ($stepName in @('Agent 365 seed blueprint', 'Workflow v3 Entra configuration')) {
                $script:recoveryState.steps[$stepName] = [ordered]@{
                    status = 'Completed'
                    sourceFingerprint = $script:whatIfSourceFingerprint
                    evidence = [ordered]@{ verified = $true }
                }
            }
            $script:recoveryState.steps['SQL private endpoint'] = [ordered]@{
                status = 'Completed'
                sourceFingerprint = $script:whatIfSourceFingerprint
                evidence = [ordered]@{ deploymentName = 'a365gw-safe-bootstrap-sql-private-dev' }
            }
            $script:recoveryState.steps['Gateway database'] = [ordered]@{
                status = 'Failed'
                sourceFingerprint = $script:whatIfSourceFingerprint
            }
            [string[]]$fullLaterGraph = @(
                $script:recoveryBoundary.resourceIds + $script:sqlPrivateEndpointExtension.resourceIds)
            Set-TestRecoveryWhatIf -IgnoreIds @($fullLaterGraph | Select-Object -SkipLast 1)

            (Invoke-GatewayFoundationWhatIf `
                    -Config $script:config -RepositoryRoot '/safe/source' `
                    -DeploymentOwnershipId $script:whatIfOwnershipId `
                    -SourceFingerprint $script:whatIfSourceFingerprint `
                    -State $script:recoveryState).applyReady |
                Should -BeFalse
            Should -Invoke Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension -Times 1 -Exactly
        }

        It 'rejects 32 Ignore resources containing multiple direct Event Grid system topics before provider readback' {
            $script:recoveryState.steps['Inert identity deployment'].status = 'Completed'
            $script:recoveryState.steps['Inert identity deployment'].evidence = [ordered]@{ sqlServerFqdn = 'sql-safe-dev.database.windows.net' }
            foreach ($stepName in @('Agent 365 seed blueprint', 'Workflow v3 Entra configuration')) {
                $script:recoveryState.steps[$stepName] = [ordered]@{
                    status = 'Completed'
                    sourceFingerprint = $script:whatIfSourceFingerprint
                    evidence = [ordered]@{ verified = $true }
                }
            }
            $script:recoveryState.steps['SQL private endpoint'] = [ordered]@{
                status = 'Completed'
                sourceFingerprint = $script:whatIfSourceFingerprint
                evidence = [ordered]@{ deploymentName = 'a365gw-safe-bootstrap-sql-private-dev' }
            }
            $script:recoveryState.steps['Gateway database'] = [ordered]@{
                status = 'Failed'
                sourceFingerprint = $script:whatIfSourceFingerprint
            }
            $secondTopic = $script:defenderStorageTopicId.Replace(
                'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
            Set-TestRecoveryWhatIf -IgnoreIds @(
                $script:recoveryBoundary.resourceIds +
                $script:sqlPrivateEndpointExtension.resourceIds +
                $script:defenderStorageTopicId +
                $secondTopic)

            (Invoke-GatewayFoundationWhatIf `
                    -Config $script:config -RepositoryRoot '/safe/source' `
                    -DeploymentOwnershipId $script:whatIfOwnershipId `
                    -SourceFingerprint $script:whatIfSourceFingerprint `
                    -State $script:recoveryState).applyReady |
                Should -BeFalse
            Should -Invoke Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension -Times 0 -Exactly
            Should -Invoke Get-GatewaySqlPrivateEndpointWhatIfRecoveryExtension -Times 0 -Exactly
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly
        }

        It 'rejects a non-contiguous later recovery state before any provider readback' {
            $script:recoveryState.steps['Inert identity deployment'].status = 'Completed'
            $script:recoveryState.steps['Inert identity deployment'].evidence = [ordered]@{ sqlServerFqdn = 'sql-safe-dev.database.windows.net' }
            $script:recoveryState.steps['Workflow v3 Entra configuration'] = [ordered]@{
                status = 'Running'
                sourceFingerprint = $script:whatIfSourceFingerprint
            }
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly
            Should -Invoke Get-GatewaySqlPrivateEndpointWhatIfRecoveryExtension -Times 0 -Exactly
        }

        It 'rejects a non-completed SQL private-endpoint step because its ARM footprint is ambiguous' {
            $script:recoveryState.steps['Inert identity deployment'].status = 'Completed'
            $script:recoveryState.steps['Inert identity deployment'].evidence = [ordered]@{ sqlServerFqdn = 'sql-safe-dev.database.windows.net' }
            foreach ($stepName in @('Agent 365 seed blueprint', 'Workflow v3 Entra configuration')) {
                $script:recoveryState.steps[$stepName] = [ordered]@{
                    status = 'Completed'
                    sourceFingerprint = $script:whatIfSourceFingerprint
                    evidence = [ordered]@{ verified = $true }
                }
            }
            $script:recoveryState.steps['SQL private endpoint'] = [ordered]@{
                status = 'Failed'
                sourceFingerprint = $script:whatIfSourceFingerprint
            }
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly
            Should -Invoke Get-GatewaySqlPrivateEndpointWhatIfRecoveryExtension -Times 0 -Exactly
        }

        It 'rejects a tampered SQL private-endpoint recovery extension' {
            $script:recoveryState.steps['Inert identity deployment'].status = 'Completed'
            $script:recoveryState.steps['Inert identity deployment'].evidence = [ordered]@{ sqlServerFqdn = 'sql-safe-dev.database.windows.net' }
            foreach ($stepName in @('Agent 365 seed blueprint', 'Workflow v3 Entra configuration')) {
                $script:recoveryState.steps[$stepName] = [ordered]@{
                    status = 'Completed'
                    sourceFingerprint = $script:whatIfSourceFingerprint
                    evidence = [ordered]@{ verified = $true }
                }
            }
            $script:recoveryState.steps['SQL private endpoint'] = [ordered]@{
                status = 'Completed'
                sourceFingerprint = $script:whatIfSourceFingerprint
                evidence = [ordered]@{ deploymentName = 'a365gw-safe-bootstrap-sql-private-dev' }
            }
            $script:recoveryState.steps['Gateway database'] = [ordered]@{
                status = 'Failed'
                sourceFingerprint = $script:whatIfSourceFingerprint
            }
            $script:sqlPrivateEndpointExtension.boundaryFingerprint = "sha256:$('f' * 64)"
            Set-TestRecoveryWhatIf -IgnoreIds @(
                $script:recoveryBoundary.resourceIds + $script:sqlPrivateEndpointExtension.resourceIds)

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly
        }

        It 'rejects wrong-case or unknown inert persisted statuses' {
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds
            foreach ($status in @('running', 'FAILED', 'completed', 'Started', 'Unknown')) {
                $script:recoveryState.steps['Inert identity deployment'].status = $status

                (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                    Should -BeFalse
            }
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly
        }

        It 'rejects wrong-case or unknown persisted step names' {
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds
            $foundationStep = $script:recoveryState.steps['Azure foundation']
            $script:recoveryState.steps.Remove('Azure foundation')
            $script:recoveryState.steps['azure foundation'] = $foundationStep

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly

            $script:recoveryState.steps.Remove('azure foundation')
            $script:recoveryState.steps['Azure foundation'] = $foundationStep
            $script:recoveryState.steps['Unreviewed recovery step'] = [ordered]@{
                status = 'Completed'
                sourceFingerprint = $script:whatIfSourceFingerprint
            }

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly
        }

        It 'rejects a missing recovery Ignore resource' {
            Set-TestRecoveryWhatIf -IgnoreIds @($script:recoveryBoundary.resourceIds | Select-Object -SkipLast 1)

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
        }

        It 'rejects an extra recovery Ignore resource' {
            $extraId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourcegroups/rg-safe-dev/providers/microsoft.test/resources/extra'
            Set-TestRecoveryWhatIf -IgnoreIds @($script:recoveryBoundary.resourceIds + $extraId)

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
        }

        It 'rejects duplicate normalized recovery Ignore resources' {
            $duplicate = ([string]$script:recoveryBoundary.resourceIds[0]).ToUpperInvariant()
            Set-TestRecoveryWhatIf -IgnoreIds @($script:recoveryBoundary.resourceIds + $duplicate)

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
        }

        It 'rejects one normalized resource ID reported under both Deploy and Ignore' {
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds
            $script:whatIfResult.properties.changes[0].resourceId =
                ([string]$script:recoveryBoundary.resourceIds[0]).ToUpperInvariant()

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly
        }

        It 'permits spaces only in the exact deterministic Failure Anomalies resource ID' {
            foreach ($resourceId in @(
                '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev/providers/Microsoft.Test/resources/unexpected name',
                '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev/providers/Microsoft.AlertsManagement/smartDetectorAlertRules/Failure Anomalies - ai-other-dev',
                "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev/providers/Microsoft.Test/resources/unexpected`tname"
            )) {
                $script:whatIfResult = [pscustomobject]@{
                    status = 'Succeeded'
                    error = $null
                    changes = @([pscustomobject]@{ changeType = 'Create'; resourceId = $resourceId })
                }

                (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                    Should -BeFalse
            }
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly
        }

        It 'rejects an out-of-resource-group recovery Ignore resource' {
            [string[]]$observed = @($script:recoveryBoundary.resourceIds)
            $observed[0] = $observed[0].Replace('/resourcegroups/rg-safe-dev/', '/resourcegroups/rg-other/')
            Set-TestRecoveryWhatIf -IgnoreIds $observed

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
        }

        It 'rejects an unexpected recovery boundary property' {
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds
            $script:recoveryBoundary['unreviewed'] = 'value'

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
        }

        It 'rejects an out-of-scope recovery boundary binding' {
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds
            $script:recoveryBoundary.generatedNicBinding.nicId =
                '/subscriptions/11111111-1111-4111-8111-111111111111/resourcegroups/rg-other/providers/microsoft.network/networkinterfaces/unreviewed'

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
        }

        It 'rejects a mismatched recovery boundary fingerprint' {
            Set-TestRecoveryWhatIf -IgnoreIds $script:recoveryBoundary.resourceIds
            $script:recoveryBoundary.boundaryFingerprint = "sha256:$('f' * 64)"

            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                Should -BeFalse
        }

        It 'rejects an ambiguous dual-surface changes contract' {
            $script:whatIfResult = [pscustomobject]@{
                status = 'Succeeded'
                error = $null
                changes = @()
                properties = [pscustomobject]@{ changes = @() }
            }

            $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333' -SourceFingerprint $script:whatIfSourceFingerprint

            $result.applyReady | Should -BeFalse
            $result.reason | Should -BeLike '*malformed result contract*'
        }

        It 'rejects failed status or a non-null What-If error' {
            foreach ($malformed in @(
                [pscustomobject]@{ status = 'Failed'; error = $null; changes = @() },
                [pscustomobject]@{ status = 'Succeeded'; error = [pscustomobject]@{ code = 'Suppressed' }; changes = @() }
            )) {
                $script:whatIfResult = $malformed

                $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333' -SourceFingerprint $script:whatIfSourceFingerprint

                $result.applyReady | Should -BeFalse
                $result.reason | Should -BeLike '*malformed result contract*'
            }
        }

        It 'rejects every non-ResourceIdOnly or incomplete change prediction' {
            foreach ($changeType in @('Delete', 'Ignore', 'Modify', 'NoChange', 'NoEffect', 'Unsupported', 'FutureChange')) {
                $script:whatIfResult = [pscustomobject]@{
                    status = 'Succeeded'
                    error = $null
                    changes = @([pscustomobject]@{
                        changeType = $changeType
                        resourceId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev'
                    })
                }

                (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333' -SourceFingerprint $script:whatIfSourceFingerprint).applyReady |
                    Should -BeFalse
            }
        }

        It 'rejects lower or mixed-case spellings of every reviewed change type' {
            foreach ($changeType in @(
                'create', 'CREATE', 'cReAtE',
                'deploy', 'DEPLOY', 'dEpLoY',
                'ignore', 'IGNORE', 'iGnOrE'
            )) {
                $script:whatIfResult = [pscustomobject]@{
                    status = 'Succeeded'
                    error = $null
                    changes = @([pscustomobject]@{
                        changeType = $changeType
                        resourceId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev'
                    })
                }

                (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId $script:whatIfOwnershipId -SourceFingerprint $script:whatIfSourceFingerprint -State $script:recoveryState).applyReady |
                    Should -BeFalse
            }
            Should -Invoke Get-GatewayInertWhatIfRecoveryBoundary -Times 0 -Exactly
        }

        It 'rejects null or shape-less successful output' {
            foreach ($malformed in @(
                $null,
                [pscustomobject]@{},
                [pscustomobject]@{ status = 'Succeeded'; error = $null; properties = [pscustomobject]@{} }
            )) {
                $script:whatIfResult = $malformed

                $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333' -SourceFingerprint $script:whatIfSourceFingerprint

                $result.executed | Should -BeTrue
                $result.applyReady | Should -BeFalse
                $result.reason | Should -BeLike '*malformed result contract*'
            }
        }

        It 'rejects non-array changes and noncanonical resource IDs' {
            $script:whatIfResult = [pscustomobject]@{
                status = 'Succeeded'
                error = $null
                properties = [pscustomobject]@{
                    changes = [pscustomobject]@{ changeType = 'Create'; resourceId = '/subscriptions/other/resourceGroups/rg-safe-dev' }
                }
            }
            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333' -SourceFingerprint $script:whatIfSourceFingerprint).applyReady |
                Should -BeFalse

            $script:whatIfResult.properties.changes = @([pscustomobject]@{
                changeType = 'Create'
                resourceId = '/subscriptions/99999999-9999-4999-8999-999999999999/resourceGroups/rg-other'
            })
            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333' -SourceFingerprint $script:whatIfSourceFingerprint).applyReady |
                Should -BeFalse
        }
    }
}

Describe 'SQL private-endpoint What-If recovery extension' {
    InModuleScope Experience {
        BeforeEach {
            $script:sqlExtensionSubscriptionId = '11111111-1111-4111-8111-111111111111'
            $script:sqlExtensionOwnershipId = '22222222-2222-4222-8222-222222222222'
            $script:sqlExtensionSourceFingerprint = "sha256:$('a' * 64)"
            $script:sqlExtensionConfig = [pscustomobject]@{
                subscriptionId = $script:sqlExtensionSubscriptionId
                resourceGroupName = 'rg-safe-dev'
                projectName = 'safe'
                environment = 'dev'
                location = 'koreacentral'
            }
            $providerPrefix = "/subscriptions/$($script:sqlExtensionSubscriptionId)/resourceGroups/rg-safe-dev/providers"
            $script:sqlExtensionPrivateEndpointId = "$providerPrefix/Microsoft.Network/privateEndpoints/pe-sql-safe-dev"
            $script:sqlExtensionNicId = "$providerPrefix/Microsoft.Network/networkInterfaces/pe-sql-safe-dev.nic.33333333-3333-4333-8333-333333333333"
            $script:sqlExtensionZoneId = "$providerPrefix/Microsoft.Network/privateDnsZones/privatelink.database.windows.net"
            $script:sqlExtensionLinkId = "$($script:sqlExtensionZoneId)/virtualNetworkLinks/link-safe-dev-sql"
            $script:sqlExtensionZoneGroupId = "$($script:sqlExtensionPrivateEndpointId)/privateDnsZoneGroups/sqlDnsGroup"
            $script:sqlExtensionSubnetId = "$providerPrefix/Microsoft.Network/virtualNetworks/vnet-safe-dev/subnets/snet-private-endpoints"
            $script:sqlExtensionFoundation = [pscustomobject]@{
                privateEndpointSubnetId = $script:sqlExtensionSubnetId
            }
            $script:sqlExtensionEvidence = [ordered]@{
                privateEndpointId = $script:sqlExtensionPrivateEndpointId
                privateDnsZoneId = $script:sqlExtensionZoneId
                virtualNetworkLinkId = $script:sqlExtensionLinkId
                privateDnsZoneGroupId = $script:sqlExtensionZoneGroupId
            }
            $script:sqlExtensionNetworkInterfaces = @([pscustomobject]@{ id = $script:sqlExtensionNicId })
            $script:sqlExtensionNicPrivateEndpointId = $script:sqlExtensionPrivateEndpointId
            Mock Test-GatewaySqlPrivateEndpointEvidence { return $true }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'network') {
                    return [pscustomobject]@{
                        id = $script:sqlExtensionPrivateEndpointId
                        name = 'pe-sql-safe-dev'
                        location = 'koreacentral'
                        provisioningState = 'Succeeded'
                        subnet = [pscustomobject]@{ id = $script:sqlExtensionSubnetId }
                        networkInterfaces = $script:sqlExtensionNetworkInterfaces
                    }
                }
                if ([string]$Arguments[0] -ceq 'resource') {
                    return [pscustomobject]@{
                        id = $script:sqlExtensionNicId
                        type = 'Microsoft.Network/networkInterfaces'
                        name = 'pe-sql-safe-dev.nic.33333333-3333-4333-8333-333333333333'
                        location = 'koreacentral'
                        properties = [pscustomobject]@{
                            provisioningState = 'Succeeded'
                            privateEndpoint = [pscustomobject]@{ id = $script:sqlExtensionNicPrivateEndpointId }
                            ipConfigurations = @([pscustomobject]@{
                                properties = [pscustomobject]@{
                                    subnet = [pscustomobject]@{ id = $script:sqlExtensionSubnetId }
                                }
                            })
                        }
                    }
                }
                throw 'Unexpected SQL recovery extension readback.'
            }
        }

        It 'derives one fingerprinted four-resource extension with an exact generated-NIC reverse binding' {
            $extension = Get-GatewaySqlPrivateEndpointWhatIfRecoveryExtension `
                -Config $script:sqlExtensionConfig `
                -Foundation $script:sqlExtensionFoundation `
                -SqlServerFqdn 'sql-safe-dev.database.windows.net' `
                -Evidence $script:sqlExtensionEvidence `
                -DeploymentOwnershipId $script:sqlExtensionOwnershipId `
                -SourceFingerprint $script:sqlExtensionSourceFingerprint

            $validated = Assert-GatewaySqlPrivateEndpointWhatIfRecoveryExtension `
                -Extension $extension `
                -Config $script:sqlExtensionConfig `
                -DeploymentOwnershipId $script:sqlExtensionOwnershipId `
                -SourceFingerprint $script:sqlExtensionSourceFingerprint
            $extension.resourceIds.Count | Should -Be 4
            $validated.resourceIds.Count | Should -Be 4
            $extension.generatedNicBinding.nicId | Should -BeExactly $script:sqlExtensionNicId.ToLowerInvariant()
            $extension.boundaryFingerprint | Should -Match '^sha256:[0-9a-f]{64}$'
            Should -Invoke Test-GatewaySqlPrivateEndpointEvidence -Times 1 -Exactly
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'network' -and [string]$Arguments[1] -ceq 'private-endpoint'
            }
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'resource' -and $Arguments -contains '2023-11-01'
            }
        }

        It 'rejects zero or multiple generated network interfaces' {
            foreach ($interfaces in @(
                @(),
                @([pscustomobject]@{ id = $script:sqlExtensionNicId }, [pscustomobject]@{ id = $script:sqlExtensionNicId })
            )) {
                $script:sqlExtensionNetworkInterfaces = $interfaces
                { Get-GatewaySqlPrivateEndpointWhatIfRecoveryExtension `
                        -Config $script:sqlExtensionConfig `
                        -Foundation $script:sqlExtensionFoundation `
                        -SqlServerFqdn 'sql-safe-dev.database.windows.net' `
                        -Evidence $script:sqlExtensionEvidence `
                        -DeploymentOwnershipId $script:sqlExtensionOwnershipId `
                        -SourceFingerprint $script:sqlExtensionSourceFingerprint } |
                    Should -Throw '*one exact generated network interface*'
            }
            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'resource'
            }
        }

        It 'rejects a generated NIC that does not reverse-bind to the exact SQL endpoint' {
            $script:sqlExtensionNicPrivateEndpointId =
                $script:sqlExtensionPrivateEndpointId.Replace('/pe-sql-safe-dev', '/pe-other')

            { Get-GatewaySqlPrivateEndpointWhatIfRecoveryExtension `
                    -Config $script:sqlExtensionConfig `
                    -Foundation $script:sqlExtensionFoundation `
                    -SqlServerFqdn 'sql-safe-dev.database.windows.net' `
                    -Evidence $script:sqlExtensionEvidence `
                    -DeploymentOwnershipId $script:sqlExtensionOwnershipId `
                    -SourceFingerprint $script:sqlExtensionSourceFingerprint } |
                Should -Throw '*does not exactly reverse-bind*'
        }
    }
}

Describe 'Defender for Storage Event Grid What-If recovery extension' {
    InModuleScope Experience {
        BeforeEach {
            $script:defenderSubscriptionId = '11111111-1111-4111-8111-111111111111'
            $script:defenderOwnershipId = '22222222-2222-4222-8222-222222222222'
            $script:defenderSourceFingerprint = "sha256:$('a' * 64)"
            $script:defenderConfig = [pscustomobject]@{
                subscriptionId = $script:defenderSubscriptionId
                resourceGroupName = 'rg-safe-dev'
                projectName = 'safe'
                environment = 'dev'
                location = 'koreacentral'
            }
            $providerPrefix = "/subscriptions/$($script:defenderSubscriptionId)/resourcegroups/rg-safe-dev/providers"
            $script:defenderStorageAccountId =
                "$providerPrefix/microsoft.storage/storageaccounts/stsafe"
            $script:defenderSystemTopicName =
                'stsafe-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            $script:defenderSystemTopicId =
                "$providerPrefix/microsoft.eventgrid/systemtopics/$($script:defenderSystemTopicName)"
            $script:defenderEventSubscriptionId =
                "$($script:defenderSystemTopicId)/eventsubscriptions/storageantimalwaresubscription"
            $script:defenderTopicInventory = @([pscustomobject]@{
                id = $script:defenderSystemTopicId
            })
            $script:defenderSystemTopic = [pscustomobject]@{
                id = $script:defenderSystemTopicId
                type = 'Microsoft.EventGrid/systemTopics'
                name = $script:defenderSystemTopicName
                location = 'koreacentral'
                tags = $null
                identity = $null
                provisioningState = 'Succeeded'
                source = $script:defenderStorageAccountId
                topicType = 'Microsoft.Storage.StorageAccounts'
            }
            $script:defenderEventSubscriptionInventory = @([pscustomobject]@{
                id = $script:defenderEventSubscriptionId
                name = 'StorageAntimalwareSubscription'
            })
            $script:defenderEventSubscription = [pscustomobject]@{
                id = $script:defenderEventSubscriptionId
                type = 'Microsoft.EventGrid/systemTopics/eventSubscriptions'
                name = 'StorageAntimalwareSubscription'
                provisioningState = 'Succeeded'
                topic = $script:defenderSystemTopicId
                destinationEndpointType = 'WebHook'
                eventDeliverySchema = 'EventGridSchema'
                includedEventTypes = @(
                    'Microsoft.Storage.BlobCreated',
                    'Microsoft.Storage.BlobRenamed'
                )
                subjectBeginsWith = ''
                subjectEndsWith = ''
                isSubjectCaseSensitive = $null
                advancedFilters = @([pscustomobject]@{
                    key = 'data.blobType'
                    operatorType = 'StringContains'
                    values = @('BlockBlob')
                })
                retryPolicy = [pscustomobject]@{
                    eventTimeToLiveInMinutes = 1440
                    maxDeliveryAttempts = 30
                }
                deadLetterDestination = $null
                deliveryWithResourceIdentity = $null
                deadLetterWithResourceIdentity = $null
            }
            $script:defenderAzCalls = [Collections.Generic.List[object]]::new()
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                $script:defenderAzCalls.Add(@($Arguments))
                if ([string]$Arguments[0] -ceq 'resource' -and
                    [string]$Arguments[1] -ceq 'list') {
                    return $script:defenderTopicInventory
                }
                if ([string]$Arguments[0] -ceq 'eventgrid') {
                    return $script:defenderEventSubscriptionInventory
                }
                if ([string]$Arguments[0] -ceq 'resource' -and
                    [string]$Arguments[1] -ceq 'show') {
                    $idIndex = [Array]::IndexOf([object[]]$Arguments, '--ids')
                    if ($idIndex -lt 0 -or $idIndex + 1 -ge $Arguments.Count) {
                        throw 'Test resource show requires one exact ID.'
                    }
                    $resourceId = [string]$Arguments[$idIndex + 1]
                    if ($resourceId -ceq $script:defenderSystemTopicId) {
                        return $script:defenderSystemTopic
                    }
                    if ($resourceId -ceq $script:defenderEventSubscriptionId) {
                        return $script:defenderEventSubscription
                    }
                }
                throw 'Unexpected Defender Storage recovery readback.'
            }
        }

        It 'derives and validates one exact fingerprinted topic extension from the bounded live-generation child contract' {
            $extension = Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                -Config $script:defenderConfig `
                -StorageAccountId $script:defenderStorageAccountId `
                -DeploymentOwnershipId $script:defenderOwnershipId `
                -SourceFingerprint $script:defenderSourceFingerprint

            $validated = Assert-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                -Extension $extension `
                -Config $script:defenderConfig `
                -StorageAccountId $script:defenderStorageAccountId `
                -DeploymentOwnershipId $script:defenderOwnershipId `
                -SourceFingerprint $script:defenderSourceFingerprint

            $extension.schemaVersion | Should -Be 2
            $extension.present | Should -BeTrue
            $extension.resourceIds | Should -Be @($script:defenderSystemTopicId)
            $validated.present | Should -BeTrue
            $validated.resourceIds | Should -Be @($script:defenderSystemTopicId)
            $extension.systemTopicBinding.storageAccountId |
                Should -BeExactly $script:defenderStorageAccountId
            $extension.eventSubscriptionBinding.eventSubscriptionId |
                Should -BeExactly $script:defenderEventSubscriptionId
            $extension.boundaryFingerprint | Should -Match '^sha256:[0-9a-f]{64}$'
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'resource' -and
                [string]$Arguments[1] -ceq 'list' -and
                $Arguments -contains 'Microsoft.EventGrid/systemTopics'
            }
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'eventgrid' -and
                $Arguments -contains $script:defenderSystemTopicName -and
                $Arguments -contains 'event-subscription'
            }
            Should -Invoke Invoke-AzJson -Times 2 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'resource' -and
                [string]$Arguments[1] -ceq 'show' -and
                $Arguments -contains '2025-02-15'
            }
            foreach ($arguments in $script:defenderAzCalls) {
                ($arguments -join '|') |
                    Should -Not -Match '(?i)endpointUrl|endpointBaseUrl|include-full-endpoint'
            }
        }

        It 'derives and validates a fingerprinted typed-absence marker from an absent provider inventory' {
            $script:defenderTopicInventory = @()

            $extension = Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                -Config $script:defenderConfig `
                -StorageAccountId $script:defenderStorageAccountId `
                -DeploymentOwnershipId $script:defenderOwnershipId `
                -SourceFingerprint $script:defenderSourceFingerprint
            $validated = Assert-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                -Extension $extension `
                -Config $script:defenderConfig `
                -StorageAccountId $script:defenderStorageAccountId `
                -DeploymentOwnershipId $script:defenderOwnershipId `
                -SourceFingerprint $script:defenderSourceFingerprint

            $extension.schemaVersion | Should -Be 2
            $extension.phase | Should -BeExactly 'DefenderStorageSystemTopic'
            $extension.present | Should -BeFalse
            @($extension.resourceIds).Count | Should -Be 0
            @($extension.typeInventoryResourceIds['Microsoft.EventGrid/systemTopics']).Count |
                Should -Be 0
            $extension.systemTopicBinding | Should -BeNullOrEmpty
            $extension.eventSubscriptionBinding | Should -BeNullOrEmpty
            $extension.boundaryFingerprint | Should -Match '^sha256:[0-9a-f]{64}$'
            $validated.present | Should -BeFalse
            @($validated.resourceIds).Count | Should -Be 0
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'resource' -and
                [string]$Arguments[1] -ceq 'list'
            }
            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'resource' -and
                [string]$Arguments[1] -ceq 'show'
            }
            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'eventgrid'
            }
        }

        It 'rejects multiple system topics in the exact target resource group' {
            $script:defenderTopicInventory = @(
                [pscustomobject]@{ id = $script:defenderSystemTopicId },
                [pscustomobject]@{
                    id = $script:defenderSystemTopicId.Replace(
                        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
                }
            )

            { Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                    -Config $script:defenderConfig `
                    -StorageAccountId $script:defenderStorageAccountId `
                    -DeploymentOwnershipId $script:defenderOwnershipId `
                    -SourceFingerprint $script:defenderSourceFingerprint } |
                Should -Throw '*at most one Event Grid system topic*'
        }

        It 'rejects a system-topic envelope that is not the exact observed topic' {
            $script:defenderSystemTopic.type = 'Microsoft.EventGrid/topics'

            { Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                    -Config $script:defenderConfig `
                    -StorageAccountId $script:defenderStorageAccountId `
                    -DeploymentOwnershipId $script:defenderOwnershipId `
                    -SourceFingerprint $script:defenderSourceFingerprint } |
                Should -Throw '*does not match the exact observed Defender Storage recovery envelope*'
        }

        It 'rejects a system topic bound to a different storage source' {
            $script:defenderSystemTopic.source =
                $script:defenderStorageAccountId.Replace('/stsafe', '/stother')

            { Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                    -Config $script:defenderConfig `
                    -StorageAccountId $script:defenderStorageAccountId `
                    -DeploymentOwnershipId $script:defenderOwnershipId `
                    -SourceFingerprint $script:defenderSourceFingerprint } |
                Should -Throw '*does not match the exact observed Defender Storage recovery envelope*'
        }

        It 'rejects a topic whose observed live-generation suffix is not one canonical GUID before detail readback' {
            $wrongSuffixId = $script:defenderSystemTopicId.Replace(
                'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                'not-a-guid')
            $script:defenderTopicInventory[0].id = $wrongSuffixId

            { Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                    -Config $script:defenderConfig `
                    -StorageAccountId $script:defenderStorageAccountId `
                    -DeploymentOwnershipId $script:defenderOwnershipId `
                    -SourceFingerprint $script:defenderSourceFingerprint } |
                Should -Throw '*suffix is not one canonical nonempty GUID*'
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'resource' -and
                [string]$Arguments[1] -ceq 'list'
            }
            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'resource' -and
                [string]$Arguments[1] -ceq 'show'
            }
        }

        It 'rejects a wrong malware-scanning child identity' {
            $script:defenderEventSubscriptionInventory[0].name = 'OtherSubscription'

            { Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                    -Config $script:defenderConfig `
                    -StorageAccountId $script:defenderStorageAccountId `
                    -DeploymentOwnershipId $script:defenderOwnershipId `
                    -SourceFingerprint $script:defenderSourceFingerprint } |
                Should -Throw '*exact single observed malware-scanning event subscription*'
        }

        It 'rejects a child that does not reverse-bind to the exact topic' {
            $script:defenderEventSubscription.topic =
                $script:defenderSystemTopicId.Replace('/stsafe-', '/other-')

            { Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                    -Config $script:defenderConfig `
                    -StorageAccountId $script:defenderStorageAccountId `
                    -DeploymentOwnershipId $script:defenderOwnershipId `
                    -SourceFingerprint $script:defenderSourceFingerprint } |
                Should -Throw '*does not match the exact bounded live-generation recovery contract*'
        }

        It 'rejects an extra system-topic child' {
            $script:defenderEventSubscriptionInventory = @(
                [pscustomobject]@{
                    id = $script:defenderEventSubscriptionId
                    name = 'StorageAntimalwareSubscription'
                },
                [pscustomobject]@{
                    id = "$($script:defenderSystemTopicId)/eventsubscriptions/extra"
                    name = 'extra'
                }
            )

            { Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                    -Config $script:defenderConfig `
                    -StorageAccountId $script:defenderStorageAccountId `
                    -DeploymentOwnershipId $script:defenderOwnershipId `
                    -SourceFingerprint $script:defenderSourceFingerprint } |
                Should -Throw '*exact single observed malware-scanning event subscription*'
        }

        It 'rejects drift in the bounded live-generation malware filter' {
            $script:defenderEventSubscription.advancedFilters[0].values = @('PageBlob')

            { Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                    -Config $script:defenderConfig `
                    -StorageAccountId $script:defenderStorageAccountId `
                    -DeploymentOwnershipId $script:defenderOwnershipId `
                    -SourceFingerprint $script:defenderSourceFingerprint } |
                Should -Throw '*does not match the exact bounded live-generation recovery contract*'
        }

        It 'rejects scalar provider values for every array-valued malware contract field' {
            foreach ($surface in @('includedEventTypes', 'advancedFilters', 'advancedFilterValues')) {
                $script:defenderEventSubscription.includedEventTypes = @(
                    'Microsoft.Storage.BlobCreated',
                    'Microsoft.Storage.BlobRenamed'
                )
                $script:defenderEventSubscription.advancedFilters = @([pscustomobject]@{
                    key = 'data.blobType'
                    operatorType = 'StringContains'
                    values = @('BlockBlob')
                })
                switch ($surface) {
                    'includedEventTypes' {
                        $script:defenderEventSubscription.includedEventTypes =
                            'Microsoft.Storage.BlobCreated'
                    }
                    'advancedFilters' {
                        $script:defenderEventSubscription.advancedFilters = [pscustomobject]@{
                            key = 'data.blobType'
                            operatorType = 'StringContains'
                            values = @('BlockBlob')
                        }
                    }
                    'advancedFilterValues' {
                        $script:defenderEventSubscription.advancedFilters[0].values = 'BlockBlob'
                    }
                }

                { Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                        -Config $script:defenderConfig `
                        -StorageAccountId $script:defenderStorageAccountId `
                        -DeploymentOwnershipId $script:defenderOwnershipId `
                        -SourceFingerprint $script:defenderSourceFingerprint } |
                    Should -Throw '*does not match the exact bounded live-generation recovery contract*'
            }
        }

        It 'rejects scalar arrays in a persisted present extension before trusting its fingerprint' {
            foreach ($surface in @('includedEventTypes', 'advancedFilterValues')) {
                $extension = Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                    -Config $script:defenderConfig `
                    -StorageAccountId $script:defenderStorageAccountId `
                    -DeploymentOwnershipId $script:defenderOwnershipId `
                    -SourceFingerprint $script:defenderSourceFingerprint
                if ($surface -ceq 'includedEventTypes') {
                    $extension.eventSubscriptionBinding.includedEventTypes =
                        'Microsoft.Storage.BlobCreated'
                }
                else {
                    $extension.eventSubscriptionBinding.advancedFilter.values = 'BlockBlob'
                }

                { Assert-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                        -Extension $extension `
                        -Config $script:defenderConfig `
                        -StorageAccountId $script:defenderStorageAccountId `
                        -DeploymentOwnershipId $script:defenderOwnershipId `
                        -SourceFingerprint $script:defenderSourceFingerprint } |
                    Should -Throw '*does not match the exact bounded live-generation contract*'
            }
        }

        It 'rejects a tampered extension even when its fingerprint is recomputed' {
            $extension = Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                -Config $script:defenderConfig `
                -StorageAccountId $script:defenderStorageAccountId `
                -DeploymentOwnershipId $script:defenderOwnershipId `
                -SourceFingerprint $script:defenderSourceFingerprint
            $extension.eventSubscriptionBinding.advancedFilter.values = @('PageBlob')
            $extension.boundaryFingerprint = Get-BootstrapObjectFingerprint -InputObject (
                [ordered]@{
                    schemaVersion = 2
                    phase = 'DefenderStorageSystemTopic'
                    present = $true
                    deploymentOwnershipId = $extension.deploymentOwnershipId
                    sourceFingerprint = $extension.sourceFingerprint
                    resourceIds = $extension.resourceIds
                    typeInventoryResourceIds = $extension.typeInventoryResourceIds
                    systemTopicBinding = $extension.systemTopicBinding
                    eventSubscriptionBinding = $extension.eventSubscriptionBinding
                })

            { Assert-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                    -Extension $extension `
                    -Config $script:defenderConfig `
                    -StorageAccountId $script:defenderStorageAccountId `
                    -DeploymentOwnershipId $script:defenderOwnershipId `
                    -SourceFingerprint $script:defenderSourceFingerprint } |
                Should -Throw '*does not match the exact bounded live-generation contract*'
        }
    }
}

Describe 'Immutable ACR QuickRun verification boundary' {
    InModuleScope Experience {
        BeforeEach {
            $script:imageSourceFingerprint = "sha256:$('a' * 64)"
            $script:imageOwnershipId = '11111111-1111-4111-8111-111111111111'
            $script:imageLoginServer = 'acrsafe.azurecr.io'
            $script:imageRunType = 'QuickRun'
            $script:imageDefinitions = [ordered]@{
                api = [ordered]@{
                    repository = 'gateway-api'
                    intentId = '22222222-2222-4222-8222-222222222222'
                    runId = 'run-api'
                    digest = "sha256:$('1' * 64)"
                }
                worker = [ordered]@{
                    repository = 'gateway-worker'
                    intentId = '33333333-3333-4333-8333-333333333333'
                    runId = 'run-worker'
                    digest = "sha256:$('2' * 64)"
                }
                adminUi = [ordered]@{
                    repository = 'gateway-admin'
                    intentId = '44444444-4444-4444-8444-444444444444'
                    runId = 'run-admin'
                    digest = "sha256:$('3' * 64)"
                }
                databaseMigrator = [ordered]@{
                    repository = 'gateway-db-migrator'
                    intentId = '55555555-5555-4555-8555-555555555555'
                    runId = 'run-database-migrator'
                    digest = "sha256:$('4' * 64)"
                }
            }
            $script:imageEvidence = [ordered]@{
                schemaVersion = 3
                registry = 'acrsafe'
                sourceFingerprint = $script:imageSourceFingerprint
                deploymentOwnershipId = $script:imageOwnershipId
                provenance = 'BootstrapPreMutationIntentV3'
                buildIntents = [ordered]@{}
                checkpointedComponents = @('api', 'worker', 'adminUi', 'databaseMigrator')
            }
            foreach ($name in @('api', 'worker', 'adminUi', 'databaseMigrator')) {
                $definition = $script:imageDefinitions[$name]
                $tag = Get-BootstrapImageBuildIntentTag `
                    -DeploymentOwnershipId $script:imageOwnershipId `
                    -SourceFingerprint $script:imageSourceFingerprint `
                    -IntentId ([string]$definition.intentId)
                $image = "$($script:imageLoginServer)/$($definition.repository)@$($definition.digest)"
                $script:imageEvidence.buildIntents[$name] = [ordered]@{
                    component = $name
                    repository = [string]$definition.repository
                    intentId = [string]$definition.intentId
                    tag = $tag
                    state = 'DigestCheckpointed'
                    runId = [string]$definition.runId
                    digest = [string]$definition.digest
                    image = $image
                }
                $script:imageEvidence[$name] = $image
                $script:imageEvidence["${name}Digest"] = [string]$definition.digest
            }

            Mock Invoke-AzTsv {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'acr' -and [string]$Arguments[1] -ceq 'show') {
                    return $script:imageLoginServer
                }
                if ([string]$Arguments[0] -ceq 'acr' -and [string]$Arguments[1] -ceq 'manifest') {
                    $nameIndex = [Array]::IndexOf([object[]]$Arguments, '--name')
                    $target = [string]$Arguments[$nameIndex + 1]
                    foreach ($component in @('api', 'worker', 'adminUi', 'databaseMigrator')) {
                        $definition = $script:imageDefinitions[$component]
                        $intent = $script:imageEvidence.buildIntents[$component]
                        if ($target -ceq "$($definition.repository):$($intent.tag)") {
                            return [string]$definition.digest
                        }
                    }
                }
                throw 'Unexpected immutable-image TSV readback.'
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                $runIdIndex = [Array]::IndexOf([object[]]$Arguments, '--run-id')
                $runId = [string]$Arguments[$runIdIndex + 1]
                $components = @($script:imageDefinitions.Keys | Where-Object {
                    [string]$script:imageDefinitions[$_].runId -ceq $runId
                })
                if ($components.Count -ne 1) { throw 'Unexpected immutable-image run readback.' }
                $component = [string]$components[0]
                $definition = $script:imageDefinitions[$component]
                $intent = $script:imageEvidence.buildIntents[$component]
                return [pscustomobject]@{
                    runId = $runId
                    status = 'Succeeded'
                    runType = $script:imageRunType
                    outputImages = @([pscustomobject]@{
                        repository = [string]$definition.repository
                        tag = [string]$intent.tag
                        digest = [string]$definition.digest
                    })
                    providerOutput = 'private-provider-body-marker'
                }
            }
        }

        It 'accepts exact succeeded QuickRun evidence for all four az acr build outputs' {
            Test-GatewayImmutableImageEvidence `
                -Evidence $script:imageEvidence `
                -SourceFingerprint $script:imageSourceFingerprint `
                -DeploymentOwnershipId $script:imageOwnershipId |
                Should -BeTrue

            Should -Invoke Invoke-AzJson -Times 4 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'acr' -and
                [string]$Arguments[1] -ceq 'task' -and
                [string]$Arguments[2] -ceq 'show-run'
            }
        }

        It 'rejects legacy three-image evidence before any Azure readback' {
            $script:imageEvidence.schemaVersion = 2
            $script:imageEvidence.provenance = 'BootstrapPreMutationIntentV2'
            $null = $script:imageEvidence.buildIntents.Remove('databaseMigrator')
            $null = $script:imageEvidence.Remove('databaseMigrator')
            $null = $script:imageEvidence.Remove('databaseMigratorDigest')
            $script:imageEvidence.checkpointedComponents = @('api', 'worker', 'adminUi')

            { Test-GatewayImmutableImageEvidence `
                    -Evidence $script:imageEvidence `
                    -SourceFingerprint $script:imageSourceFingerprint `
                    -DeploymentOwnershipId $script:imageOwnershipId } |
                Should -Throw '*evidence is incomplete or belongs to different state/source*'

            Should -Invoke Invoke-AzTsv -Times 0 -Exactly
            Should -Invoke Invoke-AzJson -Times 0 -Exactly
        }

        It 'rejects QuickBuild and automatic run types without disclosing provider output' {
            foreach ($unsupportedRunType in @('QuickBuild', 'AutoBuild', 'AutoRun')) {
                $script:imageRunType = $unsupportedRunType
                try {
                    Test-GatewayImmutableImageEvidence `
                        -Evidence $script:imageEvidence `
                        -SourceFingerprint $script:imageSourceFingerprint `
                        -DeploymentOwnershipId $script:imageOwnershipId
                    throw 'Expected non-QuickRun immutable-image evidence to fail closed.'
                }
                catch {
                    $_.Exception.Message | Should -BeExactly 'Immutable-image revalidation was unavailable or mismatched; refusing automatic rebuild. Review access/state and run gateway diagnose.'
                    $_.Exception.Message | Should -Not -Match 'private-provider-body-marker'
                }
            }
        }
    }
}

Describe 'Resume-time Entra application authentication boundary' {
    InModuleScope Experience {
        BeforeEach {
            $script:lastGraphUrl = ''
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                $script:lastGraphUrl = [string]$Arguments[$Arguments.Count - 1]
                return [pscustomobject]@{
                    id = '11111111-1111-4111-8111-111111111111'
                    appId = '22222222-2222-4222-8222-222222222222'
                    displayName = 'A365 Gateway API - safe-dev'
                    signInAudience = 'AzureADMyOrg'
                    identifierUris = @('api://a365-gateway-safe-dev')
                    tags = @(
                        'A365GatewayBootstrap',
                        'A365GatewayOwnership:33333333-3333-4333-8333-333333333333'
                    )
                    api = [pscustomobject]@{
                        requestedAccessTokenVersion = 2
                        acceptMappedClaims = $false
                        preAuthorizedApplications = @()
                        knownClientApplications = @()
                    }
                    appRoles = @()
                    requiredResourceAccess = @()
                    passwordCredentials = @()
                    keyCredentials = @()
                    web = [pscustomobject]@{ redirectUris = @(); logoutUrl = $null; homePageUrl = $null }
                    spa = [pscustomobject]@{ redirectUris = @() }
                    publicClient = [pscustomobject]@{ redirectUris = @() }
                    isFallbackPublicClient = $true
                }
            }

            $script:resumeConfig = [pscustomobject]@{ projectName = 'safe'; environment = 'dev' }
            $script:resumeEvidence = [ordered]@{
                gatewayApiApplicationObjectId = '11111111-1111-4111-8111-111111111111'
                gatewayApiClientId = '22222222-2222-4222-8222-222222222222'
                gatewayApiScopeBaseUri = 'api://a365-gateway-safe-dev'
                gatewayApiTokenAudience = '22222222-2222-4222-8222-222222222222'
                deploymentOwnershipId = '33333333-3333-4333-8333-333333333333'
                ownerObjectId = '44444444-4444-4444-8444-444444444444'
                gatewayAdministratorRoleId = '55555555-5555-4555-8555-555555555555'
                gatewayApiAccessScopeId = '66666666-6666-4666-8666-666666666666'
                gatewayApiServicePrincipalId = '77777777-7777-4777-8777-777777777777'
            }
        }

        It 'rejects a public-client fallback before replay and selects the complete auth surface' {
            { Test-GatewayApplicationEvidence `
                -Config $script:resumeConfig `
                -Evidence $script:resumeEvidence `
                -ObjectIdProperty 'gatewayApiApplicationObjectId' `
                -ClientIdProperty 'gatewayApiClientId' `
                -ApplicationKind GatewayApi } |
                Should -Throw '*refusing automatic replay*'

            $script:lastGraphUrl | Should -Match 'isFallbackPublicClient'
            $script:lastGraphUrl | Should -Match '(?:\?|,)api(?:,|$)'
            $script:lastGraphUrl | Should -Match '(?:\?|,)web(?:,|$)'
        }

        It 'rejects a service-principal credential during resume and selects every exact SP surface' {
            $roleValues = @('Gateway.Administrator', 'Gateway.Operator', 'Gateway.Auditor', 'Gateway.SupportReader')
            $roles = @($roleValues | ForEach-Object {
                [pscustomobject]@{
                    id = if ($_ -eq 'Gateway.Administrator') { $script:resumeEvidence.gatewayAdministratorRoleId } else { [guid]::NewGuid().ToString('D') }
                    value = $_
                    isEnabled = $true
                    allowedMemberTypes = @('User')
                }
            })
            Mock Invoke-AzJson {
                return [pscustomobject]@{
                    id = $script:resumeEvidence.gatewayApiApplicationObjectId
                    appId = $script:resumeEvidence.gatewayApiClientId
                    displayName = 'A365 Gateway API - safe-dev'
                    signInAudience = 'AzureADMyOrg'
                    identifierUris = @('api://a365-gateway-safe-dev')
                    tags = @('A365GatewayBootstrap', 'A365GatewayOwnership:33333333-3333-4333-8333-333333333333')
                    api = [pscustomobject]@{
                        requestedAccessTokenVersion = 2
                        acceptMappedClaims = $false
                        preAuthorizedApplications = @()
                        knownClientApplications = @()
                        oauth2PermissionScopes = @([pscustomobject]@{
                            id = $script:resumeEvidence.gatewayApiAccessScopeId
                            value = 'access_as_user'
                            isEnabled = $true
                            type = 'Admin'
                        })
                    }
                    appRoles = $roles
                    requiredResourceAccess = @()
                    passwordCredentials = @()
                    keyCredentials = @()
                    web = [pscustomobject]@{ redirectUris = @(); logoutUrl = $null; homePageUrl = $null }
                    spa = [pscustomobject]@{ redirectUris = @() }
                    publicClient = [pscustomobject]@{ redirectUris = @() }
                    isFallbackPublicClient = $false
                }
            }
            Mock Get-BoundedGraphCollection {
                param([string]$InitialUrl)
                if ($InitialUrl -match '/applications/.*/owners') {
                    return @([pscustomobject]@{ id = $script:resumeEvidence.ownerObjectId })
                }
                if ($InitialUrl -match '/servicePrincipals\?') {
                    $script:servicePrincipalUrl = $InitialUrl
                    return @([pscustomobject]@{
                        id = $script:resumeEvidence.gatewayApiServicePrincipalId
                        appId = $script:resumeEvidence.gatewayApiClientId
                        passwordCredentials = @([pscustomobject]@{ keyId = 'unapproved' })
                        keyCredentials = @()
                    })
                }
                throw "Unexpected Graph URL: $InitialUrl"
            }
            Mock Assert-ExactBootstrapServicePrincipalBoundary {
                param($ServicePrincipal)
                if (@($ServicePrincipal.passwordCredentials).Count -ne 0) {
                    throw 'Unapproved service-principal credential.'
                }
            }
            Mock Assert-GatewayApiDelegatedPermissionBoundary { return $true }

            { Test-GatewayApplicationEvidence `
                -Config $script:resumeConfig `
                -Evidence $script:resumeEvidence `
                -ObjectIdProperty 'gatewayApiApplicationObjectId' `
                -ClientIdProperty 'gatewayApiClientId' `
                -ApplicationKind GatewayApi } |
                Should -Throw '*refusing automatic replay*'

            foreach ($selectedProperty in @(
                'passwordCredentials', 'keyCredentials', 'accountEnabled',
                'appRoleAssignmentRequired', 'servicePrincipalType',
                'servicePrincipalNames', 'tags', 'alternativeNames',
                'appRoles', 'oauth2PermissionScopes'
            )) {
                $script:servicePrincipalUrl | Should -Match $selectedProperty
            }
        }
    }
}
