#Requires -Version 7.0

[CmdletBinding()]
param([string]$RuntimeRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    return Get-Sha256 -Text ($Value | ConvertTo-Json -Depth 20 -Compress)
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

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
    $RuntimeRoot = Join-Path $repositoryRoot '.agents/runtime/bootstrap-delivery'
}
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$currentPath = Join-Path $RuntimeRoot 'CURRENT.json'
if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { throw 'CURRENT.json is missing.' }
if ((Get-Item -LiteralPath $currentPath).Length -gt 16KB) { throw 'CURRENT.json exceeds 16 KiB.' }

$current = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
foreach ($name in @('schemaVersion', 'sessionId', 'status', 'gate', 'lastSequence', 'lastEventFingerprint', 'currentShard', 'objective', 'workItem', 'summary', 'nextAction', 'checkpointFingerprint')) {
    if (-not $current.Contains($name)) { throw "CURRENT.json is missing '$name'." }
}
Assert-ObjectFingerprint -Value $current -Field 'checkpointFingerprint' -Label 'CURRENT.json'
Assert-NoSensitiveMaterial -Text (Get-Content -LiteralPath $currentPath -Raw) -Label 'CURRENT.json'
if ([string]$current.sessionId -cnotmatch '^\d{8}T\d{6}Z-[0-9a-f]{8}$' -or
    [string]$current.checkpointFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
    throw 'CURRENT.json contains an invalid session or checkpoint identifier.'
}

$sessionRoot = Join-Path (Join-Path $RuntimeRoot 'sessions') ([string]$current.sessionId)
$manifestPath = Join-Path $sessionRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The active manifest is missing.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
if ([string]$manifest.sessionId -cne [string]$current.sessionId -or
    [string]$manifest.manifestFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
    throw 'The active manifest is not bound to CURRENT.json.'
}
Assert-ObjectFingerprint -Value $manifest -Field 'manifestFingerprint' -Label 'Manifest'
Assert-NoSensitiveMaterial -Text (Get-Content -LiteralPath $manifestPath -Raw) -Label 'Manifest'

$journalRoot = Join-Path $sessionRoot 'journal'
$expectedSequence = 1L
$eventCount = 0
$previousEventFingerprint = 'sha256:' + ('0' * 64)
foreach ($shard in @(Get-ChildItem -LiteralPath $journalRoot -Filter '*.jsonl' -File | Sort-Object Name)) {
    if ($shard.Length -gt 128KB) { throw "Journal shard '$($shard.Name)' exceeds 128 KiB." }
    $shardEvents = 0
    foreach ($line in Get-Content -LiteralPath $shard.FullName) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = $line | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
        foreach ($name in @('sessionId', 'sequence', 'timestampUtc', 'kind', 'status', 'actor', 'workItem', 'gate', 'summary', 'eventFingerprint')) {
            if (-not $event.Contains($name)) { throw "Journal event is missing '$name'." }
        }
        if ([string]$event.sessionId -cne [string]$current.sessionId -or
            [int64]$event.sequence -ne $expectedSequence -or
            [string]$event.eventFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$event.priorEventFingerprint -cne $previousEventFingerprint) {
            throw "Journal sequence or binding failed at event $expectedSequence."
        }
        Assert-ObjectFingerprint -Value $event -Field 'eventFingerprint' -Label "Journal event $expectedSequence"
        Assert-NoSensitiveMaterial -Text $line -Label "Journal event $expectedSequence"
        $previousEventFingerprint = [string]$event.eventFingerprint
        $expectedSequence++
        $eventCount++
        $shardEvents++
    }
    if ($shardEvents -gt 100) { throw "Journal shard '$($shard.Name)' exceeds 100 events." }
}
if ($eventCount -ne [int64]$current.lastSequence) { throw 'CURRENT.json lastSequence does not match the journal.' }
if ([string]$current.lastEventFingerprint -cne $previousEventFingerprint) { throw 'CURRENT.json lastEventFingerprint does not match the journal chain.' }

foreach ($handoffPath in @(Get-ChildItem -LiteralPath (Join-Path $sessionRoot 'handoffs') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    if ($handoffPath.Length -gt 32KB) { throw "Handoff '$($handoffPath.Name)' exceeds 32 KiB." }
    $handoff = Get-Content -LiteralPath $handoffPath.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
    if ([string]$handoff.sessionId -cne [string]$current.sessionId -or
        [string]$handoff.handoffFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "Handoff '$($handoffPath.Name)' is malformed or cross-session."
    }
    Assert-ObjectFingerprint -Value $handoff -Field 'handoffFingerprint' -Label "Handoff '$($handoffPath.Name)'"
    Assert-NoSensitiveMaterial -Text (Get-Content -LiteralPath $handoffPath.FullName -Raw) -Label "Handoff '$($handoffPath.Name)'"
}

[pscustomobject]@{
    valid = $true
    sessionId = [string]$current.sessionId
    status = [string]$current.status
    gate = [string]$current.gate
    events = $eventCount
    shards = @(Get-ChildItem -LiteralPath $journalRoot -Filter '*.jsonl' -File).Count
    handoffs = @(Get-ChildItem -LiteralPath (Join-Path $sessionRoot 'handoffs') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
}
