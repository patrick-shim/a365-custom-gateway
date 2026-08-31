#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$worklog = Join-Path $PSScriptRoot 'worklog.ps1'
$validator = Join-Path $PSScriptRoot 'validate-worklog.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('a365-delivery-ledger-' + [guid]::NewGuid().ToString('N'))

function Invoke-Record {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Summary,
        [string]$EventType = 'Result',
        [string]$Status = 'Passed',
        [string]$Gate = 'OfflineValidate'
    )
    & $worklog -Action Record -RuntimeRoot $Root -EventType $EventType -Status $Status `
        -WorkItem 'ledger-self-test' -Actor 'self-test' -Gate $Gate -Summary $Summary `
        -NextAction 'Continue isolated validation.' | Out-Null
}

try {
    $basicRoot = Join-Path $testRoot 'basic'
    & $worklog -Action Start -RuntimeRoot $basicRoot -Objective 'Exercise the bounded delivery ledger.' `
        -WorkItem 'ledger-self-test' -Actor 'self-test' -Gate Plan `
        -Summary 'Started an isolated ledger session.' -NextAction 'Exercise event and handoff recording.' | Out-Null
    Invoke-Record -Root $basicRoot -Summary 'Recorded one intent.' -EventType Intent -Status InProgress -Gate Build
    Invoke-Record -Root $basicRoot -Summary 'Recorded one observable result.' -Gate Build
    & $worklog -Action Handoff -RuntimeRoot $basicRoot -Status Passed -WorkItem 'ledger-self-test' `
        -Actor 'self-test-agent' -Recipient 'self-test' -Gate OfflineValidate `
        -Summary 'Recorded a bounded structured handoff.' -NextAction 'Validate ledger integrity.' `
        -Files '.agents/skills/a365-bootstrap-delivery/scripts/worklog.ps1' `
        -Evidence 'isolated-test-evidence' | Out-Null
    $basic = & $validator -RuntimeRoot $basicRoot
    if (-not $basic.valid -or $basic.events -ne 4 -or $basic.handoffs -ne 1) {
        throw 'Basic ledger validation did not return the expected event/handoff counts.'
    }

    $redactionRejected = $false
    try {
        Invoke-Record -Root $basicRoot -Summary 'Authorization: Bearer synthetic-value-for-rejection'
    }
    catch { $redactionRejected = $true }
    if (-not $redactionRejected) { throw 'Credential-like text was not rejected.' }
    $afterRedaction = & $validator -RuntimeRoot $basicRoot
    if ($afterRedaction.events -ne 4) { throw 'A rejected event changed the journal.' }

    $rotationRoot = Join-Path $testRoot 'rotation'
    & $worklog -Action Start -RuntimeRoot $rotationRoot -Objective 'Exercise deterministic journal rotation.' `
        -WorkItem 'ledger-self-test' -Actor 'self-test' -Gate Plan `
        -Summary 'Started the rotation session.' -NextAction 'Fill and rotate one shard.' | Out-Null
    for ($index = 1; $index -le 101; $index++) {
        Invoke-Record -Root $rotationRoot -Summary "Recorded bounded rotation event $index."
    }
    $rotation = & $validator -RuntimeRoot $rotationRoot
    if (-not $rotation.valid -or $rotation.events -ne 102 -or $rotation.shards -ne 2) {
        throw 'Journal rotation did not preserve the expected 100-event shard boundary.'
    }

    $tamperPath = Join-Path $basicRoot 'CURRENT.json'
    $tampered = [IO.File]::ReadAllText($tamperPath).Replace(
        'Recorded a bounded structured handoff.',
        'Tampered checkpoint summary.')
    [IO.File]::WriteAllText($tamperPath, $tampered, [Text.UTF8Encoding]::new($false))
    $tamperRejected = $false
    try { & $validator -RuntimeRoot $basicRoot | Out-Null }
    catch { $tamperRejected = $true }
    if (-not $tamperRejected) { throw 'Checkpoint tampering was not rejected.' }

    [pscustomobject]@{
        passed = $true
        basicEvents = $basic.events
        handoffs = $basic.handoffs
        rotatedEvents = $rotation.events
        rotatedShards = $rotation.shards
        redactionRejected = $redactionRejected
        tamperRejected = $tamperRejected
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
