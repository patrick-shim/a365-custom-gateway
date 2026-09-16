#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeJson.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeOperator.psm1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap\modules\Common.psm1') -DisableNameChecking
$script:AbortRoot = Split-Path -Parent $PSScriptRoot
$script:AbortInventory = @('actions\coordination-container\intent.json', 'actions\coordination-container\result.json', 'lease.json')
$script:AbortJournalNames = @('intent.json', 'renew-intent.json', 'renew-result.json', 'release-intent.json', 'release-result.json', 'terminal.json')

function Assert-GatewayAbortShape {
    param($Value, [string[]]$Keys)
    if ($Value -isnot [Collections.IDictionary] -or $Value.Count -ne $Keys.Count -or
        @($Value.Keys | Where-Object { $_ -cnotin $Keys }).Count) { throw 'UpgradeAbort: unsupported record shape.' }
}

function Assert-GatewayAbortHash {
    param($Value)
    if ($Value -isnot [string] -or $Value -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'UpgradeAbort: canonical fingerprint required.' }
}

function Resolve-GatewayAbortPath {
    param([string]$Path, [string]$Root, [switch]$AllowMissing)
    $full = [IO.Path]::GetFullPath($Path)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not $full.StartsWith("$base\", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'UpgradeAbort: evidence path escaped its workspace.'
    }
    $part = $base
    foreach ($segment in @('') + [IO.Path]::GetRelativePath($base, $full).Split('\')) {
        if ($segment) { $part = Join-Path $part $segment }
        if (Test-Path -LiteralPath $part) {
            if ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'UpgradeAbort: linked evidence is forbidden.'
            }
        } elseif (-not $AllowMissing) { throw 'UpgradeAbort: required evidence is absent.' }
    }
    return $full
}

function Get-GatewayAbortOwner {
    return Get-GatewayUpgradeFingerprint @{
        machine = [Environment]::MachineName
        user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
}

function Get-GatewayAbortFileBinding {
    param([string]$Path, [string]$Root)
    $full = Resolve-GatewayAbortPath $Path $Root
    return @{ path = $full; sha256 = Get-GatewayUpgradeFileHash $full }
}

function Get-GatewayAbortToolManifest {
    return @(& (Get-Module GatewayUpgrade) {
        param($root)
        Get-GatewayUpgradeSourceManifest $root | Where-Object {
            $_.path -cmatch '^(bootstrap\\modules\\.*\.psm1|operations\\GatewayUpgrade.*\.psm1|operations\\gateway-upgrade(?:-baseline)?\.ps1|tools\\_common\.ps1)$'
        }
    } $script:AbortRoot)
}

function Invoke-GatewayAbortOriginalValidator {
    param([string]$BundleRoot, [string]$OriginalPlanPath, [string]$ExpectedOriginalPlanFingerprint,
        [string]$StatePath, [string]$ConfigPath)
    $inputJson = ConvertTo-Json -Compress @{
        root = $BundleRoot; plan = $OriginalPlanPath; expected = $ExpectedOriginalPlanFingerprint; state = $StatePath; config = $ConfigPath
    }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($inputJson))
    $code = @'
$ErrorActionPreference='Stop'
$WarningPreference='SilentlyContinue'
$x=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__'))) -AsHashtable
Import-Module (Join-Path $x.root 'operations\GatewayUpgrade.psm1') -Force
Import-Module (Join-Path $x.root 'operations\GatewayUpgradePlan.psm1') -Force
$p=Read-GatewayUpgradeJson $x.plan
$null=Test-GatewayUpgradePlanV2 $p $x.expected $x.state $x.config
[Console]::Out.WriteLine('A365GW_ABORT_ORIGINAL_VALIDATED:'+$x.expected)
'@
    $code = $code.Replace('__PAYLOAD__', $payload)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME 'pwsh.exe'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'UpgradeAbort: original validator did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(180000)) {
            $process.Kill($true); $process.WaitForExit()
            throw 'UpgradeAbort: original validator timed out; no result accepted.'
        }
        $text = $stdout.GetAwaiter().GetResult(); $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $text.Trim() -cne "A365GW_ABORT_ORIGINAL_VALIDATED:$ExpectedOriginalPlanFingerprint") {
            throw 'UpgradeAbort: pinned original Plan validator rejected its original bindings; child details suppressed.'
        }
    } finally { $process.Dispose() }
}

function Test-GatewayUpgradeAbortOriginalPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OriginalPlanPath, [Parameter(Mandatory)][string]$ExpectedOriginalPlanFingerprint,
        [Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$WorkspaceRoot)
    Assert-GatewayAbortHash $ExpectedOriginalPlanFingerprint
    $planFile = Get-GatewayAbortFileBinding $OriginalPlanPath $WorkspaceRoot
    $envelope = Read-GatewayUpgradeJson $planFile.path
    Assert-GatewayAbortShape $envelope @('planFingerprint','plan')
    $plan = $envelope.plan
    if ($envelope.planFingerprint -cne $ExpectedOriginalPlanFingerprint -or
        (Get-GatewayUpgradeFingerprint $plan) -cne $ExpectedOriginalPlanFingerprint -or
        $plan.schemaVersion -ne 2 -or $plan.executionSupported -ne $true -or
        $plan.request.schemaVersion -ne 2 -or $plan.request.mode -cne 'SourceOnlyFull') {
        throw 'UpgradeAbort: exact previously approved executable SourceOnlyFull Plan required.'
    }
    $stateFile = Get-GatewayAbortFileBinding $StatePath $WorkspaceRoot
    $configFile = Get-GatewayAbortFileBinding $ConfigPath $WorkspaceRoot
    if ($stateFile.sha256 -cne $plan.original.stateSha256 -or $configFile.sha256 -cne $plan.original.configSha256) {
        throw 'UpgradeAbort: original state or configuration changed.'
    }
    Assert-GatewayAbortHash $plan.candidate.fingerprint
    $candidate = Resolve-GatewayAbortPath $plan.localValidation.sourceRoot $WorkspaceRoot
    $expectedCandidate = Join-Path ([IO.Path]::GetFullPath($WorkspaceRoot)) ".maintenance\candidates\$($plan.candidate.fingerprint.Substring(7))\source"
    if (-not $candidate.Equals($expectedCandidate, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'UpgradeAbort: original validator candidate is outside its immutable candidate directory.'
    }
    $verifiers = @($plan.content.verifierManifest)
    if ($verifiers.Count -lt 10 -or (Get-GatewayUpgradeFingerprint $verifiers) -cne $plan.content.verifierFingerprint) {
        throw 'UpgradeAbort: original verifier manifest is incomplete.'
    }
    $bundle = Resolve-GatewayAbortPath (Join-Path $WorkspaceRoot ".maintenance\abort-validation\$($plan.content.verifierFingerprint.Substring(7))") $WorkspaceRoot -AllowMissing
    $origins = [Collections.Generic.List[object]]::new()
    foreach ($entry in $verifiers) {
        Assert-GatewayAbortShape $entry @('path','sha256')
        Assert-GatewayAbortHash $entry.sha256
        if ($entry.path -cnotmatch '^(bootstrap\\modules\\[A-Za-z0-9_.-]+\.psm1|operations\\[A-Za-z0-9_.-]+\.ps(?:1|m1)|tools\\_common\.ps1)$') {
            throw 'UpgradeAbort: original verifier file is outside its literal allowlist.'
        }
        $source = Join-Path $candidate $entry.path
        $origin = 'OriginalCandidate'
        # Packaging deliberately omits tools\_common.ps1. Restore only the exact
        # old-Plan-pinned verifier bytes into this separate validator bundle.
        if (-not (Test-Path -LiteralPath $source)) {
            if ($entry.path -cne 'tools\_common.ps1') { throw 'UpgradeAbort: immutable original verifier file is absent.' }
            $source = Join-Path $script:AbortRoot $entry.path
            $origin = 'OriginalPlanPinnedMainHelper'
        }
        $source = Resolve-GatewayAbortPath $source $WorkspaceRoot
        if ((Get-GatewayUpgradeFileHash $source) -cne $entry.sha256) { throw 'UpgradeAbort: original verifier bytes differ.' }
        $origins.Add(@{ path = $entry.path; sha256 = $entry.sha256; origin = $origin; sourcePath = $source })
        $destination = Resolve-GatewayAbortPath (Join-Path $bundle $entry.path) $WorkspaceRoot -AllowMissing
        if (-not (Test-Path -LiteralPath $destination)) {
            [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            [IO.File]::Copy($source, $destination, $false)
        }
        if ((Get-GatewayUpgradeFileHash $destination) -cne $entry.sha256) { throw 'UpgradeAbort: pinned validator bundle changed.' }
    }
    $actual = @(Get-ChildItem -LiteralPath $bundle -Recurse -File -Force | ForEach-Object {
        Resolve-GatewayAbortPath $_.FullName $WorkspaceRoot | Out-Null
        [IO.Path]::GetRelativePath($bundle, $_.FullName)
    })
    if ($actual.Count -ne $verifiers.Count -or @($actual | Where-Object { $_ -cnotin $verifiers.path }).Count) {
        throw 'UpgradeAbort: unapproved file in original validator bundle.'
    }
    Invoke-GatewayAbortOriginalValidator $bundle $planFile.path $ExpectedOriginalPlanFingerprint $stateFile.path $configFile.path
    if ((Get-GatewayUpgradeFileHash $planFile.path) -cne $planFile.sha256) { throw 'UpgradeAbort: original Plan changed during validation.' }
    return @{ envelope = $envelope; planFile = $planFile; stateFile = $stateFile; configFile = $configFile
        validator = @{ root = $bundle; manifest = $verifiers; fingerprint = $plan.content.verifierFingerprint; origins = $origins.ToArray() } }
}

function Get-GatewayAbortExecutionBinding {
    param($Original, [string]$WorkspaceRoot)
    $plan = $Original.envelope.plan
    $fingerprint = $Original.envelope.planFingerprint
    $directory = Resolve-GatewayAbortPath (Join-Path $WorkspaceRoot ".maintenance\executions\$($fingerprint.Substring(7))") $WorkspaceRoot
    $files = @(Get-ChildItem -LiteralPath $directory -Recurse -File -Force)
    $entries = @($files | ForEach-Object {
        @{ path = [IO.Path]::GetRelativePath($directory, $_.FullName); sha256 = (Get-GatewayAbortFileBinding $_.FullName $WorkspaceRoot).sha256 }
    } | Sort-Object path)
    if ($entries.Count -ne 3 -or @($entries.path | Where-Object { $_ -cnotin $script:AbortInventory }).Count) {
        throw 'UpgradeAbort: execution is not the exact three-file pre-cutover checkpoint.'
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $directory -Recurse -Directory -Force)) {
        $relative = [IO.Path]::GetRelativePath($directory, $dir.FullName)
        if ($relative -cnotin @('actions','actions\coordination-container')) { throw 'UpgradeAbort: unexpected execution directory or active cutover.' }
        $null = Resolve-GatewayAbortPath $dir.FullName $WorkspaceRoot
    }
    $lease = Read-GatewayUpgradeJson (Join-Path $directory 'lease.json')
    Assert-GatewayAbortShape $lease @('schemaVersion','planFingerprint','leaseId','containerId','ownerFingerprint')
    $containers = @($plan.scope.resources | Where-Object { $_.stage -ceq 'Coordination' })
    if ($containers.Count -ne 1) { throw 'UpgradeAbort: exact original coordination scope is missing.' }
    $containerId = $containers[0].resourceId
    if ($lease.schemaVersion -ne 1 -or $lease.planFingerprint -cne $fingerprint -or $lease.containerId -cne $containerId -or
        $lease.ownerFingerprint -cne (Get-GatewayAbortOwner) -or
        $lease.leaseId -cne ([guid]$lease.leaseId).ToString('D') -or $lease.leaseId -ceq [guid]::Empty.ToString('D')) {
        throw 'UpgradeAbort: retained lease belongs to another Plan, owner or target.'
    }
    $metadata = @{ gatewayowner = $plan.request.target.deploymentOwnershipId; gatewaybootstrap = $plan.original.acceptedSourceFingerprint }
    foreach ($kind in @('intent','result')) {
        $record = Read-GatewayUpgradeJson (Join-Path $directory "actions\coordination-container\$kind.json")
        Assert-GatewayAbortShape $record @('record','fingerprint')
        Assert-GatewayAbortShape $record.record @('schemaVersion','planFingerprint','originalStateSha256','action','kind','value')
        if ((Get-GatewayUpgradeFingerprint $record.record) -cne $record.fingerprint -or
            $record.record.schemaVersion -ne 1 -or $record.record.planFingerprint -cne $fingerprint -or
            $record.record.originalStateSha256 -cne $plan.original.stateSha256 -or
            $record.record.action -cne 'coordination-container' -or $record.record.kind -cne $kind) {
            throw 'UpgradeAbort: original coordination evidence differs.'
        }
        $expected = @{ id = $containerId; metadata = $metadata }
        if ($kind -ceq 'intent') {
            if ((Get-GatewayUpgradeFingerprint $record.record.value.input) -cne (Get-GatewayUpgradeFingerprint $expected) -or
                $record.record.value.inputFingerprint -cne (Get-GatewayUpgradeFingerprint $expected)) { throw 'UpgradeAbort: coordination intent differs.' }
        } else {
            $expected.publicAccess = 'None'
            if ((Get-GatewayUpgradeFingerprint $record.record.value) -cne (Get-GatewayUpgradeFingerprint $expected)) { throw 'UpgradeAbort: coordination result differs.' }
        }
    }
    return @{ directory = $directory; inventory = $entries; lease = $lease; metadata = $metadata }
}

