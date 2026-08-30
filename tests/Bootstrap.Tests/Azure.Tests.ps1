$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Force

Describe 'Bootstrap Azure authentication boundary' {
    InModuleScope Azure {
        BeforeEach {
            $script:config = [pscustomobject]@{
                subscriptionId = '11111111-1111-4111-8111-111111111111'
                tenantId = '22222222-2222-4222-8222-222222222222'
            }
            Mock Clear-BootstrapAzureSubscriptionContext
            Mock Set-BootstrapAzureSubscriptionContext
            Mock Invoke-BootstrapCommand
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'account') {
                    return [pscustomobject]@{
                        id = $script:config.subscriptionId
                        tenantId = $script:config.tenantId
                    }
                }
                if ([string]$Arguments[0] -ceq 'rest') {
                    return [pscustomobject]@{
                        id = '33333333-3333-4333-8333-333333333333'
                        userPrincipalName = 'bootstrap.operator@example.invalid'
                        displayName = 'Bootstrap Operator'
                    }
                }
                throw 'Unexpected Azure authentication command family.'
            }
        }

        It 'reads the signed-in user through the bounded subscription-pinned Graph route' {
            $identity = Connect-BootstrapAzure -Config $script:config -NonInteractive

            $identity.subscriptionId | Should -BeExactly $script:config.subscriptionId
            $identity.tenantId | Should -BeExactly $script:config.tenantId
            $identity.userObjectId | Should -BeExactly '33333333-3333-4333-8333-333333333333'
            Should -Invoke Set-BootstrapAzureSubscriptionContext -Times 1 -Exactly -ParameterFilter {
                $SubscriptionId -ceq $script:config.subscriptionId -and
                $TenantId -ceq $script:config.tenantId
            }
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                $Arguments.Count -eq 5 -and
                [string]$Arguments[0] -ceq 'rest' -and
                [string]$Arguments[1] -ceq '--method' -and
                [string]$Arguments[2] -ceq 'GET' -and
                [string]$Arguments[3] -ceq '--url' -and
                [string]$Arguments[4] -ceq 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName,displayName'
            }
            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'ad'
            }
        }
    }
}

Describe 'Allowlisted ACR build context' {
    It 'copies only reviewed runtime source classes and excludes credential-file classes' {
        $projectRoots = @(
            'Gateway.Api', 'Gateway.Application', 'Gateway.Domain', 'Gateway.Contracts',
            'Gateway.Infrastructure', 'Gateway.Agent365', 'Gateway.Purview',
            'Gateway.ContentSafety', 'Gateway.Observability', 'Gateway.Provisioning.Worker',
            'Gateway.AdminUi'
        )
        '10.0.100' | Set-Content -LiteralPath (Join-Path $TestDrive 'global.json')
        '<configuration />' | Set-Content -LiteralPath (Join-Path $TestDrive 'nuget.config')
        foreach ($project in $projectRoots) {
            $directory = Join-Path $TestDrive "src/$project"
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            '<Project />' | Set-Content -LiteralPath (Join-Path $directory "$project.csproj")
            'namespace Safe;' | Set-Content -LiteralPath (Join-Path $directory 'Safe.cs')
        }
        foreach ($project in @('Gateway.Api', 'Gateway.Provisioning.Worker', 'Gateway.AdminUi')) {
            'FROM scratch' | Set-Content -LiteralPath (Join-Path $TestDrive "src/$project/Dockerfile")
        }
        'must-not-leave-machine' | Set-Content -LiteralPath (Join-Path $TestDrive 'src/Gateway.Api/.env')
        'must-not-leave-machine' | Set-Content -LiteralPath (Join-Path $TestDrive 'src/Gateway.Api/operator.pem')
        'must-not-leave-machine' | Set-Content -LiteralPath (Join-Path $TestDrive 'src/Gateway.Api/credentials.json')
        'must-not-leave-machine' | Set-Content -LiteralPath (Join-Path $TestDrive 'src/Gateway.Api/private-settings.json')

        $sourceFingerprint = Get-BootstrapSourceFingerprint -Root $TestDrive
        $context = New-GatewayAcrBuildContext -RepositoryRoot $TestDrive -SourceFingerprint $sourceFingerprint
        try {
            Test-Path -LiteralPath (Join-Path $context 'src/Gateway.Api/Safe.cs') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $context 'src/Gateway.Api/.env') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $context 'src/Gateway.Api/operator.pem') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $context 'src/Gateway.Api/credentials.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $context 'src/Gateway.Api/private-settings.json') | Should -BeFalse
        }
        finally {
            if (Test-Path -LiteralPath $context) { Remove-Item -LiteralPath $context -Recurse -Force }
        }
    }

    It 'rejects inline NuGet package-source credentials without rendering them' {
        $projectRoots = @(
            'Gateway.Api', 'Gateway.Application', 'Gateway.Domain', 'Gateway.Contracts',
            'Gateway.Infrastructure', 'Gateway.Agent365', 'Gateway.Purview',
            'Gateway.ContentSafety', 'Gateway.Observability', 'Gateway.Provisioning.Worker',
            'Gateway.AdminUi'
        )
        '10.0.100' | Set-Content -LiteralPath (Join-Path $TestDrive 'global.json')
        '<configuration><packageSourceCredentials><feed><add key="ClearTextPassword" value="private-marker" /></feed></packageSourceCredentials></configuration>' |
            Set-Content -LiteralPath (Join-Path $TestDrive 'nuget.config')
        foreach ($project in $projectRoots) {
            $directory = Join-Path $TestDrive "src/$project"
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            '<Project />' | Set-Content -LiteralPath (Join-Path $directory "$project.csproj")
        }
        foreach ($project in @('Gateway.Api', 'Gateway.Provisioning.Worker', 'Gateway.AdminUi')) {
            'FROM scratch' | Set-Content -LiteralPath (Join-Path $TestDrive "src/$project/Dockerfile")
        }

        try {
            $sourceFingerprint = Get-BootstrapSourceFingerprint -Root $TestDrive
            New-GatewayAcrBuildContext -RepositoryRoot $TestDrive -SourceFingerprint $sourceFingerprint
            throw 'Expected inline credentials to be rejected.'
        }
        catch {
            $_.Exception.Message | Should -BeLike '*exact credential-free HTTPS source allowlist*'
            $_.Exception.Message | Should -Not -Match 'private-marker'
        }
    }

    It 'rejects NuGet API keys and credential-bearing source URLs without rendering them' {
        foreach ($xml in @(
            '<configuration><apikeys><add key="https://api.nuget.org/v3/index.json" value="private-api-marker" /></apikeys></configuration>',
            '<configuration><packageSources><add key="feed" value="https://private-user:private-pass@api.nuget.org/v3/index.json?token=private-query-marker" /></packageSources></configuration>'
        )) {
            $path = Join-Path $TestDrive "nuget-$([guid]::NewGuid().ToString('N')).config"
            $xml | Set-Content -LiteralPath $path

            try {
                Assert-GatewayCredentialFreeNuGetConfig -Path $path
                throw 'Expected unsafe NuGet configuration to be rejected.'
            }
            catch {
                $_.Exception.Message | Should -BeLike '*exact credential-free HTTPS source allowlist*'
                $_.Exception.Message | Should -Not -Match 'private-(api|user|pass|query)-marker'
            }
        }
    }
}

