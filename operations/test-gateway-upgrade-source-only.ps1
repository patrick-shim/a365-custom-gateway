#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$StatePath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.bootstrap\state\6f6ae863-dcb7-456f-a7f0-d6f9887cfb76-rg-gw72130-dev-dev.json'),
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap\config.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1') -Force -PassThru
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeSqlAdmission.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeCutover.psm1') -Force
$state = Read-GatewayUpgradeJson $StatePath
$config = Read-GatewayUpgradeJson $ConfigPath
$stateHash = Get-GatewayUpgradeFileHash $StatePath
$configHash = Get-GatewayUpgradeFileHash $ConfigPath
$request = @{
    schemaVersion = 2; mode = 'SourceOnlyFull'; releaseId = 'source-only-check'
    target = @{
        subscriptionId = $config.subscriptionId; tenantId = $config.tenantId; resourceGroupName = $config.resourceGroupName
        projectName = $config.projectName; environment = $config.environment; location = $config.location
        deploymentOwnershipId = $state.deploymentOwnershipId
    }
    capabilities = @{
        promptShields = @{ enabled = $true; sku = $config.promptShield.skuName; acceptPaidUsage = ($config.promptShield.skuName -ceq 'S0') }
        purview = @{ enabled = $true; executorSku = $state.freshPurviewExecutor.host.executorPlanSku.value; acceptPaidHosting = $true }
    }
    images = @{ api = ''; worker = ''; adminUi = ''; databaseMigrator = '' }
    database = @{
        name = 'GatewayDb'; currentSchemaFingerprint = $state.steps['Gateway database'].evidence.schemaFingerprint
        targetSchemaFingerprint = $state.steps['Gateway database'].evidence.schemaFingerprint
        targetModelFingerprint = 'sha256:96ab3daee7b7e84f92729dec88a1b68db2b57a87f8d69d20ac955f3f0d3de469'
        scripts = @(); rollbackStrategy = 'RetainExpandedSchema'
    }
    acknowledgeHistoricalVerificationFailure = $false
}
$count = 0
function Assert-Test([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:count++
}
function Assert-Rejected([scriptblock]$Action, [string]$Name) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Test $rejected $Name
}
function Copy-Object($Value) { ConvertFrom-Json (ConvertTo-Json $Value -Depth 100) -AsHashtable -Depth 100 }
$inputs = & $module { param($s,$c,$r) Read-GatewayUpgradeBaselineInputs $s $c $r } $StatePath $ConfigPath $request
Assert-Test ($inputs.stateSha256 -ceq $stateHash -and $inputs.configSha256 -ceq $configHash) 'real retained inputs remain byte-bound'
$scope = & $module { param($r,$s) Get-GatewayUpgradeScope $r $s } $request $state
Assert-Test ($scope.purview.siteId -ceq $state.freshPurviewExecutor.host.executorId.value) 'exact installed executor'
Assert-Test ($scope.purview.retained.contentSafetyAccountId -ceq $state.steps['Gateway runtime deployment'].evidence.promptShieldAccountId) 'exact installed Content Safety'
Assert-Test ($scope.purview.planName -ceq "asp-$($config.projectName)-$($config.environment)-purview") 'exact installed Windows plan'
Assert-Test (@($scope.resources | Where-Object { $_.stage -cin @('ContentSafety','PurviewPrerequisites','PurviewQueue') }).Count -eq 0) 'no capability installation authority'
Assert-Test (@($scope.resources | Where-Object stage -CEQ 'PurviewExecutor').Count -eq 1) 'executor settings only'
Assert-Test (@($scope.purview.graphRoleAllowlist).Count -eq 0 -and @($scope.purview.directoryRoleAllowlist).Count -eq 0) 'no permission grants'
Add-GatewayUpgradeCutoverScope $request $scope
Assert-Test (@($scope.resources | Where-Object { $_.stage -ceq 'Cutover' -and $_.permittedChange -ceq 'ModifyReceiveStatusOnly' }).Count -eq 2) 'both original queues retain bounded receive holds'
Assert-GatewayUpgradeSqlAdmission -SourceRoot $root -Database $request.database -Mode SourceOnlyFull
Assert-Test $true 'explicit no-DDL admission'
Assert-Rejected { Assert-GatewayUpgradeSqlAdmission -SourceRoot $root -Database $request.database } 'legacy SQL still requires migrations'
foreach ($case in @(
    @{ name='unsupported mode'; change={param($r,$s,$c) $r.mode='Anything'} }
    @{ name='missing mode'; change={param($r,$s,$c) $r.Remove('mode')} }
    @{ name='partial Full'; change={param($r,$s,$c) $c.purview.enabled=$false} }
    @{ name='paid transition'; change={param($r,$s,$c) $r.capabilities.promptShields.sku='S0';$r.capabilities.promptShields.acceptPaidUsage=$true} }
    @{ name='plan resize'; change={param($r,$s,$c) $r.capabilities.purview.executorSku='B1'} }
    @{ name='unowned executor'; change={param($r,$s,$c) $s.freshPurviewExecutor.context.deploymentOwnershipId=[guid]::NewGuid().ToString('D')} }
    @{ name='changed source'; change={param($r,$s,$c) $s.freshPurviewExecutor.context.sourceFingerprint='sha256:'+('a'*64)} }
    @{ name='unfinished operation'; change={param($r,$s,$c) $s.freshPurviewExecutor.operations.application.status='Started'} }
    @{ name='unsupported recovery'; change={param($r,$s,$c) $s['manualDatabaseRepairPlan']=@{}} }
    @{ name='failed verification'; change={param($r,$s,$c) $s.steps['End-to-end deployment verification'].status='Failed'} }
    @{ name='changed endpoint'; change={param($r,$s,$c) $s.steps['Gateway runtime deployment'].evidence.promptShieldEndpoint='https://foreign.cognitiveservices.azure.com/'} }
    @{ name='changed identity'; change={param($r,$s,$c) $s.freshPurviewExecutor.host.executorBinding.value.ExecutorPrincipalId=[guid]::NewGuid().ToString('D')} }
    @{ name='changed certificate'; change={param($r,$s,$c) $s.freshPurviewExecutor.host.executorBinding.value.CertificateSecretUri+='-foreign'} }
    @{ name='changed physical schema'; change={param($r,$s,$c) $r.database.targetSchemaFingerprint='sha256:'+('b'*64)} }
    @{ name='missing model'; change={param($r,$s,$c) $r.database.Remove('targetModelFingerprint')} }
)) {
    $r=Copy-Object $request; $s=Copy-Object $state; $c=Copy-Object $config
    & $case.change $r $s $c
    Assert-Rejected { & $module { param($r,$s,$c) Assert-GatewayUpgradeRequest $r; Assert-GatewayUpgradeFullBaseline $r $s $c } $r $s $c } $case.name
}
$legacy = Copy-Object $request
$legacy.schemaVersion=1; $legacy.Remove('mode'); $legacy.capabilities.promptShields.sku='S0';$legacy.capabilities.promptShields.acceptPaidUsage=$true
& $module { param($r) Assert-GatewayUpgradeRequest $r } $legacy
$legacyScope = & $module { param($r,$s) Get-GatewayUpgradeScope $r $s } $legacy $state
Assert-Test (@($legacyScope.resources | Where-Object stage -CEQ 'ContentSafety').Count -eq 2) 'legacy capability installation route retained'
Assert-Rejected { & $module {param($s,$c,$r) Read-GatewayUpgradeBaselineInputs $s $c $r} $StatePath $ConfigPath $legacy } 'v1 still rejects Full baseline'
$output = Join-Path $root '.maintenance\local-source-only-validation'
[IO.Directory]::CreateDirectory($output) | Out-Null
$path = Join-Path $output "request-$([guid]::NewGuid().ToString('N')).json"
[IO.File]::WriteAllText($path, (ConvertTo-Json $request -Depth 100))
$local = & (Join-Path $PSScriptRoot 'gateway-upgrade.ps1') -Mode ValidateRequest -StatePath $StatePath -ConfigPath $ConfigPath -RequestPath $path
Assert-Test ($local.status -ceq 'LocalRequestValidated' -and -not $local.liveBaselineVerified -and -not $local.buildSupported -and -not $local.executionSupported) 'local validation cannot fabricate live proof or approval'
Assert-Test ((Get-GatewayUpgradeFileHash $StatePath) -ceq $stateHash -and (Get-GatewayUpgradeFileHash $ConfigPath) -ceq $configHash) 'original files unchanged'
$execution = Get-Module GatewayUpgradeExecution
foreach ($action in @('content-safety', 'protection-queue', 'purview-certificate', 'executor-identity', 'executor-host', 'executor-enable')) {
    Assert-Rejected { & $execution {param($r,$a) Assert-GatewayUpgradeExecutionAuthority @{plan=@{request=$r}} $a} $request $action } "source-only forbids $action"
}
$executionChecks = & $execution {
    param($state, $config, $request, $scope)
    $script:fixture = @{
        saved = @{ WEBSITE_RUN_FROM_PACKAGE='original.zip'; Executor__RuntimeManifestDigest='sha256:'+('1'*64)
            Executor__Binding__ExecutionSourceFingerprint=$state.acceptedPlan.sourceFingerprint
            Executor__Binding__PackageDigest=$state.freshPurviewExecutor.package.receipt.packageDigest
            PreservedSetting='unchanged' }
        writes = 0; corrupt = $false; captured = $null
    }
    $script:fixture.current = $script:fixture.saved
    function script:Get-GatewayUpgradeSourceOnlyEvidence { param($Context,$Name,$Value,[switch]$ReadOnly) return $script:fixture.saved }
    function script:Get-GatewayUpgradeSourceOnlyCapabilities { param($Context,[switch]$ReadOnly) return @{} }
    function script:Read-GatewayUpgradeExecutionRecord { param($Context,$Action,$Phase) return $null }
    function script:Invoke-GatewayUpgradeArm {
        param($Context,$Method,$ResourceId,$ApiVersion,$Body)
        if ($Method -cne 'POST' -or $ResourceId -cne "$($Context.plan.scope.purview.siteId)/config/appsettings/list") {
            throw 'Fixture forbids any unmodeled provider operation.'
        }
        $properties = ConvertFrom-Json (ConvertTo-Json $script:fixture.current) -AsHashtable
        if ($script:fixture.corrupt) { $properties.PreservedSetting='changed' }
        return @{properties=$properties}
    }
    function script:Invoke-GatewayUpgradeArmDeployment {
        param($Context,$Action,$RelativeTemplate,$Parameters,$AllowedResourceIds,[scriptblock]$Readback,[switch]$ReadOnly,$AllowedModifyResourceIds)
        $script:fixture.captured = @{ action=$Action; template=$RelativeTemplate; ids=$AllowedResourceIds; modify=$AllowedModifyResourceIds }
        if (-not $ReadOnly) { $script:fixture.writes++; $script:fixture.current=$Parameters.appSettings }
        return & $Readback @{}
    }
    $context = @{
        plan=@{request=$request;scope=$scope;content=@{sourceFingerprint='sha256:'+('2'*64)}}
        state=$state;config=$config;runtime=$state.steps['Gateway runtime deployment'].evidence
        database=$state.steps['Gateway database'].evidence; planFingerprint='sha256:'+('3'*64)
        purviewRuntime=@{clientId=$state.freshPurviewExecutor.context.runtimeClientId;principalId=$state.freshPurviewExecutor.context.runtimePrincipalId}
        artifactSourceFingerprint='sha256:'+('4'*64)
    }
    $automation=@{applicationId=$state.freshPurviewExecutor.context.automationApplicationId;principalId=$state.freshPurviewExecutor.context.automationServicePrincipalId}
    $package=@{receipt=@{packageDigest='sha256:'+('5'*64);runtimeManifestDigest='sha256:'+('6'*64)}}
    Invoke-GatewayUpgradeExecutorHost $context $automation @{} $state.freshPurviewExecutor.identity $package
    if ($script:fixture.writes -ne 0) { throw 'Initial source-only host observation mutated.' }
    $result=Invoke-GatewayUpgradeExecutorHost $context $automation @{} $state.freshPurviewExecutor.identity $package -Enable
    if ($script:fixture.writes -ne 1 -or $script:fixture.current.PreservedSetting -cne 'unchanged' -or
        $result.principalId -cne $state.freshPurviewExecutor.host.executorPrincipalId.value -or
        $result.endpoint -cne $state.freshPurviewExecutor.host.executorEndpoint.value -or
        $result.binding.BootstrapSourceFingerprint -cne $state.acceptedPlan.sourceFingerprint -or
        $result.binding.ExecutionSourceFingerprint -cne $context.artifactSourceFingerprint -or
        $script:fixture.captured.template -cne 'infrastructure\bicep\maintenance-source-only-executor.bicep' -or
        @($script:fixture.captured.ids).Count -ne 1 -or @($script:fixture.captured.modify).Count -ne 1 -or
        $script:fixture.captured.ids[0] -cne "$($scope.purview.siteId)/config/appsettings") { throw 'Exact source-only executor dispatch failed.' }
    $null=Invoke-GatewayUpgradeExecutorHost $context $automation @{} $state.freshPurviewExecutor.identity $package -Enable -ReadOnly
    if ($script:fixture.writes -ne 1) { throw 'Read-only reconciliation mutated.' }
    $script:fixture.corrupt=$true
    $rejected=$false
    try { $null=Invoke-GatewayUpgradeExecutorHost $context $automation @{} $state.freshPurviewExecutor.identity $package -Enable -ReadOnly } catch {$rejected=$true}
    if (-not $rejected) { throw 'Foreign setting was accepted.' }
    $manifest=Get-GatewayUpgradeSqlManifest $context ([guid]::NewGuid().ToString('D'))
    if ($manifest.SchemaVersion -ne 2 -or $manifest.Scripts.Count -ne 0 -or $manifest.BeforeSchemaFingerprint -cne $manifest.AfterSchemaFingerprint) {
        throw 'Source-only SQL transport differed from the no-DDL contract.'
    }
    $receipt=@{schemaFingerprint=$request.database.currentSchemaFingerprint;receiptFingerprint='sha256:'+('7'*64)
        beforeSchemaFingerprint=$request.database.currentSchemaFingerprint;sqlManifestFingerprint='sha256:'+('8'*64);receiptJson='fixture'}
    $api=Get-GatewayUpgradeApiEnvironment $context $receipt @{}
    $worker=Get-GatewayUpgradeWorkerEnvironment $context $automation @{} $result
    if (@($api.Keys | Where-Object {$_ -clike 'BootstrapCapabilities__*'}).Count -ne 0 -or
        @($worker.Keys | Where-Object {$_ -clike '*Certificate*'}).Count -ne 0 -or $worker.Count -ne 4) {
        throw 'Source-only promotion changed existing capability or certificate configuration.'
    }
    return 7
} $state $config $request $scope
$count += $executionChecks
$tokens = $null
$parseErrors = $null
$planAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'GatewayUpgradePlan.psm1'), [ref]$tokens, [ref]$parseErrors)
Assert-Test ($parseErrors.Count -eq 0) 'Plan revalidation parses'
$revalidation = @($planAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-GatewayUpgradePlanV2'
}, $false))
Assert-Test ($revalidation.Count -eq 1) 'one executable Plan validator'
$admissionCalls = @($revalidation[0].FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Assert-GatewayUpgradeSqlAdmission'
}, $true))
Assert-Test ($admissionCalls.Count -eq 1) 'one executable SQL admission command'
$admissionCommand = [scriptblock]::Create($admissionCalls[0].Extent.Text)
$source = $root
$plan = @{ request = $request; executionSupported = $true }
& $admissionCommand
Assert-Test $true 'executable SourceOnlyFull revalidation accepts zero scripts'
$legacyRequest = Copy-Object $request
$legacyRequest.schemaVersion = 1
$legacyRequest.Remove('mode')
$plan = @{ request = $legacyRequest; executionSupported = $true }
Assert-Rejected { & $admissionCommand } 'executable v1 revalidation still requires migration scripts'
$assetChecks = & $module {
    param($state, $config)
    $script:assetFixture = @{ root = 'current-tooling'; original = 'verified-original'; reject = $false; fail = $false; calls = 0; cleared = 0 }
    function script:Initialize-GatewayUpgradeVerifier {}
    function script:Get-BootstrapExecutionSourceRoot { return $script:assetFixture.root }
    function script:Set-BootstrapExecutionSourceRoot { param($Path) $script:assetFixture.root = $Path }
    function script:Set-BootstrapAzureSubscriptionContext { param($SubscriptionId, $TenantId) }
    function script:Clear-BootstrapAzureSubscriptionContext { $script:assetFixture.cleared++ }
    function script:Resolve-BootstrapAcceptedSourceRoot {
        param($State)
        if ($script:assetFixture.reject) { throw 'Rejected original snapshot.' }
        return $script:assetFixture.original
    }
    function script:Assert-BootstrapAzureContext { param($Config) }
    function script:Test-GatewayBootstrapDeployment {
        $script:assetFixture.calls++
        if ($script:assetFixture.root -cne 'verified-original') { throw 'Verifier did not use independently resolved original assets.' }
        if ($script:assetFixture.fail) { throw 'Readback failed.' }
        return @{ deploymentVerification='Passed'; azureRbac='Passed'; sqlPrivateEndpoint='Passed'
            adminUiIdentity='Passed'; adminUiCredential='Passed'; provisioningAdmissionReady=$true }
    }
    $inputs = @{ state=$state; config=$config }
    $null = Invoke-GatewayUpgradeCanonicalVerifierCore $inputs
    if ($script:assetFixture.root -cne 'current-tooling' -or $script:assetFixture.calls -ne 1 -or $script:assetFixture.cleared -ne 1) {
        throw 'Original assets or context restoration were not exact.'
    }
    $script:assetFixture.fail = $true
    $rejected = $false
    try { $null = Invoke-GatewayUpgradeCanonicalVerifierCore $inputs } catch { $rejected = $true }
    if (-not $rejected -or $script:assetFixture.root -cne 'current-tooling' -or $script:assetFixture.cleared -ne 2) {
        throw 'Failed readback did not restore contexts and fail closed.'
    }
    $script:assetFixture.reject = $true
    $rejected = $false
    try { $null = Invoke-GatewayUpgradeCanonicalVerifierCore $inputs } catch { $rejected = $true }
    if (-not $rejected -or $script:assetFixture.calls -ne 2 -or
        $script:assetFixture.root -cne 'current-tooling' -or $script:assetFixture.cleared -ne 3) {
        throw 'Rejected original assets reached verification or changed contexts.'
    }
    return 3
} $state $config
$count += $assetChecks
$baselineAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'GatewayUpgrade.psm1'), [ref]$tokens, [ref]$parseErrors)
Assert-Test ($parseErrors.Count -eq 0) 'baseline wrapper parses'
$baselineFunction = @($baselineAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-GatewayUpgradeBaselineProcess'
}, $false))
Assert-Test ($baselineFunction.Count -eq 1) 'one read-only baseline process wrapper'
$timeoutContract = [scriptblock]::Create($baselineFunction[0].Body.ParamBlock.Extent.Text + '; return $TimeoutSeconds')
Assert-Test ((& $timeoutContract @{}) -eq 1800) 'complete Full readback has a finite 30-minute default'
Assert-Rejected { & $timeoutContract @{} -TimeoutSeconds 1801 } 'unbounded baseline timeout rejected'
Assert-Rejected { & $timeoutContract @{} -TimeoutSeconds 0 } 'zero baseline timeout rejected'
$executionAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'GatewayUpgradeExecution.psm1'), [ref]$tokens, [ref]$parseErrors)
Assert-Test ($parseErrors.Count -eq 0) 'ARM credential boundary parses'
$armFunction = @($executionAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-GatewayUpgradeArm'
}, $false))
Assert-Test ($armFunction.Count -eq 1) 'one ARM credential boundary'
$armChecks = & {
    param($definition, $target, $resourceGroupId)
    Invoke-Expression $definition
    $fixture = @{ credential=[pscustomobject]@{ accessToken='fixture-token'; tenant=$target.tenantId }; httpCalls=0; tokenCalls=0; arguments=@() }
    function Invoke-AzJson {
        param($Arguments)
        $fixture.tokenCalls++
        $fixture.arguments = $Arguments
        return $fixture.credential
    }
    function Invoke-GatewayUpgradeArmHttp {
        param($Context, $Method, $ResourceId, $Url, $Token, $Body, [switch]$AllowNotFound)
        if ($Method -cne 'GET' -or $Token -cne 'fixture-token') { throw 'Unexpected fixture dispatch.' }
        $fixture.httpCalls++
        return @{ observed=$true }
    }
    $context = @{ config=$target; plan=@{scope=@{resourceGroupId=$resourceGroupId}} }
    $id = "$resourceGroupId/providers/Microsoft.Storage/storageAccounts/fixture"
    $null = Invoke-GatewayUpgradeArm $context GET $id '2023-05-01'
    $expected = @('account', 'get-access-token', '--subscription', $target.subscriptionId,
        '--resource', 'https://management.azure.com/', '--query', '{accessToken:accessToken,tenant:tenant}')
    if (($fixture.arguments -join '|') -cne ($expected -join '|') -or $fixture.httpCalls -ne 1) {
        throw 'ARM credential command must select only the exact subscription and validate tenant metadata.'
    }
    $checks = 1
    foreach ($badCredential in @(
        [pscustomobject]@{accessToken='fixture-token';tenant='00000000-0000-0000-0000-000000000000'},
        [pscustomobject]@{accessToken='fixture-token'},
        [pscustomobject]@{tenant=$target.tenantId},
        [pscustomobject]@{accessToken='';tenant=$target.tenantId},
        [pscustomobject]@{accessToken=42;tenant=$target.tenantId},
        [pscustomobject]@{accessToken='fixture-token';tenant=$target.tenantId;unexpected=$true},
        [pscustomobject]@{accessToken='fixture-token';TENANT=$target.tenantId},
        @{accessToken='fixture-token';tenant=$target.tenantId},
        'unstructured-token'
    )) {
        $fixture.credential = $badCredential
        $rejected = $false
        try { $null = Invoke-GatewayUpgradeArm $context GET $id '2023-05-01' } catch { $rejected=$true }
        if (-not $rejected -or $fixture.httpCalls -ne 1) { throw 'Foreign or malformed credential reached ARM HTTP.' }
        $checks++
    }
    $tokenCalls = $fixture.tokenCalls
    $rejected = $false
    try { $null = Invoke-GatewayUpgradeArm $context GET '/subscriptions/foreign/resourceGroups/foreign/providers/Microsoft.Storage/storageAccounts/fixture' '2023-05-01' } catch { $rejected=$true }
    if (-not $rejected -or $fixture.tokenCalls -ne $tokenCalls) { throw 'Outside-scope ARM request reached credential acquisition.' }
    return ($checks + 1)
} $armFunction[0].Extent.Text $request.target $scope.resourceGroupId
$count += $armChecks
Write-Output "PASS: $count source-only request/scope/baseline checks; no network calls. Local request: $path"