function Get-GatewayAbortBinding {
    param($Original, [string]$WorkspaceRoot)
    $plan = $Original.envelope.plan
    foreach ($entry in $Original.validator.manifest) {
        if ($entry.path -cin @('operations\GatewayUpgradeExecution.psm1','operations\gateway-upgrade.ps1')) { continue }
        if ((Get-GatewayUpgradeFileHash (Join-Path $script:AbortRoot $entry.path)) -cne $entry.sha256) {
            throw 'UpgradeAbort: canonical baseline/operator/validator code in the current checkout changed from the original Plan.'
        }
    }
    $state = Read-GatewayUpgradeJson $Original.stateFile.path
    $accepted = Resolve-BootstrapAcceptedSourceRoot -State $state
    if ((Get-BootstrapSourceFingerprint -Root $accepted) -cne $plan.original.acceptedSourceFingerprint) {
        throw 'UpgradeAbort: original accepted assets changed.'
    }
    $execution = Get-GatewayAbortExecutionBinding $Original $WorkspaceRoot
    $manifest = Get-GatewayAbortToolManifest
    return @{
        schemaVersion = 1; operation = 'AbortBeforeCutoverOnly'
        originalPlan = $Original.planFile; originalPlanFingerprint = $Original.envelope.planFingerprint
        candidate = $plan.candidate; candidateSourceFingerprint = $plan.content.sourceFingerprint
        artifacts = Get-GatewayAbortFileBinding $plan.artifacts.reference $WorkspaceRoot
        state = $Original.stateFile; config = $Original.configFile
        originalValidator = $Original.validator
        acceptedAssets = @{ root = $accepted; fingerprint = $plan.original.acceptedSourceFingerprint }
        execution = $execution; authorizedOperator = $plan.authorizedOperator
        driver = @{ root = $script:AbortRoot; manifest = $manifest; fingerprint = Get-GatewayUpgradeFingerprint $manifest
            powerShellPath = Join-Path $PSHOME 'pwsh.exe'; powerShellSha256 = Get-GatewayUpgradeFileHash (Join-Path $PSHOME 'pwsh.exe') }
        permittedLeaseActions = @('Renew','Release'); reacquireAllowed = $false
    }
}

