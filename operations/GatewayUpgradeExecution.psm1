#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeJson.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradePackaging.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeOperator.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeSqlAdmission.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeCutover.psm1')

function Initialize-GatewayUpgradeExecutionHelpers {
    foreach ($name in @('Common', 'Experience', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Database',
            'Purview', 'PurviewRecovery', 'Verification', 'PublisherRecovery', 'PurviewPackage', 'PurviewExecutor')) {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) "bootstrap\modules\$name.psm1") -Force -Global -DisableNameChecking
    }
}

function Write-GatewayUpgradeExecutionRecord {
    param($Context, [string]$Action, [ValidateSet('intent', 'result')][string]$Kind, $Value)
    if ($Action -cnotmatch '^[a-z][a-z0-9-]{1,79}$') { throw 'UpgradeExecution: invalid action name.' }
    $directory = Join-Path $Context.directory "actions\$Action"
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $body = @{
        schemaVersion = 1; planFingerprint = $Context.planFingerprint; originalStateSha256 = $Context.plan.original.stateSha256
        action = $Action; kind = $Kind; value = $Value
    }
    $record = @{ fingerprint = Get-GatewayUpgradeFingerprint $body; record = $body }
    $path = Join-Path $directory "$Kind.json"
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $record -Depth 100))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    return $record
}

function Read-GatewayUpgradeExecutionRecord {
    param($Context, [string]$Action, [string]$Kind)
    if ($Action -cnotmatch '^[a-z][a-z0-9-]{1,79}$' -or $Kind -cnotin @('intent', 'result')) {
        throw 'UpgradeExecution: invalid action record selector.'
    }
    $path = Join-Path $Context.directory "actions\$Action\$Kind.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $value = Read-GatewayUpgradeJson $path
    if ($value.Keys.Count -ne 2 -or $value.record.Keys.Count -ne 6 -or
        $value.record.schemaVersion -ne 1 -or $value.record.planFingerprint -cne $Context.planFingerprint -or
        $value.record.originalStateSha256 -cne $Context.plan.original.stateSha256 -or
        $value.record.action -cne $Action -or $value.record.kind -cne $Kind -or
        (Get-GatewayUpgradeFingerprint $value.record) -cne $value.fingerprint) {
        throw 'UpgradeExecution: action evidence integrity or provenance failed.'
    }
    return $value
}

function Assert-GatewayUpgradeExecutionAuthority {
    param($Context, [string]$Action, [switch]$ReadOnly, [switch]$Compensation)
    if (-not $ReadOnly -and $Context.Contains('directory') -and $Context.Contains('planFingerprint')) {
        Assert-GatewayUpgradeNoAbortMarker (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Context.directory))) $Context.planFingerprint
    }
    if ($Context.plan.request.schemaVersion -eq 2 -and
        $Action -cmatch '^(?:content-safety|protection-queue|purview-|executor-(?:identity|host|enable))') {
        throw 'UpgradeSourceOnly: capability installation, identity/grant creation and host replacement are forbidden in this mode.'
    }
    if ($Compensation -and $Action -cne 'sql-admin-restore') {
        throw 'UpgradeExecution: only exact SQL administrator restoration may use compensation authority.'
    }
    if ($Context.expectedPlanFingerprint -cne $Context.planFingerprint -or
        (Get-GatewayUpgradeFingerprint $Context.plan) -cne $Context.planFingerprint) {
        throw 'UpgradeAuthorizationRequired: exact approved Plan or preserved original inputs do not match.'
    }
    $artifactAction = $Action -cin @('coordination-container', 'executor-package', 'image-api', 'image-worker', 'image-adminui', 'image-databasemigrator', 'image-publisher')
    $buildAllowed = $Context.plan.Contains('buildSupported') -and $Context.plan.buildSupported -eq $true -and $artifactAction
    if (-not $ReadOnly -and -not $buildAllowed -and ($Context.plan.executionSupported -isnot [bool] -or $Context.plan.executionSupported -ne $true)) {
        throw 'UpgradeIntegrationNotReady: this Plan is review-only and cannot authorize mutation.'
    }
    if (-not $ReadOnly) { $null = Assert-GatewayUpgradeCurrentOperator $Context.plan }
    if ($Context.Contains('actor') -and $Context.actor.userObjectId -cne $Context.plan.authorizedOperator.objectId) {
        throw 'UpgradeAuthorizationRequired: execution actor differs from the approved operator.'
    }
    if ($Compensation) { return }
    if ((Get-GatewayUpgradeFileHash $Context.statePath) -cne $Context.plan.original.stateSha256 -or
        (Get-GatewayUpgradeFileHash $Context.configPath) -cne $Context.plan.original.configSha256 -or
        (Get-GatewayUpgradeFingerprint $Context.state) -cne (Get-GatewayUpgradeFingerprint (Read-GatewayUpgradeJson $Context.statePath)) -or
        (Get-GatewayUpgradeFingerprint $Context.config) -cne (Get-GatewayUpgradeFingerprint (Read-GatewayUpgradeJson $Context.configPath)) -or
        (Get-GatewayUpgradeFingerprint $Context.runtime) -cne (Get-GatewayUpgradeFingerprint $Context.state.steps['Gateway runtime deployment'].evidence) -or
        (Get-GatewayUpgradeFingerprint $Context.foundation) -cne (Get-GatewayUpgradeFingerprint $Context.state.steps['Azure foundation'].evidence) -or
        (Get-GatewayUpgradeFingerprint $Context.database) -cne (Get-GatewayUpgradeFingerprint $Context.state.steps['Gateway database'].evidence)) {
        throw 'UpgradeExecution: execution context differs from the preserved original inputs.'
    }
    $source = Test-GatewayUpgradeCandidate $Context.candidateReceiptPath $Context.candidateFingerprint
    if (-not $artifactAction) {
        Assert-GatewayUpgradeSqlAdmission -SourceRoot $source -Database $Context.plan.request.database -Mode $(if ($Context.plan.request.schemaVersion -eq 2) { 'SourceOnlyFull' } else { 'CoreToFull' })
    }
    if ([IO.Path]::GetFullPath($source) -cne [IO.Path]::GetFullPath($Context.sourceRoot)) {
        throw 'UpgradeExecution: the source snapshot differs from its exact approved packaging receipt.'
    }
    foreach ($entry in $Context.plan.content.verifierManifest) {
        if ((Get-GatewayUpgradeFileHash (Join-Path (Split-Path -Parent $PSScriptRoot) $entry.path)) -cne $entry.sha256) {
            throw 'UpgradeExecution: executing maintenance/helper source changed after approval.'
        }
    }
    if (-not $ReadOnly -and $Action -cne 'coordination-container' -and -not $Context.Contains('leaseId')) {
        throw 'UpgradeExecution: a distributed lease is required before external mutation.'
    }
}

