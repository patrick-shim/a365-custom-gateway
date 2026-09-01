#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Start', 'Record', 'Checkpoint', 'Handoff', 'Complete', 'Show')]
    [string]$Action,

    [ValidateSet('Plan', 'Build', 'OfflineValidate', 'Deploy', 'LiveValidate', 'UpdateCheckpoint', 'Complete')]
    [string]$Gate = 'Plan',

    [ValidateSet('Intent', 'Result', 'Decision', 'Assignment', 'Receipt', 'Checkpoint', 'Handoff', 'Failure')]
    [string]$EventType = 'Result',

    [ValidateSet('InProgress', 'Passed', 'Failed', 'Blocked', 'Completed')]
    [string]$Status = 'InProgress',

    [string]$Objective = '',
    [string]$WorkItem = '',
    [string]$Actor = 'root',
    [string]$Recipient = '',
    [string]$Summary = '',
    [string]$NextAction = '',
    [string[]]$Files = @(),
    [string[]]$Evidence = @(),
    [string[]]$Blockers = @(),
    [int]$Tail = 30,
    [string]$RuntimeRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'DeliveryLedger.Core.psm1') -Force -DisableNameChecking
$schemaVersion = Get-DeliveryLedgerSchemaVersion
$maximumActiveAssignments = Get-MaximumActiveAssignments
$maximumRecentHandoffs = Get-MaximumRecentHandoffs

function Get-CurrentShardEvents {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Current
    )
    $sessionRoot = Get-SessionRoot -Root $Root -SessionId ([string]$Current.sessionId)
    $path = Join-Path (Join-Path $sessionRoot 'journal') ('{0:d4}.jsonl' -f [int]$Current.currentShard)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = $line | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
        if ($event -isnot [System.Collections.IDictionary] -or
            -not $event.Contains('sessionId') -or
            [string]$event.sessionId -cne [string]$Current.sessionId) {
            throw 'The current journal shard contains a malformed or cross-session event.'
        }
        Assert-DictionaryFingerprint -Value $event -Field 'eventFingerprint' -Label "Journal event $($event.sequence)"
        $events.Add($event)
    }
    if ($events.Count -gt 100) { throw 'The current journal shard exceeds the bounded 100-event contract.' }
    return @($events)
}

function New-AssignmentIndexEntry {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Event)
    return [ordered]@{
        workItem = [string]$Event.workItem
        owner = [string]$Event.recipient
        assignedBy = [string]$Event.actor
        assignedSequence = [int64]$Event.sequence
        startingCheckpointFingerprint = [string]$Event.priorCheckpointFingerprint
        boundaryRefs = @($Event.files)
        validationRefs = @($Event.evidence)
        stoppingCondition = [string]$Event.nextAction
    }
}

function Get-MatchingAssignments {
    param(
        [object[]]$Assignments,
        [Parameter(Mandatory)][string]$WorkItemId,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$AssignedBy
    )
    return @($Assignments | Where-Object {
        [string]$_.workItem -ceq $WorkItemId -and
        [string]$_.owner -ceq $Owner -and
        [string]$_.assignedBy -ceq $AssignedBy
    })
}

