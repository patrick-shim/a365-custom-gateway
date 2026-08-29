$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Force

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
                        runId = "run-$Repository"; status = 'Succeeded'; runType = 'QuickBuild'
                        outputImages = @([pscustomobject]@{ repository = $Repository; tag = $Tag; digest = $script:digestByRepository[$Repository] })
                    })
                }
                return @()
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                $script:buildArguments += ,@($Arguments)
                $imageIndex = [Array]::IndexOf($Arguments, '--image')
                $imageParts = $Arguments[$imageIndex + 1].Split(':')
                $script:submittedRepositories += $imageParts[0]
                return [pscustomobject]@{ runId = "run-$($imageParts[0])"; status = 'Queued'; runType = 'QuickBuild'; outputImages = @() }
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
                        runId = "run-$Repository"; status = 'Succeeded'; runType = 'QuickBuild'
                        outputImages = @([pscustomobject]@{ repository = $Repository; tag = $Tag; digest = $script:digestByRepository[$Repository] })
                    })
                }
                return @()
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                $imageIndex = [Array]::IndexOf($Arguments, '--image')
                $imageParts = $Arguments[$imageIndex + 1].Split(':')
                $script:submittedRepositories += $imageParts[0]
                return [pscustomobject]@{ runId = "run-$($imageParts[0])"; status = 'Queued'; runType = 'QuickBuild'; outputImages = @() }
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
