#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeJson.psm1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap\modules\Common.psm1') -DisableNameChecking

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
    $prefix = "$AppId/revisions/"
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($revision in $response.value) {
        if ($revision.id -isnot [string] -or
            -not $revision.id.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            $revision.id.Substring($prefix.Length) -cnotmatch '\A[a-z0-9-]+\z' -or
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
    if ($Configuration -isnot [Collections.IDictionary] -or -not $Configuration.Contains('ingress') -or
        $Configuration.ingress -isnot [Collections.IDictionary]) {
        throw 'UpgradeCutover: an exact HTTP ingress configuration is required.'
    }
    $ingress = $Configuration.ingress
    if (($ingress.Contains('transport') -and
            ($ingress.transport -isnot [string] -or
                (-not [string]::Equals($ingress.transport, 'auto', [StringComparison]::OrdinalIgnoreCase) -and
                    -not [string]::Equals($ingress.transport, 'http', [StringComparison]::OrdinalIgnoreCase) -and
                    -not [string]::Equals($ingress.transport, 'http2', [StringComparison]::OrdinalIgnoreCase)))) -or
        ($ingress.Contains('additionalPortMappings') -and $null -ne $ingress.additionalPortMappings -and
            ($ingress.additionalPortMappings -isnot [array] -or $ingress.additionalPortMappings.Count -ne 0)) -or
        ($Configuration.Contains('dapr') -and $null -ne $Configuration.dapr -and
            ($Configuration.dapr -isnot [Collections.IDictionary] -or
                $Configuration.dapr.enabled -isnot [bool] -or $Configuration.dapr.enabled))) {
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
        if (-not (Test-GatewayUpgradeResourceId $queue.id $id) -or $queue.properties.status -cne 'Active') {
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
    if (-not (Test-GatewayUpgradeResourceId $queue.id $Id) -or $queue.properties.status -cnotin @('Active', 'ReceiveDisabled')) {
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

function Assert-GatewayUpgradeQueueShape {
    param($Value, [string[]]$Keys)
    & (Get-Module GatewayUpgrade) {
        param($value, $keys)
        Assert-GatewayUpgradeShape $value $keys 'queue quarantine evidence'
    } $Value $Keys
}

function Assert-GatewayUpgradeQueueUtc {
    param($Value)
    $date = [DateTimeOffset]::MinValue
    if ($Value -isnot [string] -or -not [DateTimeOffset]::TryParseExact($Value, 'O',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date) -or
        $date.Offset -ne [TimeSpan]::Zero -or $date.ToString('O') -cne $Value) {
        throw 'UpgradeQueueQuarantineInvalid: a canonical UTC observation or creation identity is required.'
    }
}

function Assert-GatewayUpgradeQueueCounters {
    param($Counters)
    $keys = @('ActiveMessageCount', 'ScheduledMessageCount', 'TransferMessageCount',
        'TransferDeadLetterMessageCount', 'DeadLetterMessageCount', 'MessageCount')
    Assert-GatewayUpgradeQueueShape $Counters $keys
    foreach ($key in $keys) {
        if (($Counters[$key] -isnot [int] -and $Counters[$key] -isnot [long]) -or $Counters[$key] -lt 0) {
            throw 'UpgradeQueueQuarantineInvalid: all six nonnegative integer counters are mandatory.'
        }
    }
    if ($Counters.ActiveMessageCount -ne 0 -or $Counters.ScheduledMessageCount -ne 0 -or
        $Counters.TransferMessageCount -ne 0 -or $Counters.TransferDeadLetterMessageCount -ne 0 -or
        $Counters.MessageCount -ne $Counters.DeadLetterMessageCount) {
        throw 'UpgradeQueueQuarantineInvalid: executable/transfer work is forbidden and total count must equal normal DLQ count.'
    }
}

function Get-GatewayUpgradeQueueQuarantineState {
    param($Queue, [string]$Id, [ValidateSet('Active', 'ReceiveDisabled')][string]$Status)
    if ($Queue -isnot [Collections.IDictionary] -or -not $Queue.Contains('id') -or -not $Queue.Contains('properties') -or
        -not (Test-GatewayUpgradeResourceId $Queue.id $Id) -or $Queue.properties -isnot [Collections.IDictionary]) {
        throw 'UpgradeQueueQuarantineInvalid: exact queue identity and properties are required.'
    }
    $properties = $Queue.properties
    foreach ($name in @('status', 'createdAt', 'countDetails', 'messageCount')) {
        if (-not $properties.Contains($name)) { throw 'UpgradeQueueQuarantineInvalid: required queue readback is missing.' }
    }
    if ($properties.status -cne $Status -or $properties.countDetails -isnot [Collections.IDictionary]) {
        throw 'UpgradeQueueQuarantineInvalid: queue phase or counter readback is unknown.'
    }
    foreach ($name in @('forwardTo', 'forwardDeadLetteredMessagesTo')) {
        if ($properties.Contains($name) -and $null -ne $properties[$name]) {
            throw 'UpgradeQueueQuarantineInvalid: normal or dead-letter forwarding is forbidden.'
        }
    }
    $created = [DateTimeOffset]::MinValue
    if ($properties.createdAt -isnot [string] -or -not [DateTimeOffset]::TryParse($properties.createdAt,
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$created) -or
        $created.Offset -ne [TimeSpan]::Zero) {
        throw 'UpgradeQueueQuarantineInvalid: queue creation identity is missing or malformed.'
    }
    $counts = @{ MessageCount = $properties.messageCount }
    foreach ($key in @('ActiveMessageCount', 'ScheduledMessageCount', 'TransferMessageCount',
            'TransferDeadLetterMessageCount', 'DeadLetterMessageCount')) {
        $name = $key.Substring(0, 1).ToLowerInvariant() + $key.Substring(1)
        if (-not $properties.countDetails.Contains($name)) { throw 'UpgradeQueueQuarantineInvalid: a queue counter is missing.' }
        $counts[$key] = $properties.countDetails[$name]
    }
    Assert-GatewayUpgradeQueueCounters $counts
    $configuration = Get-GatewayUpgradeCutoverQueueProperties $Queue
    $configuration.status = 'Active'
    return @{
        ResourceId = $Id; CreatedAtUtc = $created.ToString('O')
        ConfigurationFingerprint = Get-GatewayUpgradeFingerprint $configuration; Counters = $counts
    }
}

function New-GatewayUpgradeQueueQuarantineBaseline {
    param($Plan)
    if ($Plan.request.schemaVersion -ne 2 -or $Plan.request.mode -cne 'SourceOnlyFull' -or
        $Plan.Contains('queueQuarantineBaseline')) {
        throw 'UpgradeQueueQuarantineInvalid: only a new source-only Plan may capture a baseline; rebaselining is forbidden.'
    }
    $queues = @(
        foreach ($id in @($Plan.cutover.ProvisioningQueueResourceId, $Plan.cutover.ProtectionQueueResourceId)) {
            $raw = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('rest', '--method', 'GET',
                '--subscription', $Plan.request.target.subscriptionId,
                '--url', "https://management.azure.com$id`?api-version=2024-01-01", '--output', 'json', '--only-show-errors')
            if ($raw -isnot [string] -or $raw.Length -gt 65536) { throw 'UpgradeQueueQuarantineInvalid: bounded queue readback is unavailable.' }
            $queue = ConvertFrom-GatewayUpgradeArmJson -Json $raw
            Get-GatewayUpgradeQueueQuarantineState $queue $id 'Active'
        }
    )
    return @{
        SchemaVersion = 1; EvidenceKind = 'NormalDeadLetterCountOnly'; Phase = 'PlanReadOnlyBaseline'; ReceiverSubQueue = 'None'
        ObservedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        DeploymentOwnershipId = $Plan.request.target.deploymentOwnershipId
        OriginalAcceptedSourceFingerprint = $Plan.original.acceptedSourceFingerprint
        UpgradeSourceFingerprint = $Plan.content.sourceFingerprint; Queues = $queues
    }
}

function Assert-GatewayUpgradeQueueQuarantineBaseline {
    param($Plan)
    if ($Plan.request.schemaVersion -ne 2 -or $Plan.request.mode -cne 'SourceOnlyFull' -or
        -not $Plan.Contains('queueQuarantineBaseline')) {
        throw 'UpgradeQueueQuarantineMissing: an immutable source-only Plan baseline is required.'
    }
    $baseline = $Plan.queueQuarantineBaseline
    Assert-GatewayUpgradeQueueShape $baseline @('SchemaVersion', 'EvidenceKind', 'Phase', 'ReceiverSubQueue', 'ObservedAtUtc',
        'DeploymentOwnershipId', 'OriginalAcceptedSourceFingerprint', 'UpgradeSourceFingerprint', 'Queues')
    if (($baseline.SchemaVersion -isnot [int] -and $baseline.SchemaVersion -isnot [long]) -or $baseline.SchemaVersion -ne 1 -or
        $baseline.EvidenceKind -cne 'NormalDeadLetterCountOnly' -or $baseline.Phase -cne 'PlanReadOnlyBaseline' -or
        $baseline.ReceiverSubQueue -cne 'None' -or $baseline.DeploymentOwnershipId -cne $Plan.request.target.deploymentOwnershipId -or
        $baseline.OriginalAcceptedSourceFingerprint -cne $Plan.original.acceptedSourceFingerprint -or
        $baseline.UpgradeSourceFingerprint -cne $Plan.content.sourceFingerprint -or
        $baseline.Queues -isnot [array] -or $baseline.Queues.Count -ne 2) {
        throw 'UpgradeQueueQuarantineInvalid: source, purpose, receiver or exact queue-pair binding differs.'
    }
    Assert-GatewayUpgradeQueueUtc $baseline.ObservedAtUtc
    $ids = @($Plan.cutover.ProvisioningQueueResourceId, $Plan.cutover.ProtectionQueueResourceId)
    for ($index = 0; $index -lt 2; $index++) {
        $queue = $baseline.Queues[$index]
        Assert-GatewayUpgradeQueueShape $queue @('ResourceId', 'CreatedAtUtc', 'ConfigurationFingerprint', 'Counters')
        Assert-GatewayUpgradeQueueUtc $queue.CreatedAtUtc
        if ($queue.ResourceId -cne $ids[$index] -or
            [string]::CompareOrdinal($queue.CreatedAtUtc, $baseline.ObservedAtUtc) -gt 0 -or
            $queue.ConfigurationFingerprint -isnot [string] -or $queue.ConfigurationFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
            throw 'UpgradeQueueQuarantineInvalid: queue creation or configuration binding differs.'
        }
        Assert-GatewayUpgradeQueueCounters $queue.Counters
    }
}

function Assert-GatewayUpgradeQueueObservation {
    param($Context, $Observation, [string]$Phase)
    Assert-GatewayUpgradeQueueQuarantineBaseline $Context.plan
    Assert-GatewayUpgradeQueueShape $Observation @('SchemaVersion', 'EvidenceKind', 'PlanFingerprint',
        'UpgradeSourceFingerprint', 'BaselineFingerprint', 'ObservedAtUtc', 'Phase')
    Assert-GatewayUpgradeQueueUtc $Observation.ObservedAtUtc
    if (($Observation.SchemaVersion -isnot [int] -and $Observation.SchemaVersion -isnot [long]) -or $Observation.SchemaVersion -ne 1 -or
        $Observation.EvidenceKind -cne 'NormalDeadLetterCountOnly' -or $Observation.Phase -cne $Phase -or
        $Observation.PlanFingerprint -cne $Context.planFingerprint -or $Observation.UpgradeSourceFingerprint -cne $Context.plan.content.sourceFingerprint -or
        $Observation.BaselineFingerprint -cne (Get-GatewayUpgradeFingerprint $Context.plan.queueQuarantineBaseline) -or
        [string]::CompareOrdinal($Observation.ObservedAtUtc, $Context.plan.queueQuarantineBaseline.ObservedAtUtc) -lt 0) {
        throw 'UpgradeQueueQuarantineMismatch: count-only observation differs from the exact Plan/source/baseline/phase.'
    }
}

function Assert-GatewayUpgradeCutoverHeld {
    param($Context, [switch]$ZeroWriters, [switch]$AllowAbsentProtectionQueue,
        [ValidateSet('', 'SqlBefore', 'PreReopen', 'PreApiOpen')][string]$QueueQuarantinePhase = '')
    Assert-GatewayUpgradeCutoverAuthority $Context -ReadOnly
    $null = Get-GatewayUpgradeCutoverInventory $Context -ReadOnly
    if ($QueueQuarantinePhase) { Assert-GatewayUpgradeQueueQuarantineBaseline $Context.plan }
    foreach ($component in @('api', 'worker')) {
        $entry = $Context.cutoverInventory.apps[$component]
        $app = Invoke-GatewayUpgradeCutoverArm $Context GET $entry.id '2025-01-01'
        if ($component -ceq 'api') { Assert-GatewayUpgradeCutoverHttpBoundary $app.properties.configuration }
        if (-not (Test-GatewayUpgradeResourceId $app.id $entry.id) -or $app.properties.provisioningState -cne 'Succeeded' -or
            $app.properties.configuration.activeRevisionsMode -cne 'Multiple') {
            throw 'UpgradeCutoverUnknown: management readback does not prove the ingress/revision hold.'
        }
        $normalized = ConvertTo-GatewayUpgradeCutoverNormalizedConfiguration $Context $component $app.properties.configuration
        if ((Get-GatewayUpgradeFingerprint $normalized) -cne (Get-GatewayUpgradeFingerprint $entry.configuration)) {
            throw 'UpgradeCutoverUnknown: protected application configuration drifted.'
        }
        $revisions = Get-GatewayUpgradeCutoverRevisions $Context $entry.id
        foreach ($originalId in $entry.revisions) {
            if (-not (Test-GatewayUpgradeResourceId $originalId @($revisions.id))) {
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
            $approvedNew = (Test-GatewayUpgradeResourceId $revision.id $allowed) -and @($revision.properties.template.containers).Count -eq 1 -and
                $revision.properties.template.containers[0].image -cin $images
            $closedApi = $component -ceq 'api' -and $approvedNew -and $revision.properties.active -eq $true
            if ($closedApi) {
                $phase = if (Test-GatewayUpgradeResourceId $revision.id $preSchemaId) { 'PreSchemaClosed' } else { 'PostSchemaClosed' }
                if ($ZeroWriters -and $phase -cne 'PreSchemaClosed') {
                    throw 'UpgradeCutoverNotDrained: schema work requires the exact pre-schema closed API.'
                }
                & (Get-GatewayUpgradeCutoverExecutionModule $Context) {
                    param($ctx, $rev, $maintenancePhase)
                    Assert-GatewayUpgradeMaintenanceApiRevision $ctx $rev $maintenancePhase
                } $Context $revision $phase
            }
            if (($ZeroWriters -and -not $closedApi) -or (Test-GatewayUpgradeResourceId $revision.id $entry.revisions) -or -not $approvedNew) {
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
        if ($null -eq $queue -and $AllowAbsentProtectionQueue -and -not $QueueQuarantinePhase -and $id -ceq $Context.plan.cutover.ProtectionQueueResourceId -and
            $null -eq $Context.cutoverInventory.queues[$id]) { continue }
        if ($null -eq $queue -or -not (Test-GatewayUpgradeResourceId $queue.id $id) -or $queue.properties.status -cne 'ReceiveDisabled') {
            throw 'UpgradeCutoverUnknown: management readback does not prove the queue receive hold.'
        }
        if ($QueueQuarantinePhase) {
            $observed = Get-GatewayUpgradeQueueQuarantineState $queue $id 'ReceiveDisabled'
            $baseline = @($Context.plan.queueQuarantineBaseline.Queues | Where-Object ResourceId -CEQ $id)
            if ($baseline.Count -ne 1 -or (Get-GatewayUpgradeFingerprint $observed) -cne (Get-GatewayUpgradeFingerprint $baseline[0])) {
                throw 'UpgradeQueueQuarantineMismatch: per-queue creation, configuration or counts changed; no rebaseline or cleanup is authorized.'
            }
        }
        $properties = Get-GatewayUpgradeCutoverQueueProperties $queue
        $properties.status = 'Active'
        $original = $Context.cutoverInventory.queues[$id]
        if ($null -ne $original -and (Get-GatewayUpgradeFingerprint $properties) -cne (Get-GatewayUpgradeFingerprint $original)) {
            throw 'UpgradeCutoverUnknown: protected queue configuration drifted.'
        }
    }
    if ($QueueQuarantinePhase) {
        $observation = @{
            SchemaVersion = 1; EvidenceKind = 'NormalDeadLetterCountOnly'; PlanFingerprint = $Context.planFingerprint
            UpgradeSourceFingerprint = $Context.plan.content.sourceFingerprint
            BaselineFingerprint = Get-GatewayUpgradeFingerprint $Context.plan.queueQuarantineBaseline
            ObservedAtUtc = [DateTimeOffset]::UtcNow.ToString('O'); Phase = $QueueQuarantinePhase
        }
        Assert-GatewayUpgradeQueueObservation $Context $observation $QueueQuarantinePhase
        return $observation
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
                if ($revision.properties.active -and -not (Test-GatewayUpgradeResourceId $revision.id $preSchemaId)) {
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
    Get-GatewayUpgradeCutoverInventory, ConvertTo-GatewayUpgradeCutoverNormalizedConfiguration, Assert-GatewayUpgradeCutoverHttpBoundary,
    Close-GatewayUpgradeCutover, Assert-GatewayUpgradeCutoverHeld, Set-GatewayUpgradeCutoverQueueHold,
    Get-GatewayUpgradeCutoverRevisions, New-GatewayUpgradeQueueQuarantineBaseline,
    Assert-GatewayUpgradeQueueQuarantineBaseline, Assert-GatewayUpgradeQueueObservation