function Invoke-GatewayUpgradeOnce {
    param($Context, [string]$Action, $InputBinding, [scriptblock]$Discover, [scriptblock]$Mutate,
        [switch]$ReadOnly, [switch]$AllowExisting, [scriptblock]$Preflight,
        [ValidateRange(1, 360)][int]$MaximumReadAttempts = 120, [switch]$Compensation)
    Assert-GatewayUpgradeExecutionAuthority $Context $Action -ReadOnly:$ReadOnly -Compensation:$Compensation
    $inputHash = Get-GatewayUpgradeFingerprint $InputBinding
    $intent = Read-GatewayUpgradeExecutionRecord $Context $Action 'intent'
    $result = Read-GatewayUpgradeExecutionRecord $Context $Action 'result'
    if ($null -ne $result -and $null -eq $intent) { throw 'UpgradeExecution: result has no original intent.' }
    if ($null -ne $intent -and $intent.record.value.inputFingerprint -cne $inputHash) {
        throw 'UpgradeExecution: action inputs differ from the approved prior intent.'
    }
    $observed = & $Discover
    if ($null -ne $intent) {
        if ($null -eq $observed -and $Compensation -and -not $ReadOnly) {
            Assert-GatewayUpgradeExecutionAuthority $Context $Action -Compensation
            $null = Save-GatewayUpgradeNamedEvidence $Context "sql-admin-restore-attempt-$([guid]::NewGuid().ToString('N')).json" @{
                planFingerprint = $Context.planFingerprint; inputFingerprint = $inputHash
                disposition = 'ExactCurrentDelegatedAdministratorObserved;RestoreOriginalOnly'
            }
            & $Mutate | Out-Null
            $observed = & $Discover
        }
        if ($null -eq $observed) {
            throw 'UpgradeOutcomeUnknown: prior intent has no exact completed readback; automatic replay is forbidden.'
        }
        if ($null -ne $result -and
            (Get-GatewayUpgradeFingerprint $observed) -cne (Get-GatewayUpgradeFingerprint $result.record.value)) {
            throw 'UpgradeExecution: completed provider evidence drifted.'
        }
        if ($null -eq $result -and -not $ReadOnly) {
            $null = Write-GatewayUpgradeExecutionRecord $Context $Action 'result' $observed
        }
        return $observed
    }
    if ($ReadOnly) { throw 'UpgradeExecution: read-only verification cannot manufacture missing action evidence.' }
    if ($null -ne $observed -and -not $AllowExisting) {
        throw 'UpgradeExecution: an unowned pre-existing action target cannot be adopted.'
    }
    if ($null -ne $Preflight) { & $Preflight | Out-Null }
    Assert-GatewayUpgradeExecutionAuthority $Context $Action -Compensation:$Compensation
    $null = Write-GatewayUpgradeExecutionRecord $Context $Action 'intent' @{
        inputFingerprint = $inputHash; input = $InputBinding; acceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
    if ($null -eq $observed) {
        & $Mutate | Out-Null
        for ($attempt = 1; $attempt -le $MaximumReadAttempts; $attempt++) {
            $observed = & $Discover
            if ($null -ne $observed) { break }
            if ($attempt -lt $MaximumReadAttempts) { Start-Sleep -Seconds 5 }
        }
    }
    if ($null -eq $observed) { throw 'UpgradeOutcomeUnknown: dispatched mutation lacks exact readback; no second dispatch is permitted.' }
    $null = Write-GatewayUpgradeExecutionRecord $Context $Action 'result' $observed
    return $observed
}

function Invoke-GatewayUpgradeArm {
    param($Context, [ValidateSet('GET', 'PUT', 'POST', 'PATCH')][string]$Method, [string]$ResourceId,
        [string]$ApiVersion, $Body, [switch]$AllowNotFound, [string]$PollUrl)
    $prefix = "$($Context.plan.scope.resourceGroupId)/providers/"
    if (-not $Context.Contains('allowedPollUrls')) { $Context.allowedPollUrls = @{} }
    if ($PollUrl) {
        if ($Method -cne 'GET' -or -not $Context.allowedPollUrls.ContainsKey($PollUrl)) {
            throw 'UpgradeExecution: an asynchronous ARM result URL has no exact issuing request.'
        }
        $url = $PollUrl
    }
    elseif (-not $ResourceId.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $ResourceId.Contains('?') -or $ResourceId.Contains('#') -or $ResourceId.Contains('..') -or
        $ApiVersion -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') {
        throw 'UpgradeExecution: ARM request escaped the exact approved resource-group scope.'
    }
    else { $url = "https://management.azure.com$ResourceId`?api-version=$ApiVersion" }
    $credential = Invoke-AzJson -Arguments @('account', 'get-access-token', '--subscription', $Context.config.subscriptionId,
        '--resource', 'https://management.azure.com/', '--query', '{accessToken:accessToken,tenant:tenant}')
    if ($credential -isnot [pscustomobject] -or @($credential.PSObject.Properties).Count -ne 2 -or
        $null -eq $credential.PSObject.Properties['tenant'] -or
        $credential.PSObject.Properties['tenant'].Name -cne 'tenant' -or $credential.tenant -isnot [string] -or
        $credential.tenant -cne $Context.config.tenantId -or $null -eq $credential.PSObject.Properties['accessToken'] -or
        $credential.PSObject.Properties['accessToken'].Name -cne 'accessToken' -or
        $credential.accessToken -isnot [string] -or [string]::IsNullOrWhiteSpace($credential.accessToken)) {
        throw 'UpgradeAuthenticationRequired: ARM credential does not match the exact subscription tenant.'
    }
    return Invoke-GatewayUpgradeArmHttp $Context $Method $ResourceId $url $credential.accessToken $Body -AllowNotFound:$AllowNotFound
}

function Invoke-GatewayUpgradeArmHttp {
    param($Context, [string]$Method, [string]$ResourceId, [string]$Url, [string]$Token, $Body, [switch]$AllowNotFound)
    $client = [Net.Http.HttpClient]::new()
    $seconds = 120.0
    if ($Context.Contains('cutoverDeadline')) {
        $seconds = [Math]::Min($seconds, ($Context.cutoverDeadline - [DateTimeOffset]::UtcNow).TotalSeconds)
        if ($seconds -le 0) {
            $client.Dispose()
            throw 'UpgradeCutoverUnknown: the approved boundary timeout expired; physical closure is not proven.'
        }
    }
    $client.Timeout = [TimeSpan]::FromSeconds($seconds)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $url)
    try {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        if ($null -ne $Body) {
            $request.Content = [Net.Http.StringContent]::new((ConvertTo-Json -InputObject $Body -Depth 100 -Compress),
                [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            if ($AllowNotFound -and [int]$response.StatusCode -eq 404) { return $null }
            if (-not $response.IsSuccessStatusCode) {
                throw "UpgradeAzureOperationFailed: HTTP $([int]$response.StatusCode); provider body suppressed."
            }
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $value = ConvertFrom-GatewayUpgradeArmJson -Json $text
            if ([int]$response.StatusCode -eq 202 -and $response.Headers.Location) {
                $location = [uri]::new([uri]'https://management.azure.com/', $response.Headers.Location.ToString())
                if ($location.Scheme -cne 'https' -or $location.Host -cne 'management.azure.com' -or
                    $location.UserInfo -or $location.Fragment -or
                    -not $location.AbsolutePath.StartsWith("/subscriptions/$($Context.config.subscriptionId)/", [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'UpgradeExecution: ARM asynchronous location escaped its subscription.'
                }
                $Context.allowedPollUrls[$location.AbsoluteUri] = $ResourceId
                $value['_maintenancePollUrl'] = $location.AbsoluteUri
            }
            return $value
        }
        finally { $response.Dispose() }
    }
    finally { $request.Dispose(); $client.Dispose(); $token = $null }
}

function Get-GatewayUpgradeLeaseContainerId {
    param($Context)
    return "$($Context.runtime.storageAccountId)/blobServices/default/containers/gateway-upgrade-lock"
}

function Assert-GatewayUpgradeNoAbortMarker {
    param([string]$WorkspaceRoot, [string]$PlanFingerprint)
    if ($PlanFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'UpgradeAuthorizationRequired: exact Plan fingerprint required.' }
    $root = Join-Path ([IO.Path]::GetFullPath($WorkspaceRoot)) '.maintenance\abort-state'
    $path = Join-Path $root $PlanFingerprint.Substring(7)
    if (Test-Path -LiteralPath $path) {
        throw 'UpgradeAbortTerminal: this Plan has an admitted, interrupted or verified abort and cannot mutate or reacquire its lease.'
    }
    if ((Test-Path -LiteralPath $root) -and ((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'UpgradeAbortTerminal: lifecycle marker path is linked; mutation is forbidden.'
    }
}

function Enter-GatewayUpgradeCloudLease {
    param($Context)
    Assert-GatewayUpgradeNoAbortMarker (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Context.directory))) $Context.planFingerprint
    $containerId = Get-GatewayUpgradeLeaseContainerId $Context
    $metadata = @{ gatewayowner = $Context.state.deploymentOwnershipId; gatewaybootstrap = $Context.state.acceptedPlan.sourceFingerprint }
    $null = Invoke-GatewayUpgradeOnce $Context 'coordination-container' @{ id = $containerId; metadata = $metadata } -AllowExisting -Discover {
        $container = Invoke-GatewayUpgradeArm $Context GET $containerId '2023-05-01' -AllowNotFound
        if ($null -eq $container) { return $null }
        if ($container.properties.publicAccess -cne 'None' -or
            (Get-GatewayUpgradeFingerprint $container.properties.metadata) -cne (Get-GatewayUpgradeFingerprint $metadata)) {
            throw 'UpgradeExecution: coordination container ownership or privacy differs.'
        }
        return @{ id = $containerId; metadata = $metadata; publicAccess = 'None' }
    } -Mutate {
        Invoke-GatewayUpgradeArm $Context PUT $containerId '2023-05-01' @{ properties = @{ publicAccess = 'None'; metadata = $metadata } } | Out-Null
    }
    $leaseFile = Join-Path $Context.directory 'lease.json'
    $owner = Get-GatewayUpgradeFingerprint @{
        machine = [Environment]::MachineName
        user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    $newLease = -not (Test-Path -LiteralPath $leaseFile)
    if ($newLease) {
        $leaseId = [guid]::NewGuid().ToString('D')
        $lease = @{ schemaVersion = 1; planFingerprint = $Context.planFingerprint; leaseId = $leaseId; containerId = $containerId; ownerFingerprint = $owner }
        $stream = [IO.File]::Open($leaseFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $lease -Compress))
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
        }
        finally { $stream.Dispose() }
    }
    else {
        $lease = Read-GatewayUpgradeJson $leaseFile
        $leaseId = [string]$lease.leaseId
        if ($lease.Keys.Count -ne 5 -or $lease.schemaVersion -ne 1 -or $lease.planFingerprint -cne $Context.planFingerprint -or
            $lease.ownerFingerprint -cne $owner -or
            $lease.containerId -cne $containerId -or $leaseId -cne ([guid]$leaseId).ToString('D')) {
            throw 'UpgradeExecution: retained lease evidence is malformed or belongs to another Plan.'
        }
    }
    $acquire = $newLease
    if (-not $newLease) {
        $container = Invoke-GatewayUpgradeArm $Context GET $containerId '2023-05-01'
        $state = [string]$container.properties.leaseState
        if ($state -iin @('Available', 'Expired', 'Broken')) { $acquire = $true }
        elseif ($state -ine 'Leased') { throw 'UpgradeExecution: distributed lease is pending or unclassified; it is not broken automatically.' }
    }
    $body = if ($acquire) { @{ action = 'Acquire'; leaseDuration = -1; proposedLeaseId = $leaseId } }
        else { @{ action = 'Renew'; leaseId = $leaseId } }
    $response = Invoke-GatewayUpgradeArm $Context POST "$containerId/lease" '2023-05-01' $body
    if (($acquire -or $response.Contains('leaseId')) -and [string]$response.leaseId -cne $leaseId) {
        throw 'UpgradeExecution: exact distributed lease was not independently returned.'
    }
    $Context.leaseId = $leaseId
    $Context.leaseContainerId = $containerId
}

function Exit-GatewayUpgradeCloudLease {
    param($Context)
    if (-not $Context.Contains('leaseId')) { return }
    $null = Invoke-GatewayUpgradeArm $Context POST "$($Context.leaseContainerId)/lease" '2023-05-01' @{
        action = 'Release'; leaseId = $Context.leaseId
    }
    $null = Save-GatewayUpgradeNamedEvidence $Context "lease-release-$([guid]::NewGuid().ToString('N')).json" @{
        planFingerprint = $Context.planFingerprint; containerId = $Context.leaseContainerId
        leaseId = $Context.leaseId; releasedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
}

function Invoke-GatewayUpgradeArmDeployment {
    param($Context, [string]$Action, [string]$RelativeTemplate, $Parameters, [string[]]$AllowedResourceIds,
        [scriptblock]$Readback, [switch]$ReadOnly, [string[]]$AllowedModifyResourceIds = @())
    if ($RelativeTemplate -cnotin @(
            'infrastructure\bicep\maintenance-content-safety.bicep', 'infrastructure\bicep\maintenance-database-job.bicep',
            'infrastructure\bicep\maintenance-purview-executor.bicep', 'infrastructure\bicep\maintenance-purview-publisher.bicep',
            'infrastructure\bicep\maintenance-protection-queue.bicep',
            'infrastructure\bicep\maintenance-source-only-executor.bicep',
            'bootstrap\infra\purview-windows-executor.bicep', 'bootstrap\infra\purview-package-publisher-job.bicep',
            'bootstrap\infra\purview-automation-certificate.bicep')) {
        throw 'UpgradeExecution: unsupported fixed deployment template.'
    }
    $templatePath = Join-Path $Context.sourceRoot $RelativeTemplate
    $templateSha = Get-GatewayUpgradeFileHash $templatePath
    $deploymentName = "maintenance-$Action-$($Context.planFingerprint.Substring(7, 10))"
    $deploymentId = "$($Context.plan.scope.resourceGroupId)/providers/Microsoft.Resources/deployments/$deploymentName"
    $parameterBinding = Get-GatewayUpgradeFingerprint $Parameters
    $prepared = @{}
    return Invoke-GatewayUpgradeOnce $Context $Action @{
        template = $RelativeTemplate; templateSha256 = $templateSha; parameterFingerprint = $parameterBinding; deploymentId = $deploymentId
    } -ReadOnly:$ReadOnly -Discover {
        $deployment = Invoke-GatewayUpgradeArm $Context GET $deploymentId '2025-04-01' -AllowNotFound
        if ($null -eq $deployment) { return $null }
        if ($deployment.properties.provisioningState -in @('Accepted', 'Running')) { return $null }
        if ($deployment.properties.provisioningState -cne 'Succeeded') { throw 'UpgradeExecution: the exact deployment is terminal without success.' }
        return & $Readback $deployment.properties.outputs
    } -Preflight {
        $compiledText = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('bicep', 'build', '--file', $templatePath, '--stdout')
        $compiled = ConvertFrom-Json $compiledText -AsHashtable -Depth 100
        if ((Get-GatewayUpgradeFileHash $templatePath) -cne $templateSha) { throw 'UpgradeExecution: reviewed template bytes changed.' }
        $armParameters = [ordered]@{}
        foreach ($key in $Parameters.Keys) { $armParameters[$key] = @{ value = $Parameters[$key] } }
        $body = @{ properties = @{ mode = 'Incremental'; template = $compiled; parameters = $armParameters } }
        $whatIf = Invoke-GatewayUpgradeArm $Context POST "$deploymentId/whatIf" '2025-04-01' $body
        for ($attempt = 1; $whatIf.Contains('_maintenancePollUrl') -and $attempt -le 60; $attempt++) {
            $pollUrl = [string]$whatIf['_maintenancePollUrl']
            Start-Sleep -Seconds 5
            $whatIf = Invoke-GatewayUpgradeArm $Context GET -PollUrl $pollUrl
            if ($whatIf.Contains('status') -and $whatIf.status -in @('Running', 'Accepted', 'InProgress', 'Queued')) {
                $whatIf['_maintenancePollUrl'] = $pollUrl
            }
        }
        if (-not $whatIf.Contains('status') -or $whatIf.status -cne 'Succeeded') { throw 'UpgradeExecution: complete successful What-If was not observed.' }
        $changes = if ($whatIf.Contains('properties') -and $whatIf.properties.Contains('changes')) { @($whatIf.properties.changes) }
            elseif ($whatIf.Contains('changes')) { @($whatIf.changes) }
            else { throw 'UpgradeExecution: What-If omitted its complete change set.' }
        foreach ($change in $changes) {
            if ($change.changeType -cnotin @('Create', 'Modify', 'NoChange', 'Ignore') -or
                $change.resourceId.ToLowerInvariant() -cnotin @($AllowedResourceIds | ForEach-Object { $_.ToLowerInvariant() }) -or
                ($change.changeType -ceq 'Modify' -and $change.resourceId.ToLowerInvariant() -cnotin @($AllowedModifyResourceIds | ForEach-Object { $_.ToLowerInvariant() }))) {
                throw 'UpgradeExecution: What-If escaped the exact resource allowlist or requested deletion.'
            }
            if ($RelativeTemplate -ceq 'infrastructure\bicep\maintenance-source-only-executor.bicep' -and
                $change.changeType -ceq 'Create') {
                throw 'UpgradeExecution: source-only cutover cannot recreate the installed executor settings.'
            }
        }
        $prepared.body = $body
    } -Mutate {
        Invoke-GatewayUpgradeArm $Context PUT $deploymentId '2025-04-01' $prepared.body | Out-Null
    }
}

function Get-GatewayUpgradeRoleContract {
    param($Context, [string]$Key)
    $roles = @($Context.plan.scope.purview.roles | Where-Object key -CEQ $Key)
    if ($roles.Count -ne 1) { throw 'UpgradeExecution: role key is not uniquely declared in the approved scope.' }
    return $roles[0]
}

function Test-GatewayUpgradeRoleReadback {
    param($Context, $Role, [string]$PrincipalId)
    $live = Invoke-GatewayUpgradeArm $Context GET $Role.assignmentResourceId '2022-04-01'
    if ($live.properties.principalId -cne $PrincipalId -or $live.properties.roleDefinitionId -cne $Role.roleDefinitionId -or
        ($live.properties.Contains('condition') -and $live.properties.condition)) {
        throw 'UpgradeExecution: role principal, permission or condition differs from its exact declaration.'
    }
    return @{ scope = $Role.scope; principalId = $PrincipalId; roleId = $Role.role; assignmentId = $Role.assignmentName }
}

function Invoke-GatewayUpgradeProtectionQueue {
    param($Context, [switch]$ReadOnly)
    $scope = $Context.plan.scope.purview
    $sender = Get-GatewayUpgradeRoleContract $Context 'apiQueueSender'
    $receiver = Get-GatewayUpgradeRoleContract $Context 'workerQueueReceiver'
    $certificate = Get-GatewayUpgradeRoleContract $Context 'workerCertificateReader'
    $parameters = @{
        namespaceName = "sb-$($Context.config.projectName)-$($Context.config.environment)"
        keyVaultName = $Context.runtime.sharedKeyVaultId.Split('/')[-1]
        apiPrincipalId = $Context.runtime.apiPrincipalId; workerPrincipalId = $Context.runtime.workerPrincipalId
        apiSenderRoleName = $sender.assignmentName; workerReceiverRoleName = $receiver.assignmentName
        workerCertificateRoleName = $certificate.assignmentName
    }
    $ids = @($Context.plan.scope.resources | Where-Object stage -CEQ 'PurviewQueue' | ForEach-Object resourceId)
    return Invoke-GatewayUpgradeArmDeployment $Context 'protection-queue' 'infrastructure\bicep\maintenance-protection-queue.bicep' `
        $parameters $ids -ReadOnly:$ReadOnly -Readback {
            param($outputs)
            $queue = Invoke-GatewayUpgradeArm $Context GET $scope.queueId '2024-01-01'
            if ($queue.properties.requiresSession -ne $false -or $queue.properties.requiresDuplicateDetection -ne $false -or
                $queue.properties.lockDuration -cne 'PT5M' -or $queue.properties.defaultMessageTimeToLive -cne 'P7D' -or
                [int]$queue.properties.maxDeliveryCount -ne 10 -or $queue.properties.deadLetteringOnMessageExpiration -ne $true) {
                throw 'UpgradeExecution: dedicated protection queue configuration differs.'
            }
            $send = Test-GatewayUpgradeRoleReadback $Context $sender $Context.runtime.apiPrincipalId
            $receive = Test-GatewayUpgradeRoleReadback $Context $receiver $Context.runtime.workerPrincipalId
            $readCertificate = Test-GatewayUpgradeRoleReadback $Context $certificate $Context.runtime.workerPrincipalId
            return @{ queueId = $scope.queueId; sender = $send; receiver = $receive; certificateReader = $readCertificate }
        }
}

function New-GatewayUpgradeExecutorPackage {
    param($Context)
    Assert-GatewayUpgradeExecutionAuthority $Context 'executor-package'
    $recordPath = Join-Path $Context.directory 'executor-package.json'
    if (Test-Path -LiteralPath $recordPath) {
        $record = Read-GatewayUpgradeJson $recordPath
        if ($record.planFingerprint -cne $Context.planFingerprint -or $record.sourceFingerprint -cne $Context.artifactSourceFingerprint) {
            throw 'UpgradeExecution: retained local executor package has another source/Plan binding.'
        }
        $package = Read-PurviewExecutorPackage -PackageDirectory $record.directory -ExpectedSourceFingerprint $Context.artifactSourceFingerprint
        if ($package.receiptFingerprint -cne $record.receiptFingerprint) { throw 'UpgradeExecution: retained executor package changed.' }
        return @{ directory = $record.directory; package = $package }
    }
    $clone = Join-Path $Context.directory "local-builds\$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($clone) | Out-Null
    $candidate = Read-GatewayUpgradeJson $Context.candidateReceiptPath
    foreach ($relative in @($candidate.provenance.entries.path) + @('.dockerignore')) {
        $destination = Join-Path $clone $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [IO.File]::Copy((Join-Path $Context.sourceRoot $relative), $destination, $false)
    }
    if ((Get-BootstrapSourceFingerprint -Root $clone) -cne $Context.artifactSourceFingerprint) {
        throw 'UpgradeExecution: isolated local build copy differs from the immutable candidate.'
    }
    $directory = Join-Path $clone '.agent-runtime\purview-package'
    Invoke-BootstrapCommand -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $clone 'operations\build-purview-executor-package.ps1'),
        '-OutputDirectory', $directory, '-ExpectedSourceFingerprint', $Context.artifactSourceFingerprint) | Out-Null
    $package = Read-PurviewExecutorPackage -PackageDirectory $directory -ExpectedSourceFingerprint $Context.artifactSourceFingerprint
    $record = @{ planFingerprint = $Context.planFingerprint; sourceFingerprint = $Context.artifactSourceFingerprint
        directory = $directory; receiptFingerprint = $package.receiptFingerprint }
    $stream = [IO.File]::Open($recordPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $record -Compress))
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    return @{ directory = $directory; package = $package }
}

function Save-GatewayUpgradeExecutorIdentityState {
    param($Context, $Operations)
    $directory = Join-Path $Context.directory 'executor-identity'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File)
    $index = $files.Count + 1
    if ($index -gt 64) { throw 'UpgradeExecution: executor identity checkpoint bound exceeded.' }
    $body = @{ planFingerprint = $Context.planFingerprint; sourceFingerprint = $Context.artifactSourceFingerprint
        index = $index; operations = $Operations }
    $record = @{ fingerprint = Get-GatewayUpgradeFingerprint $body; record = $body }
    $path = Join-Path $directory "$($index.ToString('D3')).json"
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $record -Depth 100))
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Invoke-GatewayUpgradeExecutorIdentity {
    param($Context, [switch]$ReadOnly)
    $directory = Join-Path $Context.directory 'executor-identity'
    $operations = [ordered]@{}
    if (Test-Path -LiteralPath $directory) {
        $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File | Sort-Object Name)
        if ($files.Count -gt 64) { throw 'UpgradeExecution: executor identity history is oversized.' }
        for ($index = 0; $index -lt $files.Count; $index++) {
            $record = Read-GatewayUpgradeJson $files[$index].FullName
            if ($files[$index].Name -cne "$(($index + 1).ToString('D3')).json" -or
                $record.record.index -ne ($index + 1) -or $record.record.planFingerprint -cne $Context.planFingerprint -or
                $record.record.sourceFingerprint -cne $Context.artifactSourceFingerprint -or
                (Get-GatewayUpgradeFingerprint $record.record) -cne $record.fingerprint) {
                throw 'UpgradeExecution: executor identity evidence is not exact and contiguous.'
            }
            $operations = $record.record.operations
        }
    }
    $identityContext = @{
        deploymentOwnershipId = $Context.state.deploymentOwnershipId; sourceFingerprint = $Context.artifactSourceFingerprint
        tenantId = $Context.config.tenantId; workerPrincipalId = $Context.runtime.workerPrincipalId
        workerApplicationId = $Context.database.workerPrincipalClientId
    }
    return Invoke-GatewayUpgradeOnce $Context 'executor-identity' $identityContext -ReadOnly:$ReadOnly -Discover {
        if ($operations.Count -eq 0) {
            $existing = Get-ExactApplicationByDisplayName -DisplayName "A365 Gateway Purview Executor - $($Context.state.deploymentOwnershipId)"
            if ($null -ne $existing) { throw 'UpgradeExecution: unowned executor application cannot be adopted.' }
            return $null
        }
        return Ensure-PurviewExecutorIdentity -Context $identityContext -Operations $operations -ReadOnly -Checkpoint { throw 'Read-only identity verification attempted a write.' }
    } -Mutate {
        Ensure-PurviewExecutorIdentity -Context $identityContext -Operations $operations -Checkpoint {
            Save-GatewayUpgradeExecutorIdentityState $Context $operations
        } | Out-Null
    }
}

function Get-GatewayUpgradeExecutorBinding {
    param($Context, $Automation, $ExecutorIdentity, $Package, [string]$ExecutorPrincipalId)
    return @{
        DeploymentOwnershipId = $Context.state.deploymentOwnershipId; TenantId = $Context.config.tenantId
        BootstrapSourceFingerprint = $Context.state.acceptedPlan.sourceFingerprint
        ExecutionSourceFingerprint = $Context.artifactSourceFingerprint; PackageDigest = $Package.receipt.packageDigest
        ExecutorApplicationId = $ExecutorIdentity.applicationId; ExecutorPrincipalId = $ExecutorPrincipalId
        GatewayWorkerPrincipalId = $Context.runtime.workerPrincipalId; CallerApplicationId = $Context.database.workerPrincipalClientId
        KeyVaultResourceId = $Context.runtime.sharedKeyVaultId; CertificateName = 'purview-automation-certificate'
        CertificateSecretUri = "$($Context.runtime.keyVaultUri.TrimEnd('/'))/secrets/purview-automation-certificate"
        AutomationApplicationId = $Automation.applicationId; AutomationServicePrincipalObjectId = $Automation.principalId
        GatewayApiPrincipalId = $Context.runtime.apiPrincipalId
        RuntimeClientId = $Context.purviewRuntime.clientId; RuntimePrincipalId = $Context.purviewRuntime.principalId
    }
}

function Invoke-GatewayUpgradeExecutorHost {
    param($Context, $Automation, $Certificate, $ExecutorIdentity, $Package,
        [switch]$Enable, [switch]$ReadOnly)
    if ($Context.plan.request.schemaVersion -eq 2) {
        return Invoke-GatewayUpgradeSourceOnlyExecutor $Context $Automation $ExecutorIdentity $Package -Enable:$Enable -ReadOnly:$ReadOnly
    }
    $scope = $Context.plan.scope.purview
    $selectedSku = [string]$Context.plan.request.capabilities.purview.executorSku
    if ($selectedSku -cnotin @('B1','B2')) { throw 'UpgradeExecution: the reviewed executor SKU is invalid.' }
    $reader = Get-GatewayUpgradeRoleContract $Context 'packageReader'
    $writer = Get-GatewayUpgradeRoleContract $Context 'claimWriter'
    $certificateReader = Get-GatewayUpgradeRoleContract $Context 'certificateReader'
    $parameters = @{
        executorName = $scope.siteName; planName = $scope.planName; location = $Context.config.location; executorSku = $selectedSku
        deploymentOwnershipId = $Context.state.deploymentOwnershipId; bootstrapSourceFingerprint = $Context.state.acceptedPlan.sourceFingerprint
        executionSourceFingerprint = $Context.artifactSourceFingerprint; upgradePlanFingerprint = $Context.planFingerprint
        virtualNetworkName = $Context.foundation.virtualNetworkName; privateEndpointSubnetId = $Context.foundation.privateEndpointSubnetId
        storageAccountName = $Context.runtime.storageAccountId.Split('/')[-1]; keyVaultName = $Context.runtime.sharedKeyVaultId.Split('/')[-1]
        certificateName = 'purview-automation-certificate'; executorApplicationId = $ExecutorIdentity.applicationId
        workerApplicationId = $Context.database.workerPrincipalClientId; workerPrincipalId = $Context.runtime.workerPrincipalId
        packageSha256 = $Package.receipt.packageDigest.Substring(7); runtimeManifestDigest = $Package.receipt.runtimeManifestDigest
        executionBinding = @{
            AutomationApplicationId = $Automation.applicationId; AutomationServicePrincipalObjectId = $Automation.principalId
            GatewayApiPrincipalId = $Context.runtime.apiPrincipalId; RuntimeClientId = $Context.purviewRuntime.clientId
            RuntimePrincipalId = $Context.purviewRuntime.principalId
        }
        organization = $Certificate.organization; packageReaderRoleName = $reader.assignmentName
        claimWriterRoleName = $writer.assignmentName; certificateReaderRoleName = $certificateReader.assignmentName
        privateEndpointName = $scope.endpointName; dnsLinkName = $scope.dnsLinkName; enableRuntime = [bool]$Enable
    }
    $ids = @($scope.resources | Where-Object stage -CEQ 'PurviewExecutor' | ForEach-Object resourceId)
    $modify = if ($Enable) { @($scope.siteId, "$($scope.siteId)/config/appsettings") } else { @() }
    $action = if ($Enable) { 'executor-enable' } else { 'executor-host' }
    return Invoke-GatewayUpgradeArmDeployment $Context $action 'infrastructure\bicep\maintenance-purview-executor.bicep' `
        $parameters $ids -AllowedModifyResourceIds $modify -ReadOnly:$ReadOnly -Readback {
            param($outputs)
            $site = Invoke-GatewayUpgradeArm $Context GET $scope.siteId '2024-11-01'
            $planId = "$($Context.plan.scope.resourceGroupId)/providers/Microsoft.Web/serverfarms/$($scope.planName)"
            $plan = Invoke-GatewayUpgradeArm $Context GET $planId '2024-11-01'
            if ($site.identity.type -cne 'SystemAssigned' -or $site.properties.serverFarmId -cne $planId -or
                $site.tags.gatewayUpgradePlanFingerprint -cne $Context.planFingerprint -or
                $site.properties.publicNetworkAccess -cne 'Disabled' -or $site.properties.httpsOnly -ne $true -or
                $site.properties.virtualNetworkSubnetId -cne "$($scope.networkId)/subnets/snet-purview-executor" -or
                $site.properties.outboundVnetRouting.allTraffic -ne $true -or
                $plan.sku.name -cne $selectedSku -or $plan.sku.capacity -ne 1 -or $plan.properties.reserved -ne $false) {
                throw 'UpgradeExecution: reviewed Windows host SKU, identity or private-network boundary differs.'
            }
            if ($Enable -and $site.properties.enabled -ne $true) { return $null }
            $binding = Get-GatewayUpgradeExecutorBinding $Context $Automation $ExecutorIdentity $Package $site.identity.principalId
            $auth = Invoke-GatewayUpgradeArm $Context GET "$($scope.siteId)/config/authsettingsV2" '2024-11-01'
            $aad = $auth.properties.identityProviders.azureActiveDirectory
            if ($auth.properties.globalValidation.requireAuthentication -ne $true -or
                $auth.properties.globalValidation.unauthenticatedClientAction -cne 'Return401' -or
                $auth.properties.login.tokenStore.enabled -ne $false -or $aad.enabled -ne $true -or
                $aad.registration.clientId -cne $ExecutorIdentity.applicationId -or
                $aad.registration.openIdIssuer -cne "https://login.microsoftonline.com/$($Context.config.tenantId)/v2.0" -or
                (Get-GatewayUpgradeFingerprint @($aad.validation.allowedAudiences)) -cne (Get-GatewayUpgradeFingerprint @($ExecutorIdentity.applicationId)) -or
                (Get-GatewayUpgradeFingerprint @($aad.validation.defaultAuthorizationPolicy.allowedApplications)) -cne (Get-GatewayUpgradeFingerprint @($Context.database.workerPrincipalClientId)) -or
                (Get-GatewayUpgradeFingerprint @($aad.validation.defaultAuthorizationPolicy.allowedPrincipals.identities)) -cne (Get-GatewayUpgradeFingerprint @($Context.runtime.workerPrincipalId))) {
                throw 'UpgradeExecution: executor audience/caller authentication differs.'
            }
            foreach ($policy in @('ftp', 'scm')) {
                $publishing = Invoke-GatewayUpgradeArm $Context GET "$($scope.siteId)/basicPublishingCredentialsPolicies/$policy" '2024-11-01'
                if ($publishing.properties.allow -ne $false) { throw 'UpgradeExecution: basic publishing credentials were enabled.' }
            }
            $null = Test-GatewayUpgradeRoleReadback $Context $reader $site.identity.principalId
            $null = Test-GatewayUpgradeRoleReadback $Context $writer $site.identity.principalId
            $null = Test-GatewayUpgradeRoleReadback $Context $certificateReader $site.identity.principalId
            $endpointId = "$($Context.plan.scope.resourceGroupId)/providers/Microsoft.Network/privateEndpoints/$($scope.endpointName)"
            $endpoint = Invoke-GatewayUpgradeArm $Context GET $endpointId '2023-11-01'
            $connections = @($endpoint.properties.privateLinkServiceConnections)
            if ($endpoint.properties.subnet.id -cne $Context.foundation.privateEndpointSubnetId -or $connections.Count -ne 1 -or
                $connections[0].properties.privateLinkServiceId -cne $scope.siteId -or
                $connections[0].properties.privateLinkServiceConnectionState.status -cne 'Approved' -or
                (Get-GatewayUpgradeFingerprint @($connections[0].properties.groupIds)) -cne (Get-GatewayUpgradeFingerprint @('sites'))) {
                throw 'UpgradeExecution: executor private endpoint is not approved for the exact host/subnet.'
            }
            if ($Enable) {
                $settings = Invoke-GatewayUpgradeArm $Context POST "$($scope.siteId)/config/appsettings/list" '2024-11-01' @{}
                $expected = @{
                    WEBSITE_RUN_FROM_PACKAGE = "https://$($parameters.storageAccountName).blob.core.windows.net/purview-executor-packages/$($parameters.packageSha256).zip"
                    WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID = 'SystemAssigned'; SCM_DO_BUILD_DURING_DEPLOYMENT = 'false'
                    DOTNET_EnableDiagnostics = '0'; ASPNETCORE_ENVIRONMENT = 'Production'
                    Executor__ClaimsContainerUri = "https://$($parameters.storageAccountName).blob.core.windows.net/purview-executor-claims"
                    Executor__RuntimeManifestDigest = $Package.receipt.runtimeManifestDigest; Executor__OperationTimeoutSeconds = '195'
                    Purview__PolicyProvisioningEnabled = 'true'; Purview__PolicyProvisioningOrganization = $Certificate.organization
                    Purview__PolicyProvisioningApplicationId = $Automation.applicationId
                    Purview__PolicyProvisioningCertificateSecretUri = $binding.CertificateSecretUri
                    Purview__PolicyProvisioningTimeoutSeconds = '180'
                }
                foreach ($key in $binding.Keys) { $expected["Executor__Binding__$key"] = [string]$binding[$key] }
                if ((Get-GatewayUpgradeFingerprint $settings.properties) -cne (Get-GatewayUpgradeFingerprint $expected)) {
                    throw 'UpgradeExecution: executor runtime/package/certificate binding differs from the complete expected settings.'
                }
            }
            $hostName = [string]$site.properties.defaultHostName
            if ($hostName -cnotmatch '^[a-z0-9-]+(?:\.[a-z0-9-]+)?\.azurewebsites\.net$') { throw 'UpgradeExecution: executor hostname is not canonical.' }
            return @{ id = $scope.siteId; principalId = [string]$site.identity.principalId; endpoint = "https://$hostName"
                binding = $binding; packageDigest = $Package.receipt.packageDigest }
        }
}

function Invoke-GatewayUpgradePublisher {
    param($Context, $Package, $PublisherImage, [switch]$ReadOnly)
    $scope = $Context.plan.scope.purview
    $role = Get-GatewayUpgradeRoleContract $Context 'publisherWriter'
    $network = Get-PurviewExecutorStorageNetwork -Config $Context.config -Foundation $Context.foundation -Runtime $Context.runtime `
        -Context @{ deploymentOwnershipId = $Context.state.deploymentOwnershipId; sourceFingerprint = $Context.state.acceptedPlan.sourceFingerprint }
    $intentHash = Get-GatewayUpgradeFingerprint @{ plan = $Context.planFingerprint; operation = 'purview-publication' }
    $intentId = [guid]::new($intentHash.Substring(7, 32)).ToString('D')
    $parameters = @{
        jobName = $scope.publisherName; location = $Context.config.location
        deploymentOwnershipId = $Context.state.deploymentOwnershipId; bootstrapSourceFingerprint = $Context.state.acceptedPlan.sourceFingerprint
        executionSourceFingerprint = $Context.artifactSourceFingerprint; upgradePlanFingerprint = $Context.planFingerprint
        executionIntentId = $intentId; containerAppsEnvironmentId = $Context.foundation.containerAppsEnvironmentId
        imagePullIdentityResourceId = $Context.foundation.runtimeImagePullIdentityId; acrLoginServer = $Context.foundation.acrLoginServer
        publisherImageDigest = $PublisherImage.digest; packageDigest = $Package.receipt.packageDigest
        packageBytes = [int]$Package.receipt.packageBytes; storageAccountName = $network.storageAccountName
        expectedStoragePrivateEndpointIp = $network.privateEndpointIp; writerRoleName = $role.assignmentName
    }
    $expectedEnv = @(
        @{ name = 'PUBLISHER_DEPLOYMENT_OWNERSHIP_ID'; value = $Context.state.deploymentOwnershipId }
        @{ name = 'PUBLISHER_EXECUTION_INTENT_ID'; value = $intentId }
        @{ name = 'PUBLISHER_EXECUTION_SOURCE_FINGERPRINT'; value = $Context.artifactSourceFingerprint }
        @{ name = 'PUBLISHER_PACKAGE_DIGEST'; value = $Package.receipt.packageDigest }
        @{ name = 'PUBLISHER_PACKAGE_BYTES'; value = [string]$Package.receipt.packageBytes }
        @{ name = 'PUBLISHER_CONTAINER_URI'; value = "https://$($network.storageAccountName).blob.core.windows.net/purview-executor-packages" }
        @{ name = 'PUBLISHER_PRIVATE_ENDPOINT_IP'; value = $network.privateEndpointIp }
    )
    $templateHolder = @{}
    $job = Invoke-GatewayUpgradeArmDeployment $Context 'publisher-job' 'infrastructure\bicep\maintenance-purview-publisher.bicep' `
        $parameters @($scope.publisherId, $role.assignmentResourceId) -ReadOnly:$ReadOnly -Readback {
            param($outputs)
            $live = Invoke-GatewayUpgradeArm $Context GET $scope.publisherId '2025-01-01'
            $containers = @($live.properties.template.containers)
            if ($live.properties.environmentId -cne $Context.foundation.containerAppsEnvironmentId -or
                $live.tags.gatewayUpgradePlanFingerprint -cne $Context.planFingerprint -or
                $live.properties.configuration.triggerType -cne 'Manual' -or [int]$live.properties.configuration.replicaRetryLimit -ne 0 -or
                [int]$live.properties.configuration.manualTriggerConfig.parallelism -ne 1 -or
                $containers.Count -ne 1 -or $containers[0].image -cne $PublisherImage.image -or
                (Get-GatewayUpgradeFingerprint @($containers[0].env | Sort-Object name)) -cne (Get-GatewayUpgradeFingerprint @($expectedEnv | Sort-Object name))) {
                throw 'UpgradeExecution: publisher job or source-bound payload transport differs.'
            }
            $null = Test-GatewayUpgradeRoleReadback $Context $role $live.identity.principalId
            $templateHolder.value = $live.properties.template
            return @{ id = $scope.publisherId; name = $scope.publisherName; principalId = [string]$live.identity.principalId; image = $PublisherImage.image }
        }
    return Invoke-GatewayUpgradeOnce $Context 'publisher-execution' @{
        jobId = $job.id; executionIntentId = $intentId; packageDigest = $Package.receipt.packageDigest
    } -ReadOnly:$ReadOnly -MaximumReadAttempts 140 -Discover {
        $executions = @(Invoke-AzJson -Arguments @('containerapp', 'job', 'execution', 'list',
            '--resource-group', $Context.config.resourceGroupName, '--name', $job.name, '--query', '[].{name:name}'))
        if ($executions.Count -eq 0) { return $null }
        if ($executions.Count -ne 1) { throw 'UpgradeExecution: publisher has more than its one authorized execution.' }
        $execution = Invoke-AzJson -Arguments @('containerapp', 'job', 'execution', 'show',
            '--resource-group', $Context.config.resourceGroupName, '--name', $job.name, '--job-execution-name', $executions[0].name)
        $actual = ConvertTo-PurviewPublisherExecutionTemplate -Template $execution.properties.template
        $expected = ConvertTo-PurviewPublisherExecutionTemplate -Template $templateHolder.value -JobTemplate
        if ((Get-GatewayUpgradeFingerprint $actual) -cne (Get-GatewayUpgradeFingerprint $expected)) {
            throw 'UpgradeExecution: publisher execution differs from the exact verified one-shot template.'
        }
        if ($execution.properties.status -in @('Running', 'Processing', 'Pending', 'Scheduled')) { return $null }
        if ($execution.properties.status -cne 'Succeeded') { throw 'UpgradeExecution: publisher failed; upload is not replayed.' }
        return @{ executionName = [string]$execution.name; packageDigest = $Package.receipt.packageDigest; sourceFingerprint = $Context.artifactSourceFingerprint }
    } -Mutate {
        Invoke-AzJson -CaptureStdoutOnly -Arguments @('containerapp', 'job', 'start', '--resource-group',
            $Context.config.resourceGroupName, '--name', $job.name, '--query', '{name:name}') | Out-Null
    }
}

function New-GatewayUpgradeCapabilityFact {
    param([string]$Kind, [string]$Status, $Values = @{})
    $fact = [ordered]@{ kind = $Kind; status = $Status }
    foreach ($name in @('agent365RegistryApiApplicationId', 'contentSafetyAccountResourceId', 'contentSafetyEndpoint',
            'gatewayApiManagedIdentityPrincipalObjectId', 'purviewRuntimeManagedIdentityPrincipalObjectId',
            'purviewAutomationApplicationId', 'purviewAutomationServicePrincipalObjectId', 'keyVaultResourceId',
            'keyVaultHost', 'certificateName', 'certificateSecretUri')) {
        $fact[$name] = if ($Values.Contains($name)) { $Values[$name] } else { $null }
    }
    return $fact
}

function Get-GatewayUpgradeCapabilityPreparation {
    param($Context, $ContentSafety, $Automation, $Certificate, $Queue, $RuntimeRoles, $DatabaseReceipt, [switch]$ReadOnly)
    if ($Context.plan.request.schemaVersion -eq 2) {
        $receipt = ConvertFrom-Json $DatabaseReceipt.receiptJson -AsHashtable -Depth 100
        if ($receipt.BeforeSchemaFingerprint -cne $receipt.AfterSchemaFingerprint -or
            [string]::IsNullOrEmpty($receipt.PriorCapabilityFactsJson)) {
            throw 'UpgradeExecution: source-only promotion requires independently observed unchanged schema and Full capability facts.'
        }
        $facts = ConvertFrom-Json $receipt.PriorCapabilityFactsJson -AsHashtable -Depth 20
        $baseline = $Context.state.steps['Purview capability prerequisites'].evidence
        $expected = @(
            (New-GatewayUpgradeCapabilityFact 'Agent365RegistrationBeta' 'Installed' @{
                agent365RegistryApiApplicationId = $baseline.agent365RegistrationBeta.registryApiApplicationId
            })
            (New-GatewayUpgradeCapabilityFact 'PromptShields' 'Installed' @{
                contentSafetyAccountResourceId = $baseline.promptShields.contentSafetyAccountResourceId
                contentSafetyEndpoint = $baseline.promptShields.contentSafetyEndpoint
                gatewayApiManagedIdentityPrincipalObjectId = $baseline.promptShields.gatewayApiManagedIdentityPrincipalObjectId
            })
            (New-GatewayUpgradeCapabilityFact 'Purview' 'Installed' @{
                gatewayApiManagedIdentityPrincipalObjectId = $baseline.purview.gatewayApiManagedIdentityPrincipalObjectId
                purviewRuntimeManagedIdentityPrincipalObjectId = $baseline.purview.purviewRuntimeManagedIdentityPrincipalObjectId
                purviewAutomationApplicationId = $baseline.purview.automationApplicationId
                purviewAutomationServicePrincipalObjectId = $baseline.purview.automationServicePrincipalObjectId
                keyVaultResourceId = $baseline.purview.keyVaultResourceId; keyVaultHost = $baseline.purview.keyVaultHost
                certificateName = $baseline.purview.certificateName; certificateSecretUri = $baseline.purview.certificateSecretUri
            })
        )
        if ($facts.deploymentOwnershipId -cne $Context.state.deploymentOwnershipId -or
            $facts.originalBootstrapSourceFingerprint -cne $Context.state.acceptedPlan.sourceFingerprint -or
            (Get-GatewayUpgradeFingerprint $facts.capabilities) -cne (Get-GatewayUpgradeFingerprint $expected)) {
            throw 'UpgradeSourceOnly: private Full capability facts differ from the exact retained baseline.'
        }
        # No Core->Full preparation or certificate grant is manufactured. The
        # original Full projection remains the runtime's exact attestation.
        return @{ factsJson = $receipt.PriorCapabilityFactsJson; factsFingerprint = $receipt.PriorCapabilityFactsFingerprint; mode = 'PreserveFull' }
    }
    $existing = Read-GatewayUpgradeExecutionRecord $Context 'capability-preparation' 'result'
    if ($null -ne $existing) { return $existing.record.value }
    if ($ReadOnly) { throw 'UpgradeExecution: read-only verification cannot create a missing capability preparation receipt.' }
    $database = ConvertFrom-Json $DatabaseReceipt.receiptJson -AsHashtable -Depth 100
    if (-not $database.PriorCapabilityFactsJson -or
        $database.PriorCapabilityFactsFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'UpgradeExecution: capability preparation requires independently observed private database facts.'
    }
    $prior = ConvertFrom-Json $database.PriorCapabilityFactsJson -AsHashtable -Depth 20
    $time = [DateTime]::UtcNow.ToString('O')
    $registration = $prior.capabilities[0]
    $roles = [Collections.Generic.List[object]]::new()
    $roles.Add(@{
        capability = 'PromptShields'; kind = 'AzureRbac'; principalObjectId = $Context.runtime.apiPrincipalId
        resourceId = $ContentSafety.accountId; roleName = 'CognitiveServicesUser'
        roleDefinitionId = 'a97b65f3-24c7-4388-baec-2e87135dc908'; assignmentId = $ContentSafety.roleId.Split('/')[-1]
        resourcePrincipalObjectId = $null
    })
    $roles.Add(@{
        capability = 'Purview'; kind = 'AzureRbac'; principalObjectId = $Context.runtime.workerPrincipalId
        resourceId = $Queue.certificateReader.scope; roleName = 'KeyVaultSecretsUser'
        roleDefinitionId = $Queue.certificateReader.roleId; assignmentId = $Queue.certificateReader.assignmentId
        resourcePrincipalObjectId = $null
    })
    foreach ($role in @($RuntimeRoles) + @($Automation.exchangeGrant)) {
        $roles.Add(@{
            capability = 'Purview'; kind = 'GraphApplication'; principalObjectId = $role.principalId
            resourceId = $role.resourceAppId; roleName = $role.roleName; roleDefinitionId = $role.roleId
            assignmentId = $role.assignmentId; resourcePrincipalObjectId = $role.resourcePrincipalId
        })
    }
    $roles.Add(@{
        capability = 'Purview'; kind = 'EntraDirectory'; principalObjectId = $Automation.principalId
        resourceId = '/'; roleName = 'ComplianceAdministrator'; roleDefinitionId = $Automation.directoryGrant.roleId
        assignmentId = $Automation.directoryGrant.assignmentId; resourcePrincipalObjectId = $null
    })
    $snapshot = @{
        attestedAtUtc = $time; roleBindings = @($roles)
        capabilities = @(
            $registration
            (New-GatewayUpgradeCapabilityFact 'PromptShields' 'Installed' @{
                contentSafetyAccountResourceId = $ContentSafety.accountId; contentSafetyEndpoint = $ContentSafety.endpoint
                gatewayApiManagedIdentityPrincipalObjectId = $Context.runtime.apiPrincipalId
            })
            (New-GatewayUpgradeCapabilityFact 'Purview' 'Installed' @{
                gatewayApiManagedIdentityPrincipalObjectId = $Context.runtime.apiPrincipalId
                purviewRuntimeManagedIdentityPrincipalObjectId = $Context.purviewRuntime.principalId
                purviewAutomationApplicationId = $Automation.applicationId; purviewAutomationServicePrincipalObjectId = $Automation.principalId
                keyVaultResourceId = $Context.runtime.sharedKeyVaultId
                keyVaultHost = ([uri]$Context.runtime.keyVaultUri).Host; certificateName = 'purview-automation-certificate'
                certificateSecretUri = $Certificate.secretUri
            })
        )
    }
    $hash = Get-GatewayUpgradeFingerprint @{ plan = $Context.planFingerprint; operation = 'capability-preparation' }
    $receipt = @{
        schemaVersion = 1; kind = 'A365GatewayCapabilityPreparation'; upgradeId = [guid]::new($hash.Substring(7, 32)).ToString('D')
        status = 'PreparedConfiguration'; approvedPlanFingerprint = $Context.planFingerprint
        candidateSourceFingerprint = $Context.plan.content.sourceFingerprint; deploymentOwnershipId = $Context.state.deploymentOwnershipId
        tenantId = $Context.config.tenantId; subscriptionId = $Context.config.subscriptionId; resourceGroup = $Context.config.resourceGroupName
        originalBootstrapSourceFingerprint = $Context.state.acceptedPlan.sourceFingerprint
        originalStateReference = 'state/' + [IO.Path]::GetFileName($Context.statePath); originalStateFingerprint = $Context.plan.original.stateSha256
        originalConfigurationReference = 'configuration/' + [IO.Path]::GetFileName($Context.configPath); originalConfigurationFingerprint = $Context.plan.original.configSha256
        originalCapabilityFactsHash = ''; previousReceiptFingerprint = $null; expectedPriorCapabilityFactsHash = ''; targetSnapshotHash = ''
        apiPrincipal = @{ clientId = $Context.database.apiPrincipalClientId; objectId = $Context.runtime.apiPrincipalId }
        workerPrincipal = @{ clientId = $Context.database.workerPrincipalClientId; objectId = $Context.runtime.workerPrincipalId }
        purviewRuntimePrincipal = @{ clientId = $Context.purviewRuntime.clientId; objectId = $Context.purviewRuntime.principalId }
        targetSnapshot = $snapshot; readbackAtUtc = $time
    }
    $inputJson = ConvertTo-Json -InputObject @{ receipt = $receipt; databaseUpgradeReceiptJson = $DatabaseReceipt.receiptJson } -Depth 100 -Compress
    $null = Test-GatewayUpgradeLocalValidation $Context.plan.localValidation
    $output = Invoke-BootstrapCommand -FilePath 'dotnet' -ArgumentList @(
        $Context.plan.localValidation.toolPath, '--server', $Context.runtime.sqlServerFqdn, '--database', 'GatewayDb',
        '--phase', 'capability-preparation-plan', '--repository-root', $Context.plan.localValidation.buildRoot,
        '--capability-preparation-input-json', $inputJson)
    $lines = @($output.Split("`n") | Where-Object { $_.StartsWith('A365GW_CAPABILITY_PREPARATION:') })
    if ($lines.Count -ne 1) { throw 'UpgradeExecution: canonical prepared capability receipt was not emitted.' }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($lines[0].Substring('A365GW_CAPABILITY_PREPARATION:'.Length).Trim()))
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $digest = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)) } finally { $algorithm.Dispose() }
    $result = @{ receiptJson = $json; receiptFingerprint = 'sha256:' + [BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant() }
    $null = Write-GatewayUpgradeExecutionRecord $Context 'capability-preparation' 'intent' @{
        inputFingerprint = Get-GatewayUpgradeFingerprint @{
            snapshot = $snapshot; databaseReceiptFingerprint = $DatabaseReceipt.receiptFingerprint
            observedPriorFactsFingerprint = $database.PriorCapabilityFactsFingerprint
        }
    }
    $null = Write-GatewayUpgradeExecutionRecord $Context 'capability-preparation' 'result' $result
    return $result
}

function Get-GatewayUpgradeApiEnvironment {
    param($Context, $DatabaseReceipt, $Preparation)
    if ($Context.plan.request.schemaVersion -eq 2) {
        return @{
            DatabaseAttestation__ExpectedSchemaFingerprint = $DatabaseReceipt.schemaFingerprint
            DatabaseAttestation__Upgrade__Enabled = 'true'; DatabaseAttestation__Upgrade__PlanFingerprint = $Context.planFingerprint
            DatabaseAttestation__Upgrade__UpgradeSourceFingerprint = $Context.plan.content.sourceFingerprint
            DatabaseAttestation__Upgrade__ReceiptFingerprint = $DatabaseReceipt.receiptFingerprint
            DatabaseAttestation__Upgrade__BeforeSchemaFingerprint = $DatabaseReceipt.beforeSchemaFingerprint
            DatabaseAttestation__Upgrade__SqlManifestFingerprint = $DatabaseReceipt.sqlManifestFingerprint
            DatabaseAttestation__Upgrade__ReceiptJson = $DatabaseReceipt.receiptJson
        }
    }
    $receipt = ConvertFrom-Json $Preparation.receiptJson -AsHashtable -Depth 100
    $values = @{
        EntraId__Instance = 'https://login.microsoftonline.com/'
        PromptShield__Enabled = 'true'; Purview__Enabled = 'true'
        PurviewRuntimeIdentity__ManagedIdentityClientId = $Context.purviewRuntime.clientId
        PurviewRuntimeIdentity__ManagedIdentityPrincipalObjectId = $Context.purviewRuntime.principalId
        Purview__ManagedIdentityClientId = $Context.purviewRuntime.clientId
        DatabaseAttestation__ExpectedSchemaFingerprint = $DatabaseReceipt.schemaFingerprint
        DatabaseAttestation__Upgrade__Enabled = 'true'; DatabaseAttestation__Upgrade__PlanFingerprint = $Context.planFingerprint
        DatabaseAttestation__Upgrade__UpgradeSourceFingerprint = $Context.plan.content.sourceFingerprint
        DatabaseAttestation__Upgrade__ReceiptFingerprint = $DatabaseReceipt.receiptFingerprint
        DatabaseAttestation__Upgrade__BeforeSchemaFingerprint = $DatabaseReceipt.beforeSchemaFingerprint
        DatabaseAttestation__Upgrade__SqlManifestFingerprint = $DatabaseReceipt.sqlManifestFingerprint
        DatabaseAttestation__Upgrade__ReceiptJson = $DatabaseReceipt.receiptJson
        BootstrapCapabilities__AttestedAtUtc = $receipt.targetSnapshot.attestedAtUtc
        BootstrapCapabilities__Preparation__ReceiptJson = $Preparation.receiptJson
        BootstrapCapabilities__Preparation__ReceiptFingerprint = $Preparation.receiptFingerprint
    }
    foreach ($fact in $receipt.targetSnapshot.capabilities) {
        $values["BootstrapCapabilities__$($fact.kind)__Status"] = $fact.status
        foreach ($key in $fact.Keys) {
            if ($key -cin @('kind', 'status') -or $null -eq $fact[$key]) { continue }
            $property = $key.Substring(0, 1).ToUpperInvariant() + $key.Substring(1)
            $values["BootstrapCapabilities__$($fact.kind)__$property"] = [string]$fact[$key]
        }
        if ($fact.kind -ceq 'PromptShields') { $values.PromptShield__Endpoint = [string]$fact.contentSafetyEndpoint }
    }
    foreach ($key in @('approvedPlanFingerprint', 'candidateSourceFingerprint', 'tenantId', 'subscriptionId', 'resourceGroup',
            'originalStateReference', 'originalStateFingerprint', 'originalConfigurationReference', 'originalConfigurationFingerprint')) {
        $property = $key.Substring(0, 1).ToUpperInvariant() + $key.Substring(1)
        $values["BootstrapCapabilities__Preparation__$property"] = [string]$receipt[$key]
    }
    foreach ($key in @('apiPrincipal', 'workerPrincipal', 'purviewRuntimePrincipal')) {
        $property = $key.Substring(0, 1).ToUpperInvariant() + $key.Substring(1)
        $values["BootstrapCapabilities__Preparation__$property`__ClientId"] = [string]$receipt[$key].clientId
        $values["BootstrapCapabilities__Preparation__$property`__ObjectId"] = [string]$receipt[$key].objectId
    }
    if ($Context.plan.Contains('cutover')) {
        foreach ($entry in (Get-GatewayUpgradeMaintenanceEnvironment $Context PostSchemaClosed).GetEnumerator()) {
            $values[$entry.Key] = $entry.Value
        }
    }
    return $values
}

function Get-GatewayUpgradeMaintenanceEnvironment {
    param($Context, [ValidateSet('PreSchemaClosed', 'PostSchemaClosed', 'Open')][string]$Phase)
    if ($Phase -ceq 'Open') { return @{ MaintenanceCutover__Phase = 'Open' } }
    $idHash = Get-GatewayUpgradeFingerprint @{
        purpose = 'GatewayUpgradeCutover'; planFingerprint = $Context.planFingerprint
        boundaryFingerprint = Get-GatewayUpgradeFingerprint $Context.plan.cutover
    }
    return @{
        MaintenanceCutover__Phase = $Phase
        MaintenanceCutover__PlanFingerprint = $Context.planFingerprint
        MaintenanceCutover__CandidateSourceFingerprint = $Context.plan.content.sourceFingerprint
        MaintenanceCutover__CutoverId = [guid]::new($idHash.Substring(7, 32)).ToString('D')
    }
}

function Get-GatewayUpgradeWorkerEnvironment {
    param($Context, $Automation, $Certificate, $Executor)
    if ($Context.plan.request.schemaVersion -eq 2) {
        return @{
            ProvisioningWorker__ProcessingEnabled = 'false'; ProtectionAdminWorker__ProcessingEnabled = 'false'
            PurviewExecutor__Binding__ExecutionSourceFingerprint = $Executor.binding.ExecutionSourceFingerprint
            PurviewExecutor__Binding__PackageDigest = $Executor.binding.PackageDigest
        }
    }
    $values = @{
        ProvisioningWorker__ProcessingEnabled = 'false'
        ProtectionAdminWorker__ProcessingEnabled = 'false'; ProtectionAdminWorker__MaxConcurrentCalls = '2'
        ProtectionAdminWorker__MaxDeliveryCount = '10'; ProtectionAdminWorker__MaximumPropagationAttempts = '5'
        ProtectionAdminWorker__PropagationRetryDelaySeconds = '30'
        Purview__Enabled = 'true'; Purview__PolicyProvisioningEnabled = 'true'
        Purview__PolicyProvisioningOrganization = $Certificate.organization
        Purview__PolicyProvisioningApplicationId = $Automation.applicationId
        Purview__PolicyProvisioningCertificateSecretUri = $Certificate.secretUri
        PurviewRuntimeIdentity__ManagedIdentityClientId = $Context.purviewRuntime.clientId
        PurviewRuntimeIdentity__ManagedIdentityPrincipalObjectId = $Context.purviewRuntime.principalId
        PurviewExecutor__Enabled = 'true'; PurviewExecutor__Endpoint = $Executor.endpoint; PurviewExecutor__TimeoutSeconds = '215'
    }
    foreach ($key in $Executor.binding.Keys) { $values["PurviewExecutor__Binding__$key"] = [string]$Executor.binding[$key] }
    return $values
}

function Invoke-GatewayUpgradeContentSafety {
    param($Context, [switch]$ReadOnly)
    $scope = $Context.plan.scope
    $accountId = [string]$scope.roles[0].scope
    $roleId = [string]$scope.roles[0].assignmentResourceId
    $parameters = @{
        accountName = $accountId.Split('/')[-1]; location = $Context.config.location
        apiPrincipalId = $Context.runtime.apiPrincipalId; roleAssignmentName = $roleId.Split('/')[-1]
        deploymentOwnershipId = $Context.state.deploymentOwnershipId
        bootstrapSourceFingerprint = $Context.state.acceptedPlan.sourceFingerprint
        upgradeSourceFingerprint = $Context.plan.content.sourceFingerprint; upgradePlanFingerprint = $Context.planFingerprint
    }
    return Invoke-GatewayUpgradeArmDeployment $Context 'content-safety' 'infrastructure\bicep\maintenance-content-safety.bicep' `
        $parameters @($accountId, $roleId) -ReadOnly:$ReadOnly -Readback {
            param($outputs)
            $account = Invoke-GatewayUpgradeArm $Context GET $accountId '2023-05-01'
            $role = Invoke-GatewayUpgradeArm $Context GET $roleId '2022-04-01'
            if ($account.kind -cne 'ContentSafety' -or $account.sku.name -cne 'S0' -or
                $account.location -cne $Context.config.location -or $account.properties.disableLocalAuth -ne $true -or
                $account.properties.customSubDomainName -cne $parameters.accountName -or
                $account.tags.gatewayUpgradePlanFingerprint -cne $Context.planFingerprint -or
                $role.properties.principalId -cne $Context.runtime.apiPrincipalId -or
                $role.properties.roleDefinitionId -cne $scope.roles[0].roleDefinitionId) {
                throw 'UpgradeExecution: Content Safety identity, paid SKU or role readback differs.'
            }
            return @{ accountId = $accountId; endpoint = "https://$($parameters.accountName).cognitiveservices.azure.com/"; roleId = $roleId; sku = 'S0' }
        }
}

function Invoke-GatewayUpgradeImageBuild {
    param($Context, [ValidateSet('api', 'worker', 'adminUi', 'databaseMigrator', 'publisher')][string]$Component,
        [string]$BuildRoot, [switch]$ReadOnly)
    if ($Component -cne 'publisher' -and
        [IO.Path]::GetFullPath($BuildRoot) -cne [IO.Path]::GetFullPath($Context.sourceRoot)) {
        throw 'UpgradeExecution: image builds must upload the exact approved source snapshot.'
    }
    if ($Component -ceq 'publisher') {
        if (-not $Context.Contains('publisherContextReceipt') -or -not $Context.Contains('publisherContextFingerprint') -or
            (Test-GatewayUpgradePublisherContext $Context.publisherContextReceipt $Context.publisherContextFingerprint) -cne
            [IO.Path]::GetFullPath($BuildRoot)) {
            throw 'UpgradeExecution: publisher upload lacks its exact independently verified binary-context receipt.'
        }
    }
    $definitions = @{
        api = @('gateway-api', 'src/Gateway.Api/Dockerfile')
        worker = @('gateway-worker', 'src/Gateway.Provisioning.Worker/Dockerfile')
        adminUi = @('gateway-admin', 'src/Gateway.AdminUi/Dockerfile')
        databaseMigrator = @('gateway-db-migrator', 'tools/Gateway.DatabaseMigrator/Dockerfile')
        publisher = @('gateway-purview-package-publisher', 'src/Gateway.Purview.PackagePublisher/Dockerfile')
    }
    $definition = $definitions[$Component]
    $registry = $Context.foundation.acrLoginServer.Split('.')[0]
    $tag = "maintenance-$($Context.planFingerprint.Substring(7, 24))-$($Component.ToLowerInvariant())"
    $repository = $definition[0]
    return Invoke-GatewayUpgradeOnce $Context "image-$($Component.ToLowerInvariant())" @{
        registry = $registry; repository = $repository; tag = $tag; sourceFingerprint = $Context.plan.content.sourceFingerprint
        publisherContextFingerprint = if ($Component -ceq 'publisher') { $Context.publisherContextFingerprint } else { $null }
    } -ReadOnly:$ReadOnly -Discover {
        $runs = @(Get-GatewayAcrExactImageRuns -Registry $registry -Repository $repository -Tag $tag -TagContract MaintenanceV1)
        if ($runs.Count -eq 0) {
            if ($null -ne (Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag -TagContract MaintenanceV1)) {
                throw 'UpgradeExecution: image tag has no exact source-bound build run.'
            }
            return $null
        }
        if ($runs.Count -ne 1) { throw 'UpgradeExecution: an image intent has multiple build runs.' }
        $run = Get-GatewayAcrExactRunById -Registry $registry -Repository $repository -Tag $tag -RunId $runs[0].runId -TagContract MaintenanceV1
        if ($run.status -in @('Queued', 'Started', 'Running')) { return $null }
        $run = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository $repository -Tag $tag -TagContract MaintenanceV1
        $digest = [string]$run.outputImages[0].digest
        $tagReadback = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag -TagContract MaintenanceV1
        if ($null -eq $tagReadback -or $tagReadback.digest -cne $digest) { throw 'UpgradeExecution: build output and immutable tag digest differ.' }
        return @{ image = "$($Context.foundation.acrLoginServer)/$repository@$digest"; digest = $digest; runId = [string]$run.runId }
    } -Mutate {
        if ($Component -cne 'publisher') {
            $null = Test-GatewayUpgradeCandidate $Context.candidateReceiptPath $Context.candidateFingerprint
        }
        else { $null = Test-GatewayUpgradePublisherContext $Context.publisherContextReceipt $Context.publisherContextFingerprint }
        Invoke-AzJson -CaptureStdoutOnly -Arguments @('acr', 'build', '--registry', $registry,
            '--image', "${repository}:$tag", '--file', $definition[1], $BuildRoot, '--no-logs',
            '--query', '{runId:runId,status:status}') | Out-Null
    }
}

function Get-GatewayUpgradeSqlManifest {
    param($Context, [string]$ExecutionIntentId)
    $database = $Context.plan.request.database
    $scripts = @($database.scripts | ForEach-Object {
        @{ Name = [IO.Path]::GetFileName($_.path); Sha256 = [string]$_.sha256 }
    })
    return [ordered]@{
        SchemaVersion = $(if ($Context.plan.request.schemaVersion -eq 2) { 2 } else { 1 }); PlanFingerprint = $Context.planFingerprint
        UpgradeSourceFingerprint = $Context.plan.content.sourceFingerprint
        OriginalAcceptedSourceFingerprint = $Context.state.acceptedPlan.sourceFingerprint
        DeploymentOwnershipId = $Context.state.deploymentOwnershipId; ExecutionIntentId = $ExecutionIntentId
        Server = $Context.runtime.sqlServerFqdn; Database = 'GatewayDb'
        EvidenceContainerUri = "https://$($Context.runtime.storageAccountId.Split('/')[-1]).blob.core.windows.net/gateway-upgrade-evidence"
        BeforeSchemaFingerprint = $database.currentSchemaFingerprint
        AfterSchemaFingerprint = $database.targetSchemaFingerprint
        PreviousReceiptFingerprint = $null
        Scripts = $scripts
        TargetModelFingerprint = if ($database.Contains('targetModelFingerprint')) { $database.targetModelFingerprint } else { $null }
        Cutover = if ($Context.plan.Contains('cutover')) { $Context.plan.cutover } else { $null }
        CutoverBoundaryFingerprint = if ($Context.plan.Contains('cutover')) { Get-GatewayUpgradeFingerprint $Context.plan.cutover } else { $null }
        CutoverApiImage = if ($Context.plan.Contains('cutover')) { $Context.plan.request.images.api } else { $null }
        RollbackCompatibilityReviewFingerprint = if ($Context.plan.Contains('rollbackContract')) { $Context.plan.rollbackContract.reviewEvidenceFingerprint } else { $null }
        RollbackImages = if ($Context.plan.Contains('rollbackContract')) { $Context.plan.rollbackContract.images } else { $null }
        CutoverOriginalRevisionResourceIds = if ($Context.Contains('cutoverInventory')) {
            @($Context.cutoverInventory.apps.api.revisions) + @($Context.cutoverInventory.apps.worker.revisions)
        } else { $null }
    }
}

function Get-GatewayUpgradeGraphApplicationRoleId {
    param($Context, [string]$RoleName)
    $validation = $Context.plan.localValidation
    $null = Test-GatewayUpgradeLocalValidation $validation
    # Use a fresh candidate-bound process rather than retaining another candidate's loaded assembly.
    $output = Invoke-BootstrapCommand -FilePath 'dotnet' -ArgumentList @(
        $validation.toolPath, '--server', 'sql-role-lookup.database.windows.net', '--database', 'GatewayDb',
        '--phase', 'capability-graph-role-id', '--repository-root', $validation.sourceRoot, '--graph-role-name', $RoleName)
    if ($output -isnot [string] -or $output.Length -gt 128 -or
        $output.Trim() -cnotmatch '^A365GW_GRAPH_APPLICATION_ROLE:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') {
        throw 'UpgradeExecution: candidate Graph role lookup did not return one exact application-role ID.'
    }
    return $Matches[1]
}

function Invoke-GatewayUpgradeGraphRole {
    param($Context, [string]$Action, [string]$PrincipalId,
        [ValidateSet('ProtectionScopes.Compute.User', 'Content.Process.User', 'ContentActivity.Write', 'Exchange.ManageAsApp')][string]$RoleName,
        [switch]$ReadOnly)
    $resourceAppId = if ($RoleName -ceq 'Exchange.ManageAsApp') { '00000002-0000-0ff1-ce00-000000000000' }
        else { '00000003-0000-0000-c000-000000000000' }
    $resource = Get-ServicePrincipalByAppId -AppId $resourceAppId
    $roles = @($resource.appRoles | Where-Object { $_.value -ceq $RoleName -and $_.isEnabled -eq $true -and 'Application' -cin @($_.allowedMemberTypes) })
    if ($roles.Count -ne 1) { throw 'UpgradeExternalPrerequisite: the exact Microsoft application role is unavailable.' }
    $roleId = [string]$roles[0].id
    $expectedRoleId = if ($RoleName -ceq 'Exchange.ManageAsApp') { 'dc50a0fb-09a3-484d-be87-e023b12c6440' }
        else { Get-GatewayUpgradeGraphApplicationRoleId $Context $RoleName }
    if ($roleId -cne $expectedRoleId -or [string]$resource.appId -cne $resourceAppId) {
        throw 'UpgradeExternalPrerequisite: discovered Microsoft application role ID/resource differs from the reviewed permission contract.'
    }
    $resourcePrincipalId = [string]$resource.id
    return Invoke-GatewayUpgradeOnce $Context $Action @{
        principalId = $PrincipalId; resourcePrincipalId = $resourcePrincipalId; resourceAppId = $resourceAppId; roleId = $roleId; roleName = $RoleName
    } -ReadOnly:$ReadOnly -Discover {
        $assignments = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments")
        $matching = @($assignments | Where-Object {
            $_.principalId -ceq $PrincipalId -and $_.resourceId -ceq $resourcePrincipalId -and $_.appRoleId -ceq $roleId
        })
        if ($matching.Count -eq 0) { return $null }
        if ($matching.Count -ne 1) { throw 'UpgradeExecution: duplicate Microsoft application role assignments.' }
        return @{
            kind = 'GraphApplication'; principalId = $PrincipalId; resourceAppId = $resourceAppId
            resourcePrincipalId = $resourcePrincipalId; roleId = $roleId; roleName = $RoleName; assignmentId = [string]$matching[0].id
        }
    } -Mutate {
        Invoke-GraphJsonBody -Method POST -Url "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" `
            -Body @{ principalId = $PrincipalId; resourceId = $resourcePrincipalId; appRoleId = $roleId } | Out-Null
    }
}