function Read-GatewayAbortReview {
    param([string]$Path, $Authority, [string]$WorkspaceRoot)
    if (-not $Path) { return $null }
    $file = Get-GatewayAbortFileBinding $Path $WorkspaceRoot
    $review = Read-GatewayUpgradeJson $file.path
    Assert-GatewayAbortShape $review @('schemaVersion','decision','reviewerModel','authorityFingerprint','originalPlanFingerprint','driverFingerprint','evidencePath','evidenceSha256')
    if ($review.schemaVersion -ne 1 -or $review.decision -cne 'ApprovedAbortBeforeCutover' -or
        $review.reviewerModel -cne 'gpt-6-astra' -or $review.authorityFingerprint -cne (Get-GatewayUpgradeFingerprint $Authority) -or
        $review.originalPlanFingerprint -cne $Authority.originalPlanFingerprint -or $review.driverFingerprint -cne $Authority.driver.fingerprint -or
        (Get-GatewayAbortFileBinding $review.evidencePath $WorkspaceRoot).sha256 -cne $review.evidenceSha256) {
        throw 'UpgradeAbort: separate genuine lifecycle/source review is missing or bound to other authority.'
    }
    return @{ file = $file; record = $review }
}

function New-GatewayAbortContext {
    param($Original, $Authority, [string]$WorkspaceRoot)
    $plan = $Original.envelope.plan
    $allowed = @($Authority.execution.lease.containerId, "$($plan.scope.resourceGroupId)/providers/Microsoft.Resources/deployments",
        $plan.cutover.ApiResourceId, $plan.cutover.WorkerResourceId, $plan.cutover.ProvisioningQueueResourceId, $plan.cutover.ProtectionQueueResourceId)
    $allowed += @($plan.scope.resources | Where-Object { $_.resourceId -match '/Microsoft.App/jobs/|/Microsoft.App/containerApps/' } | ForEach-Object resourceId)
    $allowed += @($plan.scope.privilegedMutations | ForEach-Object resourceId)
    return @{ original = $Original; authority = $Authority; workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
        allowedReadIds = @($allowed | Select-Object -Unique)
        journal = Join-Path $WorkspaceRoot ".maintenance\abort-state\$($Authority.originalPlanFingerprint.Substring(7))" }
}

