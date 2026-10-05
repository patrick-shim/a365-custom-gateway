#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../modules/Experience.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot/../modules/Runtime.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot/../modules/Entra.psm1" -Force -DisableNameChecking

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$credential = [pscustomobject]@{
    displayName = 'a365gw-bootstrap-runtime-api-obo'
    keyId = [guid]::NewGuid().ToString('D')
    endDateTime = [DateTimeOffset]::UtcNow.AddDays(1).ToString('O')
}
Assert-True (Test-GatewayApiPasswordCredentialBoundary -Credentials @()) 'A fresh API app has no credentials.'
Assert-True (Test-GatewayApiPasswordCredentialBoundary -Credentials @($credential)) 'Runtime reapply must accept its one bootstrap OBO credential.'
Assert-True (-not (Test-GatewayApiPasswordCredentialBoundary -Credentials @($credential, $credential))) 'Duplicate credentials must be rejected.'
$credential.displayName = 'installation-specific-api-obo'
Assert-True (Test-GatewayApiPasswordCredentialBoundary -Credentials @($credential) -ExpectedCredentialName 'installation-specific-api-obo') 'Reapply must accept the configured credential label.'
Assert-True (-not (Test-GatewayApiPasswordCredentialBoundary -Credentials @($credential))) 'A custom label must not be accepted without its configuration binding.'
Assert-True (-not (Test-GatewayApiPasswordCredentialBoundary -Credentials @($credential, $credential) -ExpectedCredentialName 'installation-specific-api-obo')) 'A configured label must not permit duplicate credentials.'
$credential.displayName = 'unreviewed'
Assert-True (-not (Test-GatewayApiPasswordCredentialBoundary -Credentials @($credential))) 'An unrelated credential must be rejected.'
$credential.displayName = 'a365gw-bootstrap-runtime-api-obo'
$credential.endDateTime = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('O')
Assert-True (-not (Test-GatewayApiPasswordCredentialBoundary -Credentials @($credential))) 'An expired OBO credential must not pass revalidation.'

$config = [pscustomobject]@{
    deployProfile = 'runtime'; projectName = 'test'; environment = 'dev'
    tenantId = '00000000-0000-0000-0000-000000000001'; subscriptionId = ''
    promptShield = @{ enabled = $false }
    purview = @{ enabled = $false }
    runtime = @{ apiHostPort = 5080; consoleHostPort = 5081 }
    agent365 = @{ reviewedManagerApplicationIds = @(); allowDevelopmentRegistryPreview = $false; registryBetaAcknowledged = $false }
}
$state = @{ deploymentKey = 'test'; steps = @{}; outputs = @{} }
foreach ($name in Get-GatewayRuntimeBootstrapStepNames) {
    $state.steps[$name] = @{ status = 'Completed'; evidence = @{} }
}
$state.steps['Gateway runtime'].evidence = @{ consoleUrl = 'http://127.0.0.1:5081/' }
$state.steps['End-to-end deployment verification'].evidence = @{ healthy = $true }
$status = Get-GatewayBootstrapStatus -Config $config -State $state -StatePath 'test-state'
Assert-True ($status.totalSteps -eq 13 -and $status.completedSteps -eq 13) 'Runtime status must count only runtime checkpoints.'
Assert-True ($status.overallStatus -eq 'Verified') 'Completed runtime checkpoints should show Verified.'
Assert-True ($status.endpoints.adminUi -eq 'http://127.0.0.1:5081/') 'Runtime Console endpoint must be retained.'
Assert-True ($status.readiness.ControlPlaneReady -and -not $status.readiness.ProvisioningReady) 'Health must not claim Registry admission.'
$state.steps.Remove('Prerequisites')
$status = Get-GatewayBootstrapStatus -Config $config -State $state -StatePath 'test-state'
Assert-True ($status.completedSteps -eq 12 -and $status.nextStep -eq 'Prerequisites') 'Missing historical checkpoints must not be fabricated.'
$state.steps['Gateway runtime'].status = 'Failed'
$status = Get-GatewayBootstrapStatus -Config $config -State $state -StatePath 'test-state'
Assert-True ($status.overallStatus -eq 'NeedsAttention' -and -not $status.readiness.ControlPlaneReady) 'Failed runtime must invalidate readiness.'

