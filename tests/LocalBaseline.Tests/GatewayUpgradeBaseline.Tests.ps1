BeforeAll {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'operations\GatewayUpgrade.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'The real upgrade baseline helpers must parse.' }
    $names = @(
        'Assert-GatewayUpgradeShape', 'Assert-GatewayUpgradeHash', 'Assert-GatewayUpgradeGuid',
        'Assert-GatewayUpgradeRequest', 'Read-GatewayUpgradeBaselineInputs', 'Assert-GatewayUpgradeFullBaseline',
        'ConvertTo-GatewayUpgradeCanonical', 'ConvertTo-GatewayUpgradeCanonicalJson',
        'Get-GatewayUpgradeFingerprint', 'Get-GatewayUpgradeFileHash', 'Read-GatewayUpgradeJson',
        'ConvertFrom-GatewayUpgradeJsonElement', 'Get-GatewayUpgradeAdminUiPredecessorBinding',
        'Invoke-GatewayUpgradeCanonicalVerifierCore', 'Invoke-GatewayUpgradeBaselineProcess',
        'Resolve-GatewayUpgradeFile', 'Get-GatewayUpgradeBaselineFailureContext'
    )
    $definitions = foreach ($name in $names) {
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $false)
        if ($null -eq $definition) { throw "Missing real upgrade helper: $name" }
        $definition.Extent.Text
    }
    $steps = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -ceq '$script:RequiredSteps'
    }, $false)
    if ($null -eq $steps) { throw 'The real required bootstrap stage set is missing.' }
    $common = Import-Module (Join-Path $root 'bootstrap\modules\Common.psm1') -PassThru -NoClobber -DisableNameChecking
    $configFingerprint = $common.ExportedCommands['Get-BootstrapConfigurationFingerprint']
    $baselineModule = New-Module -Name "UpgradeBaselineFixture_$([guid]::NewGuid().ToString('N'))" `
        -ArgumentList ($definitions -join "`n"), $steps.Extent.Text, $root -ScriptBlock {
        param($definitions, $steps, $root)
        Set-StrictMode -Version Latest
        $script:ToolingRoot = $root
        . ([scriptblock]::Create($steps))
        . ([scriptblock]::Create($definitions))
        function Initialize-GatewayUpgradeVerifier { throw 'Live verifier initialization is forbidden.' }
        function Get-BootstrapExecutionSourceRoot { throw 'Unscripted source context is forbidden.' }
        function Set-BootstrapExecutionSourceRoot { param($Path) throw 'Unscripted source context is forbidden.' }
        function Set-BootstrapAzureSubscriptionContext { param($SubscriptionId, $TenantId) throw 'Ambient Azure context is forbidden.' }
        function Clear-BootstrapAzureSubscriptionContext { throw 'Ambient Azure context is forbidden.' }
        function Resolve-BootstrapAcceptedSourceRoot { param($State) throw 'Ambient original-source lookup is forbidden.' }
        function Assert-BootstrapAzureContext { param($Config) throw 'Live Azure access is forbidden.' }
        function Get-GatewayUpgradeAdminUiPredecessor { param($Inputs) throw 'Live predecessor lookup is forbidden.' }
        function Test-GatewayBootstrapDeployment {
            param($Config, $State, $DeploymentOwnershipId, $NonInteractive,
                $Foundation, $Identity, $Blueprint, $Runtime, $Database, $SqlPrivateEndpoint,
                $AdminUi, $Images, $AdminIdentity, $AdminCredential, $AdminUiPredecessor, $AcceptedExecutorPlanSku)
            throw 'Live bootstrap verification is forbidden.'
        }
        Export-ModuleMember -Function Assert-GatewayUpgradeRequest, Read-GatewayUpgradeBaselineInputs,
            Invoke-GatewayUpgradeCanonicalVerifierCore, Get-GatewayUpgradeFingerprint,
            Get-GatewayUpgradeAdminUiPredecessorBinding, Invoke-GatewayUpgradeBaselineProcess
    }
    $baselineModule | Import-Module -NoClobber -DisableNameChecking
    $admitRequest = $baselineModule.ExportedCommands['Assert-GatewayUpgradeRequest']
    $readInputs = $baselineModule.ExportedCommands['Read-GatewayUpgradeBaselineInputs']
    $verifyCore = $baselineModule.ExportedCommands['Invoke-GatewayUpgradeCanonicalVerifierCore']
    $hashObject = $baselineModule.ExportedCommands['Get-GatewayUpgradeFingerprint']
    $runBaselineProcess = $baselineModule.ExportedCommands['Invoke-GatewayUpgradeBaselineProcess']

    $executorAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'bootstrap\modules\PurviewExecutor.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'The actual hosting verifier must parse.' }
    $hostingDefinitions = foreach ($functionName in @(
        'Get-PurviewExecutorExpectedPlanSku', 'Assert-PurviewExecutorPlanBoundary',
        'Assert-PurviewExecutorHost', 'Install-BootstrapPurviewExecutor')) {
        $definition = $executorAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
        }, $false)
        if ($null -eq $definition) { throw "Missing actual hosting helper: $functionName" }
        $definition.Extent.Text
    }
    $hostingModule = New-Module -Name "ExecutorHostingFixture_$([guid]::NewGuid().ToString('N'))" `
        -ArgumentList ($hostingDefinitions -join "`n") -ScriptBlock {
        param($definitions)
        Set-StrictMode -Version Latest
        . ([scriptblock]::Create($definitions))
        function Get-PurviewExecutorArmResource { param($Id, $ApiVersion) throw 'Unscripted ARM transport is forbidden.' }
        function Assert-PurviewExecutorOwnedResource { param($Resource, $Id, $Context) throw 'Unscripted ownership readback is forbidden.' }
        function Get-PurviewExecutorFreshContext {
            param($Config, $State, $Foundation, $Runtime, $Automation, $Database)
            throw 'Unscripted provider work is forbidden.'
        }
        Export-ModuleMember -Function Assert-PurviewExecutorHost, Install-BootstrapPurviewExecutor
    }
    $hostingModule | Import-Module -NoClobber -DisableNameChecking
    $verifyHost = $hostingModule.ExportedCommands['Assert-PurviewExecutorHost']
    $installExecutor = $hostingModule.ExportedCommands['Install-BootstrapPurviewExecutor']

    $verificationAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'bootstrap\modules\Verification.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'The actual bootstrap verifier must parse.' }
    $verificationDefinition = $verificationAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-GatewayBootstrapDeployment'
    }, $false)
    if ($null -eq $verificationDefinition) { throw 'The actual bootstrap verifier is missing.' }
    $bridgeModule = New-Module -Name "HostingBridgeFixture_$([guid]::NewGuid().ToString('N'))" `
        -ArgumentList $verificationDefinition.Extent.Text -ScriptBlock {
        param($definition)
        Set-StrictMode -Version Latest
        . ([scriptblock]::Create($definition))
        function Get-BootstrapPurviewAutomationIdentityEvidence {
            param($Config, $AzureIdentity, $KeyVaultUri, $DeploymentOwnershipId, $SourceFingerprint)
            throw 'Unscripted automation transport is forbidden.'
        }
        function Get-BootstrapStatePath { param($Config) throw 'Unscripted state lookup is forbidden.' }
        function Install-BootstrapPurviewExecutor {
            param($Config, $State, $StatePath, $Foundation, $Runtime, $Automation, $Database,
                [switch]$ReadOnly, [string]$AcceptedExecutorPlanSku)
            throw 'Unscripted executor transport is forbidden.'
        }
        Export-ModuleMember -Function Test-GatewayBootstrapDeployment
    }
    $bridgeModule | Import-Module -NoClobber -DisableNameChecking
    $verifyBootstrap = $bridgeModule.ExportedCommands['Test-GatewayBootstrapDeployment']

    function Copy-FixtureObject($Value) {
        ConvertFrom-Json (ConvertTo-Json -InputObject $Value -Depth 100) -AsHashtable -Depth 100
    }

    function New-FullBaselineFixture {
        $target = @{
            subscriptionId = '22222222-2222-4222-8222-222222222222'
            tenantId = '11111111-1111-4111-8111-111111111111'
            resourceGroupName = 'rg-fixture-dev-20260924'; projectName = 'fixture'
            environment = 'dev'; location = 'koreacentral'
        }
        $config = Copy-FixtureObject $target
        $config.promptShield = @{ enabled = $true; skuName = 'S0' }
        $config.purview = @{ enabled = $true }
        $ownership = '33333333-3333-4333-8333-333333333333'
        $source = 'sha256:' + ('1' * 64)
        $plan = 'sha256:' + ('2' * 64)
        $schema = 'sha256:' + ('3' * 64)
        $configuration = & $configFingerprint -Config $config
        $binding = @{
            DeploymentOwnershipId = $ownership; TenantId = $target.tenantId
            BootstrapSourceFingerprint = $source; ExecutionSourceFingerprint = $source
            PackageDigest = 'sha256:' + ('4' * 64)
            GatewayApiPrincipalId = '44444444-4444-4444-8444-444444444444'
            GatewayWorkerPrincipalId = '55555555-5555-4555-8555-555555555555'
            ExecutorPrincipalId = '66666666-6666-4666-8666-666666666666'
            ExecutorApplicationId = '77777777-7777-4777-8777-777777777777'
            RuntimePrincipalId = '88888888-8888-4888-8888-888888888888'
            RuntimeClientId = '99999999-9999-4999-8999-999999999999'
            AutomationApplicationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            AutomationServicePrincipalObjectId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
            CallerApplicationId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
            CertificateSecretUri = 'https://synthetic.invalid/secrets/fixture'
        }
        $state = @{
            configuration = Copy-FixtureObject $target
            configurationFingerprint = $configuration; deploymentOwnershipId = $ownership
            acceptedPlan = @{ sourceFingerprint = $source; planFingerprint = $plan; configurationFingerprint = $configuration }
            steps = @{}
        }
        $required = & $baselineModule { return $script:RequiredSteps }
        foreach ($name in $required) {
            $state.steps[$name] = @{
                status = 'Completed'
                evidence = @{ deploymentOwnershipId = $ownership; sourceFingerprint = $source }
            }
        }
        $runtime = $state.steps['Gateway runtime deployment'].evidence
        $runtime.apiPrincipalId = $binding.GatewayApiPrincipalId
        $runtime.workerPrincipalId = $binding.GatewayWorkerPrincipalId
        $runtime.purviewRuntimeIdentityPrincipalId = $binding.RuntimePrincipalId
        $runtime.purviewRuntimeIdentityClientId = $binding.RuntimeClientId
        $runtime.promptShieldAccountId = '/synthetic/content-safety'
        $runtime.promptShieldEndpoint = 'https://synthetic.invalid/'
        $database = $state.steps['Gateway database'].evidence
        $database.schemaFingerprint = $schema
        $database.workerPrincipalClientId = $binding.CallerApplicationId
        $capabilities = $state.steps['Purview capability prerequisites'].evidence
        $capabilities.enabled = $true
        $capabilities.promptShields = @{
            status = 'Installed'; contentSafetyAccountResourceId = $runtime.promptShieldAccountId
            contentSafetyEndpoint = $runtime.promptShieldEndpoint
        }
        $capabilities.purview = @{
            status = 'Installed'; automationApplicationId = $binding.AutomationApplicationId
            automationServicePrincipalObjectId = $binding.AutomationServicePrincipalObjectId
            certificateSecretUri = $binding.CertificateSecretUri
        }
        $state.steps['End-to-end deployment verification'].evidence = @{
            deploymentVerification = 'Passed'; promptShield = 'Passed'; purviewCapability = 'Installed'
        }
        $state.steps['Admin UI deployment'].evidence.adminUiImage = 'synthetic.invalid/admin@sha256:' + ('5' * 64)
        $state.steps['Immutable workload images'].evidence.adminUi = $state.steps['Admin UI deployment'].evidence.adminUiImage
        $state.freshPurviewExecutor = @{
            schemaVersion = 1; status = 'Installed'
            context = @{
                deploymentOwnershipId = $ownership; sourceFingerprint = $source; planFingerprint = $plan
                configurationFingerprint = $configuration; tenantId = $target.tenantId
                subscriptionId = $target.subscriptionId; resourceGroupName = $target.resourceGroupName
                apiPrincipalId = $binding.GatewayApiPrincipalId; workerPrincipalId = $binding.GatewayWorkerPrincipalId
                runtimePrincipalId = $binding.RuntimePrincipalId; runtimeClientId = $binding.RuntimeClientId
            }
            host = @{
                executorPlanSku = @{ value = 'B2' }; executorBinding = @{ value = $binding }
                executorPrincipalId = @{ value = $binding.ExecutorPrincipalId }
            }
            package = @{ receipt = @{ sourceFingerprint = $source; packageDigest = $binding.PackageDigest } }
            identity = @{ applicationId = $binding.ExecutorApplicationId }
            operations = @{}
        }
        foreach ($name in @('application', 'audience', 'principal', 'invokeRole', 'publisherImage', 'publish',
            'a365gw-fixture-executor-host-dev', 'a365gw-fixture-executor-publisher-dev', 'a365gw-fixture-executor-enable-dev')) {
            $state.freshPurviewExecutor.operations[$name] = @{
                status = 'Completed'; intentFingerprint = $plan; evidenceFingerprint = $source
            }
        }
        $request = @{
            schemaVersion = 2; mode = 'SourceOnlyFull'; releaseId = 'fixture-release'
            target = Copy-FixtureObject $target
            capabilities = @{
                promptShields = @{ enabled = $true; sku = 'S0'; acceptPaidUsage = $true }
                purview = @{ enabled = $true; executorSku = 'B2'; acceptPaidHosting = $true }
            }
            images = @{ api = ''; worker = ''; adminUi = ''; databaseMigrator = '' }
            database = @{
                name = 'GatewayDb'; currentSchemaFingerprint = $schema; targetSchemaFingerprint = $schema
                targetModelFingerprint = $source; scripts = @(); rollbackStrategy = 'RetainExpandedSchema'
            }
            acknowledgeHistoricalVerificationFailure = $false
        }
        $request.target.deploymentOwnershipId = $ownership
        return @{ state = $state; config = $config; request = $request }
    }
}

AfterAll {
    if ($bridgeModule) { Remove-Module -ModuleInfo $bridgeModule -Force }
    if ($hostingModule) { Remove-Module -ModuleInfo $hostingModule -Force }
    if ($baselineModule) { Remove-Module -ModuleInfo $baselineModule -Force }
}

Describe 'Exact accepted custom target for source-only Full maintenance' {
    BeforeEach {
        $fixture = New-FullBaselineFixture
        $statePath = Join-Path $TestDrive 'original-state.json'
        $configPath = Join-Path $TestDrive 'original-config.json'
        [IO.File]::WriteAllText($statePath, (ConvertTo-Json $fixture.state -Depth 100))
        [IO.File]::WriteAllText($configPath, (ConvertTo-Json $fixture.config -Depth 100))
        $stateHash = (Get-FileHash -LiteralPath $statePath).Hash
        $configHash = (Get-FileHash -LiteralPath $configPath).Hash
    }

    AfterEach {
        (Get-FileHash -LiteralPath $statePath).Hash | Should -BeExactly $stateHash
        (Get-FileHash -LiteralPath $configPath).Hash | Should -BeExactly $configHash
    }

    It 'accepts the valid original custom name with unchanged Full configuration and evidence' {
        $inputs = & $readInputs -StatePath $statePath -ConfigPath $configPath -Request $fixture.request
        $inputs.state.configuration.resourceGroupName | Should -BeExactly 'rg-fixture-dev-20260924'
        $inputs.stateSha256 | Should -BeExactly "sha256:$($stateHash.ToLowerInvariant())"
        $inputs.configSha256 | Should -BeExactly "sha256:$($configHash.ToLowerInvariant())"
        $inputs.Contains('acceptedExecutorPlanSku') | Should -BeFalse
    }

    It 'accepts an explicitly reviewed existing B1 allocation without changing the historical B2 inputs' {
        $originalRequestHash = & $hashObject $fixture.request
        $fixture.request.capabilities.purview.executorSku = 'B1'
        $fixture.request.capabilities.purview.acceptExistingSkuChange = $true
        $inputs = & $readInputs -StatePath $statePath -ConfigPath $configPath -Request $fixture.request
        $inputs.acceptedExecutorPlanSku | Should -BeExactly 'B1'
        $inputs.state.freshPurviewExecutor.host.executorPlanSku.value | Should -BeExactly 'B2'
        (& $hashObject $fixture.request) | Should -Not -BeExactly $originalRequestHash
    }

    It 'rejects a non-explicit hosting-change acknowledgment: <Label>' -ForEach @(
        @{ Label = 'false'; Value = $false }
        @{ Label = 'string'; Value = 'true' }
        @{ Label = 'number'; Value = 1 }
        @{ Label = 'null'; Value = $null }
    ) {
        $fixture.request.capabilities.purview.executorSku = 'B1'
        $fixture.request.capabilities.purview.acceptExistingSkuChange = $Value
        { & $readInputs -StatePath $statePath -ConfigPath $configPath -Request $fixture.request } |
            Should -Throw '*explicit true acceptance*'
    }

    It 'does not acknowledge a nonexistent hosting change' {
        $fixture.request.capabilities.purview.acceptExistingSkuChange = $true
        { & $readInputs -StatePath $statePath -ConfigPath $configPath -Request $fixture.request } |
            Should -Throw '*unchanged hosting must not claim a change*'
    }

    It 'does not use hosting acknowledgment to enable an unsupported SKU' {
        $fixture.request.capabilities.purview.executorSku = 'B3'
        $fixture.request.capabilities.purview.acceptExistingSkuChange = $true
        { & $readInputs -StatePath $statePath -ConfigPath $configPath -Request $fixture.request } |
            Should -Throw '*selected Windows B1/B2*'
    }

    It 'does not add hosting-drift acceptance to a v1 installation' {
        $fixture.request.schemaVersion = 1
        $fixture.request.Remove('mode')
        $fixture.request.target.resourceGroupName = 'rg-fixture-dev'
        $fixture.request.capabilities.purview.acceptExistingSkuChange = $true
        { & $admitRequest $fixture.request } | Should -Throw '*unsupported fields*'
    }

    It 'does not substitute a conventional or unrelated group for the accepted target: <Name>' -ForEach @(
        @{ Name = 'rg-fixture-dev' }
        @{ Name = 'rg-unrelated-dev-20260924' }
    ) {
        $fixture.request.target.resourceGroupName = $Name
        { & $readInputs -StatePath $statePath -ConfigPath $configPath -Request $fixture.request } |
            Should -Throw '*target mismatch*'
    }

    It 'rejects invalid resource-group syntax <Label>' -ForEach @(
        @{ Label = 'empty'; Value = '' }
        @{ Label = 'path separator'; Value = 'rg-fixture/dev' }
        @{ Label = 'trailing dot'; Value = 'rg-fixture.' }
        @{ Label = 'space'; Value = 'rg fixture' }
        @{ Label = 'overlong'; Value = ('a' * 91) }
    ) {
        $fixture.request.target.resourceGroupName = $Value
        { & $admitRequest -Request $fixture.request } | Should -Throw '*target must name*'
    }

    It 'keeps the original v1 conventional-name restriction' {
        $fixture.request.schemaVersion = 1
        $fixture.request.Remove('mode')
        { & $admitRequest -Request $fixture.request } | Should -Throw '*v1 requires*'
        $fixture.request.target.resourceGroupName = 'rg-fixture-dev'
        { & $admitRequest -Request $fixture.request } | Should -Not -Throw
    }

    It 'retains exact <Label> admission after a custom target is accepted' -ForEach @(
        @{ Label = 'ownership'; Change = { param($r) $r.target.deploymentOwnershipId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' } }
        @{ Label = 'tenant'; Change = { param($r) $r.target.tenantId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' } }
        @{ Label = 'subscription'; Change = { param($r) $r.target.subscriptionId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' } }
        @{ Label = 'installed SKU'; Change = { param($r) $r.capabilities.purview.executorSku = 'B1' } }
        @{ Label = 'unchanged schema'; Change = { param($r) $r.database.targetSchemaFingerprint = 'sha256:' + ('f' * 64) } }
    ) {
        & $Change $fixture.request
        { & $readInputs -StatePath $statePath -ConfigPath $configPath -Request $fixture.request } | Should -Throw '*Upgrade*'
    }
}

Describe 'Full canonical verification preserves original evidence and rechecks its UI predecessor' {
    BeforeEach {
        $fixture = New-FullBaselineFixture
        $originalHash = & $hashObject -Value $fixture.state
        $proof = @{
            context = @{ deploymentOwnershipId = $fixture.state.deploymentOwnershipId }
            receiptSetFingerprint = 'sha256:' + ('6' * 64)
            receiptFileName = ('7' * 64) + '.json'; receiptByteFingerprint = 'sha256:' + ('8' * 64)
            planFingerprint = 'sha256:' + ('9' * 64)
            build = @{ image = 'synthetic.invalid/admin@sha256:' + ('a' * 64) }
            upgradeSourceFingerprint = 'sha256:' + ('b' * 64)
            verification = @{
                verifiedAtUtc = '2026-09-24T00:00:00Z'
                adminUi = @{ principalId = 'fixture-principal'; secretResourceId = 'fixture-secret'; fqdn = 'synthetic.invalid'; revisionName = 'fixture--2' }
            }
        }
        $scenario = @{
            assetRoot = 'current-tooling'; after = Copy-FixtureObject $proof; before = $proof
            readCount = 0; verifyCount = 0; cleared = 0; fail = $false; acceptedSku = $null
        }
        Mock Initialize-GatewayUpgradeVerifier -ModuleName $baselineModule.Name {}
        Mock Get-BootstrapExecutionSourceRoot -ModuleName $baselineModule.Name { $scenario.assetRoot }
        Mock Set-BootstrapExecutionSourceRoot -ModuleName $baselineModule.Name { $scenario.assetRoot = $Path }
        Mock Resolve-BootstrapAcceptedSourceRoot -ModuleName $baselineModule.Name { 'verified-original-assets' }
        Mock Set-BootstrapAzureSubscriptionContext -ModuleName $baselineModule.Name {
            $SubscriptionId | Should -BeExactly $fixture.config.subscriptionId
            $TenantId | Should -BeExactly $fixture.config.tenantId
        }
        Mock Clear-BootstrapAzureSubscriptionContext -ModuleName $baselineModule.Name { $scenario.cleared++ }
        Mock Assert-BootstrapAzureContext -ModuleName $baselineModule.Name {}
        Mock Get-GatewayUpgradeAdminUiPredecessor -ModuleName $baselineModule.Name {
            $scenario.readCount++
            if ($scenario.readCount -eq 1) { return $scenario.before }
            if ($scenario.readCount -eq 2) { return $scenario.after }
            throw 'An unplanned predecessor read is forbidden.'
        }
        Mock Test-GatewayBootstrapDeployment -ModuleName $baselineModule.Name {
            param($AdminUi, $Images, $AdminUiPredecessor = $null, $AcceptedExecutorPlanSku = $null)
            $scenario.verifyCount++
            $scenario.assetRoot | Should -BeExactly 'verified-original-assets'
            $AdminUi.adminUiImage | Should -BeExactly $fixture.state.steps['Admin UI deployment'].evidence.adminUiImage
            $Images.adminUi | Should -BeExactly $AdminUi.adminUiImage
            if ($scenario.before) { $AdminUiPredecessor.build.image | Should -BeExactly $proof.build.image }
            else { $AdminUiPredecessor | Should -BeNullOrEmpty }
            $AcceptedExecutorPlanSku | Should -BeExactly $scenario.acceptedSku
            if ($scenario.fail) { throw 'Synthetic complete verifier failure.' }
            return @{
                deploymentVerification = 'Passed'; azureRbac = 'Passed'; sqlPrivateEndpoint = 'Passed'
                adminUiIdentity = 'Passed'; adminUiCredential = 'Passed'; provisioningAdmissionReady = $true
            }
        }
    }

    AfterEach {
        (& $hashObject -Value $fixture.state) | Should -BeExactly $originalHash
        $scenario.assetRoot | Should -BeExactly 'current-tooling'
        $scenario.cleared | Should -Be 1
    }

    It 'keeps original image evidence and binds the independently reverified promoted UI separately' {
        $scenario.after.verification.verifiedAtUtc = '2026-09-24T00:10:00Z'
        $result = & $verifyCore -Inputs $fixture
        $result.adminUiPredecessor.receiptByteFingerprint | Should -BeExactly $proof.receiptByteFingerprint
        $result.adminUiPredecessor.verification.verifiedAtUtc | Should -BeExactly $scenario.after.verification.verifiedAtUtc
        $scenario.readCount | Should -Be 2
        $scenario.verifyCount | Should -Be 1
    }

    It 'preserves the original, never-promoted Full baseline path' {
        $scenario.before = $null
        $scenario.after = $null
        $result = & $verifyCore -Inputs $fixture
        $result.Contains('adminUiPredecessor') | Should -BeFalse
        $scenario.readCount | Should -Be 2
    }

    It 'forwards the accepted existing SKU while separately retaining its original B2 history' {
        $fixture['acceptedExecutorPlanSku'] = 'B1'
        $scenario.acceptedSku = 'B1'
        $result = & $verifyCore -Inputs $fixture
        $result.executorHostingSelection.originalSku | Should -BeExactly 'B2'
        $result.executorHostingSelection.currentSku | Should -BeExactly 'B1'
        $result.executorHostingSelection.capacity | Should -Be 1
        $result.executorHostingSelection.disposition | Should -BeExactly 'AcceptedExistingAllocation;NoHostingMutation'
        $scenario.verifyCount | Should -Be 1
    }

    It 'rejects <Label> drift during the complete verification' -ForEach @(
        @{ Label = 'receipt bytes'; Change = { param($p) $p.receiptByteFingerprint = 'sha256:' + ('c' * 64) } }
        @{ Label = 'receipt set'; Change = { param($p) $p.receiptSetFingerprint = 'sha256:' + ('c' * 64) } }
        @{ Label = 'image'; Change = { param($p) $p.build.image = 'synthetic.invalid/admin@sha256:' + ('c' * 64) } }
        @{ Label = 'revision'; Change = { param($p) $p.verification.adminUi.revisionName = 'fixture--3' } }
        @{ Label = 'identity'; Change = { param($p) $p.verification.adminUi.principalId = 'changed-principal' } }
        @{ Label = 'secret'; Change = { param($p) $p.verification.adminUi.secretResourceId = 'changed-secret' } }
        @{ Label = 'owner'; Change = { param($p) $p.context.deploymentOwnershipId = 'changed-owner' } }
    ) {
        & $Change $scenario.after
        { & $verifyCore -Inputs $fixture } | Should -Throw '*canonical read-only verification failed*'
        $scenario.readCount | Should -Be 2
    }

    It 'rejects a promotion that starts during original-baseline verification' {
        $scenario.before = $null
        { & $verifyCore -Inputs $fixture } | Should -Throw '*canonical read-only verification failed*'
    }

    It 'restores source and Azure contexts on complete-verifier failure without accepting the predecessor' {
        $scenario.fail = $true
        { & $verifyCore -Inputs $fixture } | Should -Throw '*canonical read-only verification failed*'
        $scenario.readCount | Should -Be 1
    }
}

Describe 'Isolated baseline failure diagnostics preserve safe source context' {
    BeforeAll {
        $processRoot = Join-Path $TestDrive 'baseline-process'
        $operations = New-Item -ItemType Directory -Path (Join-Path $processRoot 'operations')
        $childPath = Join-Path $operations.FullName 'gateway-upgrade-baseline.ps1'
        $modules = New-Item -ItemType Directory -Path (Join-Path $processRoot 'bootstrap\modules')
        [IO.File]::WriteAllText((Join-Path $modules.FullName 'Common.psm1'), '', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $modules.FullName 'Verification.psm1'), '', [Text.UTF8Encoding]::new($false))
        $childSource = @'
[CmdletBinding()]
param($StatePath, $ConfigPath, $ExpectedStateSha256, $ExpectedConfigSha256, $AcceptedExecutorPlanSku)
$root = Split-Path $PSScriptRoot -Parent
$common = Join-Path $root 'bootstrap\modules\Common.psm1'
$verification = Join-Path $root 'bootstrap\modules\Verification.psm1'
if ($StatePath -ne 'success') {
    [Console]::Out.WriteLine('synthetic-provider-body-canary')
    [Console]::Error.WriteLine('synthetic-credential-canary')
    $label = if ($StatePath -eq 'localized') { [char]0xC904 } else { 'line' }
    $separator = if ($StatePath -eq 'localized') { [string][char]0xC5D0 + [char]0xC11C + ' ' } else { ', ' }
    Write-Verbose ("Verifier failure type: InvalidOperationException; source stack: Invoke-BootstrapCommand{0}{1}: {2} 994`nTest-GatewayBootstrapDeployment{0}{3}: {2} 432" -f $separator, $common, $label, $verification)
}
$result = @{
    status = 'Passed'; verifiedAtUtc = '2026-09-24T00:00:00Z'
    verifierResultFingerprint = 'sha256:1111111111111111111111111111111111111111111111111111111111111111'
}
if ($AcceptedExecutorPlanSku -and $ConfigPath -ne 'omit-sku') {
    $result.acceptedExecutorPlanSku = if ($ConfigPath -eq 'wrong-sku') { 'B2' } else { $AcceptedExecutorPlanSku }
}
[Console]::Out.WriteLine('A365GW_UPGRADE_BASELINE:' + (ConvertTo-Json $result -Compress))
if ($StatePath -ne 'success') { exit 1 }
'@
        [IO.File]::WriteAllText($childPath, $childSource, [Text.UTF8Encoding]::new($false))
    }

    BeforeEach {
        & $baselineModule { param($root) $script:ToolingRoot = $root } $processRoot
        $processInputs = @{
            statePath = 'success'; configPath = 'synthetic-unused'
            stateSha256 = 'sha256:' + ('1' * 64); configSha256 = 'sha256:' + ('2' * 64)
        }
    }

    AfterEach {
        & $baselineModule { param($root) $script:ToolingRoot = $root } $root
    }

    It 'keeps the exact successful child result contract' {
        $result = & $runBaselineProcess -Inputs $processInputs -TimeoutSeconds 30
        $result.status | Should -BeExactly 'Passed'
        $result.verifierResultFingerprint | Should -BeExactly ('sha256:' + ('1' * 64))
    }

    It 'passes and verifies the selected B1 across the actual process argument boundary' {
        $processInputs['acceptedExecutorPlanSku'] = 'B1'
        $result = & $runBaselineProcess -Inputs $processInputs -TimeoutSeconds 30
        $result.acceptedExecutorPlanSku | Should -BeExactly 'B1'
    }

    It 'rejects an unproven selected SKU from the isolated verifier: <_>' -ForEach @('omit-sku', 'wrong-sku') {
        $processInputs['acceptedExecutorPlanSku'] = 'B1'
        $processInputs.configPath = $_
        { & $runBaselineProcess -Inputs $processInputs -TimeoutSeconds 30 } | Should -Throw '*Upgrade*'
    }

    It 'retains trusted source locations on <_> failure without forwarding provider bodies or accepting a spoofed success' -ForEach @('english', 'localized') {
        $processInputs.statePath = $_
        $failure = $null
        try { & $runBaselineProcess -Inputs $processInputs -TimeoutSeconds 30 }
        catch { $failure = $_ }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Exception.Message | Should -Match 'Common\.psm1:994'
        $failure.Exception.Message | Should -Match 'Verification\.psm1:432'
        $failure.Exception.Message | Should -Not -Match 'synthetic-provider-body-canary|synthetic-credential-canary'
        $failure.Exception.Message | Should -Not -Match ([regex]::Escape($processRoot))
    }

    It 'suppresses unusable diagnostic context: <_>' -ForEach @(
        'missing marker', 'overlong', 'invalid type', 'unknown file', 'sibling root',
        'traversal', 'zero line', 'overlong line'
    ) {
        $prefix = 'Verifier failure type: InvalidOperationException; source stack: '
        $common = Join-Path $processRoot 'bootstrap\modules\Common.psm1'
        $trace = switch ($_) {
            'missing marker' { 'synthetic-private-prose' }
            'overlong' { $prefix + ('x' * 32769) }
            'invalid type' { "Verifier failure type: synthetic-private-prose; source stack: $($common): line 994" }
            'unknown file' { $prefix + (Join-Path $processRoot 'bootstrap\synthetic-private-prose.psm1') + ': line 994' }
            'sibling root' { $prefix + (Join-Path "$processRoot-sibling" 'bootstrap\modules\Common.psm1') + ': line 994' }
            'traversal' { $prefix + (Join-Path $processRoot 'bootstrap\..\operations\gateway-upgrade-baseline.ps1') + ': line 994' }
            'zero line' { "$prefix$($common): line 0" }
            'overlong line' { "$prefix$($common): line 1000000" }
        }
        $context = & $baselineModule {
            param($trace, $root)
            Get-GatewayUpgradeBaselineFailureContext -Output $trace -SourceRoot $root
        } $trace $processRoot
        $context | Should -BeNullOrEmpty
    }

    It 'bounds retained locations even when the child reports a longer source stack' {
        $common = Join-Path $processRoot 'bootstrap\modules\Common.psm1'
        $trace = 'Verifier failure type: InvalidOperationException; source stack: ' +
            ((1000..1020 | ForEach-Object { "$($common): line $_" }) -join "`n")
        $context = & $baselineModule {
            param($trace, $root)
            Get-GatewayUpgradeBaselineFailureContext -Output $trace -SourceRoot $root
        } $trace $processRoot
        [regex]::Matches($context, 'Common\.psm1:').Count | Should -Be 12
        $context | Should -Match 'Common\.psm1:1011'
        $context | Should -Not -Match 'Common\.psm1:1012'
    }
}

