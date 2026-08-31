#Requires -Version 7.0

Describe 'Recovered bootstrap continuation' {
    BeforeAll {
        $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $scriptPath = Join-Path $repositoryRoot 'operations/continue-bootstrap-after-database-recovery.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }

    It 'parses and exposes the exact review and authorization surface' {
        @($parseErrors) | Should -HaveCount 0
        $parameterNames = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
        $parameterNames | Should -Contain 'Config'
        $parameterNames | Should -Contain 'Yes'
        $parameterNames | Should -Contain 'ExpectedContinuationFingerprint'
        $parameterNames | Should -Contain 'NonInteractive'
        $parameterNames | Should -Contain 'OutputFormat'
        $text | Should -Match "ValidateSet\('Json'\)"
        $text | Should -Match 'ExpectedContinuationFingerprint -cne \$fingerprint'
    }

    It 'self-fingerprints an immutable recovered-state contract and receipt' {
        $text | Should -Match 'Get-FileHash -LiteralPath \$script:continuationToolPath -Algorithm SHA256'
        $text | Should -Match 'continuationFingerprint = Get-BootstrapObjectFingerprint -InputObject \$contract'
        $text | Should -Match 'acceptedContract = ConvertTo-BootstrapCanonicalValue -Value \$boundary.contract'
        $text | Should -Match 'Get-BootstrapObjectFingerprint -InputObject \$Receipt.acceptedContract'
        $text | Should -Match '\.bootstrap/evidence/.*?/continuation/'
        $text | Should -Match 'chmod 600'
    }

    It 'selects the final successful recovery attempt dynamically' {
        $text | Should -Match "databaseRecoveryPlan.status -ceq 'Completed'"
        $text | Should -Match "manualDatabaseRepairPlan.status -ceq 'Completed'"
        $commands | Should -Contain 'Get-BootstrapDatabaseRecoveryAttemptNumber'
        $commands | Should -Contain 'Assert-BootstrapDatabaseRecoveryHistory'
        $commands | Should -Contain 'Resolve-BootstrapDatabaseRecoveryPlanSourceRoot'
        $text | Should -Match 'databaseRecoveryAttemptNumber -eq \$attemptNumber'
        $text | Should -Not -Match '\$attemptNumber\s*=\s*1'
    }

    It 'loads corrected modules then pins deployment inputs to the original snapshot' {
        $importIndex = $text.IndexOf('Import-Module (Join-Path $recoverySourceRoot')
        $setOriginalIndex = $text.IndexOf('Set-BootstrapExecutionSourceRoot -Path $originalSourceRoot')
        $validationIndex = $text.IndexOf('Assert-BootstrapPrerequisites -Install:$false')
        $importIndex | Should -BeGreaterThan -1
        $setOriginalIndex | Should -BeGreaterThan $importIndex
        $validationIndex | Should -BeGreaterThan $setOriginalIndex
        $text | Should -Match 'originalAcceptedPlanRecordFingerprint'
        $text | Should -Match 'originalExecutionSource'
        $text | Should -Match 'recoveryExecutionSource'
    }

    It 'validates completed steps 1-11 with the canonical read-only functions' {
        foreach ($validator in @(
            'Test-GatewayResourceProviderEvidence',
            'Test-GatewaySubscriptionDeploymentEvidence',
            'Test-GatewayApplicationEvidence',
            'Test-GatewayImmutableImageEvidence',
            'Test-GatewayGroupDeploymentEvidence',
            'Test-GatewayBlueprintEvidence',
            'Test-GatewayWorkflowIdentityEvidence',
            'Test-GatewaySqlPrivateEndpointEvidence',
            'Test-GatewayDatabaseEvidence')) {
            $commands | Should -Contain $validator
        }
        $text | Should -Match 'Continuation requires completed and evidenced bootstrap step'
        $text | Should -Match 'Get-BootstrapObjectFingerprint -InputObject \$databaseStep.evidence'
    }

    It 'contains no replay command for steps 3-11 and no Plan or What-If command' {
        foreach ($forbidden in @(
            'Register-BootstrapResourceProviders',
            'Deploy-BootstrapFoundation',
            'Ensure-GatewayApiApplication',
            'Build-GatewayImages',
            'Deploy-SqlPrivateEndpoint',
            'Initialize-GatewayDatabase',
            'Ensure-Agent365SeedBlueprint',
            'Configure-GatewayWorkloadIdentity',
            'Invoke-GatewayFoundationWhatIf',
            'Invoke-GatewayDatabaseRecoveryWhatIf')) {
            $commands | Should -Not -Contain $forbidden
        }
    }

    It 'executes exactly canonical steps 12-19 through the state-step wrapper' {
        $invokedSteps = @([regex]::Matches($text, "Invoke-ContinuationStateStep -Name '([^']+)'", 'CultureInvariant') |
            ForEach-Object { $_.Groups[1].Value })
        $invokedSteps | Should -Be @(
            'Admin UI identity',
            'Admin UI Key Vault credential',
            'Purview policies',
            'Gateway runtime deployment',
            'Admin UI deployment',
            'Admin UI redirect URIs',
            'Network hardening',
            'End-to-end deployment verification'
        )
        $text | Should -Match "Admin UI identity'[\s\S]*?-NoAutomaticReplayAfterStart"
        $text | Should -Match "Admin UI Key Vault credential'[\s\S]*?-NoAutomaticReplayAfterStart"
        $text | Should -Match 'Purview policies''[\s\S]*?-Reconcile[\s\S]*?-NoAutomaticReplayAfterStart:\(\$configuration\.purview\.enabled -eq \$true\)'
        $text | Should -Match "Admin UI deployment'[\s\S]*?-NoAutomaticReplayAfterStart"
        $commands | Should -Contain 'Invoke-BootstrapStateStep'
    }

    It 'persists authorization before Azure activity and checkpoints every step' {
        $runningIndex = $text.IndexOf("`$receipt['status'] = 'Running'")
        $saveAfterRunningIndex = $text.IndexOf('Save-ContinuationReceipt -Receipt $receipt -Path $receiptPath', $runningIndex)
        $connectIndex = $text.IndexOf('Connect-BootstrapAzure -Config $configuration')
        $runningIndex | Should -BeGreaterThan -1
        $saveAfterRunningIndex | Should -BeGreaterThan $runningIndex
        $connectIndex | Should -BeGreaterThan $saveAfterRunningIndex
        $text | Should -Match 'Save-ValidationCheckpoint -Name'
        $text | Should -Match '\$script:continuationReceipt.checkpoints\[\$Name\]'
        $text.Contains("`$receipt['status'] = 'Verified'") | Should -BeTrue
    }

    It 'requires Purview disabled and never reads credential values or secret files' {
        $text | Should -Match "Configuration.purview.enabled -cne 'False'"
        $commands | Should -Not -Contain 'Get-AzKeyVaultSecret'
        $commands | Should -Not -Contain 'az'
        $text | Should -Not -Match '(?i)Get-Content[^\r\n]*\.secrets|list-keys|show-secret|secret\s+show'
    }
}

Describe 'Recovered bootstrap continuation state contract' {
    BeforeAll {
        $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repositoryRoot 'operations/continue-bootstrap-after-database-recovery.ps1')
        $boundedVerifierImplementation = ${function:Assert-BoundedAdminUiVerifierCompatibility}

        function New-TestRecoveredBoundary {
            $originalSource = 'sha256:' + ('1' * 64)
            $correctedSource = 'sha256:' + ('2' * 64)
            $recoveryPlanFingerprint = 'sha256:' + ('3' * 64)
            $configurationFingerprint = 'sha256:' + ('4' * 64)
            $originalPlan = [ordered]@{
                planFingerprint = 'sha256:' + ('5' * 64)
                configurationFingerprint = $configurationFingerprint
                sourceFingerprint = $originalSource
                executionSource = '.bootstrap/accepted-source/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' + ('5' * 64)
            }
            $databaseEvidence = [ordered]@{
                databaseRecoveryPlanFingerprint = $recoveryPlanFingerprint
                databaseRecoveryAttemptNumber = 2
                marker = 'database'
            }
            $recoveryPlan = [ordered]@{
                status = 'Completed'
                attemptNumber = 2
                planFingerprint = $recoveryPlanFingerprint
                originalSourceFingerprint = $originalSource
                correctedSourceFingerprint = $correctedSource
                originalAcceptedPlan = $originalPlan
                executionSource = '.bootstrap/accepted-source/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' + ('3' * 64)
                databaseEvidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $databaseEvidence
            }
            $stepNames = @(
                'Prerequisites', 'Azure authentication', 'Azure provider registration',
                'Azure foundation', 'Gateway API identity', 'Immutable workload images',
                'Inert identity deployment', 'Agent 365 seed blueprint',
                'Workflow v3 Entra configuration', 'SQL private endpoint', 'Gateway database'
            )
            $steps = [ordered]@{}
            foreach ($name in $stepNames) {
                $steps[$name] = [ordered]@{
                    status = 'Completed'
                    sourceFingerprint = if ($name -eq 'Gateway database') { $correctedSource } else { $originalSource }
                    evidence = if ($name -eq 'Gateway database') { $databaseEvidence } else { [ordered]@{ marker = $name } }
                }
            }
            $state = [ordered]@{
                deploymentOwnershipId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                configurationFingerprint = $configurationFingerprint
                acceptedPlan = $originalPlan
                databaseRecoveryPlan = $recoveryPlan
                databaseRecoveryHistory = @([ordered]@{ archiveFingerprint = 'sha256:' + ('6' * 64) })
                steps = $steps
                outputs = [ordered]@{}
            }
            $configuration = [pscustomobject]@{
                subscriptionId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                tenantId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
                resourceGroupName = 'rg-test'
                projectName = 'a365test'
                environment = 'dev'
                purview = [pscustomobject]@{
                    enabled = $false
                    activateGatewayAdapterAfterPolicyReadback = $false
                    policyProvisioningEnabled = $false
                }
            }
            return [ordered]@{ state = $state; configuration = $configuration }
        }

        Mock Assert-BootstrapAcceptedDatabaseRecoveryPlan { }
        Mock Assert-BootstrapDatabaseRecoveryHistory { }
        Mock Resolve-BootstrapDatabaseRecoveryPlanSourceRoot { '/safe/corrected' }
        Mock Resolve-BootstrapAcceptedSourceRoot { '/safe/original' }
        Mock Assert-BoundedAdminUiVerifierCompatibility { 'sha256:' + ('7' * 64) }
        Mock Get-FileHash { [pscustomobject]@{ Hash = ('8' * 64) } }
    }

    It 'binds attempt two and its history without hard-coding attempt one' {
        $testBoundary = New-TestRecoveredBoundary
        $boundary = Get-ContinuationBoundary -Configuration $testBoundary.configuration -State $testBoundary.state
        $boundary.attemptNumber | Should -Be 2
        $boundary.contract.recoveryHistoryFingerprint | Should -Be ('sha256:' + ('6' * 64))
        @($boundary.contract.validatedSteps) | Should -HaveCount 11
        @($boundary.contract.continuationSteps) | Should -HaveCount 8
        $boundary.contract.adminUiVerifierFingerprint | Should -Be ('sha256:' + ('7' * 64))
        $boundary.contract.adminUiRecoveryExperienceFingerprint | Should -Be ('sha256:' + ('8' * 64))
        $boundary.contract.adminUiVerifierCorrection | Should -Be 'AzureResourceIdOrdinalIgnoreCaseV1'
        Should -Invoke Assert-BootstrapDatabaseRecoveryHistory -Times 1 -Exactly
    }

    It 'rejects a non-completed or mismatched recovered database boundary' {
        $testBoundary = New-TestRecoveredBoundary
        $testBoundary.state.steps['Gateway database'].evidence.databaseRecoveryAttemptNumber = 1
        { Get-ContinuationBoundary -Configuration $testBoundary.configuration -State $testBoundary.state } | Should -Throw '*final successful recovery attempt*'
    }

    It 'rejects any enabled Purview continuation' {
        $testBoundary = New-TestRecoveredBoundary
        $testBoundary.configuration.purview.enabled = $true
        { Get-ContinuationBoundary -Configuration $testBoundary.configuration -State $testBoundary.state } | Should -Throw '*requires Purview*disabled*'
    }

    It 'accepts only the one reviewed Admin UI resource-ID casing correction' {
        $legacy = '        [string]$entries[0].identity -cne $ExpectedIdentity -or'
        $corrected = '        -not ([string]$entries[0].identity).Equals($ExpectedIdentity, [StringComparison]::OrdinalIgnoreCase) -or'
        $recoveryPath = Join-Path $TestDrive 'recovery-experience.psm1'
        $currentPath = Join-Path $TestDrive 'current-experience.psm1'
        [IO.File]::WriteAllText($recoveryPath, "before`n$legacy`nafter`n")
        [IO.File]::WriteAllText($currentPath, "before`n$corrected`nafter`n")
        $previousPath = $script:adminUiVerifierModulePath
        try {
            $script:adminUiVerifierModulePath = $currentPath
            & $boundedVerifierImplementation -RecoveryExperiencePath $recoveryPath |
                Should -Match '^sha256:[0-9a-f]{64}$'
            [IO.File]::AppendAllText($currentPath, "unreviewed`n")
            { & $boundedVerifierImplementation -RecoveryExperiencePath $recoveryPath } |
                Should -Throw '*differs*reviewed*correction*'
        }
        finally {
            $script:adminUiVerifierModulePath = $previousPath
        }
    }

    It 'writes the safe continuation receipt with owner-only Unix permissions' {
        $path = Join-Path $TestDrive 'continuation-receipt.json'
        $receipt = [ordered]@{ schemaVersion = 1; marker = 'safe-identifiers-only' }
        Save-ContinuationReceipt -Receipt $receipt -Path $path
        (Get-Content -LiteralPath $path -Raw) | Should -Match 'safe-identifiers-only'
        if (-not $IsWindows) {
            [IO.File]::GetUnixFileMode($path) | Should -Be ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
    }

    It 'revalidates every local continuation checkpoint before trusting Verified' {
        $stepNames = @('Admin UI identity', 'End-to-end deployment verification')
        $verification = [ordered]@{ verified = $true }
        $state = [ordered]@{ steps = [ordered]@{}; outputs = [ordered]@{ verification = $verification } }
        $receipt = [ordered]@{ checkpoints = [ordered]@{}; result = [ordered]@{ verificationFingerprint = Get-BootstrapObjectFingerprint -InputObject $verification } }
        foreach ($name in $stepNames) {
            $evidence = if ($name -eq 'End-to-end deployment verification') { $verification } else { [ordered]@{ marker = $name } }
            $state.steps[$name] = [ordered]@{ status = 'Completed'; evidence = $evidence }
            $receipt.checkpoints[$name] = [ordered]@{ evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $evidence }
        }
        Assert-VerifiedContinuationState -Receipt $receipt -State $state -StepNames $stepNames | Should -BeTrue
        $receipt.checkpoints['Admin UI identity'].evidenceFingerprint = 'sha256:' + ('9' * 64)
        { Assert-VerifiedContinuationState -Receipt $receipt -State $state -StepNames $stepNames } | Should -Throw '*no longer matches*'
    }
}