Describe 'Deterministic resumable ACR image builds' {
    InModuleScope Azure {
        BeforeEach {
            $script:sourceFingerprint = "sha256:$('a' * 64)"
            $script:ownershipId = '33333333-3333-4333-8333-333333333333'
            $script:expectedTag = "bootstrap-33333333333343338333333333333333-$('a' * 64)"
            $script:repositories = [ordered]@{ api = 'gateway-api'; worker = 'gateway-worker'; adminUi = 'gateway-admin' }
            $script:intentIds = [ordered]@{
                api = '44444444-4444-4444-8444-444444444444'
                worker = '55555555-5555-4555-8555-555555555555'
                adminUi = '66666666-6666-4666-8666-666666666666'
            }
            $script:digestByRepository = [ordered]@{
                'gateway-api' = "sha256:$('1' * 64)"
                'gateway-worker' = "sha256:$('2' * 64)"
                'gateway-admin' = "sha256:$('3' * 64)"
            }
            Mock Get-BootstrapExecutionSourceRoot { return $TestDrive }
            Mock Get-BootstrapSourceFingerprint { return $script:sourceFingerprint }
        }

        It 'derives one full source-and-state-bound tag with no time or randomness' {
            $first = Get-BootstrapImageBuildTag -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint
            $second = Get-BootstrapImageBuildTag -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint

            $first | Should -BeExactly $script:expectedTag
            $second | Should -BeExactly $first
            $first.Length | Should -BeLessOrEqual 128
        }

        It 'derives a unique bounded tag from the full source-bound state and a durable intent' {
            $tag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -IntentId $script:intentIds.api

            $tag | Should -BeExactly "bootstrap-33333333333343338333333333333333-$('a' * 32)-44444444444444448444444444444444"
            $tag.Length | Should -BeLessOrEqual 128
        }

        It 'scans a bounded registry-wide projection before the exact tag manifest exists' {
            $tag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -IntentId $script:intentIds.api
            Mock Get-GatewayAcrExactTagDigest { throw 'Run discovery must not require a completed tag manifest.' }
            Mock Invoke-BootstrapCommand {
                return '[{"runId":"run-without-output-metadata","status":"Running","runType":"QuickRun","outputImages":[]}]'
            }

            @(Get-GatewayAcrExactImageRuns -Registry 'acrsafe' -Repository 'gateway-api' -Tag $tag).Count |
                Should -Be 0

            Should -Invoke Get-GatewayAcrExactTagDigest -Times 0 -Exactly
            Should -Invoke Invoke-BootstrapCommand -Times 1 -Exactly -ParameterFilter {
                $FilePath -ceq 'az' -and
                ((@($ArgumentList) -join ' ') -ceq (
                    'acr task list-runs --registry acrsafe --top 101 ' +
                    '--query [].{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}} ' +
                    '--output json --only-show-errors'))
            }
            Should -Invoke Invoke-BootstrapCommand -Times 0 -Exactly -ParameterFilter {
                $ArgumentList -contains '--image'
            }
        }

        It 'selects only the exact tagged QuickRun while ignoring unrelated valid runs' {
            $tag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -IntentId $script:intentIds.api
            $script:acrDiscoveryRunType = 'QuickRun'
            Mock Invoke-BootstrapCommand {
                return (ConvertTo-Json -InputObject @(
                    [ordered]@{
                        runId = 'unrelated-run'; status = 'Running'; runType = 'AutoRun'
                        outputImages = @([ordered]@{ repository = 'other-repository'; tag = 'other-tag'; digest = $null })
                    },
                    [ordered]@{
                        runId = 'run-api'; status = 'Succeeded'; runType = $script:acrDiscoveryRunType
                        outputImages = @([ordered]@{
                            repository = 'gateway-api'; tag = $tag; digest = "sha256:$('1' * 64)"
                        })
                    }
                ) -Depth 10 -Compress)
            }

            $runs = @(Get-GatewayAcrExactImageRuns `
                -Registry 'acrsafe' `
                -Repository 'gateway-api' `
                -Tag $tag)
            $runs.Count | Should -Be 1
            $runs[0].runType | Should -BeExactly 'QuickRun'

            foreach ($unsupportedRunType in @('QuickBuild', 'AutoBuild', 'AutoRun')) {
                $script:acrDiscoveryRunType = $unsupportedRunType
                try {
                    Get-GatewayAcrExactImageRuns `
                        -Registry 'acrsafe' `
                        -Repository 'gateway-api' `
                        -Tag $tag
                    throw 'Expected the non-QuickRun discovery contract to fail closed.'
                }
                catch {
                    $_.Exception.Message | Should -BeExactly 'ACR exact image-run discovery returned a malformed run contract.'
                }
            }
        }

        It 'rejects malformed or duplicate exact-tag discovery without disclosing provider output' {
            $tag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -IntentId $script:intentIds.api
            $exactRun = [ordered]@{
                runId = 'run-api'; status = 'Running'; runType = 'QuickRun'
                outputImages = @([ordered]@{ repository = 'gateway-api'; tag = $tag; digest = $null })
            }
            $script:acrDiscoveryOutput = ''
            Mock Invoke-BootstrapCommand { return $script:acrDiscoveryOutput }
            $cases = @(
                [pscustomobject]@{
                    output = ConvertTo-Json -InputObject @($exactRun, $exactRun) -Depth 10 -Compress
                    expected = 'ACR exact image-run discovery found more than one run for the unique intent tag.'
                },
                [pscustomobject]@{
                    output = '[{"runId":"run-api","status":"Running","runType":"QuickRun","outputImages":{},"providerOutput":"private-provider-body-marker"}]'
                    expected = 'ACR exact image-run discovery returned a malformed run contract.'
                },
                [pscustomobject]@{
                    output = '{"private-provider-body-marker":"private-token-marker"}'
                    expected = 'ACR exact image-run discovery was non-array or exceeded its bounded result contract.'
                }
            )

            foreach ($case in $cases) {
                $script:acrDiscoveryOutput = $case.output
                try {
                    Get-GatewayAcrExactImageRuns -Registry 'acrsafe' -Repository 'gateway-api' -Tag $tag
                    throw 'Expected malformed or duplicate exact-tag discovery to fail closed.'
                }
                catch {
                    $_.Exception.Message | Should -BeExactly $case.expected
                    $_.Exception.Message | Should -Not -Match 'private-(provider-body|token)-marker'
                }
            }
        }

        It 'accepts 100 bounded discovery records and rejects the 101st truncation sentinel' {
            $tag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -IntentId $script:intentIds.api
            $boundedRuns = @(1..100 | ForEach-Object {
                    [ordered]@{
                        runId = "unrelated-run-$_"
                        status = 'Running'
                        runType = 'AutoRun'
                        outputImages = @()
                    }
                })
            $script:acrDiscoveryOutput = ConvertTo-Json -InputObject $boundedRuns -Depth 10 -Compress
            Mock Invoke-BootstrapCommand { return $script:acrDiscoveryOutput }

            @(Get-GatewayAcrExactImageRuns -Registry 'acrsafe' -Repository 'gateway-api' -Tag $tag).Count |
                Should -Be 0

            $sentinelRun = [ordered]@{
                runId = 'sentinel-run-101'
                status = 'Running'
                runType = 'QuickRun'
                outputImages = @()
                providerOutput = 'private-provider-body-marker'
            }
            $script:acrDiscoveryOutput = ConvertTo-Json `
                -InputObject @($boundedRuns + $sentinelRun) `
                -Depth 10 `
                -Compress
            try {
                Get-GatewayAcrExactImageRuns -Registry 'acrsafe' -Repository 'gateway-api' -Tag $tag
                throw 'Expected the 101st discovery record to fail closed as a truncation sentinel.'
            }
            catch {
                $_.Exception.Message | Should -BeExactly 'ACR exact image-run discovery reached its truncation sentinel; absence and uniqueness were not proven.'
                $_.Exception.Message | Should -Not -Match 'private-provider-body-marker'
            }
        }

        It 'reads a durable queued run by its exact run ID without requiring the image tag' {
            $tag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -IntentId $script:intentIds.api
            Mock Get-GatewayAcrExactTagDigest { throw 'Run-ID readback must not require the image tag.' }
            Mock Invoke-BootstrapCommand {
                return '{"runId":"run-api","status":"Running","runType":"QuickRun","outputImages":[]}'
            }

            $run = Get-GatewayAcrExactRunById `
                -Registry 'acrsafe' `
                -Repository 'gateway-api' `
                -Tag $tag `
                -RunId 'run-api'

            $run.status | Should -BeExactly 'Running'
            Should -Invoke Get-GatewayAcrExactTagDigest -Times 0 -Exactly
            Should -Invoke Invoke-BootstrapCommand -Times 1 -Exactly -ParameterFilter {
                $FilePath -ceq 'az' -and
                ((@($ArgumentList) -join ' ') -ceq (
                    'acr task show-run --registry acrsafe --run-id run-api ' +
                    '--query {runId:runId,status:status,runType:runType,outputImages:outputImages} ' +
                    '--output json --only-show-errors'))
            }
        }

        It 'rejects mismatched or malformed exact-run readback without disclosing provider output' {
            $tag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -IntentId $script:intentIds.api
            $script:acrRunReadback = ''
            Mock Invoke-BootstrapCommand { return $script:acrRunReadback }
            $cases = @(
                [pscustomobject]@{
                    output = '{"runId":"different-run","status":"Running","runType":"QuickRun","outputImages":[]}'
                    expected = 'ACR exact run readback returned a different or malformed run.'
                },
                [pscustomobject]@{
                    output = '{"runId":"run-api","status":"Running","runType":"QuickRun","outputImages":[],"private-provider-body-marker":"private-token-marker"}'
                    expected = 'ACR exact run readback returned a different or malformed run.'
                },
                [pscustomobject]@{
                    output = '{"runId":"run-api","status":"Succeeded","runType":"QuickRun","outputImages":[{"repository":"gateway-worker","tag":"private-provider-body-marker","digest":"sha256:' + ('1' * 64) + '"}]}'
                    expected = 'A succeeded ACR run did not report the one exact intended output image.'
                },
                [pscustomobject]@{
                    output = '{"runId":"run-api","status":"Running","runType":"QuickBuild","outputImages":[{"private-provider-body-marker":"private-token-marker"}]}'
                    expected = 'ACR exact run readback returned a malformed run contract.'
                },
                [pscustomobject]@{
                    output = '{"runId":"run-api","status":"Running","runType":"AutoBuild","outputImages":[{"private-provider-body-marker":"private-token-marker"}]}'
                    expected = 'ACR exact run readback returned a malformed run contract.'
                },
                [pscustomobject]@{
                    output = '{"runId":"run-api","status":"Running","runType":"AutoRun","outputImages":[{"private-provider-body-marker":"private-token-marker"}]}'
                    expected = 'ACR exact run readback returned a malformed run contract.'
                },
                [pscustomobject]@{
                    output = '{"private-provider-body-marker":'
                    expected = 'ACR exact run readback returned malformed JSON.'
                }
            )

            foreach ($case in $cases) {
                $script:acrRunReadback = $case.output
                try {
                    Get-GatewayAcrExactRunById `
                        -Registry 'acrsafe' `
                        -Repository 'gateway-api' `
                        -Tag $tag `
                        -RunId 'run-api'
                    throw 'Expected the mismatched ACR run readback to fail closed.'
                }
                catch {
                    $_.Exception.Message | Should -BeExactly $case.expected
                    $_.Exception.Message | Should -Not -Match 'private-(provider-body|token)-marker'
                }
            }
        }

        It 'accepts only one exact successful completed-build QuickRun contract' {
            $tag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -IntentId $script:intentIds.api
            $validRun = [pscustomobject]@{
                runId = 'de1'; status = 'Succeeded'; runType = 'QuickRun'
                outputImages = @([pscustomobject]@{
                    repository = 'gateway-api'; tag = $tag; digest = "sha256:$('1' * 64)"
                })
            }
            (Assert-GatewayAcrCompletedBuildContract -Run $validRun -Repository 'gateway-api' -Tag $tag).runId |
                Should -BeExactly 'de1'

            $invalidRuns = @(
                $null,
                'de1',
                [pscustomobject]@{},
                [pscustomobject]@{
                    runId = 'de1'; status = 'Succeeded'; runType = 'QuickRun'; outputImages = @()
                    providerOutput = 'private-provider-body-marker'
                },
                [pscustomobject]@{
                    runId = 'de1'; status = 'Running'; runType = 'QuickRun'
                    outputImages = $validRun.outputImages
                },
                [pscustomobject]@{
                    runId = 'de1'; status = 'Succeeded'; runType = 'QuickBuild'
                    outputImages = $validRun.outputImages
                },
                [pscustomobject]@{
                    runId = 'bad/run'; status = 'Succeeded'; runType = 'QuickRun'
                    outputImages = $validRun.outputImages
                },
                [pscustomobject]@{
                    runId = 'de1'; status = 'Succeeded'; runType = 'QuickRun'
                    outputImages = @([pscustomobject]@{
                        repository = 'gateway-worker'; tag = 'private-provider-body-marker'; digest = "sha256:$('1' * 64)"
                    })
                }
            )
            foreach ($invalidRun in $invalidRuns) {
                try {
                    Assert-GatewayAcrCompletedBuildContract -Run $invalidRun -Repository 'gateway-api' -Tag $tag
                    throw 'Expected the malformed completed-build contract to fail closed.'
                }
                catch {
                    $_.Exception.Message | Should -BeExactly 'The submitted ACR build did not return one exact successful QuickRun contract.'
                    $_.Exception.Message | Should -Not -Match 'private-provider-body-marker'
                }
            }
        }

        It 'reuses only exact intent tags carrying durable digest checkpoints' {
            Mock Get-GatewayAcrExactTagDigest {
                param([string]$Registry, [string]$Repository, [string]$Tag)
                return [pscustomobject]@{ tag = $Tag; digest = $script:digestByRepository[$Repository] }
            }
            Mock New-GatewayAcrBuildContext { throw 'Build context must not be created for recovered images.' }
            Mock Invoke-BootstrapCommand { throw 'No ACR build mutation was expected.' }
            $recovered = [ordered]@{
                schemaVersion = 2
                registry = 'acrsafe'
                sourceFingerprint = $script:sourceFingerprint
                deploymentOwnershipId = $script:ownershipId
                provenance = 'BootstrapPreMutationIntentV2'
                buildIntents = [ordered]@{}
                checkpointedComponents = @('api', 'worker', 'adminUi')
            }
            foreach ($component in @('api', 'worker', 'adminUi')) {
                $repository = $script:repositories[$component]
                $digest = $script:digestByRepository[$repository]
                $image = "acrsafe.azurecr.io/$repository@$digest"
                $tag = Get-BootstrapImageBuildIntentTag -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint -IntentId $script:intentIds[$component]
                $recovered.buildIntents[$component] = [ordered]@{
                    component = $component; repository = $repository; intentId = $script:intentIds[$component]
                    tag = $tag; state = 'DigestCheckpointed'; runId = "run-$component"; digest = $digest; image = $image
                }
                $recovered[$component] = $image
                $recovered["${component}Digest"] = $digest
            }

            $result = Build-GatewayImages `
                -Config ([pscustomobject]@{}) `
                -AcrLoginServer 'acrsafe.azurecr.io' `
                -SourceFingerprint $script:sourceFingerprint `
                -DeploymentOwnershipId $script:ownershipId `
                -RecoveredEvidence $recovered `
                -Checkpoint { throw 'Recovered images must not be checkpointed again.' }

            $result.schemaVersion | Should -Be 2
            $result.deploymentOwnershipId | Should -BeExactly $script:ownershipId
            $result.api | Should -BeExactly "acrsafe.azurecr.io/gateway-api@$($script:digestByRepository['gateway-api'])"
            Should -Invoke Get-GatewayAcrExactTagDigest -Times 3 -Exactly
            Should -Invoke Invoke-BootstrapCommand -Times 0 -Exactly
        }

        It 'checkpoints every unique intent before building and every digest after reconciliation' {
            $context = Join-Path $TestDrive 'acr-context'
            New-Item -ItemType Directory -Path $context -Force | Out-Null
            $script:submittedRepositories = @()
            $script:buildArguments = @()
            $script:checkpointStates = @()
            Mock New-GatewayAcrBuildContext { return $context }
            Mock Get-GatewayAcrExactTagDigest {
                param([string]$Registry, [string]$Repository, [string]$Tag)
                if ($Repository -in $script:submittedRepositories) {
                    return [pscustomobject]@{ tag = $Tag; digest = $script:digestByRepository[$Repository] }
                }
                return $null
            }
            Mock Get-GatewayAcrExactImageRuns {
                param([string]$Registry, [string]$Repository, [string]$Tag)
                if ($Repository -in $script:submittedRepositories) {
                    return @([pscustomobject]@{
                        runId = "run-$Repository"; status = 'Succeeded'; runType = 'QuickRun'
                        outputImages = @([pscustomobject]@{ repository = $Repository; tag = $Tag; digest = $script:digestByRepository[$Repository] })
                    })
                }
                return @()
            }
            Mock Get-GatewayAcrExactRunById {
                param([string]$Registry, [string]$Repository, [string]$Tag, [string]$RunId)
                $expectedCheckpoint = switch ($Repository) {
                    'gateway-api' { 'api=RunQueued' }
                    'gateway-worker' { 'api=DigestCheckpointed,worker=RunQueued' }
                    'gateway-admin' { 'api=DigestCheckpointed,worker=DigestCheckpointed,adminUi=RunQueued' }
                }
                if ([string]($script:checkpointStates[-1]) -cne $expectedCheckpoint) {
                    throw 'Exact ACR run readback occurred before its durable RunQueued checkpoint.'
                }
                return [pscustomobject]@{
                    runId = $RunId; status = 'Succeeded'; runType = 'QuickRun'
                    outputImages = @([pscustomobject]@{
                        repository = $Repository; tag = $Tag; digest = $script:digestByRepository[$Repository]
                    })
                }
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments, [switch]$CaptureStdoutOnly)
                $script:buildArguments += ,@($Arguments)
                $imageIndex = [Array]::IndexOf($Arguments, '--image')
                $imageParts = $Arguments[$imageIndex + 1].Split(':')
                $script:submittedRepositories += $imageParts[0]
                return [pscustomobject]@{
                    runId = "run-$($imageParts[0])"; status = 'Succeeded'; runType = 'QuickRun'
                    outputImages = @([pscustomobject]@{
                        repository = $imageParts[0]
                        tag = $imageParts[1]
                        digest = $script:digestByRepository[$imageParts[0]]
                    })
                }
            }
            Mock Start-Sleep {}

            $result = Build-GatewayImages `
                -Config ([pscustomobject]@{}) `
                -AcrLoginServer 'acrsafe.azurecr.io' `
                -SourceFingerprint $script:sourceFingerprint `
                -DeploymentOwnershipId $script:ownershipId `
                -Checkpoint {
                    param($evidence)
                    $states = @($evidence.buildIntents.Keys | ForEach-Object { "$_=$($evidence.buildIntents[$_].state)" }) -join ','
                    $script:checkpointStates += $states
                }

            $result.workerDigest | Should -BeExactly $script:digestByRepository['gateway-worker']
            $result.adminUiDigest | Should -BeExactly $script:digestByRepository['gateway-admin']
            Should -Invoke Invoke-AzJson -Times 3 -Exactly -ParameterFilter { $CaptureStdoutOnly }
            $script:buildArguments.Count | Should -Be 3
            $script:checkpointStates | Should -Be @(
                'api=IntentRecorded',
                'api=RunQueued',
                'api=DigestCheckpointed',
                'api=DigestCheckpointed,worker=IntentRecorded',
                'api=DigestCheckpointed,worker=RunQueued',
                'api=DigestCheckpointed,worker=DigestCheckpointed',
                'api=DigestCheckpointed,worker=DigestCheckpointed,adminUi=IntentRecorded',
                'api=DigestCheckpointed,worker=DigestCheckpointed,adminUi=RunQueued',
                'api=DigestCheckpointed,worker=DigestCheckpointed,adminUi=DigestCheckpointed'
            )
            foreach ($arguments in $script:buildArguments) {
                $imageIndex = [Array]::IndexOf($arguments, '--image')
                $arguments[$imageIndex + 1] | Should -Match ':(bootstrap-[0-9a-f]{32}-[0-9a-f]{32}-[0-9a-f]{32})$'
                $fileIndex = [Array]::IndexOf($arguments, '--file')
                $arguments[$fileIndex + 1] | Should -Match '^src/Gateway\.(Api|Provisioning\.Worker|AdminUi)/Dockerfile$'
                $arguments | Should -Contain $context
                $arguments | Should -Contain '--no-logs'
                $arguments | Should -Not -Contain '--no-wait'
                $queryIndex = [Array]::IndexOf($arguments, '--query')
                $queryIndex | Should -BeGreaterOrEqual 0
                $arguments[$queryIndex + 1] | Should -BeExactly '{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}}'
            }
        }

        It 'keeps only IntentRecorded when completed-build stdout is malformed and does not read back or resubmit' {
            $context = Join-Path $TestDrive 'acr-context-malformed-completed-run'
            New-Item -ItemType Directory -Path $context -Force | Out-Null
            $script:malformedCompletedRunCheckpoints = @()
            Mock New-GatewayAcrBuildContext { return $context }
            Mock Get-GatewayAcrExactTagDigest { return $null }
            Mock Get-GatewayAcrExactImageRuns { return @() }
            Mock Invoke-AzJson {
                return [pscustomobject]@{
                    runId = 'run-api'; status = 'Succeeded'; runType = 'QuickBuild'; outputImages = @()
                    providerOutput = 'private-provider-body-marker'
                }
            }
            Mock Get-GatewayAcrExactRunById { throw 'Malformed completed-build output must not reach show-run.' }

            try {
                Build-GatewayImages `
                    -Config ([pscustomobject]@{}) `
                    -AcrLoginServer 'acrsafe.azurecr.io' `
                    -SourceFingerprint $script:sourceFingerprint `
                    -DeploymentOwnershipId $script:ownershipId `
                    -Checkpoint {
                        param($evidence)
                        $script:malformedCompletedRunCheckpoints += [string]$evidence.buildIntents.api.state
                    }
                throw 'Expected malformed completed-build output to fail closed.'
            }
            catch {
                $_.Exception.Message | Should -BeExactly 'The submitted ACR build did not return one exact successful QuickRun contract.'
                $_.Exception.Message | Should -Not -Match 'private-provider-body-marker'
            }

            $script:malformedCompletedRunCheckpoints | Should -Be @('IntentRecorded')
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter { $CaptureStdoutOnly }
            Should -Invoke Get-GatewayAcrExactRunById -Times 0 -Exactly
            Should -Invoke New-GatewayAcrBuildContext -Times 1 -Exactly
        }

        It 'checkpoints the completed scheduling result before rejecting a non-QuickRun exact readback' {
            $context = Join-Path $TestDrive 'acr-context-invalid-show-run'
            New-Item -ItemType Directory -Path $context -Force | Out-Null
            $script:invalidRunReadbackCheckpoints = @()
            Mock New-GatewayAcrBuildContext { return $context }
            Mock Get-GatewayAcrExactTagDigest { return $null }
            Mock Get-GatewayAcrExactImageRuns { return @() }
            Mock Invoke-AzJson {
                param([string[]]$Arguments, [switch]$CaptureStdoutOnly)
                $imageIndex = [Array]::IndexOf($Arguments, '--image')
                $imageParts = $Arguments[$imageIndex + 1].Split(':')
                return [pscustomobject]@{
                    runId = 'run-api'; status = 'Succeeded'; runType = 'QuickRun'
                    outputImages = @([pscustomobject]@{
                        repository = $imageParts[0]; tag = $imageParts[1]; digest = "sha256:$('1' * 64)"
                    })
                }
            }
            Mock Invoke-BootstrapCommand {
                return '{"runId":"run-api","status":"Running","runType":"QuickBuild","outputImages":[{"private-provider-body-marker":"private-token-marker"}]}'
            }

            try {
                Build-GatewayImages `
                    -Config ([pscustomobject]@{}) `
                    -AcrLoginServer 'acrsafe.azurecr.io' `
                    -SourceFingerprint $script:sourceFingerprint `
                    -DeploymentOwnershipId $script:ownershipId `
                    -Checkpoint {
                        param($evidence)
                        $script:invalidRunReadbackCheckpoints += [string]$evidence.buildIntents.api.state
                    }
                throw 'Expected the non-QuickRun exact readback to fail closed.'
            }
            catch {
                $_.Exception.Message | Should -BeExactly 'ACR exact run readback returned a malformed run contract.'
                $_.Exception.Message | Should -Not -Match 'private-(provider-body|token)-marker'
            }

            $script:invalidRunReadbackCheckpoints | Should -Be @('IntentRecorded', 'RunQueued')
            Should -Invoke Invoke-AzJson -Times 1 -Exactly
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter { $CaptureStdoutOnly }
            Should -Invoke Invoke-BootstrapCommand -Times 1 -Exactly -ParameterFilter {
                $FilePath -ceq 'az' -and
                [string]$ArgumentList[0] -ceq 'acr' -and
                [string]$ArgumentList[1] -ceq 'task' -and
                [string]$ArgumentList[2] -ceq 'show-run' -and
                $ArgumentList -contains 'run-api'
            }
            Should -Invoke New-GatewayAcrBuildContext -Times 1 -Exactly
        }

        It 'preserves RunQueued before an unavailable exact readback and never resubmits' {
            $context = Join-Path $TestDrive 'acr-context-unavailable-show-run'
            New-Item -ItemType Directory -Path $context -Force | Out-Null
            $script:unavailableRunCheckpoints = @()
            $script:runQueuedWasDurableBeforeReadback = $false
            Mock New-GatewayAcrBuildContext { return $context }
            Mock Get-GatewayAcrExactTagDigest { return $null }
            Mock Get-GatewayAcrExactImageRuns { return @() }
            Mock Invoke-AzJson {
                param([string[]]$Arguments, [switch]$CaptureStdoutOnly)
                $imageIndex = [Array]::IndexOf($Arguments, '--image')
                $imageParts = $Arguments[$imageIndex + 1].Split(':')
                return [pscustomobject]@{
                    runId = 'run-api'; status = 'Succeeded'; runType = 'QuickRun'
                    outputImages = @([pscustomobject]@{
                        repository = $imageParts[0]; tag = $imageParts[1]; digest = "sha256:$('1' * 64)"
                    })
                }
            }
            Mock Get-GatewayAcrExactRunById {
                $script:runQueuedWasDurableBeforeReadback =
                    ($script:unavailableRunCheckpoints -join ',') -ceq 'IntentRecorded,RunQueued'
                throw 'The exact ACR run readback is temporarily unavailable.'
            }

            { Build-GatewayImages `
                    -Config ([pscustomobject]@{}) `
                    -AcrLoginServer 'acrsafe.azurecr.io' `
                    -SourceFingerprint $script:sourceFingerprint `
                    -DeploymentOwnershipId $script:ownershipId `
                    -Checkpoint {
                        param($evidence)
                        $script:unavailableRunCheckpoints += [string]$evidence.buildIntents.api.state
                    } } |
                Should -Throw '*exact ACR run readback is temporarily unavailable*'

            $script:runQueuedWasDurableBeforeReadback | Should -BeTrue
            $script:unavailableRunCheckpoints | Should -Be @('IntentRecorded', 'RunQueued')
            Should -Invoke Invoke-AzJson -Times 1 -Exactly
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter { $CaptureStdoutOnly }
            Should -Invoke Get-GatewayAcrExactRunById -Times 1 -Exactly -ParameterFilter {
                $Registry -ceq 'acrsafe' -and
                $Repository -ceq 'gateway-api' -and
                $RunId -ceq 'run-api'
            }
            Should -Invoke New-GatewayAcrBuildContext -Times 1 -Exactly
        }

        It 'reconciles a tag created after the pre-mutation intent checkpoint without resubmitting that build' {
            $context = Join-Path $TestDrive 'acr-context-recovery'
            New-Item -ItemType Directory -Path $context -Force | Out-Null
            $apiTag = Get-BootstrapImageBuildIntentTag -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint -IntentId $script:intentIds.api
            $recovered = [ordered]@{
                schemaVersion = 2; registry = 'acrsafe'; sourceFingerprint = $script:sourceFingerprint
                deploymentOwnershipId = $script:ownershipId; provenance = 'BootstrapPreMutationIntentV2'
                buildIntents = [ordered]@{
                    api = [ordered]@{ component = 'api'; repository = 'gateway-api'; intentId = $script:intentIds.api; tag = $apiTag; state = 'IntentRecorded' }
                }
                checkpointedComponents = @()
            }
            $script:submittedRepositories = @('gateway-api')
            Mock New-GatewayAcrBuildContext { return $context }
            Mock Get-GatewayAcrExactTagDigest {
                param([string]$Registry, [string]$Repository, [string]$Tag)
                if ($Repository -in $script:submittedRepositories) {
                    return [pscustomobject]@{ tag = $Tag; digest = $script:digestByRepository[$Repository] }
                }
                return $null
            }
            Mock Get-GatewayAcrExactImageRuns {
                param([string]$Registry, [string]$Repository, [string]$Tag)
                if ($Repository -in $script:submittedRepositories) {
                    return @([pscustomobject]@{
                        runId = "run-$Repository"; status = 'Succeeded'; runType = 'QuickRun'
                        outputImages = @([pscustomobject]@{ repository = $Repository; tag = $Tag; digest = $script:digestByRepository[$Repository] })
                    })
                }
                return @()
            }
            Mock Get-GatewayAcrExactRunById {
                param([string]$Registry, [string]$Repository, [string]$Tag, [string]$RunId)
                return [pscustomobject]@{
                    runId = $RunId; status = 'Succeeded'; runType = 'QuickRun'
                    outputImages = @([pscustomobject]@{
                        repository = $Repository; tag = $Tag; digest = $script:digestByRepository[$Repository]
                    })
                }
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments, [switch]$CaptureStdoutOnly)
                $imageIndex = [Array]::IndexOf($Arguments, '--image')
                $imageParts = $Arguments[$imageIndex + 1].Split(':')
                $script:submittedRepositories += $imageParts[0]
                return [pscustomobject]@{
                    runId = "run-$($imageParts[0])"; status = 'Succeeded'; runType = 'QuickRun'
                    outputImages = @([pscustomobject]@{
                        repository = $imageParts[0]
                        tag = $imageParts[1]
                        digest = $script:digestByRepository[$imageParts[0]]
                    })
                }
            }
            Mock Start-Sleep {}

            $result = Build-GatewayImages -Config ([pscustomobject]@{}) -AcrLoginServer 'acrsafe.azurecr.io' `
                -SourceFingerprint $script:sourceFingerprint -DeploymentOwnershipId $script:ownershipId `
                -RecoveredEvidence $recovered -Checkpoint { param($evidence) }

            $result.apiDigest | Should -BeExactly $script:digestByRepository['gateway-api']
            Should -Invoke Invoke-AzJson -Times 2 -Exactly
            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter {
                $imageIndex = [Array]::IndexOf($Arguments, '--image')
                $Arguments[$imageIndex + 1] -like 'gateway-api:*'
            }
        }

        It 'polls a recovered RunQueued checkpoint by durable run ID and never resubmits a terminal failure' {
            $apiTag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -IntentId $script:intentIds.api
            $recovered = [ordered]@{
                schemaVersion = 2; registry = 'acrsafe'; sourceFingerprint = $script:sourceFingerprint
                deploymentOwnershipId = $script:ownershipId; provenance = 'BootstrapPreMutationIntentV2'
                buildIntents = [ordered]@{
                    api = [ordered]@{
                        component = 'api'; repository = 'gateway-api'; intentId = $script:intentIds.api
                        tag = $apiTag; state = 'RunQueued'; runId = 'durable-run-api'
                    }
                }
                checkpointedComponents = @()
            }
            Mock Get-GatewayAcrExactImageRuns { throw 'RunQueued recovery must not rediscover by image tag.' }
            Mock Get-GatewayAcrExactTagDigest { throw 'A failed queued run must not be treated as a completed image.' }
            Mock Get-GatewayAcrExactRunById {
                return [pscustomobject]@{
                    runId = 'durable-run-api'; status = 'Failed'; runType = 'QuickRun'; outputImages = @()
                }
            }
            Mock Invoke-AzJson { throw 'A terminal run must never be resubmitted.' }
            Mock New-GatewayAcrBuildContext { throw 'A terminal run must not create a new build context.' }

            { Build-GatewayImages `
                    -Config ([pscustomobject]@{}) `
                    -AcrLoginServer 'acrsafe.azurecr.io' `
                    -SourceFingerprint $script:sourceFingerprint `
                    -DeploymentOwnershipId $script:ownershipId `
                    -RecoveredEvidence $recovered `
                    -Checkpoint {} } |
                Should -Throw '*exact ACR build reached a terminal failure*'

            Should -Invoke Get-GatewayAcrExactRunById -Times 1 -Exactly -ParameterFilter {
                $Registry -ceq 'acrsafe' -and
                $Repository -ceq 'gateway-api' -and
                $Tag -ceq $apiTag -and
                $RunId -ceq 'durable-run-api'
            }
            Should -Invoke Get-GatewayAcrExactImageRuns -Times 0 -Exactly
            Should -Invoke Invoke-AzJson -Times 0 -Exactly
            Should -Invoke New-GatewayAcrBuildContext -Times 0 -Exactly
        }

        It 'refuses to resubmit a recovered intent when neither the run nor its outcome can be proven' {
            $apiTag = Get-BootstrapImageBuildIntentTag -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint -IntentId $script:intentIds.api
            $recovered = [ordered]@{
                schemaVersion = 2; registry = 'acrsafe'; sourceFingerprint = $script:sourceFingerprint
                deploymentOwnershipId = $script:ownershipId; provenance = 'BootstrapPreMutationIntentV2'
                buildIntents = [ordered]@{
                    api = [ordered]@{ component = 'api'; repository = 'gateway-api'; intentId = $script:intentIds.api; tag = $apiTag; state = 'IntentRecorded' }
                }
                checkpointedComponents = @()
            }
            Mock Get-GatewayAcrExactImageRuns { return @() }
            Mock Get-GatewayAcrExactTagDigest { return $null }
            Mock Invoke-AzJson { throw 'A duplicate build must not be submitted.' }
            Mock Start-Sleep {}

            { Build-GatewayImages -Config ([pscustomobject]@{}) -AcrLoginServer 'acrsafe.azurecr.io' `
                -SourceFingerprint $script:sourceFingerprint -DeploymentOwnershipId $script:ownershipId `
                -RecoveredEvidence $recovered -Checkpoint {} } |
                Should -Throw '*Submission outcome is ambiguous*'
            Should -Invoke Invoke-AzJson -Times 0 -Exactly
        }

        It 'rejects a collision before persisting a fresh build intent or submitting a build' {
            Mock Get-GatewayAcrExactTagDigest {
                param([string]$Registry, [string]$Repository, [string]$Tag)
                return [pscustomobject]@{ tag = $Tag; digest = $script:digestByRepository[$Repository] }
            }
            Mock Get-GatewayAcrExactImageRuns { return @() }
            Mock Invoke-AzJson { throw 'No build was authorized.' }

            { Build-GatewayImages `
                -Config ([pscustomobject]@{}) `
                -AcrLoginServer 'acrsafe.azurecr.io' `
                -SourceFingerprint $script:sourceFingerprint `
                -DeploymentOwnershipId $script:ownershipId `
                -Checkpoint {} } |
                Should -Throw '*freshly generated image-build intent tag already exists*'
            Should -Invoke Invoke-AzJson -Times 0 -Exactly
        }

        It 'rejects a non-array ACR discovery result before treating a tag as absent' {
            Mock Invoke-BootstrapCommand { return '{"value":"gateway-api"}' }

            { Invoke-GatewayAcrExactStringArray `
                -OperationLabel 'ACR repository discovery' `
                -Arguments @('acr', 'repository', 'list') `
                -ExpectedValue 'gateway-api' } |
                Should -Throw '*malformed or non-exact*'
        }
    }
}

Describe 'Gateway core initial and runtime identity bindings' {
    InModuleScope Azure {
        BeforeEach {
            $script:coreSourceFingerprint = "sha256:$('b' * 64)"
            $script:coreOwnershipId = '77777777-7777-4777-8777-777777777777'
            $script:coreWorkerPrincipalId = '88888888-8888-4888-8888-888888888888'
            $script:wrongCoreWorkerPrincipalId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            $script:coreManagerApplicationId = '99999999-9999-4999-8999-999999999999'
            $script:coreConfig = [pscustomobject]@{
                subscriptionId = '10101010-1010-4010-8010-101010101010'
                environment = 'dev'
                location = 'koreacentral'
                projectName = 'safe'
                resourceGroupName = 'rg-safe-dev'
                tenantId = '11111111-1111-4111-8111-111111111111'
                alertEmail = ''
                agent365 = [pscustomobject]@{
                    reviewedManagerApplicationIds = @($script:coreManagerApplicationId)
                    allowDevelopmentRegistryPreview = $false
                }
                promptShield = [pscustomobject]@{ enabled = $false; skuName = 'S0' }
                purview = [pscustomobject]@{
                    policyProvisioningEnabled = $false
                    policyProvisioningOrganization = ''
                    policyProvisioningApplicationId = ''
                    policyProvisioningCertificateSecretUri = ''
                    sensitiveInformationType = ''
                }
                sql = [pscustomobject]@{ skuName = 'Basic'; skuTier = 'Basic' }
            }
            $script:coreFoundation = [pscustomobject]@{
                deploymentOwnershipId = $script:coreOwnershipId
                sourceFingerprint = $script:coreSourceFingerprint
                resourceGroupName = 'rg-safe-dev'
                containerAppsEnvironmentName = 'cae-safe-dev-vnet'
                containerAppsEnvironmentId = '/subscriptions/10101010-1010-4010-8010-101010101010/resourceGroups/rg-safe-dev/providers/Microsoft.App/managedEnvironments/cae-safe-dev-vnet'
                virtualNetworkName = 'vnet-safe-dev'
                privateEndpointSubnetName = 'snet-private-endpoints'
                acrName = 'acrsafedevabc123'
                acrLoginServer = 'acrsafedevabc123.azurecr.io'
                runtimeImagePullIdentityId = '/subscriptions/10101010-1010-4010-8010-101010101010/resourceGroups/rg-safe-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-runtime-pull-dev'
                runtimeImagePullIdentityPrincipalId = 'abababab-abab-4bab-8bab-abababababab'
                runtimeImagePullAcrPullRoleAssignmentId = '/subscriptions/10101010-1010-4010-8010-101010101010/resourceGroups/rg-safe-dev/providers/Microsoft.ContainerRegistry/registries/acrsafedevabc123/providers/Microsoft.Authorization/roleAssignments/cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd'
            }
            $script:coreIdentity = [pscustomobject]@{
                gatewayApiClientId = '22222222-2222-4222-8222-222222222222'
                gatewayApiScopeBaseUri = 'api://a365-gateway-safe-dev'
                gatewayApiTokenAudience = '22222222-2222-4222-8222-222222222222'
                userObjectId = '33333333-3333-4333-8333-333333333333'
                userPrincipalName = 'operator@example.invalid'
            }
            $script:coreDatabase = [pscustomobject]@{
                deploymentOwnershipId = $script:coreOwnershipId
                acceptedSourceFingerprint = $script:coreSourceFingerprint
                server = 'sql-safe-dev.database.windows.net'
                database = 'GatewayDb'
                schemaFingerprint = "sha256:$('c' * 64)"
                apiPrincipalName = 'ca-gateway-api-dev'
                apiPrincipalClientId = '44444444-4444-4444-8444-444444444444'
                workerPrincipalName = 'ca-gateway-worker-dev-v3'
                workerPrincipalClientId = '55555555-5555-4555-8555-555555555555'
                workerPrincipalObjectId = $script:coreWorkerPrincipalId
            }
            $script:coreApiImage = "acrsafe.azurecr.io/gateway-api@sha256:$('1' * 64)"
            $script:coreWorkerImage = "acrsafe.azurecr.io/gateway-worker@sha256:$('2' * 64)"
            $script:coreInitialArguments = @{
                Config = $script:coreConfig
                Foundation = $script:coreFoundation
                Identity = $script:coreIdentity
                ApiImage = $script:coreApiImage
                WorkerImage = $script:coreWorkerImage
                WorkerPrincipalId = ''
                ManagerApplicationIds = @()
                DeploymentOwnershipId = $script:coreOwnershipId
                SourceFingerprint = $script:coreSourceFingerprint
                Initial = $true
            }
            $script:newPartialWorkerApp = {
                $userAssigned = [ordered]@{}
                $userAssigned[[string]$script:coreFoundation.runtimeImagePullIdentityId] = [ordered]@{
                    principalId = [string]$script:coreFoundation.runtimeImagePullIdentityPrincipalId
                    clientId = 'dededede-dede-4ede-8ede-dededededede'
                }
                return [pscustomobject]@{
                    id = "/subscriptions/$($script:coreConfig.subscriptionId)/resourceGroups/$($script:coreConfig.resourceGroupName)/providers/Microsoft.App/containerApps/ca-gateway-worker-dev-v3"
                    name = 'ca-gateway-worker-dev-v3'
                    type = 'Microsoft.App/containerApps'
                    location = 'koreacentral'
                    tags = [ordered]@{
                        project = 'a365-gateway'
                        environment = 'dev'
                        managedBy = 'bicep'
                        projectName = 'safe'
                        deploymentId = 'safe-dev'
                        bootstrapOwnershipId = $script:coreOwnershipId
                        bootstrapSourceFingerprint = $script:coreSourceFingerprint
                    }
                    identity = [ordered]@{
                        type = 'SystemAssigned, UserAssigned'
                        principalId = 'efefefef-efef-4fef-8fef-efefefefefef'
                        tenantId = [string]$script:coreConfig.tenantId
                        userAssignedIdentities = $userAssigned
                    }
                    properties = [ordered]@{
                        provisioningState = 'Failed'
                        managedEnvironmentId = [string]$script:coreFoundation.containerAppsEnvironmentId
                        configuration = [ordered]@{
                            activeRevisionsMode = 'Single'
                            secretCount = 0
                            registries = @([ordered]@{
                                server = [string]$script:coreFoundation.acrLoginServer
                                identity = [string]$script:coreFoundation.runtimeImagePullIdentityId
                            })
                            ingress = $null
                        }
                        template = [ordered]@{
                            containers = @([ordered]@{
                                name = 'ca-gateway-worker-dev-v3'
                                image = $script:coreWorkerImage
                                resources = [ordered]@{ cpu = 0.25; memory = '0.5Gi' }
                                env = @([ordered]@{ name = 'DOTNET_ENVIRONMENT'; value = 'Production' })
                            })
                            volumes = @()
                            scale = [ordered]@{ minReplicas = 0; maxReplicas = 3; rules = @() }
                        }
                    }
                }
            }
            $script:newCompleteApiApp = {
                $app = & $script:newPartialWorkerApp
                $app.id = "/subscriptions/$($script:coreConfig.subscriptionId)/resourceGroups/$($script:coreConfig.resourceGroupName)/providers/Microsoft.App/containerApps/ca-gateway-api-dev"
                $app.name = 'ca-gateway-api-dev'
                $app.properties.provisioningState = 'Succeeded'
                $app.properties.configuration.ingress = [ordered]@{
                    external = $true
                    allowInsecure = $false
                    targetPort = 8080
                    transport = 'auto'
                    fqdn = 'ca-gateway-api-dev.safe.azurecontainerapps.io'
                    customDomains = @()
                    ipSecurityRestrictions = @()
                }
                $app.properties.template.containers[0].name = 'ca-gateway-api-dev'
                $app.properties.template.containers[0].image = $script:coreApiImage
                $app.properties.template.containers[0].resources = [ordered]@{ cpu = 0.5; memory = '1Gi' }
                $app.properties.template.containers[0].env = @([ordered]@{ name = 'ASPNETCORE_ENVIRONMENT'; value = 'Production' })
                $app.properties.template.scale = [ordered]@{ minReplicas = 1; maxReplicas = 3; rules = @() }
                return $app
            }
            $script:newTerminalCoreDeployment = {
                param([string]$State, [string]$CorrelationId = '12121212-1212-4212-8212-121212121212')
                return [pscustomobject]@{
                    properties = [pscustomobject]@{
                        provisioningState = $State
                        mode = 'Incremental'
                        correlationId = $CorrelationId
                        timestamp = '2026-08-30T01:02:03.0000000+00:00'
                        parameters = [pscustomobject]@{}
                        outputs = [pscustomobject]@{}
                    }
                }
            }
            Mock Get-BootstrapExecutionSourceRoot { return $TestDrive }
            Mock Get-BootstrapSourceFingerprint { return $script:coreSourceFingerprint }
            Mock Invoke-AzTsv { return '0' }
            Mock Invoke-AzJson { throw 'Unexpected Azure JSON read.' }
            Mock Invoke-BootstrapCommand { throw 'Unexpected native Azure command.' }
            Mock Invoke-ArmDeploymentWithSecureParameters { throw 'core-deployment-reached' }
        }

        It 'accepts exact succeeded Container App location form <Location>' -ForEach @(
            @{ Location = 'koreacentral' },
            @{ Location = 'Korea Central' }
        ) {
            $app = & $script:newPartialWorkerApp
            $app.location = $Location
            $app.properties.provisioningState = 'Succeeded'
            $app.properties.configuration.Remove('secretCount')
            $app.properties.configuration['secrets'] = @()

            Assert-GatewaySucceededContainerAppBoundary -App $app -Role Worker `
                -Config $script:coreConfig -Foundation $script:coreFoundation `
                -ExpectedImage $script:coreWorkerImage -ExpectedPrincipalId ([string]$app.identity.principalId) `
                -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint |
                Should -BeTrue
        }

        It 'accepts the Azure display-name location on a partial Container App boundary' {
            $app = & $script:newPartialWorkerApp
            $app.location = 'Korea Central'

            Assert-GatewayExactPartialContainerAppEnvelope -App $app -Role Worker `
                -Config $script:coreConfig -Foundation $script:coreFoundation `
                -ExpectedImage $script:coreWorkerImage -DeploymentOwnershipId $script:coreOwnershipId `
                -SourceFingerprint $script:coreSourceFingerprint `
                -ExpectedEnvironment ([ordered]@{ DOTNET_ENVIRONMENT = 'Production' }) |
                Should -BeTrue
        }

        It 'accepts exact zero succeeded Container App secrets in <SecretShape> form' -ForEach @(
            @{ SecretShape = 'null' },
            @{ SecretShape = 'empty-array' }
        ) {
            $app = & $script:newPartialWorkerApp
            $app.properties.provisioningState = 'Succeeded'
            $app.properties.configuration.Remove('secretCount')
            $app.properties.configuration['secrets'] = if ($SecretShape -ceq 'null') { $null } else { @() }

            Assert-GatewaySucceededContainerAppBoundary -App $app -Role Worker `
                -Config $script:coreConfig -Foundation $script:coreFoundation `
                -ExpectedImage $script:coreWorkerImage -ExpectedPrincipalId ([string]$app.identity.principalId) `
                -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint |
                Should -BeTrue
        }

        It 'rejects one succeeded Container App secret without reading its value' {
            $app = & $script:newPartialWorkerApp
            $app.properties.provisioningState = 'Succeeded'
            $app.properties.configuration.Remove('secretCount')
            $app.properties.configuration['secrets'] = @([ordered]@{ name = 'unreviewed-secret' })

            { Assert-GatewaySucceededContainerAppBoundary -App $app -Role Worker `
                    -Config $script:coreConfig -Foundation $script:coreFoundation `
                    -ExpectedImage $script:coreWorkerImage -ExpectedPrincipalId ([string]$app.identity.principalId) `
                    -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint } |
                Should -Throw '*outside the exact image, identity, environment, and secret-free boundary*'
        }

        It 'accepts Azure provider casing for the exact API ingress transport enum' {
            $succeededApp = & $script:newCompleteApiApp
            $succeededApp.properties.configuration.ingress.transport = 'Auto'
            $succeededApp.properties.configuration.Remove('secretCount')
            $succeededApp.properties.configuration['secrets'] = @()

            Assert-GatewaySucceededContainerAppBoundary -App $succeededApp -Role Api `
                -Config $script:coreConfig -Foundation $script:coreFoundation `
                -ExpectedImage $script:coreApiImage -ExpectedPrincipalId ([string]$succeededApp.identity.principalId) `
                -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint |
                Should -BeTrue

            $partialApp = & $script:newCompleteApiApp
            $partialApp.properties.configuration.ingress.transport = 'Auto'
            Assert-GatewayExactPartialContainerAppEnvelope -App $partialApp -Role Api `
                -Config $script:coreConfig -Foundation $script:coreFoundation `
                -ExpectedImage $script:coreApiImage -DeploymentOwnershipId $script:coreOwnershipId `
                -SourceFingerprint $script:coreSourceFingerprint `
                -ExpectedEnvironment ([ordered]@{
                    ASPNETCORE_ENVIRONMENT = 'Production'
                    __recoveryApiFqdn = 'ca-gateway-api-dev.safe.azurecontainerapps.io'
                }) | Should -BeTrue
        }

        It 'rejects a different API ingress transport enum on both recovery boundaries' {
            $succeededApp = & $script:newCompleteApiApp
            $succeededApp.properties.configuration.ingress.transport = 'tcp'
            $succeededApp.properties.configuration.Remove('secretCount')
            $succeededApp.properties.configuration['secrets'] = @()
            { Assert-GatewaySucceededContainerAppBoundary -App $succeededApp -Role Api `
                    -Config $script:coreConfig -Foundation $script:coreFoundation `
                    -ExpectedImage $script:coreApiImage -ExpectedPrincipalId ([string]$succeededApp.identity.principalId) `
                    -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint } |
                Should -Throw '*external HTTPS-only ingress boundary*'

            $partialApp = & $script:newCompleteApiApp
            $partialApp.properties.configuration.ingress.transport = 'tcp'
            { Assert-GatewayExactPartialContainerAppEnvelope -App $partialApp -Role Api `
                    -Config $script:coreConfig -Foundation $script:coreFoundation `
                    -ExpectedImage $script:coreApiImage -DeploymentOwnershipId $script:coreOwnershipId `
                    -SourceFingerprint $script:coreSourceFingerprint `
                    -ExpectedEnvironment ([ordered]@{
                        ASPNETCORE_ENVIRONMENT = 'Production'
                        __recoveryApiFqdn = 'ca-gateway-api-dev.safe.azurecontainerapps.io'
                    }) } | Should -Throw '*external HTTPS-only contract*'
        }

        It 'rejects a different Azure region on the succeeded Container App boundary' {
            $app = & $script:newPartialWorkerApp
            $app.location = 'Japan East'
            $app.properties.provisioningState = 'Succeeded'
            $app.properties.configuration.Remove('secretCount')
            $app.properties.configuration['secrets'] = @()

            { Assert-GatewaySucceededContainerAppBoundary -App $app -Role Worker `
                    -Config $script:coreConfig -Foundation $script:coreFoundation `
                    -ExpectedImage $script:coreWorkerImage -ExpectedPrincipalId ([string]$app.identity.principalId) `
                    -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint } |
                Should -Throw '*outside the exact image, identity, environment, and secret-free boundary*'
        }

        It 'rejects empty or non-ASCII-alphanumeric Azure location forms <Location>' -ForEach @(
            @{ Location = '' },
            @{ Location = ' ' },
            @{ Location = "Korea`tCentral" },
            @{ Location = 'Korea-Central' },
            @{ Location = '서울' }
        ) {
            { ConvertTo-GatewayCanonicalAzureLocation -Location $Location } | Should -Throw '*Azure location*'
        }

        It 'accepts the project-scoped API audience, binds empty initial authority, and reaches the inert deployment boundary' {
            { Deploy-GatewayCore `
                    -Config $script:coreConfig `
                    -Foundation $script:coreFoundation `
                    -Identity $script:coreIdentity `
                    -ApiImage "acrsafe.azurecr.io/gateway-api@sha256:$('1' * 64)" `
                    -WorkerImage "acrsafe.azurecr.io/gateway-worker@sha256:$('2' * 64)" `
                    -WorkerPrincipalId '' `
                    -ManagerApplicationIds @() `
                    -DeploymentOwnershipId $script:coreOwnershipId `
                    -SourceFingerprint $script:coreSourceFingerprint `
                    -Initial } |
                Should -Throw '*core-deployment-reached*'

            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 1 -Exactly -ParameterFilter {
                [string]$Parameters.agent365ProvisioningManagedIdentityPrincipalId -ceq '' -and
                @($Parameters.agent365ManagerApplicationIds).Count -eq 0 -and
                [bool]$Parameters.agent365ManagerApplicationsPreflightConfirmed -eq $false -and
                [bool]$Parameters.allowLegacySystemAssignedImagePull -eq $false -and
                [string]$Parameters.entraIdAudience -ceq [string]$script:coreIdentity.gatewayApiTokenAudience
            }
        }

        It 'keeps the exact deployment map in case-sensitive parity with compiled main.bicep and rejects legacy image pull' {
            $script:capturedCompiledParityParameters = $null
            Mock Invoke-AzTsv { return '0' }
            Mock Invoke-ArmDeploymentWithSecureParameters {
                param($ResourceGroup, $Name, $TemplateFile, $Parameters, $Mode)
                $script:capturedCompiledParityParameters = $Parameters
                throw 'compiled-parameter-parity-captured'
            }

            { Deploy-GatewayCore @script:coreInitialArguments } |
                Should -Throw '*compiled-parameter-parity-captured*'

            $mainBicep = [IO.Path]::GetFullPath((Join-Path (Get-Location) 'infrastructure/bicep/main.bicep'))
            $compiledText = (& az bicep build --file $mainBicep --stdout --only-show-errors 2>$null) -join [Environment]::NewLine
            $LASTEXITCODE | Should -Be 0
            $compiled = ConvertFrom-Json -InputObject $compiledText -Depth 100 -ErrorAction Stop
            $compiledNames = @($compiled.parameters.PSObject.Properties.Name | Sort-Object -CaseSensitive)
            $capturedNames = @($script:capturedCompiledParityParameters.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)

            $capturedNames.Count | Should -Be 76
            ($capturedNames -join '|') | Should -BeExactly ($compiledNames -join '|')
            $script:capturedCompiledParityParameters.allowLegacySystemAssignedImagePull | Should -BeFalse

            $actual = [ordered]@{}
            foreach ($entry in $script:capturedCompiledParityParameters.GetEnumerator()) {
                $actual[$entry.Key] = [ordered]@{ value = $entry.Value }
            }
            $actual.allowLegacySystemAssignedImagePull.value = $true
            { Assert-GatewayExactReadableArmParameters -ActualParameters $actual `
                    -ExpectedParameters $script:capturedCompiledParityParameters `
                    -SecureParameterNames @('adminUiEntraClientSecretKeyVaultSecretUri') } |
                Should -Throw '*allowLegacySystemAssignedImagePull*'
        }

        It 'rejects swapped scope-base and v2 token-audience values before any Azure discovery or workload mutation' {
            foreach ($identityMutation in @(
                { $script:coreIdentity.gatewayApiScopeBaseUri = "api://$($script:coreIdentity.gatewayApiClientId)" },
                { $script:coreIdentity.gatewayApiTokenAudience = $script:coreIdentity.gatewayApiScopeBaseUri }
            )) {
                $script:coreIdentity.gatewayApiScopeBaseUri = 'api://a365-gateway-safe-dev'
                $script:coreIdentity.gatewayApiTokenAudience = $script:coreIdentity.gatewayApiClientId
                & $identityMutation

                { Deploy-GatewayCore @script:coreInitialArguments } |
                    Should -Throw '*identity evidence does not match the exact API application authority contract*'
            }

            Should -Invoke Invoke-AzTsv -Times 0 -Exactly
            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
        }

        It 'rejects nonempty authority inputs on the initial inert deployment path' {
            $invalidAuthorityInputs = @(
                [pscustomobject]@{
                    workerPrincipalId = $script:coreWorkerPrincipalId
                    managerApplicationIds = @()
                },
                [pscustomobject]@{
                    workerPrincipalId = ''
                    managerApplicationIds = @($script:coreManagerApplicationId)
                }
            )
            foreach ($invalidAuthorityInput in $invalidAuthorityInputs) {
                { Deploy-GatewayCore `
                        -Config $script:coreConfig `
                        -Foundation $script:coreFoundation `
                        -Identity $script:coreIdentity `
                        -ApiImage "acrsafe.azurecr.io/gateway-api@sha256:$('1' * 64)" `
                        -WorkerImage "acrsafe.azurecr.io/gateway-worker@sha256:$('2' * 64)" `
                        -WorkerPrincipalId $invalidAuthorityInput.workerPrincipalId `
                        -ManagerApplicationIds $invalidAuthorityInput.managerApplicationIds `
                        -DeploymentOwnershipId $script:coreOwnershipId `
                        -SourceFingerprint $script:coreSourceFingerprint `
                        -Initial } |
                    Should -Throw '*Initial inert deployment requires empty worker and managerApplications authority inputs*'
            }

            Should -Invoke Invoke-AzTsv -Times 0 -Exactly
            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
        }

        It 'rejects every runtime-only input on Initial before any Azure call' {
            $runtimeOnlyCases = @(
                [ordered]@{ Database = $script:coreDatabase },
                [ordered]@{ EnableWorkerProcessing = $true },
                [ordered]@{ EnableProvisioning = $true },
                [ordered]@{ EnablePurview = $true },
                [ordered]@{ AdminUiImage = 'acrsafe.azurecr.io/gateway-admin@sha256:' + ('3' * 64) },
                [ordered]@{ AdminUiClientId = '66666666-6666-4666-8666-666666666666' },
                [ordered]@{ AdminUiSecretUri = 'https://kv-safe-dev.vault.azure.net/secrets/admin-ui' }
            )
            foreach ($runtimeOnlyCase in $runtimeOnlyCases) {
                $arguments = @{
                    Config = $script:coreConfig
                    Foundation = $script:coreFoundation
                    Identity = $script:coreIdentity
                    ApiImage = "acrsafe.azurecr.io/gateway-api@sha256:$('1' * 64)"
                    WorkerImage = "acrsafe.azurecr.io/gateway-worker@sha256:$('2' * 64)"
                    WorkerPrincipalId = ''
                    ManagerApplicationIds = @()
                    DeploymentOwnershipId = $script:coreOwnershipId
                    SourceFingerprint = $script:coreSourceFingerprint
                    Initial = $true
                }
                foreach ($entry in $runtimeOnlyCase.GetEnumerator()) {
                    $arguments[[string]$entry.Key] = $entry.Value
                }

                { Deploy-GatewayCore @arguments } |
                    Should -Throw '*Initial inert deployment rejects database, activation, Purview, and Admin UI runtime inputs*'
            }

            Should -Invoke Invoke-AzTsv -Times 0 -Exactly
            Should -Invoke Invoke-AzJson -Times 0 -Exactly
            Should -Invoke Invoke-BootstrapCommand -Times 0 -Exactly
            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
        }

        It 'rejects an empty worker principal ID before any runtime deployment' {
            { Deploy-GatewayCore `
                    -Config $script:coreConfig `
                    -Foundation $script:coreFoundation `
                    -Identity $script:coreIdentity `
                    -ApiImage "acrsafe.azurecr.io/gateway-api@sha256:$('1' * 64)" `
                    -WorkerImage "acrsafe.azurecr.io/gateway-worker@sha256:$('2' * 64)" `
                    -WorkerPrincipalId '' `
                    -ManagerApplicationIds @($script:coreManagerApplicationId) `
                    -DeploymentOwnershipId $script:coreOwnershipId `
                    -SourceFingerprint $script:coreSourceFingerprint } |
                Should -Throw '*canonical lowercase worker managed-identity principal ID*'

            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
        }

        It 'rejects an empty runtime managerApplications collection before deployment' {
            $script:coreConfig.agent365.reviewedManagerApplicationIds = @()

            { Deploy-GatewayCore `
                    -Config $script:coreConfig `
                    -Foundation $script:coreFoundation `
                    -Identity $script:coreIdentity `
                    -ApiImage "acrsafe.azurecr.io/gateway-api@sha256:$('1' * 64)" `
                    -WorkerImage "acrsafe.azurecr.io/gateway-worker@sha256:$('2' * 64)" `
                    -WorkerPrincipalId $script:coreWorkerPrincipalId `
                    -ManagerApplicationIds @() `
                    -DeploymentOwnershipId $script:coreOwnershipId `
                    -SourceFingerprint $script:coreSourceFingerprint } |
                Should -Throw '*Runtime managerApplications must exactly equal*'

            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
        }

        It 'accepts only the canonical worker principal exactly bound to database attestation' {
            { Deploy-GatewayCore `
                    -Config $script:coreConfig `
                    -Foundation $script:coreFoundation `
                    -Identity $script:coreIdentity `
                    -ApiImage "acrsafe.azurecr.io/gateway-api@sha256:$('1' * 64)" `
                    -WorkerImage "acrsafe.azurecr.io/gateway-worker@sha256:$('2' * 64)" `
                    -WorkerPrincipalId $script:coreWorkerPrincipalId `
                    -ManagerApplicationIds @($script:coreManagerApplicationId) `
                    -DeploymentOwnershipId $script:coreOwnershipId `
                    -SourceFingerprint $script:coreSourceFingerprint `
                    -Database $script:coreDatabase } |
                Should -Throw '*core-deployment-reached*'

            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 1 -Exactly -ParameterFilter {
                [string]$Parameters.agent365ProvisioningManagedIdentityPrincipalId -ceq $script:coreWorkerPrincipalId -and
                [string]$Parameters.databaseAttestationWorkerPrincipalClientId -ceq [string]$script:coreDatabase.workerPrincipalClientId
            }
        }

        It 'rejects a different canonical worker principal from the database-bound object ID' {
            { Deploy-GatewayCore `
                    -Config $script:coreConfig `
                    -Foundation $script:coreFoundation `
                    -Identity $script:coreIdentity `
                    -ApiImage "acrsafe.azurecr.io/gateway-api@sha256:$('1' * 64)" `
                    -WorkerImage "acrsafe.azurecr.io/gateway-worker@sha256:$('2' * 64)" `
                    -WorkerPrincipalId $script:wrongCoreWorkerPrincipalId `
                    -ManagerApplicationIds @($script:coreManagerApplicationId) `
                    -DeploymentOwnershipId $script:coreOwnershipId `
                    -SourceFingerprint $script:coreSourceFingerprint `
                    -Database $script:coreDatabase } |
                Should -Throw '*exact ownership/source-bound current database-attestation evidence*'

            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
        }

        It 'accepts the exact readable parameter surface while treating the secure Admin UI URI as logically blank' {
            $expected = [ordered]@{
                deployAdminUi = $false
                adminUiContainerImage = ''
                adminUiEntraClientId = ''
                adminUiEntraClientSecretKeyVaultSecretUri = ''
                runtimeImagePullIdentityId = [string]$script:coreFoundation.runtimeImagePullIdentityId
            }
            $actual = [ordered]@{
                deployAdminUi = [ordered]@{ value = $false }
                adminUiContainerImage = [ordered]@{ value = '' }
                adminUiEntraClientId = [ordered]@{ value = '' }
                adminUiEntraClientSecretKeyVaultSecretUri = [ordered]@{}
                runtimeImagePullIdentityId = [ordered]@{ value = ([string]$script:coreFoundation.runtimeImagePullIdentityId).ToUpperInvariant() }
            }

            Assert-GatewayExactReadableArmParameters -ActualParameters $actual -ExpectedParameters $expected `
                -SecureParameterNames @('adminUiEntraClientSecretKeyVaultSecretUri') | Should -BeTrue
        }

        It 'rejects exact deployment parameter mismatch <Mutation>' -ForEach @(
            @{ Mutation = 'extra' },
            @{ Mutation = 'missing' },
            @{ Mutation = 'value' },
            @{ Mutation = 'unreadable' }
        ) {
            $expected = [ordered]@{ environment = 'dev'; workerProcessingEnabled = $false }
            $actual = [ordered]@{
                environment = [ordered]@{ value = 'dev' }
                workerProcessingEnabled = [ordered]@{ value = $false }
            }
            switch ($Mutation) {
                'extra' { $actual['unreviewed'] = [ordered]@{ value = 'x' } }
                'missing' { $actual.Remove('environment') }
                'value' { $actual.workerProcessingEnabled.value = $true }
                'unreadable' { $actual.environment = [ordered]@{} }
            }

            { Assert-GatewayExactReadableArmParameters -ActualParameters $actual -ExpectedParameters $expected } |
                Should -Throw '*prior inert deployment*'
        }

        It 'accepts truly absent partial provider fields without weakening the exact resource boundary' {
            $app = & $script:newPartialWorkerApp
            $app.PSObject.Properties.Remove('identity')
            $app.properties.Remove('configuration')
            $app.properties.Remove('template')

            Assert-GatewayExactPartialContainerAppEnvelope -App $app -Role Worker `
                -Config $script:coreConfig -Foundation $script:coreFoundation `
                -ExpectedImage $script:coreWorkerImage -DeploymentOwnershipId $script:coreOwnershipId `
                -SourceFingerprint $script:coreSourceFingerprint `
                -ExpectedEnvironment ([ordered]@{ DOTNET_ENVIRONMENT = 'Production' }) | Should -BeTrue
        }

        It 'rejects a Succeeded child whose identity, configuration, and template are incomplete' {
            $app = & $script:newPartialWorkerApp
            $app.properties.provisioningState = 'Succeeded'
            $app.PSObject.Properties.Remove('identity')
            $app.properties.Remove('configuration')
            $app.properties.Remove('template')

            { Assert-GatewayExactPartialContainerAppEnvelope -App $app -Role Worker `
                    -Config $script:coreConfig -Foundation $script:coreFoundation `
                    -ExpectedImage $script:coreWorkerImage -DeploymentOwnershipId $script:coreOwnershipId `
                    -SourceFingerprint $script:coreSourceFingerprint `
                    -ExpectedEnvironment ([ordered]@{ DOTNET_ENVIRONMENT = 'Production' }) } |
                Should -Throw '*completed Container App*'
        }

        It 'rejects a Succeeded worker with missing complete field <Field>' -ForEach @(
            @{ Field = 'tenantId' },
            @{ Field = 'cpu' },
            @{ Field = 'memory' },
            @{ Field = 'minReplicas' },
            @{ Field = 'maxReplicas' }
        ) {
            $app = & $script:newPartialWorkerApp
            $app.properties.provisioningState = 'Succeeded'
            switch ($Field) {
                'tenantId' { $app.identity.Remove('tenantId') }
                'cpu' { $app.properties.template.containers[0].resources.Remove('cpu') }
                'memory' { $app.properties.template.containers[0].resources.Remove('memory') }
                'minReplicas' { $app.properties.template.scale.Remove('minReplicas') }
                'maxReplicas' { $app.properties.template.scale.Remove('maxReplicas') }
            }

            { Assert-GatewayExactPartialContainerAppEnvelope -App $app -Role Worker `
                    -Config $script:coreConfig -Foundation $script:coreFoundation `
                    -ExpectedImage $script:coreWorkerImage -DeploymentOwnershipId $script:coreOwnershipId `
                    -SourceFingerprint $script:coreSourceFingerprint `
                    -ExpectedEnvironment ([ordered]@{ DOTNET_ENVIRONMENT = 'Production' }) } |
                Should -Throw
        }

        It 'rejects a Succeeded API with missing ingress field <Field>' -ForEach @(
            @{ Field = 'external' },
            @{ Field = 'allowInsecure' },
            @{ Field = 'targetPort' },
            @{ Field = 'transport' },
            @{ Field = 'fqdn' }
        ) {
            $app = & $script:newCompleteApiApp
            $app.properties.configuration.ingress.Remove($Field)
            $expectedEnvironment = [ordered]@{
                ASPNETCORE_ENVIRONMENT = 'Production'
                __recoveryApiFqdn = 'ca-gateway-api-dev.safe.azurecontainerapps.io'
            }

            { Assert-GatewayExactPartialContainerAppEnvelope -App $app -Role Api `
                    -Config $script:coreConfig -Foundation $script:coreFoundation `
                    -ExpectedImage $script:coreApiImage -DeploymentOwnershipId $script:coreOwnershipId `
                    -SourceFingerprint $script:coreSourceFingerprint -ExpectedEnvironment $expectedEnvironment } |
                Should -Throw
        }

        It 'rejects a wrong-case partial environment name under ordinal matching' {
            $app = & $script:newPartialWorkerApp
            $app.properties.template.containers[0].env[0].name = 'dotnet_environment'

            { Assert-GatewayExactPartialContainerAppEnvelope -App $app -Role Worker `
                    -Config $script:coreConfig -Foundation $script:coreFoundation `
                    -ExpectedImage $script:coreWorkerImage -DeploymentOwnershipId $script:coreOwnershipId `
                    -SourceFingerprint $script:coreSourceFingerprint `
                    -ExpectedEnvironment ([ordered]@{ DOTNET_ENVIRONMENT = 'Production' }) } |
                Should -Throw '*missing, duplicate, or unreviewed name*'
        }

        It 'rejects partial Container App mismatch <Mutation>' -ForEach @(
            @{ Mutation = 'source' },
            @{ Mutation = 'extraIdentity' },
            @{ Mutation = 'systemRegistry' },
            @{ Mutation = 'secret' },
            @{ Mutation = 'extraEnvironment' },
            @{ Mutation = 'nonterminal' },
            @{ Mutation = 'environmentId' },
            @{ Mutation = 'scaleRule' },
            @{ Mutation = 'workerIngress' }
        ) {
            $app = & $script:newPartialWorkerApp
            switch ($Mutation) {
                'source' { $app.tags.bootstrapSourceFingerprint = "sha256:$('f' * 64)" }
                'extraIdentity' { $app.identity.userAssignedIdentities['/subscriptions/other/resourceGroups/other/providers/Microsoft.ManagedIdentity/userAssignedIdentities/other'] = [ordered]@{} }
                'systemRegistry' { $app.properties.configuration.registries[0].identity = 'system' }
                'secret' { $app.properties.configuration.secretCount = 1 }
                'extraEnvironment' { $app.properties.template.containers[0].env += ,[ordered]@{ name = 'Unreviewed__Gate'; value = 'true' } }
                'nonterminal' { $app.properties.provisioningState = 'Running' }
                'environmentId' { $app.properties.managedEnvironmentId = '/subscriptions/other/resourceGroups/other/providers/Microsoft.App/managedEnvironments/other' }
                'scaleRule' { $app.properties.template.scale.rules = @([ordered]@{ name = 'unreviewed' }) }
                'workerIngress' { $app.properties.configuration.ingress = [ordered]@{ external = $true; targetPort = 8080 } }
            }

            { Assert-GatewayExactPartialContainerAppEnvelope -App $app -Role Worker `
                    -Config $script:coreConfig -Foundation $script:coreFoundation `
                    -ExpectedImage $script:coreWorkerImage -DeploymentOwnershipId $script:coreOwnershipId `
                    -SourceFingerprint $script:coreSourceFingerprint `
                    -ExpectedEnvironment ([ordered]@{ DOTNET_ENVIRONMENT = 'Production' }) } |
                Should -Throw
        }

        It 'rejects an absent deployment that collides with either fresh app target' {
            Mock Invoke-AzTsv {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'deployment') { return '0' }
                if ($Arguments -contains 'ca-gateway-worker-dev-v3') { return '1' }
                return '0'
            }

            { Deploy-GatewayCore @script:coreInitialArguments } |
                Should -Throw '*was not proven absent*'
            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
        }

        It 'retries an exact terminal <State> deployment under the same Incremental name only after checkpointing' -ForEach @(
            @{ State = 'Failed'; CorrelationId = '12121212-1212-4212-8212-121212121212' },
            @{ State = 'Canceled'; CorrelationId = '13131313-1313-4313-8313-131313131313' }
        ) {
            $script:retryCheckpoint = $null
            $terminal = & $script:newTerminalCoreDeployment $State $CorrelationId
            Mock Assert-GatewayExactReadableArmParameters { return $true }
            Mock Invoke-AzTsv {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'deployment') { return '1' }
                return '0'
            }
            Mock Invoke-AzJson { return $terminal }
            Mock Invoke-ArmDeploymentWithSecureParameters { throw 'terminal-retry-reached' }

            { Deploy-GatewayCore @script:coreInitialArguments -Checkpoint {
                    param($partialEvidence)
                    $script:retryCheckpoint = $partialEvidence
                } } | Should -Throw '*terminal-retry-reached*'

            $script:retryCheckpoint.terminalDeploymentRetryReceipts.Count | Should -Be 1
            @($script:retryCheckpoint.Keys | Sort-Object -CaseSensitive) -join '|' |
                Should -BeExactly 'deploymentName|deploymentOwnershipId|observedPartialPrincipalIds|sourceFingerprint|terminalDeploymentRetryReceipts'
            $receipt = $script:retryCheckpoint.terminalDeploymentRetryReceipts[0]
            @($receipt.Keys | Sort-Object) -join '|' | Should -BeExactly 'correlationId|mode|state|timestamp'
            $receipt.state | Should -BeExactly $State
            $receipt.correlationId | Should -BeExactly $CorrelationId
            $receipt.mode | Should -BeExactly 'Incremental'
            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 1 -Exactly -ParameterFilter {
                $Name -ceq 'a365gw-safe-bootstrap-inert-dev' -and $Mode -ceq 'Incremental'
            }
        }

        It 'rejects nonterminal deployment state <State> without mutation' -ForEach @(
            @{ State = 'Running' },
            @{ State = 'Accepted' }
        ) {
            $terminal = & $script:newTerminalCoreDeployment $State
            Mock Assert-GatewayExactReadableArmParameters { return $true }
            Mock Invoke-AzTsv { return '1' }
            Mock Invoke-AzJson { return $terminal }

            { Deploy-GatewayCore @script:coreInitialArguments -Checkpoint {} } |
                Should -Throw '*nonterminal or has an unknown state*'
            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
        }

        It 'adopts a Succeeded deployment through GET-only evidence and app validation' {
            $succeeded = & $script:newTerminalCoreDeployment 'Succeeded'
            $script:succeededCheckpoint = $null
            $script:succeededEvidence = [ordered]@{
                deploymentName = 'a365gw-safe-bootstrap-inert-dev'
                apiPrincipalId = '14141414-1414-4414-8414-141414141414'
                workerPrincipalId = '15151515-1515-4515-8515-151515151515'
            }
            Mock Assert-GatewayExactReadableArmParameters { return $true }
            Mock New-GatewayCoreEvidence { return $script:succeededEvidence }
            Mock Assert-GatewaySucceededContainerAppBoundary { return $true }
            Mock Invoke-AzTsv { return '1' }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'deployment') { return $succeeded }
                return [pscustomobject]@{ name = [string]$Arguments[$Arguments.Count - 1] }
            }

            $result = Deploy-GatewayCore @script:coreInitialArguments -SucceededRecoveryOnly -Checkpoint {
                param($evidence)
                $script:succeededCheckpoint = $evidence
            }

            $result.deploymentName | Should -BeExactly 'a365gw-safe-bootstrap-inert-dev'
            $script:succeededCheckpoint.deploymentName | Should -BeExactly 'a365gw-safe-bootstrap-inert-dev'
            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
            Should -Invoke Assert-GatewaySucceededContainerAppBoundary -Times 2 -Exactly
        }

        It 'rejects absent or non-Succeeded read-only inert recovery without ARM mutation' {
            { Deploy-GatewayCore @script:coreInitialArguments -SucceededRecoveryOnly } |
                Should -Throw '*Succeeded inert deployment required for read-only recovery is absent*'

            $failed = & $script:newTerminalCoreDeployment 'Failed'
            Mock Assert-GatewayExactReadableArmParameters { return $true }
            Mock Invoke-AzTsv { return '1' }
            Mock Invoke-AzJson { return $failed }
            { Deploy-GatewayCore @script:coreInitialArguments -SucceededRecoveryOnly } |
                Should -Throw '*not Succeeded; no mutation was attempted*'

            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
        }

        It 'checkpoints fresh Succeeded inert evidence before returning it for outer validation' {
            $script:freshSucceededCheckpoint = $null
            $succeeded = & $script:newTerminalCoreDeployment 'Succeeded'
            $script:succeededEvidence = [ordered]@{ deploymentName = 'a365gw-safe-bootstrap-inert-dev' }
            Mock Invoke-ArmDeploymentWithSecureParameters { return $succeeded }
            Mock New-GatewayCoreEvidence { return $script:succeededEvidence }

            $result = Deploy-GatewayCore @script:coreInitialArguments -Checkpoint {
                param($evidence)
                $script:freshSucceededCheckpoint = $evidence
            }

            $result.deploymentName | Should -BeExactly 'a365gw-safe-bootstrap-inert-dev'
            $script:freshSucceededCheckpoint.deploymentName | Should -BeExactly 'a365gw-safe-bootstrap-inert-dev'
            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 1 -Exactly
        }

        It 'validates both exact extant app targets before a terminal retry' {
            $terminal = & $script:newTerminalCoreDeployment 'Failed'
            Mock Assert-GatewayExactReadableArmParameters { return $true }
            Mock Get-GatewayInertPartialEnvironmentContract { return [ordered]@{ Api = [ordered]@{}; Worker = [ordered]@{} } }
            Mock Assert-GatewayExactPartialContainerAppEnvelope { return $true }
            Mock Invoke-AzTsv { return '1' }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'deployment') { return $terminal }
                return [pscustomobject]@{ name = [string]$Arguments[$Arguments.Count - 1] }
            }
            Mock Invoke-ArmDeploymentWithSecureParameters { throw 'two-app-retry-reached' }

            { Deploy-GatewayCore @script:coreInitialArguments -Checkpoint {} } |
                Should -Throw '*two-app-retry-reached*'
            Should -Invoke Assert-GatewayExactPartialContainerAppEnvelope -Times 2 -Exactly
        }

        It 'runs terminal retry through real parameter and partial-app validators and blocks a mismatch first' {
            $script:capturedCoreParameters = $null
            Mock Invoke-AzTsv { return '0' }
            Mock Invoke-ArmDeploymentWithSecureParameters {
                param($ResourceGroup, $Name, $TemplateFile, $Parameters, $Mode)
                $script:capturedCoreParameters = $Parameters
                throw 'parameter-capture-complete'
            }
            { Deploy-GatewayCore @script:coreInitialArguments } | Should -Throw '*parameter-capture-complete*'

            $actualParameters = [ordered]@{}
            foreach ($entry in $script:capturedCoreParameters.GetEnumerator()) {
                $actualParameters[$entry.Key] = [ordered]@{}
                if ([string]$entry.Key -cne 'adminUiEntraClientSecretKeyVaultSecretUri') {
                    $actualParameters[$entry.Key]['value'] = $entry.Value
                }
            }
            $actualParameters.agent365ManagerApplicationIds.value = @()
            $terminal = & $script:newTerminalCoreDeployment 'Failed'
            $terminal.properties.parameters = $actualParameters
            $partialWorker = & $script:newPartialWorkerApp
            $script:terminalRetryCalls = 0
            $script:integratedCheckpoint = $null
            $script:partialContainerAppQuery = $null
            Mock Get-GatewayInertPartialEnvironmentContract {
                return [ordered]@{ Worker = [ordered]@{ DOTNET_ENVIRONMENT = 'Production' } }
            }
            Mock Invoke-AzTsv {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'deployment') { return '1' }
                if ($Arguments -contains 'ca-gateway-worker-dev-v3') { return '1' }
                return '0'
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'deployment') { return $terminal }
                $script:partialContainerAppQuery = [string]$Arguments[[Array]::IndexOf($Arguments, '--query') + 1]
                return $partialWorker
            }
            Mock Invoke-ArmDeploymentWithSecureParameters {
                $script:terminalRetryCalls++
                throw 'integrated-terminal-retry-reached'
            }

            $terminal.properties.parameters.workerProcessingEnabled.value = $true
            { Deploy-GatewayCore @script:coreInitialArguments -Checkpoint {} } |
                Should -Throw '*parameter does not match*'
            $script:terminalRetryCalls | Should -Be 0

            $terminal.properties.parameters.workerProcessingEnabled.value = $false
            { Deploy-GatewayCore @script:coreInitialArguments -Checkpoint {
                    param($partialEvidence)
                    $script:integratedCheckpoint = $partialEvidence
                } } | Should -Throw '*integrated-terminal-retry-reached*'
            $script:terminalRetryCalls | Should -Be 1
            $script:integratedCheckpoint.observedPartialPrincipalIds.Worker | Should -BeExactly 'efefefef-efef-4fef-8fef-efefefefefef'
            $script:partialContainerAppQuery.Contains('secretCount:length(not_null(properties.configuration.secrets, `[]`))') | Should -BeTrue
            $script:partialContainerAppQuery | Should -Not -BeLike '*secrets:properties.configuration.secrets*'
        }

        It 'does not invoke ARM when the durable retry checkpoint fails' {
            $terminal = & $script:newTerminalCoreDeployment 'Failed'
            Mock Assert-GatewayExactReadableArmParameters { return $true }
            Mock Invoke-AzTsv {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'deployment') { return '1' }
                return '0'
            }
            Mock Invoke-AzJson { return $terminal }

            { Deploy-GatewayCore @script:coreInitialArguments -Checkpoint { throw 'checkpoint-write-failed' } } |
                Should -Throw '*checkpoint-write-failed*'
            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
        }

        It 'rejects a previously observed partial principal drift before mutation' {
            $terminal = & $script:newTerminalCoreDeployment 'Failed'
            $partialWorker = & $script:newPartialWorkerApp
            $priorEvidence = [ordered]@{
                deploymentName = 'a365gw-safe-bootstrap-inert-dev'
                deploymentOwnershipId = $script:coreOwnershipId
                sourceFingerprint = $script:coreSourceFingerprint
                terminalDeploymentRetryReceipts = @()
                observedPartialPrincipalIds = [ordered]@{ Worker = '18181818-1818-4818-8818-181818181818' }
            }
            Mock Assert-GatewayExactReadableArmParameters { return $true }
            Mock Get-GatewayInertPartialEnvironmentContract {
                return [ordered]@{ Worker = [ordered]@{ DOTNET_ENVIRONMENT = 'Production' } }
            }
            Mock Invoke-AzTsv {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'deployment') { return '1' }
                if ($Arguments -contains 'ca-gateway-worker-dev-v3') { return '1' }
                return '0'
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'deployment') { return $terminal }
                return $partialWorker
            }

            { Deploy-GatewayCore @script:coreInitialArguments -RecoveredEvidence $priorEvidence -Checkpoint {} } |
                Should -Throw '*principal is absent or has drifted*'
            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
        }

        It 'seeds recovery principal bindings from prior completed inert evidence' {
            $priorEvidence = [ordered]@{
                deploymentName = 'a365gw-safe-bootstrap-inert-dev'
                deploymentOwnershipId = $script:coreOwnershipId
                sourceFingerprint = $script:coreSourceFingerprint
                apiPrincipalId = '19191919-1919-4919-8919-191919191919'
                workerPrincipalId = '20202020-2020-4020-8020-202020202020'
            }

            $recovered = Get-GatewayInertRecoveredRetryReceipts -RecoveredEvidence $priorEvidence `
                -DeploymentName 'a365gw-safe-bootstrap-inert-dev' `
                -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint

            $recovered.principalIds.Api | Should -BeExactly '19191919-1919-4919-8919-191919191919'
            $recovered.principalIds.Worker | Should -BeExactly '20202020-2020-4020-8020-202020202020'

            $malformedCases = @(
                [ordered]@{
                    deploymentName = 'a365gw-safe-bootstrap-inert-dev'
                    deploymentOwnershipId = $script:coreOwnershipId
                    sourceFingerprint = $script:coreSourceFingerprint
                    terminalDeploymentRetryReceipts = @([ordered]@{
                        state = 'Failed'; correlationId = '23232323-2323-4323-8323-232323232323'
                        timestamp = '2026-08-29T00:00:00.0000000+00:00'; mode = 'Incremental'
                        providerBody = 'private-provider-body-marker'
                    })
                },
                [ordered]@{
                    deploymentName = 'a365gw-safe-bootstrap-inert-dev'
                    deploymentOwnershipId = $script:coreOwnershipId
                    sourceFingerprint = $script:coreSourceFingerprint
                    observedPartialPrincipalIds = [ordered]@{ Unknown = '24242424-2424-4424-8424-242424242424' }
                }
            )
            foreach ($malformed in $malformedCases) {
                try {
                    Get-GatewayInertRecoveredRetryReceipts -RecoveredEvidence $malformed `
                        -DeploymentName 'a365gw-safe-bootstrap-inert-dev' `
                        -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint
                    throw 'Expected malformed recovered evidence to fail closed.'
                }
                catch {
                    $_.Exception.Message | Should -Match '^Recovered inert retry evidence contains (?:an invalid observed principal binding|a non-minimal receipt)\.$'
                    $_.Exception.Message | Should -Not -Match 'private-provider-body-marker'
                }
            }
        }

        It 'rejects successful deployment output principal drift from the durable partial binding' {
            Mock Get-GatewayCoreOutputValue {
                param($Outputs, [string]$Name)
                switch ($Name) {
                    'deploymentOwnershipId' { return $script:coreOwnershipId }
                    'bootstrapSourceFingerprint' { return $script:coreSourceFingerprint }
                    'apiContainerImage' { return $script:coreApiImage }
                    'workerContainerImage' { return $script:coreWorkerImage }
                    'runtimeImagePullIdentityId' { return [string]$script:coreFoundation.runtimeImagePullIdentityId }
                    'runtimeImagePullIdentityPrincipalId' { return [string]$script:coreFoundation.runtimeImagePullIdentityPrincipalId }
                    'runtimeImagePullAcrPullRoleAssignmentId' { return [string]$script:coreFoundation.runtimeImagePullAcrPullRoleAssignmentId }
                    'workerPrincipalId' { return '22222222-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }
                    default { return '' }
                }
            }
            $parameters = [ordered]@{
                deploymentOwnershipId = $script:coreOwnershipId
                bootstrapSourceFingerprint = $script:coreSourceFingerprint
                apiContainerImage = $script:coreApiImage
                workerContainerImage = $script:coreWorkerImage
            }

            { New-GatewayCoreEvidence -DeploymentName 'a365gw-safe-bootstrap-inert-dev' -Outputs ([pscustomobject]@{}) `
                    -Foundation $script:coreFoundation -Parameters $parameters `
                    -ObservedPartialPrincipalIds ([ordered]@{ Worker = '21212121-2121-4121-8121-212121212121' }) } |
                Should -Throw '*system principal drifted*'
        }

        It 'preserves prior safe receipts and checkpoints the current terminal receipt when retry submission fails' {
            $terminal = & $script:newTerminalCoreDeployment 'Canceled' '17171717-1717-4717-8717-171717171717'
            $priorEvidence = [ordered]@{
                deploymentName = 'a365gw-safe-bootstrap-inert-dev'
                deploymentOwnershipId = $script:coreOwnershipId
                sourceFingerprint = $script:coreSourceFingerprint
                terminalDeploymentRetryReceipts = @([ordered]@{
                    state = 'Failed'
                    correlationId = '16161616-1616-4616-8616-161616161616'
                    timestamp = '2026-08-29T00:00:00.0000000+00:00'
                    mode = 'Incremental'
                })
            }
            $script:retryCheckpoint = $null
            Mock Assert-GatewayExactReadableArmParameters { return $true }
            Mock Invoke-AzTsv {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'deployment') { return '1' }
                return '0'
            }
            Mock Invoke-AzJson { return $terminal }
            Mock Invoke-ArmDeploymentWithSecureParameters { throw 'provider-retry-failed' }

            { Deploy-GatewayCore @script:coreInitialArguments -RecoveredEvidence $priorEvidence -Checkpoint {
                    param($partialEvidence)
                    $script:retryCheckpoint = $partialEvidence
                } } | Should -Throw '*provider-retry-failed*'

            $script:retryCheckpoint.terminalDeploymentRetryReceipts.Count | Should -Be 2
            $script:retryCheckpoint.terminalDeploymentRetryReceipts[0].correlationId | Should -BeExactly '16161616-1616-4616-8616-161616161616'
            $script:retryCheckpoint.terminalDeploymentRetryReceipts[1].correlationId | Should -BeExactly '17171717-1717-4717-8717-171717171717'
        }

        Context 'Succeeded inert What-If Ignore recovery boundary' {
            BeforeEach {
                $script:coreFoundation | Add-Member -NotePropertyName virtualNetworkId `
                    -NotePropertyValue "/subscriptions/$($script:coreConfig.subscriptionId)/resourceGroups/$($script:coreConfig.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/vnet-safe-dev"
                $script:coreFoundation | Add-Member -NotePropertyName privateEndpointSubnetId `
                    -NotePropertyValue "$($script:coreFoundation.virtualNetworkId)/subnets/snet-private-endpoints"
                $script:coreFoundation | Add-Member -NotePropertyName logAnalyticsWorkspaceName -NotePropertyValue 'log-safe-dev'
                $script:boundaryProviderPrefix = "/subscriptions/$($script:coreConfig.subscriptionId)/resourceGroups/$($script:coreConfig.resourceGroupName)/providers"
                $script:boundaryStorageName = 'stsafedevabc123'
                $script:boundaryStorageId = "$($script:boundaryProviderPrefix)/Microsoft.Storage/storageAccounts/$($script:boundaryStorageName)"
                $script:boundaryPrivateEndpointName = "pe-$($script:boundaryStorageName)-blob"
                $script:boundaryPrivateEndpointId = "$($script:boundaryProviderPrefix)/Microsoft.Network/privateEndpoints/$($script:boundaryPrivateEndpointName)"
                $script:boundaryDnsZoneId = "$($script:boundaryProviderPrefix)/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
                $script:boundaryDnsLinkName = 'link-safe-dev-storage'
                $script:boundaryDnsLinkId = "$($script:boundaryDnsZoneId)/virtualNetworkLinks/$($script:boundaryDnsLinkName)"
                $script:boundaryNicId = "$($script:boundaryProviderPrefix)/Microsoft.Network/networkInterfaces/$($script:boundaryPrivateEndpointName).nic.34343434-3434-4434-8434-343434343434"
                $script:boundaryServiceBusId = "$($script:boundaryProviderPrefix)/Microsoft.ServiceBus/namespaces/sb-safe-dev"
                $script:boundarySqlServerId = "$($script:boundaryProviderPrefix)/Microsoft.Sql/servers/sql-safe-dev"
                $script:boundaryGatewayDbId = "$($script:boundarySqlServerId)/databases/GatewayDb"
                $script:boundaryMasterId = "$($script:boundarySqlServerId)/databases/master"
                $script:boundaryActionGroupId = "$($script:boundaryProviderPrefix)/Microsoft.Insights/actionGroups/ag-gateway-alerts"
                $script:boundaryAppInsightsId = "$($script:boundaryProviderPrefix)/Microsoft.Insights/components/ai-safe-dev"
                $script:boundarySharedVaultId = "$($script:boundaryProviderPrefix)/Microsoft.KeyVault/vaults/kv-safe-dev"
                $script:boundaryProvisioningVaultId = "$($script:boundaryProviderPrefix)/Microsoft.KeyVault/vaults/kv-safe-dev-prov"
                $script:boundaryBaseTags = [ordered]@{
                    project = 'a365-gateway'; environment = 'dev'; managedBy = 'bicep'; projectName = 'safe'
                    deploymentId = 'safe-dev'; bootstrapOwnershipId = $script:coreOwnershipId
                    bootstrapSourceFingerprint = $script:coreSourceFingerprint
                }
                $script:boundaryProvisioningTags = [ordered]@{}
                foreach ($entry in $script:boundaryBaseTags.GetEnumerator()) { $script:boundaryProvisioningTags[$entry.Key] = $entry.Value }
                $script:boundaryProvisioningTags.workload = 'provisioning-credentials'
                $script:boundaryPrivateEndpointTags = [ordered]@{}
                foreach ($entry in $script:boundaryBaseTags.GetEnumerator()) { $script:boundaryPrivateEndpointTags[$entry.Key] = $entry.Value }
                $script:boundaryPrivateEndpointTags.workload = 'interaction-content'
                $script:boundaryResources = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
                $script:boundaryIdsByType = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
                $script:addBoundaryResource = {
                    param(
                        [string]$Id, [string]$Type, [string]$Name, [string]$Location,
                        $Tags, $Properties, [bool]$IncludeInInventory = $true
                    )
                    $resource = [pscustomobject]@{
                        id = $Id; type = $Type; name = $Name; location = $Location
                        tags = $Tags
                        properties = if ($null -eq $Properties) { [ordered]@{ provisioningState = 'Succeeded' } } else { $Properties }
                    }
                    $script:boundaryResources[$Id] = $resource
                    if ($IncludeInInventory) {
                        if (-not $script:boundaryIdsByType.ContainsKey($Type)) {
                            $script:boundaryIdsByType[$Type] = [Collections.ArrayList]::new()
                        }
                        [void]$script:boundaryIdsByType[$Type].Add($Id)
                    }
                }

                & $script:addBoundaryResource "$($script:boundaryProviderPrefix)/Microsoft.App/containerApps/ca-gateway-api-dev" `
                    'Microsoft.App/containerApps' 'ca-gateway-api-dev' 'koreacentral' $script:boundaryBaseTags $null
                & $script:addBoundaryResource "$($script:boundaryProviderPrefix)/Microsoft.App/containerApps/ca-gateway-worker-dev-v3" `
                    'Microsoft.App/containerApps' 'ca-gateway-worker-dev-v3' 'koreacentral' $script:boundaryBaseTags $null
                & $script:addBoundaryResource $script:boundaryActionGroupId 'Microsoft.Insights/actionGroups' `
                    'ag-gateway-alerts' 'global' $script:boundaryBaseTags $null
                & $script:addBoundaryResource $script:boundaryAppInsightsId 'Microsoft.Insights/components' 'ai-safe-dev' `
                    'koreacentral' $script:boundaryBaseTags ([ordered]@{
                        provisioningState = 'Succeeded'
                        WorkspaceResourceId = "$($script:boundaryProviderPrefix)/Microsoft.OperationalInsights/workspaces/log-safe-dev"
                    })
                & $script:addBoundaryResource $script:boundarySharedVaultId 'Microsoft.KeyVault/vaults' 'kv-safe-dev' `
                    'koreacentral' $script:boundaryBaseTags $null
                & $script:addBoundaryResource $script:boundaryProvisioningVaultId 'Microsoft.KeyVault/vaults' 'kv-safe-dev-prov' `
                    'koreacentral' $script:boundaryProvisioningTags $null
                & $script:addBoundaryResource $script:boundaryDnsZoneId 'Microsoft.Network/privateDnsZones' `
                    'privatelink.blob.core.windows.net' 'global' ([ordered]@{}) $null
                & $script:addBoundaryResource $script:boundaryDnsLinkId 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' `
                    'link-safe-dev-storage' 'global' ([ordered]@{}) ([ordered]@{
                        provisioningState = 'Succeeded'; registrationEnabled = $false
                        virtualNetwork = [ordered]@{ id = $script:coreFoundation.virtualNetworkId }
                    })
                & $script:addBoundaryResource $script:boundaryPrivateEndpointId 'Microsoft.Network/privateEndpoints' `
                    $script:boundaryPrivateEndpointName 'koreacentral' $script:boundaryPrivateEndpointTags ([ordered]@{
                        provisioningState = 'Succeeded'
                        subnet = [ordered]@{ id = $script:coreFoundation.privateEndpointSubnetId }
                        privateLinkServiceConnections = @([ordered]@{
                            name = "peconn-$($script:boundaryStorageName)-blob"
                            properties = [ordered]@{
                                privateLinkServiceId = $script:boundaryStorageId
                                groupIds = @('blob')
                            }
                        })
                        networkInterfaces = @([ordered]@{ id = $script:boundaryNicId })
                    })
                & $script:addBoundaryResource $script:boundaryServiceBusId 'Microsoft.ServiceBus/namespaces' `
                    'sb-safe-dev' 'koreacentral' $script:boundaryBaseTags $null
                & $script:addBoundaryResource $script:boundarySqlServerId 'Microsoft.Sql/servers' `
                    'sql-safe-dev' 'koreacentral' $script:boundaryBaseTags $null
                & $script:addBoundaryResource $script:boundaryGatewayDbId 'Microsoft.Sql/servers/databases' `
                    'GatewayDb' 'koreacentral' $script:boundaryBaseTags $null
                & $script:addBoundaryResource $script:boundaryMasterId 'Microsoft.Sql/servers/databases' `
                    'master' 'koreacentral' ([ordered]@{}) $null
                & $script:addBoundaryResource $script:boundaryStorageId 'Microsoft.Storage/storageAccounts' `
                    $script:boundaryStorageName 'koreacentral' $script:boundaryBaseTags $null

                $metricScopes = [ordered]@{
                    'alert-sql-connection-failed-dev' = $script:boundaryGatewayDbId
                    'alert-servicebus-server-errors-dev' = $script:boundaryServiceBusId
                    'alert-keyvault-availability-drop-dev' = $script:boundarySharedVaultId
                    'alert-servicebus-queue-depth-high-dev' = $script:boundaryServiceBusId
                    'alert-servicebus-deadletter-depth-dev' = $script:boundaryServiceBusId
                }
                foreach ($entry in $metricScopes.GetEnumerator()) {
                    & $script:addBoundaryResource "$($script:boundaryProviderPrefix)/Microsoft.Insights/metricAlerts/$($entry.Key)" `
                        'Microsoft.Insights/metricAlerts' ([string]$entry.Key) 'global' $script:boundaryBaseTags ([ordered]@{
                            provisioningState = 'Succeeded'; scopes = @([string]$entry.Value)
                            actions = @([ordered]@{ actionGroupId = $script:boundaryActionGroupId })
                        })
                }
                foreach ($name in @(
                    'alert-api-server-errors-dev', 'alert-api-auth-failures-dev',
                    'alert-api-response-latency-high-dev', 'alert-identity-mismatch-dev',
                    'alert-provisioning-failed-dev'
                )) {
                    & $script:addBoundaryResource "$($script:boundaryProviderPrefix)/Microsoft.Insights/scheduledQueryRules/$name" `
                        'Microsoft.Insights/scheduledQueryRules' $name 'koreacentral' $script:boundaryBaseTags ([ordered]@{
                            provisioningState = 'Succeeded'; scopes = @($script:boundaryAppInsightsId)
                            actions = [ordered]@{ actionGroups = @($script:boundaryActionGroupId) }
                        })
                }
                & $script:addBoundaryResource $script:boundaryNicId 'Microsoft.Network/networkInterfaces' `
                    "$($script:boundaryPrivateEndpointName).nic.34343434-3434-4434-8434-343434343434" `
                    'koreacentral' ([ordered]@{}) ([ordered]@{
                        provisioningState = 'Succeeded'
                        privateEndpoint = [ordered]@{ id = $script:boundaryPrivateEndpointId }
                        ipConfigurations = @([ordered]@{
                            properties = [ordered]@{ subnet = [ordered]@{ id = $script:coreFoundation.privateEndpointSubnetId } }
                        })
                    })
                & $script:addBoundaryResource "$($script:boundaryPrivateEndpointId)/privateDnsZoneGroups/storageBlobDnsGroup" `
                    'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' `
                    'storageBlobDnsGroup' '' ([ordered]@{}) ([ordered]@{
                        provisioningState = 'Succeeded'
                        privateDnsZoneConfigs = @([ordered]@{
                            name = 'blob'; properties = [ordered]@{ privateDnsZoneId = $script:boundaryDnsZoneId }
                        })
                    }) $false
                $script:boundaryResources["$($script:boundaryPrivateEndpointId)/privateDnsZoneGroups/storageBlobDnsGroup"].location = $null

                $script:boundaryEvidence = [ordered]@{
                    deploymentName = 'a365gw-safe-bootstrap-inert-dev'
                    deploymentOwnershipId = $script:coreOwnershipId
                    sourceFingerprint = $script:coreSourceFingerprint
                    apiImage = $script:coreApiImage
                    workerImage = $script:coreWorkerImage
                    containerRegistryId = "$($script:boundaryProviderPrefix)/Microsoft.ContainerRegistry/registries/$($script:coreFoundation.acrName)"
                    sharedKeyVaultId = $script:boundarySharedVaultId
                    storageAccountId = $script:boundaryStorageId
                    storageBlobPrivateEndpointId = $script:boundaryPrivateEndpointId
                    storageBlobPrivateDnsZoneId = $script:boundaryDnsZoneId
                    serviceBusQueueId = "$($script:boundaryServiceBusId)/queues/gateway-provisioning-v3"
                    serviceBusQueueName = 'gateway-provisioning-v3'
                    sqlServerFqdn = 'sql-safe-dev.database.windows.net'
                }

                Mock Get-GatewayInertBoundaryResource {
                    param([string]$ResourceId, [string]$ApiVersion)
                    return $script:boundaryResources[$ResourceId]
                }
                Mock Get-GatewayInertBoundaryTypeInventory {
                    param($Config, [string]$ResourceType)
                    return @($script:boundaryIdsByType[$ResourceType] | ForEach-Object { [pscustomobject]@{ id = $_ } })
                }
            }

            It 'builds one deterministic sorted 25-resource boundary with exact NIC and master bindings' {
                $first = New-GatewayInertWhatIfRecoveryBoundary -Config $script:coreConfig `
                    -Foundation $script:coreFoundation -Evidence $script:boundaryEvidence `
                    -ApiImage $script:coreApiImage -WorkerImage $script:coreWorkerImage `
                    -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint
                $second = New-GatewayInertWhatIfRecoveryBoundary -Config $script:coreConfig `
                    -Foundation $script:coreFoundation -Evidence $script:boundaryEvidence `
                    -ApiImage $script:coreApiImage -WorkerImage $script:coreWorkerImage `
                    -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint

                $first.schemaVersion | Should -Be 1
                $first.phase | Should -BeExactly 'InertIdentityDeployment'
                $first.resourceIds.Count | Should -Be 25
                ($first.resourceIds -join '|') | Should -BeExactly ((@($first.resourceIds | Sort-Object -CaseSensitive)) -join '|')
                $first.generatedNicBinding.nicId | Should -BeExactly $script:boundaryNicId.ToLowerInvariant()
                $first.generatedNicBinding.privateEndpointId | Should -BeExactly $script:boundaryPrivateEndpointId.ToLowerInvariant()
                $first.masterDatabaseBinding.databaseId | Should -BeExactly $script:boundaryMasterId.ToLowerInvariant()
                $first.boundaryFingerprint | Should -Match '^sha256:[0-9a-f]{64}$'
                $second.boundaryFingerprint | Should -BeExactly $first.boundaryFingerprint
                Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
                Should -Invoke Get-GatewayInertBoundaryResource -ParameterFilter { $ResourceId -match '[*?]' } -Times 0 -Exactly
            }

            It 'rejects a parent-qualified provider name for child resource <Child>' -ForEach @(
                @{ Child = 'private DNS virtual-network link' },
                @{ Child = 'Gateway SQL database' },
                @{ Child = 'SQL master database' },
                @{ Child = 'private-endpoint DNS zone group' }
            ) {
                switch ($Child) {
                    'private DNS virtual-network link' {
                        $id = $script:boundaryDnsLinkId
                        $parentQualifiedName = "privatelink.blob.core.windows.net/$($script:boundaryDnsLinkName)"
                    }
                    'Gateway SQL database' {
                        $id = $script:boundaryGatewayDbId
                        $parentQualifiedName = 'sql-safe-dev/GatewayDb'
                    }
                    'SQL master database' {
                        $id = $script:boundaryMasterId
                        $parentQualifiedName = 'sql-safe-dev/master'
                    }
                    'private-endpoint DNS zone group' {
                        $id = "$($script:boundaryPrivateEndpointId)/privateDnsZoneGroups/storageBlobDnsGroup"
                        $parentQualifiedName = "$($script:boundaryPrivateEndpointName)/storageBlobDnsGroup"
                    }
                }
                $script:boundaryResources[$id].name = $parentQualifiedName

                { New-GatewayInertWhatIfRecoveryBoundary -Config $script:coreConfig `
                        -Foundation $script:coreFoundation -Evidence $script:boundaryEvidence `
                        -ApiImage $script:coreApiImage -WorkerImage $script:coreWorkerImage `
                        -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint } |
                    Should -Throw '*exact ID, type, name, and location envelope*'
                Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
            }

            It 'accepts the provider-null location only for the private-endpoint DNS zone-group child' {
                $dnsZoneGroupId = "$($script:boundaryPrivateEndpointId)/privateDnsZoneGroups/storageBlobDnsGroup"
                $script:boundaryResources[$dnsZoneGroupId].location | Should -BeNullOrEmpty

                $boundary = New-GatewayInertWhatIfRecoveryBoundary -Config $script:coreConfig `
                    -Foundation $script:coreFoundation -Evidence $script:boundaryEvidence `
                    -ApiImage $script:coreApiImage -WorkerImage $script:coreWorkerImage `
                    -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint

                $boundary.resourceIds.Count | Should -Be 25
            }

            It 'rejects a nonempty private-endpoint DNS zone-group location <Location>' -ForEach @(
                @{ Location = 'koreacentral' },
                @{ Location = 'global' }
            ) {
                $dnsZoneGroupId = "$($script:boundaryPrivateEndpointId)/privateDnsZoneGroups/storageBlobDnsGroup"
                $script:boundaryResources[$dnsZoneGroupId].location = $Location

                { New-GatewayInertWhatIfRecoveryBoundary -Config $script:coreConfig `
                        -Foundation $script:coreFoundation -Evidence $script:boundaryEvidence `
                        -ApiImage $script:coreApiImage -WorkerImage $script:coreWorkerImage `
                        -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint } |
                    Should -Throw '*Microsoft.Network/privateEndpoints/privateDnsZoneGroups/storageBlobDnsGroup*'
            }

            It 'identifies only the safe expected type and name in a resource-envelope diagnostic' {
                $script:boundaryResources[$script:boundaryStorageId].name = 'provider-only-unexpected-name'
                $message = $null
                try {
                    New-GatewayInertWhatIfRecoveryBoundary -Config $script:coreConfig `
                        -Foundation $script:coreFoundation -Evidence $script:boundaryEvidence `
                        -ApiImage $script:coreApiImage -WorkerImage $script:coreWorkerImage `
                        -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint | Out-Null
                }
                catch { $message = $_.Exception.Message }

                $message | Should -BeExactly `
                    "An inert recovery resource does not match its exact ID, type, name, and location envelope (Microsoft.Storage/storageAccounts/$($script:boundaryStorageName))."
                $message | Should -Not -Match 'provider-only-unexpected-name'
            }

            It 'uses only succeeded-recovery reads when composing the public helper result' {
                $expectedBoundary = [ordered]@{ schemaVersion = 1; phase = 'InertIdentityDeployment'; resourceIds = @('safe') }
                Mock Deploy-GatewayCore { return $script:boundaryEvidence }
                Mock New-GatewayInertWhatIfRecoveryBoundary { return $expectedBoundary }

                $result = Get-GatewayInertWhatIfRecoveryBoundary -Config $script:coreConfig `
                    -Foundation $script:coreFoundation -Identity $script:coreIdentity `
                    -ApiImage $script:coreApiImage -WorkerImage $script:coreWorkerImage `
                    -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint

                $result.evidence | Should -Be $script:boundaryEvidence
                $result.boundary | Should -Be $expectedBoundary
                Should -Invoke Deploy-GatewayCore -Times 1 -Exactly -ParameterFilter {
                    $Initial -and $SucceededRecoveryOnly -and $WorkerPrincipalId -ceq '' -and
                    @($ManagerApplicationIds).Count -eq 0
                }
                Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
            }

            It 'fails closed on inert resource-graph mutation <Mutation>' -ForEach @(
                @{ Mutation = 'extraInventory' },
                @{ Mutation = 'missingInventory' },
                @{ Mutation = 'duplicateInventory' },
                @{ Mutation = 'ambiguousNic' },
                @{ Mutation = 'outOfGroupNic' },
                @{ Mutation = 'unownedTag' },
                @{ Mutation = 'missingResource' },
                @{ Mutation = 'reverseNic' },
                @{ Mutation = 'masterBinding' },
                @{ Mutation = 'extraAlertScope' },
                @{ Mutation = 'crossTypeReadback' }
            ) {
                switch ($Mutation) {
                    'extraInventory' {
                        [void]$script:boundaryIdsByType['Microsoft.Storage/storageAccounts'].Add(
                            "$($script:boundaryProviderPrefix)/Microsoft.Storage/storageAccounts/unownedextra")
                    }
                    'missingInventory' {
                        $script:boundaryIdsByType['Microsoft.KeyVault/vaults'].RemoveAt(0)
                    }
                    'duplicateInventory' {
                        [void]$script:boundaryIdsByType['Microsoft.ServiceBus/namespaces'].Add($script:boundaryServiceBusId)
                    }
                    'ambiguousNic' {
                        $script:boundaryResources[$script:boundaryPrivateEndpointId].properties.networkInterfaces +=
                            ,[ordered]@{ id = "$($script:boundaryProviderPrefix)/Microsoft.Network/networkInterfaces/other.nic.45454545-4545-4454-8454-454545454545" }
                    }
                    'outOfGroupNic' {
                        $script:boundaryResources[$script:boundaryPrivateEndpointId].properties.networkInterfaces[0].id =
                            '/subscriptions/99999999-9999-4999-8999-999999999999/resourceGroups/other/providers/Microsoft.Network/networkInterfaces/other'
                    }
                    'unownedTag' {
                        $script:boundaryResources[$script:boundaryStorageId].tags.bootstrapOwnershipId =
                            '56565656-5656-4565-8565-565656565656'
                    }
                    'missingResource' {
                        Mock Get-GatewayInertBoundaryResource {
                            param([string]$ResourceId, [string]$ApiVersion)
                            if ($ResourceId -ieq $script:boundaryStorageId) { return $null }
                            return $script:boundaryResources[$ResourceId]
                        }
                    }
                    'reverseNic' {
                        $script:boundaryResources[$script:boundaryNicId].properties.privateEndpoint.id =
                            "$($script:boundaryProviderPrefix)/Microsoft.Network/privateEndpoints/other"
                    }
                    'masterBinding' {
                        $script:boundaryResources[$script:boundaryMasterId].id =
                            "$($script:boundarySqlServerId)/databases/not-master"
                    }
                    'extraAlertScope' {
                        $alertId = "$($script:boundaryProviderPrefix)/Microsoft.Insights/metricAlerts/alert-sql-connection-failed-dev"
                        $script:boundaryResources[$alertId].properties.scopes += ,$script:boundaryServiceBusId
                    }
                    'crossTypeReadback' {
                        $script:boundaryResources[$script:boundaryStorageId].type = 'Microsoft.KeyVault/vaults'
                    }
                }

                { New-GatewayInertWhatIfRecoveryBoundary -Config $script:coreConfig `
                        -Foundation $script:coreFoundation -Evidence $script:boundaryEvidence `
                        -ApiImage $script:coreApiImage -WorkerImage $script:coreWorkerImage `
                        -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint } |
                    Should -Throw
                Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
            }

            It 'rejects optional graph expansion before any provider read' {
                $script:coreConfig.promptShield.enabled = $true

                { New-GatewayInertWhatIfRecoveryBoundary -Config $script:coreConfig `
                        -Foundation $script:coreFoundation -Evidence $script:boundaryEvidence `
                        -ApiImage $script:coreApiImage -WorkerImage $script:coreWorkerImage `
                        -DeploymentOwnershipId $script:coreOwnershipId -SourceFingerprint $script:coreSourceFingerprint } |
                    Should -Throw '*does not include optional Prompt Shields resources*'
                Should -Invoke Get-GatewayInertBoundaryResource -Times 0 -Exactly
                Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 0 -Exactly
            }
        }
    }
}
