Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SchemaVersion = 1
$script:MaximumCurrentBytes = 16KB
$script:MaximumShardBytes = 128KB
$script:MaximumShardEvents = 100
$script:MaximumShardAge = [TimeSpan]::FromHours(4)
$script:TextLimit = 1200

function Get-DeliveryLedgerSchemaVersion { return $script:SchemaVersion }

function Get-DefaultRuntimeRoot {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
    return Join-Path $repositoryRoot '.agents/runtime/bootstrap-delivery'
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
    param([string[]]$Values, [Parameter(Mandatory)][string]$Label, [int]$MaximumCount = 40)
    if ($Values.Count -gt $MaximumCount) { throw "$Label contains too many entries." }
    $result = [Collections.Generic.List[string]]::new()
    foreach ($value in $Values) {
        $text = Assert-SafeText -Value ([string]$value) -Label $Label -MaximumLength 500
        if (-not [string]::IsNullOrWhiteSpace($text)) { $result.Add($text) }
    }
    return @($result)
}

function Get-ObjectFingerprint {
    param([Parameter(Mandatory)]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 20 -Compress))
    try {
        $digest = [Security.Cryptography.SHA256]::HashData($bytes)
        return 'sha256:' + ([Convert]::ToHexString($digest)).ToLowerInvariant()
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Write-AtomicJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
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

function Set-CurrentFingerprint {
    param([System.Collections.IDictionary]$Current)
    if ($Current.Contains('checkpointFingerprint')) { $Current.Remove('checkpointFingerprint') }
    $fingerprint = Get-ObjectFingerprint -Value $Current
    $Current['checkpointFingerprint'] = $fingerprint
    return $Current
}

function Write-Current {
    param([string]$Path, [System.Collections.IDictionary]$Current)
    Set-CurrentFingerprint -Current $Current | Out-Null
    $json = $Current | ConvertTo-Json -Depth 20
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:MaximumCurrentBytes) {
        throw 'CURRENT.json exceeded its 16 KiB bounded checkpoint contract.'
    }
    Write-AtomicJson -Path $Path -Value $Current
}

function Assert-CurrentFingerprint {
    param([System.Collections.IDictionary]$Current)
    if (-not $Current.Contains('checkpointFingerprint')) { throw 'CURRENT.json has no checkpoint fingerprint.' }
    $recorded = [string]$Current.checkpointFingerprint
    $copy = [ordered]@{}
    foreach ($entry in $Current.GetEnumerator()) {
        if ([string]$entry.Key -cne 'checkpointFingerprint') { $copy[[string]$entry.Key] = $entry.Value }
    }
    if ($recorded -cne (Get-ObjectFingerprint -Value $copy)) { throw 'CURRENT.json fingerprint is invalid.' }
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
        [string[]]$EventEvidence
    )
    $now = [DateTimeOffset]::UtcNow
    $sessionRoot = Get-SessionRoot -Root $Root -SessionId ([string]$Current.sessionId)
    $journalRoot = Join-Path $sessionRoot 'journal'
    [IO.Directory]::CreateDirectory($journalRoot) | Out-Null
    $sequence = [int64]$Current.lastSequence + 1
    $event = [ordered]@{
        schemaVersion = $script:SchemaVersion
        sessionId = [string]$Current.sessionId
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
        priorCheckpointFingerprint = [string]$Current.checkpointFingerprint
        priorEventFingerprint = [string]$Current.lastEventFingerprint
    }
    $eventFingerprint = Get-ObjectFingerprint -Value $event
    $event['eventFingerprint'] = $eventFingerprint
    $line = ($event | ConvertTo-Json -Depth 20 -Compress) + [Environment]::NewLine

    $shardNumber = [int]$Current.currentShard
    $shardPath = Join-Path $journalRoot ('{0:d4}.jsonl' -f $shardNumber)
    $shardAge = $now - [DateTimeOffset]::Parse([string]$Current.shardStartedAtUtc)
    $existingBytes = if (Test-Path -LiteralPath $shardPath) { (Get-Item -LiteralPath $shardPath).Length } else { 0L }
    if ([int]$Current.shardEventCount -ge $script:MaximumShardEvents -or
        $existingBytes + [Text.Encoding]::UTF8.GetByteCount($line) -gt $script:MaximumShardBytes -or
        $shardAge -ge $script:MaximumShardAge) {
        $shardNumber++
        $shardPath = Join-Path $journalRoot ('{0:d4}.jsonl' -f $shardNumber)
        $Current.currentShard = $shardNumber
        $Current.shardEventCount = 0
        $Current.shardStartedAtUtc = $now.ToString('O')
    }
    [IO.File]::AppendAllText($shardPath, $line, [Text.UTF8Encoding]::new($false))
    $Current.lastSequence = $sequence
    $Current.lastEventFingerprint = [string]$event.eventFingerprint
    $Current.shardEventCount = [int]$Current.shardEventCount + 1
    $Current.updatedAtUtc = $now.ToString('O')
    $Current.gate = $EventGate
    $Current.workItem = $EventWorkItem
    $Current.summary = $EventSummary
    $Current.nextAction = $EventNextAction
    return $event
}

Export-ModuleMember -Function *
