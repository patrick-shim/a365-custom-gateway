[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Plan','Build','Promote','Verify')][string]$Mode,
    [string]$ApprovalFingerprint = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root '.test-work\gw0911g-kyd-capture-admin'
$seed = Join-Path $root '.test-work\gw0911g-admin-inventory\candidate'
$candidate = Join-Path $work 'candidate'
$context = Join-Path $work 'context'
$seedSource = 'sha256:dcf48f2cf67b11889cc12510f7e0be102dc3be3b8f0f7b1587e46cf1f1de7d0a'
$deltaPath = 'src/Gateway.AdminUi/Components/Pages/Settings.razor'
$deltaHash = '21ae008ef411a263302ed1832f3a5b25803747fae669b5d113be61cdcb0f51cd'
$tag = 'maintenance-be3c4c3cd83345098fc63080-adminui'
$currentWork = Join-Path $root '.test-work\gw0911g-artifact-hotfix\kyd-provider-mode'
$currentPlan = '22692ce01d17aedc737ba506a7d862712875f69fe58b090927b16d00f9ce4f18'
$currentReceiptHash = '6560f646f262d2630b38fcf928b20efc75c6d5a14cd11cde6aec2926e63d9127'
$module = @(Import-Module (Join-Path $PSScriptRoot 'Gw0911gArtifactHotfix.psm1') `
    -ArgumentList KydProviderMode -PassThru -Force -DisableNameChecking |
    Where-Object { $_.Name -eq 'Gw0911gArtifactHotfix' })[0]
function Hash-File([string]$Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Equal($Actual, $Expected, [string]$Label) {
    if ((Get-BootstrapObjectFingerprint $Actual) -cne (Get-BootstrapObjectFingerprint $Expected)) {
        throw "WorkerClockCorrection:$Label"
    }
}
function Save-New([string]$Name, $Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 100))
    $stream = [IO.File]::Open((Join-Path $work $Name), 'CreateNew', 'Write', 'None')
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Read-Json([string]$Name) {
    $path = Join-Path $work $Name
    if (Test-Path $path) { return Get-Content $path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String }
    return $null
}
function Copy-Object($Value) {
    ,($Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String)
}
function Read-Observation { & $module { Get-GwHotfixObservation } }
function Previous-Target {
    if ((Hash-File (Join-Path $currentWork 'verified.json')) -cne $currentReceiptHash) { throw 'WorkerClockCorrection:PreviousReceiptChanged' }
    $plan = Get-Content (Join-Path $currentWork "plan-$currentPlan.json") -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    if ((Get-BootstrapObjectFingerprint $plan) -cne "sha256:$currentPlan") { throw 'WorkerClockCorrection:PreviousPlanChanged' }
    $previous = Copy-Object $plan.target.resources
    return $previous
}
function Assert-Baseline($Observation) {
    $previous = Previous-Target
    foreach ($name in @('admin','api','worker','site','publisher','settings','companionSha256')) {
        Equal $Observation[$name] $previous[$name] "Previous$name"
    }
}
function Assert-Capacity {
    if ((Hash-File (Join-Path $root '.test-work\live-acceptance-20260912\executor-capacity-b2\verified.json')) -cne
        '9f3d3b59f5ce4607727956570cd22c346a9044782a809427bb26c80a3c624b77') {
        throw 'AdminInventoryCorrection:CapacityReceiptChanged'
    }
    & $module { Assert-GwHotfixB2Capacity }
}
function Expected-Manifest {
    $manifest = @(Get-BootstrapSourceManifest -Root $seed)
    if ((Get-BootstrapObjectFingerprint $manifest) -cne $seedSource) { throw 'WorkerClockCorrection:FrozenSourceChanged' }
    @($manifest | ForEach-Object { if ($_.path -ceq $deltaPath) { @{ path = $_.path; sha256 = $deltaHash } } else { $_ } })
}
function Build-Paths {
    $sourcePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @(Expected-Manifest)) { $null = $sourcePaths.Add($entry.path) }
    $paths = @(Get-GatewayAcrBuildSourceFiles -RepositoryRoot $candidate |
        Where-Object { $_ -notmatch '(?i)(^|/)(bin|obj)/' } | Sort-Object)
    foreach ($path in $paths) {
        if (-not $sourcePaths.Contains($path)) { throw 'WorkerClockCorrection:InputOutsideSourceManifest' }
    }
    return $paths
}
function Assert-Context {
    $manifest = @(Expected-Manifest)
    Equal @(Get-BootstrapSourceManifest -Root $candidate) $manifest 'CandidateSourceChanged'
    $paths = @(Build-Paths)
    $actual = @(Get-ChildItem $context -File -Recurse | ForEach-Object {
        [IO.Path]::GetRelativePath($context, $_.FullName).Replace('\','/')
    } | Sort-Object)
    Equal $actual $paths 'ContextInventoryChanged'
    foreach ($path in $paths) {
        if ((Hash-File (Join-Path $context $path)) -cne (Hash-File (Join-Path $candidate $path))) {
            throw 'WorkerClockCorrection:ContextBytesChanged'
        }
    }
    Assert-GatewayCredentialFreeNuGetConfig -Path (Join-Path $context 'nuget.config') | Out-Null
    return Get-BootstrapObjectFingerprint $manifest
}
[IO.Directory]::CreateDirectory($work) | Out-Null
$lock = [IO.File]::Open((Join-Path $work 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $null = & $module { Get-GwHotfixState }
    if ($Mode -eq 'Prepare') {
        if (Test-Path $candidate) { throw 'WorkerClockCorrection:PreparedSourceAlreadyExists' }
        if ((Hash-File (Join-Path $root $deltaPath)) -cne $deltaHash) { throw 'WorkerClockCorrection:ReviewedDeltaChanged' }
        foreach ($entry in @(Expected-Manifest)) {
            $source = if ($entry.path -ceq $deltaPath) { Join-Path $root $entry.path } else { Join-Path $seed $entry.path }
            Assert-BootstrapSourcePathIsRegular -Root $(if ($entry.path -ceq $deltaPath) { $root } else { $seed }) -RelativePath $entry.path | Out-Null
            $destination = Join-Path $candidate $entry.path
            [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
            Copy-Item $source $destination
        }
        foreach ($path in @(Build-Paths)) {
            $destination = Join-Path $context $path
            [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
            Copy-Item (Join-Path $candidate $path) $destination
        }
            $source = Assert-Context
        & dotnet publish (Join-Path $candidate 'src\Gateway.AdminUi\Gateway.AdminUi.csproj') `
            -c Release -o (Join-Path $work 'publish') /p:UseAppHost=false --nologo -v quiet
        if ($LASTEXITCODE -ne 0) { throw 'WorkerClockCorrection:LocalBuildFailed' }
        if ((Hash-File (Join-Path $work 'publish\wwwroot\downloads\Connect-PurviewTenant.ps1')) -cne
            'e985e96da95566fe5890bdc7801a8d46440d0cbc2adff24acc46af54decf016c') {
            throw 'AdminInventoryCorrection:CompanionChanged'
        }
        Save-New 'prepared.json' @{ source = $source; seed = $seedSource; delta = @{ path = $deltaPath; sha256 = $deltaHash }; localPublish = 'Passed' }
        return
    }
    $source = Assert-Context
    & $module { Assert-GwHotfixOperator }
    Assert-Capacity
    $prepared = Read-Json 'prepared.json'
    if (-not $prepared -or $prepared.source -cne $source) { throw 'WorkerClockCorrection:PreparedProofMissing' }
    $build = Read-Json 'build.json'
    if ($Mode -eq 'Plan') {
        $observation = Read-Observation
        Assert-Baseline $observation
        $plan = @{ kind = 'FilteredKydCaptureAdmin'; stage = if ($build) { 'Promote' } else { 'Build' };
            source = $source; seedSource = $seedSource; delta = $prepared.delta; original = $observation;
            tag = $tag; repository = 'gateway-admin'; previousArtifactReceiptSha256 = $currentReceiptHash;
            scriptSha256 = Hash-File $PSCommandPath; build = $build
            purpose = 'Keep the explicitly selected KYD classifier and disable incompatible full AI content capture; no broadening to All.'
            costScope = 'One existing ACR Admin image build; no new recurring resources.' }
        if ($build) {
            $target = Copy-Object $observation.admin
            $target.properties.template.containers[0].image = $build.image
            $plan.targetAdmin = $target
        }
        $fingerprint = Get-BootstrapObjectFingerprint $plan
        Save-New "plan-$($fingerprint.Substring(7)).json" $plan
        @{ stage = $plan.stage; approvalFingerprint = $fingerprint } | ConvertTo-Json -Compress
        return
    }
    if ($ApprovalFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'WorkerClockCorrection:ExactApprovalRequired' }
    $plan = Read-Json "plan-$($ApprovalFingerprint.Substring(7)).json"
    if (-not $plan -or (Get-BootstrapObjectFingerprint $plan) -cne $ApprovalFingerprint -or
        $plan.source -cne $source -or $plan.scriptSha256 -cne (Hash-File $PSCommandPath)) { throw 'WorkerClockCorrection:PlanChanged' }
    $reader = @{ Registry = 'acrgw0911gdevdbilxu'; Repository = 'gateway-admin'; Tag = $tag; TagContract = 'MaintenanceV1' }
    if ($Mode -eq 'Build') {
        if ($plan.stage -cne 'Build') { throw 'WorkerClockCorrection:WrongStage' }
        $current = Read-Observation
        Equal $current $plan.original 'PreBuildDrift'
        $intent = @{ plan = $ApprovalFingerprint; source = $source; tag = $tag }
        $prior = Read-Json 'build-intent.json'
        $runs = @(Get-GatewayAcrExactImageRuns @reader)
        if ($prior) { Equal $prior $intent 'BuildIntentChanged' }
        else {
            if ($runs.Count) { throw 'WorkerClockCorrection:UnownedBuild' }
            Save-New 'build-intent.json' $intent
            $run = Invoke-AzJson -CaptureStdoutOnly -Arguments @('acr','build','--subscription','6f6ae863-dcb7-456f-a7f0-d6f9887cfb76',
                '--registry','acrgw0911gdevdbilxu','--image',"gateway-admin:$tag",'--file','src/Gateway.AdminUi/Dockerfile',
                $context,'--no-logs','--query','{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}}')
            $null = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository 'gateway-admin' -Tag $tag -TagContract MaintenanceV1
            $runs = @(Get-GatewayAcrExactImageRuns @reader)
        }
        if ($runs.Count -ne 1) { throw 'WorkerClockCorrection:UnknownBuildOutcomeNoReplay' }
        $run = Get-GatewayAcrExactRunById @reader -RunId $runs[0].runId
        $null = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository 'gateway-admin' -Tag $tag -TagContract MaintenanceV1
        $digest = @($run.outputImages)[0].digest
        if ((Get-GatewayAcrExactTagDigest @reader).digest -cne $digest) { throw 'WorkerClockCorrection:ImageDigestChanged' }
        $result = @{ plan = $ApprovalFingerprint; source = $source; runId = $run.runId; image = "acrgw0911gdevdbilxu.azurecr.io/gateway-admin@$digest" }
        if ($build) { Equal $build $result 'BuildReceiptChanged' } else { Save-New 'build.json' $result }
        return
    }
    if ($plan.stage -cne 'Promote' -or -not $build) { throw 'WorkerClockCorrection:WrongStage' }
    Equal $plan.build $build 'BuildChanged'
    $run = Get-GatewayAcrExactRunById @reader -RunId $build.runId
    $null = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository 'gateway-admin' -Tag $tag -TagContract MaintenanceV1
    if ("acrgw0911gdevdbilxu.azurecr.io/gateway-admin@$(@($run.outputImages)[0].digest)" -cne $build.image -or
        "acrgw0911gdevdbilxu.azurecr.io/gateway-admin@$((Get-GatewayAcrExactTagDigest @reader).digest)" -cne $build.image) { throw 'WorkerClockCorrection:BuiltImageChanged' }
    $expected = Copy-Object $plan.original.admin
    $expected.properties.template.containers[0].image = $build.image
    Equal $plan.targetAdmin $expected 'OnlyImageMayChange'
    $intent = @{ plan = $ApprovalFingerprint; target = $expected }
    if ($Mode -eq 'Promote' -and -not (Read-Json 'admin-intent.json')) {
        Equal (Read-Observation) $plan.original 'PrePromotionDrift'
        Save-New 'admin-intent.json' $intent
        $null = & $module { param($body) Invoke-GwHotfixArm admin PATCH $body } @{ properties = $expected.properties; identity = $expected.identity; tags = $expected.tags }
    }
    $savedIntent = Read-Json 'admin-intent.json'
    if (-not $savedIntent) { throw 'WorkerClockCorrection:UnownedPromotion' }
    Equal $savedIntent $intent 'PromotionIntentChanged'
    $current = Read-Observation
    foreach ($name in @('worker','api','site','publisher','settings','companionSha256','executions')) {
        Equal $current[$name] $plan.original[$name] "Preserved$name"
    }
    Equal $current.admin $expected 'AdminTargetNotYetVerified'
    $receipt = @{ status = 'ExactAdminImageVerified'; plan = $ApprovalFingerprint; source = $source;
        image = $build.image; runtimeBindingsAndOtherConfigurationPreserved = $true; privateExecutorArtifactUnchanged = $true }
    $oldReceipt = Read-Json 'verified.json'
    if ($oldReceipt) { Equal $oldReceipt $receipt 'VerificationReceiptChanged' } else { Save-New 'verified.json' $receipt }
    $receipt | ConvertTo-Json -Compress
}
finally { $lock.Dispose() }
