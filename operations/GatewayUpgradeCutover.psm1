#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1')

function New-GatewayUpgradeCutoverContract {
    param($Request, $Scope)
    $prefix = $Scope.resourceGroupId
    $namespace = "$prefix/providers/Microsoft.ServiceBus/namespaces/sb-$($Request.target.projectName)-$($Request.target.environment)"
    return @{
        SchemaVersion = 1
        ApiResourceId = "$prefix/providers/Microsoft.App/containerApps/ca-gateway-api-$($Request.target.environment)"
        WorkerResourceId = "$prefix/providers/Microsoft.App/containerApps/ca-gateway-worker-$($Request.target.environment)-v3"
        ProvisioningQueueResourceId = "$namespace/queues/gateway-provisioning-v3"
        ProtectionQueueResourceId = "$namespace/queues/gateway-protection-admin-v1"
        IngressRuleName = 'gateway-maintenance-deny'
        TimeoutSeconds = 600
    }
}

function Get-GatewayUpgradeCutoverDenyRule {
    return @{ name = 'gateway-maintenance-deny'; description = 'Plan-bound gateway cutover'; ipAddressRange = '0.0.0.0/0'; action = 'Deny' }
}

function Get-GatewayUpgradeCutoverExecutionModule {
    param($Context)
    $module = if ($Context.Contains('cutoverExecutionModule')) { $Context.cutoverExecutionModule } else { Get-Module GatewayUpgradeExecution }
    if ($module -isnot [System.Management.Automation.PSModuleInfo] -or $module.Name -cne 'GatewayUpgradeExecution' -or
        [IO.Path]::GetFullPath($module.Path) -cne [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'GatewayUpgradeExecution.psm1'))) {
        throw 'UpgradeCutover: only the source-bound execution module may service internal operations.'
    }
    return $module
}

function Add-GatewayUpgradeCutoverScope {
    param($Request, $Scope)
    $contract = New-GatewayUpgradeCutoverContract $Request $Scope
    $jobId = [string]@($Scope.resources | Where-Object stage -CEQ 'DatabaseExpand')[0].resourceId
    $Scope.resources += @{ stage = 'Cutover'; resourceId = $contract.ProvisioningQueueResourceId; permittedChange = 'ModifyReceiveStatusOnly' }
    if ($Request.schemaVersion -eq 2) {
        $Scope.resources += @{ stage = 'Cutover'; resourceId = $contract.ProtectionQueueResourceId; permittedChange = 'ModifyReceiveStatusOnly' }
    }
    foreach ($id in @($contract.ApiResourceId, $contract.WorkerResourceId, $contract.ProvisioningQueueResourceId, $contract.ProtectionQueueResourceId)) {
        $hash = Get-GatewayUpgradeFingerprint @{ scope = $id; principalResourceId = $jobId; role = 'Reader'; purpose = 'CutoverObservation' }
        $roleId = "$id/providers/Microsoft.Authorization/roleAssignments/$([guid]::new($hash.Substring(7, 32)).ToString('D'))"
        $Scope.resources += @{ stage = 'CutoverObservation'; resourceId = $roleId; permittedChange = 'Create' }
        $Scope.roles += @{
            scope = $id; principalResourceId = $jobId; assignmentResourceId = $roleId
            roleDefinitionId = "/subscriptions/$($Request.target.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
        }
    }
}

function Invoke-GatewayUpgradeCutoverArm {
    param($Context, [string]$Method, [string]$Id, [string]$Version, $Body, [switch]$AllowNotFound)
    if ($Context.Contains('cutoverDeadline') -and [DateTimeOffset]::UtcNow -ge $Context.cutoverDeadline) {
        throw 'UpgradeCutoverUnknown: the approved boundary timeout expired; physical closure is not proven.'
    }
    return & (Get-GatewayUpgradeCutoverExecutionModule $Context) {
        param($ctx, $method, $id, $version, $body, $allowNotFound)
        Invoke-GatewayUpgradeArm $ctx $method $id $version $body -AllowNotFound:$allowNotFound
    } $Context $Method $Id $Version $Body $AllowNotFound
}