function Invoke-GatewayUpgradeAutomationIdentity {
    param($Context, [switch]$ReadOnly)
    $name = "A365 Gateway Purview Automation - $($Context.config.projectName)-$($Context.config.environment)"
    $tags = @(Get-BootstrapApplicationTags -DeploymentOwnershipId $Context.state.deploymentOwnershipId)
    $exchange = Get-BootstrapPurviewExchangeRole
    $app = Invoke-GatewayUpgradeOnce $Context 'purview-automation-application' @{
        displayName = $name; tenantId = $Context.config.tenantId; ownershipId = $Context.state.deploymentOwnershipId
    } -ReadOnly:$ReadOnly -Discover {
        $value = Get-ExactApplicationByDisplayName -DisplayName $name
        if ($null -eq $value) { return $null }
        $value = Get-BootstrapPurviewAutomationApplication -ApplicationObjectId $value.id
        if ($value.displayName -cne $name -or $value.signInAudience -cne 'AzureADMyOrg' -or
            @($value.passwordCredentials).Count -ne 0 -or
            (Get-GatewayUpgradeFingerprint @($value.tags | Sort-Object)) -cne (Get-GatewayUpgradeFingerprint @($tags | Sort-Object))) {
            throw 'UpgradeExecution: automation application ownership or credential surface differs.'
        }
        return @{ objectId = [string]$value.id; applicationId = [string]$value.appId }
    } -Mutate {
        Invoke-GraphJsonBody -Method POST -Url 'https://graph.microsoft.com/v1.0/applications' -Body @{
            displayName = $name; signInAudience = 'AzureADMyOrg'; tags = $tags; isFallbackPublicClient = $false
            web = @{ implicitGrantSettings = @{ enableAccessTokenIssuance = $false; enableIdTokenIssuance = $false } }
            api = @{ acceptMappedClaims = $false; preAuthorizedApplications = @(); knownClientApplications = @(); oauth2PermissionScopes = @() }
            appRoles = @(); keyCredentials = @()
            requiredResourceAccess = @(@{ resourceAppId = '00000002-0000-0ff1-ce00-000000000000'
                resourceAccess = @(@{ id = 'dc50a0fb-09a3-484d-be87-e023b12c6440'; type = 'Role' }) })
        } | Out-Null
    }
    $null = Invoke-GatewayUpgradeOnce $Context 'purview-automation-owner' @{
        applicationId = $app.objectId; ownerObjectId = $Context.plan.authorizedOperator.automationOwnerObjectId
    } -AllowExisting -ReadOnly:$ReadOnly -Discover {
        $owners = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/applications/$($app.objectId)/owners?`$select=id")
        if ($owners.Count -eq 0) { return $null }
        if ($owners.Count -ne 1 -or $owners[0].id -cne $Context.plan.authorizedOperator.automationOwnerObjectId) { throw 'UpgradeExecution: automation owners differ from the approved operator.' }
        return @{ applicationId = $app.objectId; ownerObjectId = [string]$owners[0].id }
    } -Mutate {
        Invoke-GraphJsonBody -Method POST -Url "https://graph.microsoft.com/v1.0/applications/$($app.objectId)/owners/`$ref" `
            -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($Context.plan.authorizedOperator.automationOwnerObjectId)" } | Out-Null
    }
    $applicationReadback = Get-BootstrapPurviewAutomationApplication -ApplicationObjectId $app.objectId
    $null = Assert-BootstrapPurviewAutomationApplication -Application $applicationReadback -DisplayName $name `
        -DeploymentOwnershipId $Context.state.deploymentOwnershipId -OwnerObjectId $Context.plan.authorizedOperator.automationOwnerObjectId `
        -ExchangeRole $exchange -AllowMissingCertificate
    $principal = Invoke-GatewayUpgradeOnce $Context 'purview-automation-principal' @{
        applicationId = $app.applicationId; ownershipId = $Context.state.deploymentOwnershipId
    } -ReadOnly:$ReadOnly -Discover {
        $value = Get-ServicePrincipalByAppId -AppId $app.applicationId
        if ($null -eq $value) { return $null }
        $null = Assert-BootstrapPurviewAutomationServicePrincipal -Principal $value -ApplicationId $app.applicationId `
            -DeploymentOwnershipId $Context.state.deploymentOwnershipId -ExchangeRole $exchange -AllowMissingAssignments
        return @{ objectId = [string]$value.id; applicationId = [string]$value.appId }
    } -Mutate {
        Ensure-ServicePrincipal -AppId $app.applicationId -ServicePrincipalNames @($app.applicationId) -Tags $tags | Out-Null
    }
    $exchangeGrant = Invoke-GatewayUpgradeGraphRole $Context 'purview-exchange-grant' $principal.objectId 'Exchange.ManageAsApp' -ReadOnly:$ReadOnly
    $definitionId = '17315797-102d-40b4-93e0-432062caca18'
    $directoryGrant = Invoke-GatewayUpgradeOnce $Context 'purview-compliance-grant' @{
        principalId = $principal.objectId; definitionId = $definitionId; scope = '/'
    } -ReadOnly:$ReadOnly -Discover {
        $assignments = @(Get-BootstrapPurviewDirectoryRoleAssignments -PrincipalId $principal.objectId)
        if ($assignments.Count -eq 0) { return $null }
        if ($assignments.Count -ne 1 -or $assignments[0].roleDefinitionId -cne $definitionId -or $assignments[0].directoryScopeId -cne '/') {
            throw 'UpgradeExecution: automation directory authority is outside the exact reviewed role.'
        }
        return @{ principalId = $principal.objectId; roleId = $definitionId; assignmentId = [string]$assignments[0].id; scope = '/' }
    } -Preflight {
        $definition = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url',
            "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/$definitionId")
        if ($definition.id -cne $definitionId -or $definition.templateId -cne $definitionId -or $definition.isBuiltIn -ne $true -or $definition.isEnabled -ne $true) {
            throw 'UpgradeExternalPrerequisite: Compliance Administrator is not available exactly.'
        }
    } -Mutate {
        Invoke-GraphJsonBody -Method POST -Url 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' `
            -Body @{ principalId = $principal.objectId; roleDefinitionId = $definitionId; directoryScopeId = '/' } | Out-Null
    }
    return @{ applicationObjectId = $app.objectId; applicationId = $app.applicationId; principalId = $principal.objectId
        exchangeGrant = $exchangeGrant; directoryGrant = $directoryGrant }
}

