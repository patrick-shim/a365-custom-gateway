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

        It 'returns no runs for an absent exact tag without calling the image-filtered run command' {
            $tag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -IntentId $script:intentIds.api
            Mock Get-GatewayAcrExactTagDigest { return $null }
            Mock Invoke-BootstrapCommand { throw 'Image-filtered run discovery must not execute for an absent tag.' }

            @(Get-GatewayAcrExactImageRuns -Registry 'acrsafe' -Repository 'gateway-api' -Tag $tag).Count |
                Should -Be 0

            Should -Invoke Get-GatewayAcrExactTagDigest -Times 1 -Exactly
            Should -Invoke Invoke-BootstrapCommand -Times 0 -Exactly
        }

        It 'uses image-filtered run discovery only after the exact tag exists' {
            $tag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -IntentId $script:intentIds.api
            $image = "gateway-api:$tag"
            Mock Get-GatewayAcrExactTagDigest {
                return [pscustomobject]@{ tag = $tag; digest = "sha256:$('1' * 64)" }
            }
            Mock Invoke-BootstrapCommand { return '[]' }

            @(Get-GatewayAcrExactImageRuns -Registry 'acrsafe' -Repository 'gateway-api' -Tag $tag).Count |
                Should -Be 0

            Should -Invoke Invoke-BootstrapCommand -Times 1 -Exactly -ParameterFilter {
                $FilePath -ceq 'az' -and
                ((@($ArgumentList) -join ' ') -ceq (
                    "acr task list-runs --registry acrsafe --image $image --top 2 " +
                    '--query [].{runId:runId,status:status,runType:runType,outputImages:outputImages} ' +
                    '--output json --only-show-errors'))
            }
        }

        It 'accepts only QuickRun from exact image-tag run discovery' {
            $tag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -IntentId $script:intentIds.api
            $script:acrDiscoveryRunType = 'QuickRun'
            Mock Get-GatewayAcrExactTagDigest {
                return [pscustomobject]@{ tag = $tag; digest = "sha256:$('1' * 64)" }
            }
            Mock Invoke-BootstrapCommand {
                return (ConvertTo-Json -InputObject @([ordered]@{
                    runId = 'run-api'
                    status = 'Succeeded'
                    runType = $script:acrDiscoveryRunType
                    outputImages = @([ordered]@{
                        repository = 'gateway-api'
                        tag = $tag
                        digest = "sha256:$('1' * 64)"
                        providerOutput = 'private-provider-body-marker'
                    })
                }) -Depth 10 -Compress)
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
                    $_.Exception.Message | Should -Not -Match 'private-provider-body-marker'
                }
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

        It 'accepts only the queued QuickRun contract returned by az acr build' {
            $validRun = [pscustomobject]@{
                runId = 'run-api'
                status = 'Queued'
                runType = 'QuickRun'
                outputImages = @()
            }
            Assert-GatewayAcrQueuedRunContract `
                -Run $validRun `
                -Repository 'gateway-api' `
                -Tag (Get-BootstrapImageBuildIntentTag `
                    -DeploymentOwnershipId $script:ownershipId `
                    -SourceFingerprint $script:sourceFingerprint `
                    -IntentId $script:intentIds.api) |
                Should -BeExactly 'run-api'

            foreach ($unsupportedRunType in @('QuickBuild', 'AutoBuild', 'AutoRun')) {
                $invalidRun = [pscustomobject]@{
                    runId = 'run-api'
                    status = 'Queued'
                    runType = $unsupportedRunType
                    outputImages = @([pscustomobject]@{
                        providerOutput = 'private-provider-body-marker'
                    })
                }
                try {
                    Assert-GatewayAcrQueuedRunContract `
                        -Run $invalidRun `
                        -Repository 'gateway-api' `
                        -Tag $script:expectedTag
                    throw 'Expected the non-QuickRun submission contract to fail closed.'
                }
                catch {
                    $_.Exception.Message | Should -BeExactly 'The submitted ACR build did not return one canonical queued QuickRun contract.'
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
                return [pscustomobject]@{
                    runId = $RunId; status = 'Succeeded'; runType = 'QuickRun'
                    outputImages = @([pscustomobject]@{
                        repository = $Repository; tag = $Tag; digest = $script:digestByRepository[$Repository]
                    })
                }
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                $script:buildArguments += ,@($Arguments)
                $imageIndex = [Array]::IndexOf($Arguments, '--image')
                $imageParts = $Arguments[$imageIndex + 1].Split(':')
                $script:submittedRepositories += $imageParts[0]
                return [pscustomobject]@{ runId = "run-$($imageParts[0])"; status = 'Queued'; runType = 'QuickRun'; outputImages = @() }
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
            Should -Invoke Invoke-AzJson -Times 3 -Exactly
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
                $arguments | Should -Contain '--no-wait'
            }
        }

        It 'stops after one submitted build when the provider returns a non-QuickRun contract' {
            $context = Join-Path $TestDrive 'acr-context-invalid-run-type'
            New-Item -ItemType Directory -Path $context -Force | Out-Null
            $script:invalidRunTypeCheckpoints = @()
            Mock New-GatewayAcrBuildContext { return $context }
            Mock Get-GatewayAcrExactTagDigest { return $null }
            Mock Get-GatewayAcrExactImageRuns { return @() }
            Mock Invoke-AzJson {
                return [pscustomobject]@{
                    runId = 'run-api'
                    status = 'Queued'
                    runType = 'QuickBuild'
                    outputImages = @([pscustomobject]@{
                        providerOutput = 'private-provider-body-marker'
                    })
                }
            }

            try {
                Build-GatewayImages `
                    -Config ([pscustomobject]@{}) `
                    -AcrLoginServer 'acrsafe.azurecr.io' `
                    -SourceFingerprint $script:sourceFingerprint `
                    -DeploymentOwnershipId $script:ownershipId `
                    -Checkpoint {
                        param($evidence)
                        $script:invalidRunTypeCheckpoints += [string]$evidence.buildIntents.api.state
                    }
                throw 'Expected the non-QuickRun submission contract to fail closed.'
            }
            catch {
                $_.Exception.Message | Should -BeExactly 'The submitted ACR build did not return one canonical queued QuickRun contract.'
                $_.Exception.Message | Should -Not -Match 'private-provider-body-marker'
            }

            $script:invalidRunTypeCheckpoints | Should -Be @('IntentRecorded')
            Should -Invoke Invoke-AzJson -Times 1 -Exactly
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
                param([string[]]$Arguments)
                $imageIndex = [Array]::IndexOf($Arguments, '--image')
                $imageParts = $Arguments[$imageIndex + 1].Split(':')
                $script:submittedRepositories += $imageParts[0]
                return [pscustomobject]@{ runId = "run-$($imageParts[0])"; status = 'Queued'; runType = 'QuickRun'; outputImages = @() }
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
