#Requires -Version 7.0

Describe 'Bounded bootstrap API-attestation correction' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Force -DisableNameChecking
        $script:OperationPath = Join-Path $script:RepositoryRoot 'operations/repair-bootstrap-api-attestation.ps1'
        $script:OperationText = Get-Content -LiteralPath $script:OperationPath -Raw
        $script:BashText = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'gateway') -Raw
        $script:CmdText = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'gateway.cmd') -Raw
        . $script:OperationPath -Config ''
    }

    It 'is valid PowerShell and requires explicit authorization before main execution' {
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile($script:OperationPath, [ref]$null, [ref]$parseErrors) | Out-Null
        @($parseErrors) | Should -HaveCount 0
        $script:OperationText | Should -Match 'if \(-not \$Yes\)[\s\S]*?requires --yes'
        $script:OperationText | Should -Match 'if \(\$MyInvocation\.InvocationName -cne ''\.''\)'
    }

    It 'literal-pins both accepted and corrected overlay hashes' {
        foreach ($hash in @(
            'd3cd443c7fff178dee8c7c153f32ec3fb6556f6f4eb408d1bb34dfc2be21559b',
            'ea455f13ddb8db52c2208f49a8b598e81fcdaf01d9f977a89f4afa40fa675541',
            'f0b10e9b3d5786c44cdaa4676641bf9387236cd60f8df863e940dbbb8ad41496',
            '3e188ee8ab2080d5cee0436bb3ebaf85de47f76720ceafd943b46a57748523e1')) {
            ([regex]::Matches($script:OperationText, [regex]::Escape($hash))).Count | Should -Be 1
        }
        $script:OperationText | Should -Match 'Resolve-BootstrapAcceptedSourceRoot -State \$State'
        $script:OperationText | Should -Match 'New-ApiAttestationCorrectionSynthesizedSource'
        $script:OperationText | Should -Match 'New-GatewayAcrBuildContext[\s\S]*?-RepositoryRoot \$synthesizedRoot'
    }

    It 'canonically binds all executable dependencies and rejects module hash drift' {
        $expectedPaths = @(
            'bootstrap/modules/Agent365.psm1',
            'bootstrap/modules/Azure.psm1',
            'bootstrap/modules/Common.psm1',
            'bootstrap/modules/Database.psm1',
            'bootstrap/modules/Entra.psm1',
            'bootstrap/modules/Experience.psm1',
            'bootstrap/modules/Prerequisites.psm1',
            'bootstrap/modules/Purview.psm1',
            'bootstrap/modules/Verification.psm1',
            'operations/test-provisioning-prerequisites.ps1')
        $current = @(Get-ApiAttestationCorrectionExecutionDependencyMetadata)
        $current | Should -HaveCount 10
        @($current.path) -join '|' | Should -BeExactly ($expectedPaths -join '|')

        $dependencyRoot = Join-Path $TestDrive 'dependency-contract'
        $testPaths = @('bootstrap/modules/Example.psm1', 'operations/example.ps1')
        foreach ($relativePath in $testPaths) {
            $path = Join-Path $dependencyRoot $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            "# $relativePath" | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        }
        $accepted = @(Get-ApiAttestationCorrectionExecutionDependencyMetadata `
            -RepositoryRoot $dependencyRoot -RelativePaths $testPaths)
        { $null = Assert-ApiAttestationCorrectionExecutionDependencyContract `
                -Expected $accepted -RepositoryRoot $dependencyRoot -RelativePaths $testPaths } |
            Should -Not -Throw
        '# changed module' | Set-Content -LiteralPath (Join-Path $dependencyRoot $testPaths[0]) -Encoding utf8NoBOM
        { $null = Assert-ApiAttestationCorrectionExecutionDependencyContract `
                -Expected $accepted -RepositoryRoot $dependencyRoot -RelativePaths $testPaths } |
            Should -Throw '*executable dependency contract changed*'
    }

    It 'persists source tool and build intent before the sole gateway-api build' {
        $acceptIndex = $script:OperationText.LastIndexOf("acceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')")
        $resolveIndex = $script:OperationText.LastIndexOf('Resolve-ApiAttestationCorrectionBuild')
        $acceptIndex | Should -BeGreaterThan -1
        $resolveIndex | Should -BeGreaterThan $acceptIndex
        $script:OperationText | Should -Match "repository = 'gateway-api'"
        $script:OperationText | Should -Match "dockerfile = 'src/Gateway.Api/Dockerfile'"
        ([regex]::Matches($script:OperationText, "'acr', 'build'")).Count | Should -Be 1
        $script:OperationText | Should -Not -Match 'gateway-(?:worker|admin|db-migrator):\$tag'
    }

    It 'uses one direct digest-only Container App update and no deployment replay surface' {
        ([regex]::Matches($script:OperationText, "'containerapp', 'update'")).Count | Should -Be 1
        $directUpdate = "'--image', `$TargetImage, '--revision-suffix'"
        $script:OperationText | Should -Match ([regex]::Escape($directUpdate))
        $script:OperationText | Should -Not -Match "'deployment', '(?:group|sub)', '(?:create|what-if)'|Invoke-ArmDeployment|New-AzResourceGroupDeployment"
        $script:OperationText | Should -Not -Match "servicebus[^\r\n]*(?:peek|receive|purge|delete)"
    }

    It 'writes only the canonical final bootstrap state step after receipt verification' {
        ([regex]::Matches($script:OperationText, 'Invoke-BootstrapStateStep')).Count | Should -Be 1
        ([regex]::Matches($script:OperationText, 'Save-BootstrapState')).Count | Should -Be 1
        $script:OperationText | Should -Match "-Name 'End-to-end deployment verification'[\s\S]*?-AlwaysRun"
        $script:OperationText | Should -Match 'Test-GatewayBootstrapDeployment[\s\S]*?-State \$State'
        $script:OperationText | Should -Not -Match '\s-ApiAttestationCorrectionReceipt|\s-ApiAttestationCorrection \$Projection'
        $script:OperationText | Should -Match "outputs\['verification'\]"
        $script:OperationText | Should -Match "outputs\['adminUiUrl'\]"
        $script:OperationText | Should -Match "outputs\['apiUrl'\]"
    }

    It 'exposes the receipt helpers and canonical eight-field projection' {
        foreach ($name in @(
            'Get-BootstrapApiAttestationCorrectionReceiptPath',
            'Read-BootstrapApiAttestationCorrectionReceipt',
            'Get-BootstrapApiAttestationCorrectionReceiptFingerprint',
            'Assert-BootstrapApiAttestationCorrectionReceipt')) {
            Get-Command $name -CommandType Function | Should -Not -BeNullOrEmpty
        }
        $projection = @(
            'receiptFingerprint', 'contractFingerprint', 'baselineApiImage', 'baselineWorkerImage',
            'targetApiImage', 'targetRevisionName', 'synthesizedBuildSourceFingerprint', 'verifiedAtUtc')
        foreach ($field in $projection) {
            $script:OperationText | Should -Match ([regex]::Escape("$field ="))
        }
    }

    It 'keeps the canonical receipt fingerprint independent of its own field' {
        $receipt = [ordered]@{
            schemaVersion = 1
            operation = 'BootstrapApiAttestationCorrection'
            status = 'Verified'
            updatedAtUtc = '2026-08-31T00:00:00.0000000+00:00'
            receiptFingerprint = "sha256:$('1' * 64)"
        }
        $first = Get-BootstrapApiAttestationCorrectionReceiptFingerprint -Receipt $receipt
        $receipt.receiptFingerprint = "sha256:$('2' * 64)"
        Get-BootstrapApiAttestationCorrectionReceiptFingerprint -Receipt $receipt | Should -BeExactly $first
        $receipt.status = 'NeedsAttention'
        Get-BootstrapApiAttestationCorrectionReceiptFingerprint -Receipt $receipt | Should -Not -BeExactly $first
    }

    It 'reads only a bounded JSON receipt and fails closed on malformed JSON' {
        $path = Join-Path $TestDrive 'receipt.json'
        '{"schemaVersion":1,"operation":"BootstrapApiAttestationCorrection"}' |
            Set-Content -LiteralPath $path -Encoding utf8NoBOM
        $read = Read-BootstrapApiAttestationCorrectionReceipt -Path $path
        $read.schemaVersion | Should -Be 1
        '{not-json' | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        { Read-BootstrapApiAttestationCorrectionReceipt -Path $path } | Should -Throw '*malformed*'
    }

    It 'maps both public launchers directly to the correction operation' {
        $script:BashText | Should -Match 'repair-api-attestation'
        $script:BashText | Should -Match 'operations/repair-bootstrap-api-attestation\.ps1'
        $script:BashText | Should -Not -Match 'repair-api-attestation\) mode='
        $script:CmdText | Should -Match 'RepairApiAttestation'
        $script:CmdText | Should -Match 'operations\\repair-bootstrap-api-attestation\.ps1'
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if ($bash) {
            $help = & $bash.Source (Join-Path $script:RepositoryRoot 'gateway') repair-api-attestation --help
            $LASTEXITCODE | Should -Be 0
            $help | Should -Match 'repair-api-attestation.*--yes'
        }
    }

    Context 'resumable exact ACR build recovery' {
        BeforeEach {
            $script:BuildDigest = "sha256:$('1' * 64)"
            $script:BuildRunId = 'run-checkpointed'
            $script:BuildTag = "bootstrap-$('a' * 32)-$('b' * 32)-$('c' * 32)"
            $script:BuildImage = "acrsafedev.azurecr.io/gateway-api@$($script:BuildDigest)"
            $script:BuildReceipt = [ordered]@{
                acceptedContract = [ordered]@{
                    foundation = [ordered]@{ acrName = 'acrsafedev'; acrLoginServer = 'acrsafedev.azurecr.io' }
                }
                build = [ordered]@{
                    repository = 'gateway-api'; dockerfile = 'src/Gateway.Api/Dockerfile'; tag = $script:BuildTag
                    state = 'RunQueued'; runId = $script:BuildRunId; digest = ''; image = ''
                    runCheckpointedAtUtc = '2026-08-31T00:00:00Z'; digestCheckpointedAtUtc = ''
                }
            }
            $script:BuildConfig = [pscustomobject]@{ subscriptionId = '00000000-0000-0000-0000-000000000001' }
            Mock Save-ApiAttestationCorrectionReceipt {}
            Mock Get-GatewayAcrExactImageRuns { @([pscustomobject]@{ runId = $script:BuildRunId }) }
            Mock Get-GatewayAcrExactRunById {
                [pscustomobject]@{
                    status = 'Succeeded'
                    outputImages = @([pscustomobject]@{ digest = $script:BuildDigest })
                }
            }
            Mock Assert-GatewayAcrCompletedBuildContract { $Run }
            Mock Get-GatewayAcrExactTagDigest { [pscustomobject]@{ digest = $script:BuildDigest } }
        }

        It 'never rebinds a RunQueued receipt to a different exact-tag run' {
            Mock Get-GatewayAcrExactImageRuns { @([pscustomobject]@{ runId = 'run-different' }) }
            { Resolve-ApiAttestationCorrectionBuild `
                    -Config $script:BuildConfig -Receipt $script:BuildReceipt `
                    -ReceiptPath (Join-Path $TestDrive 'receipt.json') `
                    -ReceiptCreatedThisInvocation:$false -SourceMetadata ([ordered]@{}) } |
                Should -Throw '*checkpointed ACR run identifier*'
            $script:BuildReceipt.build.runId | Should -BeExactly $script:BuildRunId
            Should -Invoke Save-ApiAttestationCorrectionReceipt -Times 0 -Exactly
            Should -Invoke Get-GatewayAcrExactRunById -Times 0 -Exactly
        }

        It 'requires full exact ACR provenance before a DigestCheckpointed resume can deploy' {
            $script:BuildReceipt.build.state = 'DigestCheckpointed'
            $script:BuildReceipt.build.digest = $script:BuildDigest
            $script:BuildReceipt.build.image = $script:BuildImage
            Mock Get-GatewayAcrExactRunById {
                [pscustomobject]@{
                    status = 'Succeeded'
                    outputImages = @([pscustomobject]@{ digest = "sha256:$('2' * 64)" })
                }
            }
            { Resolve-ApiAttestationCorrectionBuild `
                    -Config $script:BuildConfig -Receipt $script:BuildReceipt `
                    -ReceiptPath (Join-Path $TestDrive 'receipt.json') `
                    -ReceiptCreatedThisInvocation:$false -SourceMetadata ([ordered]@{}) } |
                Should -Throw '*QuickRun output digest*'
            Should -Invoke Get-GatewayAcrExactImageRuns -Times 1 -Exactly
            Should -Invoke Get-GatewayAcrExactRunById -Times 1 -Exactly
        }
    }

    Context 'authoritative live receipt reconciliation' {
        BeforeEach {
            $script:ReceiptDigest = "sha256:$('1' * 64)"
            $script:RunDigest = $script:ReceiptDigest
            $script:TagDigest = $script:ReceiptDigest
            $script:RunId = 'run-123'
            $script:Tag = "bootstrap-$('a' * 32)-$('b' * 32)-$('c' * 32)"
            $script:TargetRevision = 'ca-gateway-api-dev--attest-abcdef123456'
            $script:TargetImage = "acrsafedev.azurecr.io/gateway-api@$($script:ReceiptDigest)"
            $script:WorkerImage = "acrsafedev.azurecr.io/gateway-worker@sha256:$('4' * 64)"
            $script:Queues = @([ordered]@{
                name = 'gateway-provisioning-v3'; active = 0L; scheduled = 0L; deadLetter = 0L; transfer = 0L; transferDeadLetter = 0L
            })
            $script:Snapshot = [ordered]@{
                id = '/safe'; name = 'safe'; image = $script:TargetImage; principalId = 'safe'; fqdn = 'api.example.test'
                latestReadyRevisionName = $script:TargetRevision
                identityFingerprint = "sha256:$('5' * 64)"; tagsFingerprint = "sha256:$('6' * 64)"
                configurationFingerprint = "sha256:$('7' * 64)"
                templateWithoutRevisionAndImageFingerprint = "sha256:$('8' * 64)"
                normalizedEnvelopeFingerprint = "sha256:$('9' * 64)"
                fullEnvelopeFingerprint = "sha256:$('a' * 64)"
                environmentEntryCount = 1; registryCount = 1; secretCount = 0
            }
            $script:WorkerSnapshot = ConvertTo-BootstrapCanonicalValue -Value $script:Snapshot
            $script:WorkerSnapshot.image = $script:WorkerImage
            $script:Receipt = [ordered]@{
                build = [ordered]@{ tag = $script:Tag; runId = $script:RunId; digest = $script:ReceiptDigest; image = $script:TargetImage }
                verification = [ordered]@{ targetRevisionName = $script:TargetRevision }
            }
            $script:Contract = [ordered]@{
                foundation = [ordered]@{ acrName = 'acrsafedev' }
                deployment = [ordered]@{ appName = 'ca-gateway-api-dev' }
            }
            $script:Boundary = [ordered]@{ runtime = [ordered]@{ apiFqdn = 'api.example.test' } }
            $script:Baseline = [ordered]@{
                api = $script:Snapshot
                worker = $script:WorkerSnapshot
                queueCounts = @(ConvertTo-BootstrapCanonicalValue -Value $script:Queues)
                queueCountsFingerprint = Get-BootstrapObjectFingerprint -InputObject $script:Queues
            }

            Mock Get-GatewayAcrExactImageRuns { @([pscustomobject]@{ runId = $script:RunId }) }
            Mock Get-GatewayAcrExactRunById {
                [pscustomobject]@{ outputImages = @([pscustomobject]@{ digest = $script:RunDigest }) }
            }
            Mock Assert-GatewayAcrCompletedBuildContract { $Run }
            Mock Get-GatewayAcrExactTagDigest { [pscustomobject]@{ digest = $script:TagDigest } }
            Mock Get-ApiAttestationCorrectionContainerAppSnapshot {
                if ($Role -ceq 'Api') { return $script:Snapshot }
                return $script:WorkerSnapshot
            }
            Mock Assert-ApiAttestationCorrectionUnchangedSnapshot { $true }
            Mock Get-ApiAttestationCorrectionActiveRevision { [ordered]@{ name = $script:TargetRevision } }
            Mock Get-ApiAttestationCorrectionQueueCounts { $script:Queues }
            Mock Test-ApiAttestationCorrectionHttp {
                [ordered]@{
                    checksStatus = 200; readyStatus = 200; ready = 'Ready'; attestationStatus = 200
                    attestation = 'Attested'; contractVersion = 1
                }
            }
        }

        It 'accepts only the exact ACR run tag digest revision invariants queues and HTTP contract' {
            Assert-ApiAttestationCorrectionLiveReceipt `
                -Config ([pscustomobject]@{}) -Receipt $script:Receipt -Boundary $script:Boundary `
                -Contract $script:Contract -Baseline $script:Baseline |
                Should -BeTrue
            Should -Invoke Get-GatewayAcrExactRunById -Times 1 -Exactly
            Should -Invoke Get-GatewayAcrExactTagDigest -Times 1 -Exactly
            Should -Invoke Get-ApiAttestationCorrectionActiveRevision -Times 1 -Exactly
        }

        It 'rejects a fabricated same-ACR receipt digest that is not the exact QuickRun output' {
            $script:RunDigest = "sha256:$('2' * 64)"
            { Assert-ApiAttestationCorrectionLiveReceipt `
                -Config ([pscustomobject]@{}) -Receipt $script:Receipt -Boundary $script:Boundary `
                -Contract $script:Contract -Baseline $script:Baseline } |
                Should -Throw '*QuickRun output digest*'
        }

        It 'rejects an exact-run digest whose deterministic ACR tag resolves elsewhere' {
            $script:TagDigest = "sha256:$('3' * 64)"
            { Assert-ApiAttestationCorrectionLiveReceipt `
                -Config ([pscustomobject]@{}) -Receipt $script:Receipt -Boundary $script:Boundary `
                -Contract $script:Contract -Baseline $script:Baseline } |
                Should -Throw '*deterministic tag*'
        }

        It 'rejects a different live ready revision even when image and health are otherwise valid' {
            $script:Snapshot.latestReadyRevisionName = 'ca-gateway-api-dev--different'
            { Assert-ApiAttestationCorrectionLiveReceipt `
                -Config ([pscustomobject]@{}) -Receipt $script:Receipt -Boundary $script:Boundary `
                -Contract $script:Contract -Baseline $script:Baseline } |
                Should -Throw '*latest ready revision*'
        }

        It 'allows legitimate count movement while requiring the exact queue topology' {
            $script:Queues[0].active = 3L
            Assert-ApiAttestationCorrectionLiveReceipt `
                -Config ([pscustomobject]@{}) -Receipt $script:Receipt -Boundary $script:Boundary `
                -Contract $script:Contract -Baseline $script:Baseline |
                Should -BeTrue
        }

        It 'rejects a changed queue topology even when every returned count is valid' {
            $script:Queues[0].name = 'different-v3'
            { Assert-ApiAttestationCorrectionLiveReceipt `
                -Config ([pscustomobject]@{}) -Receipt $script:Receipt -Boundary $script:Boundary `
                -Contract $script:Contract -Baseline $script:Baseline } |
                Should -Throw '*queue topology*'
        }
    }
}