# Inject command observations in the module, so no cloud calls or installs occur.
$runtimeModule = Get-Module Runtime
& $runtimeModule {
    function script:Get-GatewayCommandVersion {
        param($Name, $Arguments)
        if ($Name -eq 'dotnet') { return '10.0.401' }
        if ($Name -eq 'az') { throw 'Core runtime doctor must not invoke Bicep.' }
        return '1.0'
    }
    function script:Get-GatewayAzureCliVersion { return '2.89.1' }
    function script:Invoke-GatewayAzJson {
        param($Arguments)
        if (($Arguments -join ' ') -notmatch '^account show ') { throw 'Unexpected Azure infrastructure query.' }
        return @{ id = 'tenant-only'; tenantId = '00000000-0000-0000-0000-000000000001' }
    }
}
$doctor = Get-GatewayRuntimeDoctorReport -Config $config
Assert-True ($doctor.readyForPlan -and -not $doctor.readyForApply) 'Tenant-only runtime setup should allow planning without claiming provider readiness.'
Assert-True ('Docker Engine' -in $doctor.checks.name -and 'Docker Compose' -in $doctor.checks.name) 'Runtime doctor must check its actual runtime.'
Assert-True (-not ($doctor.checks.name -match 'SQL|Key Vault|Service Bus')) 'Runtime doctor must not require Azure hosting services.'
& $runtimeModule {
    function script:Get-GatewayCommandVersion { param($Name, $Arguments); if ($Name -eq 'docker') { return $null }; return '10.0.401' }
}
$doctor = Get-GatewayRuntimeDoctorReport -Config $config
Assert-True (-not $doctor.readyForPlan -and $doctor.failures -eq 2) 'Unavailable Docker must block runtime planning.'
Remove-Module Runtime
Import-Module "$PSScriptRoot/../modules/Runtime.psm1" -Force -DisableNameChecking