function Invoke-GatewayAbortArm {
    param($Context, [ValidateSet('GET','Renew','Release')][string]$Action, [string]$ResourceId, [string]$ApiVersion, [switch]$AllowNotFound)
    if ($Action -ceq 'GET') {
        if ($ResourceId -cnotin $Context.allowedReadIds) { throw 'UpgradeAbort: read escaped exact original scopes.' }
    } elseif ($ResourceId -cne $Context.authority.execution.lease.containerId) { throw 'UpgradeAbort: lease write escaped the original coordinator.' }
    if ($ApiVersion -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' -or $ResourceId -match '[?#]' -or $ResourceId.Contains('..')) {
        throw 'UpgradeAbort: malformed ARM address.'
    }
    $target = $Context.original.envelope.plan.request.target
    $credential = Invoke-AzJson -Arguments @('account','get-access-token','--subscription',$target.subscriptionId,
        '--resource','https://management.azure.com/','--query','{accessToken:accessToken,tenant:tenant}')
    if ($credential.tenant -cne $target.tenantId -or $credential.accessToken -isnot [string] -or [string]::IsNullOrWhiteSpace($credential.accessToken)) {
        throw 'UpgradeAbort: ARM credential tenant mismatch.'
    }
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(120)
    $url = "https://management.azure.com$ResourceId$(if ($Action -cne 'GET') { '/lease' })?api-version=$ApiVersion"
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($(if ($Action -ceq 'GET') { 'GET' } else { 'POST' })), $url)
    try {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $credential.accessToken)
        if ($Action -cne 'GET') {
            $body = @{ action = $Action; leaseId = $Context.authority.execution.lease.leaseId }
            $request.Content = [Net.Http.StringContent]::new((ConvertTo-Json $body -Compress), [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            if ($Action -ceq 'GET' -and $AllowNotFound -and [int]$response.StatusCode -eq 404) { return $null }
            if ([int]$response.StatusCode -notin @(200,204)) { throw "UpgradeAbort: ARM HTTP $([int]$response.StatusCode); outcome is not inferred." }
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ($text.Length -gt 4194304) { throw 'UpgradeAbort: oversized ARM response.' }
            $value = ConvertFrom-GatewayUpgradeArmJson -Json $text
            if ($Action -cne 'GET' -and $value.Contains('leaseId') -and $value.leaseId -cne $Context.authority.execution.lease.leaseId) {
                throw 'UpgradeAbort: lease acknowledgement differs from the exact retained lease ID.'
            }
            return $value
        } finally { $response.Dispose() }
    } finally { $request.Dispose(); $client.Dispose(); $credential = $null }
}

function Get-GatewayAbortLeaseState {
    param($Context)
    $value = Invoke-GatewayAbortArm $Context GET $Context.authority.execution.lease.containerId '2023-05-01'
    if ($value.properties.publicAccess -cne 'None' -or
        -not ([string]$value.id).Equals($Context.authority.execution.lease.containerId, [StringComparison]::OrdinalIgnoreCase) -or
        (Get-GatewayUpgradeFingerprint $value.properties.metadata) -cne (Get-GatewayUpgradeFingerprint $Context.authority.execution.metadata)) {
        throw 'UpgradeAbort: coordinator identity, privacy or ownership changed.'
    }
    if ($value.properties.leaseState -ieq 'Leased' -and $value.properties.leaseDuration -ine 'Infinite') {
        throw 'UpgradeAbort: the retained infinite lease has an unexpected duration.'
    }
    return @{ state = ([string]$value.properties.leaseState).ToLowerInvariant(); status = ([string]$value.properties.leaseStatus).ToLowerInvariant() }
}

function Get-GatewayAbortLiveBoundary {
    param($Context)
    $plan = $Context.original.envelope.plan
    $inputs = @{ statePath = $Context.authority.state.path; stateSha256 = $Context.authority.state.sha256
        configPath = $Context.authority.config.path; configSha256 = $Context.authority.config.sha256 }
    $baseline = & (Get-Module GatewayUpgrade) { param($inputs) Invoke-GatewayUpgradeBaselineProcess $inputs } $inputs
    if ($baseline.status -cne 'Passed') { throw 'UpgradeAbort: independent original healthy baseline did not pass.' }
    $stable = @{}
    foreach ($id in @($plan.cutover.ApiResourceId, $plan.cutover.WorkerResourceId) +
        @($plan.scope.resources | Where-Object stage -CEQ 'Admin' | ForEach-Object resourceId)) {
        $app = Invoke-GatewayAbortArm $Context GET $id '2025-01-01'
        $ingress = if ($app.properties.configuration.Contains('ingress')) { $app.properties.configuration.ingress } else { $null }
        $rules = @()
        if ($null -ne $ingress -and $ingress.Contains('ipSecurityRestrictions') -and $null -ne $ingress.ipSecurityRestrictions) {
            if ($ingress.ipSecurityRestrictions -isnot [array]) { throw 'UpgradeAbort: malformed ingress restriction collection.' }
            $rules = $ingress.ipSecurityRestrictions
        }
        foreach ($rule in $rules) {
            if ($rule -isnot [Collections.IDictionary] -or -not $rule.Contains('name') -or
                $rule.name -isnot [string] -or [string]::IsNullOrWhiteSpace($rule.name) -or
                -not $rule.Contains('ipAddressRange') -or $rule.ipAddressRange -isnot [string] -or
                [string]::IsNullOrWhiteSpace($rule.ipAddressRange) -or
                -not $rule.Contains('action') -or $rule.action -isnot [string] -or $rule.action -cnotin @('Allow','Deny')) {
                throw 'UpgradeAbort: malformed ingress restriction entry.'
            }
            if ($rule.name -ceq 'gateway-maintenance-deny') {
                throw 'UpgradeAbort: workload has a maintenance ingress hold; pre-cutover abort is forbidden.'
            }
        }
        if (-not ([string]$app.id).Equals($id, [StringComparison]::OrdinalIgnoreCase) -or
            $app.properties.provisioningState -cne 'Succeeded') {
            throw 'UpgradeAbort: workload is not an untouched healthy pre-cutover application.'
        }
        $environmentId = if ($app.properties.Contains('environmentId') -and $app.properties.environmentId) {
            $app.properties.environmentId
        } else { $app.properties.managedEnvironmentId }
        $stable[$id] = @{ identity = $app.identity; tags = $app.tags; environmentId = $environmentId
            configuration = $app.properties.configuration; template = $app.properties.template }
    }
    foreach ($id in @($plan.cutover.ProvisioningQueueResourceId, $plan.cutover.ProtectionQueueResourceId)) {
        $queue = Invoke-GatewayAbortArm $Context GET $id '2024-01-01'
        if (-not ([string]$queue.id).Equals($id, [StringComparison]::OrdinalIgnoreCase) -or $queue.properties.status -ine 'Active') {
            throw 'UpgradeAbort: queue identity differs or is held; pre-cutover abort is forbidden.'
        }
        foreach ($key in @('createdAt','updatedAt','accessedAt','sizeInBytes','messageCount','countDetails')) { $queue.properties.Remove($key) }
        $stable[$id] = $queue.properties
    }
    $sql = @($plan.scope.privilegedMutations | Where-Object operation -CEQ 'TemporarySqlAdministratorDelegation')
    if ($sql.Count -ne 1) { throw 'UpgradeAbort: original SQL administrator scope is ambiguous.' }
    $admin = Invoke-GatewayAbortArm $Context GET $sql[0].resourceId '2023-08-01'
    if (-not ([string]$admin.id).Equals($sql[0].resourceId, [StringComparison]::OrdinalIgnoreCase) -or
        $admin.properties.sid -cne $sql[0].restoreObjectId -or $admin.properties.login -cne $sql[0].restoreLogin -or
        $admin.properties.tenantId -cne $plan.request.target.tenantId) { throw 'UpgradeAbort: original SQL administrator is not restored/unchanged.' }
    $stable[$sql[0].resourceId] = $admin.properties
    foreach ($job in @($plan.scope.resources | Where-Object { $_.resourceId -match '/Microsoft.App/jobs/' })) {
        if ($null -ne (Invoke-GatewayAbortArm $Context GET $job.resourceId '2025-01-01' -AllowNotFound)) {
            throw 'UpgradeAbort: a planned mutation job exists; pre-cutover abort is forbidden.'
        }
    }
    $deployments = Invoke-GatewayAbortArm $Context GET "$($plan.scope.resourceGroupId)/providers/Microsoft.Resources/deployments" '2025-04-01'
    if (-not $deployments.Contains('value') -or $deployments.value -isnot [array] -or
        ($deployments.Contains('nextLink') -and $deployments.nextLink) -or
        @($deployments.value | Where-Object { $_.name -clike "maintenance-*-$($Context.authority.originalPlanFingerprint.Substring(7,10))" }).Count) {
        throw 'UpgradeAbort: deployment absence is incomplete or a Plan mutation deployment exists.'
    }
    return @{ baseline = $baseline; stable = $stable; lease = Get-GatewayAbortLeaseState $Context }
}

function Enter-GatewayAbortLocalLock {
    param($Context)
    $owner = $Context.original.envelope.plan.request.target.deploymentOwnershipId
    $path = Resolve-GatewayAbortPath (Join-Path $Context.workspace ".maintenance\locks\$owner.lock") $Context.workspace
    return [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}

function Write-GatewayAbortRecord {
    param($Context, [string]$Name, $Value)
    if ($Name -cnotin $script:AbortJournalNames) { throw 'UpgradeAbort: unapproved journal action.' }
    $path = Resolve-GatewayAbortPath (Join-Path $Context.journal $Name) $Context.workspace -AllowMissing
    [IO.Directory]::CreateDirectory($Context.journal) | Out-Null
    $record = @{ schemaVersion = 1; abortPlanFingerprint = $Context.abortPlanFingerprint
        originalPlanFingerprint = $Context.authority.originalPlanFingerprint
        authorityFingerprint = Get-GatewayUpgradeFingerprint $Context.authority; action = $Name; value = $Value }
    $envelope = @{ fingerprint = Get-GatewayUpgradeFingerprint $record; record = $record }
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $envelope -Depth 100))
        $stream.Write($bytes); $stream.Flush($true)
    } finally { $stream.Dispose() }
    $readback = Read-GatewayUpgradeJson $path
    if ($readback.fingerprint -cne $envelope.fingerprint -or
        (Get-GatewayUpgradeFingerprint $readback.record) -cne $envelope.fingerprint) {
        throw 'UpgradeAbort: journal did not retain its exact serialized fingerprint.'
    }
}

