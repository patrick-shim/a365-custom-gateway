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
        Assert-SafeText -Value $Objective -Label 'Objective' | Out-Null
        Assert-TokenText -Value $WorkItem -Label 'Work item' | Out-Null
        Assert-TokenText -Value $Actor -Label 'Actor' | Out-Null
        if ([string]::IsNullOrWhiteSpace($Summary)) { $Summary = $Objective }
        Assert-SafeText -Value $Summary -Label 'Summary' | Out-Null
        Assert-SafeText -Value $NextAction -Label 'Next action' | Out-Null
        $sessionId = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $sessionRoot = Get-SessionRoot -Root $RuntimeRoot -SessionId $sessionId
        [IO.Directory]::CreateDirectory((Join-Path $sessionRoot 'journal')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $sessionRoot 'handoffs')) | Out-Null
        $now = [DateTimeOffset]::UtcNow.ToString('O')
        $manifest = [ordered]@{
            schemaVersion = $schemaVersion
            sessionId = $sessionId
            status = 'Active'
            createdAtUtc = $now
            objective = $Objective
            coordinator = $Actor
            releaseSequence = @('Plan', 'Build', 'OfflineValidate', 'Deploy', 'LiveValidate', 'UpdateCheckpoint', 'Complete')
        }
        $manifestFingerprint = Get-ObjectFingerprint -Value $manifest
        $manifest['manifestFingerprint'] = $manifestFingerprint
        Write-AtomicJson -Path (Join-Path $sessionRoot 'manifest.json') -Value $manifest
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
            blockers = @()
            nextAction = $NextAction
            updatedAtUtc = $now
        }
        Set-CurrentFingerprint -Current $current | Out-Null
        $null = Add-LedgerEvent -Root $RuntimeRoot -Current $current -Kind 'Checkpoint' -EventStatus 'InProgress' `
            -EventSummary $Summary -EventNextAction $NextAction -EventActor $Actor -EventRecipient '' `
            -EventWorkItem $WorkItem -EventGate $Gate -EventFiles @() -EventEvidence @('session-start')
        Write-Current -Path $currentPath -Current $current
        [pscustomobject]@{ sessionId = $sessionId; checkpointFingerprint = $current.checkpointFingerprint; currentPath = $currentPath }
        return
    }

    $current = Read-JsonDictionary -Path $currentPath
    Assert-CurrentFingerprint -Current $current
    if ([string]$current.status -cne 'Active') { throw 'The current delivery session is completed; start a new session.' }
    if ([string]::IsNullOrWhiteSpace($WorkItem)) { $WorkItem = [string]$current.workItem }
    if ([string]::IsNullOrWhiteSpace($Summary)) { throw 'A bounded summary is required.' }
    Assert-TokenText -Value $WorkItem -Label 'Work item' | Out-Null
    Assert-TokenText -Value $Actor -Label 'Actor' | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Recipient)) { Assert-TokenText -Value $Recipient -Label 'Recipient' | Out-Null }
    Assert-SafeText -Value $Summary -Label 'Summary' | Out-Null
    Assert-SafeText -Value $NextAction -Label 'Next action' | Out-Null
    $safeFiles = ConvertTo-SafeStringArray -Values $Files -Label 'Files'
    $safeEvidence = ConvertTo-SafeStringArray -Values $Evidence -Label 'Evidence'
    $safeBlockers = ConvertTo-SafeStringArray -Values $Blockers -Label 'Blockers' -MaximumCount 12
    $kind = if ($Action -in @('Checkpoint', 'Complete', 'Handoff')) { $Action } else { $EventType }
    $eventStatus = if ($Action -ceq 'Complete') { 'Completed' } else { $Status }
    $event = Add-LedgerEvent -Root $RuntimeRoot -Current $current -Kind $kind -EventStatus $eventStatus `
        -EventSummary $Summary -EventNextAction $NextAction -EventActor $Actor -EventRecipient $Recipient `
        -EventWorkItem $WorkItem -EventGate $(if ($Action -ceq 'Complete') { 'Complete' } else { $Gate }) `
        -EventFiles $safeFiles -EventEvidence $safeEvidence
    $current.blockers = @($safeBlockers)

    if ($Action -ceq 'Handoff') {
        if ([string]::IsNullOrWhiteSpace($Recipient)) { throw 'A handoff requires a recipient.' }
        $safeWorkItem = $WorkItem -replace '[^A-Za-z0-9._-]', '-'
        $handoffRelative = "handoffs/$('{0:d6}' -f [int64]$event.sequence)-$safeWorkItem.json"
        $current['latestHandoff'] = $handoffRelative
        Set-CurrentFingerprint -Current $current | Out-Null
        $handoff = [ordered]@{
            schemaVersion = $schemaVersion
            sessionId = [string]$current.sessionId
            sequence = [int64]$event.sequence
            workItem = $WorkItem
            from = $Actor
            to = $Recipient
            status = $Status
            summary = $Summary
            files = @($safeFiles)
            evidence = @($safeEvidence)
            blockers = @($safeBlockers)
            nextAction = $NextAction
            startingCheckpointFingerprint = [string]$event.priorCheckpointFingerprint
            endingCheckpointFingerprint = [string]$current.checkpointFingerprint
        }
        $handoffFingerprint = Get-ObjectFingerprint -Value $handoff
        $handoff['handoffFingerprint'] = $handoffFingerprint
        $sessionRoot = Get-SessionRoot -Root $RuntimeRoot -SessionId ([string]$current.sessionId)
        Write-AtomicJson -Path (Join-Path $sessionRoot $handoffRelative) -Value $handoff
    }
    if ($Action -ceq 'Complete') {
        $current.status = 'Completed'
        $current.gate = 'Complete'
        $current.nextAction = $NextAction
        $manifestPath = Join-Path (Get-SessionRoot -Root $RuntimeRoot -SessionId ([string]$current.sessionId)) 'manifest.json'
        $manifest = Read-JsonDictionary -Path $manifestPath
        $manifest.status = 'Completed'
        $manifest['completedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
        $manifest.Remove('manifestFingerprint')
        $manifestFingerprint = Get-ObjectFingerprint -Value $manifest
        $manifest['manifestFingerprint'] = $manifestFingerprint
        Write-AtomicJson -Path $manifestPath -Value $manifest
    }
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
