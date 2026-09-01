Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SchemaVersion = 2
$script:MaximumCurrentBytes = 16KB
$script:MaximumHandoffBytes = 32KB
$script:MaximumShardBytes = 128KB
$script:MaximumShardEvents = 100
$script:MaximumShardAge = [TimeSpan]::FromHours(4)
$script:MaximumActiveAssignments = 8
$script:MaximumRecentHandoffs = 12
$script:TextLimit = 1200

function Get-DeliveryLedgerSchemaVersion { return $script:SchemaVersion }
function Get-MaximumActiveAssignments { return $script:MaximumActiveAssignments }
function Get-MaximumRecentHandoffs { return $script:MaximumRecentHandoffs }
function Get-MaximumCurrentBytes { return $script:MaximumCurrentBytes }
function Get-MaximumHandoffBytes { return $script:MaximumHandoffBytes }

function Get-RepositoryRoot {
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
}

function Get-DefaultRuntimeRoot {
    return Join-Path (Get-RepositoryRoot) '.agent-runtime/bootstrap-delivery'
}

function Assert-SafeText {
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Label,
        [int]$MaximumLength = $script:TextLimit
    )
    if ($Value.Length -gt $MaximumLength -or $Value.Contains([char]0)) {
        throw "$Label exceeds its bounded safe-text contract."
    }
    foreach ($pattern in @(
        '(?i)authorization\s*:\s*\S+',
        '(?i)\bbearer\s+[a-z0-9._~+\-/]+=*',
        '(?i)-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
        '(?i)\b(?:password|client[_ -]?secret|access[_ -]?token|refresh[_ -]?token|gateway[_ -]?key)\s*[:=]\s*[^\s,;]+',
        '(?i)(?:^|[?&])(?:sig|se|sp|sv|token)=[^&\s]+',
        '\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b',
        '\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}\b'
    )) {
        if ($Value -match $pattern) {
            throw "$Label resembles credential or content-bearing material and was not recorded."
        }
    }
    return $Value
}

function Assert-TokenText {
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Label,
        [int]$MaximumLength = 96
    )
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $MaximumLength -or
        $Value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]*$') {
        throw "$Label must be a bounded identifier."
    }
    return $Value
}

function ConvertTo-SafeStringArray {
    param(
        [string[]]$Values,
        [Parameter(Mandatory)][string]$Label,
        [int]$MaximumCount = 40,
        [int]$MaximumEntryLength = 500,
        [int]$MaximumTotalLength = 12000
    )
    if ($Values.Count -gt $MaximumCount) { throw "$Label contains too many entries." }
    $result = [Collections.Generic.List[string]]::new()
    $totalLength = 0
    foreach ($value in $Values) {
        $text = Assert-SafeText -Value ([string]$value) -Label $Label -MaximumLength $MaximumEntryLength
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $totalLength += $text.Length
            if ($totalLength -gt $MaximumTotalLength) { throw "$Label exceeds its bounded aggregate contract." }
            $result.Add($text)
        }
    }
    return @($result)
}

function Get-ObjectFingerprint {
    param([Parameter(Mandatory)]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 20 -Compress))
    try {
        $digest = [Security.Cryptography.SHA256]::HashData($bytes)
        return 'sha256:' + ([Convert]::ToHexString($digest)).ToLowerInvariant()
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Get-FileSha256Fingerprint {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required source file is missing: $Path" }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $digest = [Security.Cryptography.SHA256]::HashData($stream)
        return 'sha256:' + ([Convert]::ToHexString($digest)).ToLowerInvariant()
    }
    finally { $stream.Dispose() }
}

function Copy-JsonValue {
    param([Parameter(Mandatory)]$Value)
    return (ConvertTo-Json -InputObject $Value -Depth 20 -Compress |
        ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String)
}

function Get-JsonDocumentText {
    param([Parameter(Mandatory)]$Value)
    return ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine
}