function Initialize-V2State {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Current,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest
    )
    $currentVersion = [int]$Current.schemaVersion
    $manifestVersion = [int]$Manifest.schemaVersion
    if ($currentVersion -gt $schemaVersion -or $manifestVersion -gt $schemaVersion) {
        throw 'The delivery ledger schema is newer than this recorder supports.'
    }
    if ($currentVersion -eq $schemaVersion -and $manifestVersion -eq $schemaVersion) {
        foreach ($name in @('manifestFingerprint', 'sourceBinding', 'activeAssignments', 'recentHandoffs')) {
            if (-not $Current.Contains($name)) { throw "CURRENT.json is missing schema-v2 field '$name'." }
        }
        foreach ($name in @('coordinator', 'sourceBinding', 'manifestFingerprint')) {
            if (-not $Manifest.Contains($name)) { throw "The manifest is missing schema-v2 field '$name'." }
        }
        Assert-DictionaryFingerprint -Value $Manifest.sourceBinding -Field 'sourceBindingFingerprint' -Label 'Manifest source binding'
        if ([string]$Current.manifestFingerprint -cne [string]$Manifest.manifestFingerprint -or
            [string]$Current.sourceBinding.sourceBindingFingerprint -cne [string]$Manifest.sourceBinding.sourceBindingFingerprint) {
            throw 'CURRENT.json is not bound to the active manifest and source checkpoint.'
        }
        return [ordered]@{ current = $Current; manifest = $Manifest; migrated = $false }
    }
    if ($currentVersion -ne 1 -and $manifestVersion -ne 1) {
        throw 'The active delivery ledger has an unsupported mixed schema state.'
    }

    $events = @(Get-CurrentShardEvents -Root $Root -Current $Current)
    $coordinator = [string]$Manifest.coordinator
    Assert-TokenText -Value $coordinator -Label 'Manifest coordinator' | Out-Null
    $active = [Collections.Generic.List[object]]::new()
    $recent = [Collections.Generic.List[object]]::new()
    $lastCoordinatorEvent = $null
    foreach ($event in $events) {
        if ([string]$event.actor -ceq $coordinator -and [string]$event.kind -cne 'Handoff') {
            $lastCoordinatorEvent = $event
        }
        if ([string]$event.kind -ceq 'Assignment' -and
            -not [string]::IsNullOrWhiteSpace([string]$event.recipient) -and
            @($event.files).Count -gt 0) {
            $duplicate = @(Get-MatchingAssignments -Assignments @($active) -WorkItemId ([string]$event.workItem) `
                -Owner ([string]$event.recipient) -AssignedBy ([string]$event.actor))
            if ($duplicate.Count -eq 0) { $active.Add((New-AssignmentIndexEntry -Event $event)) }
        }
        if ([string]$event.kind -ceq 'Handoff') {
            $matches = @(Get-MatchingAssignments -Assignments @($active) -WorkItemId ([string]$event.workItem) `
                -Owner ([string]$event.actor) -AssignedBy ([string]$event.recipient))
            foreach ($match in $matches) { $active.Remove($match) | Out-Null }
            $relative = "handoffs/$('{0:d6}' -f [int64]$event.sequence)-$(([string]$event.workItem) -replace '[^A-Za-z0-9._-]', '-').json"
            $handoffPath = Join-Path (Get-SessionRoot -Root $Root -SessionId ([string]$Current.sessionId)) $relative
            if (Test-Path -LiteralPath $handoffPath -PathType Leaf) {
                $recent.Add([ordered]@{
                    path = $relative
                    sequence = [int64]$event.sequence
                    workItem = [string]$event.workItem
                    from = [string]$event.actor
                    to = [string]$event.recipient
                    status = [string]$event.status
                    assignmentSequence = 0L
                    legacy = $true
                })
            }
        }
    }
    if ($active.Count -gt $maximumActiveAssignments) {
        throw 'The bounded v1 migration found too many active assignments in the current shard; the coordinator must close or reassign them explicitly.'
    }

    $sourceBinding = if ($manifestVersion -eq $schemaVersion -and $Manifest.Contains('sourceBinding')) {
        Copy-JsonValue -Value $Manifest.sourceBinding
    }
    else {
        Get-RepositorySourceBinding
    }
    Assert-DictionaryFingerprint -Value $sourceBinding -Field 'sourceBindingFingerprint' -Label 'Migrated source binding'

    $Manifest.schemaVersion = $schemaVersion
    $Manifest['sourceBinding'] = Copy-JsonValue -Value $sourceBinding
    if (-not $Manifest.Contains('upgradedFromSchemaVersion')) { $Manifest['upgradedFromSchemaVersion'] = 1 }
    if (-not $Manifest.Contains('upgradedAtUtc')) { $Manifest['upgradedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O') }
    Set-DictionaryFingerprint -Value $Manifest -Field 'manifestFingerprint' | Out-Null

    $Current.schemaVersion = $schemaVersion
    $Current.objective = [string]$Manifest.objective
    if ($null -ne $lastCoordinatorEvent) {
        $Current.gate = [string]$lastCoordinatorEvent.gate
        $Current.workItem = [string]$lastCoordinatorEvent.workItem
        $Current.summary = [string]$lastCoordinatorEvent.summary
        $Current.nextAction = [string]$lastCoordinatorEvent.nextAction
    }
    $Current['manifestFingerprint'] = [string]$Manifest.manifestFingerprint
    $Current['sourceBinding'] = Copy-JsonValue -Value $sourceBinding
    $Current['activeAssignments'] = @($active)
    $Current['recentHandoffs'] = @($recent | Select-Object -Last $maximumRecentHandoffs)
    $Current['upgradedFromSchemaVersion'] = 1
    if (@($Current.recentHandoffs).Count -gt 0) {
        $Current['latestHandoff'] = [string]$Current.recentHandoffs[-1].path
    }
    elseif ($Current.Contains('latestHandoff')) {
        $Current.Remove('latestHandoff')
    }
    Assert-CurrentFeasible -Current $Current | Out-Null
    return [ordered]@{ current = $Current; manifest = $Manifest; migrated = $true }
}

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Get-DefaultRuntimeRoot }
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$currentPath = Get-CurrentPath -Root $RuntimeRoot

