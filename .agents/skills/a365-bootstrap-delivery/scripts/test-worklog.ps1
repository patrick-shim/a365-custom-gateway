#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('a365-delivery-ledger-' + [guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $testRoot 'source'
$sourceScripts = Join-Path $sourceRoot '.agents/skills/a365-bootstrap-delivery/scripts'
$worklog = Join-Path $sourceScripts 'worklog.ps1'
$validator = Join-Path $sourceScripts 'validate-worklog.ps1'
$core = Join-Path $sourceScripts 'DeliveryLedger.Core.psm1'

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-Current {
    param([Parameter(Mandatory)][string]$Root)
    return Get-Content -LiteralPath (Join-Path $Root 'CURRENT.json') -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
}

function Get-GlobalCheckpointJson {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Current)
    $global = [ordered]@{
        objective = [string]$Current.objective
        gate = [string]$Current.gate
        workItem = [string]$Current.workItem
        summary = [string]$Current.summary
        nextAction = [string]$Current.nextAction
        blockers = @($Current.blockers)
    }
    return $global | ConvertTo-Json -Depth 10 -Compress
}

function Get-LedgerSnapshot {
    param([Parameter(Mandatory)][string]$Root)
    $lines = foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        "$relative=$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)"
    }
    return ($lines -join "`n")
}

function Invoke-Record {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Summary,
        [string]$EventType = 'Result',
        [string]$Status = 'Passed',
        [string]$Gate = 'OfflineValidate',
        [string]$Actor = 'coordinator',
        [string]$WorkItem = 'ledger-self-test',
        [string[]]$Blockers = @()
    )
    & $worklog -Action Record -RuntimeRoot $Root -EventType $EventType -Status $Status `
        -WorkItem $WorkItem -Actor $Actor -Gate $Gate -Summary $Summary -Blockers $Blockers `
        -NextAction 'Continue isolated validation.' | Out-Null
}

function Invoke-Assignment {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$WorkItem,
        [Parameter(Mandatory)][string]$Recipient
    )
    & $worklog -Action Record -RuntimeRoot $Root -EventType Assignment -Status InProgress `
        -WorkItem $WorkItem -Actor coordinator -Recipient $Recipient -Gate Build `
        -Summary "Assign bounded work item $WorkItem." -Files "boundary/$WorkItem" `
        -Evidence "validation/$WorkItem" -NextAction "Stop after validating $WorkItem and hand off to coordinator." | Out-Null
}

function Invoke-Handoff {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$WorkItem,
        [Parameter(Mandatory)][string]$Actor
    )
    & $worklog -Action Handoff -RuntimeRoot $Root -Status Passed -WorkItem $WorkItem `
        -Actor $Actor -Recipient coordinator -Gate OfflineValidate `
        -Summary "Completed bounded work item $WorkItem." -NextAction "Coordinator receipts $WorkItem." `
        -Files "boundary/$WorkItem" -Evidence "validation/$WorkItem passed" | Out-Null
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    & git -C $sourceRoot @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Local Git fixture command failed: git $($Arguments -join ' ')" }
}