function Read-GatewayAbortJournal {
    param($Context)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Context.journal)) { return $result }
    $null = Resolve-GatewayAbortPath $Context.journal $Context.workspace
    foreach ($file in Get-ChildItem -LiteralPath $Context.journal -Force) {
        if ($file.PSIsContainer -or $file.Name -cnotin $script:AbortJournalNames) { throw 'UpgradeAbort: unexpected lifecycle journal entry.' }
        $null = Resolve-GatewayAbortPath $file.FullName $Context.workspace
        $entry = Read-GatewayUpgradeJson $file.FullName
        Assert-GatewayAbortShape $entry @('fingerprint','record')
        Assert-GatewayAbortShape $entry.record @('schemaVersion','abortPlanFingerprint','originalPlanFingerprint','authorityFingerprint','action','value')
        if ((Get-GatewayUpgradeFingerprint $entry.record) -cne $entry.fingerprint -or
            $entry.record.schemaVersion -ne 1 -or $entry.record.action -cne $file.Name -or
            $entry.record.abortPlanFingerprint -cne $Context.abortPlanFingerprint -or
            $entry.record.originalPlanFingerprint -cne $Context.authority.originalPlanFingerprint -or
            $entry.record.authorityFingerprint -cne (Get-GatewayUpgradeFingerprint $Context.authority)) {
            throw 'UpgradeAbort: lifecycle journal authority or content changed.'
        }
        $result[$file.Name] = $entry.record.value
    }
    if ($result.Count -eq 0 -or -not $result.Contains('intent.json')) { throw 'UpgradeAbort: partial abort admission requires manual reconciliation.' }
    foreach ($pair in @(@('renew-result.json','renew-intent.json'), @('release-intent.json','renew-result.json'),
        @('release-result.json','release-intent.json'), @('terminal.json','release-intent.json'))) {
        if ($result.Contains($pair[0]) -and -not $result.Contains($pair[1])) { throw 'UpgradeAbort: noncontiguous abort evidence.' }
    }
    return $result
}

