$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Experience.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Prerequisites.psm1') -Force

Describe 'Capability-only bootstrap source contract' {
    BeforeAll {
        $script:CapabilityRepositoryRoot =
            [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    }

    It 'does not discover or select a Purview SIT during terminal initialization' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Get-Module Experience).Path,
            [ref]$tokens,
            [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0
        $initializer = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'New-GatewayBootstrapConfiguration'
        }, $true)
        $source = $initializer.Extent.Text

        $source | Should -Not -Match 'Connect-GatewayPurviewSelectedTenantMember'
        $source | Should -Not -Match 'Get-BootstrapPurviewSensitiveInformationTypes'
        $source | Should -Not -Match 'Resolve-BootstrapPurviewSensitiveInformationType'
        $source | Should -Not -Match 'sensitiveInformationType'
        $source | Should -Match 'Full evaluation'
        $source | Should -Match 'Core Gateway'
        $source | Should -Match 'Custom'
        $source | Should -Match 'quota'
        $source | Should -Match 'authority'
    }

    It 'never invokes Purview policy authoring or policy readback from the ordinary engine' {
        $source = Get-Content -LiteralPath (
            Join-Path $script:CapabilityRepositoryRoot 'bootstrap/bootstrap.ps1') -Raw

        $source | Should -Not -Match 'Ensure-BootstrapPurviewPolicies'
        $source | Should -Not -Match 'Get-BootstrapPurviewPolicyEvidence'
        $source | Should -Not -Match 'Test-GatewayPurviewEvidence'
        $source | Should -Not -Match 'Purview-enabled deployment and verification require Windows'
    }

    It 'uses a capability prerequisite step rather than a policy step' {
        Get-GatewayBootstrapStepNames |
            Should -Contain 'Purview capability prerequisites'
        Get-GatewayBootstrapStepNames |
            Should -Not -Contain 'Purview policies'
    }

    It 'keeps capability readback separate from policy and runtime readiness' {
        $config = [pscustomobject]@{
            purview = [pscustomobject]@{ enabled = $true }
        }
        $identity = [pscustomobject]@{
            apiApplicationRoles = [ordered]@{
                'AgentIdentityBlueprint.Read.All' = '11111111-1111-4111-8111-111111111111'
                'ProtectionScopes.Compute.User' = '22222222-2222-4222-8222-222222222222'
                'Content.Process.User' = '33333333-3333-4333-8333-333333333333'
                'ContentActivity.Write' = '44444444-4444-4444-8444-444444444444'
            }
        }
        $automation = [ordered]@{
            status = 'Installed'
            organization = 'contoso.onmicrosoft.com'
            automationApplicationObjectId = '55555555-5555-4555-8555-555555555555'
            automationApplicationId = '66666666-6666-4666-8666-666666666666'
            automationServicePrincipalId = '77777777-7777-4777-8777-777777777777'
            exchangeOnlineProtectionApplicationId = '00000007-0000-0ff1-ce00-000000000000'
            exchangeManageAsAppRoleId = '455e5cd2-84e8-4751-8344-5672145dfa17'
            complianceAdministratorRoleDefinitionId = '17315797-102d-40b4-93e0-432062caca18'
            keyCredentialId = '88888888-8888-4888-8888-888888888888'
            certificateThumbprint = 'a' * 40
            certificateSecretResourceId = '/subscriptions/test/resourceGroups/test/providers/Microsoft.KeyVault/vaults/test/secrets/purview-automation-certificate'
            certificateSecretUri = 'https://test.vault.azure.net/secrets/purview-automation-certificate'
            deploymentOwnershipId = '99999999-9999-4999-8999-999999999999'
            sourceFingerprint = "sha256:$('b' * 64)"
            policyConfiguration = 'NotPerformed'
            policyReadiness = 'NotClaimed'
        }

        $evidence = Get-GatewayPurviewCapabilityEvidence `
            -Config $config `
            -WorkloadIdentity $identity `
            -Automation $automation

        $evidence.enabled | Should -BeTrue
        $evidence.apiGraphRoles | Should -BeExactly 'Installed'
        $evidence.policyConfiguration | Should -BeExactly 'NotPerformed'
        $evidence.policyReadiness | Should -BeExactly 'NotClaimed'
        Test-GatewayPurviewCapabilityEvidence `
            -Config $config `
            -WorkloadIdentity $identity `
            -Automation $automation `
            -Evidence $evidence |
            Should -BeTrue
    }

    It 'migrates a legacy policy checkpoint without replaying or discarding its evidence' {
        $config = [pscustomobject]@{
            purview = [pscustomobject]@{ enabled = $false }
        }
        $legacyEvidence = [ordered]@{
            configured = $true
            collectionPolicyId = 'safe-provider-id'
        }
        $state = [ordered]@{
            steps = [ordered]@{
                'Workflow v3 Entra configuration' = [ordered]@{
                    status = 'Completed'
                    evidence = [ordered]@{ apiApplicationRoles = [ordered]@{} }
                }
                'Purview policies' = [ordered]@{
                    status = 'Completed'
                    evidence = $legacyEvidence
                }
            }
        }

        Convert-GatewayLegacyPurviewPolicyStep -State $state -Config $config |
            Should -BeTrue

        $state.steps.Contains('Purview policies') | Should -BeFalse
        $state.steps.Contains('Purview capability prerequisites') | Should -BeTrue
        $state.legacyPurviewPolicyMigration.priorStep.evidence |
            Should -Be $legacyEvidence
        $state.steps['Purview capability prerequisites'].evidence.policyConfiguration |
            Should -BeExactly 'NotPerformed'
    }

    It 'emits a capability-only example and keeps legacy policy fields deprecated in the schema' {
        $example = Get-Content -LiteralPath (
            Join-Path $script:CapabilityRepositoryRoot 'bootstrap/config.example.json') -Raw
        $schema = Get-Content -LiteralPath (
            Join-Path $script:CapabilityRepositoryRoot 'bootstrap/config.schema.json') -Raw |
                ConvertFrom-Json -Depth 30

        $example | Should -Not -Match 'sensitiveInformationType'
        $example | Should -Not -Match '(collection|dlp)(Policy|Rule)Name'
        $schema.properties.purview.properties.sensitiveInformationType.deprecated |
            Should -BeTrue
        $schema.properties.purview.properties.sensitiveInformationTypeId.deprecated |
            Should -BeTrue
    }

    It 'requires explicit beta, quota-cost, and Purview authority acknowledgements' {
        $examplePath = Join-Path $script:CapabilityRepositoryRoot 'bootstrap/config.example.json'
        $base = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json -Depth 30
        $base.subscriptionId = '11111111-1111-4111-8111-111111111111'
        $base.tenantId = '22222222-2222-4222-8222-222222222222'
        foreach ($case in @(
            [ordered]@{ name = 'registry'; apply = { param($config) $config.agent365.registryBetaAcknowledged = $false } },
            [ordered]@{ name = 'prompt'; apply = { param($config) $config.promptShield.costAndQuotaAcknowledged = $false } },
            [ordered]@{ name = 'purview'; apply = { param($config) $config.purview.authorityRequirementsAcknowledged = $false } }
        )) {
            $config = $base | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
            & $case.apply $config
            $path = Join-Path $TestDrive "$($case.name)-acknowledgement.json"
            $config | ConvertTo-Json -Depth 30 |
                Set-Content -LiteralPath $path -Encoding utf8NoBOM

            { Read-BootstrapConfig -Path $path } |
                Should -Throw '*JSON Schema validation*'
        }
    }

    It 'loads a legacy configuration as migration-only evidence without weakening acknowledgements' {
        $config = Get-Content -LiteralPath (
            Join-Path $script:CapabilityRepositoryRoot 'bootstrap/config.example.json') -Raw |
                ConvertFrom-Json -Depth 30
        $config.PSObject.Properties.Remove('capabilityPreset')
        $config.agent365.PSObject.Properties.Remove('registryBetaAcknowledged')
        $config.promptShield.PSObject.Properties.Remove('costAndQuotaAcknowledged')
        $config.purview.PSObject.Properties.Remove('authorityRequirementsAcknowledged')
        $config.purview | Add-Member -NotePropertyName collectionPolicyName -NotePropertyValue 'Legacy collection'
        $config.purview | Add-Member -NotePropertyName dlpPolicyName -NotePropertyValue 'Legacy policy'
        $config.purview | Add-Member -NotePropertyName dlpRuleName -NotePropertyValue 'Legacy rule'
        $config.purview | Add-Member -NotePropertyName sensitiveInformationTypeId `
            -NotePropertyValue '50842eb7-edc8-4019-85dd-5a5c1f2bb085'
        $config.purview | Add-Member -NotePropertyName sensitiveInformationType `
            -NotePropertyValue 'Legacy classifier'
        $path = Join-Path $TestDrive 'legacy-capability.json'
        $config | ConvertTo-Json -Depth 30 |
            Set-Content -LiteralPath $path -Encoding utf8NoBOM

        $loaded = Read-BootstrapConfig -Path $path -WarningAction SilentlyContinue

        $loaded.capabilityPreset | Should -BeExactly 'fullEvaluation'
        $loaded.agent365.registryBetaAcknowledged | Should -BeTrue
        $loaded.promptShield.costAndQuotaAcknowledged | Should -BeTrue
        $loaded.purview.authorityRequirementsAcknowledged | Should -BeTrue
        $loaded.purview.legacyPolicyMigrationRequired | Should -BeTrue
    }

    It 'does not require Security and Compliance PowerShell for capability deployment' {
        $source = Get-Content -LiteralPath (
            Join-Path $script:CapabilityRepositoryRoot 'bootstrap/modules/Prerequisites.psm1') -Raw

        $source | Should -Not -Match 'if \(\$RequirePurview -and -not \$IsWindows\)'
        (Get-Command Assert-BootstrapPrerequisites).Parameters.Keys |
            Should -Not -Contain 'RequirePurview'
    }
}