function Assert-JsonDocumentSize {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][long]$MaximumBytes,
        [Parameter(Mandatory)][string]$Label
    )
    $bytes = [Text.Encoding]::UTF8.GetByteCount((Get-JsonDocumentText -Value $Value))
    if ($bytes -gt $MaximumBytes) { throw "$Label exceeded its $([int]($MaximumBytes / 1KB)) KiB bounded document contract." }
    return $bytes
}

function Write-AtomicJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = Get-JsonDocumentText -Value $Value
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Read-JsonDictionary {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required ledger file is missing: $Path" }
    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
    if ($value -isnot [System.Collections.IDictionary]) { throw "Ledger JSON is malformed: $Path" }
    return $value
}

function Invoke-WithLedgerLock {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$Body)
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $lockPath = Join-Path $Root '.writer.lock'
    $stream = $null
    for ($attempt = 0; $attempt -lt 100 -and $null -eq $stream; $attempt++) {
        try { $stream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
        catch [IO.IOException] { Start-Sleep -Milliseconds 50 }
    }
    if ($null -eq $stream) { throw 'The delivery ledger writer lock could not be acquired.' }
    try { return & $Body }
    finally {
        $stream.Dispose()
        if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force }
    }
}

function Get-CurrentPath { param([string]$Root) return Join-Path $Root 'CURRENT.json' }

function Get-SessionRoot {
    param([string]$Root, [string]$SessionId)
    return Join-Path (Join-Path $Root 'sessions') $SessionId
}

function Set-DictionaryFingerprint {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string]$Field
    )
    if ($Value.Contains($Field)) { $Value.Remove($Field) }
    $Value[$Field] = Get-ObjectFingerprint -Value $Value
    return $Value
}

function Assert-DictionaryFingerprint {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string]$Field,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not $Value.Contains($Field) -or [string]$Value[$Field] -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "$Label has no canonical $Field."
    }
    $recorded = [string]$Value[$Field]
    $copy = [ordered]@{}
    foreach ($entry in $Value.GetEnumerator()) {
        if ([string]$entry.Key -cne $Field) { $copy[[string]$entry.Key] = $entry.Value }
    }
    if ($recorded -cne (Get-ObjectFingerprint -Value $copy)) { throw "$Label $Field is invalid." }
}

function Set-CurrentFingerprint {
    param([System.Collections.IDictionary]$Current)
    Set-DictionaryFingerprint -Value $Current -Field 'checkpointFingerprint' | Out-Null
    return $Current
}

function Write-Current {
    param([string]$Path, [System.Collections.IDictionary]$Current)
    Assert-CurrentFeasible -Current $Current | Out-Null
    Write-AtomicJson -Path $Path -Value $Current
}

function Assert-CurrentFeasible {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Current)
    Set-CurrentFingerprint -Current $Current | Out-Null
    Assert-CurrentFingerprint -Current $Current
    Assert-JsonDocumentSize -Value $Current -MaximumBytes $script:MaximumCurrentBytes -Label 'CURRENT.json' | Out-Null
    return $Current
}

function Assert-HandoffFeasible {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Handoff)
    Assert-DictionaryFingerprint -Value $Handoff -Field 'handoffFingerprint' -Label 'Handoff'
    Assert-JsonDocumentSize -Value $Handoff -MaximumBytes $script:MaximumHandoffBytes -Label 'Handoff' | Out-Null
    return $Handoff
}

function Assert-CurrentFingerprint {
    param([System.Collections.IDictionary]$Current)
    Assert-DictionaryFingerprint -Value $Current -Field 'checkpointFingerprint' -Label 'CURRENT.json'
}