function Assert-GatewayUpgradeCutoverAuthority {
    param($Context, [switch]$ReadOnly)
    & (Get-GatewayUpgradeCutoverExecutionModule $Context) {
        param($ctx, $readOnly)
        Assert-GatewayUpgradeExecutionAuthority $ctx 'cutover-boundary' -ReadOnly:$readOnly
    } $Context $ReadOnly
    $expected = New-GatewayUpgradeCutoverContract $Context.plan.request $Context.plan.scope
    if ((Get-GatewayUpgradeFingerprint $Context.plan.cutover) -cne (Get-GatewayUpgradeFingerprint $expected)) {
        throw 'UpgradeCutover: the fixed cutover contract differs from the approved Plan.'
    }
}

function Get-GatewayUpgradeCutoverRevisions {
    param($Context, [string]$AppId)
    $response = Invoke-GatewayUpgradeCutoverArm $Context GET "$AppId/revisions" '2025-01-01'
    if (-not $response.Contains('value') -or $response.value -isnot [array] -or $response.value.Count -eq 0 -or
        ($response.Contains('nextLink') -and $response.nextLink)) {
        throw 'UpgradeCutoverUnknown: incomplete revision inventory; closure is not proven.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($revision in $response.value) {
        if ($revision.id -isnot [string] -or
            $revision.id -cnotmatch "^$([regex]::Escape($AppId))/revisions/[a-z0-9-]+$" -or
            -not $seen.Add($revision.id) -or $revision.properties.active -isnot [bool] -or
            ($revision.properties.replicas -isnot [long] -and $revision.properties.replicas -isnot [int]) -or
            $revision.properties.replicas -lt 0) {
            throw 'UpgradeCutoverUnknown: malformed revision inventory; closure is not proven.'
        }
    }
    return ,@($response.value)
}

function Get-GatewayUpgradeCutoverQueueProperties {
    param($Queue)
    $properties = ConvertFrom-Json (ConvertTo-Json $Queue.properties -Depth 50) -AsHashtable -Depth 50
    foreach ($name in @('createdAt', 'updatedAt', 'accessedAt', 'sizeInBytes', 'messageCount', 'countDetails')) {
        $properties.Remove($name)
    }
    return $properties
}

function Assert-GatewayUpgradeCutoverHttpBoundary {
    param($Configuration)
    $ingress = $Configuration.ingress
    if (($ingress.Contains('transport') -and $ingress.transport -cnotin @('auto', 'http', 'http2')) -or
        ($ingress.Contains('additionalPortMappings') -and $null -ne $ingress.additionalPortMappings -and
            @($ingress.additionalPortMappings).Count -ne 0) -or
        ($Configuration.Contains('dapr') -and $null -ne $Configuration.dapr -and
            ($Configuration.dapr.enabled -isnot [bool] -or $Configuration.dapr.enabled))) {
        throw 'UpgradeCutover: alternate TCP or Dapr admission paths are outside the verified HTTP ingress hold.'
    }
}