if ($Action -ceq 'Show') {
    $current = Read-JsonDictionary -Path $currentPath
    Assert-CurrentFingerprint -Current $current
    $sessionRoot = Get-SessionRoot -Root $RuntimeRoot -SessionId ([string]$current.sessionId)
    $shardPath = Join-Path (Join-Path $sessionRoot 'journal') ('{0:d4}.jsonl' -f [int]$current.currentShard)
    $current | ConvertTo-Json -Depth 20
    if (Test-Path -LiteralPath $shardPath) { Get-Content -LiteralPath $shardPath -Tail ([Math]::Clamp($Tail, 1, 100)) }
    return
}

Invoke-WithLedgerLock -Root $RuntimeRoot -Body {
    if ($Action -ceq 'Start') {
        if (Test-Path -LiteralPath $currentPath) {
            $existing = Read-JsonDictionary -Path $currentPath
            Assert-CurrentFingerprint -Current $existing
            if ([string]$existing.status -ceq 'Active') {
                throw "Delivery session '$($existing.sessionId)' is already active; resume it instead of starting another."
            }
        }
        if ([string]::IsNullOrWhiteSpace($Objective)) { throw 'A new delivery session requires an objective.' }
        Assert-SafeText -Value $Objective -Label 'Objective' | Out-Null
        Assert-TokenText -Value $WorkItem -Label 'Work item' | Out-Null
        Assert-TokenText -Value $Actor -Label 'Actor' | Out-Null
        if ([string]::IsNullOrWhiteSpace($Summary)) { $Summary = $Objective }
        Assert-SafeText -Value $Summary -Label 'Summary' | Out-Null
        Assert-SafeText -Value $NextAction -Label 'Next action' | Out-Null
        $safeBlockers = @(ConvertTo-SafeStringArray -Values $Blockers -Label 'Blockers' -MaximumCount 12)
        $sourceBinding = Get-RepositorySourceBinding -RequireTrackedContinuation
        $sessionId = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $sessionRoot = Get-SessionRoot -Root $RuntimeRoot -SessionId $sessionId
        $now = [DateTimeOffset]::UtcNow.ToString('O')
        $manifest = [ordered]@{
            schemaVersion = $schemaVersion
            sessionId = $sessionId
            status = 'Active'
            createdAtUtc = $now
            objective = $Objective
            coordinator = $Actor
            sourceBinding = Copy-JsonValue -Value $sourceBinding
            releaseSequence = @('Plan', 'Build', 'OfflineValidate', 'Deploy', 'LiveValidate', 'UpdateCheckpoint', 'Complete')
        }
        Set-DictionaryFingerprint -Value $manifest -Field 'manifestFingerprint' | Out-Null
        $current = [ordered]@{
            schemaVersion = $schemaVersion
            sessionId = $sessionId
            status = 'Active'
            gate = $Gate
            lastSequence = 0L
            lastEventFingerprint = 'sha256:' + ('0' * 64)
            currentShard = 1
            shardEventCount = 0
            shardStartedAtUtc = $now
            objective = $Objective
            workItem = $WorkItem
            summary = $Summary
            blockers = @($safeBlockers)
            nextAction = $NextAction
            updatedAtUtc = $now
            manifestFingerprint = [string]$manifest.manifestFingerprint
            sourceBinding = Copy-JsonValue -Value $sourceBinding
            activeAssignments = @()
            recentHandoffs = @()
        }
        Set-CurrentFingerprint -Current $current | Out-Null
        $eventPlan = New-LedgerEventPlan -Root $RuntimeRoot -Current $current -Kind 'Checkpoint' -EventStatus 'InProgress' `
            -EventSummary $Summary -EventNextAction $NextAction -EventActor $Actor -EventRecipient '' `
            -EventWorkItem $WorkItem -EventGate $Gate -EventFiles @() `
            -EventEvidence @("source-binding=$($sourceBinding.sourceBindingFingerprint)")
        $current = $eventPlan.current
        Assert-CurrentFeasible -Current $current | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $sessionRoot 'journal')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $sessionRoot 'handoffs')) | Out-Null
        Write-AtomicJson -Path (Join-Path $sessionRoot 'manifest.json') -Value $manifest
        Write-LedgerEventPlan -Plan $eventPlan
        Write-Current -Path $currentPath -Current $current
        [pscustomobject]@{
            sessionId = $sessionId
            checkpointFingerprint = $current.checkpointFingerprint
            sourceBindingFingerprint = $sourceBinding.sourceBindingFingerprint
            currentPath = $currentPath
        }
        return
    }

    if ([string]::IsNullOrWhiteSpace($Summary)) { throw 'A bounded summary is required.' }
    Assert-TokenText -Value $Actor -Label 'Actor' | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Recipient)) { Assert-TokenText -Value $Recipient -Label 'Recipient' | Out-Null }
    Assert-SafeText -Value $Summary -Label 'Summary' | Out-Null
    Assert-SafeText -Value $NextAction -Label 'Next action' | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Objective)) { Assert-SafeText -Value $Objective -Label 'Objective' | Out-Null }
    $safeFiles = @(ConvertTo-SafeStringArray -Values $Files -Label 'Files')
    $safeEvidence = @(ConvertTo-SafeStringArray -Values $Evidence -Label 'Evidence')
    $safeBlockers = @(ConvertTo-SafeStringArray -Values $Blockers -Label 'Blockers' -MaximumCount 12)
    $kind = if ($Action -in @('Checkpoint', 'Complete', 'Handoff')) { $Action } else { $EventType }
    $eventStatus = if ($Action -ceq 'Complete') { 'Completed' } else { $Status }

    if ($kind -ceq 'Assignment') {
        if ([string]::IsNullOrWhiteSpace($Recipient)) { throw 'An assignment requires a recipient.' }
        if ($safeFiles.Count -eq 0) { throw 'An assignment requires an exact file or read-only boundary reference.' }
        if ($safeEvidence.Count -eq 0) { throw 'An assignment requires a validation reference.' }
        if ([string]::IsNullOrWhiteSpace($NextAction)) { throw 'An assignment requires a stopping condition in NextAction.' }
        $safeFiles = @(ConvertTo-SafeStringArray -Values $safeFiles -Label 'Assignment boundaries' `
            -MaximumCount 8 -MaximumEntryLength 240 -MaximumTotalLength 640)
        $safeEvidence = @(ConvertTo-SafeStringArray -Values $safeEvidence -Label 'Assignment validation' `
            -MaximumCount 4 -MaximumEntryLength 240 -MaximumTotalLength 400)
    }
    if ($kind -ceq 'Handoff') {
        if ([string]::IsNullOrWhiteSpace($Recipient)) { throw 'A handoff requires a recipient.' }
        if ($Status -ceq 'InProgress') { throw 'A handoff must report Passed, Failed, Blocked, or Completed status.' }
        if ($safeFiles.Count -eq 0 -or $safeEvidence.Count -eq 0 -or [string]::IsNullOrWhiteSpace($NextAction)) {
            throw 'A handoff requires files, validation evidence, and an exact next action.'
        }
    }

    $current = Read-JsonDictionary -Path $currentPath
    Assert-CurrentFingerprint -Current $current
    if ([string]$current.status -cne 'Active') { throw 'The current delivery session is completed; start a new session.' }
    if ([string]::IsNullOrWhiteSpace($WorkItem)) { $WorkItem = [string]$current.workItem }
    Assert-TokenText -Value $WorkItem -Label 'Work item' | Out-Null
    $sessionRoot = Get-SessionRoot -Root $RuntimeRoot -SessionId ([string]$current.sessionId)
    $manifestPath = Join-Path $sessionRoot 'manifest.json'
    $manifest = Read-JsonDictionary -Path $manifestPath
    Assert-DictionaryFingerprint -Value $manifest -Field 'manifestFingerprint' -Label 'Manifest'
    if ([string]$manifest.sessionId -cne [string]$current.sessionId) { throw 'The active manifest is not bound to CURRENT.json.' }

    $state = Initialize-V2State -Root $RuntimeRoot -Current $current -Manifest $manifest
    $current = $state.current
    $manifest = $state.manifest
    $coordinator = [string]$manifest.coordinator
    $isCoordinator = $Actor -ceq $coordinator
    if ($Action -in @('Checkpoint', 'Complete') -and -not $isCoordinator) {
        throw "Only manifest coordinator '$coordinator' may record $Action."
    }

    $activeAssignments = @($current.activeAssignments)
    $matchingAssignment = $null
    if ($kind -ceq 'Assignment') {
        if ($activeAssignments.Count -ge $maximumActiveAssignments) {
            throw "CURRENT.json already contains the maximum $maximumActiveAssignments active assignments."
        }
        $duplicate = @($activeAssignments | Where-Object { [string]$_.workItem -ceq $WorkItem })
        if ($duplicate.Count -gt 0) { throw "Work item '$WorkItem' already has an active assignment." }
    }
    if ($kind -ceq 'Handoff') {
        $matches = @(Get-MatchingAssignments -Assignments $activeAssignments -WorkItemId $WorkItem -Owner $Actor -AssignedBy $Recipient)
        if ($matches.Count -ne 1) {
            throw "Handoff '$WorkItem' requires exactly one matching active assignment for owner '$Actor' and recipient '$Recipient'."
        }
        $matchingAssignment = $matches[0]
    }

    $eventMetadata = [ordered]@{}
    if ($kind -ceq 'Handoff') {
        $safeWorkItem = $WorkItem -replace '[^A-Za-z0-9._-]', '-'
        $predictedSequence = [int64]$current.lastSequence + 1
        $handoffRelative = "handoffs/$('{0:d6}' -f $predictedSequence)-$safeWorkItem.json"
        $eventMetadata['assignmentSequence'] = [int64]$matchingAssignment.assignedSequence
        $eventMetadata['startingCheckpointFingerprint'] = [string]$matchingAssignment.startingCheckpointFingerprint
        $eventMetadata['handoffPath'] = $handoffRelative
    }
    $eventPlan = New-LedgerEventPlan -Root $RuntimeRoot -Current $current -Kind $kind -EventStatus $eventStatus `
        -EventSummary $Summary -EventNextAction $NextAction -EventActor $Actor -EventRecipient $Recipient `
        -EventWorkItem $WorkItem -EventGate $(if ($Action -ceq 'Complete') { 'Complete' } else { $Gate }) `
        -EventFiles $safeFiles -EventEvidence $safeEvidence -EventMetadata $eventMetadata
    $event = $eventPlan.event
    $current = $eventPlan.current

    if ($kind -ceq 'Assignment') {
        $entry = New-AssignmentIndexEntry -Event $event
        $current.activeAssignments = @($activeAssignments + @($entry))
    }
    if ($kind -ceq 'Handoff') {
        $remaining = @($activeAssignments | Where-Object {
            -not ([string]$_.workItem -ceq $WorkItem -and
                [string]$_.owner -ceq $Actor -and
                [string]$_.assignedBy -ceq $Recipient)
        })
        $current.activeAssignments = @($remaining)
        $handoffIndex = [ordered]@{
            path = [string]$event.handoffPath
            sequence = [int64]$event.sequence
            workItem = $WorkItem
            from = $Actor
            to = $Recipient
            status = $Status
            assignmentSequence = [int64]$matchingAssignment.assignedSequence
            legacy = $false
        }
        $current.recentHandoffs = @(@($current.recentHandoffs) + @($handoffIndex) | Select-Object -Last $maximumRecentHandoffs)
        $current['latestHandoff'] = [string]$event.handoffPath
    }

    $canUpdateCoordinatorCheckpoint = $isCoordinator -and $Action -in @('Record', 'Checkpoint', 'Complete')
    if ($canUpdateCoordinatorCheckpoint) {
        $current.gate = $(if ($Action -ceq 'Complete') { 'Complete' } else { $Gate })
        $current.workItem = $WorkItem
        $current.summary = $Summary
        $current.nextAction = $NextAction
        $current.blockers = @($safeBlockers)
        if (-not [string]::IsNullOrWhiteSpace($Objective)) {
            $current.objective = $Objective
            $manifest.objective = $Objective
        }
    }

    $manifestChanged = -not [string]::IsNullOrWhiteSpace($Objective) -and $canUpdateCoordinatorCheckpoint
    if ($Action -ceq 'Complete') {
        $current.status = 'Completed'
        $manifest.status = 'Completed'
        $manifest['completedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
        $manifestChanged = $true
    }
    if ($manifestChanged) {
        Set-DictionaryFingerprint -Value $manifest -Field 'manifestFingerprint' | Out-Null
        $current.manifestFingerprint = [string]$manifest.manifestFingerprint
    }

    Assert-CurrentFeasible -Current $current | Out-Null
    $handoff = $null
    if ($kind -ceq 'Handoff') {
        $handoff = [ordered]@{
            schemaVersion = $schemaVersion
            sessionId = [string]$current.sessionId
            sequence = [int64]$event.sequence
            eventFingerprint = [string]$event.eventFingerprint
            assignmentSequence = [int64]$matchingAssignment.assignedSequence
            workItem = $WorkItem
            from = $Actor
            to = $Recipient
            status = $Status
            summary = $Summary
            files = @($safeFiles)
            evidence = @($safeEvidence)
            blockers = @($safeBlockers)
            nextAction = $NextAction
            startingCheckpointFingerprint = [string]$matchingAssignment.startingCheckpointFingerprint
            endingCheckpointFingerprint = [string]$current.checkpointFingerprint
        }
        Set-DictionaryFingerprint -Value $handoff -Field 'handoffFingerprint' | Out-Null
        Assert-HandoffFeasible -Handoff $handoff | Out-Null
        if ([string]$handoff.eventFingerprint -cne [string]$event.eventFingerprint -or
            [string]$handoff.endingCheckpointFingerprint -cne [string]$current.checkpointFingerprint -or
            [string]$handoff.startingCheckpointFingerprint -cne [string]$event.startingCheckpointFingerprint) {
            throw 'The derived handoff is not bound to its planned journal event and checkpoint.'
        }
    }
    if ([string]$current.lastEventFingerprint -cne [string]$event.eventFingerprint -or
        [int64]$current.lastSequence -ne [int64]$event.sequence) {
        throw 'The derived CURRENT.json is not bound to its planned journal event.'
    }

    Write-LedgerEventPlan -Plan $eventPlan -Handoff $handoff
    if ($null -ne $handoff) {
        Write-AtomicJson -Path (Join-Path $sessionRoot ([string]$event.handoffPath)) -Value $handoff
    }
    if ($manifestChanged -or [bool]$state.migrated) { Write-AtomicJson -Path $manifestPath -Value $manifest }
    Write-Current -Path $currentPath -Current $current
    [pscustomobject]@{
        sessionId = [string]$current.sessionId
        sequence = [int64]$event.sequence
        eventFingerprint = [string]$event.eventFingerprint
        checkpointFingerprint = [string]$current.checkpointFingerprint
        gate = [string]$current.gate
        status = [string]$current.status
    }
}