function Get-RepositorySourceBinding {
    param([switch]$RequireTrackedContinuation)

    $repositoryRoot = Get-RepositoryRoot
    $continuationRelative = 'docs/agent-continuation.md'
    $continuationPath = Join-Path $repositoryRoot $continuationRelative
    if (-not (Test-Path -LiteralPath $continuationPath -PathType Leaf)) {
        throw "The tracked continuation checkpoint is missing at '$continuationRelative'."
    }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) { throw 'Git is required to bind a delivery session to its checked-out source.' }

    $headLines = @(& $git.Source -C $repositoryRoot rev-parse --verify HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $headLines.Count -ne 1 -or [string]$headLines[0] -cnotmatch '^[0-9a-fA-F]{40,64}$') {
        throw 'The delivery ledger could not resolve the checked-out Git HEAD.'
    }
    $trackedLines = @(& $git.Source -C $repositoryRoot ls-files --error-unmatch -- $continuationRelative 2>$null)
    $continuationTracked = $LASTEXITCODE -eq 0 -and $trackedLines.Count -gt 0
    if ($RequireTrackedContinuation -and -not $continuationTracked) {
        throw "A new delivery session requires '$continuationRelative' to be tracked by Git."
    }
    $statusLines = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=normal 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'The delivery ledger could not determine whether the checkout is clean or dirty.' }

    $binding = [ordered]@{
        gitHead = ([string]$headLines[0]).ToLowerInvariant()
        checkoutState = $(if ($statusLines.Count -eq 0) { 'Clean' } else { 'Dirty' })
        continuationPath = $continuationRelative
        continuationFingerprint = Get-FileSha256Fingerprint -Path $continuationPath
        continuationTracked = [bool]$continuationTracked
    }
    Set-DictionaryFingerprint -Value $binding -Field 'sourceBindingFingerprint' | Out-Null
    return $binding
}

function New-LedgerEventPlan {
    param(
        [string]$Root,
        [System.Collections.IDictionary]$Current,
        [string]$Kind,
        [string]$EventStatus,
        [string]$EventSummary,
        [string]$EventNextAction,
        [string]$EventActor,
        [string]$EventRecipient,
        [string]$EventWorkItem,
        [string]$EventGate,
        [string[]]$EventFiles,
        [string[]]$EventEvidence,
        [System.Collections.IDictionary]$EventMetadata = @{}
    )
    $plannedCurrent = Copy-JsonValue -Value $Current
    $now = [DateTimeOffset]::UtcNow
    $sessionRoot = Get-SessionRoot -Root $Root -SessionId ([string]$Current.sessionId)
    $journalRoot = Join-Path $sessionRoot 'journal'
    $sequence = [int64]$plannedCurrent.lastSequence + 1
    $event = [ordered]@{
        schemaVersion = $script:SchemaVersion
        sessionId = [string]$plannedCurrent.sessionId
        sequence = $sequence
        timestampUtc = $now.ToString('O')
        kind = $Kind
        status = $EventStatus
        actor = $EventActor
        recipient = $EventRecipient
        workItem = $EventWorkItem
        gate = $EventGate
        summary = $EventSummary
        files = @($EventFiles)
        evidence = @($EventEvidence)
        nextAction = $EventNextAction
        priorCheckpointFingerprint = [string]$plannedCurrent.checkpointFingerprint
        priorEventFingerprint = [string]$plannedCurrent.lastEventFingerprint
    }
    foreach ($entry in $EventMetadata.GetEnumerator()) {
        $key = [string]$entry.Key
        if ($event.Contains($key) -or $key -ceq 'eventFingerprint') { throw "Event metadata key '$key' is reserved." }
        $event[$key] = $entry.Value
    }
    $event['eventFingerprint'] = Get-ObjectFingerprint -Value $event
    Assert-DictionaryFingerprint -Value $event -Field 'eventFingerprint' -Label "Journal event $sequence"
    $line = ($event | ConvertTo-Json -Depth 20 -Compress) + [Environment]::NewLine
    $lineBytes = [Text.Encoding]::UTF8.GetByteCount($line)
    if ($lineBytes -gt $script:MaximumShardBytes) {
        throw "Journal event $sequence exceeds the 128 KiB shard contract."
    }

    $shardNumber = [int]$plannedCurrent.currentShard
    $shardPath = Join-Path $journalRoot ('{0:d4}.jsonl' -f $shardNumber)
    $shardAge = $now - [DateTimeOffset]::Parse([string]$plannedCurrent.shardStartedAtUtc)
    $existingBytes = if (Test-Path -LiteralPath $shardPath) { (Get-Item -LiteralPath $shardPath).Length } else { 0L }
    if ([int]$plannedCurrent.shardEventCount -ge $script:MaximumShardEvents -or
        $existingBytes + $lineBytes -gt $script:MaximumShardBytes -or
        $shardAge -ge $script:MaximumShardAge) {
        $shardNumber++
        $shardPath = Join-Path $journalRoot ('{0:d4}.jsonl' -f $shardNumber)
        if ((Test-Path -LiteralPath $shardPath -PathType Leaf) -and (Get-Item -LiteralPath $shardPath).Length -gt 0) {
            throw "The planned journal shard '$([IO.Path]::GetFileName($shardPath))' already contains data."
        }
        $plannedCurrent.currentShard = $shardNumber
        $plannedCurrent.shardEventCount = 0
        $plannedCurrent.shardStartedAtUtc = $now.ToString('O')
    }
    $plannedCurrent.lastSequence = $sequence
    $plannedCurrent.lastEventFingerprint = [string]$event.eventFingerprint
    $plannedCurrent.shardEventCount = [int]$plannedCurrent.shardEventCount + 1
    $plannedCurrent.updatedAtUtc = $now.ToString('O')
    return [ordered]@{
        event = $event
        current = $plannedCurrent
        shardPath = $shardPath
        line = $line
    }
}