function Get-GatewayUpgradeCutoverInventory {
    param($Context, [switch]$ReadOnly)
    $path = Join-Path $Context.directory 'cutover-inventory.json'
    if (Test-Path -LiteralPath $path) {
        $saved = Read-GatewayUpgradeJson $path
        if ((Get-GatewayUpgradeFingerprint $saved.record) -cne $saved.fingerprint -or
            $saved.record.planFingerprint -cne $Context.planFingerprint -or
            $saved.record.originalStateSha256 -cne $Context.plan.original.stateSha256) {
            throw 'UpgradeCutover: inventory binding changed.'
        }
        $Context.cutoverInventory = $saved.record
        return $saved.record
    }
    if ($ReadOnly) { throw 'UpgradeCutover: original cutover inventory is required.' }
    $actions = Join-Path $Context.directory 'actions'
    if (Test-Path -LiteralPath $actions) {
        $unsafe = @(Get-ChildItem -LiteralPath $actions -Directory | Where-Object {
            $_.Name -cne 'coordination-container' -and $_.Name -cnotmatch '^image-'
        })
        if ($unsafe.Count) { throw 'UpgradeCutoverUnsafePriorWork: cannot introduce a boundary after prior maintenance work.' }
    }
    $apps = @{}
    foreach ($component in @('api', 'worker')) {
        $snapshot = & (Get-GatewayUpgradeCutoverExecutionModule $Context) {
            param($ctx, $component)
            Get-GatewayUpgradeWorkloadSnapshot $ctx $component
        } $Context $component
        if ($snapshot.raw.properties.provisioningState -cne 'Succeeded') {
            throw 'UpgradeCutoverUnknown: the original workload operation has not settled.'
        }
        if ($component -ceq 'api') {
            Assert-GatewayUpgradeCutoverHttpBoundary $snapshot.raw.properties.configuration
            $probes = @($snapshot.raw.properties.template.containers[0].probes)
            if ($probes.Count -ne 3 -or @($probes.type | Sort-Object -Unique).Count -ne 3 -or
                @($probes | Where-Object { $_.type -cnotin @('Startup', 'Liveness', 'Readiness') }).Count) {
                throw 'UpgradeCutover: the original API requires exactly the reviewed startup, liveness and readiness probes.'
            }
        }
        $revisions = Get-GatewayUpgradeCutoverRevisions $Context $snapshot.id
        if ($revisions.Count -eq 0) { throw 'UpgradeCutoverUnknown: original revision inventory is empty.' }
        $apps[$component] = @{
            id = $snapshot.id; configuration = $snapshot.raw.properties.configuration
            revisions = @($revisions | ForEach-Object { $_.id })
        }
        if ($component -ceq 'api') { $apps[$component].probes = $probes }
        if ($component -ceq 'worker') {
            $outbox = @($snapshot.raw.properties.template.containers[0].env | Where-Object name -EQ 'OutboxRelay__Enabled')
            if ($outbox.Count -gt 1) { throw 'UpgradeCutover: duplicate original worker outbox controls.' }
            $apps[$component].outboxEnvironment = $outbox
        }
    }
    $queues = @{}
    foreach ($id in @($Context.plan.cutover.ProvisioningQueueResourceId, $Context.plan.cutover.ProtectionQueueResourceId)) {
        $queue = Invoke-GatewayUpgradeCutoverArm $Context GET $id '2024-01-01' -AllowNotFound
        if ($null -eq $queue) {
            if ($id -cne $Context.plan.cutover.ProtectionQueueResourceId) { throw 'UpgradeCutover: original provisioning queue is missing.' }
            $queues[$id] = $null
            continue
        }
        if ($queue.id -cne $id -or $queue.properties.status -cne 'Active') {
            throw 'UpgradeCutover: an unknown or previously held queue cannot be adopted.'
        }
        $queues[$id] = Get-GatewayUpgradeCutoverQueueProperties $queue
    }
    $saved = & (Get-GatewayUpgradeCutoverExecutionModule $Context) {
        param($ctx, $apps, $queues)
        Save-GatewayUpgradeNamedEvidence $ctx 'cutover-inventory.json' @{
            schemaVersion = 1; planFingerprint = $ctx.planFingerprint
            originalStateSha256 = $ctx.plan.original.stateSha256; apps = $apps; queues = $queues
        }
    } $Context $apps $queues
    $Context.cutoverInventory = $saved.record
    return $saved.record
}

function ConvertTo-GatewayUpgradeCutoverNormalizedConfiguration {
    param($Context, [string]$Component, $Configuration)
    $result = ConvertFrom-Json (ConvertTo-Json $Configuration -Depth 100) -AsHashtable -Depth 100
    if ($Component -ceq 'adminUi' -or -not $Context.Contains('cutoverInventory')) { return $result }
    $original = $Context.cutoverInventory.apps[$Component].configuration
    if ($result.activeRevisionsMode -ceq 'Multiple') {
        $result.activeRevisionsMode = $original.activeRevisionsMode
    }
    elseif ($result.activeRevisionsMode -cne $original.activeRevisionsMode) {
        throw 'UpgradeCutover: unowned revision mode change.'
    }
    if ($Component -ceq 'api') {
        $rules = @(if ($result.ingress.Contains('ipSecurityRestrictions') -and $null -ne $result.ingress.ipSecurityRestrictions) {
            $result.ingress.ipSecurityRestrictions
        })
        $originalHasNoRules = -not $original.ingress.Contains('ipSecurityRestrictions') -or $null -eq $original.ingress.ipSecurityRestrictions
        if ((Get-GatewayUpgradeFingerprint $rules) -ceq (Get-GatewayUpgradeFingerprint @(Get-GatewayUpgradeCutoverDenyRule)) -or
            ($rules.Count -eq 0 -and $originalHasNoRules)) {
            if ($original.ingress.Contains('ipSecurityRestrictions')) {
                $result.ingress.ipSecurityRestrictions = $original.ingress.ipSecurityRestrictions
            }
            else { $result.ingress.Remove('ipSecurityRestrictions') }
        }
    }
    return $result
}