function Invoke-GatewayUpgradeAutomationCertificate {
    param($Context, $Automation, [switch]$ReadOnly)
    $secretId = "$($Context.runtime.sharedKeyVaultId)/secrets/purview-automation-certificate"
    $keyHash = Get-GatewayUpgradeFingerprint @{ plan = $Context.planFingerprint; operation = 'purview-certificate' }
    $keyId = [guid]::new($keyHash.Substring(7, 32)).ToString('D')
    return Invoke-GatewayUpgradeOnce $Context 'purview-certificate' @{
        applicationId = $Automation.applicationId; applicationObjectId = $Automation.applicationObjectId; secretId = $secretId; keyId = $keyId
    } -ReadOnly:$ReadOnly -Discover {
        $secret = Get-GatewayPurviewAutomationCertificateSecretArmMetadata -Config $Context.config `
            -KeyVaultUri $Context.runtime.keyVaultUri -AutomationApplicationId $Automation.applicationId `
            -DeploymentOwnershipId $Context.state.deploymentOwnershipId -SourceFingerprint $Context.state.acceptedPlan.sourceFingerprint
        $application = Get-BootstrapPurviewAutomationApplication -ApplicationObjectId $Automation.applicationObjectId
        $keys = @($application.keyCredentials)
        if ($secret.status -ceq 'Absent' -and $keys.Count -eq 0) { return $null }
        if ($secret.status -cne 'Present' -or $keys.Count -ne 1 -or $keys[0].keyId -cne $keyId -or $secret.keyCredentialId -cne $keyId) {
            throw 'UpgradeOutcomeUnknown: certificate state is partial or foreign; no certificate replacement is permitted.'
        }
        $evidence = Get-BootstrapPurviewAutomationIdentityEvidence -Config $Context.config -AzureIdentity $Context.actor `
            -KeyVaultUri $Context.runtime.keyVaultUri -DeploymentOwnershipId $Context.state.deploymentOwnershipId `
            -SourceFingerprint $Context.state.acceptedPlan.sourceFingerprint
        return @{ secretId = $secretId; secretUri = [string]$evidence.certificateSecretUri; keyId = $keyId
            thumbprint = [string]$secret.certificateThumbprint; organization = [string]$evidence.organization }
    } -Mutate {
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $certificate = $null
        $pfx = $null
        try {
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                "CN=A365GatewayPurview-$($Automation.applicationId)", $rsa,
                [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $start = [DateTimeOffset]::UtcNow.AddMinutes(-5)
            $end = $start.AddDays(364)
            $certificate = $request.CreateSelfSigned($start, $end)
            $pfx = $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12)
            $parameters = @{
                keyVaultName = $Context.runtime.sharedKeyVaultId.Split('/')[-1]; keyCredentialId = $keyId
                certificateThumbprint = $certificate.Thumbprint.ToLowerInvariant(); automationApplicationId = $Automation.applicationId
                deploymentOwnershipId = $Context.state.deploymentOwnershipId
                bootstrapSourceFingerprint = $Context.state.acceptedPlan.sourceFingerprint
                secretValue = [Convert]::ToBase64String($pfx)
            }
            $null = Invoke-GatewayUpgradeArmDeployment $Context 'purview-certificate-store' 'bootstrap\infra\purview-automation-certificate.bicep' `
                $parameters @($secretId) -Readback {
                    param($outputs)
                    $value = Get-GatewayPurviewAutomationCertificateSecretArmMetadata -Config $Context.config `
                        -KeyVaultUri $Context.runtime.keyVaultUri -AutomationApplicationId $Automation.applicationId `
                        -DeploymentOwnershipId $Context.state.deploymentOwnershipId -SourceFingerprint $Context.state.acceptedPlan.sourceFingerprint
                    if ($value.status -cne 'Present' -or $value.keyCredentialId -cne $keyId -or
                        $value.certificateThumbprint -cne $certificate.Thumbprint.ToLowerInvariant()) {
                        throw 'UpgradeExecution: stored certificate metadata differs from the exact one-shot credential.'
                    }
                    return @{ secretId = $secretId; keyId = $keyId; thumbprint = [string]$value.certificateThumbprint }
                }
            Invoke-GraphJsonBody -Method PATCH -Url "https://graph.microsoft.com/v1.0/applications/$($Automation.applicationObjectId)" -Body @{
                keyCredentials = @(@{
                    keyId = $keyId; type = 'AsymmetricX509Cert'; usage = 'Verify'
                    displayName = 'a365gw-purview-automation-certificate'
                    key = [Convert]::ToBase64String($certificate.RawData)
                    customKeyIdentifier = [Convert]::ToBase64String($certificate.GetCertHash())
                    startDateTime = $start.ToString('O'); endDateTime = $end.ToString('O')
                })
            } | Out-Null
        }
        finally {
            if ($null -ne $pfx) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($pfx) }
            if ($null -ne $certificate) { $certificate.Dispose() }
            $rsa.Dispose()
        }
    }
}

function Read-GatewayUpgradeDatabaseReceipt {
    param($Context, [string]$JobName, [string]$ExecutionName)
    if ($JobName -cnotmatch '^[a-z0-9-]{3,32}$' -or $ExecutionName -cnotmatch "^$([regex]::Escape($JobName))-[a-z0-9]{5,16}$") {
        throw 'UpgradeExecution: invalid exact migration execution name.'
    }
    $intentHash = Get-GatewayUpgradeFingerprint @{ plan = $Context.planFingerprint; operation = 'private-database-upgrade' }
    $executionIntentId = [guid]::new($intentHash.Substring(7, 32)).ToString('D')
    $prefix = "A365GW_UPGRADE_EVIDENCE|$executionIntentId|"
    $workspace = Invoke-AzJson -Arguments @('monitor', 'log-analytics', 'workspace', 'show',
        '--resource-group', $Context.config.resourceGroupName, '--workspace-name', $Context.foundation.logAnalyticsWorkspaceName,
        '--query', '{id:id,customerId:customerId}')
    $expectedWorkspaceId = "$($Context.plan.scope.resourceGroupId)/providers/Microsoft.OperationalInsights/workspaces/$($Context.foundation.logAnalyticsWorkspaceName)"
    if ($workspace.id -cne $expectedWorkspaceId -or [string]$workspace.customerId -cne ([guid][string]$workspace.customerId).ToString('D')) {
        throw 'UpgradeExecution: migration evidence workspace is outside the exact deployment.'
    }
    $query = "ContainerAppConsoleLogs_CL | where TimeGenerated > ago(30d) | where ContainerGroupName_s startswith '$ExecutionName' | where Log_s startswith '$prefix' | summarize by Log_s | take 2"
    $matches = @()
    for ($attempt = 1; $attempt -le 36; $attempt++) {
        $matches = @(Invoke-AzJson -CaptureStdoutOnly -Arguments @('monitor', 'log-analytics', 'query',
            '--workspace', $workspace.customerId, '--analytics-query', $query, '--query', '[].Log_s'))
        if ($matches.Count -gt 0) { break }
        if ($attempt -lt 36) { Start-Sleep -Seconds 10 }
    }
    if ($matches.Count -ne 1) { throw 'UpgradeExecution: exactly one bounded private database receipt was not observed.' }
    $encoded = $matches[0].Substring($prefix.Length).Trim()
    if ($encoded.Length -gt 16384 -or $encoded -cnotmatch '^[A-Za-z0-9+/]+={0,2}$') {
        throw 'UpgradeExecution: private database receipt encoding is invalid.'
    }
    $json = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String($encoded))
    return Test-GatewayUpgradeDatabaseReceipt $Context $json $JobName $ExecutionName
}

function Test-GatewayUpgradeDatabaseReceipt {
    param($Context, [string]$Json, [string]$JobName, [string]$ExecutionName)
    $intentHash = Get-GatewayUpgradeFingerprint @{ plan = $Context.planFingerprint; operation = 'private-database-upgrade' }
    $executionIntentId = [guid]::new($intentHash.Substring(7, 32)).ToString('D')
    if ($json.Length -gt 8192) { throw 'UpgradeExecution: database receipt exceeds its bounded contract.' }
    $document = [Text.Json.JsonDocument]::Parse($json)
    try {
        $receipt = & (Get-Module GatewayUpgrade) { param($element) ConvertFrom-GatewayUpgradeJsonElement $element } $document.RootElement
    }
    finally { $document.Dispose() }
    $receiptKeys = @('SchemaVersion', 'DeploymentOwnershipId', 'OriginalAcceptedSourceFingerprint', 'OriginalMarkerFingerprint',
        'PlanFingerprint', 'UpgradeSourceFingerprint', 'PreviousReceiptFingerprint', 'BeforeSchemaFingerprint', 'AfterSchemaFingerprint',
        'SqlManifestFingerprint', 'ExecutionIntentId', 'Server', 'Database', 'RegistrationIdentityFingerprintBefore',
        'RegistrationIdentityFingerprintAfter', 'VerifiedAtUtc', 'TargetModelFingerprint',
        'PriorCapabilityFactsJson', 'PriorCapabilityFactsFingerprint')
    if ($receipt.Keys.Count -ne $receiptKeys.Count -or @($receipt.Keys | Where-Object { $_ -cnotin $receiptKeys }).Count -ne 0 -or
        $receipt.SchemaVersion -ne 1 -or $receipt.PlanFingerprint -cne $Context.planFingerprint -or
        $receipt.DeploymentOwnershipId -cne $Context.state.deploymentOwnershipId -or
        $receipt.OriginalAcceptedSourceFingerprint -cne $Context.state.acceptedPlan.sourceFingerprint -or
        $receipt.UpgradeSourceFingerprint -cne $Context.plan.content.sourceFingerprint -or
        $receipt.Server -cne $Context.runtime.sqlServerFqdn -or $receipt.Database -cne 'GatewayDb' -or
        $receipt.ExecutionIntentId -cne $executionIntentId -or
        $receipt.BeforeSchemaFingerprint -cne $Context.plan.request.database.currentSchemaFingerprint -or
        $receipt.RegistrationIdentityFingerprintBefore -cne $receipt.RegistrationIdentityFingerprintAfter) {
        throw 'UpgradeExecution: database receipt does not match the exact original and approved upgrade boundaries.'
    }
    if ($receipt.PriorCapabilityFactsJson -isnot [string] -or $receipt.PriorCapabilityFactsJson.Length -gt 4096 -or
        $receipt.PriorCapabilityFactsFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'UpgradeExecution: independently observed prior capability facts are missing.'
    }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $priorHash = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($receipt.PriorCapabilityFactsJson)) } finally { $algorithm.Dispose() }
    if (('sha256:' + [BitConverter]::ToString($priorHash).Replace('-', '').ToLowerInvariant()) -cne $receipt.PriorCapabilityFactsFingerprint) {
        throw 'UpgradeExecution: independently observed prior capability facts changed.'
    }
    $manifest = Get-GatewayUpgradeSqlManifest $Context $executionIntentId
    $manifestLines = (@($manifest.Scripts | ForEach-Object { "$($_.Name)|$($_.Sha256)`n" }) -join '')
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $sqlHash = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($manifestLines)) } finally { $algorithm.Dispose() }
    $expectedSqlHash = 'sha256:' + [BitConverter]::ToString($sqlHash).Replace('-', '').ToLowerInvariant()
    if ($receipt.SqlManifestFingerprint -cne $expectedSqlHash -or
        ($manifest.AfterSchemaFingerprint -cne '' -and $receipt.AfterSchemaFingerprint -cne $manifest.AfterSchemaFingerprint) -or
        $receipt.TargetModelFingerprint -cne $manifest.TargetModelFingerprint) {
        throw 'UpgradeExecution: receipt SQL or target-schema contract differs from the approved manifest.'
    }
    foreach ($key in @('OriginalMarkerFingerprint', 'BeforeSchemaFingerprint', 'AfterSchemaFingerprint',
            'SqlManifestFingerprint', 'RegistrationIdentityFingerprintBefore')) {
        if ([string]$receipt[$key] -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'UpgradeExecution: database receipt fingerprint is malformed.' }
    }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $hash = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)) } finally { $algorithm.Dispose() }
    return @{
        receiptJson = $json; receiptFingerprint = 'sha256:' + [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
        schemaFingerprint = $receipt.AfterSchemaFingerprint; beforeSchemaFingerprint = $receipt.BeforeSchemaFingerprint
        sqlManifestFingerprint = $receipt.SqlManifestFingerprint; jobName = $JobName; executionName = $ExecutionName
        priorCapabilityFactsFingerprint = $receipt.PriorCapabilityFactsFingerprint
    }
}

function Restore-GatewayUpgradeSqlAdministrator {
    param($Context, $Job, [string]$ServerName, $Original, [switch]$ReadOnly)
    $admin = Get-GatewaySqlEntraAdministrator -Config $Context.config -ServerName $ServerName
    if ($admin.objectId -ceq $Original.objectId -and $admin.login -ceq $Original.login) { return }
    if ($admin.objectId -cne $Job.principalId -or $admin.login -cne $Job.name) {
        throw 'UpgradeExecution: SQL administrator changed outside the exact authorized delegation.'
    }
    if ($ReadOnly) { throw 'UpgradeExecution: original SQL administrator restoration is required; read-only verification will not mutate it.' }
    $null = Invoke-GatewayUpgradeOnce $Context 'sql-admin-restore' @{ server = $ServerName; original = $Original } -Compensation -Discover {
        $current = Get-GatewaySqlEntraAdministrator -Config $Context.config -ServerName $ServerName
        if ($current.objectId -ceq $Original.objectId -and $current.login -ceq $Original.login) { return $Original }
        if ($current.objectId -cne $Job.principalId -or $current.login -cne $Job.name) {
            throw 'UpgradeExecution: SQL administrator changed outside the authorized delegation.'
        }
        return $null
    } -Mutate {
        Set-GatewaySqlEntraAdministratorExact -Config $Context.config -ServerName $ServerName -ObjectId $Original.objectId -Login $Original.login
    }
}

function Assert-GatewayUpgradeDatabaseJobFields {
    param($Value, [string[]]$Required, [string[]]$Optional = @())
    if ($Value -isnot [Collections.IDictionary] -or
        @($Required | Where-Object { $_ -cnotin @($Value.Keys) }).Count -ne 0 -or
        @($Value.Keys | Where-Object { $_ -cnotin @($Required + $Optional) }).Count -ne 0) {
        throw 'UpgradeExecution: database job contract has missing or unknown fields.'
    }
}

function Assert-GatewayUpgradeDatabaseJobValue {
    param($Actual, $Expected)
    if ($Expected -is [Collections.IDictionary]) {
        Assert-GatewayUpgradeDatabaseJobFields $Actual @($Expected.Keys)
        foreach ($key in $Expected.Keys) { Assert-GatewayUpgradeDatabaseJobValue $Actual[$key] $Expected[$key] }
    }
    elseif ($Expected -is [Array]) {
        if ($Actual -isnot [Array] -or $Actual.Count -ne $Expected.Count) {
            throw 'UpgradeExecution: database job contract collection differs.'
        }
        for ($i = 0; $i -lt $Expected.Count; $i++) { Assert-GatewayUpgradeDatabaseJobValue $Actual[$i] $Expected[$i] }
    }
    elseif ($null -eq $Expected) {
        if ($null -ne $Actual) { throw 'UpgradeExecution: database job provider default differs.' }
    }
    elseif ($Expected -is [string]) {
        if ($Actual -isnot [string] -or $Actual -cne $Expected) { throw 'UpgradeExecution: database job contract value differs.' }
    }
    elseif (($Actual -isnot [int] -and $Actual -isnot [long] -and $Actual -isnot [double] -and $Actual -isnot [decimal]) -or
        $Actual -ne $Expected) {
        throw 'UpgradeExecution: database job numeric contract differs.'
    }
}

function Add-GatewayUpgradeDatabaseJobEmptyDefaults {
    param($Actual, $Expected, [string[]]$Names)
    foreach ($name in $Names) {
        if ($Actual.Contains($name)) {
            # ARM optional, unconfigured collections may be omitted, null or [].
            $value = $Actual[$name]
            if ($null -ne $value -and ($value -isnot [Array] -or $value.Count -ne 0)) {
                throw 'UpgradeExecution: database job optional collection is not empty.'
            }
            if ($null -eq $value) { $Expected[$name] = $null }
            else { $Expected[$name] = @() }
        }
    }
}

function New-GatewayUpgradeDatabaseJobContract {
    param($Parameters, [string]$JobId)
    $p = $Parameters
    # Mirror maintenance-database-job.bicep from approved LOCAL inputs, never a live job.
    return @{
        id = $JobId; name = $p.jobName; type = 'Microsoft.App/jobs'; location = $p.location
        tags = @{
            application = 'a365-custom-gateway'; workload = 'database-upgrade'
            bootstrapOwnershipId = $p.deploymentOwnershipId; bootstrapSourceFingerprint = $p.bootstrapSourceFingerprint
            gatewayUpgradeSourceFingerprint = $p.upgradeSourceFingerprint; gatewayUpgradePlanFingerprint = $p.upgradePlanFingerprint
        }
        properties = @{
            environmentId = $p.containerAppsEnvironmentId; provisioningState = 'Succeeded'
            configuration = @{
                triggerType = 'Manual'; replicaTimeout = 1800; replicaRetryLimit = 0
                manualTriggerConfig = @{ parallelism = 1; replicaCompletionCount = 1 }
                identitySettings = @(
                    @{ identity = 'system'; lifecycle = 'Main' }
                    @{ identity = $p.imagePullIdentityResourceId; lifecycle = 'None' }
                )
                registries = @(@{ server = $p.acrLoginServer; identity = $p.imagePullIdentityResourceId })
                secrets = @()
            }
            template = @{
                containers = @(@{
                    name = 'database-upgrade'; image = "$($p.acrLoginServer)/gateway-db-migrator@$($p.migratorImageDigest)"
                    command = @('dotnet', 'Gateway.DatabaseMigrator.dll')
                    args = @(
                        '--server', $p.sqlServerFqdn, '--database', 'GatewayDb', '--phase', 'upgrade', '--repository-root', '/app',
                        '--deployment-ownership-id', $p.deploymentOwnershipId,
                        '--accepted-source-fingerprint', $p.bootstrapSourceFingerprint,
                        '--expected-private-endpoint-ip', $p.expectedPrivateEndpointIp,
                        '--execution-intent-id', $p.executionIntentId,
                        '--expected-api-principal-name', $p.apiPrincipalName,
                        '--expected-api-principal-client-id', $p.apiPrincipalClientId,
                        '--expected-worker-principal-name', $p.workerPrincipalName,
                        '--expected-worker-principal-client-id', $p.workerPrincipalClientId,
                        '--upgrade-plan-fingerprint', $p.upgradePlanFingerprint
                    )
                    env = @(
                        @{ name = 'DATABASE_MIGRATOR_UPGRADE_MANIFEST_JSON'; value = $p.upgradeManifestJson }
                        @{ name = 'DATABASE_MIGRATOR_UPGRADE_MANIFEST_FINGERPRINT'; value = $p.upgradeManifestFingerprint }
                        @{ name = 'DOTNET_EnableDiagnostics'; value = '0' }
                    )
                    resources = @{ cpu = 0.5; memory = '1Gi' }
                })
            }
        }
    }
}

function Assert-GatewayUpgradeDatabaseJobTemplate {
    param($Actual, $Expected, [switch]$Execution)
    $expectedCopy = ConvertFrom-Json (ConvertTo-Json $Expected -Depth 30) -AsHashtable -Depth 30
    $optional = @('initContainers')
    if (-not $Execution) { $optional += 'volumes' }
    Assert-GatewayUpgradeDatabaseJobFields $Actual @('containers') $optional
    Add-GatewayUpgradeDatabaseJobEmptyDefaults $Actual $expectedCopy $optional
    if ($Actual.containers -isnot [Array] -or $Actual.containers.Count -ne 1) {
        throw 'UpgradeExecution: database job requires exactly one container.'
    }
    $container = $Actual.containers[0]
    $expectedContainer = $expectedCopy.containers[0]
    $containerOptional = if ($Execution) { @('imageType') } else { @('probes', 'volumeMounts') }
    Assert-GatewayUpgradeDatabaseJobFields $container @('name', 'image', 'command', 'args', 'env', 'resources') $containerOptional
    if ($Execution -and $container.Contains('imageType')) {
        # Stable executions expose this discriminator; only ContainerImage is reviewed
        # (see PurviewExecutor's 2025-02-02-preview BaseContainer schema reference).
        $expectedContainer.imageType = 'ContainerImage'
    }
    if (-not $Execution) { Add-GatewayUpgradeDatabaseJobEmptyDefaults $container $expectedContainer $containerOptional }
    Assert-GatewayUpgradeDatabaseJobFields $container.resources @('cpu', 'memory') @('ephemeralStorage')
    if ($container.resources.Contains('ephemeralStorage')) {
        # Consumption's provider allocation for 0.5 vCPU is 2Gi, not caller-selected storage.
        $expectedContainer.resources.ephemeralStorage = '2Gi'
    }
    # Exact recursive comparison includes every env entry/key; even a null secretRef,
    # duplicate name, extra env, reordered arguments or additional resource field fails.
    Assert-GatewayUpgradeDatabaseJobValue $Actual $expectedCopy
}

function Assert-GatewayUpgradeDatabaseJobMetadata {
    param($Value, [string[]]$Fields)
    Assert-GatewayUpgradeDatabaseJobFields $Value @() $Fields
    foreach ($key in $Value.Keys) {
        if ($null -ne $Value[$key] -and $Value[$key] -isnot [string]) {
            throw 'UpgradeExecution: database job provider metadata is malformed.'
        }
    }
}

function Assert-GatewayUpgradeDatabaseJobReadback {
    param($Context, $Live, $Role, $Expected, [string]$RoleId, [string]$PrincipalId)
    Assert-GatewayUpgradeDatabaseJobFields $Live @('id', 'name', 'type', 'location', 'tags', 'identity', 'properties') @('systemData')
    foreach ($key in @('id', 'name', 'type', 'location', 'tags')) {
        Assert-GatewayUpgradeDatabaseJobValue $Live[$key] $Expected[$key]
    }
    if ($Live.Contains('systemData')) {
        Assert-GatewayUpgradeDatabaseJobMetadata $Live.systemData @('createdBy', 'createdByType', 'createdAt', 'lastModifiedBy', 'lastModifiedByType', 'lastModifiedAt')
    }
    $identity = $Live.identity
    Assert-GatewayUpgradeDatabaseJobFields $identity @('type', 'principalId', 'tenantId', 'userAssignedIdentities')
    if ($identity.type -cnotin @('SystemAssigned,UserAssigned', 'SystemAssigned, UserAssigned') -or
        $identity.principalId -isnot [string] -or $identity.principalId -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or
        $identity.principalId -ceq '00000000-0000-0000-0000-000000000000' -or
        ($PrincipalId -and $identity.principalId -cne $PrincipalId)) {
        throw 'UpgradeExecution: database job system identity differs.'
    }
    Assert-GatewayUpgradeDatabaseJobValue $identity.tenantId $Context.config.tenantId
    $pullId = $Context.foundation.runtimeImagePullIdentityId
    Assert-GatewayUpgradeDatabaseJobFields $identity.userAssignedIdentities @($pullId)
    $pull = $identity.userAssignedIdentities[$pullId]
    Assert-GatewayUpgradeDatabaseJobFields $pull @() @('principalId', 'clientId')
    if ($pull.Contains('principalId')) {
        Assert-GatewayUpgradeDatabaseJobValue $pull.principalId $Context.foundation.runtimeImagePullIdentityPrincipalId
    }
    if ($pull.Contains('clientId') -and ($pull.clientId -isnot [string] -or
        $pull.clientId -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')) {
        throw 'UpgradeExecution: database job image-pull metadata is malformed.'
    }
    $properties = $Live.properties
    Assert-GatewayUpgradeDatabaseJobFields $properties @('environmentId', 'provisioningState', 'configuration', 'template') @('workloadProfileName', 'outboundIpAddresses', 'eventStreamEndpoint')
    $expectedProperties = ConvertFrom-Json (ConvertTo-Json $Expected.properties -Depth 30) -AsHashtable -Depth 30
    if ($properties.Contains('workloadProfileName')) {
        $expectedProperties.workloadProfileName = if ($null -eq $properties.workloadProfileName) { $null } else { 'Consumption' }
    }
    # Read-only ARM routing metadata is not execution configuration; validate it
    # explicitly before excluding it from the configuration comparison.
    if ($properties.Contains('outboundIpAddresses')) {
        if ($properties.outboundIpAddresses -isnot [Array]) { throw 'UpgradeExecution: database job outbound metadata is malformed.' }
        foreach ($ip in $properties.outboundIpAddresses) {
            $parsed = $null
            if ($ip -isnot [string] -or -not [Net.IPAddress]::TryParse($ip, [ref]$parsed)) { throw 'UpgradeExecution: database job outbound metadata is malformed.' }
        }
        $expectedProperties.outboundIpAddresses = $properties.outboundIpAddresses
    }
    if ($properties.Contains('eventStreamEndpoint')) {
        $endpoint = $null
        if ($properties.eventStreamEndpoint -isnot [string] -or
            -not [uri]::TryCreate($properties.eventStreamEndpoint, [UriKind]::Absolute, [ref]$endpoint) -or
            $endpoint.Scheme -cne 'https' -or $endpoint.UserInfo -or $endpoint.Fragment) {
            throw 'UpgradeExecution: database job event metadata is malformed.'
        }
        $expectedProperties.eventStreamEndpoint = $properties.eventStreamEndpoint
    }
    $configuration = $properties.configuration
    $expectedConfiguration = $expectedProperties.configuration
    Assert-GatewayUpgradeDatabaseJobFields $configuration @($expectedConfiguration.Keys) @('scheduleTriggerConfig', 'eventTriggerConfig')
    foreach ($key in @('scheduleTriggerConfig', 'eventTriggerConfig')) {
        if ($configuration.Contains($key)) { $expectedConfiguration[$key] = $null }
    }
    Add-GatewayUpgradeDatabaseJobEmptyDefaults $configuration $expectedConfiguration @('secrets')
    if ($configuration.registries -isnot [Array] -or $configuration.registries.Count -ne 1) {
        throw 'UpgradeExecution: database job registry contract differs.'
    }
    $registry = $configuration.registries[0]
    Assert-GatewayUpgradeDatabaseJobFields $registry @('server', 'identity') @('username', 'passwordSecretRef')
    foreach ($key in @('username', 'passwordSecretRef')) {
        if ($registry.Contains($key)) {
            if ($null -ne $registry[$key] -and ($registry[$key] -isnot [string] -or $registry[$key].Length -ne 0)) {
                throw 'UpgradeExecution: database job registry is secret-backed or malformed.'
            }
            $expectedConfiguration.registries[0][$key] = $registry[$key]
        }
    }
    Assert-GatewayUpgradeDatabaseJobTemplate $properties.template $Expected.properties.template
    $expectedProperties.template = $properties.template
    Assert-GatewayUpgradeDatabaseJobValue $properties $expectedProperties

    Assert-GatewayUpgradeDatabaseJobFields $Role @('id', 'name', 'type', 'properties')
    Assert-GatewayUpgradeDatabaseJobValue $Role.id $RoleId
    Assert-GatewayUpgradeDatabaseJobValue $Role.name $RoleId.Split('/')[-1]
    Assert-GatewayUpgradeDatabaseJobValue $Role.type 'Microsoft.Authorization/roleAssignments'
    $rp = $Role.properties
    Assert-GatewayUpgradeDatabaseJobFields $rp @('principalId', 'principalType', 'roleDefinitionId', 'scope') @(
        'condition', 'conditionVersion', 'description', 'delegatedManagedIdentityResourceId', 'createdOn', 'updatedOn', 'createdBy', 'updatedBy')
    Assert-GatewayUpgradeDatabaseJobValue $rp.principalId $identity.principalId
    Assert-GatewayUpgradeDatabaseJobValue $rp.principalType 'ServicePrincipal'
    Assert-GatewayUpgradeDatabaseJobValue $rp.scope ($RoleId -creplace '/providers/Microsoft.Authorization/roleAssignments/[^/]+$', '')
    Assert-GatewayUpgradeDatabaseJobValue $rp.roleDefinitionId "/subscriptions/$($Context.config.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe"
    foreach ($key in @('condition', 'conditionVersion', 'description', 'delegatedManagedIdentityResourceId')) {
        if ($rp.Contains($key) -and $null -ne $rp[$key] -and ($rp[$key] -isnot [string] -or $rp[$key].Length -ne 0)) {
            throw 'UpgradeExecution: database job evidence role has an override.'
        }
    }
    foreach ($key in @('createdOn', 'updatedOn', 'createdBy', 'updatedBy')) {
        if ($rp.Contains($key) -and $null -ne $rp[$key] -and $rp[$key] -isnot [string]) {
            throw 'UpgradeExecution: database job evidence role metadata is malformed.'
        }
    }
    return @{ id = $Expected.id; name = $Expected.name; principalId = $identity.principalId; image = $Expected.properties.template.containers[0].image }
}

function Get-GatewayUpgradeDatabaseJobExecution {
    param($Context, $Expected, [string]$ExecutionName)
    if ($ExecutionName -cnotmatch "^$([regex]::Escape($Expected.name))-[a-z0-9]{5,16}$") {
        throw 'UpgradeExecution: invalid exact database job execution name.'
    }
    $execution = Invoke-AzJson -Arguments @('containerapp', 'job', 'execution', 'show',
        '--subscription', $Context.config.subscriptionId, '--resource-group', $Context.config.resourceGroupName,
        '--name', $Expected.name, '--job-execution-name', $ExecutionName)
    Assert-GatewayUpgradeDatabaseJobFields $execution @('id', 'name', 'type', 'properties')
    Assert-GatewayUpgradeDatabaseJobValue $execution.name $ExecutionName
    Assert-GatewayUpgradeDatabaseJobValue $execution.id "$($Expected.id)/executions/$ExecutionName"
    Assert-GatewayUpgradeDatabaseJobValue $execution.type 'Microsoft.App/jobs/executions'
    Assert-GatewayUpgradeDatabaseJobFields $execution.properties @('status', 'template') @('startTime', 'endTime')
    foreach ($key in @('startTime', 'endTime')) {
        if ($execution.properties.Contains($key) -and $null -ne $execution.properties[$key] -and $execution.properties[$key] -isnot [string]) {
            throw 'UpgradeExecution: database job execution time metadata is malformed.'
        }
    }
    Assert-GatewayUpgradeDatabaseJobTemplate $execution.properties.template $Expected.properties.template -Execution
    if ($execution.properties.status -cnotin @('Succeeded', 'Running', 'Processing', 'Pending', 'Scheduled')) {
        throw 'UpgradeExecution: private migration did not succeed; SQL will not be replayed.'
    }
    return $execution
}

function Assert-GatewayUpgradeCutoverReaderRoles {
    param($Context, $Roles, [string]$PrincipalId)
    foreach ($contract in $Roles) {
        $role = Invoke-GatewayUpgradeArm $Context GET $contract.assignmentResourceId '2022-04-01'
        Assert-GatewayUpgradeDatabaseJobFields $role @('id', 'name', 'type', 'properties')
        Assert-GatewayUpgradeDatabaseJobFields $role.properties @('principalId', 'principalType', 'roleDefinitionId', 'scope') @(
            'condition', 'conditionVersion', 'description', 'delegatedManagedIdentityResourceId', 'createdOn', 'updatedOn', 'createdBy', 'updatedBy')
        if ($role.id -cne $contract.assignmentResourceId -or $role.properties.principalId -cne $PrincipalId -or
            $role.name -cne $contract.assignmentResourceId.Split('/')[-1] -or $role.type -cne 'Microsoft.Authorization/roleAssignments' -or
            $role.properties.scope -cne ($contract.assignmentResourceId -creplace '/providers/Microsoft.Authorization/roleAssignments/[^/]+$', '') -or
            $role.properties.roleDefinitionId -cne $contract.roleDefinitionId -or
            $role.properties.principalType -cne 'ServicePrincipal') {
            throw 'UpgradeCutover: the private observer Reader role differs from its exact Plan scope.'
        }
        foreach ($field in @('condition', 'conditionVersion', 'description', 'delegatedManagedIdentityResourceId')) {
            if ($role.properties.Contains($field) -and $null -ne $role.properties[$field] -and
                ($role.properties[$field] -isnot [string] -or $role.properties[$field].Length -ne 0)) {
                throw 'UpgradeCutover: private observer Reader role overrides are forbidden.'
            }
        }
    }
}

function Invoke-GatewayUpgradeDatabase {
    param($Context, $Images, [switch]$ReadOnly, [switch]$ObserveForRollback)
    if ($Context.plan.Contains('cutover') -and (-not $ReadOnly -or $ObserveForRollback)) {
        Assert-GatewayUpgradeCutoverHeld $Context -ZeroWriters
    }
    $jobId = [string]@($Context.plan.scope.resources | Where-Object stage -CEQ 'DatabaseExpand')[0].resourceId
    $jobName = $jobId.Split('/')[-1]
    $intentHash = Get-GatewayUpgradeFingerprint @{ plan = $Context.planFingerprint; operation = 'private-database-upgrade' }
    $executionIntentId = [guid]::new($intentHash.Substring(7, 32)).ToString('D')
    $manifest = Get-GatewayUpgradeSqlManifest $Context $executionIntentId
    $manifestJson = ConvertTo-GatewayUpgradeCanonicalJson $manifest
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $manifestHash = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($manifestJson)) } finally { $algorithm.Dispose() }
    $manifestFingerprint = 'sha256:' + [BitConverter]::ToString($manifestHash).Replace('-', '').ToLowerInvariant()
    $containerId = "$($Context.runtime.storageAccountId)/blobServices/default/containers/gateway-upgrade-evidence"
    $roleHash = Get-GatewayUpgradeFingerprint @{ scope = $containerId; principalResourceId = $jobId; role = 'Storage Blob Data Contributor' }
    $roleName = [guid]::new($roleHash.Substring(7, 32)).ToString('D')
    $roleId = "$containerId/providers/Microsoft.Authorization/roleAssignments/$roleName"
    $parameters = @{
        jobName = $jobName; location = $Context.config.location
        containerAppsEnvironmentId = $Context.foundation.containerAppsEnvironmentId
        imagePullIdentityResourceId = $Context.foundation.runtimeImagePullIdentityId
        acrLoginServer = $Context.foundation.acrLoginServer; migratorImageDigest = $Images.databaseMigrator.digest
        deploymentOwnershipId = $Context.state.deploymentOwnershipId; bootstrapSourceFingerprint = $Context.state.acceptedPlan.sourceFingerprint
        upgradeSourceFingerprint = $Context.plan.content.sourceFingerprint; upgradePlanFingerprint = $Context.planFingerprint
        executionIntentId = $executionIntentId; sqlServerFqdn = $Context.runtime.sqlServerFqdn
        expectedPrivateEndpointIp = $Context.database.privateEndpointIpv4Address
        apiPrincipalName = $Context.database.apiPrincipalName; apiPrincipalClientId = $Context.database.apiPrincipalClientId
        workerPrincipalName = $Context.database.workerPrincipalName; workerPrincipalClientId = $Context.database.workerPrincipalClientId
        storageAccountName = $Context.runtime.storageAccountId.Split('/')[-1]; evidenceRoleAssignmentName = $roleName
        upgradeManifestJson = $manifestJson; upgradeManifestFingerprint = $manifestFingerprint
    }
    $cutoverRoles = @()
    if ($Context.plan.Contains('cutover')) {
        $cutoverRoles = @($Context.plan.scope.roles | Where-Object {
            $_.Contains('principalResourceId') -and $_.principalResourceId -ceq $jobId -and
            $_.roleDefinitionId.EndsWith('/acdd72a7-3385-48ef-bd42-f606fba81ae7', [StringComparison]::Ordinal)
        })
        if ($cutoverRoles.Count -ne 4) { throw 'UpgradeCutover: exact private observer Reader scopes are missing.' }
        $parameters.cutoverApiName = $Context.plan.cutover.ApiResourceId.Split('/')[-1]
        $parameters.cutoverWorkerName = $Context.plan.cutover.WorkerResourceId.Split('/')[-1]
        $parameters.cutoverNamespaceName = $Context.plan.cutover.ProvisioningQueueResourceId.Split('/')[-3]
        $parameters.cutoverReaderRoleNames = @($cutoverRoles | ForEach-Object { $_.assignmentResourceId.Split('/')[-1] })
    }
    $expectedJob = New-GatewayUpgradeDatabaseJobContract $parameters $jobId
    Assert-GatewayUpgradeDatabaseJobValue $Images.databaseMigrator.image $expectedJob.properties.template.containers[0].image
    $serverName = $Context.runtime.sqlServerFqdn.Split('.')[0]
    $originalAdmin = @{
        objectId = [string]$Context.database.originalSqlAdministratorObjectId
        login = [string]$Context.database.originalSqlAdministratorLogin
    }
    $job = $null
    $priorJob = Read-GatewayUpgradeExecutionRecord $Context 'database-job' 'result'
    if ($null -ne $priorJob) {
        # Keep the previously bound principal solely for original-only compensation
        # if a fresh job/role validation fails. Never adopt a changed live principal.
        $retained = $priorJob.record.value
        Assert-GatewayUpgradeDatabaseJobFields $retained @('id', 'name', 'principalId', 'image')
        Assert-GatewayUpgradeDatabaseJobValue $retained.id $jobId
        Assert-GatewayUpgradeDatabaseJobValue $retained.name $jobName
        Assert-GatewayUpgradeDatabaseJobValue $retained.image $Images.databaseMigrator.image
        if ($retained.principalId -isnot [string] -or $retained.principalId -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {
            throw 'UpgradeExecution: retained database job principal is malformed.'
        }
        $job = $retained
    }
    try {
        $job = Invoke-GatewayUpgradeArmDeployment $Context 'database-job' 'infrastructure\bicep\maintenance-database-job.bicep' `
            $parameters (@($jobId, $containerId, $roleId) + @($cutoverRoles | ForEach-Object assignmentResourceId)) -ReadOnly:$ReadOnly -Readback {
                param($outputs)
                $live = Invoke-GatewayUpgradeArm $Context GET $jobId '2025-01-01'
                $role = Invoke-GatewayUpgradeArm $Context GET $roleId '2022-04-01'
                $principal = if ($null -ne $job) { $job.principalId } else { '' }
                $verified = Assert-GatewayUpgradeDatabaseJobReadback $Context $live $role $expectedJob $roleId $principal
                Assert-GatewayUpgradeCutoverReaderRoles $Context $cutoverRoles $verified.principalId
                return $verified
            }
        $assertCurrentJob = {
            $live = Invoke-GatewayUpgradeArm $Context GET $jobId '2025-01-01'
            $role = Invoke-GatewayUpgradeArm $Context GET $roleId '2022-04-01'
            $null = Assert-GatewayUpgradeDatabaseJobReadback $Context $live $role $expectedJob $roleId $job.principalId
            Assert-GatewayUpgradeCutoverReaderRoles $Context $cutoverRoles $job.principalId
        }
        $executionResult = Read-GatewayUpgradeExecutionRecord $Context 'database-execution' 'result'
        if ($ReadOnly -or $null -ne $executionResult) {
            if ($null -eq $executionResult) { throw 'UpgradeExecution: no private migration execution is verified.' }
            Restore-GatewayUpgradeSqlAdministrator $Context $job $serverName $originalAdmin -ReadOnly:$ReadOnly
            $saved = $executionResult.record.value
            $execution = Get-GatewayUpgradeDatabaseJobExecution $Context $expectedJob $saved.executionName
            if ($execution.properties.status -cne 'Succeeded') { throw 'UpgradeExecution: retained database job execution has not succeeded.' }
            $verified = Test-GatewayUpgradeDatabaseReceipt $Context $saved.receiptJson $jobName $saved.executionName
            if ((Get-GatewayUpgradeFingerprint $saved) -cne (Get-GatewayUpgradeFingerprint $verified)) {
                throw 'UpgradeExecution: retained immutable database receipt changed.'
            }
            if ($ObserveForRollback) {
                $null = Invoke-GatewayUpgradeRollbackDatabaseObservation $Context $expectedJob $job $cutoverRoles $roleId `
                    $serverName $originalAdmin $verified $manifestFingerprint
            }
            return $verified
        }
        $executionIntent = Read-GatewayUpgradeExecutionRecord $Context 'database-execution' 'intent'
        if ($null -eq $executionIntent) {
            $null = Invoke-GatewayUpgradeOnce $Context 'sql-admin-delegate' @{
                server = $serverName; original = $originalAdmin; jobPrincipalId = $job.principalId
            } -Discover {
                & $assertCurrentJob
                $admin = Get-GatewaySqlEntraAdministrator -Config $Context.config -ServerName $serverName
                if ($admin.objectId -ceq $job.principalId -and $admin.login -ceq $jobName) { return @{ objectId = $admin.objectId; login = $admin.login } }
                if ($admin.objectId -cne $originalAdmin.objectId -or $admin.login -cne $originalAdmin.login) { throw 'UpgradeExecution: SQL administrator drift prevents delegation.' }
                return $null
            } -Mutate {
                & $assertCurrentJob
                if ($Context.plan.Contains('cutover')) { Assert-GatewayUpgradeCutoverHeld $Context -ZeroWriters }
                Set-GatewaySqlEntraAdministratorExact -Config $Context.config -ServerName $serverName -ObjectId $job.principalId -Login $jobName
            }
        }
        return Invoke-GatewayUpgradeOnce $Context 'database-execution' @{
            jobId = $jobId; executionIntentId = $executionIntentId; image = $Images.databaseMigrator.image; manifestFingerprint = $manifestFingerprint
        } -MaximumReadAttempts 360 -Discover {
            $executions = @(Invoke-AzJson -Arguments @('containerapp', 'job', 'execution', 'list',
                '--subscription', $Context.config.subscriptionId, '--resource-group', $Context.config.resourceGroupName, '--name', $jobName,
                '--query', '[].{name:name,status:properties.status}'))
            if ($executions.Count -eq 0) { return $null }
            if ($executions.Count -ne 1 -or $executions[0].name -cnotmatch "^$([regex]::Escape($jobName))-[a-z0-9]+$") {
                throw 'UpgradeExecution: the one-shot migration job exposes ambiguous executions.'
            }
            $execution = Get-GatewayUpgradeDatabaseJobExecution $Context $expectedJob $executions[0].name
            if ($execution.properties.status -cne 'Succeeded') { return $null }
            return Read-GatewayUpgradeDatabaseReceipt $Context $jobName $executions[0].name
        } -Mutate {
            & $assertCurrentJob
            Invoke-AzJson -Arguments @('containerapp', 'job', 'start', '--subscription', $Context.config.subscriptionId,
                '--resource-group', $Context.config.resourceGroupName, '--name', $jobName) | Out-Null
        }
    }
    finally {
        if ($null -ne $job) { Restore-GatewayUpgradeSqlAdministrator $Context $job $serverName $originalAdmin -ReadOnly:$ReadOnly }
    }
}