function Convert-FixtureToSchemaV1 {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$RotateToEmptyTail
    )
    $currentPath = Join-Path $Root 'CURRENT.json'
    $current = Read-Current -Root $Root
    $sessionRoot = Join-Path (Join-Path $Root 'sessions') ([string]$current.sessionId)
    $previousEventFingerprint = 'sha256:' + ('0' * 64)
    foreach ($shardPath in @(Get-ChildItem -LiteralPath (Join-Path $sessionRoot 'journal') -Filter '*.jsonl' -File | Sort-Object Name)) {
        $convertedLines = [Collections.Generic.List[string]]::new()
        foreach ($line in Get-Content -LiteralPath $shardPath.FullName) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $event = $line | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
            $event.schemaVersion = 1
            if ([string]$event.kind -ceq 'Handoff') {
                foreach ($field in @('assignmentSequence', 'startingCheckpointFingerprint', 'handoffPath')) {
                    if ($event.Contains($field)) { $event.Remove($field) }
                }
            }
            $event.priorEventFingerprint = $previousEventFingerprint
            Set-DictionaryFingerprint -Value $event -Field eventFingerprint | Out-Null
            $previousEventFingerprint = [string]$event.eventFingerprint
            $convertedLines.Add(($event | ConvertTo-Json -Depth 20 -Compress))
        }
        [IO.File]::WriteAllLines($shardPath.FullName, $convertedLines, [Text.UTF8Encoding]::new($false))
    }
    foreach ($handoffPath in @(Get-ChildItem -LiteralPath (Join-Path $sessionRoot 'handoffs') -Filter '*.json' -File)) {
        $handoff = Read-JsonDictionary -Path $handoffPath.FullName
        $handoff.schemaVersion = 1
        foreach ($field in @('eventFingerprint', 'assignmentSequence')) {
            if ($handoff.Contains($field)) { $handoff.Remove($field) }
        }
        Set-DictionaryFingerprint -Value $handoff -Field handoffFingerprint | Out-Null
        Write-AtomicJson -Path $handoffPath.FullName -Value $handoff
    }
    $current.schemaVersion = 1
    $current.lastEventFingerprint = $previousEventFingerprint
    foreach ($field in @('manifestFingerprint', 'sourceBinding', 'activeAssignments', 'recentHandoffs',
            'upgradedFromSchemaVersion', 'upgradedAtUtc')) {
        if ($current.Contains($field)) { $current.Remove($field) }
    }
    if ($RotateToEmptyTail) {
        $current.currentShard = [int]$current.currentShard + 1
        $current.shardEventCount = 0
        $current.shardStartedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        [IO.File]::WriteAllText(
            (Join-Path (Join-Path $sessionRoot 'journal') ('{0:d4}.jsonl' -f [int]$current.currentShard)),
            '',
            [Text.UTF8Encoding]::new($false))
    }
    Set-CurrentFingerprint -Current $current | Out-Null
    Write-AtomicJson -Path $currentPath -Value $current

    $manifestPath = Join-Path $sessionRoot 'manifest.json'
    $manifest = Read-JsonDictionary -Path $manifestPath
    $manifest.schemaVersion = 1
    foreach ($field in @('sourceBinding', 'upgradedFromSchemaVersion', 'upgradedAtUtc')) {
        if ($manifest.Contains($field)) { $manifest.Remove($field) }
    }
    Set-DictionaryFingerprint -Value $manifest -Field manifestFingerprint | Out-Null
    Write-AtomicJson -Path $manifestPath -Value $manifest
}

