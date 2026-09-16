[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan','Apply','Verify')][string]$Mode,
    [string]$ApprovalFingerprint = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root '.test-work\live-acceptance-20260912\executor-capacity-b2'
$python = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\python.exe'
$subscription = '6f6ae863-dcb7-456f-a7f0-d6f9887cfb76'
$scope = "/subscriptions/$subscription/resourceGroups/rg-gw0911g-dev"
$planId = "$scope/providers/Microsoft.Web/serverfarms/asp-gw0911g-dev-purview"
$siteId = "$scope/providers/Microsoft.Web/sites/app-gw0911g-dev-purview-roeal6"
$statePath = Join-Path $root ".test-work\fresh-full-0911g\.bootstrap\state\$subscription-rg-gw0911g-dev-dev.json"
$stateHash = '716269a7e668e85b67f8504b8fa1b8d3a6316676f3d8912cef8f7dc653c6a1ac'
function Canonical($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) { $out[$key] = Canonical $Value[$key] }
        return $out
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { Canonical $_ }) }
    return $Value
}
function Fingerprint($Value) {
    'sha256:' + [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes((Canonical $Value | ConvertTo-Json -Depth 50 -Compress))))
}
function Hash-File([string]$Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Equal($Actual,$Expected,[string]$Label) {
    if ((Fingerprint $Actual) -cne (Fingerprint $Expected)) { throw "ExecutorCapacity:$Label" }
}
function Save-New([string]$Name,$Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 50))
    $stream = [IO.File]::Open((Join-Path $work $Name),'CreateNew','Write','None')
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Run([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($python)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    foreach ($arg in @('-X','utf8','-IBm','azure.cli') + $Arguments + @('-o','json','--only-show-errors')) { $start.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync(); $errorOutput = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(180000)) { $process.Kill($true); $process.WaitForExit(); throw 'ExecutorCapacity:OutcomeUnverified' }
        if ($process.ExitCode -ne 0) { throw 'ExecutorCapacity:OutcomeUnverified' }
        if ([string]::IsNullOrWhiteSpace($output.Result)) { return $null }
        return $output.Result | ConvertFrom-Json -AsHashtable -Depth 50 -DateKind String
    } finally { $process.Dispose() }
}
function Arm([string]$Id) { Run @('rest','--method','GET','--url',"https://management.azure.com${Id}?api-version=2024-04-01") }
function Read-Snapshot {
    $plan = Arm $planId
    $site = Arm $siteId
    foreach ($resource in @($plan,$site)) {
        if ($resource.tags.bootstrapOwnershipId -cne '9b34fc6e-3ba5-4d2e-b40d-d706ba23833f' -or
            $resource.tags.bootstrapSourceFingerprint -cne 'sha256:de369d5427906dc782dd5425354b1ca0e427012a279f3360cac6a2ed46a7565c') {
            throw 'ExecutorCapacity:OwnershipChanged'
        }
    }
    if (-not ([string]$plan.id).Equals($planId,[StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$site.id).Equals($siteId,[StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$site.properties.serverFarmId).Equals($planId,[StringComparison]::OrdinalIgnoreCase) -or
        ([string]$plan.location).Replace(' ','').ToLowerInvariant() -cne 'koreacentral' -or $plan.properties.reserved -ne $false -or
        $plan.properties.numberOfSites -ne 1 -or $plan.sku.capacity -ne 1 -or $plan.sku.tier -cne 'Basic' -or
        $site.properties.enabled -ne $true -or $site.properties.state -cne 'Running' -or $plan.properties.status -cne 'Ready') {
        throw 'ExecutorCapacity:DedicatedWindowsPlanBoundaryChanged'
    }
    @{
        sku = @{ name = $plan.sku.name; tier = $plan.sku.tier; capacity = $plan.sku.capacity }
        plan = @{ id = $plan.id.ToLowerInvariant(); location = $plan.location; kind = $plan.kind; tags = $plan.tags
            reserved = $plan.properties.reserved; perSiteScaling = $plan.properties.perSiteScaling; zoneRedundant = $plan.properties.zoneRedundant }
        site = @{ id = $site.id.ToLowerInvariant(); identity = $site.identity; tags = $site.tags
            serverFarmId = $site.properties.serverFarmId; httpsOnly = $site.properties.httpsOnly
            publicNetworkAccess = $site.properties.publicNetworkAccess; virtualNetworkSubnetId = $site.properties.virtualNetworkSubnetId }
    }
}
function Source-Proof {
    $result = [ordered]@{}
    foreach ($path in @('operations\repair-gw0911g-executor-capacity.ps1',
        'bootstrap\infra\purview-windows-executor.bicep','bootstrap\modules\PurviewExecutor.psm1',
        'infrastructure\bicep\maintenance-purview-executor.bicep',
        'operations\GatewayUpgrade.psm1','operations\GatewayUpgradeExecution.psm1','operations\GatewayUpgradePlan.psm1')) {
        $result[$path] = Hash-File (Join-Path $root $path)
    }
    return $result
}
[IO.Directory]::CreateDirectory($work) | Out-Null
$lock = [IO.File]::Open((Join-Path $work 'operation.lock'),'OpenOrCreate','ReadWrite','None')
try {
    if ((Hash-File $statePath) -cne $stateHash) { throw 'ExecutorCapacity:AcceptedStateChanged' }
    $account = Run @('account','show','--query','{id:id,tenantId:tenantId}')
    Equal $account @{ id = $subscription; tenantId = 'ff8b1e46-ff0f-4bc2-ab02-caf2b92da496' } 'AuthorityChanged'
    $me = Run @('rest','--method','GET','--url','https://graph.microsoft.com/v1.0/me?$select=id')
    if ($me.id -cne '2db7287c-9462-404f-810e-17e57377618d') { throw 'ExecutorCapacity:OperatorChanged' }
    $snapshot = Read-Snapshot
    $targetSku = @{ name = 'B2'; tier = 'Basic'; capacity = 1 }
    if ($Mode -ceq 'Plan') {
        Equal $snapshot.sku @{ name = 'B1'; tier = 'Basic'; capacity = 1 } 'OriginalSkuChanged'
        $plan = @{ targetResource = $planId; before = $snapshot; targetSku = $targetSku; sourceProof = Source-Proof
            acceptedStateHash = $stateHash; purpose = 'Two-core capacity for bounded, fresh-inventory PowerShell policy workflows'
            cost = @{ currency = 'USD'; oldHourly = 0.085; newHourly = 0.17; incrementalHourly = 0.085
                oldMonthly730Hours = 62.05; newMonthly730Hours = 124.10; incrementalMonthly730Hours = 62.05
                product = 'Azure App Service Basic Plan'; b1Meter = 'ed30dffb-5e85-41a7-b3b5-8f1f475413d9'
                b2Meter = 'aaa55d88-f45f-41e8-9949-38f93f309f8c'; region = 'koreacentral' }
            imagesNetworkIdentityCertificatesPermissionsUnchanged = $true }
        $fingerprint = Fingerprint $plan
        Save-New "plan-$($fingerprint.Substring(7)).json" $plan
        @{ approvalFingerprint = $fingerprint; incrementalMonthlyUsd730Hours = 62.05 } | ConvertTo-Json -Compress
        return
    }
    if ($ApprovalFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'ExecutorCapacity:ExactApprovalRequired' }
    $plan = Get-Content (Join-Path $work "plan-$($ApprovalFingerprint.Substring(7)).json") -Raw |
        ConvertFrom-Json -AsHashtable -Depth 50 -DateKind String
    if ($ApprovalFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or (Fingerprint $plan) -cne $ApprovalFingerprint) { throw 'ExecutorCapacity:ExactApprovalRequired' }
    Equal (Source-Proof) $plan.sourceProof 'ReviewedSourceChanged'
    Equal $targetSku $plan.targetSku 'TargetChanged'
    if ($Mode -ceq 'Apply') {
        Equal $snapshot $plan.before 'PreDispatchDrift'
        Save-New 'dispatch-intent.json' @{ plan = $ApprovalFingerprint; resource = $planId; targetSku = $targetSku }
        $null = Run @('rest','--method','PATCH','--url',"https://management.azure.com${planId}?api-version=2024-04-01",
            '--headers','Content-Type=application/json','--body',(@{ sku = $targetSku } | ConvertTo-Json -Compress))
    }
    $intentPath = Join-Path $work 'dispatch-intent.json'
    if (-not (Test-Path $intentPath)) { throw 'ExecutorCapacity:UnownedTarget' }
    Equal (Get-Content $intentPath -Raw | ConvertFrom-Json -AsHashtable) @{
        plan = $ApprovalFingerprint; resource = $planId; targetSku = $targetSku } 'IntentChanged'
    $after = Read-Snapshot
    Equal $after.sku $targetSku 'TargetNotYetVerified'
    Equal $after.plan $plan.before.plan 'PlanBoundaryChanged'
    Equal $after.site $plan.before.site 'SiteBoundaryChanged'
    if ((Hash-File $statePath) -cne $stateHash) { throw 'ExecutorCapacity:AcceptedStateChanged' }
    $receipt = @{ status = 'ExactB2CapacityVerified'; plan = $ApprovalFingerprint; targetResource = $planId
        sku = $targetSku; otherProjectedConfigurationPreserved = $true; existingInstanceCount = 1
        imagesNetworkIdentityCertificatesPermissionsUnchanged = $true; acceptedStateHash = $stateHash }
    $old = Join-Path $work 'verified.json'
    if (Test-Path $old) { Equal (Get-Content $old -Raw | ConvertFrom-Json -AsHashtable) $receipt 'ReceiptChanged' }
    else { Save-New 'verified.json' $receipt }
    $receipt | ConvertTo-Json -Compress
}
finally { $lock.Dispose() }