function Invoke-GatewayUpgradeRollbackDatabaseObservation {
    param($Context, $ExpectedJob, $Job, $ReaderRoles, [string]$EvidenceRoleId,
        [string]$ServerName, $OriginalAdmin, $OriginalReceipt, [string]$ManifestFingerprint)
    Assert-GatewayUpgradeCutoverHeld $Context -ZeroWriters
    Assert-GatewayUpgradeRollbackContract $Context $OriginalReceipt
    $observationJob = ConvertFrom-Json (ConvertTo-Json $ExpectedJob -Depth 100) -AsHashtable -Depth 100
    $arguments = $observationJob.properties.template.containers[0].args
    $phaseIndices = @(for ($index = 0; $index -lt $arguments.Count; $index++) { if ($arguments[$index] -ceq '--phase') { $index } })
    if ($phaseIndices.Count -ne 1 -or $phaseIndices[0] + 1 -ge $arguments.Count -or $arguments[$phaseIndices[0] + 1] -cne 'upgrade') {
        throw 'UpgradeCutover: the original private job phase is not the fixed upgrade contract.'
    }
    $arguments[$phaseIndices[0] + 1] = 'upgrade-observe'
    $observationTransport = Get-GatewayUpgradeRollbackObservationTransport $Context $OriginalReceipt
    $observationJob.properties.template.containers[0].args += @(
        '--rollback-observation-json', $observationTransport.json,
        '--rollback-observation-fingerprint', $observationTransport.fingerprint)
    $assertJob = {
        $live = Invoke-GatewayUpgradeArm $Context GET $Job.id '2025-01-01'
        $role = Invoke-GatewayUpgradeArm $Context GET $EvidenceRoleId '2022-04-01'
        $null = Assert-GatewayUpgradeDatabaseJobReadback $Context $live $role $ExpectedJob $EvidenceRoleId $Job.principalId
        Assert-GatewayUpgradeCutoverReaderRoles $Context $ReaderRoles $Job.principalId
    }
    $observationAction = 'database-rollback-observation'
    if ($null -ne (Read-GatewayUpgradeExecutionRecord $Context 'cutover-open-rollback' 'intent')) {
        throw 'UpgradeCutoverReconciliationRequired: another rollback observation requires a new approved Plan after a rollback reopen attempt.'
    }
    try {
        & $assertJob
        if ($null -eq (Read-GatewayUpgradeExecutionRecord $Context $observationAction 'intent')) {
            $null = Invoke-GatewayUpgradeOnce $Context 'sql-admin-observation-delegate' @{
                server = $ServerName; original = $OriginalAdmin; jobPrincipalId = $Job.principalId
            } -Discover {
                & $assertJob
                $admin = Get-GatewaySqlEntraAdministrator -Config $Context.config -ServerName $ServerName
                if ($admin.objectId -ceq $Job.principalId -and $admin.login -ceq $Job.name) { return @{ objectId = $admin.objectId; login = $admin.login } }
                if ($admin.objectId -cne $OriginalAdmin.objectId -or $admin.login -cne $OriginalAdmin.login) {
                    throw 'UpgradeExecution: SQL administrator drift prevents observation delegation.'
                }
                return $null
            } -Mutate {
                & $assertJob
                Assert-GatewayUpgradeCutoverHeld $Context -ZeroWriters
                Set-GatewaySqlEntraAdministratorExact -Config $Context.config -ServerName $ServerName -ObjectId $Job.principalId -Login $Job.name
            }
        }
        return Invoke-GatewayUpgradeOnce $Context $observationAction @{
            jobId = $Job.id; manifestFingerprint = $ManifestFingerprint
            originalExecutionName = $OriginalReceipt.executionName; originalReceiptFingerprint = $OriginalReceipt.receiptFingerprint
            observationTemplateFingerprint = Get-GatewayUpgradeFingerprint $observationJob.properties.template
        } -MaximumReadAttempts 360 -Discover {
            & $assertJob
            $executions = @(Invoke-AzJson -Arguments @('containerapp', 'job', 'execution', 'list',
                '--subscription', $Context.config.subscriptionId, '--resource-group', $Context.config.resourceGroupName, '--name', $Job.name,
                '--query', '[].{name:name,status:properties.status}'))
            $original = @($executions | Where-Object name -CEQ $OriginalReceipt.executionName)
            $observations = @($executions | Where-Object name -CNE $OriginalReceipt.executionName)
            if ($original.Count -ne 1 -or $original[0].status -cne 'Succeeded' -or $observations.Count -gt 1) {
                throw 'UpgradeOutcomeUnknown: rollback observation execution inventory differs from one original and at most one observation.'
            }
            if ($observations.Count -eq 0) { return $null }
            $execution = Get-GatewayUpgradeDatabaseJobExecution $Context $observationJob $observations[0].name
            if ($execution.properties.status -cin @('Failed', 'Stopped', 'Canceled')) {
                throw 'UpgradeCutoverReconciliationRequired: private rollback observation failed; no SQL replay or reopening is authorized.'
            }
            if ($execution.properties.status -cne 'Succeeded') { return $null }
            $observed = Read-GatewayUpgradeDatabaseReceipt $Context $Job.name $observations[0].name
            if ($observed.receiptJson -cne $OriginalReceipt.receiptJson -or $observed.receiptFingerprint -cne $OriginalReceipt.receiptFingerprint) {
                throw 'UpgradeCutoverReconciliationRequired: observation must return the unchanged original upgrade receipt, never apply another migration.'
            }
            return $observed
        } -Mutate {
            & $assertJob
            Assert-GatewayUpgradeCutoverHeld $Context -ZeroWriters
            $null = Invoke-GatewayUpgradeArm $Context POST "$($Job.id)/start" '2025-01-01' $observationJob.properties.template
        }
    }
    finally { Restore-GatewayUpgradeSqlAdministrator $Context $Job $ServerName $OriginalAdmin }
}

function Get-GatewayUpgradeRollbackObservationTransport {
    param($Context, $OriginalReceipt)
    $compatibility = $Context.plan.rollbackContract
    $reviewBytes = [IO.File]::ReadAllBytes($compatibility.reviewEvidenceReference)
    $reviewJson = [Text.UTF8Encoding]::new($false, $true).GetString($reviewBytes)
    $observationBinding = @{
        SchemaVersion = 1
        PlanFingerprint = $Context.planFingerprint
        UpgradeSourceFingerprint = $Context.plan.content.sourceFingerprint
        ReceiptFingerprint = $OriginalReceipt.receiptFingerprint
        ModelFingerprint = $compatibility.modelFingerprint
        CompatibilityReviewFingerprint = $compatibility.reviewEvidenceFingerprint
        CompatibilityReviewJson = $reviewJson
        Images = $compatibility.images
    }
    $observationJson = ConvertTo-GatewayUpgradeCanonicalJson $observationBinding
    if ([Text.Encoding]::UTF8.GetByteCount($observationJson) -gt 32768) {
        throw 'UpgradeRollbackNotApproved: the bounded observation review exceeds the private transport contract.'
    }
    $observationHash = 'sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($observationJson))).ToLowerInvariant()
    return @{ json = $observationJson; fingerprint = $observationHash }
}

function Get-GatewayUpgradeWorkloadSnapshot {
    param($Context, [ValidateSet('api', 'worker', 'adminUi')][string]$Component)
    $name = switch ($Component) {
        api { "ca-gateway-api-$($Context.config.environment)" }
        worker { "ca-gateway-worker-$($Context.config.environment)-v3" }
        adminUi { "ca-gateway-admin-$($Context.config.environment)" }
    }
    $id = "$($Context.plan.scope.resourceGroupId)/providers/Microsoft.App/containerApps/$name"
    $version = if ($Component -ceq 'worker') { '2025-01-01' } else { '2024-03-01' }
    $app = Invoke-GatewayUpgradeArm $Context GET $id $version
    $containers = @($app.properties.template.containers)
    $environmentId = if ($app.properties.Contains('environmentId') -and $app.properties.environmentId) { [string]$app.properties.environmentId } else { [string]$app.properties.managedEnvironmentId }
    if ($app.id -cne $id -or $app.tags.bootstrapOwnershipId -cne $Context.state.deploymentOwnershipId -or
        $app.tags.bootstrapSourceFingerprint -cne $Context.state.acceptedPlan.sourceFingerprint -or
        $environmentId -cne $Context.foundation.containerAppsEnvironmentId -or
        ($app.properties.configuration.activeRevisionsMode -cne 'Single' -and
            (-not $Context.Contains('cutoverInventory') -or $Component -ceq 'adminUi' -or
                $app.properties.configuration.activeRevisionsMode -cne 'Multiple')) -or
        $containers.Count -ne 1 -or $containers[0].image -cnotmatch '@sha256:[0-9a-f]{64}$') {
        throw 'UpgradeExecution: workload identity, original provenance, environment or immutable image boundary differs.'
    }
    $identityIds = @($app.identity.userAssignedIdentities.Keys)
    if ($Component -ceq 'adminUi') {
        $identityId = "$($Context.plan.scope.resourceGroupId)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-admin-$($Context.config.environment)"
        $identity = Invoke-GatewayUpgradeArm $Context GET $identityId '2023-01-31'
        if ($app.identity.type -cne 'UserAssigned' -or $identityIds.Count -ne 1 -or $identityIds[0] -cne $identityId -or
            $identity.properties.principalId -cne $Context.state.steps['Admin UI deployment'].evidence.adminUiPrincipalId) {
            throw 'UpgradeExecution: Admin identity would be changed or replaced.'
        }
        $principalId = [string]$identity.properties.principalId
        $fqdn = ([uri]$Context.state.steps['Admin UI deployment'].evidence.adminUiUrl).Host
    }
    else {
        $principalId = if ($Component -ceq 'api') { [string]$Context.runtime.apiPrincipalId } else { [string]$Context.runtime.workerPrincipalId }
        if ($app.identity.principalId -cne $principalId -or $identityIds.Count -ne 1 -or
            $identityIds[0] -cne $Context.foundation.runtimeImagePullIdentityId) {
            throw 'UpgradeExecution: an existing API/worker identity would change.'
        }
        $fqdn = if ($Component -ceq 'api') { [string]$Context.runtime.apiFqdn } else { '' }
    }
    if ($fqdn -and $app.properties.configuration.ingress.fqdn -cne $fqdn) {
        throw 'UpgradeExecution: an existing endpoint would change.'
    }
    foreach ($secret in @($app.properties.configuration.secrets)) {
        if ($null -eq $secret) { continue }
        if (-not $secret.Contains('keyVaultUrl') -or -not $secret.Contains('identity') -or
            [string]::IsNullOrWhiteSpace($secret.keyVaultUrl) -or
            ($secret.Contains('value') -and -not [string]::IsNullOrEmpty([string]$secret.value))) {
            throw 'UpgradeExecution: only exact existing Key Vault secret references can be preserved by this adapter.'
        }
    }
    return @{
        id = $id; name = $name; apiVersion = $version; raw = $app; image = [string]$containers[0].image
        normalizedConfiguration = ConvertTo-GatewayUpgradeCutoverNormalizedConfiguration $Context $Component $app.properties.configuration
        principalId = $principalId; fqdn = $fqdn; revision = [string]$app.properties.latestReadyRevisionName
        protectedConfigurationFingerprint = Get-GatewayUpgradeFingerprint @{
            identity = $app.identity; environmentId = $environmentId
            configuration = ConvertTo-GatewayUpgradeCutoverNormalizedConfiguration $Context $Component $app.properties.configuration
            protectedEnvironment = @($containers[0].env | Where-Object {
                $_.name -cnotmatch (Get-GatewayUpgradeMutableEnvironmentPattern $Component)
            } | Sort-Object name)
        }
    }
}

function Get-GatewayUpgradeMutableEnvironmentPattern {
    param([ValidateSet('api', 'worker', 'adminUi')][string]$Component)
    switch ($Component) {
        api { '^(?:MaintenanceCutover__(?:Phase|PlanFingerprint|CandidateSourceFingerprint|CutoverId)|DatabaseAttestation__(?:ExpectedSchemaFingerprint|Upgrade__[A-Za-z]+)|BootstrapCapabilities__(?:AttestedAtUtc|Agent365RegistrationBeta__[A-Za-z0-9]+|PromptShields__[A-Za-z]+|Purview__[A-Za-z]+|Preparation__[A-Za-z_]+)|PromptShield__(?:Enabled|Endpoint|ManagedIdentityClientId)|Purview__(?:Enabled|ManagedIdentityClientId)|PurviewRuntimeIdentity__ManagedIdentity(?:ClientId|PrincipalObjectId)|EntraId__Instance)$' }
        worker { '^(?:OutboxRelay__Enabled|ProvisioningWorker__ProcessingEnabled|ProtectionAdminWorker__[A-Za-z]+|Purview__(?:Enabled|PolicyProvisioningEnabled|PolicyProvisioningOrganization|PolicyProvisioningApplicationId|PolicyProvisioningCertificateSecretUri)|PurviewRuntimeIdentity__ManagedIdentity(?:ClientId|PrincipalObjectId)|PurviewExecutor__(?:Enabled|Endpoint|TimeoutSeconds|Binding__[A-Za-z]+))$' }
        adminUi { '^EntraId__Instance$' }
    }
}

function New-GatewayUpgradeWorkloadBody {
    param($Context, $Snapshot, [string]$Component, [string]$Image, $Environment, [switch]$Rollback, [switch]$EnableConsumers,
        [ValidateSet('PreSchemaClosed', 'PostSchemaClosed', 'Open')][string]$MaintenancePhase = 'PostSchemaClosed')
    $allowed = Get-GatewayUpgradeMutableEnvironmentPattern $Component
    foreach ($name in $Environment.Keys) {
        if ($name -cnotmatch $allowed -or $Environment[$name] -isnot [string]) {
            throw 'UpgradeExecution: a workload environment change is outside its fixed maintenance allowlist.'
        }
    }
    $raw = $Snapshot.raw
    $template = ConvertFrom-Json (ConvertTo-Json -InputObject $raw.properties.template -Depth 100) -AsHashtable -Depth 100
    $configuration = ConvertFrom-Json (ConvertTo-Json -InputObject $raw.properties.configuration -Depth 100) -AsHashtable -Depth 100
    foreach ($secret in @($configuration.secrets)) {
        if ($null -ne $secret -and $secret.Contains('value') -and [string]::IsNullOrEmpty([string]$secret.value)) { $secret.Remove('value') }
    }
    $identity = @{ type = $raw.identity.type; userAssignedIdentities = @{} }
    foreach ($key in $raw.identity.userAssignedIdentities.Keys) { $identity.userAssignedIdentities[$key] = @{} }
    $tags = @{}
    foreach ($key in $raw.tags.Keys) { $tags[$key] = $raw.tags[$key] }
    $tags.gatewayUpgradePlanFingerprint = $Context.planFingerprint
    $tags.gatewayUpgradeSourceFingerprint = $Context.plan.content.sourceFingerprint
    if ($Rollback) { $tags.gatewayUpgradeDisposition = 'CompatibleCodeRollback' }
    else { $tags.gatewayUpgradeDisposition = 'Promoted' }
    $template.revisionSuffix = "upg-$($Context.planFingerprint.Substring(7, 16))-$($Component.ToLowerInvariant())$(if ($Rollback) { '-rb' })"
    if ($Component -ceq 'api' -and $Context.plan.Contains('cutover')) {
        if ($MaintenancePhase -ceq 'PreSchemaClosed') { $template.revisionSuffix += '-pre' }
        elseif ($MaintenancePhase -ceq 'Open') { $template.revisionSuffix += '-open' }
    }
    if ($EnableConsumers) { $template.revisionSuffix += '-run' }
    $template.containers[0].image = $Image
    $variables = [ordered]@{}
    foreach ($entry in @($template.containers[0].env)) { $variables[$entry.name] = $entry }
    foreach ($key in $Environment.Keys) { $variables[$key] = @{ name = $key; value = $Environment[$key] } }
    if ($Component -ceq 'api' -and $Context.plan.Contains('cutover')) {
        foreach ($name in @($variables.Keys | Where-Object { $_ -clike 'MaintenanceCutover__*' })) { $variables.Remove($name) }
        foreach ($entry in (Get-GatewayUpgradeMaintenanceEnvironment $Context $MaintenancePhase).GetEnumerator()) {
            $variables[$entry.Key] = @{ name = $entry.Key; value = $entry.Value }
        }
    }
    if ($Component -ceq 'worker' -and $Context.Contains('cutoverInventory')) {
        $variables.Remove('OutboxRelay__Enabled')
        if ($EnableConsumers) {
            foreach ($entry in $Context.cutoverInventory.apps.worker.outboxEnvironment) {
                $variables[$entry.name] = ConvertFrom-Json (ConvertTo-Json $entry -Depth 100) -AsHashtable -Depth 100
            }
        }
        else { $variables.OutboxRelay__Enabled = @{ name = 'OutboxRelay__Enabled'; value = 'false' } }
    }
    $template.containers[0].env = @($variables.Values)
    if ($Component -ceq 'api') {
        if ($Context.Contains('cutoverInventory')) {
            $template.containers[0].probes = @(ConvertFrom-Json (ConvertTo-Json -InputObject $Context.cutoverInventory.apps.api.probes -Depth 100) -AsHashtable -Depth 100)
        }
        $readiness = @($template.containers[0].probes | Where-Object type -CEQ 'Readiness')
        if ($readiness.Count -ne 1 -or -not $readiness[0].Contains('httpGet')) {
            throw 'UpgradeExecution: the API lacks its exact reviewed readiness probe.'
        }
        $readiness[0].httpGet.path = if ($Context.plan.Contains('cutover') -and $MaintenancePhase -cne 'Open') {
            '/health/maintenance'
        } else { '/health/bootstrap-attestation' }
        if ($Context.plan.Contains('cutover') -and $MaintenancePhase -cne 'Open') {
            foreach ($probe in $template.containers[0].probes) {
                if (-not $probe.Contains('httpGet') -or $probe.Contains('tcpSocket') -or
                    ($probe.httpGet.Contains('host') -and $probe.httpGet.host) -or
                    $probe.httpGet.port -ne $configuration.ingress.targetPort) {
                    throw 'UpgradeCutover: pre-schema hosting requires reviewed local HTTP probes only.'
                }
                $probe.httpGet.path = '/health/maintenance'
            }
        }
        if ($Context.plan.Contains('cutover') -and $MaintenancePhase -ceq 'PreSchemaClosed') {
            foreach ($name in @('initContainers', 'volumes', 'serviceBinds')) {
                if ($template.Contains($name) -and $null -ne $template[$name] -and @($template[$name]).Count) {
                    throw 'UpgradeCutover: pre-schema hosting cannot include auxiliary containers, volumes or service bindings.'
                }
            }
            foreach ($name in @('command', 'args', 'volumeMounts')) {
                if ($template.containers[0].Contains($name) -and $null -ne $template.containers[0][$name] -and @($template.containers[0][$name]).Count) {
                    throw 'UpgradeCutover: pre-schema hosting requires the exact image entry point without mounts.'
                }
            }
        }
    }
    if ($Component -cin @('api', 'worker')) { $template.scale.minReplicas = 1 }
    $properties = @{ managedEnvironmentId = $Context.foundation.containerAppsEnvironmentId; configuration = $configuration; template = $template }
    if ($raw.properties.Contains('workloadProfileName')) { $properties.workloadProfileName = $raw.properties.workloadProfileName }
    return @{ location = $raw.location; tags = $tags; identity = $identity; properties = $properties }
}

