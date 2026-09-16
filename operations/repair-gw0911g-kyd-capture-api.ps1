[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Plan','Build','Promote','Verify')][string]$Mode,
    [string]$ApprovalFingerprint = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root '.test-work\gw0911g-kyd-capture-api'
$seed = Join-Path $root '.test-work\fresh-full-0911g'
$candidate = Join-Path $work 'candidate'
$context = Join-Path $work 'context'
$seedSource = 'sha256:de369d5427906dc782dd5425354b1ca0e427012a279f3360cac6a2ed46a7565c'
$delta = [ordered]@{
    'src/Gateway.Application/Protection/ProtectionReviewHandler.cs' = '242437bd8d367c683b480906978d59f73754ff15dd8bc4d95b67036ae2eccf00'
    'src/Gateway.Application/Protection/ProtectionMutationHandler.cs' = 'bbc71b399209fee09a185362471d6fbcd119f11bc8fcb5dddcf45a04ffba82bf'
}
$tag = 'maintenance-be3c4c3cd83345098fc63080-api'
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
function Read-RestPredispatchCorrection([string]$Source) {
    $proof = Read-Json 'rest-predispatch-proof.json'
    if (-not $proof) { return $null }
    $oldBuildId = 'sha256:b387d355f06374acb2ba688aa638cffe0ff4ff37e31a5126f378fd5e738cf831'
    $oldPromoteId = 'sha256:7527853fdd4bb7e01f9ed7ee25f18b26554918e1ee081d2129d42ac2ca23b93e'
    if ($proof.kind -cne 'NativeRestCaptureGuardBeforeDispatch' -or
        $proof.httpDispatchOccurred -isnot [bool] -or $proof.httpDispatchOccurred -or
        $proof.actualAllResourcesStillOriginal -isnot [bool] -or -not $proof.actualAllResourcesStillOriginal -or
        $proof.oldBuildPlan -cne $oldBuildId -or $proof.oldPromotePlan -cne $oldPromoteId -or
        $proof.originalAdapterSha256 -cne '51b89f77faf5ef10d4fb1aa7813d95fc16f7b37b892a3e0578e1a4b06d08db31' -or
        $proof.retainedApiIntentSha256 -cne 'ab063ce39b383ec8848f6994e180da01994c0b779744cbc92bb6e31c1726a42b' -or
        $proof.guardModuleSha256 -cne '5391bd9c6623f5c8b158b525e4e5aa2381f7659c0fd7770ab87b724e541cd46c') {
        throw 'KydCaptureApi:UnprovenPredispatchCorrection'
    }
    if ((Hash-File (Join-Path $work 'approved-adapter-before-rest-fix.ps1')) -cne $proof.originalAdapterSha256 -or
        (Hash-File (Join-Path $work 'api-intent.json')) -cne $proof.retainedApiIntentSha256 -or
        (Hash-File (Join-Path $root '.test-work\fresh-full-0911g\bootstrap\modules\Common.psm1')) -cne $proof.guardModuleSha256) {
        throw 'KydCaptureApi:PredispatchHistoryChanged'
    }
    $oldBuild = Read-Json "plan-$($oldBuildId.Substring(7)).json"
    $oldPromote = Read-Json "plan-$($oldPromoteId.Substring(7)).json"
    $built = Read-Json 'build.json'
    if ((Get-BootstrapObjectFingerprint $oldBuild) -cne $oldBuildId -or
        (Get-BootstrapObjectFingerprint $oldPromote) -cne $oldPromoteId -or
        $oldBuild.scriptSha256 -cne $proof.originalAdapterSha256 -or
        $oldPromote.scriptSha256 -cne $proof.originalAdapterSha256 -or
        $built.plan -cne $oldBuildId -or $built.source -cne $Source) {
        throw 'KydCaptureApi:OriginalBuildAuthorityChanged'
    }
    Equal $oldPromote.build $built 'OriginalBuildReceipt'
    Equal (Read-Json 'api-intent.json') @{ plan=$oldPromoteId;target=$oldPromote.targetApi } 'OriginalApiIntent'
    $result = @{
        kind='FixedInProcessApiArmDispatch'
        oldBuildPlan=$oldBuildId;oldPromotePlan=$oldPromoteId
        retainedApiIntentSha256=$proof.retainedApiIntentSha256
        originalAdapterSha256=$proof.originalAdapterSha256
        proofSha256=Hash-File (Join-Path $work 'rest-predispatch-proof.json')
    }
    $tokenProof = Read-Json 'token-wrapper-rejection-proof.json'
    if ($tokenProof) {
        $priorPlanId = 'sha256:99a7a7c50668f3af7522484bc219dc478c475a1c13ed3d8a4cb2f84619780568'
        if ($tokenProof.kind -cne 'InvalidBearerWrapperCannotAuthorize' -or
            $tokenProof.priorPlan -cne $priorPlanId -or
            $tokenProof.priorAdapterSha256 -cne '2a9af24df106592bfef753ca44962354d9dee68216acd024ce72faa2b89761f6' -or
            $tokenProof.priorHttpIntentSha256 -cne '425e4ae7c1a5ebff945230601af7f688a77a19d20d1ad1325f88650f4e15145a' -or
            $tokenProof.wrapperType -cne 'System.Management.Automation.PSCustomObject' -or
            $tokenProof.interpolatedAsPropertyBag -isnot [bool] -or -not $tokenProof.interpolatedAsPropertyBag -or
            $tokenProof.actualAllResourcesStillOriginal -isnot [bool] -or -not $tokenProof.actualAllResourcesStillOriginal -or
            $tokenProof.syntheticEquivalentReadOnlyGetStatus -ne 401) {
            throw 'KydCaptureApi:UnprovenTokenProjectionCorrection'
        }
        $prior = Read-Json "plan-$($priorPlanId.Substring(7)).json"
        if ((Get-BootstrapObjectFingerprint $prior) -cne $priorPlanId -or
            $prior.scriptSha256 -cne $tokenProof.priorAdapterSha256 -or
            (Hash-File (Join-Path $work 'approved-adapter-before-token-property-fix.ps1')) -cne $tokenProof.priorAdapterSha256 -or
            (Hash-File (Join-Path $work 'api-corrected-intent.json')) -cne $tokenProof.priorHttpIntentSha256) {
            throw 'KydCaptureApi:TokenCorrectionHistoryChanged'
        }
        Equal $prior.predispatchCorrection $result 'PriorTransportAuthority'
        Equal (Read-Json 'api-corrected-intent.json') @{
            plan=$priorPlanId;target=$prior.targetApi;retainedApiIntentSha256=$proof.retainedApiIntentSha256
        } 'PriorUnauthenticatedIntent'
        $result.tokenWrapperCorrection=@{
            priorPlan=$priorPlanId;priorHttpIntentSha256=$tokenProof.priorHttpIntentSha256
            priorAdapterSha256=$tokenProof.priorAdapterSha256
            proofSha256=Hash-File (Join-Path $work 'token-wrapper-rejection-proof.json')
        }
    }
    return $result
}
function Read-Observation { & $module { Get-GwHotfixObservation } }
function Previous-Target {
    if ((Hash-File (Join-Path $currentWork 'verified.json')) -cne $currentReceiptHash) { throw 'WorkerClockCorrection:PreviousReceiptChanged' }
    $plan = Get-Content (Join-Path $currentWork "plan-$currentPlan.json") -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    if ((Get-BootstrapObjectFingerprint $plan) -cne "sha256:$currentPlan") { throw 'WorkerClockCorrection:PreviousPlanChanged' }
    $previous = Copy-Object $plan.target.resources
    $adminWork = Join-Path $root '.test-work\gw0911g-kyd-capture-admin'
    $adminReceiptHash = '788df48a7d61756b325ee4692b34a0247835afc9cc5eab6a13b264bec1a446c0'
    if ((Hash-File (Join-Path $adminWork 'verified.json')) -cne $adminReceiptHash) {
        throw 'KydCaptureApi:AdminReceiptChanged'
    }
    $adminPlan = Get-Content (Join-Path $adminWork 'plan-be4361fa42a64a566c5ef2743c32f007ac0bcf9c652c7f0e41ceb5e52bbc15b0.json') -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    if ((Get-BootstrapObjectFingerprint $adminPlan) -cne
        'sha256:be4361fa42a64a566c5ef2743c32f007ac0bcf9c652c7f0e41ceb5e52bbc15b0') {
        throw 'KydCaptureApi:AdminPlanChanged'
    }
    foreach ($name in @('admin','api','worker','site','publisher','settings','companionSha256')) {
        Equal $adminPlan.original[$name] $previous[$name] "AdminPredecessor$name"
    }
    $expectedAdmin = Copy-Object $previous.admin
    $expectedAdmin.properties.template.containers[0].image =
        'acrgw0911gdevdbilxu.azurecr.io/gateway-admin@sha256:2ad62283e773deff6bdc7bb5f9a848b438ac662e7ca4333e50842b59fdb8431c'
    Equal $adminPlan.targetAdmin $expectedAdmin 'ExactAdminAmendment'
    $previous.admin = $expectedAdmin
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
    foreach ($path in $delta.Keys) {
        if ($path -cnotin @($manifest.path)) { throw 'KydCaptureApi:DeltaOutsideSeed' }
    }
    @($manifest | ForEach-Object { if ($delta.Contains($_.path)) { @{ path = $_.path; sha256 = $delta[$_.path] } } else { $_ } })
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
        foreach ($path in $delta.Keys) {
            if ((Hash-File (Join-Path $root $path)) -cne $delta[$path]) { throw 'KydCaptureApi:ReviewedDeltaChanged' }
        }
        foreach ($entry in @(Expected-Manifest)) {
            $source = if ($delta.Contains($entry.path)) { Join-Path $root $entry.path } else { Join-Path $seed $entry.path }
            Assert-BootstrapSourcePathIsRegular -Root $(if ($delta.Contains($entry.path)) { $root } else { $seed }) -RelativePath $entry.path | Out-Null
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
        & dotnet publish (Join-Path $candidate 'src\Gateway.Api\Gateway.Api.csproj') `
            -c Release -o (Join-Path $work 'publish') /p:UseAppHost=false --nologo -v quiet
        if ($LASTEXITCODE -ne 0) { throw 'WorkerClockCorrection:LocalBuildFailed' }
        Save-New 'prepared.json' @{ source = $source; seed = $seedSource; delta = $delta; localPublish = 'Passed' }
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
        $plan = @{ kind = 'FilteredKydCaptureApi'; stage = if ($build) { 'Promote' } else { 'Build' };
            source = $source; seedSource = $seedSource; delta = $prepared.delta; original = $observation;
            tag = $tag; repository = 'gateway-api'; previousArtifactReceiptSha256 = $currentReceiptHash;
            adminAmendmentReceiptSha256 = '788df48a7d61756b325ee4692b34a0247835afc9cc5eab6a13b264bec1a446c0';
            scriptSha256 = Hash-File $PSCommandPath; build = $build
            purpose = 'Reject incompatible full-content capture for specific-SIT KYD reviews and pending confirmations; preserve valid filtered requests and historical accepted replays.'
            costScope = 'One existing ACR API image build; no new recurring resources.' }
        if ($build) {
            $target = Copy-Object $observation.api
            $target.properties.template.containers[0].image = $build.image
            $plan.targetApi = $target
            $correction = Read-RestPredispatchCorrection $source
            if ($correction) { $plan.predispatchCorrection = $correction }
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
    $reader = @{ Registry = 'acrgw0911gdevdbilxu'; Repository = 'gateway-api'; Tag = $tag; TagContract = 'MaintenanceV1' }
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
                '--registry','acrgw0911gdevdbilxu','--image',"gateway-api:$tag",'--file','src/Gateway.Api/Dockerfile',
                $context,'--no-logs','--query','{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}}')
            $null = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository 'gateway-api' -Tag $tag -TagContract MaintenanceV1
            $runs = @(Get-GatewayAcrExactImageRuns @reader)
        }
        if ($runs.Count -ne 1) { throw 'WorkerClockCorrection:UnknownBuildOutcomeNoReplay' }
        $run = Get-GatewayAcrExactRunById @reader -RunId $runs[0].runId
        $null = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository 'gateway-api' -Tag $tag -TagContract MaintenanceV1
        $digest = @($run.outputImages)[0].digest
        if ((Get-GatewayAcrExactTagDigest @reader).digest -cne $digest) { throw 'WorkerClockCorrection:ImageDigestChanged' }
        $result = @{ plan = $ApprovalFingerprint; source = $source; runId = $run.runId; image = "acrgw0911gdevdbilxu.azurecr.io/gateway-api@$digest" }
        if ($build) { Equal $build $result 'BuildReceiptChanged' } else { Save-New 'build.json' $result }
        return
    }
    if ($plan.stage -cne 'Promote' -or -not $build) { throw 'WorkerClockCorrection:WrongStage' }
    $correction = Read-RestPredispatchCorrection $source
    if ($correction) {
        if (-not $plan.Contains('predispatchCorrection')) { throw 'KydCaptureApi:NewCorrectionApprovalRequired' }
        Equal $plan.predispatchCorrection $correction 'ReviewedPredispatchCorrection'
    } elseif ($plan.Contains('predispatchCorrection')) { throw 'KydCaptureApi:MissingPredispatchProof' }
    Equal $plan.build $build 'BuildChanged'
    $run = Get-GatewayAcrExactRunById @reader -RunId $build.runId
    $null = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository 'gateway-api' -Tag $tag -TagContract MaintenanceV1
    if ("acrgw0911gdevdbilxu.azurecr.io/gateway-api@$(@($run.outputImages)[0].digest)" -cne $build.image -or
        "acrgw0911gdevdbilxu.azurecr.io/gateway-api@$((Get-GatewayAcrExactTagDigest @reader).digest)" -cne $build.image) { throw 'WorkerClockCorrection:BuiltImageChanged' }
    $expected = Copy-Object $plan.original.api
    $expected.properties.template.containers[0].image = $build.image
    Equal $plan.targetApi $expected 'OnlyImageMayChange'
    $intent = @{ plan = $ApprovalFingerprint; target = $expected }
    $tokenCorrection = $correction -and $correction.Contains('tokenWrapperCorrection')
    $intentName = if ($tokenCorrection) { 'api-token-corrected-intent.json' }
        elseif ($correction) { 'api-corrected-intent.json' } else { 'api-intent.json' }
    if ($correction) { $intent.retainedApiIntentSha256 = $correction.retainedApiIntentSha256 }
    if ($tokenCorrection) { $intent.priorHttpIntentSha256 = $correction.tokenWrapperCorrection.priorHttpIntentSha256 }
    if ($Mode -eq 'Promote' -and -not (Read-Json $intentName)) {
        Equal (Read-Observation) $plan.original 'PrePromotionDrift'
        $token = & $module { Get-GwHotfixArmToken }
        try {
            Save-New $intentName $intent
            $body = @{ properties = @{ template = $expected.properties.template } }
            $response = Invoke-WebRequest -Uri 'https://management.azure.com/subscriptions/6f6ae863-dcb7-456f-a7f0-d6f9887cfb76/resourceGroups/rg-gw0911g-dev/providers/Microsoft.App/containerApps/ca-gateway-api-dev?api-version=2025-01-01' `
                -Method PATCH -Headers @{ Authorization = "Bearer $($token.accessToken)" } -ContentType 'application/json' `
                -Body ($body | ConvertTo-Json -Depth 100 -Compress) -MaximumRedirection 0 -TimeoutSec 120 -SkipHttpErrorCheck
            if ([int]$response.StatusCode -notin @(200,201,202)) { throw 'ApiArmWriteNotAccepted' }
        }
        catch { throw 'KydCaptureApi:ArmOutcomeUnverifiedReconcileOnlyNoReplay' }
        finally { $token = $null }
    }
    $savedIntent = Read-Json $intentName
    if (-not $savedIntent) { throw 'WorkerClockCorrection:UnownedPromotion' }
    Equal $savedIntent $intent 'PromotionIntentChanged'
    $current = Read-Observation
    foreach ($name in @('worker','admin','site','publisher','settings','companionSha256','executions')) {
        Equal $current[$name] $plan.original[$name] "Preserved$name"
    }
    Equal $current.api $expected 'ApiTargetNotYetVerified'
    $receipt = @{ status = 'ExactApiImageVerified'; plan = $ApprovalFingerprint; source = $source;
        image = $build.image; runtimeBindingsAndOtherConfigurationPreserved = $true; privateExecutorArtifactUnchanged = $true;
        adminAmendmentReceiptSha256 = '788df48a7d61756b325ee4692b34a0247835afc9cc5eab6a13b264bec1a446c0' }
    if ($correction) { $receipt.predispatchCorrection = $correction }
    $receiptName = if ($tokenCorrection) { 'verified-token-corrected.json' }
        elseif ($correction) { 'verified-corrected.json' } else { 'verified.json' }
    $oldReceipt = Read-Json $receiptName
    if ($oldReceipt) { Equal $oldReceipt $receipt 'VerificationReceiptChanged' } else { Save-New $receiptName $receipt }
    $receipt | ConvertTo-Json -Compress
}
finally { $lock.Dispose() }
