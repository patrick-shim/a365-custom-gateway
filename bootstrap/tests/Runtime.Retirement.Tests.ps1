#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach ($name in @('Common','Experience','Prerequisites','Azure','Entra','Agent365','Runtime','RuntimePurview','Lifecycle')) {
    Import-Module (Join-Path $root "bootstrap/modules/$name.psm1") -Force -DisableNameChecking
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

# The live F0 preflight uses this read after authentication. Exercise the actual
# command boundary, since the plan composition test mocks capacity discovery.
& (Get-Module Common) {
    $previous = $script:BootstrapAzureSubscriptionId
    $previousTenant = $script:BootstrapAzureTenantId
    try {
        $script:BootstrapAzureSubscriptionId = '11111111-1111-4111-8111-111111111111'
        $script:BootstrapAzureTenantId = '33333333-3333-4333-8333-333333333333'
        $arguments = @(Get-BootstrapAzureCliArguments -Arguments @('resource','list','--resource-type','Microsoft.CognitiveServices/accounts'))
        if (($arguments -join '|') -cne 'resource|list|--resource-type|Microsoft.CognitiveServices/accounts|--subscription|11111111-1111-4111-8111-111111111111') {
            throw 'Content Safety inventory must be allowed and pinned to the authenticated subscription.'
        }
        foreach ($command in @(
            @('resource','delete','--resource-type','Microsoft.CognitiveServices/accounts'),
            @('resource','list','--resource-type','Microsoft.Storage/storageAccounts'),
            @('resource','list','--resource-type','Microsoft.CognitiveServices/accounts','--subscription','22222222-2222-4222-8222-222222222222')
        )) {
            $rejected = $false
            try { Get-BootstrapAzureCliArguments -Arguments $command | Out-Null } catch { $rejected = $true }
            if (-not $rejected) { throw 'Unreviewed resource access or a different subscription was accepted.' }
        }
    } finally {
        $script:BootstrapAzureSubscriptionId = $previous
        $script:BootstrapAzureTenantId = $previousTenant
    }
}

$config = Read-BootstrapConfig -Path (Join-Path $root 'bootstrap/config.example.runtime.json')
Assert-True ((Get-GatewayDeployProfile -Config $config) -ceq 'runtime') 'Runtime configuration must remain supported.'
Assert-True ((Get-GatewayDeployProfile -Config @{ deployProfile = 'runtime' }) -ceq 'runtime') 'Dictionary configurations must remain supported.'
foreach ($profile in @('azureLegacy','')) {
    $rejected = $false
    try { Get-GatewayDeployProfile -Config ([pscustomobject]@{ deployProfile = $profile }) | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*only the runtime deployment profile*' }
    Assert-True $rejected 'Legacy or implicit profiles must fail before state/provider work.'
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('gateway-retirement-test-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $legacyPath = Join-Path $fixture 'config.json'
    $legacy = [ordered]@{ deployProfile = 'azureLegacy' }
    $legacy | ConvertTo-Json | Set-Content -LiteralPath $legacyPath -Encoding utf8
    $before = (Get-FileHash -LiteralPath $legacyPath).Hash
    $output = & (Join-Path $PSHOME 'pwsh') -NoProfile -File (Join-Path $root 'bootstrap/bootstrap.ps1') `
        -Mode Apply -Config $legacyPath -NonInteractive -Yes -OutputFormat Json
    Assert-True ($LASTEXITCODE -eq 1 -and ($output -join '') -like '*only the runtime deployment profile*') 'The real entry point must reject Azure Apply before schema/state/provider work.'
    Assert-True ((Get-FileHash -LiteralPath $legacyPath).Hash -ceq $before) 'Rejected Azure configuration must remain unchanged.'
    Assert-True (@(Get-ChildItem -LiteralPath $fixture -Force).Count -eq 1) 'Rejected Azure Apply must not create local state.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $resolved.StartsWith($parent + [IO.Path]::DirectorySeparatorChar) -or
        (Split-Path $resolved -Leaf) -notmatch '^gateway-retirement-test-[a-f0-9]{32}$') { throw 'Unsafe test fixture cleanup.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
$templates = @(Get-ChildItem (Join-Path $root 'infrastructure'),(Join-Path $root 'bootstrap') -Recurse -File |
    Where-Object { $_.Extension -in @('.bicep','.bicepparam') } |
    ForEach-Object { [IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/') } | Sort-Object)
Assert-True (($templates -join '|') -ceq 'infrastructure/bicep/modules/content-safety.bicep|infrastructure/bicep/runtime-content-safety.bicep') 'Only the Content Safety template and its module may remain.'

# Catch removed helpers that are still called by an active module. Framework,
# native commands and late-imported Exchange cmdlets are outside this namespace.
foreach ($file in Get-ChildItem (Join-Path $root 'bootstrap/modules') -Filter '*.psm1') {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    $localFunctions = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object Name)
    foreach ($command in $ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)) {
        $name = $command.GetCommandName()
        if ($name -match '^[A-Za-z]+-(Gateway|Bootstrap|Runtime|Agent365)' -and
            $name -notin $localFunctions -and
            -not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Missing installer helper: $name" }
    }
}

# Exercise the real plan composition twice, replacing only machine/provider IO.
# No tenant calls, actual state writes, consent, or deployments occur in this test.
& (Get-Module Runtime) {
    param($Configuration)
    function script:Clear-BootstrapAcceptedPlan { param($State,$StatePath) }
    function script:Assert-GatewayRuntimePrerequisites {
        param([switch]$Install,[bool]$RequireBicep)
        $script:ObservedBicep = $RequireBicep
    }
    function script:Clear-BootstrapAzureSubscriptionContext { }
    function script:Set-BootstrapAzureSubscriptionContext { param($SubscriptionId,$TenantId) }
    function script:Set-BootstrapAzureTenantContext { param($TenantId) }
    function script:Assert-GatewayApplicationNamespacePlanBoundary { param($Config,$DeploymentOwnershipId) }
    function script:Assert-RuntimeContentSafetyOwnership { param($Config,$DeploymentOwnershipId) }
    function script:Assert-RuntimePurviewPrerequisites { param($Enabled) }
    function script:Assert-GatewayPromptShieldFreeTierCapacity {
        param($Config,$ResourceGroupName)
        $script:CapacityChecked = $true
    }
    function script:Write-GatewayExperienceEvent { param($Type,$Message,$Data,$OutputFormat) }
    foreach ($enabled in @($false,$true)) {
        $Configuration.promptShield.enabled = $enabled
        $script:CapacityChecked = $false
        $state = @{ deploymentOwnershipId = '11111111-1111-4111-8111-111111111111'; steps = @{} }
        $plan = Invoke-GatewayRuntimePlanWorkflow -Configuration $Configuration -State $state `
            -StatePath 'unused-test-state' -Format Json -InstallLocalPrerequisites $false -StreamOnly
        if ($plan.descriptor.deployProfile -cne 'runtime' -or -not $plan.whatIf.applyReady -or
            $plan.planFingerprint -cnotmatch '^sha256:[a-f0-9]{64}$' -or
            $script:ObservedBicep -ne $enabled -or $script:CapacityChecked -ne $enabled) {
            throw 'Runtime plan did not preserve product-resource selection and source binding.'
        }
    }
} $config

'Runtime retirement checks passed: explicit profile, only two templates, helper closure, and both product-resource plan branches (no network).'