function Assert-GatewayAbortAuthority {
    param($Context)
    $a = $Context.authority
    if ((Get-GatewayUpgradeFingerprint (Get-GatewayAbortToolManifest)) -cne $a.driver.fingerprint -or
        (Get-GatewayUpgradeFingerprint $a.driver.manifest) -cne $a.driver.fingerprint) { throw 'UpgradeAbort: reviewed driver/tool closure changed.' }
    $original = Test-GatewayUpgradeAbortOriginalPlan $a.originalPlan.path $a.originalPlanFingerprint $a.state.path $a.config.path $Context.workspace
    $binding = Get-GatewayAbortBinding $original $Context.workspace
    if ((Get-GatewayUpgradeFingerprint $binding) -cne (Get-GatewayUpgradeFingerprint $a)) { throw 'UpgradeAbort: original authority/source/lease/evidence binding changed.' }
    $null = Assert-GatewayUpgradeCurrentOperator $original.envelope.plan
    $review = Read-GatewayAbortReview $Context.abortPlan.review.file.path $a $Context.workspace
    if ((Get-GatewayUpgradeFingerprint $review) -cne (Get-GatewayUpgradeFingerprint $Context.abortPlan.review)) {
        throw 'UpgradeAbort: genuine review evidence changed.'
    }
}

function New-GatewayUpgradeAbortPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OriginalPlanPath, [Parameter(Mandatory)][string]$ExpectedOriginalPlanFingerprint,
        [Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$WorkspaceRoot, [string]$ReviewPath)
    $original = Test-GatewayUpgradeAbortOriginalPlan $OriginalPlanPath $ExpectedOriginalPlanFingerprint $StatePath $ConfigPath $WorkspaceRoot
    $authority = Get-GatewayAbortBinding $original $WorkspaceRoot
    $context = New-GatewayAbortContext $original $authority $WorkspaceRoot
    $lock = Enter-GatewayAbortLocalLock $context
    try {
        if (Test-Path -LiteralPath $context.journal) { throw 'UpgradeAbort: an abort is already admitted; use its exact existing Plan for reconciliation.' }
        $null = Assert-GatewayUpgradeCurrentOperator $original.envelope.plan
        $review = Read-GatewayAbortReview $ReviewPath $authority $WorkspaceRoot
        $live = Get-GatewayAbortLiveBoundary $context
        if ($live.lease.state -cne 'leased' -or $live.lease.status -cne 'locked') { throw 'UpgradeAbort: only the existing held lease can be planned; never acquire/break.' }
        if ((Get-GatewayUpgradeFingerprint (Get-GatewayAbortBinding $original $WorkspaceRoot)) -cne (Get-GatewayUpgradeFingerprint $authority)) {
            throw 'UpgradeAbort: source/evidence changed during read-only planning.'
        }
        $plan = @{ schemaVersion = 1; operation = 'GatewayAbortBeforeCutoverPlan'; createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            authority = $authority; authorityFingerprint = Get-GatewayUpgradeFingerprint $authority; review = $review
            executionSupported = $null -ne $review; observations = $live }
        $envelope = @{ abortPlanFingerprint = Get-GatewayUpgradeFingerprint $plan; plan = $plan }
        $path = Resolve-GatewayAbortPath (Join-Path $WorkspaceRoot ".maintenance\abort-plans\$($envelope.abortPlanFingerprint.Substring(7)).json") $WorkspaceRoot -AllowMissing
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $envelope -Depth 100))); $stream.Flush($true) } finally { $stream.Dispose() }
        $readback = Read-GatewayUpgradeJson $path
        if ($readback.abortPlanFingerprint -cne $envelope.abortPlanFingerprint -or
            (Get-GatewayUpgradeFingerprint $readback.plan) -cne $envelope.abortPlanFingerprint) {
            throw 'UpgradeAbort: Plan did not retain its exact serialized fingerprint; no approval is permitted.'
        }
        return @{ abortPlanPath = $path; abortPlanFingerprint = $envelope.abortPlanFingerprint
            authorityFingerprint = $plan.authorityFingerprint; driverFingerprint = $authority.driver.fingerprint; executionSupported = $plan.executionSupported }
    } finally { $lock.Dispose() }
}