function Invoke-GatewayUpgradeWorkload {
    param($Context, [ValidateSet('api', 'worker', 'adminUi')][string]$Component, [string]$Image,
        $Environment, [switch]$ReadOnly, [switch]$Rollback, [switch]$EnableConsumers, [switch]$OpenApi)
    if ($EnableConsumers -and $Component -cne 'worker') { throw 'UpgradeCutover: only the reviewed worker can enable consumers.' }
    if ($OpenApi -and $Component -cne 'api') { throw 'UpgradeCutover: only the reviewed API can open admissions.' }
    if ($Image -cnotmatch "^$([regex]::Escape($Context.foundation.acrLoginServer))/gateway-(api|worker|admin)@sha256:[0-9a-f]{64}$") {
        throw 'UpgradeExecution: workload image is not an exact approved-registry digest.'
    }
    $repository = switch ($Component) { api { 'gateway-api' } worker { 'gateway-worker' } adminUi { 'gateway-admin' } }
    if (-not $Image.StartsWith("$($Context.foundation.acrLoginServer)/$repository@", [StringComparison]::Ordinal)) {
        throw 'UpgradeExecution: workload component/image mismatch.'
    }
    $expected = if ($Rollback) { $Context.plan.rollbackContract.images[$Component] } else { $Context.plan.request.images[$Component] }
    if ($Image -cne $expected) { throw 'UpgradeArtifactApprovalRequired: the exact workload digest is not approved in this Plan.' }
    $action = "workload-$($Component.ToLowerInvariant())$(if ($Rollback) { '-rollback' })"
    if ($EnableConsumers) { $action += '-enable' }
    if ($OpenApi) { $action += '-open' }
    Assert-GatewayUpgradeExecutionAuthority $Context $action -ReadOnly:$ReadOnly
    $before = Get-GatewayUpgradeWorkloadSnapshot $Context $Component
    $baselines = Initialize-GatewayUpgradeWorkloadBaselines $Context -ReadOnly:($ReadOnly -or $Rollback)
    $baseline = @{ record = $baselines.workloads[$Component] }
    if ($baseline.record.resourceId -cne $before.id) { throw 'UpgradeExecution: workload baseline resource differs.' }
    if ($before.protectedConfigurationFingerprint -cne $baseline.record.protectedConfigurationFingerprint -or
        $before.principalId -cne $baseline.record.principalId -or $before.fqdn -cne $baseline.record.fqdn) {
        throw 'UpgradeExecution: protected workload configuration drifted from the preserved pre-upgrade baseline.'
    }
    if ($Rollback) {
        $currentFingerprint = Get-GatewayUpgradeWorkloadDeploymentFingerprint $before
        $promotion = Read-GatewayUpgradeExecutionRecord $Context "workload-$($Component.ToLowerInvariant())" 'intent'
        $promotionResult = Read-GatewayUpgradeExecutionRecord $Context "workload-$($Component.ToLowerInvariant())" 'result'
        $rollbackIntent = Read-GatewayUpgradeExecutionRecord $Context $action 'intent'
        $permitted = @($baseline.record.deploymentFingerprint)
        $workerStage = if ($EnableConsumers) { Read-GatewayUpgradeExecutionRecord $Context 'workload-worker-rollback' 'intent' } else { $null }
        $enabledPromotion = if ($Component -ceq 'worker') { Read-GatewayUpgradeExecutionRecord $Context 'workload-worker-enable' 'intent' } else { $null }
        $apiOpenPromotion = if ($Component -ceq 'api') { Read-GatewayUpgradeExecutionRecord $Context 'workload-api-open' 'intent' } else { $null }
        $apiStage = if ($OpenApi) { Read-GatewayUpgradeExecutionRecord $Context 'workload-api-rollback' 'intent' } else { $null }
        foreach ($attempt in @($promotion, $rollbackIntent, $workerStage, $enabledPromotion, $apiOpenPromotion, $apiStage)) {
            if ($null -eq $attempt) { continue }
            if ((Get-GatewayUpgradeFingerprint $attempt.record.value.input) -cne $attempt.record.value.inputFingerprint -or
                -not $attempt.record.value.input.Contains('deploymentFingerprint')) {
                throw 'UpgradeOutcomeUnknown: attempted workload lacks its exact desired deployment contract.'
            }
            $permitted += $attempt.record.value.input.deploymentFingerprint
        }
        if ($Component -ceq 'api' -and $Context.plan.Contains('cutover')) {
            $pre = Read-GatewayUpgradeJson (Join-Path $Context.directory 'cutover-pre-schema-api.json')
            if ((Get-GatewayUpgradeFingerprint $pre.record) -cne $pre.fingerprint -or $pre.record.planFingerprint -cne $Context.planFingerprint) {
                throw 'UpgradeCutover: pre-schema rollback boundary binding differs.'
            }
            $permitted += Get-GatewayUpgradeWorkloadDeploymentFingerprint $before $pre.record.body
        }
        if ($currentFingerprint -cnotin $permitted) {
            throw 'UpgradeOutcomeUnknown: workload matches neither the original baseline nor an exact attempted deployment.'
        }
        if ($currentFingerprint -ceq $baseline.record.deploymentFingerprint -and
            $null -ne $promotion -and $null -eq $promotionResult) {
            throw 'UpgradeOutcomeUnknown: promotion intent with unchanged baseline does not prove the attempted operation settled.'
        }
        if ($before.raw.properties.provisioningState -cnotin @('Succeeded', 'Failed', 'Canceled')) {
            throw 'UpgradeOutcomeUnknown: an in-flight workload operation must settle before compatible rollback.'
        }
        if ($currentFingerprint -ceq $baseline.record.deploymentFingerprint -and $Image -ceq $baseline.record.image) {
            $currentEnvironment = @{}
            foreach ($entry in @($before.raw.properties.template.containers[0].env)) { $currentEnvironment[$entry.name] = $entry }
            $exactEnvironment = @($Environment.Keys | Where-Object {
                -not $currentEnvironment.Contains($_) -or $currentEnvironment[$_].Contains('secretRef') -or
                $currentEnvironment[$_].value -cne $Environment[$_]
            }).Count -eq 0
            if ($exactEnvironment) {
                Assert-GatewayUpgradeWorkloadHealthy $Context $before $Component
                $observed = @{ status = 'UntouchedCompatibleBaselineVerified'; resourceId = $before.id
                    image = $before.image; principalId = $before.principalId; fqdn = $before.fqdn
                    deploymentFingerprint = $currentFingerprint }
                $null = Save-GatewayUpgradeNamedEvidence $Context "rollback-untouched-$($Component.ToLowerInvariant()).json" @{
                    planFingerprint = $Context.planFingerprint; originalStateSha256 = $Context.plan.original.stateSha256
                    observed = $observed
                } -ReuseExact
                return $observed
            }
        }
    }
    elseif (-not $EnableConsumers -and -not $OpenApi -and $null -eq (Read-GatewayUpgradeExecutionRecord $Context $action 'intent') -and
        (Get-GatewayUpgradeWorkloadDeploymentFingerprint $before) -cne $baseline.record.deploymentFingerprint) {
        $prePath = Join-Path $Context.directory 'cutover-pre-schema-api.json'
        if ($Component -cne 'api' -or -not (Test-Path -LiteralPath $prePath)) {
            throw 'UpgradeExecution: unattempted workload template drifted from the complete original baseline.'
        }
        $pre = Read-GatewayUpgradeJson $prePath
        if ((Get-GatewayUpgradeFingerprint $pre.record) -cne $pre.fingerprint -or
            $pre.record.planFingerprint -cne $Context.planFingerprint -or
            (Get-GatewayUpgradeWorkloadDeploymentFingerprint $before) -cne
                (Get-GatewayUpgradeWorkloadDeploymentFingerprint $before $pre.record.body)) {
            throw 'UpgradeCutover: the API did not preserve the exact pre-schema template.'
        }
    }
    if ($OpenApi -and $null -eq (Read-GatewayUpgradeExecutionRecord $Context $action 'intent')) {
        $stage = Read-GatewayUpgradeExecutionRecord $Context "workload-api$(if ($Rollback) { '-rollback' })" 'intent'
        $stageResult = Read-GatewayUpgradeExecutionRecord $Context "workload-api$(if ($Rollback) { '-rollback' })" 'result'
        if ($null -eq $stage -or $null -eq $stageResult -or
            (Get-GatewayUpgradeWorkloadDeploymentFingerprint $before) -cne $stage.record.value.input.deploymentFingerprint) {
            throw 'UpgradeCutover: API admission can open only from the exact verified post-schema closed revision.'
        }
    }
    if ($EnableConsumers -and $null -eq (Read-GatewayUpgradeExecutionRecord $Context $action 'intent')) {
        $stageAction = "workload-worker$(if ($Rollback) { '-rollback' })"
        $stage = Read-GatewayUpgradeExecutionRecord $Context $stageAction 'intent'
        $stageResult = Read-GatewayUpgradeExecutionRecord $Context $stageAction 'result'
        if ($null -eq $stage -or $null -eq $stageResult -or
            (Get-GatewayUpgradeWorkloadDeploymentFingerprint $before) -cne $stage.record.value.input.deploymentFingerprint) {
            throw 'UpgradeCutover: consumers can only be enabled from the exact verified inert worker.'
        }
        Assert-GatewayUpgradeCutoverHeld $Context
        $revisionId = "$($before.id)/revisions/$($stageResult.record.value.revision)"
        $null = Invoke-GatewayUpgradeOnce $Context "cutover-inert-worker-deactivate$(if ($Rollback) { '-rollback' })" @{ revisionId = $revisionId } -Discover {
            $revision = Invoke-GatewayUpgradeArm $Context GET $revisionId '2025-01-01'
            $replicas = Invoke-GatewayUpgradeArm $Context GET "$revisionId/replicas" '2025-01-01'
            if ($revision.properties.active -eq $false -and $revision.properties.replicas -eq 0 -and
                $replicas.Contains('value') -and $replicas.value -is [array] -and $replicas.value.Count -eq 0 -and
                (-not $replicas.Contains('nextLink') -or -not $replicas.nextLink)) { return @{ revisionId = $revisionId; inactive = $true } }
            return $null
        } -Mutate { Invoke-GatewayUpgradeArm $Context POST "$revisionId/deactivate" '2025-01-01' | Out-Null }
    }
    $phase = if ($OpenApi) { 'Open' } else { 'PostSchemaClosed' }
    $body = New-GatewayUpgradeWorkloadBody $Context $before $Component $Image $Environment -Rollback:$Rollback -EnableConsumers:$EnableConsumers -MaintenancePhase $phase
    $expectedEnv = Get-GatewayUpgradeFingerprint @($body.properties.template.containers[0].env | Sort-Object name)
    $deploymentFingerprint = Get-GatewayUpgradeWorkloadDeploymentFingerprint $before $body
    return Invoke-GatewayUpgradeOnce $Context $action @{
        resourceId = $before.id; image = $Image; environmentFingerprint = $expectedEnv
        originalPrincipalId = $before.principalId; originalFqdn = $before.fqdn
        protectedConfigurationFingerprint = $baseline.record.protectedConfigurationFingerprint
        deploymentFingerprint = $deploymentFingerprint
        rollback = [bool]$Rollback
    } -ReadOnly:$ReadOnly -MaximumReadAttempts 180 -Discover {
        $current = Get-GatewayUpgradeWorkloadSnapshot $Context $Component
        if ($current.image -cne $Image -or
            -not $current.raw.tags.Contains('gatewayUpgradePlanFingerprint') -or
            $current.raw.tags.gatewayUpgradePlanFingerprint -cne $Context.planFingerprint -or
            $current.raw.tags.gatewayUpgradeDisposition -cne $body.tags.gatewayUpgradeDisposition -or
            (($EnableConsumers -or ($Component -ceq 'api' -and $Context.plan.Contains('cutover'))) -and
                $current.raw.properties.template.revisionSuffix -cne $body.properties.template.revisionSuffix)) { return $null }
        if ((Get-GatewayUpgradeFingerprint @($current.raw.properties.template.containers[0].env | Sort-Object name)) -cne $expectedEnv -or
            (Get-GatewayUpgradeWorkloadDeploymentFingerprint $current) -cne $deploymentFingerprint -or
            $current.principalId -cne $before.principalId -or $current.fqdn -cne $before.fqdn -or
            $current.protectedConfigurationFingerprint -cne $before.protectedConfigurationFingerprint) {
            $environmentMatches = (Get-GatewayUpgradeFingerprint @($current.raw.properties.template.containers[0].env | Sort-Object name)) -ceq $expectedEnv
            $deploymentMatches = (Get-GatewayUpgradeWorkloadDeploymentFingerprint $current) -ceq $deploymentFingerprint
            $protectedMatches = $current.protectedConfigurationFingerprint -ceq $before.protectedConfigurationFingerprint
            throw "UpgradeExecution: promoted workload configuration, identity or endpoint differs (environment=$environmentMatches; deployment=$deploymentMatches; protected=$protectedMatches)."
        }
        if ($current.raw.properties.provisioningState -cne 'Succeeded') { return $null }
        $revisions = @(Invoke-AzJson -Arguments @('containerapp', 'revision', 'list', '--resource-group',
            $Context.config.resourceGroupName, '--name', $current.name,
            '--query', '[?properties.active==`true`].{name:name,health:properties.healthState,running:properties.runningState,replicas:properties.replicas}'))
        if ($revisions.Count -ne 1 -or $revisions[0].name -cne $current.revision -or
            $revisions[0].health -cne 'Healthy' -or $revisions[0].running -cne 'Running' -or [int]$revisions[0].replicas -lt 1) { return $null }
        if ($Component -ceq 'api' -and -not $Context.Contains('cutoverInventory')) {
            $null = Get-GatewayCurrentDatabaseAttestationEvidence -ApiFqdn $current.fqdn
        }
        elseif ($Component -ceq 'adminUi') { $null = Wait-HttpsHealth -Url "https://$($current.fqdn)/health" }
        return @{
            resourceId = $current.id; image = $Image; principalId = $current.principalId
            fqdn = $current.fqdn; revision = $current.revision; environmentFingerprint = $expectedEnv
            protectedConfigurationFingerprint = $baseline.record.protectedConfigurationFingerprint
        }
    } -Mutate {
        if ($Context.plan.Contains('cutover')) { Assert-GatewayUpgradeCutoverHeld $Context }
        Invoke-GatewayUpgradeArm $Context PUT $before.id $before.apiVersion $body | Out-Null
        if ($Component -ceq 'api' -and $Context.plan.Contains('cutover')) {
            $desiredId = "$($before.id)/revisions/$($before.name)--$($body.properties.template.revisionSuffix)"
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Context.plan.cutover.TimeoutSeconds)
            while ($true) {
                $desired = Invoke-GatewayUpgradeArm $Context GET $desiredId '2025-01-01' -AllowNotFound
                if ($null -eq $desired) {
                    if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'UpgradeCutoverUnknown: API revision creation timed out.' }
                    Start-Sleep -Seconds 5
                    continue
                }
                if ($desired.properties.active -eq $true -and $desired.properties.healthState -ceq 'Healthy' -and
                    $desired.properties.runningState -ceq 'Running' -and $desired.properties.replicas -gt 0) {
                    Assert-GatewayUpgradeMaintenanceApiRevision $Context $desired $phase
                    break
                }
                if ([DateTimeOffset]::UtcNow -ge $deadline -or $desired.properties.runningState -cin @('Failed', 'Stopped', 'Degraded')) {
                    throw 'UpgradeCutoverUnknown: the next API phase did not become independently ready.'
                }
                Start-Sleep -Seconds 5
            }
            foreach ($revision in (Get-GatewayUpgradeCutoverRevisions $Context $before.id)) {
                if ($revision.properties.active -and $revision.id -cne $desiredId) {
                    $null = Invoke-GatewayUpgradeArm $Context POST "$($revision.id)/deactivate" '2025-01-01'
                }
            }
        }
    }
}

function Invoke-GatewayUpgradePreSchemaApi {
    param($Context)
    Assert-GatewayUpgradeExecutionAuthority $Context 'cutover-pre-schema-api'
    $snapshot = Get-GatewayUpgradeWorkloadSnapshot $Context api
    $baseline = (Initialize-GatewayUpgradeWorkloadBaselines $Context -ReadOnly).workloads.api
    if ($snapshot.protectedConfigurationFingerprint -cne $baseline.protectedConfigurationFingerprint) {
        throw 'UpgradeCutover: pre-schema closure cannot overwrite protected workload drift.'
    }
    $path = Join-Path $Context.directory 'cutover-pre-schema-api.json'
    if (Test-Path -LiteralPath $path) {
        $saved = Read-GatewayUpgradeJson $path
        if ((Get-GatewayUpgradeFingerprint $saved.record) -cne $saved.fingerprint -or
            $saved.record.planFingerprint -cne $Context.planFingerprint -or
            $saved.record.originalStateSha256 -cne $Context.plan.original.stateSha256) {
            throw 'UpgradeCutover: the immutable pre-schema API template binding changed.'
        }
        $body = $saved.record.body
    }
    else {
        if ((Get-GatewayUpgradeWorkloadDeploymentFingerprint $snapshot) -cne $baseline.deploymentFingerprint) {
            throw 'UpgradeCutoverUnsafePriorWork: cannot introduce the pre-schema API after template changes.'
        }
        $body = New-GatewayUpgradeWorkloadBody $Context $snapshot api $Context.plan.request.images.api @{} -MaintenancePhase PreSchemaClosed
        $null = Save-GatewayUpgradeNamedEvidence $Context 'cutover-pre-schema-api.json' @{
            planFingerprint = $Context.planFingerprint; originalStateSha256 = $Context.plan.original.stateSha256
            body = $body
        }
    }
    $expectedBody = New-GatewayUpgradeWorkloadBody $Context $snapshot api $Context.plan.request.images.api @{} -MaintenancePhase PreSchemaClosed
    $actualPins = @{}
    foreach ($entry in @($body.properties.template.containers[0].env)) {
        if ($actualPins.Contains($entry.name)) { throw 'UpgradeCutover: duplicate pre-schema environment names.' }
        $actualPins[$entry.name] = $entry
    }
    foreach ($entry in (Get-GatewayUpgradeMaintenanceEnvironment $Context PreSchemaClosed).GetEnumerator()) {
        if (-not $actualPins.Contains($entry.Key) -or $actualPins[$entry.Key].Contains('secretRef') -or
            $actualPins[$entry.Key].value -cne $entry.Value) {
            throw 'UpgradeCutover: persisted pre-schema template pins differ from the approved Plan.'
        }
    }
    $contracts = @($body, $expectedBody) | ForEach-Object {
        $copy = ConvertFrom-Json (ConvertTo-Json $_ -Depth 100) -AsHashtable -Depth 100
        $copy.properties.template.containers[0].env = @($copy.properties.template.containers[0].env |
            Where-Object { $_.name -cnotmatch (Get-GatewayUpgradeMutableEnvironmentPattern api) } | Sort-Object name)
        $copy
    }
    if ((Get-GatewayUpgradeFingerprint $contracts[0]) -cne (Get-GatewayUpgradeFingerprint $contracts[1])) {
        throw 'UpgradeCutover: persisted pre-schema template exceeds the fixed source-bound changes.'
    }
    $revisionId = "$($snapshot.id)/revisions/$($snapshot.name)--$($body.properties.template.revisionSuffix)"
    $revision = Invoke-GatewayUpgradeArm $Context GET $revisionId '2025-01-01' -AllowNotFound
    if ($null -eq $revision) {
        $null = Invoke-GatewayUpgradeArm $Context PUT $snapshot.id $snapshot.apiVersion $body
    }
    else {
        $actualTemplate = ConvertFrom-Json (ConvertTo-Json $revision.properties.template -Depth 100) -AsHashtable -Depth 100
        $expectedTemplate = ConvertFrom-Json (ConvertTo-Json $body.properties.template -Depth 100) -AsHashtable -Depth 100
        $actualTemplate.Remove('revisionSuffix')
        $expectedTemplate.Remove('revisionSuffix')
        if ((Get-GatewayUpgradeFingerprint $actualTemplate) -cne (Get-GatewayUpgradeFingerprint $expectedTemplate)) {
            throw 'UpgradeCutover: the existing pre-schema revision differs from its immutable template.'
        }
        if (-not $revision.properties.active) {
            $null = Invoke-GatewayUpgradeArm $Context POST "$revisionId/activate" '2025-01-01'
        }
    }
    while ($true) {
        $revision = Invoke-GatewayUpgradeArm $Context GET $revisionId '2025-01-01' -AllowNotFound
        if ($null -eq $revision) {
            if ([DateTimeOffset]::UtcNow -ge $Context.cutoverDeadline) { throw 'UpgradeCutoverUnknown: pre-schema API revision creation timed out.' }
            Start-Sleep -Seconds 5
            continue
        }
        if ($revision.properties.active -eq $true -and $revision.properties.healthState -ceq 'Healthy' -and
            $revision.properties.runningState -ceq 'Running' -and $revision.properties.replicas -gt 0) {
            Assert-GatewayUpgradeMaintenanceApiRevision $Context $revision PreSchemaClosed
            return $revisionId
        }
        if ($revision.properties.runningState -cin @('Failed', 'Stopped', 'Degraded') -or
            [DateTimeOffset]::UtcNow -ge $Context.cutoverDeadline) {
            throw 'UpgradeCutoverUnknown: the source-bound pre-schema API did not become ready.'
        }
        Start-Sleep -Seconds 5
    }
}

function Assert-GatewayUpgradeMaintenanceApiRevision {
    param($Context, $Revision, [ValidateSet('PreSchemaClosed', 'PostSchemaClosed', 'Open')][string]$Phase)
    $expected = Get-GatewayUpgradeMaintenanceEnvironment $Context $Phase
    $containers = @($Revision.properties.template.containers)
    $image = if ($Phase -ceq 'PreSchemaClosed') { $Context.plan.request.images.api } else {
        @($Context.plan.request.images.api) + @(if ($Context.plan.Contains('rollbackContract')) { $Context.plan.rollbackContract.images.api })
    }
    if ($containers.Count -ne 1 -or $containers[0].image -cnotin @($image)) {
        throw 'UpgradeCutover: the maintenance revision image is not exactly approved.'
    }
    $env = @{}
    foreach ($entry in @($containers[0].env)) {
        if ($env.Contains($entry.name)) { throw 'UpgradeCutover: duplicate maintenance environment names.' }
        $env[$entry.name] = $entry
    }
    foreach ($name in $expected.Keys) {
        if (-not $env.Contains($name) -or $env[$name].Contains('secretRef') -or $env[$name].value -cne $expected[$name]) {
            throw 'UpgradeCutover: maintenance phase or canonical Plan/source/cutover pin differs.'
        }
    }
    if (@($env.Keys | Where-Object { $_ -clike 'MaintenanceCutover__*' -and -not $expected.Contains($_) }).Count) {
        throw 'UpgradeCutover: unexpected maintenance environment controls.'
    }
    $probe = @($containers[0].probes | Where-Object type -CEQ 'Readiness')
    $path = if ($Phase -ceq 'Open') { '/health/bootstrap-attestation' } else { '/health/maintenance' }
    $targetPort = $Context.cutoverInventory.apps.api.configuration.ingress.targetPort
    if ($probe.Count -ne 1 -or -not $probe[0].Contains('httpGet') -or $probe[0].Contains('tcpSocket') -or
        $probe[0].httpGet.path -cne $path -or $probe[0].httpGet.port -ne $targetPort -or
        ($probe[0].httpGet.Contains('host') -and $probe[0].httpGet.host) -or
        $Revision.properties.active -isnot [bool] -or $Revision.properties.active -ne $true -or
        $Revision.properties.healthState -cne 'Healthy' -or $Revision.properties.runningState -cne 'Running' -or
        ($Revision.properties.replicas -isnot [int] -and $Revision.properties.replicas -isnot [long]) -or $Revision.properties.replicas -lt 1) {
        throw 'UpgradeCutover: the fixed maintenance probe is not independently healthy.'
    }
    if ($Phase -cne 'Open') {
        $allProbes = @($containers[0].probes)
        if ($allProbes.Count -ne 3 -or @($allProbes.type | Sort-Object -Unique).Count -ne 3) {
            throw 'UpgradeCutover: all three closed-host probes are required.'
        }
        foreach ($item in $allProbes) {
            if ($item.type -cnotin @('Startup', 'Liveness', 'Readiness') -or -not $item.Contains('httpGet') -or
                $item.Contains('tcpSocket') -or $item.httpGet.path -cne '/health/maintenance' -or
                $item.httpGet.port -ne $targetPort -or ($item.httpGet.Contains('host') -and $item.httpGet.host)) {
                throw 'UpgradeCutover: all closed-host probes must target the local maintenance endpoint.'
            }
        }
    }
    $replicas = Invoke-GatewayUpgradeArm $Context GET "$($Revision.id)/replicas" '2025-01-01'
    if (-not $replicas.Contains('value') -or $replicas.value -isnot [array] -or
        $replicas.value.Count -ne $Revision.properties.replicas -or
        ($replicas.Contains('nextLink') -and $replicas.nextLink)) {
        throw 'UpgradeCutoverUnknown: maintenance replica inventory is incomplete.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($replica in $replicas.value) {
        if ($replica.id -isnot [string] -or $replica.name -isnot [string] -or
            $replica.id -cne "$($Revision.id)/replicas/$($replica.name)" -or -not $seen.Add($replica.id) -or
            $replica.properties.runningState -cne 'Running' -or @($replica.properties.containers).Count -ne 1 -or
            $replica.properties.containers[0].name -cne $containers[0].name -or
            $replica.properties.containers[0].ready -isnot [bool] -or $replica.properties.containers[0].ready -ne $true -or
            $replica.properties.containers[0].started -isnot [bool] -or $replica.properties.containers[0].started -ne $true) {
            throw 'UpgradeCutoverUnknown: maintenance replica readiness is not proven.'
        }
    }
}

function Get-GatewayUpgradeWorkloadDeploymentFingerprint {
    param($Snapshot, $Body = $null)
    $properties = if ($null -eq $Body) { $Snapshot.raw.properties } else { $Body.properties }
    $tags = if ($null -eq $Body) { $Snapshot.raw.tags } else { $Body.tags }
    $template = ConvertFrom-Json (ConvertTo-Json $properties.template -Depth 100) -AsHashtable -Depth 100
    $configuration = ConvertFrom-Json (ConvertTo-Json $properties.configuration -Depth 100) -AsHashtable -Depth 100
    if ($Snapshot.Contains('normalizedConfiguration')) { $configuration = $Snapshot.normalizedConfiguration }
    foreach ($container in @($template.containers)) {
        $container.env = @($container.env | Sort-Object name)
    }
    foreach ($secret in @($configuration.secrets)) {
        if ($null -ne $secret -and $secret.Contains('value') -and [string]::IsNullOrEmpty([string]$secret.value)) { $secret.Remove('value') }
    }
    return Get-GatewayUpgradeFingerprint @{
        template = $template; configuration = $configuration; tags = $tags; identity = $Snapshot.raw.identity
        protectedConfigurationFingerprint = $Snapshot.protectedConfigurationFingerprint
    }
}

function Initialize-GatewayUpgradeWorkloadBaselines {
    param($Context, [switch]$ReadOnly)
    $path = Join-Path $Context.directory 'workload-baselines.json'
    if (Test-Path -LiteralPath $path) {
        $saved = Read-GatewayUpgradeJson $path
        if ((Get-GatewayUpgradeFingerprint $saved.record) -cne $saved.fingerprint -or
            $saved.record.schemaVersion -ne 1 -or $saved.record.planFingerprint -cne $Context.planFingerprint -or
            $saved.record.originalStateSha256 -cne $Context.plan.original.stateSha256 -or
            $saved.record.workloads.Count -ne 3 -or
            @($saved.record.workloads.Keys | Where-Object { $_ -cnotin @('worker', 'api', 'adminUi') }).Count -ne 0) {
            throw 'UpgradeExecution: complete workload baselines are not bound to the original deployment.'
        }
        $keys = @('resourceId', 'image', 'principalId', 'fqdn', 'protectedConfigurationFingerprint', 'deploymentFingerprint')
        foreach ($entry in $saved.record.workloads.Values) {
            if ($entry.Count -ne $keys.Count -or @($entry.Keys | Where-Object { $_ -cnotin $keys }).Count -ne 0 -or
                $entry.protectedConfigurationFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
                $entry.deploymentFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
                throw 'UpgradeExecution: workload baseline shape is incomplete or unsupported.'
            }
        }
        return $saved.record
    }
    if ($ReadOnly) { throw 'UpgradeExecution: all pre-upgrade workload baselines are required.' }
    if (Test-Path -LiteralPath (Join-Path $Context.directory 'cutover-pre-schema-api.json')) {
        throw 'UpgradeOutcomeUnknown: cannot recapture missing baselines after pre-schema staging.'
    }
    foreach ($component in @('worker', 'api', 'adminUi')) {
        if ($null -ne (Read-GatewayUpgradeExecutionRecord $Context "workload-$($component.ToLowerInvariant())" 'intent')) {
            throw 'UpgradeOutcomeUnknown: cannot recapture missing baselines after a promotion attempt.'
        }
    }
    $workloads = [ordered]@{}
    foreach ($component in @('worker', 'api', 'adminUi')) {
        $snapshot = Get-GatewayUpgradeWorkloadSnapshot $Context $component
        $workloads[$component] = @{
            resourceId = $snapshot.id; image = $snapshot.image; principalId = $snapshot.principalId; fqdn = $snapshot.fqdn
            protectedConfigurationFingerprint = $snapshot.protectedConfigurationFingerprint
            deploymentFingerprint = Get-GatewayUpgradeWorkloadDeploymentFingerprint $snapshot
        }
    }
    $saved = Save-GatewayUpgradeNamedEvidence $Context 'workload-baselines.json' @{
        schemaVersion = 1; planFingerprint = $Context.planFingerprint
        originalStateSha256 = $Context.plan.original.stateSha256; workloads = $workloads
    }
    return $saved.record
}

function Assert-GatewayUpgradeWorkloadHealthy {
    param($Context, $Snapshot, [string]$Component)
    if ($Snapshot.raw.properties.provisioningState -cne 'Succeeded') {
        throw 'UpgradeOutcomeUnknown: untouched workload has not reached a healthy terminal state.'
    }
    $revisions = @(Invoke-AzJson -Arguments @('containerapp', 'revision', 'list', '--resource-group',
        $Context.config.resourceGroupName, '--name', $Snapshot.name,
        '--query', '[?properties.active==`true`].{name:name,health:properties.healthState,running:properties.runningState,replicas:properties.replicas}'))
    if ($revisions.Count -ne 1 -or $revisions[0].name -cne $Snapshot.revision -or
        $revisions[0].health -cne 'Healthy' -or $revisions[0].running -cne 'Running' -or [int]$revisions[0].replicas -lt 1) {
        throw 'UpgradeOutcomeUnknown: untouched workload live revision is not exactly healthy.'
    }
    if ($Component -ceq 'api') { $null = Get-GatewayCurrentDatabaseAttestationEvidence -ApiFqdn $Snapshot.fqdn }
    elseif ($Component -ceq 'adminUi') { $null = Wait-HttpsHealth -Url "https://$($Snapshot.fqdn)/health" }
}