$rejected = $false
try {
    Invoke-GatewayRuntimeApplyWorkflow -Configuration $config -State @{ steps = @{} } `
        -StatePath 'unused' -Format Text -InstallLocalPrerequisites $false `
        -NonInteractive $true -AcceptedPlanFingerprint 'not-accepted'
} catch { $rejected = $_.Exception.Message -like 'Apply requires a reviewed plan*' }
Assert-True $rejected 'Apply must reject a missing accepted plan before any prerequisite or provider call.'
$rejected = $false
try {
    Invoke-GatewayRuntimePlanWorkflow -Configuration $config `
        -State @{ steps = @{ pending = @{ status = 'Running' } } } `
        -StatePath 'unused' -Format Text -InstallLocalPrerequisites $false
} catch { $rejected = $_.Exception.Message -like 'Unrecognized checkpoint*' }
Assert-True $rejected 'An unknown checkpoint must not be reinterpreted by a new plan.'

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('gateway-runtime-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    & (Get-Module Runtime) { param($Path); $script:testComposeDirectory = $Path; function script:Get-GatewayRuntimeComposeDirectory { return $script:testComposeDirectory } } $scratch
    $envFile = Write-GatewayRuntimeEnv -Config $config `
        -Identity @{ gatewayApiClientId = 'api'; gatewayApiTokenAudience = 'audience' } `
        -ConsoleIdentity @{ consoleClientId = 'console'; apiScope = 'scope' } `
        -WorkloadIdentity @{ workloadClientId = 'worker'; workloadServicePrincipalId = 'principal'; workloadClientSecret = 'test-only' } `
        -Images @{ api = 'api:test'; worker = 'worker:test'; console = 'console:test' } `
        -PromptShield @{ enabled = $false; endpoint = '' } `
        -GatewayApiOboClientSecret 'test-only' -BlueprintClientSecret 'test-only' `
        -BlueprintApplicationId '10000000-0000-0000-0000-000000000001'
    $lines = Get-Content -LiteralPath $envFile
    Assert-True ($lines -contains 'Agent365__ObservabilityServerAddress=127.0.0.1') 'Bootstrap must configure the server identity required by A365 export.'
    Assert-True ($lines -contains 'Agent365__ObservabilityServerPort=5080') 'A365 server port must match the runtime API port.'
    Add-Content -LiteralPath $envFile -Value @('Agent365__BlueprintClientSecret=old-unscoped-secret', 'Agent365__BlueprintClientSecrets__10000000-0000-0000-0000-000000000002=other-blueprint-secret')
    $envFile = Write-GatewayRuntimeEnv -Config $config `
        -Identity @{ gatewayApiClientId = 'api'; gatewayApiTokenAudience = 'audience' } `
        -ConsoleIdentity @{ consoleClientId = 'console'; apiScope = 'scope' } `
        -WorkloadIdentity @{ workloadClientId = 'worker'; workloadServicePrincipalId = 'principal'; workloadClientSecret = 'test-only' } `
        -Images @{ api = 'api:test'; worker = 'worker:test'; console = 'console:test' } `
        -PromptShield @{ enabled = $false; endpoint = '' } `
        -GatewayApiOboClientSecret 'test-only' -BlueprintClientSecret 'new-seed-secret' `
        -BlueprintApplicationId '10000000-0000-0000-0000-000000000001'
    $lines = Get-Content -LiteralPath $envFile
    Assert-True (@($lines | Where-Object { $_ -like 'Agent365__BlueprintClientSecret=*' }).Count -eq 0) 'Reapply must not emit an unscoped blueprint secret.'
    Assert-True ($lines -contains 'Agent365__BlueprintClientSecrets__10000000-0000-0000-0000-000000000002=other-blueprint-secret') 'Reapply must preserve other exact blueprint mappings.'
    Assert-True ($lines -contains 'Agent365__BlueprintClientSecrets__10000000-0000-0000-0000-000000000001=new-seed-secret') 'The seed credential must be bound to its own blueprint ID.'
} finally {
    # Delete only the exact files/directory created by this test, without recursion.
    Remove-Item -LiteralPath (Join-Path $scratch '.env.runtime') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch
}
& (Get-Module Runtime) {
    function script:Invoke-AzJson {
        param($Arguments)
        if (($Arguments -join ' ') -notmatch '/applications/10000000-0000-0000-0000-000000000001/microsoft.graph.agentIdentityBlueprint\?\$select=') {
            throw 'Seed reconciliation must read the checkpoint object ID.'
        }
        return @{ appId = '10000000-0000-0000-0000-000000000001' }
    }
    function script:Get-Agent365SeedBlueprintDisplayName { param($Config, $DeploymentOwnershipId, $SourceFingerprint); return $SourceFingerprint }
    function script:Get-Agent365BlueprintByName { throw 'Existing seed must never be looked up by the new source name.' }
    function script:Ensure-Agent365SeedBlueprint { throw 'Existing seed must never be recreated.' }
    function script:Assert-Agent365SeedBlueprintSurface {
        param($Blueprint, $Config, $ExpectedDisplayName, $DeploymentOwnershipId, $SourceFingerprint, $SponsorObjectId, [switch]$RequirePristineAuthoritySurface)
        return @{ sourceFingerprint = $SourceFingerprint }
    }
}
$seed = Ensure-RuntimeAgent365SeedBlueprint -Config $config -DeploymentOwnershipId 'owner' `
    -SourceFingerprint 'new-source' -SponsorObjectId 'sponsor' -WorkloadServicePrincipalId 'worker' `
    -ExistingEvidence @{ deploymentOwnershipId = 'owner'; sourceFingerprint = 'original-source'; objectId = '10000000-0000-0000-0000-000000000001'; applicationId = '10000000-0000-0000-0000-000000000001' }
Assert-True ($seed.sourceFingerprint -eq 'original-source') 'A new build must preserve seed identity and creation provenance.'
Write-Output 'Runtime diagnostics regression checks passed.'
