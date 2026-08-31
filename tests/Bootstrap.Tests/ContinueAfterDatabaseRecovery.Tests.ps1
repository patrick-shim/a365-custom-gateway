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
        $text | Should -Match 'Import-Module \$currentVerificationPath -Force'
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
        $text | Should -Match "Network hardening'[\s\S]*?-Validate[\s\S]*?Test-ContinuationNetworkHardening"
        $text | Should -Not -Match "Network hardening'\s+-AlwaysRun"
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
        $boundedKeyVaultVerifierImplementation = ${function:Assert-BoundedKeyVaultVerifierCompatibility}
        $boundedPreflightVerifierImplementation = ${function:Assert-BoundedPreflightVerifierCompatibility}

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
        Mock Assert-BoundedKeyVaultVerifierCompatibility { 'sha256:' + ('9' * 64) }
        Mock Assert-BoundedPreflightVerifierCompatibility { 'sha256:' + ('a' * 64) }
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
        $boundary.contract.keyVaultVerifierFingerprint | Should -Be ('sha256:' + ('9' * 64))
        $boundary.contract.keyVaultRecoveryVerifierFingerprint | Should -Be ('sha256:' + ('8' * 64))
        $boundary.contract.keyVaultVerifierCorrection | Should -Be 'DisabledPublicAccessNullNetworkAclsV1'
        $boundary.contract.preflightVerifierFingerprint | Should -Be ('sha256:' + ('a' * 64))
        $boundary.contract.recoveryPreflightVerifierFingerprint | Should -Be ('sha256:' + ('8' * 64))
        $boundary.contract.preflightVerifierCorrection | Should -Be 'OptionalEmptyContainerEnvironmentOmissionV1'
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
        $currentRoot = Join-Path $TestDrive 'current'
        $recoveryRoot = Join-Path $TestDrive 'recovery'
        $currentPath = Join-Path $currentRoot 'bootstrap/modules/Experience.psm1'
        $recoveryPath = Join-Path $recoveryRoot 'bootstrap/modules/Experience.psm1'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $currentPath)) | Out-Null
        [IO.Directory]::CreateDirectory((Split-Path -Parent $recoveryPath)) | Out-Null
        [IO.File]::WriteAllText($recoveryPath, "before`n$legacy`nafter`n")
        [IO.File]::WriteAllText($currentPath, "before`n$corrected`nafter`n")
        Mock Get-RepositoryRoot { $currentRoot }
        Mock Get-BootstrapSourceManifest {
            @([ordered]@{ path = 'bootstrap/modules/Experience.psm1'; sha256 = ('8' * 64) })
        }
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

    It 'accepts only the reviewed Key Vault null-ACL projection correction' {
        $legacyClause = "            [string]`$vault.defaultAction -cne 'Allow' -or [string]`$vault.bypass -cne 'AzureServices' -or"
        $correctedClause = '            -not $vaultNetworkAclsAreExact -or'
        $legacyRootClause = '    $root = Get-BootstrapExecutionSourceRoot'
        $correctedRootClause = "    `$root = [IO.Path]::GetFullPath((Join-Path `$PSScriptRoot '../..'))"
        $reviewedBlockLines = @(
            '        $vaultDefaultAction = [string]$vault.defaultAction',
            '        $vaultBypass = [string]$vault.bypass',
            '        $vaultNetworkAclsAreExact =',
            "            (`$vaultDefaultAction -ceq 'Allow' -and `$vaultBypass -ceq 'AzureServices') -or",
            '            ([string]::IsNullOrEmpty($vaultDefaultAction) -and [string]::IsNullOrEmpty($vaultBypass))'
        )
        $currentRoot = Join-Path $TestDrive 'current-keyvault'
        $recoveryRoot = Join-Path $TestDrive 'recovery-keyvault'
        $currentPath = Join-Path $currentRoot 'bootstrap/modules/Verification.psm1'
        $recoveryPath = Join-Path $recoveryRoot 'bootstrap/modules/Verification.psm1'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $currentPath)) | Out-Null
        [IO.Directory]::CreateDirectory((Split-Path -Parent $recoveryPath)) | Out-Null
        [IO.File]::WriteAllText($recoveryPath, (@('before', $legacyClause, $legacyRootClause, 'after', '') -join "`n"))
        [IO.File]::WriteAllText($currentPath, (@('before') + $reviewedBlockLines + @($correctedClause, $correctedRootClause, 'after', '') -join "`n"))
        $previousPath = $script:keyVaultVerifierModulePath
        try {
            $script:keyVaultVerifierModulePath = $currentPath
            & $boundedKeyVaultVerifierImplementation -RecoveryVerificationPath $recoveryPath |
                Should -Match '^sha256:[0-9a-f]{64}$'
            [IO.File]::AppendAllText($currentPath, "unreviewed`n")
            { & $boundedKeyVaultVerifierImplementation -RecoveryVerificationPath $recoveryPath } |
                Should -Throw '*differs*reviewed*provider-normalized*correction*'
        }
        finally {
            $script:keyVaultVerifierModulePath = $previousPath
        }
    }

    It 'pins the provider-normalized provisioning preflight to one reviewed file hash' {
        $currentRoot = Join-Path $TestDrive 'current-preflight'
        $recoveryRoot = Join-Path $TestDrive 'recovery-preflight'
        $currentPath = Join-Path $currentRoot 'operations/test-provisioning-prerequisites.ps1'
        $recoveryPath = Join-Path $recoveryRoot 'operations/test-provisioning-prerequisites.ps1'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $currentPath)) | Out-Null
        [IO.Directory]::CreateDirectory((Split-Path -Parent $recoveryPath)) | Out-Null
        [IO.File]::WriteAllText($currentPath, "reviewed`n")
        [IO.File]::WriteAllText($recoveryPath, "frozen`n")
        $previousPath = $script:preflightVerifierPath
        $previousFingerprint = $script:reviewedPreflightVerifierFingerprint
        try {
            $script:preflightVerifierPath = $currentPath
            $script:reviewedPreflightVerifierFingerprint = 'sha256:' + ('8' * 64)
            & $boundedPreflightVerifierImplementation -RecoveryPreflightPath $recoveryPath |
                Should -Be ('sha256:' + ('8' * 64))
            $script:reviewedPreflightVerifierFingerprint = 'sha256:' + ('9' * 64)
            { & $boundedPreflightVerifierImplementation -RecoveryPreflightPath $recoveryPath } |
                Should -Throw '*differs*exact reviewed*provider-normalization*'
        }
        finally {
            $script:preflightVerifierPath = $previousPath
            $script:reviewedPreflightVerifierFingerprint = $previousFingerprint
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

    It 'reuses completed network hardening only after exact evidence and live readback' {
        $config = [pscustomobject]@{
            projectName = 'safe'
            environment = 'dev'
            resourceGroupName = 'rg-safe'
        }
        $evidence = [ordered]@{
            sharedKeyVault = 'kv-safe-dev'
            provisioningKeyVault = 'kv-safe-dev-prov'
            publicNetworkAccess = 'Disabled'
            exactPostMutationReadback = $true
        }
        Mock Invoke-AzTsv { 'Disabled' }
        Test-ContinuationNetworkHardening -Config $config -Evidence $evidence | Should -BeTrue
        Should -Invoke Invoke-AzTsv -Times 2 -Exactly

        $evidence.publicNetworkAccess = 'Enabled'
        Test-ContinuationNetworkHardening -Config $config -Evidence $evidence | Should -BeFalse
        $evidence.publicNetworkAccess = 'Disabled'
        Mock Invoke-AzTsv { 'Enabled' }
        Test-ContinuationNetworkHardening -Config $config -Evidence $evidence | Should -BeFalse
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