function Set-GatewayUpgradeCutoverAppHold {
    param($Context, [ValidateSet('api', 'worker')][string]$Component, [switch]$EmergencyDeny)
    $entry = $Context.cutoverInventory.apps[$Component]
    $app = Invoke-GatewayUpgradeCutoverArm $Context GET $entry.id '2025-01-01'
    $configuration = $app.properties.configuration
    $normalized = ConvertTo-GatewayUpgradeCutoverNormalizedConfiguration $Context $Component $configuration
    if ((Get-GatewayUpgradeFingerprint $normalized) -cne (Get-GatewayUpgradeFingerprint $entry.configuration)) {
        throw 'UpgradeCutover: protected application configuration changed; automatic closure cannot overwrite it.'
    }
    $configuration.activeRevisionsMode = 'Multiple'
    if ($Component -ceq 'api') {
        if ($EmergencyDeny) { $configuration.ingress.ipSecurityRestrictions = @(Get-GatewayUpgradeCutoverDenyRule) }
        elseif ($entry.configuration.ingress.Contains('ipSecurityRestrictions')) {
            $configuration.ingress.ipSecurityRestrictions = $entry.configuration.ingress.ipSecurityRestrictions
        }
        else { $configuration.ingress.ipSecurityRestrictions = @() }
    }
    Assert-GatewayUpgradeCutoverAuthority $Context
    $null = Invoke-GatewayUpgradeCutoverArm $Context PATCH $entry.id '2025-01-01' @{ properties = @{ configuration = $configuration } }
    while ($true) {
        $observed = Invoke-GatewayUpgradeCutoverArm $Context GET $entry.id '2025-01-01'
        if ($observed.properties.provisioningState -ceq 'Succeeded' -and
            (Get-GatewayUpgradeFingerprint $observed.properties.configuration) -ceq (Get-GatewayUpgradeFingerprint $configuration)) { break }
        if ($observed.properties.provisioningState -cnotin @('InProgress', 'Updating', 'Accepted')) {
            throw 'UpgradeCutoverUnknown: application hold did not converge to its exact submitted controls.'
        }
        Start-Sleep -Seconds 5
    }
}

function Set-GatewayUpgradeCutoverQueueHold {
    param($Context, [string]$Id)
    if ($Id -cnotin @($Context.plan.cutover.ProvisioningQueueResourceId, $Context.plan.cutover.ProtectionQueueResourceId)) {
        throw 'UpgradeCutover: a receive hold may target only the two exact Plan-bound queues.'
    }
    $queue = Invoke-GatewayUpgradeCutoverArm $Context GET $Id '2024-01-01' -AllowNotFound
    if ($null -eq $queue) {
        if ($Id -ceq $Context.plan.cutover.ProtectionQueueResourceId -and $null -eq $Context.cutoverInventory.queues[$Id]) { return }
        throw 'UpgradeCutoverUnknown: a required queue is missing.'
    }
    if ($queue.id -cne $Id -or $queue.properties.status -cnotin @('Active', 'ReceiveDisabled')) {
        throw 'UpgradeCutoverUnknown: queue identity or state is unknown.'
    }
    $properties = Get-GatewayUpgradeCutoverQueueProperties $queue
    $original = $Context.cutoverInventory.queues[$Id]
    $properties.status = 'Active'
    if ($null -ne $original -and (Get-GatewayUpgradeFingerprint $properties) -cne (Get-GatewayUpgradeFingerprint $original)) {
        throw 'UpgradeCutover: queue configuration changed; messages and settings will not be overwritten.'
    }
    $properties.status = 'ReceiveDisabled'
    Assert-GatewayUpgradeCutoverAuthority $Context
    $null = Invoke-GatewayUpgradeCutoverArm $Context PUT $Id '2024-01-01' @{ properties = $properties }
}