function Invoke-GatewayUpgradeRollbackWorkloads {
    param($Context, $DatabaseReceipt, $Environments)
    Assert-GatewayUpgradeRollbackContract $Context $DatabaseReceipt
    $null = Initialize-GatewayUpgradeWorkloadBaselines $Context -ReadOnly
    $results = [ordered]@{}
    $failed = [Collections.Generic.List[string]]::new()
    foreach ($component in @('adminUi', 'api', 'worker')) {
        try {
            $results[$component] = Invoke-GatewayUpgradeWorkload $Context $component `
                $Context.plan.rollbackContract.images[$component] $Environments[$component] -Rollback
        }
        catch {
            # Continue independently safe components, but never convert incomplete rollback to success.
            $failed.Add($component)
            $results[$component] = @{ status = 'ReconciliationRequired'; component = $component }
        }
    }
    if ($failed.Count -gt 0) {
        $null = Save-GatewayUpgradeNamedEvidence $Context "rollback-incomplete-$([guid]::NewGuid().ToString('N')).json" @{
            planFingerprint = $Context.planFingerprint; status = 'RollbackIncomplete'; workloads = $results
        }
        throw "UpgradeRollbackIncomplete: exact reconciliation is still required for $($failed -join ', '). No successful rollback is attested."
    }
    return $results
}

function Assert-GatewayUpgradeRollbackContract {
    param($Context, $DatabaseReceipt)
    if (-not $Context.plan.Contains('rollbackContract')) { throw 'UpgradeRollbackNotApproved: no compatible rollback contract is bound to this Plan.' }
    $contract = $Context.plan.rollbackContract
    if ($contract.strategy -cne 'RetainExpandedSchema' -or $contract.queueName -cne 'gateway-provisioning-v3' -or
        $contract.capabilityPreparationContractVersion -ne 1 -or $contract.databaseUpgradeContractVersion -ne 1 -or
        $contract.modelFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $contract.reviewEvidenceFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'UpgradeRollbackNotApproved: compatible schema, queue and preparation support were not reviewed exactly.'
    }
    if (-not $contract.Contains('reviewEvidenceReference') -or
        (Get-GatewayUpgradeFileHash $contract.reviewEvidenceReference) -cne $contract.reviewEvidenceFingerprint) {
        throw 'UpgradeRollbackNotApproved: the independently reviewed compatibility evidence is missing or changed.'
    }
    $review = Read-GatewayUpgradeJson $contract.reviewEvidenceReference
    if ($review.schemaVersion -ne 1 -or $review.decision -cne 'BackwardCompatible' -or
        $review.reviewerModel -cne 'gpt-6-astra' -or $review.modelFingerprint -cne $contract.modelFingerprint -or
        (Get-GatewayUpgradeFingerprint $review.images) -cne (Get-GatewayUpgradeFingerprint $contract.images) -or
        $review.testEvidence -isnot [array] -or $review.testEvidence.Count -eq 0) {
        throw 'UpgradeRollbackNotApproved: exact image/schema compatibility tests and independent review are required.'
    }
    foreach ($test in $review.testEvidence) {
        if ((Get-GatewayUpgradeFileHash $test.path) -cne $test.sha256) { throw 'UpgradeRollbackNotApproved: compatibility test evidence changed.' }
    }
    $receipt = ConvertFrom-Json $DatabaseReceipt.receiptJson -AsHashtable -Depth 20
    if ($receipt.TargetModelFingerprint -cne $contract.modelFingerprint) {
        throw 'UpgradeRollbackNotApproved: rollback code is not approved for the current expanded database model.'
    }
    foreach ($component in @('api', 'worker', 'adminUi')) {
        if ([string]$contract.images[$component] -cnotmatch '@sha256:[0-9a-f]{64}$') {
            throw 'UpgradeRollbackNotApproved: every rollback component must use a reviewed immutable digest.'
        }
        if ($Context.plan.Contains('cutover')) {
            $originalImage = switch ($component) {
                api { $Context.plan.scope.existing.apiImage }
                worker { $Context.plan.scope.existing.workerImage }
                adminUi { $Context.plan.scope.existing.adminImage }
            }
            if ($contract.images[$component] -ceq $originalImage) {
                throw 'UpgradeRollbackNotApproved: reactivation of original binaries is forbidden.'
            }
        }
    }
}

function Assert-GatewayUpgradeJointReadback {
    param($Context, $DatabaseReceipt, $Preparation, $Environments, [switch]$Rollback, [switch]$ConsumersEnabled, [switch]$RequireHeld, [switch]$ApiOpen)
    if ($RequireHeld) { Assert-GatewayUpgradeCutoverHeld $Context }
    $savedDatabase = Read-GatewayUpgradeExecutionRecord $Context 'database-execution' 'result'
    if ($null -eq $savedDatabase) { throw 'UpgradeCutover: no independently verified SQL completion exists.' }
    $observedDatabase = Test-GatewayUpgradeDatabaseReceipt $Context $savedDatabase.record.value.receiptJson `
        $savedDatabase.record.value.jobName $savedDatabase.record.value.executionName
    if ((Get-GatewayUpgradeFingerprint $observedDatabase) -cne (Get-GatewayUpgradeFingerprint $DatabaseReceipt)) {
        throw 'UpgradeCutover: schema/receipt changed before reopening.'
    }
    if ($Rollback) { Assert-GatewayUpgradeRollbackContract $Context $DatabaseReceipt }
    $observations = @{}
    foreach ($component in @('api', 'worker', 'adminUi')) {
        $snapshot = Get-GatewayUpgradeWorkloadSnapshot $Context $component
        $action = "workload-$($component.ToLowerInvariant())$(if ($Rollback) { '-rollback' })"
        if ($component -ceq 'worker' -and $ConsumersEnabled) { $action += '-enable' }
        if ($component -ceq 'api' -and $ApiOpen) { $action += '-open' }
        $intent = Read-GatewayUpgradeExecutionRecord $Context $action 'intent'
        $result = Read-GatewayUpgradeExecutionRecord $Context $action 'result'
        $image = if ($Rollback) { $Context.plan.rollbackContract.images[$component] } else { $Context.plan.request.images[$component] }
        if ($null -eq $intent -or $null -eq $result -or $snapshot.image -cne $image -or
            $snapshot.raw.properties.provisioningState -cne 'Succeeded' -or
            (Get-GatewayUpgradeWorkloadDeploymentFingerprint $snapshot) -cne $intent.record.value.input.deploymentFingerprint) {
            throw 'UpgradeCutover: joint promotion/configuration readback is incomplete.'
        }
        $env = @{}
        foreach ($entry in $snapshot.raw.properties.template.containers[0].env) { $env[$entry.name] = $entry }
        $expectedEnvironment = @{}
        foreach ($entry in $Environments[$component].GetEnumerator()) { $expectedEnvironment[$entry.Key] = $entry.Value }
        if ($component -ceq 'api') {
            foreach ($name in @($expectedEnvironment.Keys | Where-Object { $_ -clike 'MaintenanceCutover__*' })) {
                $expectedEnvironment.Remove($name)
            }
            foreach ($entry in (Get-GatewayUpgradeMaintenanceEnvironment $Context $(if ($ApiOpen) { 'Open' } else { 'PostSchemaClosed' })).GetEnumerator()) {
                $expectedEnvironment[$entry.Key] = $entry.Value
            }
        }
        if ($component -ceq 'worker') {
            $expectedEnvironment.Remove('OutboxRelay__Enabled')
            $outbox = @($snapshot.raw.properties.template.containers[0].env | Where-Object name -EQ 'OutboxRelay__Enabled')
            $expectedOutbox = @(if ($ConsumersEnabled) { $Context.cutoverInventory.apps.worker.outboxEnvironment }
                else { @{ name = 'OutboxRelay__Enabled'; value = 'false' } })
            if ((Get-GatewayUpgradeFingerprint $outbox) -cne (Get-GatewayUpgradeFingerprint $expectedOutbox)) {
                throw 'UpgradeCutover: the operational worker outbox hold or original configuration differs.'
            }
        }
        foreach ($name in $expectedEnvironment.Keys) {
            if (-not $env.Contains($name) -or $env[$name].Contains('secretRef') -or
                $env[$name].value -cne $expectedEnvironment[$name]) {
                throw 'UpgradeCutover: exact schema, capabilities or consumer configuration is missing.'
            }
        }
        if ($component -ceq 'api') {
            if ($env.DatabaseAttestation__ExpectedSchemaFingerprint.value -cne $DatabaseReceipt.schemaFingerprint -or
                ($Context.plan.request.schemaVersion -ne 2 -and $env.BootstrapCapabilities__Preparation__ReceiptFingerprint.value -cne $Preparation.receiptFingerprint)) {
                throw 'UpgradeCutover: API schema and capabilities are not jointly bound.'
            }
            if ($Context.plan.request.schemaVersion -eq 2) {
                Assert-GatewayUpgradeSourceOnlyWorkloadPreservation $Context $component $snapshot
            }
            $probe = @($snapshot.raw.properties.template.containers[0].probes | Where-Object type -CEQ 'Readiness')
            if ($probe.Count -ne 1 -or -not $probe[0].Contains('httpGet') -or $probe[0].Contains('tcpSocket') -or
                $probe[0].httpGet.path -cne $(if ($ApiOpen) { '/health/bootstrap-attestation' } else { '/health/maintenance' }) -or
                $probe[0].httpGet.port -ne $snapshot.raw.properties.configuration.ingress.targetPort -or
                ($probe[0].httpGet.Contains('host') -and $probe[0].httpGet.host)) {
                throw 'UpgradeCutover: platform readiness must probe the local schema-attesting API endpoint.'
            }
            if ($component -ceq 'worker' -and $Context.plan.request.schemaVersion -eq 2) {
                Assert-GatewayUpgradeSourceOnlyWorkloadPreservation $Context $component $snapshot
            }
        }
        $revisions = Get-GatewayUpgradeCutoverRevisions $Context $snapshot.id
        $active = @($revisions | Where-Object { $_.properties.active })
        if ($active.Count -ne 1 -or $active[0].name -cne $result.record.value.revision -or
            $active[0].properties.healthState -cne 'Healthy' -or $active[0].properties.runningState -cne 'Running' -or
            $active[0].properties.replicas -lt 1 -or
            (Get-GatewayUpgradeFingerprint $active[0].properties.template.containers) -cne
                (Get-GatewayUpgradeFingerprint $snapshot.raw.properties.template.containers)) {
            throw 'UpgradeCutover: active revision/image/readiness is not exactly verified.'
        }
        foreach ($revision in $revisions) {
            $replicas = Invoke-GatewayUpgradeArm $Context GET "$($revision.id)/replicas" '2025-01-01'
            if (-not $replicas.Contains('value') -or $replicas.value -isnot [array] -or
                ($replicas.Contains('nextLink') -and $replicas.nextLink)) {
                throw 'UpgradeCutoverUnknown: replica readback is incomplete.'
            }
            if (-not $revision.properties.active) {
                if ($revision.properties.replicas -ne 0 -or $replicas.value.Count -ne 0) {
                    throw 'UpgradeCutoverNotDrained: an excluded writer remains.'
                }
                continue
            }
            if ($replicas.value.Count -lt 1 -or $replicas.value.Count -ne $revision.properties.replicas) {
                throw 'UpgradeCutoverUnknown: ready replica cardinality differs.'
            }
            $replicaIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($replica in $replicas.value) {
                if ($replica.id -isnot [string] -or $replica.name -isnot [string] -or
                    $replica.id -cne "$($revision.id)/replicas/$($replica.name)" -or -not $replicaIds.Add($replica.id) -or
                    $replica.properties.runningState -cne 'Running' -or @($replica.properties.containers).Count -ne 1 -or
                    $replica.properties.containers[0].ready -isnot [bool] -or
                    $replica.properties.containers[0].started -isnot [bool] -or
                    $replica.properties.containers[0].ready -ne $true -or
                    $replica.properties.containers[0].started -ne $true -or
                    $replica.properties.containers[0].name -cne $snapshot.raw.properties.template.containers[0].name) {
                    throw 'UpgradeCutover: platform replica readiness is not proven.'
                }
            }
        }
        $observations[$component] = @{ image = $image; revision = $active[0].name; deploymentFingerprint = $intent.record.value.input.deploymentFingerprint }
    }
    if ($Context.plan.request.schemaVersion -eq 2) {
        return @{ workloads = $observations; databaseReceiptFingerprint = $DatabaseReceipt.receiptFingerprint
            preservedCapabilityFactsFingerprint = $Preparation.factsFingerprint }
    }
    return @{ workloads = $observations; databaseReceiptFingerprint = $DatabaseReceipt.receiptFingerprint; preparationFingerprint = $Preparation.receiptFingerprint }
}

function Open-GatewayUpgradeCutover {
    param($Context, $DatabaseReceipt, $Preparation, $Environments, [switch]$Rollback, [switch]$ReadOnly)
    $action = "cutover-open$(if ($Rollback) { '-rollback' })"
    $intent = Read-GatewayUpgradeExecutionRecord $Context $action 'intent'
    $result = Read-GatewayUpgradeExecutionRecord $Context $action 'result'
    if ($null -ne $intent -and $null -eq $result) {
        throw 'UpgradeCutoverUnknown: a prior reopen outcome requires reclosure and manual reconciliation, never replay.'
    }
    if ($null -ne $result -or $ReadOnly) {
        if ($null -eq $result) { throw 'UpgradeCutover: no completed reopening is available for read-only verification.' }
        $joint = Assert-GatewayUpgradeJointReadback $Context $DatabaseReceipt $Preparation $Environments -Rollback:$Rollback -ConsumersEnabled -ApiOpen
        Assert-GatewayUpgradeCutoverOpenControls $Context
        return $joint
    }
    $joint = Assert-GatewayUpgradeJointReadback $Context $DatabaseReceipt $Preparation $Environments -Rollback:$Rollback -ConsumersEnabled -RequireHeld
    Assert-GatewayUpgradeExecutionAuthority $Context $action
    $null = Write-GatewayUpgradeExecutionRecord $Context $action 'intent' @{
        inputFingerprint = Get-GatewayUpgradeFingerprint $joint; input = $joint
    }
    try {
        $apiImage = if ($Rollback) { $Context.plan.rollbackContract.images.api } else { $Context.plan.request.images.api }
        $null = Invoke-GatewayUpgradeWorkload $Context api $apiImage $Environments.api -OpenApi -Rollback:$Rollback
        $null = Assert-GatewayUpgradeJointReadback $Context $DatabaseReceipt $Preparation $Environments -Rollback:$Rollback -ConsumersEnabled -ApiOpen
        # Queues stay intact. Receives resume only for the jointly verified new contracts.
        foreach ($id in @($Context.plan.cutover.ProvisioningQueueResourceId, $Context.plan.cutover.ProtectionQueueResourceId)) {
            Assert-GatewayUpgradeExecutionAuthority $Context $action
            $queue = Invoke-GatewayUpgradeArm $Context GET $id '2024-01-01'
            $properties = & (Get-Module GatewayUpgradeCutover) { param($q) Get-GatewayUpgradeCutoverQueueProperties $q } $queue
            if ($properties.status -cne 'ReceiveDisabled') { throw 'UpgradeCutoverUnknown: receive hold changed before reopening.' }
            $properties.status = 'Active'
            $null = Invoke-GatewayUpgradeArm $Context PUT $id '2024-01-01' @{ properties = $properties }
            $observed = Invoke-GatewayUpgradeArm $Context GET $id '2024-01-01'
            if ($observed.properties.status -cne 'Active') { throw 'UpgradeCutoverUnknown: queue reopening outcome is unknown.' }
        }
        $null = Assert-GatewayUpgradeJointReadback $Context $DatabaseReceipt $Preparation $Environments -Rollback:$Rollback -ConsumersEnabled -ApiOpen
        foreach ($component in @('worker', 'api')) {
            Assert-GatewayUpgradeExecutionAuthority $Context $action
            $entry = $Context.cutoverInventory.apps[$component]
            $configuration = ConvertFrom-Json (ConvertTo-Json $entry.configuration -Depth 100) -AsHashtable -Depth 100
            if ($component -ceq 'api' -and
                (-not $configuration.ingress.Contains('ipSecurityRestrictions') -or $null -eq $configuration.ingress.ipSecurityRestrictions)) {
                # PATCH omission does not remove the maintenance rule.
                $configuration.ingress.ipSecurityRestrictions = @()
            }
            $null = Invoke-GatewayUpgradeArm $Context PATCH $entry.id '2025-01-01' @{ properties = @{ configuration = $configuration } }
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Context.plan.cutover.TimeoutSeconds)
            while ($true) {
                $app = Invoke-GatewayUpgradeArm $Context GET $entry.id '2025-01-01'
                if ($app.properties.provisioningState -ceq 'Succeeded' -and
                    (Test-GatewayUpgradeCutoverRestoredConfiguration $Context $component $app.properties.configuration)) { break }
                if ([DateTimeOffset]::UtcNow -ge $deadline -or $app.properties.provisioningState -cnotin @('InProgress', 'Updating', 'Accepted')) {
                    throw 'UpgradeCutoverUnknown: reopening controls did not converge to the exact original configuration.'
                }
                Start-Sleep -Seconds 5
            }
        }
        Assert-GatewayUpgradeCutoverOpenControls $Context
        $joint = Assert-GatewayUpgradeJointReadback $Context $DatabaseReceipt $Preparation $Environments -Rollback:$Rollback -ConsumersEnabled -ApiOpen
        $null = Write-GatewayUpgradeExecutionRecord $Context $action 'result' $joint
        return $joint
    }
    catch {
        try { $null = Close-GatewayUpgradeCutover $Context }
        catch { throw 'UpgradeCutoverUnknown: reopening failed and physical reclosure could not be proven. Manual platform/SQL reconciliation is required.' }
        throw 'UpgradeCutoverReclosed: reopening failed; zero writers and receive/ingress holds were observed again. Reconcile possibly admitted work; do not replay.'
    }
}

function Test-GatewayUpgradeCutoverRestoredConfiguration {
    param($Context, [string]$Component, $Configuration)
    $original = $Context.cutoverInventory.apps[$Component].configuration
    if ($Configuration.activeRevisionsMode -cne $original.activeRevisionsMode) { return $false }
    if ($Component -ceq 'api') {
        $actualRules = @(if ($Configuration.ingress.Contains('ipSecurityRestrictions') -and $null -ne $Configuration.ingress.ipSecurityRestrictions) {
            $Configuration.ingress.ipSecurityRestrictions
        })
        $originalRules = @(if ($original.ingress.Contains('ipSecurityRestrictions') -and $null -ne $original.ingress.ipSecurityRestrictions) {
            $original.ingress.ipSecurityRestrictions
        })
        if ((Get-GatewayUpgradeFingerprint $actualRules) -cne (Get-GatewayUpgradeFingerprint $originalRules)) { return $false }
    }
    $normalized = ConvertTo-GatewayUpgradeCutoverNormalizedConfiguration $Context $Component $Configuration
    return (Get-GatewayUpgradeFingerprint $normalized) -ceq (Get-GatewayUpgradeFingerprint $original)
}

function Assert-GatewayUpgradeCutoverOpenControls {
    param($Context)
    foreach ($component in @('api', 'worker')) {
        $entry = $Context.cutoverInventory.apps[$component]
        $app = Invoke-GatewayUpgradeArm $Context GET $entry.id '2025-01-01'
        if ($app.properties.provisioningState -cne 'Succeeded' -or
            -not (Test-GatewayUpgradeCutoverRestoredConfiguration $Context $component $app.properties.configuration)) {
            throw 'UpgradeCutoverUnknown: original endpoint/revision controls were not restored exactly.'
        }
    }
    foreach ($id in @($Context.plan.cutover.ProvisioningQueueResourceId, $Context.plan.cutover.ProtectionQueueResourceId)) {
        $queue = Invoke-GatewayUpgradeArm $Context GET $id '2024-01-01'
        if ($queue.id -cne $id -or $queue.properties.status -cne 'Active') { throw 'UpgradeCutoverUnknown: queue reopen readback failed.' }
    }
}

function Save-GatewayUpgradeNamedEvidence {
    param($Context, [string]$Name, $Body, [switch]$ReuseExact)
    if ($Name -cnotmatch '^[a-z][a-z0-9-]{1,79}\.json$') { throw 'UpgradeExecution: invalid evidence name.' }
    $record = @{ fingerprint = Get-GatewayUpgradeFingerprint $Body; record = $Body }
    $path = Join-Path $Context.directory $Name
    if ($ReuseExact -and (Test-Path -LiteralPath $path)) {
        $existing = Read-GatewayUpgradeJson $path
        if ($existing.fingerprint -cne $record.fingerprint -or
            (Get-GatewayUpgradeFingerprint $existing.record) -cne $record.fingerprint) {
            throw 'UpgradeExecution: retained named evidence differs from the exact reconciled result.'
        }
        return @{ path = $path; fingerprint = $existing.fingerprint; record = $existing.record }
    }
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $record -Depth 100))
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    return @{ path = $path; fingerprint = $record.fingerprint; record = $Body }
}

function Test-GatewayUpgradeArtifactBundle {
    param($Context)
    $bundle = $Context.plan.artifacts.bundle.record
    if ((Get-GatewayUpgradeFingerprint $bundle.buildPlan) -cne $bundle.buildPlanFingerprint -or
        $bundle.sourceFingerprint -cne $Context.plan.content.sourceFingerprint -or
        $bundle.candidateFingerprint -cne $Context.candidateFingerprint) {
        throw 'UpgradeExecution: build Plan or artifact source provenance changed.'
    }
    foreach ($component in @('api', 'worker', 'adminUi', 'databaseMigrator', 'publisher')) {
        $image = $bundle.images[$component]
        $repository = switch ($component) {
            api { 'gateway-api' } worker { 'gateway-worker' } adminUi { 'gateway-admin' }
            databaseMigrator { 'gateway-db-migrator' } publisher { 'gateway-purview-package-publisher' }
        }
        $tag = "maintenance-$($bundle.buildPlanFingerprint.Substring(7, 24))-$($component.ToLowerInvariant())"
        $registry = $Context.foundation.acrLoginServer.Split('.')[0]
        $run = Get-GatewayAcrExactRunById -Registry $registry -Repository $repository -Tag $tag -RunId $image.runId -TagContract MaintenanceV1
        $run = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository $repository -Tag $tag -TagContract MaintenanceV1
        if ([string]$run.outputImages[0].digest -cne $image.digest -or
            $image.image -cne "$($Context.foundation.acrLoginServer)/$repository@$($image.digest)") {
            throw 'UpgradeExecution: the approved immutable artifact differs from its exact source-bound build run.'
        }
    }
    return $bundle
}

function Invoke-GatewayUpgradeOriginalSqlRestoration {
    param($Envelope, [string]$ExpectedPlanFingerprint, [string]$WorkspaceRoot)
    $plan = $Envelope.plan
    if ($Envelope.planFingerprint -cne $ExpectedPlanFingerprint -or
        (Get-GatewayUpgradeFingerprint $plan) -cne $ExpectedPlanFingerprint -or
        $plan.schemaVersion -ne 2 -or $plan.executionSupported -ne $true) {
        throw 'UpgradeAuthorizationRequired: restoration requires the exact previously approved executable Plan.'
    }
    $targets = @($plan.scope.privilegedMutations | Where-Object operation -CEQ 'TemporarySqlAdministratorDelegation')
    if ($targets.Count -ne 1 -or $targets[0].restorationRequiredBeforeAcceptance -ne $true) {
        throw 'UpgradeExecution: exact original-only SQL restoration scope is missing.'
    }
    $target = $targets[0]
    $configuration = $plan.request.target
    $prefix = "/subscriptions/$($configuration.subscriptionId)/resourceGroups/$($configuration.resourceGroupName)"
    $server = ([string]$plan.scope.existing.sqlServerFqdn).Split('.')[0]
    if ($plan.scope.resourceGroupId -cne $prefix -or
        $target.resourceId -cne "$prefix/providers/Microsoft.Sql/servers/$server/administrators/ActiveDirectory" -or
        $target.executionPrincipalResourceId -cnotin @($plan.scope.resources.resourceId) -or
        $target.restoreObjectId -cne ([guid][string]$target.restoreObjectId).ToString('D')) {
        throw 'UpgradeExecution: SQL restoration target escaped the approved exact scope.'
    }
    $directory = Join-Path ([IO.Path]::GetFullPath($WorkspaceRoot)) ".maintenance\executions\$($ExpectedPlanFingerprint.Substring(7))"
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'UpgradeExecution: no retained execution authority exists.' }
    $context = @{ directory = $directory; plan = $plan; planFingerprint = $ExpectedPlanFingerprint
        expectedPlanFingerprint = $ExpectedPlanFingerprint; config = $configuration }
    $delegation = Read-GatewayUpgradeExecutionRecord $context 'sql-admin-delegate' 'intent'
    if ($null -eq $delegation) { throw 'UpgradeExecution: no exact pre-mutation SQL delegation intent exists.' }
    $input = $delegation.record.value.input
    if ($input.server -cne $server -or $input.original.objectId -cne $target.restoreObjectId -or
        $input.original.login -cne $target.restoreLogin -or
        (Get-GatewayUpgradeFingerprint $input) -cne $delegation.record.value.inputFingerprint) {
        throw 'UpgradeExecution: SQL delegation evidence does not authorize this restoration.'
    }
    $lockDirectory = Join-Path ([IO.Path]::GetFullPath($WorkspaceRoot)) '.maintenance\locks'
    [IO.Directory]::CreateDirectory($lockDirectory) | Out-Null
    $lock = [IO.File]::Open((Join-Path $lockDirectory "$($configuration.deploymentOwnershipId).lock"),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Initialize-GatewayUpgradeExecutionHelpers
        Set-BootstrapAzureSubscriptionContext -SubscriptionId $configuration.subscriptionId -TenantId $configuration.tenantId
        $null = Assert-BootstrapAzureContext -Config $configuration
        $job = Invoke-GatewayUpgradeArm $context GET $target.executionPrincipalResourceId '2025-01-01'
        if ($job.identity.principalId -cne $input.jobPrincipalId -or
            $job.tags.gatewayUpgradePlanFingerprint -cne $ExpectedPlanFingerprint -or
            $job.tags.bootstrapOwnershipId -cne $configuration.deploymentOwnershipId) {
            throw 'UpgradeExecution: the delegated migration identity does not belong to this exact approved job.'
        }
        Restore-GatewayUpgradeSqlAdministrator $context @{
            principalId = [string]$job.identity.principalId; name = $target.executionPrincipalResourceId.Split('/')[-1]
        } $server @{ objectId = $target.restoreObjectId; login = $target.restoreLogin }
        $verified = Get-GatewaySqlEntraAdministrator -Config $configuration -ServerName $server
        if ($verified.objectId -cne $target.restoreObjectId -or $verified.login -cne $target.restoreLogin) {
            throw 'UpgradeExecution: original SQL administrator restoration was not read back exactly.'
        }
        return @{ status = 'OriginalSqlAdministratorRestored'; upgradeContinued = $false; candidateIntegrityBypassedOnlyForExactCompensation = $true }
    }
    finally { Clear-BootstrapAzureSubscriptionContext; $lock.Dispose() }
}

function Invoke-GatewayUpgradeObservedDatabaseThenExecutor {
    param($Context, $Images, $Automation, $Certificate, $ExecutorIdentity, $Package, [switch]$ReadOnly, [switch]$ObserveForRollback)
    $database = Invoke-GatewayUpgradeDatabase $Context $Images -ReadOnly:$ReadOnly -ObserveForRollback:$ObserveForRollback
    $executor = Invoke-GatewayUpgradeExecutorHost $Context $Automation $Certificate $ExecutorIdentity $Package -Enable -ReadOnly:$ReadOnly
    return @{ database = $database; executor = $executor }
}

function Get-GatewayUpgradeSourceOnlyEvidence {
    param($Context, [string]$Name, $Value, [switch]$ReadOnly)
    $path = Join-Path $Context.directory $Name
    if (Test-Path -LiteralPath $path) {
        $saved = Read-GatewayUpgradeJson $path
        if ((Get-GatewayUpgradeFingerprint $saved.record) -cne $saved.fingerprint -or
            $saved.record.planFingerprint -cne $Context.planFingerprint -or
            $saved.record.originalStateSha256 -cne $Context.plan.original.stateSha256) {
            throw 'UpgradeSourceOnly: immutable preservation evidence changed.'
        }
        if ($null -ne $Value -and (Get-GatewayUpgradeFingerprint $saved.record.value) -cne (Get-GatewayUpgradeFingerprint $Value)) {
            throw 'UpgradeSourceOnly: preserved configuration, credential or permission drifted.'
        }
        return $saved.record.value
    }
    if ($ReadOnly -or (Test-Path -LiteralPath (Join-Path $Context.directory 'cutover-pre-schema-api.json'))) {
        throw 'UpgradeSourceOnly: missing original preservation evidence cannot be recaptured after cutover.'
    }
    $null = Save-GatewayUpgradeNamedEvidence $Context $Name @{
        planFingerprint = $Context.planFingerprint; originalStateSha256 = $Context.plan.original.stateSha256; value = $Value
    }
    return $Value
}

function Get-GatewayUpgradeSourceOnlyWorkloadFingerprint {
    param([string]$Component, $Snapshot)
    $allowed = if ($Component -ceq 'api') {
        '^(MaintenanceCutover__|DatabaseAttestation__Upgrade__|DatabaseAttestation__ExpectedSchemaFingerprint$)'
    } elseif ($Component -ceq 'worker') {
        '^(ProvisioningWorker__ProcessingEnabled|ProtectionAdminWorker__ProcessingEnabled|OutboxRelay__Enabled|PurviewExecutor__Binding__(ExecutionSourceFingerprint|PackageDigest))$'
    } else { '(?!)' }
    return Get-GatewayUpgradeFingerprint @($Snapshot.raw.properties.template.containers[0].env |
        Where-Object { $_.name -cnotmatch $allowed } | Sort-Object name)
}

function Assert-GatewayUpgradeSourceOnlyWorkloadPreservation {
    param($Context, [string]$Component, $Snapshot)
    $expected = Get-GatewayUpgradeSourceOnlyEvidence $Context "source-only-$Component-environment.json" $null -ReadOnly
    if ((Get-GatewayUpgradeSourceOnlyWorkloadFingerprint $Component $Snapshot) -cne $expected) {
        throw 'UpgradeSourceOnly: original capability, identity, endpoint or other workload environment changed.'
    }
}

