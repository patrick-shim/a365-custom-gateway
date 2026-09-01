#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$RuntimeRoot = '',
    [switch]$FullAudit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$maximumSchemaVersion = 2
$maximumActiveAssignments = 8
$maximumRecentHandoffs = 12

Import-Module (Join-Path $PSScriptRoot 'DeliveryLedger.Core.psm1') -Force -DisableNameChecking

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    try {
        $digest = [Security.Cryptography.SHA256]::HashData($bytes)
        return 'sha256:' + ([Convert]::ToHexString($digest)).ToLowerInvariant()
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Get-ObjectFingerprint {
    param([Parameter(Mandatory)]$Value)
    return Get-Sha256 -Text (ConvertTo-Json -InputObject $Value -Depth 20 -Compress)
}

function Assert-ObjectFingerprint {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string]$Field,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not $Value.Contains($Field) -or [string]$Value[$Field] -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "$Label has no canonical $Field."
    }
    $copy = [ordered]@{}
    foreach ($entry in $Value.GetEnumerator()) {
        if ([string]$entry.Key -cne $Field) { $copy[[string]$entry.Key] = $entry.Value }
    }
    if ([string]$Value[$Field] -cne (Get-ObjectFingerprint -Value $copy)) {
        throw "$Label $Field does not match its content."
    }
}

function Assert-NoSensitiveMaterial {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Label)
    foreach ($pattern in @(
        '(?i)authorization\s*:\s*\S+',
        '(?i)\bbearer\s+[a-z0-9._~+\-/]+=*',
        '(?i)-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
        '(?i)\b(?:password|client[_ -]?secret|access[_ -]?token|refresh[_ -]?token|gateway[_ -]?key)\s*[:=]\s*[^\s,;]+',
        '(?i)(?:^|[?&])(?:sig|se|sp|sv|token)=[^&\s]+',
        '\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b',
        '\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}\b'
    )) {
        if ($Text -match $pattern) { throw "$Label contains credential-like material." }
    }
}

function Assert-RequiredFields {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$Fields,
        [Parameter(Mandatory)][string]$Label
    )
    foreach ($name in $Fields) {
        if (-not $Value.Contains($name)) { throw "$Label is missing '$name'." }
    }
}

function Test-JsonEqual {
    param($Left, $Right)
    return (Get-ObjectFingerprint -Value $Left) -ceq (Get-ObjectFingerprint -Value $Right)
}