try {
    [IO.Directory]::CreateDirectory($sourceScripts) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'docs')) | Out-Null
    foreach ($name in @('DeliveryLedger.Core.psm1', 'worklog.ps1', 'validate-worklog.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $sourceScripts $name)
    }
    $continuationPath = Join-Path $sourceRoot 'docs/agent-continuation.md'
    [IO.File]::WriteAllText($continuationPath, "# Agent continuation`n`nStart from this tracked checkpoint.`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $sourceRoot '.gitignore'), ".agent-runtime/`n", [Text.UTF8Encoding]::new($false))
    & git -C $sourceRoot init --quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the local Git fixture.' }
    Invoke-Git config user.email ledger-self-test@example.invalid
    Invoke-Git config user.name ledger-self-test
    Invoke-Git add -- .
    Invoke-Git commit --quiet -m initial
    $expectedHead = (& git -C $sourceRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the local Git fixture HEAD.' }
    $expectedContinuation = 'sha256:' + (Get-FileHash -LiteralPath $continuationPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $defaultRoot = Join-Path $sourceRoot '.agent-runtime/bootstrap-delivery'
    & $worklog -Action Start -Objective 'Exercise the sandbox-safe default runtime.' `
        -WorkItem 'default-root-test' -Actor coordinator -Gate Plan `
        -Summary 'Started a default-root ledger session.' -NextAction 'Validate the default-root session.' | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $defaultRoot 'CURRENT.json') -PathType Leaf) `
        'The default runtime was not created under .agent-runtime/bootstrap-delivery.'
    $defaultValidation = & $validator
    Assert-True ([bool]$defaultValidation.valid) 'The fresh default-root ledger did not validate.'

    $basicRoot = Join-Path $testRoot 'basic'
    & $worklog -Action Start -RuntimeRoot $basicRoot -Objective 'Exercise the bounded delivery ledger.' `
        -WorkItem 'ledger-self-test' -Actor coordinator -Gate Plan `
        -Summary 'Started an isolated ledger session.' -NextAction 'Exercise assignment and handoff recording.' | Out-Null
    $started = Read-Current -Root $basicRoot
    Assert-True ([int]$started.schemaVersion -eq 2) 'A new session did not use schema v2.'
    Assert-True ([string]$started.sourceBinding.gitHead -ceq $expectedHead) 'Git HEAD was not bound into CURRENT.json.'
    Assert-True ([string]$started.sourceBinding.checkoutState -ceq 'Clean') 'The clean Git fixture was not recorded as clean.'
    Assert-True ([bool]$started.sourceBinding.continuationTracked) 'The continuation checkpoint was not recorded as tracked.'
    Assert-True ([string]$started.sourceBinding.continuationFingerprint -ceq $expectedContinuation) 'The continuation fingerprint is incorrect.'

    $dirtyMarker = Join-Path $sourceRoot 'dirty-marker.txt'
    [IO.File]::WriteAllText($dirtyMarker, 'dirty fixture', [Text.UTF8Encoding]::new($false))
    $dirtyRoot = Join-Path $testRoot 'dirty'
    & $worklog -Action Start -RuntimeRoot $dirtyRoot -Objective 'Exercise dirty source disclosure.' `
        -WorkItem 'dirty-source-test' -Actor coordinator -Gate Plan `
        -Summary 'Started from an intentionally dirty fixture.' -NextAction 'Validate the dirty indicator.' | Out-Null
    $dirtyCurrent = Read-Current -Root $dirtyRoot
    Assert-True ([string]$dirtyCurrent.sourceBinding.checkoutState -ceq 'Dirty') 'A dirty checkout was not recorded as dirty.'
    Remove-Item -LiteralPath $dirtyMarker -Force
    $null = & $validator -RuntimeRoot $dirtyRoot

    $beforeFirstAssignment = Read-Current -Root $basicRoot
    Invoke-Assignment -Root $basicRoot -WorkItem task-one -Recipient agent-one
    $afterFirstAssignment = Read-Current -Root $basicRoot
    $taskOne = @($afterFirstAssignment.activeAssignments | Where-Object { [string]$_.workItem -ceq 'task-one' })[0]
    Assert-True ([string]$taskOne.startingCheckpointFingerprint -ceq [string]$beforeFirstAssignment.checkpointFingerprint) `
        'The assignment index did not preserve its prior checkpoint fingerprint.'

    Invoke-Assignment -Root $basicRoot -WorkItem task-two -Recipient agent-two
    $withTwoAssignments = Read-Current -Root $basicRoot
    Assert-True (@($withTwoAssignments.activeAssignments).Count -eq 2) 'Multiple active assignments overwrote each other.'
    $coordinatorCheckpoint = Get-GlobalCheckpointJson -Current $withTwoAssignments
    $sequenceBeforeDelegate = [int64]$withTwoAssignments.lastSequence
    Invoke-Record -Root $basicRoot -Summary 'Delegate progress must not replace coordinator state.' -EventType Intent `
        -Status InProgress -Gate Deploy -Actor agent-one -WorkItem task-one -Blockers 'delegate-local-blocker'
    $afterDelegate = Read-Current -Root $basicRoot
    Assert-True ((Get-GlobalCheckpointJson -Current $afterDelegate) -ceq $coordinatorCheckpoint) `
        'A delegate event replaced coordinator checkpoint fields.'
    Assert-True ([int64]$afterDelegate.lastSequence -eq $sequenceBeforeDelegate + 1) `
        'A delegate event did not advance journal sequence metadata.'

    $immediatePreHandoff = [string]$afterDelegate.checkpointFingerprint
    Invoke-Handoff -Root $basicRoot -WorkItem task-one -Actor agent-one
    $afterFirstHandoff = Read-Current -Root $basicRoot
    Assert-True (@($afterFirstHandoff.activeAssignments).Count -eq 1) 'A completed assignment was not removed from the active index.'
    Assert-True ([string]$afterFirstHandoff.activeAssignments[0].workItem -ceq 'task-two') 'The wrong active assignment remained.'
    Assert-True (@($afterFirstHandoff.recentHandoffs).Count -eq 1) 'The completed handoff was not indexed.'
    $sessionRoot = Join-Path (Join-Path $basicRoot 'sessions') ([string]$afterFirstHandoff.sessionId)
    $firstHandoffPath = Join-Path $sessionRoot ([string]$afterFirstHandoff.latestHandoff)
    $firstHandoff = Get-Content -LiteralPath $firstHandoffPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
    Assert-True ([string]$firstHandoff.startingCheckpointFingerprint -ceq [string]$taskOne.startingCheckpointFingerprint) `
        'The handoff did not propagate its assignment-start checkpoint.'
    Assert-True ([string]$firstHandoff.startingCheckpointFingerprint -cne $immediatePreHandoff) `
        'The handoff incorrectly used the immediate pre-handoff checkpoint.'
    Assert-True ([int64]$firstHandoff.assignmentSequence -eq [int64]$taskOne.assignedSequence) `
        'The handoff did not retain its assignment sequence.'

    $beforeMissingRecipient = Get-LedgerSnapshot -Root $basicRoot
    $missingRecipientRejected = $false
    try {
        & $worklog -Action Record -RuntimeRoot $basicRoot -EventType Assignment -Status InProgress `
            -WorkItem missing-recipient -Actor coordinator -Gate Build -Summary 'Reject this incomplete assignment.' `
            -Files boundary/missing -Evidence validation/missing -NextAction 'Stop.' | Out-Null
    }
    catch { $missingRecipientRejected = $true }
    Assert-True $missingRecipientRejected 'An assignment without a recipient was not rejected.'
    Assert-True ((Get-LedgerSnapshot -Root $basicRoot) -ceq $beforeMissingRecipient) `
        'A rejected assignment changed CURRENT.json or the journal.'

    $beforeMissingAssignment = Get-LedgerSnapshot -Root $basicRoot
    $missingAssignmentRejected = $false
    try {
        & $worklog -Action Handoff -RuntimeRoot $basicRoot -Status Passed -WorkItem no-assignment `
            -Actor ghost-agent -Recipient coordinator -Gate OfflineValidate -Summary 'Reject this unassigned handoff.' `
            -Files boundary/ghost -Evidence validation/ghost -NextAction 'Stop.' | Out-Null
    }
    catch { $missingAssignmentRejected = $true }
    Assert-True $missingAssignmentRejected 'A handoff without a matching assignment was not rejected.'
    Assert-True ((Get-LedgerSnapshot -Root $basicRoot) -ceq $beforeMissingAssignment) `
        'A rejected handoff changed CURRENT.json or the journal.'

    $oversizedCurrentRoot = Join-Path $testRoot 'oversized-current'
    & $worklog -Action Start -RuntimeRoot $oversizedCurrentRoot -Objective 'Reject oversized derived checkpoints atomically.' `
        -WorkItem 'oversized-current-test' -Actor coordinator -Gate Build `
        -Summary 'Started the oversized checkpoint fixture.' -NextAction 'Fill the bounded assignment index.' | Out-Null
    $oversizedCurrentRejected = $false
    for ($index = 1; $index -le 8 -and -not $oversizedCurrentRejected; $index++) {
        $beforeOversizedCurrent = Get-LedgerSnapshot -Root $oversizedCurrentRoot
        $boundaries = @(1..8 | ForEach-Object { "boundary-$index-$_-" + ('b' * 58) })
        $validations = @(1..4 | ForEach-Object { "validation-$index-$_-" + ('v' * 76) })
        try {
            & $worklog -Action Record -RuntimeRoot $oversizedCurrentRoot -EventType Assignment -Status InProgress `
                -WorkItem "large-assignment-$index" -Actor coordinator -Recipient "large-agent-$index" -Gate Build `
                -Summary "Assign large bounded work item $index." -Files $boundaries -Evidence $validations `
                -NextAction ("Complete large assignment $index after validation. " + ('n' * 1080)) | Out-Null
        }
        catch {
            if ($_.Exception.Message -notmatch 'CURRENT\.json.*16 KiB') { throw }
            $oversizedCurrentRejected = $true
            Assert-True ((Get-LedgerSnapshot -Root $oversizedCurrentRoot) -ceq $beforeOversizedCurrent) `
                'An oversized derived CURRENT.json appended or changed ledger state before rejection.'
        }
    }
    Assert-True $oversizedCurrentRejected 'Permitted assignment inputs never exercised the 16 KiB derived checkpoint rejection.'
    $null = & $validator -RuntimeRoot $oversizedCurrentRoot

    $oversizedHandoffRoot = Join-Path $testRoot 'oversized-handoff'
    & $worklog -Action Start -RuntimeRoot $oversizedHandoffRoot -Objective 'Reject oversized derived handoffs atomically.' `
        -WorkItem 'oversized-handoff-test' -Actor coordinator -Gate Build `
        -Summary 'Started the oversized handoff fixture.' -NextAction 'Assign one bounded handoff.' | Out-Null
    Invoke-Assignment -Root $oversizedHandoffRoot -WorkItem large-handoff -Recipient large-handoff-agent
    $beforeOversizedHandoff = Get-LedgerSnapshot -Root $oversizedHandoffRoot
    $handoffFiles = @(1..40 | ForEach-Object { "file-$_-" + ('f' * 290) })
    $handoffEvidence = @(1..40 | ForEach-Object { "evidence-$_-" + ('e' * 286) })
    $handoffBlockers = @(1..12 | ForEach-Object { "blocker-$_-" + ('r' * 480) })
    $oversizedHandoffRejected = $false
    try {
        & $worklog -Action Handoff -RuntimeRoot $oversizedHandoffRoot -Status Passed -WorkItem large-handoff `
            -Actor large-handoff-agent -Recipient coordinator -Gate OfflineValidate `
            -Summary ("Oversized handoff " + ('s' * 1180)) -Files $handoffFiles -Evidence $handoffEvidence `
            -Blockers $handoffBlockers -NextAction ("Review handoff " + ('a' * 1180)) | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch 'Handoff.*32 KiB') { throw }
        $oversizedHandoffRejected = $true
    }
    Assert-True $oversizedHandoffRejected 'Permitted handoff inputs did not exercise the 32 KiB derived handoff rejection.'
    Assert-True ((Get-LedgerSnapshot -Root $oversizedHandoffRoot) -ceq $beforeOversizedHandoff) `
        'An oversized derived handoff appended or changed ledger state before rejection.'
    $null = & $validator -RuntimeRoot $oversizedHandoffRoot

    Invoke-Handoff -Root $basicRoot -WorkItem task-two -Actor agent-two
    for ($index = 1; $index -le 13; $index++) {
        $item = "bounded-$index"
        $owner = "agent-$index"
        Invoke-Assignment -Root $basicRoot -WorkItem $item -Recipient $owner
        Invoke-Handoff -Root $basicRoot -WorkItem $item -Actor $owner
    }
    $bounded = Read-Current -Root $basicRoot
    Assert-True (@($bounded.activeAssignments).Count -eq 0) 'Completed assignments remained active.'
    Assert-True (@($bounded.recentHandoffs).Count -eq 12) 'The recent handoff index is not bounded to twelve entries.'
    $basic = & $validator -RuntimeRoot $basicRoot
    Assert-True ([bool]$basic.valid) 'The assignment and handoff ledger did not validate.'

    $beforeRedaction = Get-LedgerSnapshot -Root $basicRoot
    $redactionRejected = $false
    try { Invoke-Record -Root $basicRoot -Summary 'Authorization: Bearer synthetic-value-for-rejection' }
    catch { $redactionRejected = $true }
    Assert-True $redactionRejected 'Credential-like text was not rejected.'
    Assert-True ((Get-LedgerSnapshot -Root $basicRoot) -ceq $beforeRedaction) 'A redacted event changed the ledger.'

    $rotationRoot = Join-Path $testRoot 'rotation'
    & $worklog -Action Start -RuntimeRoot $rotationRoot -Objective 'Exercise deterministic journal rotation.' `
        -WorkItem 'ledger-self-test' -Actor coordinator -Gate Plan `
        -Summary 'Started the rotation session.' -NextAction 'Fill and rotate one shard.' | Out-Null
    for ($index = 1; $index -le 101; $index++) {
        Invoke-Record -Root $rotationRoot -Summary "Recorded bounded rotation event $index."
    }
    $rotation = & $validator -RuntimeRoot $rotationRoot
    Assert-True ([bool]$rotation.valid -and [int]$rotation.events -eq 102 -and [int]$rotation.shards -eq 2) `
        'Journal rotation did not preserve the expected 100-event shard boundary.'

    Import-Module $core -Force -DisableNameChecking
    $v1LegacyIndexRoot = Join-Path $testRoot 'v1-legacy-index'
    & $worklog -Action Start -RuntimeRoot $v1LegacyIndexRoot -Objective 'Exercise schema-v1 indexed handoff migration.' `
        -WorkItem 'v1-legacy-index-test' -Actor coordinator -Gate Build `
        -Summary 'Started the schema-v1 indexed handoff fixture.' -NextAction 'Create and migrate one legacy handoff.' | Out-Null
    Invoke-Assignment -Root $v1LegacyIndexRoot -WorkItem legacy-indexed-handoff -Recipient legacy-indexed-agent
    Invoke-Handoff -Root $v1LegacyIndexRoot -WorkItem legacy-indexed-handoff -Actor legacy-indexed-agent
    Convert-FixtureToSchemaV1 -Root $v1LegacyIndexRoot
    Invoke-Record -Root $v1LegacyIndexRoot -Summary 'Migrate a schema-v1 handoff in the bounded current shard.'
    $migratedLegacyIndex = Read-Current -Root $v1LegacyIndexRoot
    Assert-True (@($migratedLegacyIndex.recentHandoffs).Count -eq 1 -and
        [bool]$migratedLegacyIndex.recentHandoffs[0].legacy) `
        'Schema-v1 current-shard migration did not preserve one bounded legacy handoff index.'
    $null = & $validator -RuntimeRoot $v1LegacyIndexRoot
    $null = & $validator -RuntimeRoot $v1LegacyIndexRoot -FullAudit

    $v1EmptyTailRoot = Join-Path $testRoot 'v1-empty-tail'
    & $worklog -Action Start -RuntimeRoot $v1EmptyTailRoot -Objective 'Exercise bounded schema-v1 migration.' `
        -WorkItem 'v1-empty-tail-test' -Actor coordinator -Gate Build `
        -Summary 'Started the schema-v1 migration fixture.' -NextAction 'Create an older handoff and rotate.' | Out-Null
    Invoke-Assignment -Root $v1EmptyTailRoot -WorkItem legacy-handoff -Recipient legacy-agent
    Invoke-Handoff -Root $v1EmptyTailRoot -WorkItem legacy-handoff -Actor legacy-agent
    Convert-FixtureToSchemaV1 -Root $v1EmptyTailRoot -RotateToEmptyTail
    Invoke-Record -Root $v1EmptyTailRoot -Summary 'Migrate from the rotated empty current shard.'
    $migratedEmptyTail = Read-Current -Root $v1EmptyTailRoot
    Assert-True (-not $migratedEmptyTail.Contains('latestHandoff')) `
        'Schema-v1 empty-tail migration retained an older stale latestHandoff.'
    Assert-True (@($migratedEmptyTail.recentHandoffs).Count -eq 0) `
        'Schema-v1 empty-tail migration reconstructed handoffs outside the bounded current shard.'
    $null = & $validator -RuntimeRoot $v1EmptyTailRoot
    $null = & $validator -RuntimeRoot $v1EmptyTailRoot -FullAudit

    $boundedValidationRoot = Join-Path $testRoot 'bounded-validation'
    Copy-Item -LiteralPath $rotationRoot -Destination $boundedValidationRoot -Recurse
    $historicalShardPath = @(Get-ChildItem -Path (Join-Path $boundedValidationRoot 'sessions/*/journal/0001.jsonl') -File)[0].FullName
    $historicalShard = Get-Content -LiteralPath $historicalShardPath
    $historicalShard[0] = $historicalShard[0] -replace 'Started the rotation session', 'Tampered historical rotation event'
    [IO.File]::WriteAllLines($historicalShardPath, $historicalShard, [Text.UTF8Encoding]::new($false))
    $boundedValidation = & $validator -RuntimeRoot $boundedValidationRoot
    Assert-True ([string]$boundedValidation.validationScope -ceq 'Bounded') `
        'Normal validation did not report its bounded scope.'
    $fullAuditRejected = $false
    try { & $validator -RuntimeRoot $boundedValidationRoot -FullAudit | Out-Null }
    catch { $fullAuditRejected = $true }
    Assert-True $fullAuditRejected 'Full historical audit did not detect a tampered historical shard.'

    $lockPath = Join-Path $basicRoot '.writer.lock'
    $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $lockedValidationRejected = $false
    try {
        try { & $validator -RuntimeRoot $basicRoot | Out-Null }
        catch {
            if ($_.Exception.Message -notmatch 'writer lock') { throw }
            $lockedValidationRejected = $true
        }
    }
    finally {
        $lockStream.Dispose()
        if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force }
    }
    Assert-True $lockedValidationRejected 'Validation did not honor the ledger writer lock.'

    $handoffTamperRoot = Join-Path $testRoot 'handoff-tamper'
    Copy-Item -LiteralPath $basicRoot -Destination $handoffTamperRoot -Recurse
    $handoffTamperCurrent = Read-Current -Root $handoffTamperRoot
    $tamperSessionRoot = Join-Path (Join-Path $handoffTamperRoot 'sessions') ([string]$handoffTamperCurrent.sessionId)
    $indexedPath = Join-Path $tamperSessionRoot ([string]$handoffTamperCurrent.latestHandoff)
    $tamperedHandoff = Read-JsonDictionary -Path $indexedPath
    $tamperedHandoff.to = 'different-recipient'
    Set-DictionaryFingerprint -Value $tamperedHandoff -Field handoffFingerprint | Out-Null
    Write-AtomicJson -Path $indexedPath -Value $tamperedHandoff
    $handoffTamperRejected = $false
    try { & $validator -RuntimeRoot $handoffTamperRoot | Out-Null }
    catch { $handoffTamperRejected = $true }
    Assert-True $handoffTamperRejected 'A self-consistent but event-divergent handoff was not rejected.'

    $sourceTamperRoot = Join-Path $testRoot 'source-tamper'
    Copy-Item -LiteralPath $basicRoot -Destination $sourceTamperRoot -Recurse
    $sourceTamperCurrent = Read-Current -Root $sourceTamperRoot
    $sourceTamperCurrent.sourceBinding.checkoutState = 'Dirty'
    Set-DictionaryFingerprint -Value $sourceTamperCurrent.sourceBinding -Field sourceBindingFingerprint | Out-Null
    Set-CurrentFingerprint -Current $sourceTamperCurrent | Out-Null
    Write-AtomicJson -Path (Join-Path $sourceTamperRoot 'CURRENT.json') -Value $sourceTamperCurrent
    $sourceTamperRejected = $false
    try { & $validator -RuntimeRoot $sourceTamperRoot | Out-Null }
    catch { $sourceTamperRejected = $true }
    Assert-True $sourceTamperRejected 'Divergent CURRENT and manifest source bindings were not rejected.'

    $checkpointTamperRoot = Join-Path $testRoot 'checkpoint-tamper'
    Copy-Item -LiteralPath $basicRoot -Destination $checkpointTamperRoot -Recurse
    $checkpointPath = Join-Path $checkpointTamperRoot 'CURRENT.json'
    $tamperedCheckpoint = Read-Current -Root $checkpointTamperRoot
    $tamperedCheckpoint.summary = 'Tampered checkpoint summary.'
    Write-AtomicJson -Path $checkpointPath -Value $tamperedCheckpoint
    $checkpointTamperRejected = $false
    try { & $validator -RuntimeRoot $checkpointTamperRoot | Out-Null }
    catch { $checkpointTamperRejected = $true }
    Assert-True $checkpointTamperRejected 'Checkpoint tampering was not rejected.'

    [pscustomobject]@{
        passed = $true
        schemaVersion = [int]$basic.schemaVersion
        sourceBound = $true
        delegateIsolated = $true
        assignmentStartPropagated = $true
        atomicRejections = $missingRecipientRejected -and $missingAssignmentRejected -and
            $oversizedCurrentRejected -and $oversizedHandoffRejected
        defaultRuntimeRoot = $defaultRoot
        v1LegacyIndexValidated = [bool]$migratedLegacyIndex.recentHandoffs[0].legacy
        v1EmptyTailNormalized = -not $migratedEmptyTail.Contains('latestHandoff')
        boundedValidation = [string]$boundedValidation.validationScope
        lockedValidationRejected = $lockedValidationRejected
        fullAuditRejectedHistoricalTamper = $fullAuditRejected
        activeAssignments = [int]$basic.activeAssignments
        recentHandoffs = [int]$basic.recentHandoffs
        basicEvents = [int]$basic.events
        rotatedEvents = [int]$rotation.events
        rotatedShards = [int]$rotation.shards
        redactionRejected = $redactionRejected
        handoffTamperRejected = $handoffTamperRejected
        sourceTamperRejected = $sourceTamperRejected
        checkpointTamperRejected = $checkpointTamperRejected
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