Describe 'Actual baseline entry point diagnostics' {
    It 'retains failures from the actual module-scoped verifier child' {
        $processRoot = Join-Path $TestDrive 'actual-baseline-child'
        $operations = Join-Path $processRoot 'operations'
        [IO.Directory]::CreateDirectory($operations) | Out-Null
        [IO.File]::Copy((Join-Path $root 'operations\gateway-upgrade-baseline.ps1'),
            (Join-Path $operations 'gateway-upgrade-baseline.ps1'))
        $stubs = @'
function Initialize-GatewayUpgradeVerifier { }
function Get-BootstrapExecutionSourceRoot { return $null }
function Set-BootstrapExecutionSourceRoot { param($Path) }
function Set-BootstrapAzureSubscriptionContext { param($SubscriptionId, $TenantId) }
function Clear-BootstrapAzureSubscriptionContext { }
function Assert-BootstrapAzureContext { param($Config) }
function Test-GatewayBootstrapDeployment {
    param($Config, $State, $DeploymentOwnershipId, $NonInteractive,
        $Foundation, $Identity, $Blueprint, $Runtime, $Database, $SqlPrivateEndpoint,
        $AdminUi, $Images, $AdminIdentity, $AdminCredential)
    throw [InvalidOperationException]::new('synthetic-provider-body-canary')
}
'@
        [IO.File]::WriteAllText((Join-Path $operations 'GatewayUpgrade.psm1'),
            "Set-StrictMode -Version Latest`n" + ($definitions -join "`n") + "`n" + $stubs,
            [Text.UTF8Encoding]::new($false))
        $fixture = New-FullBaselineFixture
        $fixture.state.Remove('freshPurviewExecutor')
        $statePath = Join-Path $processRoot 'state.json'
        $configPath = Join-Path $processRoot 'config.json'
        [IO.File]::WriteAllText($statePath, (ConvertTo-Json $fixture.state -Depth 100))
        [IO.File]::WriteAllText($configPath, (ConvertTo-Json $fixture.config -Depth 100))
        $inputs = @{
            statePath = $statePath; configPath = $configPath
            stateSha256 = 'sha256:' + (Get-FileHash -LiteralPath $statePath).Hash.ToLowerInvariant()
            configSha256 = 'sha256:' + (Get-FileHash -LiteralPath $configPath).Hash.ToLowerInvariant()
        }
        $failure = $null
        try {
            & $baselineModule { param($root) $script:ToolingRoot = $root } $processRoot
            try { & $runBaselineProcess -Inputs $inputs -TimeoutSeconds 30 }
            catch { $failure = $_ }
        }
        finally {
            & $baselineModule { param($root) $script:ToolingRoot = $root } $root
        }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Exception.Message | Should -Match 'Verifier type: InvalidOperationException'
        $failure.Exception.Message | Should -Match 'operations[\\/]GatewayUpgrade\.psm1:[1-9][0-9]*'
        $failure.Exception.Message | Should -Not -Match 'synthetic-provider-body-canary'
        $failure.Exception.Message | Should -Not -Match ([regex]::Escape($processRoot))
        ('sha256:' + (Get-FileHash -LiteralPath $statePath).Hash.ToLowerInvariant()) | Should -BeExactly $inputs.stateSha256
        ('sha256:' + (Get-FileHash -LiteralPath $configPath).Hash.ToLowerInvariant()) | Should -BeExactly $inputs.configSha256
    }
}

