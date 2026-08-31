BeforeAll {
    $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:bootstrap = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/bootstrap.ps1') -Raw
    $script:common = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/modules/Common.psm1') -Raw
    $script:database = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/modules/Database.psm1') -Raw
    $script:experience = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/modules/Experience.psm1') -Raw
    $script:verification = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/modules/Verification.psm1') -Raw
    $script:bicep = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/infra/database-migrator-manual-repair-job.bicep') -Raw
    Import-Module (Join-Path $script:repoRoot 'bootstrap/modules/Common.psm1') -Force
}

Describe 'One-shot manual database repair boundary' {
    It 'uses one new deterministic Job without touching any prior Job' {
        $bicep | Should -Match "var jobName = 'job-\$\{projectName\}-db-repair-\$\{environment\}'"
        $bicep | Should -Match "name: 'database-manual-repair'"
        $bicep | Should -Match 'replicaRetryLimit: 0'
        $bicep | Should -Match 'parallelism: 1'
        $bicep | Should -Match 'replicaCompletionCount: 1'
        $bicep | Should -Match "triggerType: 'Manual'"
        $bicep | Should -Not -Match 'job-\$\{projectName\}-db-(init|recover|recov2)'
        $bicep | Should -Not -Match '(?i)\b(delete|update)\b'
        $database | Should -Match "Get-GatewayManualDatabaseRepairContract"
        $database | Should -Match "Start-GatewayDatabaseBootstrapExecution[\s\S]+-ManualRepair"
    }

    It 'retains the existing private environment, ACR pull identity, system identity, and Entra-only SQL boundary' {
        $bicep | Should -Match 'environmentId: containerAppsEnvironmentId'
        $bicep | Should -Match "type: 'SystemAssigned,UserAssigned'"
        $bicep | Should -Match 'identity: imagePullIdentityResourceId'
        $bicep | Should -Match 'secrets: \[\]'
        $bicep | Should -Match "'--required-recovery-mode'[\s\S]+'ResumeAfterSchemaCompleted'"
        $database | Should -Match 'publicNetworkAccess -cne ''Disabled'' -or \$azureAdOnlyAuthentication -cne ''true'''
        $database | Should -Match 'finally \{[\s\S]+Set-GatewaySqlEntraAdministratorExact'
    }

    It 'has no Plan or What-If path and requires direct explicit authorization' {
        $start = $bootstrap.IndexOf("if (`$Mode -eq 'RepairDatabase')", [StringComparison]::Ordinal)
        $end = $bootstrap.IndexOf("if (`$Mode -eq 'RecoverDatabase')", $start + 1, [StringComparison]::Ordinal)
        $branch = $bootstrap.Substring($start, $end - $start)
        $branch | Should -Match 'requires --yes'
        $branch | Should -Match 'has no Plan or What-If mode'
        $branch | Should -Not -Match 'Invoke-GatewayDatabaseRecoveryWhatIf'
        $branch | Should -Not -Match "'deployment', 'group', 'what-if'"
        $branch | Should -Match 'Start-BootstrapManualDatabaseRepairPlan'
        $branch | Should -Match 'Build-GatewayDatabaseRecoveryImage'
        $branch | Should -Match '-ManualRepairPlan \$state.manualDatabaseRepairPlan'
        $branch | Should -Match 'Complete-BootstrapManualDatabaseRepairPlan'
    }

    It 'requires the exact terminal attempt-two Failed manualOnly chain and preserves it' {
        $common | Should -Match 'Get-BootstrapDatabaseRecoveryAttemptNumber -Plan \$State\.databaseRecoveryPlan\) -ne 2'
        $common | Should -Match "databaseRecoveryPlan.status -cne 'Failed'"
        $common | Should -Match 'databaseRecoveryPlan.manualOnly -ne \$true'
        $common | Should -Match 'originalFailedJob'
        $common | Should -Match 'firstFailedRecovery'
        $common | Should -Match 'secondFailedRecovery'
        $common | Should -Match "State.manualDatabaseRepairPlan.status = 'Completed'"
        $common | Should -Not -Match "State.databaseRecoveryPlan.status = 'Completed'[\s\S]{0,500}ManualDatabaseRepair"
    }

    It 'binds completion to exact source image plan execution and all failure boundaries' {
        $common | Should -Match "correctedImage.state -cne 'DigestCheckpointed'"
        $common | Should -Match 'DatabaseEvidence.databaseBootstrapJobImage -cne \[string\]\$plan.correctedImage.image'
        $common | Should -Match 'originalFailedDatabaseBootstrapBoundaryFingerprint'
        $common | Should -Match 'firstFailedDatabaseRecoveryBoundaryFingerprint'
        $common | Should -Match 'secondFailedDatabaseRecoveryBoundaryFingerprint'
        $common | Should -Match "receiptFileName = 'private-database-bootstrap-manual-repair-receipt.json'"
        $database | Should -Match 'Get-GatewayFailedManualDatabaseRepairBoundary'
        $database | Should -Match "executions.Count -ne 1"
    }

    It 'allows canonical resume only through exact completed manual evidence while automatic attempt two stays failed' {
        $bootstrap | Should -Match 'Get-BootstrapCompletedDatabaseValidationPlans'
        $bootstrap | Should -Match '-ManualDatabaseRepairPlan \$manualDatabaseRepairPlan'
        $bootstrap | Should -Match 'run gateway resume'
        $experience | Should -Match '\[System.Collections.IDictionary\]\$ManualDatabaseRepairPlan'
        $experience | Should -Match 'databaseBootstrapJobImage -cne \[string\]\$ManualDatabaseRepairPlan.correctedImage.image'
        $verification | Should -Match '\[System.Collections.IDictionary\]\$ManualDatabaseRepairPlan'
        $verification | Should -Match 'secondFailedDatabaseRecoveryBoundaryFingerprint'
    }

    It 'routes standard Verify and adoption validation through exactly one completed repair mode' {
        $verifyStart = $bootstrap.IndexOf("if (`$Mode -eq 'Verify')", [StringComparison]::Ordinal)
        $verifyEnd = $bootstrap.IndexOf("`n    `$prerequisites =", $verifyStart, [StringComparison]::Ordinal)
        $verifyBranch = $bootstrap.Substring($verifyStart, $verifyEnd - $verifyStart)
        $verifyBranch | Should -Match 'Get-BootstrapCompletedDatabaseValidationPlans'
        $verifyBranch | Should -Match '-DatabaseRecoveryPlan \$verifyDatabaseValidationPlans\.databaseRecoveryPlan'
        $verifyBranch | Should -Match '-ManualDatabaseRepairPlan \$verifyDatabaseValidationPlans\.manualDatabaseRepairPlan'
        $bootstrap | Should -Match '-DatabaseRecoveryPlan \$databaseRecoveryPlan -ManualDatabaseRepairPlan \$manualDatabaseRepairPlan'

        InModuleScope Common {
            $manual = [ordered]@{ status = 'Completed'; planFingerprint = 'sha256:' + ('1' * 64) }
            $state = [ordered]@{
                databaseRecoveryPlan = [ordered]@{ status = 'Failed'; manualOnly = $true }
                manualDatabaseRepairPlan = $manual
            }
            Mock Assert-BootstrapManualDatabaseRepairPrerequisite { $true }

            $plans = Get-BootstrapCompletedDatabaseValidationPlans -State $state
            $plans.databaseRecoveryPlan | Should -BeNullOrEmpty
            $plans.manualDatabaseRepairPlan.planFingerprint | Should -BeExactly $manual.planFingerprint

            $state.manualDatabaseRepairPlan.status = 'Failed'
            { Get-BootstrapCompletedDatabaseValidationPlans -State $state } |
                Should -Throw '*cannot adopt an incomplete database recovery or repair boundary*'
            $state.manualDatabaseRepairPlan.status = 'Completed'
            $state.databaseRecoveryPlan.status = 'Completed'
            { Get-BootstrapCompletedDatabaseValidationPlans -State $state } |
                Should -Throw '*cannot both be completed*'
        }
    }

    It 'excludes singular and plural secret-path variants from fallback source snapshots' {
        InModuleScope Common -Parameters @{ TestRoot = (Join-Path $TestDrive 'source-root') } {
            param($TestRoot)
            $bootstrapRoot = Join-Path $TestRoot 'bootstrap'
            [IO.Directory]::CreateDirectory((Join-Path $bootstrapRoot 'nested/.secrets.dev')) | Out-Null
            [IO.File]::WriteAllText((Join-Path $bootstrapRoot 'safe.ps1'), '# safe test source')
            [IO.File]::WriteAllText((Join-Path $bootstrapRoot '.secret'), 'test-only placeholder')
            [IO.File]::WriteAllText((Join-Path $bootstrapRoot 'nested/.secret.local'), 'test-only placeholder')
            [IO.File]::WriteAllText((Join-Path $bootstrapRoot 'nested/.secrets.dev/value.txt'), 'test-only placeholder')

            foreach ($path in @('.secret', '.secrets', 'bootstrap/nested/.secret.local', 'bootstrap/nested/.secrets.dev/value.txt')) {
                Test-BootstrapSourcePathIsSensitive -RelativePath $path | Should -BeTrue
            }
            Test-BootstrapSourcePathIsSensitive -RelativePath 'bootstrap/safe.ps1' | Should -BeFalse

            $sourceFingerprint = Get-BootstrapSourceFingerprint -Root $TestRoot
            $owner = '11111111-1111-4111-8111-111111111111'
            $planFingerprint = 'sha256:' + ('2' * 64)
            Mock Get-RepositoryRoot { $TestRoot }
            $relative = New-BootstrapAcceptedSourceSnapshot `
                -State ([ordered]@{ deploymentOwnershipId = $owner }) `
                -PlanFingerprint $planFingerprint -SourceFingerprint $sourceFingerprint
            $snapshot = Join-Path $TestRoot $relative
            Test-Path -LiteralPath (Join-Path $snapshot 'bootstrap/safe.ps1') -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $snapshot 'bootstrap/.secret') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $snapshot 'bootstrap/nested/.secret.local') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $snapshot 'bootstrap/nested/.secrets.dev') | Should -BeFalse
        }
    }

    It 'behaviorally accepts only the exact terminal attempt-two Failed manualOnly prerequisite' {
        InModuleScope Common {
            $fp = { param($character) 'sha256:' + ($character * 64) }
            $state = [ordered]@{
                databaseRecoveryPlan = [ordered]@{
                    attemptNumber = 2
                    status = 'Failed'
                    manualOnly = $true
                    planFingerprint = & $fp '1'
                    failedJob = [ordered]@{ boundaryFingerprint = & $fp '2' }
                    priorFailedRecovery = [ordered]@{ boundaryFingerprint = & $fp '3' }
                    failedRecovery = [ordered]@{
                        recoveryPlanFingerprint = & $fp '1'
                        boundaryFingerprint = & $fp '4'
                    }
                }
            }
            Mock Assert-BootstrapDatabaseRecoveryHistory { $true }

            (Assert-BootstrapManualDatabaseRepairPrerequisite -State $state) | Should -BeTrue
            $state.databaseRecoveryPlan.status = 'Running'
            { Assert-BootstrapManualDatabaseRepairPrerequisite -State $state } | Should -Throw '*terminal Failed/manualOnly*'
            $state.databaseRecoveryPlan.status = 'Failed'
            $state.databaseRecoveryPlan.manualOnly = $false
            { Assert-BootstrapManualDatabaseRepairPrerequisite -State $state } | Should -Throw '*terminal Failed/manualOnly*'
            $state.databaseRecoveryPlan.manualOnly = $true
            $state.databaseRecoveryPlan.attemptNumber = 1
            { Assert-BootstrapManualDatabaseRepairPrerequisite -State $state } | Should -Throw '*terminal Failed/manualOnly*'
        }
    }

    It 'behaviorally records one accepted plan and enforces one-shot status transitions' {
        InModuleScope Common {
            $owner = '11111111-1111-4111-8111-111111111111'
            $original = 'sha256:' + ('1' * 64)
            $firstSource = 'sha256:' + ('2' * 64)
            $secondSource = 'sha256:' + ('3' * 64)
            $repairSource = 'sha256:' + ('4' * 64)
            $configuration = 'sha256:' + ('5' * 64)
            $originalBoundary = 'sha256:' + ('6' * 64)
            $firstBoundary = 'sha256:' + ('7' * 64)
            $secondBoundary = 'sha256:' + ('8' * 64)
            $imageIntent = '22222222-2222-4222-8222-222222222222'
            $executionIntent = '33333333-3333-4333-8333-333333333333'
            $recovery = [ordered]@{
                attemptNumber = 2; status = 'Failed'; manualOnly = $true
                planFingerprint = 'sha256:' + ('9' * 64); correctedSourceFingerprint = $secondSource
                previousRecoveryPlan = [ordered]@{ correctedSourceFingerprint = $firstSource }
                failedJob = [ordered]@{ boundaryFingerprint = $originalBoundary }
                priorFailedRecovery = [ordered]@{ boundaryFingerprint = $firstBoundary }
                failedRecovery = [ordered]@{ boundaryFingerprint = $secondBoundary; recoveryPlanFingerprint = 'sha256:' + ('9' * 64) }
            }
            $state = [ordered]@{
                configurationFingerprint = $configuration
                deploymentOwnershipId = $owner
                acceptedPlan = [ordered]@{ sourceFingerprint = $original; bootstrapClientIpv4 = '10.20.30.40' }
                databaseRecoveryPlan = $recovery
            }
            $core = [ordered]@{
                schemaVersion = 1; configurationFingerprint = $configuration; deploymentOwnershipId = $owner
                originalSourceFingerprint = $original; repairSourceFingerprint = $repairSource
                originalAcceptedPlan = $state.acceptedPlan
                exhaustedRecoveryPlanFingerprint = [string]$recovery.planFingerprint
                exhaustedRecoveryPlan = $recovery
                originalFailedJob = [ordered]@{ boundaryFingerprint = $originalBoundary }
                firstFailedRecovery = [ordered]@{ boundaryFingerprint = $firstBoundary }
                secondFailedRecovery = [ordered]@{ boundaryFingerprint = $secondBoundary }
                correctedImage = [ordered]@{ intentId = $imageIntent }
                repairJob = [ordered]@{
                    name = 'job-demo-db-repair-dev'; executionIntentId = $executionIntent; imageIntentId = $imageIntent
                    repairMode = 'ResumeAfterSchemaCompleted'; replicaRetryLimit = 0; maximumExecutions = 1
                }
            }
            $plan = ConvertTo-BootstrapCanonicalValue -Value $core
            $plan['planFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $core
            Mock Assert-BootstrapManualDatabaseRepairPrerequisite { $true }
            Mock Get-BootstrapSourceFingerprint { $repairSource }
            Mock New-BootstrapAcceptedSourceSnapshot { '.bootstrap/accepted-source/11111111-1111-4111-8111-111111111111/snapshot' }
            Mock Save-BootstrapState { }

            $mismatchedPlan = ConvertTo-BootstrapCanonicalValue -Value $plan
            $mismatchedPlan.originalAcceptedPlan.bootstrapClientIpv4 = '10.20.30.41'
            $mismatchedCore = [ordered]@{}
            foreach ($key in $mismatchedPlan.Keys) {
                if ([string]$key -cne 'planFingerprint') { $mismatchedCore[[string]$key] = $mismatchedPlan[$key] }
            }
            $mismatchedPlan.planFingerprint = Get-BootstrapObjectFingerprint -InputObject $mismatchedCore
            { Set-BootstrapAcceptedManualDatabaseRepairPlan -State $state -StatePath '/state.json' -Plan $mismatchedPlan } |
                Should -Throw '*does not preserve the exact original and exhausted recovery boundaries*'

            $accepted = Set-BootstrapAcceptedManualDatabaseRepairPlan -State $state -StatePath '/state.json' -Plan $plan
            $accepted.status | Should -BeExactly 'Accepted'
            $accepted.manualOnly | Should -BeTrue
            { Set-BootstrapAcceptedManualDatabaseRepairPlan -State $state -StatePath '/state.json' -Plan $plan } |
                Should -Throw '*already exists*one-shot*'

            Mock Assert-BootstrapAcceptedManualDatabaseRepairPlan { $true }
            (Start-BootstrapManualDatabaseRepairPlan -State $state -StatePath '/state.json' -PlanFingerprint ([string]$accepted.planFingerprint)).status |
                Should -BeExactly 'Running'
            $failed = [ordered]@{ manualDatabaseRepairPlanFingerprint = [string]$accepted.planFingerprint; boundaryFingerprint = 'sha256:' + ('a' * 64) }
            (Set-BootstrapFailedManualDatabaseRepairPlan -State $state -StatePath '/state.json' -FailedRepair $failed).status |
                Should -BeExactly 'Failed'
            { Start-BootstrapManualDatabaseRepairPlan -State $state -StatePath '/state.json' -PlanFingerprint ([string]$accepted.planFingerprint) } |
                Should -Throw '*not in an executable one-shot state*'
        }
    }

    It 'behaviorally completes without changing Failed/manualOnly recovery and rejects image or boundary mismatch' {
        InModuleScope Common {
            $owner = '11111111-1111-4111-8111-111111111111'
            $planFingerprint = 'sha256:' + ('1' * 64)
            $repairSource = 'sha256:' + ('2' * 64)
            $originalSource = 'sha256:' + ('3' * 64)
            $originalBoundary = 'sha256:' + ('4' * 64)
            $firstBoundary = 'sha256:' + ('5' * 64)
            $secondBoundary = 'sha256:' + ('6' * 64)
            $exhaustedRecovery = 'sha256:' + ('7' * 64)
            $imageIntent = '22222222-2222-4222-8222-222222222222'
            $image = 'acrdemodev.azurecr.io/gateway-db-migrator@sha256:' + ('a' * 64)
            $state = [ordered]@{
                deploymentOwnershipId = $owner
                databaseRecoveryPlan = [ordered]@{ attemptNumber = 2; status = 'Failed'; manualOnly = $true; planFingerprint = $exhaustedRecovery }
                manualDatabaseRepairPlan = [ordered]@{
                    status = 'Running'; planFingerprint = $planFingerprint; originalSourceFingerprint = $originalSource
                    repairSourceFingerprint = $repairSource; startedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                    databaseEvidenceFingerprint = ''; completedAtUtc = ''
                    exhaustedRecoveryPlanFingerprint = $exhaustedRecovery
                    originalFailedJob = [ordered]@{ boundaryFingerprint = $originalBoundary }
                    firstFailedRecovery = [ordered]@{ boundaryFingerprint = $firstBoundary }
                    secondFailedRecovery = [ordered]@{ boundaryFingerprint = $secondBoundary }
                    repairJob = [ordered]@{ imageIntentId = $imageIntent }
                    correctedImage = [ordered]@{
                        state = 'DigestCheckpointed'; component = 'databaseMigratorRecovery'; sourceFingerprint = $repairSource
                        deploymentOwnershipId = $owner; recoveryPlanFingerprint = $planFingerprint; intentId = $imageIntent; image = $image
                    }
                }
                steps = [ordered]@{ 'Gateway database' = [ordered]@{ status = 'Failed' } }
            }
            $evidence = [ordered]@{
                databaseBootstrapJobImage = $image; manualDatabaseRepairPlanFingerprint = $planFingerprint
                exhaustedDatabaseRecoveryPlanFingerprint = $exhaustedRecovery
                acceptedSourceFingerprint = $originalSource; manualDatabaseRepairSourceFingerprint = $repairSource
                originalFailedDatabaseBootstrapBoundaryFingerprint = $originalBoundary
                firstFailedDatabaseRecoveryBoundaryFingerprint = $firstBoundary
                secondFailedDatabaseRecoveryBoundaryFingerprint = $secondBoundary
                deploymentOwnershipId = $owner
            }
            Mock Assert-BootstrapAcceptedManualDatabaseRepairPlan { $true }
            Mock Save-BootstrapState { }

            $completed = Complete-BootstrapManualDatabaseRepairPlan -State $state -StatePath '/state.json' -PlanFingerprint $planFingerprint -DatabaseEvidence $evidence
            $completed.status | Should -BeExactly 'Completed'
            $state.databaseRecoveryPlan.status | Should -BeExactly 'Failed'
            $state.databaseRecoveryPlan.manualOnly | Should -BeTrue
            $state.steps['Gateway database'].completionMode | Should -BeExactly 'ManualDatabaseRepair'

            $state.manualDatabaseRepairPlan.status = 'Running'
            $state.manualDatabaseRepairPlan.correctedImage.image = 'acrdemodev.azurecr.io/gateway-db-migrator@sha256:' + ('b' * 64)
            { Complete-BootstrapManualDatabaseRepairPlan -State $state -StatePath '/state.json' -PlanFingerprint $planFingerprint -DatabaseEvidence $evidence } |
                Should -Throw '*complete accepted failure/source/ownership chain*'
            $state.manualDatabaseRepairPlan.correctedImage.image = $image
            $evidence.secondFailedDatabaseRecoveryBoundaryFingerprint = 'sha256:' + ('c' * 64)
            { Complete-BootstrapManualDatabaseRepairPlan -State $state -StatePath '/state.json' -PlanFingerprint $planFingerprint -DatabaseEvidence $evidence } |
                Should -Throw '*complete accepted failure/source/ownership chain*'
            $evidence.secondFailedDatabaseRecoveryBoundaryFingerprint = $secondBoundary
            $evidence.exhaustedDatabaseRecoveryPlanFingerprint = 'sha256:' + ('d' * 64)
            { Complete-BootstrapManualDatabaseRepairPlan -State $state -StatePath '/state.json' -PlanFingerprint $planFingerprint -DatabaseEvidence $evidence } |
                Should -Throw '*complete accepted failure/source/ownership chain*'
        }
    }
}