function Get-GatewayUpgradeSourceOnlyCapabilities {
    param($Context, [switch]$ReadOnly)
    $scope = $Context.plan.scope.purview
    $fresh = $Context.state.freshPurviewExecutor
    $old = $fresh.host.executorBinding.value
    $account = Invoke-GatewayUpgradeArm $Context GET $scope.retained.contentSafetyAccountId '2023-05-01'
    if ($account.kind -cne 'ContentSafety' -or $account.sku.name -cne $Context.plan.request.capabilities.promptShields.sku -or
        $account.location -cne $Context.config.location -or $account.properties.disableLocalAuth -ne $true -or
        $account.tags.bootstrapOwnershipId -cne $Context.state.deploymentOwnershipId -or
        $account.tags.bootstrapSourceFingerprint -cne $Context.state.acceptedPlan.sourceFingerprint -or
        "https://$($account.properties.customSubDomainName).cognitiveservices.azure.com/" -cne $scope.retained.contentSafetyEndpoint) {
        throw 'UpgradeSourceOnly: original Content Safety ownership, SKU, endpoint or authentication differs.'
    }
    $automation = Get-BootstrapPurviewAutomationIdentityEvidence -Config $Context.config -AzureIdentity $Context.actor `
        -KeyVaultUri $Context.runtime.keyVaultUri -DeploymentOwnershipId $Context.state.deploymentOwnershipId `
        -SourceFingerprint $Context.state.acceptedPlan.sourceFingerprint
    if ($automation.automationApplicationId -cne $old.AutomationApplicationId -or
        $automation.automationServicePrincipalId -cne $old.AutomationServicePrincipalObjectId -or
        $automation.certificateSecretUri -cne $old.CertificateSecretUri -or $automation.organization -cne $fresh.context.organization) {
        throw 'UpgradeSourceOnly: original automation identity/certificate/organization changed.'
    }
    $identity = Ensure-PurviewExecutorIdentity -Context $fresh.context -Operations $fresh.operations -ReadOnly `
        -Checkpoint { throw 'UpgradeSourceOnly: existing executor identity verification must never write.' }
    if ((Get-GatewayUpgradeFingerprint $identity) -cne (Get-GatewayUpgradeFingerprint $fresh.identity)) {
        throw 'UpgradeSourceOnly: original executor application/role identity changed.'
    }
    $null = Assert-ExactGraphApplicationRoleAssignments -PrincipalId $Context.purviewRuntime.principalId `
        -ExpectedRoleValues @('Content.Process.User', 'ProtectionScopes.Compute.User', 'ContentActivity.Write')
    $null = Assert-GatewayExactAzureRoleAssignments -Config $Context.config -Runtime $Context.runtime `
        -AdminUi $Context.state.steps['Admin UI deployment'].evidence -Database $Context.database `
        -PurviewAutomation $automation -PurviewExecutor @{ enabled = $true }
    $null = Assert-GatewayPrincipalExactAzureRoleAssignments -PrincipalId $old.ExecutorPrincipalId `
        -SubscriptionId $Context.config.subscriptionId -PrincipalLabel 'Retained Purview executor identity' -ExpectedAssignments @(
            @{ scope = $scope.packagesId; roleDefinitionId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'; assignmentId = $fresh.host.packageReaderRoleId.value }
            @{ scope = $scope.claimsId; roleDefinitionId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'; assignmentId = $fresh.host.claimWriterRoleId.value }
            @{ scope = $scope.certificateId; roleDefinitionId = '4633458b-17de-408a-b874-0445c86b69e6'; assignmentId = $fresh.host.certificateReaderRoleId.value }
        )
    $roles = @()
    foreach ($principal in @($Context.runtime.apiPrincipalId, $Context.runtime.workerPrincipalId, $Context.purviewRuntime.principalId, $old.ExecutorPrincipalId)) {
        $assignments = @(Invoke-AzJson -Arguments @('role', 'assignment', 'list', '--assignee-object-id', $principal,
            '--all', '--query', '[].{id:id,scope:scope,principalId:principalId,roleDefinitionId:roleDefinitionId,condition:condition,conditionVersion:conditionVersion}'))
        $roles += @($assignments | Sort-Object id)
    }
    $contentRole = @($roles | Where-Object { ([string]$_.scope).Equals($scope.retained.contentSafetyAccountId, [StringComparison]::OrdinalIgnoreCase) -and
        $_.principalId -ceq $Context.runtime.apiPrincipalId -and
        $_.roleDefinitionId.EndsWith('/a97b65f3-24c7-4388-baec-2e87135dc908', [StringComparison]::Ordinal) -and -not $_.condition })
    if ($contentRole.Count -ne 1) { throw 'UpgradeSourceOnly: the existing exact Content Safety assignment is missing or ambiguous.' }
    $site = Invoke-GatewayUpgradeArm $Context GET $scope.siteId '2024-11-01'
    $plan = Invoke-GatewayUpgradeArm $Context GET $scope.retained.planId '2024-11-01'
    if ($site.identity.principalId -cne $old.ExecutorPrincipalId -or $site.identity.type -cne 'SystemAssigned' -or
        $site.properties.serverFarmId -cne $scope.retained.planId -or $site.properties.publicNetworkAccess -cne 'Disabled' -or
        $site.properties.enabled -ne $true -or $site.properties.httpsOnly -ne $true -or
        $site.properties.virtualNetworkSubnetId -cne $fresh.host.integrationSubnetId.value -or
        $site.properties.outboundVnetRouting.allTraffic -ne $true -or
        "https://$($site.properties.defaultHostName)" -cne $fresh.host.executorEndpoint.value -or
        $plan.sku.name -cne $Context.plan.request.capabilities.purview.executorSku -or
        $plan.sku.capacity -ne 1 -or $plan.properties.reserved -ne $false -or
        $site.tags.bootstrapOwnershipId -cne $Context.state.deploymentOwnershipId -or
        $site.tags.bootstrapSourceFingerprint -cne $Context.state.acceptedPlan.sourceFingerprint) {
        throw 'UpgradeSourceOnly: installed private Windows executor boundary changed.'
    }
    $protected = @{
        account = @{ id = $account.id; sku = $account.sku; tags = $account.tags; properties = $account.properties }
        site = @{ id = $site.id; identity = $site.identity; tags = $site.tags; planId = $site.properties.serverFarmId
            subnetId = $site.properties.virtualNetworkSubnetId; endpoint = $site.properties.defaultHostName }
        plan = @{ id = $plan.id; sku = $plan.sku; tags = $plan.tags; reserved = $plan.properties.reserved }
        automation = $automation; roles = $roles; executorIdentity = $identity
    }
    foreach ($child in @('config/authsettingsV2', 'basicPublishingCredentialsPolicies/ftp', 'basicPublishingCredentialsPolicies/scm')) {
        $protected[$child] = (Invoke-GatewayUpgradeArm $Context GET "$($scope.siteId)/$child" '2024-11-01').properties
    }
    $auth = $protected['config/authsettingsV2']
    $aad = $auth.identityProviders.azureActiveDirectory
    if ($auth.platform.enabled -ne $true -or $auth.globalValidation.requireAuthentication -ne $true -or
        $auth.globalValidation.unauthenticatedClientAction -cne 'Return401' -or $auth.login.tokenStore.enabled -ne $false -or
        $aad.enabled -ne $true -or $aad.registration.clientId -cne $fresh.identity.applicationId -or
        $aad.registration.openIdIssuer -cne "https://login.microsoftonline.com/$($Context.config.tenantId)/v2.0" -or
        (Get-GatewayUpgradeFingerprint @($aad.validation.allowedAudiences)) -cne (Get-GatewayUpgradeFingerprint @($fresh.identity.applicationId)) -or
        (Get-GatewayUpgradeFingerprint @($aad.validation.defaultAuthorizationPolicy.allowedApplications)) -cne (Get-GatewayUpgradeFingerprint @($Context.database.workerPrincipalClientId)) -or
        (Get-GatewayUpgradeFingerprint @($aad.validation.defaultAuthorizationPolicy.allowedPrincipals.identities)) -cne (Get-GatewayUpgradeFingerprint @($Context.runtime.workerPrincipalId)) -or
        $protected['basicPublishingCredentialsPolicies/ftp'].allow -ne $false -or
        $protected['basicPublishingCredentialsPolicies/scm'].allow -ne $false) {
        throw 'UpgradeSourceOnly: installed executor authentication/caller/publishing boundary changed.'
    }
    $endpoint = Invoke-GatewayUpgradeArm $Context GET $fresh.host.privateEndpointId.value '2023-11-01'
    $connections = @($endpoint.properties.privateLinkServiceConnections)
    if ($connections.Count -ne 1 -or $connections[0].properties.privateLinkServiceId -cne $scope.siteId -or
        $connections[0].properties.privateLinkServiceConnectionState.status -cne 'Approved' -or
        $endpoint.properties.subnet.id -cne $Context.foundation.privateEndpointSubnetId) {
        throw 'UpgradeSourceOnly: the existing private endpoint does not target the exact executor.'
    }
    $protected.privateEndpoint = $endpoint.properties
    $queue = Invoke-GatewayUpgradeArm $Context GET $scope.queueId '2024-01-01'
    $protected.queue = @{}
    foreach ($key in @('requiresSession', 'requiresDuplicateDetection', 'lockDuration', 'defaultMessageTimeToLive', 'maxDeliveryCount',
        'deadLetteringOnMessageExpiration', 'maxSizeInMegabytes', 'enablePartitioning', 'enableExpress', 'autoDeleteOnIdle')) {
        $protected.queue[$key] = $queue.properties[$key]
    }
    $null = Get-GatewayUpgradeSourceOnlyEvidence $Context 'source-only-capabilities.json' $protected -ReadOnly:$ReadOnly
    return @{
        contentSafety = @{ accountId = $account.id; endpoint = $scope.retained.contentSafetyEndpoint; sku = $account.sku.name; roleId = $contentRole[0].id }
        automation = @{ applicationObjectId = $automation.automationApplicationObjectId; applicationId = $automation.automationApplicationId; principalId = $automation.automationServicePrincipalId }
        certificate = @{ secretUri = $automation.certificateSecretUri; organization = $automation.organization }
        executorIdentity = $identity
    }
}

function Invoke-GatewayUpgradeSourceOnlyExecutor {
    param($Context, $Automation, $ExecutorIdentity, $Package, [switch]$Enable, [switch]$ReadOnly)
    $scope = $Context.plan.scope.purview
    $fresh = $Context.state.freshPurviewExecutor
    $saved = Get-GatewayUpgradeSourceOnlyEvidence $Context 'source-only-executor-settings.json' $null -ReadOnly
    $binding = Get-GatewayUpgradeExecutorBinding $Context $Automation $ExecutorIdentity $Package $fresh.host.executorPrincipalId.value
    $expected = ConvertFrom-Json (ConvertTo-Json $saved -Depth 30) -AsHashtable -Depth 30
    $expected.WEBSITE_RUN_FROM_PACKAGE = "https://$($Context.runtime.storageAccountId.Split('/')[-1]).blob.core.windows.net/purview-executor-packages/$($Package.receipt.packageDigest.Substring(7)).zip"
    $expected.Executor__RuntimeManifestDigest = $Package.receipt.runtimeManifestDigest
    $expected.Executor__Binding__ExecutionSourceFingerprint = $binding.ExecutionSourceFingerprint
    $expected.Executor__Binding__PackageDigest = $binding.PackageDigest
    $readback = {
        param($outputs)
        $settings = (Invoke-GatewayUpgradeArm $Context POST "$($scope.siteId)/config/appsettings/list" '2024-11-01' @{}).properties
        if ((Get-GatewayUpgradeFingerprint $settings) -cne (Get-GatewayUpgradeFingerprint $expected)) {
            throw 'UpgradeSourceOnly: executor package readback differs from the exact source-only settings.'
        }
        $null = Get-GatewayUpgradeSourceOnlyCapabilities $Context -ReadOnly
        return @{ id = $scope.siteId; principalId = $fresh.host.executorPrincipalId.value; endpoint = $fresh.host.executorEndpoint.value
            binding = $binding; packageDigest = $Package.receipt.packageDigest }
    }
    if (-not $Enable) {
        $settings = (Invoke-GatewayUpgradeArm $Context POST "$($scope.siteId)/config/appsettings/list" '2024-11-01' @{}).properties
        $already = $null -ne (Read-GatewayUpgradeExecutionRecord $Context 'executor-source-cutover' 'intent')
        if ((Get-GatewayUpgradeFingerprint $settings) -cne (Get-GatewayUpgradeFingerprint $(if ($already) { $expected } else { $saved }))) {
            throw 'UpgradeSourceOnly: existing executor configuration changed outside its one approved cutover.'
        }
        return
    }
    return Invoke-GatewayUpgradeArmDeployment $Context 'executor-source-cutover' 'infrastructure\bicep\maintenance-source-only-executor.bicep' `
        @{ executorName = $scope.siteName; appSettings = $expected } @("$($scope.siteId)/config/appsettings") `
        -AllowedModifyResourceIds @("$($scope.siteId)/config/appsettings") -ReadOnly:$ReadOnly -Readback $readback
}

function Initialize-GatewayUpgradeSourceOnlyPreservation {
    param($Context, [switch]$ReadOnly)
    $null = Get-GatewayUpgradeSourceOnlyCapabilities $Context -ReadOnly:$ReadOnly
    foreach ($component in @('api', 'worker', 'adminUi')) {
        $snapshot = Get-GatewayUpgradeWorkloadSnapshot $Context $component
        $hash = Get-GatewayUpgradeSourceOnlyWorkloadFingerprint $component $snapshot
        $null = Get-GatewayUpgradeSourceOnlyEvidence $Context "source-only-$component-environment.json" $hash -ReadOnly:$ReadOnly
    }
    $path = Join-Path $Context.directory 'source-only-executor-settings.json'
    if (Test-Path -LiteralPath $path) { $null = Get-GatewayUpgradeSourceOnlyEvidence $Context 'source-only-executor-settings.json' $null -ReadOnly; return }
    $fresh = $Context.state.freshPurviewExecutor
    $settings = (Invoke-GatewayUpgradeArm $Context POST "$($Context.plan.scope.purview.siteId)/config/appsettings/list" '2024-11-01' @{}).properties
    foreach ($key in $fresh.host.executorBinding.value.Keys) {
        if ($settings["Executor__Binding__$key"] -cne $fresh.host.executorBinding.value[$key]) {
            throw 'UpgradeSourceOnly: original executor binding differs from independently verified baseline.'
        }
    }
    if ($settings.WEBSITE_RUN_FROM_PACKAGE -cne "$($fresh.host.packageContainerUri.value)/$($fresh.package.receipt.packageFileName)" -or
        $settings.Executor__RuntimeManifestDigest -cne $fresh.package.receipt.runtimeManifestDigest) {
        throw 'UpgradeSourceOnly: original executor package is not the accepted bootstrap package.'
    }
    $null = Get-GatewayUpgradeSourceOnlyEvidence $Context 'source-only-executor-settings.json' $settings -ReadOnly:$ReadOnly
}

function Invoke-GatewayUpgradePipeline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Build', 'Execute', 'Verify', 'Rollback', 'RestoreSqlAdministrator')][string]$Mode,
        [Parameter(Mandatory)]$Envelope, [Parameter(Mandatory)][string]$ExpectedPlanFingerprint,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StatePath, [Parameter(Mandatory)][AllowEmptyString()][string]$ConfigPath,
        [Parameter(Mandatory)][string]$WorkspaceRoot)
    if ($Mode -cne 'Verify') { Assert-GatewayUpgradeNoAbortMarker $WorkspaceRoot $ExpectedPlanFingerprint }
    Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradePlan.psm1')
    if ($Mode -ceq 'RestoreSqlAdministrator') {
        return Invoke-GatewayUpgradeOriginalSqlRestoration $Envelope $ExpectedPlanFingerprint $WorkspaceRoot
    }
    $null = Test-GatewayUpgradePlanV2 $Envelope $ExpectedPlanFingerprint $StatePath $ConfigPath
    $plan = $Envelope.plan
    if (($Mode -ceq 'Build' -and $plan.buildSupported -ne $true) -or
        ($Mode -cne 'Build' -and $plan.executionSupported -ne $true)) {
        throw 'UpgradeAuthorizationRequired: independent review and exact source/digest approval are required.'
    }
    if ($Mode -ceq 'Build' -and $null -ne $plan.artifacts) { throw 'UpgradeExecution: approved artifacts are never rebuilt by a deployment Plan.' }
    $root = [IO.Path]::GetFullPath($WorkspaceRoot)
    if ($root -match '(?:^|[\\/])\.bootstrap(?:[\\/]|$)') { throw 'UpgradeExecution: maintenance state cannot be stored under bootstrap proof.' }
    $state = Read-GatewayUpgradeJson $StatePath
    $config = Read-GatewayUpgradeJson $ConfigPath
    $directory = Join-Path $root ".maintenance\executions\$($ExpectedPlanFingerprint.Substring(7))"
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $lockDirectory = Join-Path $root '.maintenance\locks'
    [IO.Directory]::CreateDirectory($lockDirectory) | Out-Null
    $lock = [IO.File]::Open((Join-Path $lockDirectory "$($state.deploymentOwnershipId).lock"),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $context = @{
        directory = $directory; workspaceRoot = $root; plan = $plan; planFingerprint = $ExpectedPlanFingerprint
        cutoverExecutionModule = $ExecutionContext.SessionState.Module
        expectedPlanFingerprint = $ExpectedPlanFingerprint; state = $state; config = $config
        statePath = [IO.Path]::GetFullPath($StatePath); configPath = [IO.Path]::GetFullPath($ConfigPath)
        runtime = $state.steps['Gateway runtime deployment'].evidence; foundation = $state.steps['Azure foundation'].evidence
        database = $state.steps['Gateway database'].evidence; sourceRoot = $plan.localValidation.sourceRoot
        candidateReceiptPath = $plan.candidate.receiptPath; candidateFingerprint = $plan.candidate.fingerprint
        artifactSourceFingerprint = $plan.candidate.artifactSourceFingerprint
    }
    $completed = $false
    $cutoverStarted = $false
    try {
        Initialize-GatewayUpgradeExecutionHelpers
        Set-BootstrapAzureSubscriptionContext -SubscriptionId $config.subscriptionId -TenantId $config.tenantId
        $null = Assert-BootstrapAzureContext -Config $config
        Set-BootstrapExecutionSourceRoot -Path $context.sourceRoot
        if ((Get-BootstrapSourceFingerprint -Root $context.sourceRoot) -cne $context.artifactSourceFingerprint) {
            throw 'UpgradeExecution: helper-compatible artifact source changed.'
        }
        $operator = Assert-GatewayUpgradeCurrentOperator $plan
        $context.actor = @{ userObjectId = [string]$operator.objectId }
        $existingActions = @(if (Test-Path -LiteralPath (Join-Path $directory 'actions')) {
            Get-ChildItem -LiteralPath (Join-Path $directory 'actions') -Directory |
                Where-Object { $_.Name -cne 'coordination-container' -and $_.Name -cnotmatch '^image-' }
        })
        if ($Mode -cin @('Build', 'Execute') -and $existingActions.Count -eq 0) {
            $null = & (Get-Module GatewayUpgrade) {
                param($statePath, $configPath, $request)
                $inputs = Read-GatewayUpgradeBaselineInputs $statePath $configPath $request
                Invoke-GatewayUpgradeCanonicalVerifier $inputs
            } $StatePath $ConfigPath $plan.request
        }
        if ($Mode -cne 'Verify') { Enter-GatewayUpgradeCloudLease $context }
        if ($Mode -ceq 'Build') {
            $images = [ordered]@{}
            foreach ($component in @('api', 'worker', 'adminUi', 'databaseMigrator')) {
                $images[$component] = Invoke-GatewayUpgradeImageBuild $context $component $context.sourceRoot
            }
            $localPackage = New-GatewayUpgradeExecutorPackage $context
            $publisherPointer = Join-Path $context.directory 'publisher-context.json'
            if (Test-Path -LiteralPath $publisherPointer) {
                $savedPublisher = Read-GatewayUpgradeJson $publisherPointer
                if ((Get-GatewayUpgradeFingerprint $savedPublisher.record) -cne $savedPublisher.fingerprint -or
                    $savedPublisher.record.planFingerprint -cne $context.planFingerprint -or
                    $savedPublisher.record.packageReceiptFingerprint -cne $localPackage.package.receiptFingerprint) {
                    throw 'UpgradeExecution: publisher-context checkpoint differs from the approved package/Plan.'
                }
                $publisher = $savedPublisher.record.context
                $null = Test-GatewayUpgradePublisherContext $publisher.receiptPath $publisher.fingerprint
            }
            else {
                $publisher = New-GatewayUpgradePublisherContext -SourceRoot $context.sourceRoot -PackageDirectory $localPackage.directory `
                    -ExpectedSourceFingerprint $context.artifactSourceFingerprint -ExpectedPackageReceiptFingerprint $localPackage.package.receiptFingerprint `
                    -WorkspaceRoot $root
                $null = Save-GatewayUpgradeNamedEvidence $context 'publisher-context.json' @{
                    planFingerprint = $context.planFingerprint; packageReceiptFingerprint = $localPackage.package.receiptFingerprint; context = $publisher
                }
            }
            $context.publisherContextReceipt = $publisher.receiptPath
            $context.publisherContextFingerprint = $publisher.fingerprint
            $images.publisher = Invoke-GatewayUpgradeImageBuild $context publisher $publisher.sourceRoot
            $evidence = Save-GatewayUpgradeNamedEvidence $context 'artifacts.json' @{
                schemaVersion = 1; buildPlanFingerprint = $ExpectedPlanFingerprint; buildPlan = $plan
                candidateFingerprint = $context.candidateFingerprint; sourceFingerprint = $plan.content.sourceFingerprint
                artifactSourceFingerprint = $context.artifactSourceFingerprint; images = $images
                packageDirectory = $localPackage.directory; packageReceiptFingerprint = $localPackage.package.receiptFingerprint
                packageDigest = $localPackage.package.receipt.packageDigest
                publisherContextReceipt = $publisher.receiptPath; publisherContextFingerprint = $publisher.fingerprint
            } -ReuseExact
            $completed = $true
            return @{ status = 'ArtifactsBuiltRequireDigestApproval'; evidencePath = $evidence.path; fingerprint = $evidence.fingerprint; images = $images }
        }
        $bundle = Test-GatewayUpgradeArtifactBundle $context
        $package = Read-PurviewExecutorPackage -PackageDirectory $bundle.packageDirectory -ExpectedSourceFingerprint $context.artifactSourceFingerprint
        if ($package.receiptFingerprint -cne $bundle.packageReceiptFingerprint -or $package.receipt.packageDigest -cne $bundle.packageDigest) {
            throw 'UpgradeExecution: approved executor package changed.'
        }
        $runtimeIdentity = Invoke-GatewayUpgradeArm $context GET $context.foundation.runtimeImagePullIdentityId '2023-01-31'
        if ($runtimeIdentity.properties.principalId -cne $context.foundation.runtimeImagePullIdentityPrincipalId) {
            throw 'UpgradeExecution: original Purview runtime identity changed.'
        }
        $context.purviewRuntime = @{ clientId = [string]$runtimeIdentity.properties.clientId; principalId = [string]$runtimeIdentity.properties.principalId }
        $completedOpen = $null -ne (Read-GatewayUpgradeExecutionRecord $context 'cutover-open' 'result')
        $readOnly = $Mode -cin @('Verify', 'Rollback') -or ($Mode -ceq 'Execute' -and $completedOpen)
        if ($plan.request.schemaVersion -eq 2) { Initialize-GatewayUpgradeSourceOnlyPreservation $context -ReadOnly:$readOnly }
        if (Test-Path -LiteralPath (Join-Path $context.directory 'cutover-inventory.json')) {
            $null = Get-GatewayUpgradeCutoverInventory $context -ReadOnly
        }
        $null = Initialize-GatewayUpgradeWorkloadBaselines $context -ReadOnly:$readOnly
        if ($Mode -ceq 'Verify' -or ($Mode -ceq 'Execute' -and $completedOpen)) {
            $null = Get-GatewayUpgradeCutoverInventory $context -ReadOnly
            Assert-GatewayUpgradeCutoverOpenControls $context
        }
        else {
            $null = Get-GatewayUpgradeCutoverInventory $context
            $cutoverStarted = $true
            $null = Close-GatewayUpgradeCutover $context
            if ($Mode -cne 'Rollback' -and $null -ne (Read-GatewayUpgradeExecutionRecord $context 'cutover-open' 'intent')) {
                throw 'UpgradeCutoverReconciliationRequired: reopening may have admitted new work; a fresh private observation is required before further promotion or rollback.'
            }
        }
        if ($plan.request.schemaVersion -eq 2) {
            $retained = Get-GatewayUpgradeSourceOnlyCapabilities $context -ReadOnly:$readOnly
            $contentSafety = $retained.contentSafety
            $automation = $retained.automation
            $certificate = $retained.certificate
            $runtimeRoles = @()
            $queue = $null
            $executorIdentity = $retained.executorIdentity
        }
        else {
        $contentSafety = Invoke-GatewayUpgradeContentSafety $context -ReadOnly:$readOnly
        $automation = Invoke-GatewayUpgradeAutomationIdentity $context -ReadOnly:$readOnly
        $certificate = Invoke-GatewayUpgradeAutomationCertificate $context $automation -ReadOnly:$readOnly
        $runtimeRoles = @()
        foreach ($role in @('Content.Process.User', 'ProtectionScopes.Compute.User', 'ContentActivity.Write')) {
            $key = 'purview-runtime-' + $role.Replace('.', '-').ToLowerInvariant()
            $runtimeRoles += Invoke-GatewayUpgradeGraphRole $context $key $context.purviewRuntime.principalId $role -ReadOnly:$readOnly
        }
        $queue = Invoke-GatewayUpgradeProtectionQueue $context -ReadOnly:$readOnly
        $executorIdentity = Invoke-GatewayUpgradeExecutorIdentity $context -ReadOnly:$readOnly
        }
        if (-not $readOnly -or $Mode -ceq 'Rollback') {
            Set-GatewayUpgradeCutoverQueueHold $context $plan.cutover.ProtectionQueueResourceId
            Assert-GatewayUpgradeCutoverHeld $context -ZeroWriters
        }
        $null = Invoke-GatewayUpgradeExecutorHost $context $automation $certificate $executorIdentity $package -ReadOnly:$readOnly
        $publication = Invoke-GatewayUpgradePublisher $context $package $bundle.images.publisher -ReadOnly:$readOnly
        $observed = Invoke-GatewayUpgradeObservedDatabaseThenExecutor $context $bundle.images $automation $certificate $executorIdentity $package `
            -ReadOnly:$readOnly -ObserveForRollback:($Mode -ceq 'Rollback')
        $database = $observed.database
        $executor = $observed.executor
        $preparation = Get-GatewayUpgradeCapabilityPreparation $context $contentSafety $automation $certificate $queue $runtimeRoles $database -ReadOnly:$readOnly
        $apiEnvironment = Get-GatewayUpgradeApiEnvironment $context $database $preparation
        $workerEnvironment = Get-GatewayUpgradeWorkerEnvironment $context $automation $certificate $executor
        if ($Mode -ceq 'Verify' -or ($Mode -ceq 'Execute' -and $completedOpen)) {
            $workerEnvironment.ProvisioningWorker__ProcessingEnabled = 'true'
            $workerEnvironment.ProtectionAdminWorker__ProcessingEnabled = 'true'
        }
        $environments = @{
            api = $apiEnvironment; worker = $workerEnvironment
            adminUi = $(if ($plan.request.schemaVersion -eq 2) { @{} } else { @{ EntraId__Instance = 'https://login.microsoftonline.com/' } })
        }
        $workloads = [ordered]@{}
        if ($Mode -ceq 'Rollback') {
            $workloads = Invoke-GatewayUpgradeRollbackWorkloads $context $database $environments
        }
        else {
            foreach ($component in @('worker', 'api', 'adminUi')) {
                $environment = $environments[$component]
                $workloads[$component] = Invoke-GatewayUpgradeWorkload $context $component $bundle.images[$component].image $environment -ReadOnly:$readOnly `
                    -EnableConsumers:($component -ceq 'worker' -and ($Mode -ceq 'Verify' -or $completedOpen)) `
                    -OpenApi:($component -ceq 'api' -and ($Mode -ceq 'Verify' -or $completedOpen))
            }
        }
        if ($cutoverStarted) {
            $null = Assert-GatewayUpgradeJointReadback $context $database $preparation $environments -Rollback:($Mode -ceq 'Rollback') -RequireHeld
            $workerEnvironment.ProvisioningWorker__ProcessingEnabled = 'true'
            $workerEnvironment.ProtectionAdminWorker__ProcessingEnabled = 'true'
            $workerImage = if ($Mode -ceq 'Rollback') { $plan.rollbackContract.images.worker } else { $bundle.images.worker.image }
            $workloads.worker = Invoke-GatewayUpgradeWorkload $context worker $workerImage $workerEnvironment -EnableConsumers -Rollback:($Mode -ceq 'Rollback')
        }
        $null = Open-GatewayUpgradeCutover $context $database $preparation $environments -Rollback:($Mode -ceq 'Rollback') `
            -ReadOnly:($Mode -ceq 'Verify' -or ($Mode -ceq 'Execute' -and $completedOpen))
        $verification = @{
            schemaVersion = 1; planFingerprint = $ExpectedPlanFingerprint; observedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            status = if ($Mode -ceq 'Rollback') { 'CompatibleCodeRollbackVerified' } else { 'MaintenanceInfrastructureVerified' }
            workloads = $workloads; schemaFingerprint = $database.schemaFingerprint; databaseReceiptFingerprint = $database.receiptFingerprint
            publisher = $publication
            originalBootstrapHistoryChanged = $false; policyAndRuntimeVerdicts = 'NotClaimedRequiresSettingsOwnedTenantVerification'
        }
        if ($plan.request.schemaVersion -eq 2) { $verification.preservedCapabilityFactsFingerprint = $preparation.factsFingerprint }
        else { $verification.capabilityPreparationReceiptFingerprint = $preparation.receiptFingerprint }
        $saved = Save-GatewayUpgradeNamedEvidence $context "verification-$([guid]::NewGuid().ToString('N')).json" $verification
        $completed = $true
        return @{ status = $verification.status; evidencePath = $saved.path; fingerprint = $saved.fingerprint
            policyReadiness = 'NotClaimed'; originalBootstrapHistoryChanged = $false }
    }
    catch {
        if ($cutoverStarted -and -not $completed) {
            $failure = $_
            try { $null = Close-GatewayUpgradeCutover $context }
            catch { throw 'UpgradeCutoverUnknown: maintenance failed and management readback cannot prove physical closure. Manual reconciliation is required; do not replay or reactivate old binaries.' }
            throw $failure
        }
        throw
    }
    finally {
        if ($completed -and $Mode -cne 'Verify') { Exit-GatewayUpgradeCloudLease $context }
        Clear-BootstrapAzureSubscriptionContext
        $lock.Dispose()
    }
}

Export-ModuleMember -Function Invoke-GatewayUpgradeContentSafety, Invoke-GatewayUpgradeImageBuild, Invoke-GatewayUpgradeDatabase,
    Assert-GatewayUpgradeRollbackContract, Invoke-GatewayUpgradePipeline