function Assert-SourceBinding {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Binding, [Parameter(Mandatory)][string]$Label)
    Assert-RequiredFields -Value $Binding `
        -Fields @('gitHead', 'checkoutState', 'continuationPath', 'continuationFingerprint', 'continuationTracked', 'sourceBindingFingerprint') `
        -Label $Label
    Assert-ObjectFingerprint -Value $Binding -Field 'sourceBindingFingerprint' -Label $Label
    if ([string]$Binding.gitHead -cnotmatch '^[0-9a-f]{40,64}$' -or
        [string]$Binding.checkoutState -notin @('Clean', 'Dirty') -or
        [string]$Binding.continuationPath -cne 'docs/agent-continuation.md' -or
        [string]$Binding.continuationFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        $Binding.continuationTracked -isnot [bool]) {
        throw "$Label contains an invalid Git or continuation binding."
    }
}

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $RuntimeRoot = Get-DefaultRuntimeRoot
}
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$validationResult = Invoke-WithLedgerLock -Root $RuntimeRoot -Body {
$currentPath = Join-Path $RuntimeRoot 'CURRENT.json'
if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { throw 'CURRENT.json is missing.' }
if ((Get-Item -LiteralPath $currentPath).Length -gt 16KB) { throw 'CURRENT.json exceeds 16 KiB.' }

$currentRaw = Get-Content -LiteralPath $currentPath -Raw
$current = $currentRaw | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
Assert-RequiredFields -Value $current `
    -Fields @('schemaVersion', 'sessionId', 'status', 'gate', 'lastSequence', 'lastEventFingerprint', 'currentShard',
        'shardEventCount', 'shardStartedAtUtc', 'objective', 'workItem', 'summary', 'nextAction', 'checkpointFingerprint') `
    -Label 'CURRENT.json'
if ([int]$current.schemaVersion -lt 1 -or [int]$current.schemaVersion -gt $maximumSchemaVersion) {
    throw 'CURRENT.json uses an unsupported schema version.'
}
Assert-ObjectFingerprint -Value $current -Field 'checkpointFingerprint' -Label 'CURRENT.json'
Assert-NoSensitiveMaterial -Text $currentRaw -Label 'CURRENT.json'
if ([string]$current.sessionId -cnotmatch '^\d{8}T\d{6}Z-[0-9a-f]{8}$' -or
    [string]$current.checkpointFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
    throw 'CURRENT.json contains an invalid session or checkpoint identifier.'
}

$sessionRoot = Join-Path (Join-Path $RuntimeRoot 'sessions') ([string]$current.sessionId)
$manifestPath = Join-Path $sessionRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The active manifest is missing.' }
$manifestRaw = Get-Content -LiteralPath $manifestPath -Raw
$manifest = $manifestRaw | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
Assert-RequiredFields -Value $manifest -Fields @('schemaVersion', 'sessionId', 'status', 'objective', 'coordinator', 'manifestFingerprint') -Label 'Manifest'
if ([int]$manifest.schemaVersion -lt 1 -or [int]$manifest.schemaVersion -gt $maximumSchemaVersion -or
    [string]$manifest.sessionId -cne [string]$current.sessionId -or
    [string]$manifest.manifestFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
    throw 'The active manifest is not bound to CURRENT.json.'
}
Assert-ObjectFingerprint -Value $manifest -Field 'manifestFingerprint' -Label 'Manifest'
Assert-NoSensitiveMaterial -Text $manifestRaw -Label 'Manifest'

$isV2 = [int]$current.schemaVersion -eq 2 -or [int]$manifest.schemaVersion -eq 2
if ($isV2) {
    if ([int]$current.schemaVersion -ne 2 -or [int]$manifest.schemaVersion -ne 2) {
        throw 'CURRENT.json and its manifest have an incomplete schema-v2 migration.'
    }
    Assert-RequiredFields -Value $current -Fields @('manifestFingerprint', 'sourceBinding', 'activeAssignments', 'recentHandoffs') -Label 'CURRENT.json'
    Assert-RequiredFields -Value $manifest -Fields @('sourceBinding') -Label 'Manifest'
    Assert-SourceBinding -Binding $current.sourceBinding -Label 'CURRENT source binding'
    Assert-SourceBinding -Binding $manifest.sourceBinding -Label 'Manifest source binding'
    if ([string]$current.manifestFingerprint -cne [string]$manifest.manifestFingerprint -or
        -not (Test-JsonEqual -Left $current.sourceBinding -Right $manifest.sourceBinding)) {
        throw 'CURRENT.json source provenance does not match its manifest.'
    }
    if (@($current.activeAssignments).Count -gt $maximumActiveAssignments) { throw 'CURRENT.json has too many active assignments.' }
    if (@($current.recentHandoffs).Count -gt $maximumRecentHandoffs) { throw 'CURRENT.json has too many recent handoffs.' }
}

$journalRoot = Join-Path $sessionRoot 'journal'
$currentShardName = '{0:d4}.jsonl' -f [int]$current.currentShard
$shards = @(if ($FullAudit) {
    Get-ChildItem -LiteralPath $journalRoot -Filter '*.jsonl' -File | Sort-Object Name
}
else {
    $currentShardPath = Join-Path $journalRoot $currentShardName
    if (-not (Test-Path -LiteralPath $currentShardPath -PathType Leaf)) {
        throw "The current journal shard '$currentShardName' is missing."
    }
    Get-Item -LiteralPath $currentShardPath
})
if ($shards.Count -eq 0) { throw 'The active journal has no shards.' }
$expectedSequence = if ($FullAudit) { 1L } else { [int64]$current.lastSequence - [int64]$current.shardEventCount + 1L }
$eventCount = 0
$previousEventFingerprint = if ($FullAudit) { 'sha256:' + ('0' * 64) } else { '' }
$eventsBySequence = @{}
$handoffEvents = [Collections.Generic.List[object]]::new()
$lastShardEventCount = 0
for ($shardIndex = 0; $shardIndex -lt $shards.Count; $shardIndex++) {
    $shard = $shards[$shardIndex]
    $expectedName = if ($FullAudit) { '{0:d4}.jsonl' -f ($shardIndex + 1) } else { $currentShardName }
    if ($shard.Name -cne $expectedName) { throw "Journal shard '$($shard.Name)' is not contiguous." }
    if ($shard.Length -gt 128KB) { throw "Journal shard '$($shard.Name)' exceeds 128 KiB." }
    $shardEvents = 0
    $firstTimestamp = $null
    $lastTimestamp = $null
    foreach ($line in Get-Content -LiteralPath $shard.FullName) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = $line | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
        Assert-RequiredFields -Value $event `
            -Fields @('schemaVersion', 'sessionId', 'sequence', 'timestampUtc', 'kind', 'status', 'actor', 'recipient',
                'workItem', 'gate', 'summary', 'files', 'evidence', 'nextAction', 'priorCheckpointFingerprint',
                'priorEventFingerprint', 'eventFingerprint') `
            -Label "Journal event $expectedSequence"
        if ([int]$event.schemaVersion -lt 1 -or [int]$event.schemaVersion -gt $maximumSchemaVersion -or
            [string]$event.sessionId -cne [string]$current.sessionId -or
            [int64]$event.sequence -ne $expectedSequence -or
            [string]$event.eventFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$event.priorCheckpointFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$event.priorEventFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            (($FullAudit -or $eventCount -gt 0) -and [string]$event.priorEventFingerprint -cne $previousEventFingerprint)) {
            throw "Journal sequence or binding failed at event $expectedSequence."
        }
        Assert-ObjectFingerprint -Value $event -Field 'eventFingerprint' -Label "Journal event $expectedSequence"
        Assert-NoSensitiveMaterial -Text $line -Label "Journal event $expectedSequence"
        $timestamp = [DateTimeOffset]::Parse([string]$event.timestampUtc)
        if ($null -eq $firstTimestamp) { $firstTimestamp = $timestamp }
        $lastTimestamp = $timestamp
        if ([int]$event.schemaVersion -eq 2 -and [string]$event.kind -ceq 'Assignment') {
            if ([string]::IsNullOrWhiteSpace([string]$event.recipient) -or @($event.files).Count -eq 0 -or
                @($event.evidence).Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$event.nextAction)) {
                throw "Schema-v2 assignment event $expectedSequence is incomplete."
            }
        }
        if ([int]$event.schemaVersion -eq 2 -and [string]$event.kind -ceq 'Handoff') {
            Assert-RequiredFields -Value $event `
                -Fields @('assignmentSequence', 'startingCheckpointFingerprint', 'handoffPath') `
                -Label "Schema-v2 handoff event $expectedSequence"
            if ([int64]$event.assignmentSequence -lt 1 -or
                [string]$event.startingCheckpointFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
                [string]$event.handoffPath -cnotmatch '^handoffs/[0-9]{6}-[A-Za-z0-9._-]+\.json$') {
                throw "Schema-v2 handoff event $expectedSequence has invalid assignment metadata."
            }
        }
        $eventsBySequence[[string]$event.sequence] = $event
        if ([string]$event.kind -ceq 'Handoff') { $handoffEvents.Add($event) }
        $previousEventFingerprint = [string]$event.eventFingerprint
        $expectedSequence++
        $eventCount++
        $shardEvents++
    }
    if ($shardEvents -gt 100) { throw "Journal shard '$($shard.Name)' exceeds 100 events." }
    if ($null -ne $firstTimestamp -and $lastTimestamp - $firstTimestamp -ge [TimeSpan]::FromHours(4)) {
        throw "Journal shard '$($shard.Name)' spans four hours or more."
    }
    $lastShardEventCount = $shardEvents
}
if ($FullAudit) {
    if ($eventCount -ne [int64]$current.lastSequence) { throw 'CURRENT.json lastSequence does not match the journal.' }
    if ([int]$current.currentShard -ne $shards.Count -or [int]$current.shardEventCount -ne $lastShardEventCount) {
        throw 'CURRENT.json shard metadata does not match the active journal.'
    }
}
elseif ($eventCount -ne [int]$current.shardEventCount -or $shards[0].Name -cne $currentShardName) {
    throw 'CURRENT.json current-shard metadata does not match the bounded journal snapshot.'
}
if ($eventCount -gt 0 -and [string]$current.lastEventFingerprint -cne $previousEventFingerprint) {
    throw 'CURRENT.json lastEventFingerprint does not match the journal chain.'
}