function Assert-GatewayUpgradeCutoverHeld {
    param($Context, [switch]$ZeroWriters, [switch]$AllowAbsentProtectionQueue)
    Assert-GatewayUpgradeCutoverAuthority $Context -ReadOnly
    $null = Get-GatewayUpgradeCutoverInventory $Context -ReadOnly
    foreach ($component in @('api', 'worker')) {
        $entry = $Context.cutoverInventory.apps[$component]
        $app = Invoke-GatewayUpgradeCutoverArm $Context GET $entry.id '2025-01-01'
        if ($component -ceq 'api') { Assert-GatewayUpgradeCutoverHttpBoundary $app.properties.configuration }
        if ($app.id -cne $entry.id -or $app.properties.provisioningState -cne 'Succeeded' -or
            $app.properties.configuration.activeRevisionsMode -cne 'Multiple') {
            throw 'UpgradeCutoverUnknown: management readback does not prove the ingress/revision hold.'
        }
        $normalized = ConvertTo-GatewayUpgradeCutoverNormalizedConfiguration $Context $component $app.properties.configuration
        if ((Get-GatewayUpgradeFingerprint $normalized) -cne (Get-GatewayUpgradeFingerprint $entry.configuration)) {
            throw 'UpgradeCutoverUnknown: protected application configuration drifted.'
        }
        $revisions = Get-GatewayUpgradeCutoverRevisions $Context $entry.id
        foreach ($originalId in $entry.revisions) {
            if ($originalId -cnotin @($revisions.id)) {
                throw 'UpgradeCutoverUnknown: an inventoried original revision is absent from the complete readback.'
            }
        }
        foreach ($revision in $revisions) {
            $suffix = "upg-$($Context.planFingerprint.Substring(7, 16))-$component"
            $allowed = @("$($entry.id)/revisions/$($entry.id.Split('/')[-1])--$suffix")
            $preSchemaId = "$($allowed[0])-pre"
            if ($component -ceq 'api') { $allowed += $preSchemaId }
            if ($component -ceq 'worker') { $allowed += "$($allowed[0])-run" }
            $images = @($Context.plan.request.images[$component])
            if ($Context.plan.Contains('rollbackContract')) {
                $rollbackId = "$($entry.id)/revisions/$($entry.id.Split('/')[-1])--$suffix-rb"
                $allowed += $rollbackId
                if ($component -ceq 'worker') { $allowed += "$rollbackId-run" }
                $images += $Context.plan.rollbackContract.images[$component]
            }
            $approvedNew = $revision.id -cin $allowed -and @($revision.properties.template.containers).Count -eq 1 -and
                $revision.properties.template.containers[0].image -cin $images
            $closedApi = $component -ceq 'api' -and $approvedNew -and $revision.properties.active -eq $true
            if ($closedApi) {
                $phase = if ($revision.id -ceq $preSchemaId) { 'PreSchemaClosed' } else { 'PostSchemaClosed' }
                if ($ZeroWriters -and $phase -cne 'PreSchemaClosed') {
                    throw 'UpgradeCutoverNotDrained: schema work requires the exact pre-schema closed API.'
                }
                & (Get-GatewayUpgradeCutoverExecutionModule $Context) {
                    param($ctx, $rev, $maintenancePhase)
                    Assert-GatewayUpgradeMaintenanceApiRevision $ctx $rev $maintenancePhase
                } $Context $revision $phase
            }
            if (($ZeroWriters -and -not $closedApi) -or $revision.id -cin $entry.revisions -or -not $approvedNew) {
                if ($revision.properties.active -ne $false -or $revision.properties.replicas -ne 0) {
                    throw 'UpgradeCutoverNotDrained: an excluded revision remains active or has replicas.'
                }
                $replicas = Invoke-GatewayUpgradeCutoverArm $Context GET "$($revision.id)/replicas" '2025-01-01'
                if (-not $replicas.Contains('value') -or $replicas.value -isnot [array] -or $replicas.value.Count -ne 0 -or
                    ($replicas.Contains('nextLink') -and $replicas.nextLink)) {
                    throw 'UpgradeCutoverNotDrained: zero old writers was not independently observed.'
                }
            }
        }
    }
    foreach ($id in @($Context.plan.cutover.ProvisioningQueueResourceId, $Context.plan.cutover.ProtectionQueueResourceId)) {
        $queue = Invoke-GatewayUpgradeCutoverArm $Context GET $id '2024-01-01' -AllowNotFound
        if ($null -eq $queue -and $AllowAbsentProtectionQueue -and $id -ceq $Context.plan.cutover.ProtectionQueueResourceId -and
            $null -eq $Context.cutoverInventory.queues[$id]) { continue }
        if ($null -eq $queue -or $queue.id -cne $id -or $queue.properties.status -cne 'ReceiveDisabled') {
            throw 'UpgradeCutoverUnknown: management readback does not prove the queue receive hold.'
        }
        $properties = Get-GatewayUpgradeCutoverQueueProperties $queue
        $properties.status = 'Active'
        $original = $Context.cutoverInventory.queues[$id]
        if ($null -ne $original -and (Get-GatewayUpgradeFingerprint $properties) -cne (Get-GatewayUpgradeFingerprint $original)) {
            throw 'UpgradeCutoverUnknown: protected queue configuration drifted.'
        }
    }
}