Describe 'Actual executor host readback uses only the explicitly selected existing allocation' {
    BeforeEach {
        $fixture = New-FullBaselineFixture
        $config = $fixture.config
        $baseId = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)/providers"
        $planId = "$baseId/Microsoft.Web/serverfarms/asp-fixture-dev-purview"
        $siteId = "$baseId/Microsoft.Web/sites/fixture-executor"
        $subnetId = "$baseId/Microsoft.Network/virtualNetworks/fixture/subnets/executor"
        $source = $fixture.state.acceptedPlan.sourceFingerprint
        $principal = '66666666-6666-4666-8666-666666666666'
        $record = @{
            context = @{ sourceFingerprint = $source }
            host = @{
                executorId = @{ value = $siteId }; executorPrincipalId = @{ value = $principal }
                executorPlanSku = @{ value = 'B2' }; executorBinding = @{ value = @{} }
                executorEndpoint = @{ value = 'https://synthetic.invalid' }
                integrationSubnetId = @{ value = $subnetId }
            }
        }
        $recordHash = & $hashObject $record
        $scenario = @{
            reachedSubnet = $false
            site = @{
                id = $siteId; tags = @{ purviewExecutionSourceFingerprint = $source }
                identity = @{ type = 'SystemAssigned'; principalId = $principal }
                properties = @{
                    serverFarmId = $planId; publicNetworkAccess = 'Disabled'; httpsOnly = $true
                    enabled = $true; virtualNetworkSubnetId = $subnetId; defaultHostName = 'synthetic.invalid'
                    outboundVnetRouting = @{ allTraffic = $true }
                }
            }
            plan = @{ id = $planId; sku = @{ name = 'B1'; capacity = 1 }; properties = @{ reserved = $false } }
        }
        Mock Get-PurviewExecutorArmResource -ModuleName $hostingModule.Name {
            param($Id, $ApiVersion)
            if ($Id -ceq $siteId) { return $scenario.site }
            if ($Id -ceq $planId) { return $scenario.plan }
            if ($Id -ceq $subnetId) {
                $scenario.reachedSubnet = $true
                throw 'SyntheticHostBoundaryReached'
            }
            throw 'Unscripted ARM resource is forbidden.'
        }
        Mock Assert-PurviewExecutorOwnedResource -ModuleName $hostingModule.Name {
            param($Resource, $Id, $Context)
            $Resource.id | Should -BeExactly $Id
            $Context.sourceFingerprint | Should -BeExactly $source
        }
    }

    AfterEach {
        (& $hashObject $record) | Should -BeExactly $recordHash
    }

    It 'accepts explicitly selected B1 without replacing the B2 host receipt' {
        { & $verifyHost -Config $config -Foundation @{} -Record $record -Enabled -AcceptedExecutorPlanSku B1 } |
            Should -Throw '*SyntheticHostBoundaryReached*'
        $scenario.reachedSubnet | Should -BeTrue
        $record.host.executorPlanSku.value | Should -BeExactly 'B2'
    }

    It 'continues to reject unacknowledged B2-to-B1 drift' {
        { & $verifyHost -Config $config -Foundation @{} -Record $record -Enabled } |
            Should -Throw '*selected owned one-worker Windows plan*'
        $scenario.reachedSubnet | Should -BeFalse
    }

    It 'preserves ordinary original B2 verification without an override' {
        $scenario.plan.sku.name = 'B2'
        { & $verifyHost -Config $config -Foundation @{} -Record $record -Enabled } |
            Should -Throw '*SyntheticHostBoundaryReached*'
        $scenario.reachedSubnet | Should -BeTrue
    }

    It 'retains the <Label> boundary after accepting B1' -ForEach @(
        @{ Label = 'selected SKU'; Change = { param($s) $s.plan.sku.name = 'B2' } }
        @{ Label = 'one worker'; Change = { param($s) $s.plan.sku.capacity = 2 } }
        @{ Label = 'Windows'; Change = { param($s) $s.plan.properties.reserved = $true } }
        @{ Label = 'exact plan'; Change = { param($s) $s.site.properties.serverFarmId += '-other' } }
        @{ Label = 'private outbound routing'; Change = { param($s) $s.site.properties.outboundVnetRouting.allTraffic = $false } }
        @{ Label = 'private inbound access'; Change = { param($s) $s.site.properties.publicNetworkAccess = 'Enabled' } }
        @{ Label = 'HTTPS'; Change = { param($s) $s.site.properties.httpsOnly = $false } }
        @{ Label = 'executor identity'; Change = { param($s) $s.site.identity.principalId = 'changed' } }
        @{ Label = 'source binding'; Change = { param($s) $s.site.tags.purviewExecutionSourceFingerprint = 'changed' } }
    ) {
        & $Change $scenario
        { & $verifyHost -Config $config -Foundation @{} -Record $record -Enabled -AcceptedExecutorPlanSku B1 } |
            Should -Throw
        $scenario.reachedSubnet | Should -BeFalse
    }

    It 'does not permit the hosting selection on the mutating installer' {
        { & $installExecutor -Config $config -State $fixture.state -StatePath (Join-Path $TestDrive 'unused-state.json') `
            -Foundation @{} -Runtime @{} -Automation @{} -Database @{} -AcceptedExecutorPlanSku B1 } |
            Should -Throw '*read-only and cannot create or resize*'
    }
}

Describe 'Actual bootstrap verifier forwards hosting selection only into read-only executor verification' {
    BeforeEach {
        $fixture = New-FullBaselineFixture
        $arguments = @{
            Config = $fixture.config; State = $fixture.state
            DeploymentOwnershipId = $fixture.state.deploymentOwnershipId
            Foundation = @{}; Identity = @{}; Blueprint = @{}; Database = @{}; SqlPrivateEndpoint = @{}
            AdminUi = @{}; AdminIdentity = @{}; AdminCredential = @{}
            Runtime = @{ keyVaultUri = 'https://synthetic.invalid/' }
            Images = @{ sourceFingerprint = $fixture.state.acceptedPlan.sourceFingerprint }
        }
        $scenario = @{ selectedSku = ''; calls = 0 }
        Mock Get-BootstrapPurviewAutomationIdentityEvidence -ModuleName $bridgeModule.Name { return @{} }
        Mock Get-BootstrapStatePath -ModuleName $bridgeModule.Name { return (Join-Path $TestDrive 'unused-state.json') }
        Mock Install-BootstrapPurviewExecutor -ModuleName $bridgeModule.Name {
            param([switch]$ReadOnly, [string]$AcceptedExecutorPlanSku)
            $ReadOnly | Should -BeTrue
            $AcceptedExecutorPlanSku | Should -BeExactly $scenario.selectedSku
            $scenario.calls++
            throw 'SyntheticReadOnlyExecutorReached'
        }
    }

    It 'carries the reviewed B1 through the real bootstrap verification call' {
        $scenario.selectedSku = 'B1'
        { & $verifyBootstrap @arguments -AcceptedExecutorPlanSku B1 } |
            Should -Throw '*SyntheticReadOnlyExecutorReached*'
        $scenario.calls | Should -Be 1
    }

    It 'does not silently choose a different SKU for ordinary bootstrap verification' {
        { & $verifyBootstrap @arguments } | Should -Throw '*SyntheticReadOnlyExecutorReached*'
        $scenario.calls | Should -Be 1
    }

    It 'does not reinterpret Core as a completed Full executor installation' {
        $fixture.config.purview.enabled = $false
        { & $verifyBootstrap @arguments -AcceptedExecutorPlanSku B1 } |
            Should -Throw '*requires a completed Full executor installation*'
        $scenario.calls | Should -Be 0
    }
}
