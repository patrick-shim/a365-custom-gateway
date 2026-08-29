$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Entra.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Agent365.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Experience.psm1') -Force

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
    }
}

Describe 'Workload deployment output mapping' {
    InModuleScope Experience {
        It 'maps the real Agent 365 Registry ARM output to the normalized evidence field' {
            $outputs = [pscustomobject]@{
                agent365RegistryProvider = [pscustomobject]@{ value = 'DirectRegistryPreview' }
            }
            $evidence = [pscustomobject]@{ registryProvider = 'DirectRegistryPreview' }

            Assert-GatewayDeploymentOutputEvidenceMap `
                -Outputs $outputs `
                -Evidence $evidence `
                -OutputToEvidenceName ([ordered]@{ agent365RegistryProvider = 'registryProvider' }) |
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

Describe 'Reviewed SQL bootstrap client IPv4 discovery' {
    InModuleScope Experience {
        It 'accepts only two agreeing canonical IPv4 observations' {
            Mock Invoke-GatewayBoundedPublicTextRequest { return '192.0.2.44' }

            Get-GatewayBootstrapClientIpv4 | Should -Be '192.0.2.44'
            Should -Invoke Invoke-GatewayBoundedPublicTextRequest -Times 2 -Exactly
        }

        It 'rejects disagreement before any SQL network authorization exists' {
            $script:observationIndex = 0
            Mock Invoke-GatewayBoundedPublicTextRequest {
                $script:observationIndex++
                if ($script:observationIndex -eq 1) { return '192.0.2.44' }
                return '192.0.2.45'
            }

            { Get-GatewayBootstrapClientIpv4 } | Should -Throw '*did not agree*'
        }

        It 'rejects IPv6 or noncanonical endpoint output' {
            Mock Invoke-GatewayBoundedPublicTextRequest { return '2001:db8::1' }

            { Get-GatewayBootstrapClientIpv4 } | Should -Throw '*canonical IPv4*'
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
        }

        It 'accepts an explicit empty changes array' {
            $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333'

            $result.executed | Should -BeTrue
            $result.applyReady | Should -BeTrue
            $result.changes.Count | Should -Be 0
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                $formatIndex = [Array]::IndexOf([object[]]$Arguments, '--result-format')
                $Arguments -contains '--no-pretty-print' -and
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

            $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333'

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

            $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333'

            $result.applyReady | Should -BeTrue
            $result.changeCounts['Deploy'] | Should -Be 1
        }

        It 'rejects an ambiguous dual-surface changes contract' {
            $script:whatIfResult = [pscustomobject]@{
                status = 'Succeeded'
                error = $null
                changes = @()
                properties = [pscustomobject]@{ changes = @() }
            }

            $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333'

            $result.applyReady | Should -BeFalse
            $result.reason | Should -BeLike '*malformed result contract*'
        }

        It 'rejects failed status or a non-null What-If error' {
            foreach ($malformed in @(
                [pscustomobject]@{ status = 'Failed'; error = $null; changes = @() },
                [pscustomobject]@{ status = 'Succeeded'; error = [pscustomobject]@{ code = 'Suppressed' }; changes = @() }
            )) {
                $script:whatIfResult = $malformed

                $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333'

                $result.applyReady | Should -BeFalse
                $result.reason | Should -BeLike '*malformed result contract*'
            }
        }

        It 'rejects every non-ResourceIdOnly or incomplete change prediction' {
            foreach ($changeType in @('Delete', 'Ignore', 'Modify', 'NoChange', 'NoEffect', 'Unsupported')) {
                $script:whatIfResult = [pscustomobject]@{
                    status = 'Succeeded'
                    error = $null
                    changes = @([pscustomobject]@{
                        changeType = $changeType
                        resourceId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev'
                    })
                }

                (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333').applyReady |
                    Should -BeFalse
            }
        }

        It 'rejects null or shape-less successful output' {
            foreach ($malformed in @(
                $null,
                [pscustomobject]@{},
                [pscustomobject]@{ status = 'Succeeded'; error = $null; properties = [pscustomobject]@{} }
            )) {
                $script:whatIfResult = $malformed

                $result = Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333'

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
            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333').applyReady |
                Should -BeFalse

            $script:whatIfResult.properties.changes = @([pscustomobject]@{
                changeType = 'Create'
                resourceId = '/subscriptions/99999999-9999-4999-8999-999999999999/resourceGroups/rg-other'
            })
            (Invoke-GatewayFoundationWhatIf -Config $script:config -RepositoryRoot '/safe/source' -DeploymentOwnershipId '33333333-3333-4333-8333-333333333333').applyReady |
                Should -BeFalse
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
            }
            $script:imageEvidence = [ordered]@{
                schemaVersion = 2
                registry = 'acrsafe'
                sourceFingerprint = $script:imageSourceFingerprint
                deploymentOwnershipId = $script:imageOwnershipId
                provenance = 'BootstrapPreMutationIntentV2'
                buildIntents = [ordered]@{}
                checkpointedComponents = @('api', 'worker', 'adminUi')
            }
            foreach ($name in @('api', 'worker', 'adminUi')) {
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
                    foreach ($component in @('api', 'worker', 'adminUi')) {
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

        It 'accepts exact succeeded QuickRun evidence for all three az acr build outputs' {
            Test-GatewayImmutableImageEvidence `
                -Evidence $script:imageEvidence `
                -SourceFingerprint $script:imageSourceFingerprint `
                -DeploymentOwnershipId $script:imageOwnershipId |
                Should -BeTrue

            Should -Invoke Invoke-AzJson -Times 3 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'acr' -and
                [string]$Arguments[1] -ceq 'task' -and
                [string]$Arguments[2] -ceq 'show-run'
            }
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