function Close-GatewayUpgradeCutover {
    param($Context)
    $Context.cutoverDeadline = [DateTimeOffset]::UtcNow.AddSeconds($Context.plan.cutover.TimeoutSeconds)
    try {
    Assert-GatewayUpgradeCutoverAuthority $Context
    $null = Get-GatewayUpgradeCutoverInventory $Context
    $null = & (Get-GatewayUpgradeCutoverExecutionModule $Context) {
        param($ctx)
        Initialize-GatewayUpgradeWorkloadBaselines $ctx
    } $Context
    $null = & (Get-GatewayUpgradeCutoverExecutionModule $Context) {
        param($ctx)
        Save-GatewayUpgradeNamedEvidence $ctx "cutover-close-intent-$([guid]::NewGuid().ToString('N')).json" @{
            planFingerprint = $ctx.planFingerprint; disposition = 'CloseOnlyNeverReactivateOldRevisions'
        }
    } $Context
    # A fresh close-only attempt is safe after an unknown outcome; it never reopens or replays application work.
    $failures = [Collections.Generic.List[string]]::new()
    try { Set-GatewayUpgradeCutoverAppHold $Context api }
    catch { $failures.Add("API admission hold: $($_.Exception.Message)") }
    foreach ($id in @($Context.plan.cutover.ProvisioningQueueResourceId, $Context.plan.cutover.ProtectionQueueResourceId)) {
        try { Set-GatewayUpgradeCutoverQueueHold $Context $id }
        catch { $failures.Add("Queue receive hold: $($_.Exception.Message)") }
    }
    try { Set-GatewayUpgradeCutoverAppHold $Context worker }
    catch { $failures.Add("Worker revision hold: $($_.Exception.Message)") }
    $preSchemaId = $null
    try {
        $preSchemaId = & (Get-GatewayUpgradeCutoverExecutionModule $Context) {
            param($ctx)
            Invoke-GatewayUpgradePreSchemaApi $ctx
        } $Context
    }
    catch {
        $failures.Add("Pre-schema API hold: $($_.Exception.Message)")
        try { Set-GatewayUpgradeCutoverAppHold $Context api -EmergencyDeny }
        catch { $failures.Add("Emergency API ingress hold: $($_.Exception.Message)") }
    }
    foreach ($component in @('api', 'worker')) {
        try {
            foreach ($revision in (Get-GatewayUpgradeCutoverRevisions $Context $Context.cutoverInventory.apps[$component].id)) {
                if ($revision.properties.active -and $revision.id -cne $preSchemaId) {
                    Assert-GatewayUpgradeCutoverAuthority $Context
                    $null = Invoke-GatewayUpgradeCutoverArm $Context POST "$($revision.id)/deactivate" '2025-01-01'
                }
            }
        }
        catch { $failures.Add("$component revision exclusion: $($_.Exception.Message)") }
    }
    if ($failures.Count) {
        throw "UpgradeCutoverUnknown: independent close-only controls were attempted, but physical closure is not proven. $($failures -join '; ')"
    }
    while ($true) {
        try {
            Assert-GatewayUpgradeCutoverHeld $Context -ZeroWriters -AllowAbsentProtectionQueue
            break
        }
        catch {
            if ($_.Exception.Message -notlike 'UpgradeCutoverNotDrained:*' -or [DateTimeOffset]::UtcNow -ge $Context.cutoverDeadline) { throw }
            Start-Sleep -Seconds 5
        }
    }
    return @{ status = 'ClosedZeroWritersObserved'; planFingerprint = $Context.planFingerprint }
    }
    finally { $Context.Remove('cutoverDeadline') }
}

Export-ModuleMember -Function New-GatewayUpgradeCutoverContract, Add-GatewayUpgradeCutoverScope, Get-GatewayUpgradeCutoverDenyRule,
    Get-GatewayUpgradeCutoverInventory, ConvertTo-GatewayUpgradeCutoverNormalizedConfiguration,
    Close-GatewayUpgradeCutover, Assert-GatewayUpgradeCutoverHeld, Set-GatewayUpgradeCutoverQueueHold,
    Get-GatewayUpgradeCutoverRevisions