function Write-LedgerEventPlan {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [System.Collections.IDictionary]$Handoff
    )
    foreach ($field in @('event', 'current', 'shardPath', 'line')) {
        if (-not $Plan.Contains($field)) { throw "The ledger event plan is missing '$field'." }
    }
    $event = $Plan.event
    $current = $Plan.current
    Assert-DictionaryFingerprint -Value $event -Field 'eventFingerprint' -Label "Journal event $($event.sequence)"
    Assert-CurrentFeasible -Current $current | Out-Null
    if ([string]$event.sessionId -cne [string]$current.sessionId -or
        [int64]$event.sequence -ne [int64]$current.lastSequence -or
        [string]$event.eventFingerprint -cne [string]$current.lastEventFingerprint) {
        throw 'The planned journal event is not bound to its derived CURRENT.json state.'
    }
    if ([string]$event.kind -ceq 'Handoff') {
        if ($null -eq $Handoff) { throw 'A planned Handoff event requires its derived handoff document before append.' }
        Assert-HandoffFeasible -Handoff $Handoff | Out-Null
        if ([string]$Handoff.sessionId -cne [string]$event.sessionId -or
            [int64]$Handoff.sequence -ne [int64]$event.sequence -or
            [string]$Handoff.eventFingerprint -cne [string]$event.eventFingerprint -or
            [string]$Handoff.endingCheckpointFingerprint -cne [string]$current.checkpointFingerprint) {
            throw 'The planned handoff document is not bound to its journal event and derived CURRENT.json state.'
        }
    }
    elseif ($null -ne $Handoff) {
        throw 'A non-Handoff journal event cannot append a handoff document.'
    }
    $canonicalLine = ($event | ConvertTo-Json -Depth 20 -Compress) + [Environment]::NewLine
    if ([string]$Plan.line -cne $canonicalLine) { throw 'The planned journal line is not canonical.' }
    $directory = Split-Path -Parent ([string]$Plan.shardPath)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    [IO.File]::AppendAllText([string]$Plan.shardPath, $canonicalLine, [Text.UTF8Encoding]::new($false))
}

function Add-LedgerEvent {
    param(
        [string]$Root,
        [System.Collections.IDictionary]$Current,
        [string]$Kind,
        [string]$EventStatus,
        [string]$EventSummary,
        [string]$EventNextAction,
        [string]$EventActor,
        [string]$EventRecipient,
        [string]$EventWorkItem,
        [string]$EventGate,
        [string[]]$EventFiles,
        [string[]]$EventEvidence,
        [System.Collections.IDictionary]$EventMetadata = @{}
    )
    $plan = New-LedgerEventPlan @PSBoundParameters
    Write-LedgerEventPlan -Plan $plan
    $Current.Clear()
    foreach ($entry in $plan.current.GetEnumerator()) { $Current[[string]$entry.Key] = $entry.Value }
    return $plan.event
}

Export-ModuleMember -Function *