function Invoke-GatewayAbortLeaseLifecycle {
    param($Context, [switch]$Reconcile)
    $journal = Read-GatewayAbortJournal $Context
    if ($journal.Contains('terminal.json')) {
        if ($journal['terminal.json'].status -cne 'AbortBeforeCutoverVerified') { throw 'UpgradeAbort: unsupported terminal status.' }
        return @{ status = 'AbortBeforeCutoverVerified'; disposition = 'ExistingTerminalEvidence'; originalPlanMayResume = $false }
    }
    $live = Get-GatewayAbortLiveBoundary $Context
    if ((Get-GatewayUpgradeFingerprint $live.stable) -cne (Get-GatewayUpgradeFingerprint $Context.abortPlan.observations.stable)) {
        throw 'UpgradeAbort: live original workload/queue/SQL boundary drifted.'
    }
    if ($journal.Count) {
        if ($journal.Contains('release-intent.json') -and $live.lease.state -ceq 'available' -and $live.lease.status -ceq 'unlocked') {
            Write-GatewayAbortRecord $Context 'terminal.json' @{ status = 'AbortBeforeCutoverVerified'; disposition = 'ReleaseObservedWithoutReplay'
                observedAtUtc = [DateTimeOffset]::UtcNow.ToString('O'); baseline = $live.baseline }
            return @{ status = 'AbortBeforeCutoverVerified'; disposition = 'ReleaseObservedWithoutReplay'; originalPlanMayResume = $false }
        }
        throw 'UpgradeAbortReconciliationRequired: existing abort/renew/release intent cannot dispatch another lease operation.'
    }
    if ($Reconcile) { throw 'UpgradeAbort: read-only reconciliation cannot start an abort.' }
    if ($live.lease.state -cne 'leased' -or $live.lease.status -cne 'locked') { throw 'UpgradeAbort: expected existing leased/locked coordinator; no acquisition is permitted.' }
    Write-GatewayAbortRecord $Context 'intent.json' @{ admittedAtUtc = [DateTimeOffset]::UtcNow.ToString('O'); baseline = $live.baseline }
    Assert-GatewayAbortAuthority $Context
    Write-GatewayAbortRecord $Context 'renew-intent.json' @{ leaseFileHash = @($Context.authority.execution.inventory | Where-Object path -CEQ 'lease.json')[0].sha256 }
    $renew = Invoke-GatewayAbortArm $Context Renew $Context.authority.execution.lease.containerId '2023-05-01'
    Write-GatewayAbortRecord $Context 'renew-result.json' @{ acknowledgementFingerprint = Get-GatewayUpgradeFingerprint $renew }
    Assert-GatewayAbortAuthority $Context
    $beforeRelease = Get-GatewayAbortLiveBoundary $Context
    if ((Get-GatewayUpgradeFingerprint $beforeRelease.stable) -cne (Get-GatewayUpgradeFingerprint $Context.abortPlan.observations.stable) -or
        $beforeRelease.lease.state -cne 'leased' -or $beforeRelease.lease.status -cne 'locked') {
        throw 'UpgradeAbortReconciliationRequired: exact renewed lease or original live boundary changed.'
    }
    Assert-GatewayAbortAuthority $Context
    Write-GatewayAbortRecord $Context 'release-intent.json' @{ leaseFileHash = @($Context.authority.execution.inventory | Where-Object path -CEQ 'lease.json')[0].sha256 }
    $release = Invoke-GatewayAbortArm $Context Release $Context.authority.execution.lease.containerId '2023-05-01'
    Write-GatewayAbortRecord $Context 'release-result.json' @{ acknowledgementFingerprint = Get-GatewayUpgradeFingerprint $release }
    $released = Get-GatewayAbortLeaseState $Context
    if ($released.state -cne 'available' -or $released.status -cne 'unlocked') { throw 'UpgradeAbortReconciliationRequired: release is not independently observed; no repeat is authorized.' }
    Write-GatewayAbortRecord $Context 'terminal.json' @{ status = 'AbortBeforeCutoverVerified'; disposition = 'ExactLeaseReleased'
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('O'); baseline = $live.baseline }
    return @{ status = 'AbortBeforeCutoverVerified'; disposition = 'ExactLeaseReleased'; originalPlanMayResume = $false }
}

function Invoke-GatewayUpgradeAbort {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AbortPlanPath, [Parameter(Mandatory)][string]$ExpectedAbortPlanFingerprint,
        [Parameter(Mandatory)][string]$WorkspaceRoot, [switch]$Reconcile)
    Assert-GatewayAbortHash $ExpectedAbortPlanFingerprint
    $path = Resolve-GatewayAbortPath $AbortPlanPath $WorkspaceRoot
    $envelope = Read-GatewayUpgradeJson $path
    Assert-GatewayAbortShape $envelope @('abortPlanFingerprint','plan')
    $plan = $envelope.plan
    Assert-GatewayAbortShape $plan @('schemaVersion','operation','createdAtUtc','authority','authorityFingerprint','review','executionSupported','observations')
    if ($envelope.abortPlanFingerprint -cne $ExpectedAbortPlanFingerprint -or
        (Get-GatewayUpgradeFingerprint $plan) -cne $ExpectedAbortPlanFingerprint -or $plan.schemaVersion -ne 1 -or
        $plan.operation -cne 'GatewayAbortBeforeCutoverPlan' -or $plan.executionSupported -ne $true -or $null -eq $plan.review -or
        (Get-GatewayUpgradeFingerprint $plan.authority) -cne $plan.authorityFingerprint) {
        throw 'UpgradeAbort: exact separately reviewed/approved executable Abort Plan is required.'
    }
    $a = $plan.authority
    $original = Test-GatewayUpgradeAbortOriginalPlan $a.originalPlan.path $a.originalPlanFingerprint $a.state.path $a.config.path $WorkspaceRoot
    $context = New-GatewayAbortContext $original $a $WorkspaceRoot
    $context.abortPlan = $plan; $context.abortPlanFingerprint = $ExpectedAbortPlanFingerprint
    $lock = Enter-GatewayAbortLocalLock $context
    try {
        Assert-GatewayAbortAuthority $context
        return Invoke-GatewayAbortLeaseLifecycle $context -Reconcile:$Reconcile
    } finally { $lock.Dispose() }
}

Export-ModuleMember -Function Test-GatewayUpgradeAbortOriginalPlan, New-GatewayUpgradeAbortPlan, Invoke-GatewayUpgradeAbort