$handoffRoot = Join-Path $sessionRoot 'handoffs'
$handoffFiles = @{}
$handoffPaths = @(if ($FullAudit) {
    Get-ChildItem -LiteralPath $handoffRoot -Filter '*.json' -File -ErrorAction SilentlyContinue
}
elseif ($isV2) {
    $current.recentHandoffs | ForEach-Object {
        $relative = [string]$_.path
        if ($relative -cnotmatch '^handoffs/[0-9]{6}-[A-Za-z0-9._-]+\.json$') {
            throw "Recent handoff index '$relative' has an invalid path."
        }
        $path = Join-Path $sessionRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Recent handoff index '$relative' has no handoff file."
        }
        Get-Item -LiteralPath $path
    }
}
else { @() })
foreach ($handoffPath in $handoffPaths) {
    if ($handoffPath.Length -gt 32KB) { throw "Handoff '$($handoffPath.Name)' exceeds 32 KiB." }
    $handoffRaw = Get-Content -LiteralPath $handoffPath.FullName -Raw
    $handoff = $handoffRaw | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
    Assert-RequiredFields -Value $handoff `
        -Fields @('schemaVersion', 'sessionId', 'handoffFingerprint') `
        -Label "Handoff '$($handoffPath.Name)'"
    if ([int]$handoff.schemaVersion -lt 1 -or [int]$handoff.schemaVersion -gt $maximumSchemaVersion -or
        [string]$handoff.sessionId -cne [string]$current.sessionId -or
        [string]$handoff.handoffFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "Handoff '$($handoffPath.Name)' is malformed or cross-session."
    }
    Assert-ObjectFingerprint -Value $handoff -Field 'handoffFingerprint' -Label "Handoff '$($handoffPath.Name)'"
    Assert-NoSensitiveMaterial -Text $handoffRaw -Label "Handoff '$($handoffPath.Name)'"
    if ([int]$handoff.schemaVersion -eq 2) {
        Assert-RequiredFields -Value $handoff `
            -Fields @('sequence', 'workItem', 'from', 'to', 'status', 'eventFingerprint', 'assignmentSequence',
                'startingCheckpointFingerprint', 'endingCheckpointFingerprint') `
            -Label "Schema-v2 handoff '$($handoffPath.Name)'"
    }
    $relative = "handoffs/$($handoffPath.Name)"
    $handoffFiles[$relative] = $handoff
}

foreach ($event in $handoffEvents) {
    if ([int]$event.schemaVersion -ne 2) { continue }
    $relative = [string]$event.handoffPath
    $assignmentKey = [string][int64]$event.assignmentSequence
    if (-not $eventsBySequence.ContainsKey($assignmentKey)) {
        if ($FullAudit) { throw "Schema-v2 handoff event $($event.sequence) has no assignment event." }
        if (-not $handoffFiles.ContainsKey($relative)) { continue }
    }
    if ($eventsBySequence.ContainsKey($assignmentKey)) {
        $assignmentEvent = $eventsBySequence[$assignmentKey]
        if ([int64]$assignmentEvent.sequence -ge [int64]$event.sequence -or
            [string]$assignmentEvent.kind -cne 'Assignment' -or
            [string]$assignmentEvent.workItem -cne [string]$event.workItem -or
            [string]$assignmentEvent.recipient -cne [string]$event.actor -or
            [string]$assignmentEvent.actor -cne [string]$event.recipient -or
            [string]$assignmentEvent.priorCheckpointFingerprint -cne [string]$event.startingCheckpointFingerprint) {
            throw "Schema-v2 handoff event $($event.sequence) does not match its assignment event."
        }
    }
    if (-not $handoffFiles.ContainsKey($relative)) {
        if ($FullAudit) { throw "Schema-v2 handoff event $($event.sequence) has no handoff file." }
        continue
    }
    $handoff = $handoffFiles[$relative]
    Assert-RequiredFields -Value $handoff `
        -Fields @('eventFingerprint', 'assignmentSequence', 'startingCheckpointFingerprint', 'endingCheckpointFingerprint') `
        -Label "Schema-v2 handoff '$relative'"
    if ([int64]$handoff.sequence -ne [int64]$event.sequence -or
        [string]$handoff.eventFingerprint -cne [string]$event.eventFingerprint -or
        [int64]$handoff.assignmentSequence -ne [int64]$event.assignmentSequence -or
        [string]$handoff.startingCheckpointFingerprint -cne [string]$event.startingCheckpointFingerprint -or
        [string]$handoff.endingCheckpointFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        [string]$handoff.workItem -cne [string]$event.workItem -or
        [string]$handoff.from -cne [string]$event.actor -or
        [string]$handoff.to -cne [string]$event.recipient -or
        [string]$handoff.status -cne [string]$event.status) {
        throw "Schema-v2 handoff '$relative' does not match its journal event."
    }
}

if ($isV2) {
    $activeKeys = @{}
    foreach ($assignment in @($current.activeAssignments)) {
        if ($assignment -isnot [System.Collections.IDictionary]) { throw 'An active assignment index is malformed.' }
        Assert-RequiredFields -Value $assignment `
            -Fields @('workItem', 'owner', 'assignedBy', 'assignedSequence', 'startingCheckpointFingerprint',
                'boundaryRefs', 'validationRefs', 'stoppingCondition') `
            -Label 'Active assignment'
        $key = "$($assignment.workItem)|$($assignment.owner)|$($assignment.assignedBy)"
        if ($activeKeys.ContainsKey($key)) { throw "Active assignment '$key' is duplicated." }
        $activeKeys[$key] = $true
        $sequenceKey = [string][int64]$assignment.assignedSequence
        if (-not $eventsBySequence.ContainsKey($sequenceKey)) {
            if ($FullAudit) { throw "Active assignment '$key' has no assignment event." }
        }
        else {
            $event = $eventsBySequence[$sequenceKey]
            if ([string]$event.kind -cne 'Assignment' -or
                [string]$event.workItem -cne [string]$assignment.workItem -or
                [string]$event.recipient -cne [string]$assignment.owner -or
                [string]$event.actor -cne [string]$assignment.assignedBy -or
                [string]$event.priorCheckpointFingerprint -cne [string]$assignment.startingCheckpointFingerprint -or
                -not (Test-JsonEqual -Left @($event.files) -Right @($assignment.boundaryRefs)) -or
                -not (Test-JsonEqual -Left @($event.evidence) -Right @($assignment.validationRefs)) -or
                [string]$event.nextAction -cne [string]$assignment.stoppingCondition) {
                throw "Active assignment '$key' does not match its assignment event."
            }
        }
        $completed = @($handoffEvents | Where-Object {
            [int64]$_.sequence -gt [int64]$assignment.assignedSequence -and
            [string]$_.workItem -ceq [string]$assignment.workItem -and
            [string]$_.actor -ceq [string]$assignment.owner -and
            [string]$_.recipient -ceq [string]$assignment.assignedBy
        })
        if ($completed.Count -gt 0) { throw "Completed assignment '$key' remains active in CURRENT.json." }
    }

    $recentPaths = @{}
    $previousRecentSequence = 0L
    foreach ($index in @($current.recentHandoffs)) {
        if ($index -isnot [System.Collections.IDictionary]) { throw 'A recent handoff index is malformed.' }
        Assert-RequiredFields -Value $index `
            -Fields @('path', 'sequence', 'workItem', 'from', 'to', 'status', 'assignmentSequence', 'legacy') `
            -Label 'Recent handoff index'
        $relative = [string]$index.path
        if ($relative -cnotmatch '^handoffs/[0-9]{6}-[A-Za-z0-9._-]+\.json$' -or
            $recentPaths.ContainsKey($relative) -or
            [int64]$index.sequence -le $previousRecentSequence) {
            throw "Recent handoff index '$relative' is invalid, duplicated, or out of order."
        }
        $recentPaths[$relative] = $true
        $previousRecentSequence = [int64]$index.sequence
        $sequenceKey = [string][int64]$index.sequence
        if (-not $handoffFiles.ContainsKey($relative)) {
            throw "Recent handoff index '$relative' has no handoff file."
        }
        $handoff = $handoffFiles[$relative]
        if ([int64]$handoff.sequence -ne [int64]$index.sequence -or
            [string]$handoff.workItem -cne [string]$index.workItem -or
            [string]$handoff.from -cne [string]$index.from -or
            [string]$handoff.to -cne [string]$index.to -or
            [string]$handoff.status -cne [string]$index.status -or
            (-not [bool]$index.legacy -and
                (-not $handoff.Contains('assignmentSequence') -or
                    [int64]$handoff.assignmentSequence -ne [int64]$index.assignmentSequence))) {
            throw "Recent handoff index '$relative' does not match its handoff file."
        }
        if (-not $eventsBySequence.ContainsKey($sequenceKey)) {
            if ($FullAudit) { throw "Recent handoff index '$relative' has no journal event." }
        }
        else {
            $event = $eventsBySequence[$sequenceKey]
            if ([string]$event.kind -cne 'Handoff' -or
                [string]$event.workItem -cne [string]$index.workItem -or
                [string]$event.actor -cne [string]$index.from -or
                [string]$event.recipient -cne [string]$index.to -or
                [string]$event.status -cne [string]$index.status -or
                (-not [bool]$index.legacy -and
                    (-not $handoff.Contains('eventFingerprint') -or
                        [string]$handoff.eventFingerprint -cne [string]$event.eventFingerprint))) {
                throw "Recent handoff index '$relative' does not match its journal event."
            }
        }
        if (-not [bool]$index.legacy) {
            if ([int64]$handoff.assignmentSequence -ne [int64]$index.assignmentSequence -or
                [string]$handoff.startingCheckpointFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
                throw "Schema-v2 recent handoff index '$relative' is not assignment-bound."
            }
            if ($eventsBySequence.ContainsKey($sequenceKey) -and
                ([int]$event.schemaVersion -ne 2 -or
                    [string]$event.handoffPath -cne $relative -or
                    [int64]$event.assignmentSequence -ne [int64]$index.assignmentSequence)) {
                throw "Schema-v2 recent handoff index '$relative' is not bound to its journal event."
            }
        }
    }
    if (@($current.recentHandoffs).Count -gt 0) {
        if (-not $current.Contains('latestHandoff') -or
            [string]$current.latestHandoff -cne [string]$current.recentHandoffs[-1].path) {
            throw 'CURRENT.json latestHandoff does not match the bounded recent handoff index.'
        }
    }
    elseif ($current.Contains('latestHandoff') -and -not [string]::IsNullOrWhiteSpace([string]$current.latestHandoff)) {
        throw 'CURRENT.json names a latest handoff without a recent handoff index.'
    }

    if ($FullAudit -and -not $current.Contains('upgradedFromSchemaVersion')) {
        $expectedRecent = @($handoffEvents | Select-Object -Last $maximumRecentHandoffs | ForEach-Object { [string]$_.handoffPath })
        $actualRecent = @($current.recentHandoffs | ForEach-Object { [string]$_.path })
        if (-not (Test-JsonEqual -Left $expectedRecent -Right $actualRecent)) {
            throw 'CURRENT.json recent handoffs are not the bounded tail of the session handoff events.'
        }
    }
}

[pscustomobject]@{
    valid = $true
    validationScope = $(if ($FullAudit) { 'FullAudit' } else { 'Bounded' })
    schemaVersion = [int]$current.schemaVersion
    sessionId = [string]$current.sessionId
    status = [string]$current.status
    gate = [string]$current.gate
    events = [int64]$current.lastSequence
    eventsValidated = $eventCount
    shards = [int]$current.currentShard
    shardsValidated = $shards.Count
    handoffs = $(if ($FullAudit) { $handoffFiles.Count } elseif ($isV2) { @($current.recentHandoffs).Count } else { 0 })
    activeAssignments = $(if ($isV2) { @($current.activeAssignments).Count } else { 0 })
    recentHandoffs = $(if ($isV2) { @($current.recentHandoffs).Count } else { 0 })
}
}
$validationResult
