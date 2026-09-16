#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('ValidateRequest', 'Package', 'Prepare', 'Plan', 'Build', 'Execute', 'Verify', 'Rollback', 'RestoreSqlAdministrator', 'AbortPlan', 'AbortExecute', 'AbortReconcile')][string]$Mode,
    [string]$StatePath,
    [string]$ConfigPath,
    [string]$RequestPath,
    [string]$PlanPath,
    [string]$ExpectedPlanFingerprint,
    [string]$PackagingBaselineRoot,
    [string]$CandidateReceiptPath,
    [string]$ExpectedCandidateFingerprint,
    [string]$ValidationPath,
    [string]$ReviewPath,
    [string]$ArtifactBundlePath,
    [string]$RollbackContractPath,
    [string]$OriginalPlanPath,
    [string]$ExpectedOriginalPlanFingerprint,
    [string]$AbortPlanPath,
    [string]$ExpectedAbortPlanFingerprint
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradePackaging.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradePlan.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeExecution.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeSqlAdmission.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeAbort.psm1')

switch ($Mode) {
    AbortPlan {
        if (-not $OriginalPlanPath -or -not $ExpectedOriginalPlanFingerprint -or -not $StatePath -or -not $ConfigPath) {
            throw 'AbortPlan requires the exact original executable Plan and preserved original state/configuration.'
        }
        New-GatewayUpgradeAbortPlan -OriginalPlanPath $OriginalPlanPath -ExpectedOriginalPlanFingerprint $ExpectedOriginalPlanFingerprint `
            -StatePath $StatePath -ConfigPath $ConfigPath -WorkspaceRoot $root -ReviewPath $ReviewPath
    }
    { $_ -cin @('AbortExecute','AbortReconcile') } {
        if (-not $AbortPlanPath -or -not $ExpectedAbortPlanFingerprint) { throw 'Abort execution/reconciliation requires its separate exact approved Abort Plan.' }
        Invoke-GatewayUpgradeAbort -AbortPlanPath $AbortPlanPath -ExpectedAbortPlanFingerprint $ExpectedAbortPlanFingerprint `
            -WorkspaceRoot $root -Reconcile:($Mode -ceq 'AbortReconcile')
    }
    ValidateRequest {
        if (-not $StatePath -or -not $ConfigPath -or -not $RequestPath) {
            throw 'ValidateRequest requires preserved state/configuration and an explicit request; it never authenticates or creates a Plan.'
        }
        $request = Read-GatewayUpgradeJson $RequestPath
        $local = & (Get-Module GatewayUpgrade) {
            param($statePath, $configPath, $request)
            $inputs = Read-GatewayUpgradeBaselineInputs $statePath $configPath $request
            return @{ original = Get-GatewayUpgradeOriginalBinding $inputs; scope = Get-GatewayUpgradeScope $request $inputs.state }
        } $StatePath $ConfigPath $request
        Assert-GatewayUpgradeSqlAdmission -SourceRoot $root -Database $request.database `
            -Mode $(if ($request.schemaVersion -eq 2) { 'SourceOnlyFull' } else { 'CoreToFull' })
        [pscustomobject]@{
            status = 'LocalRequestValidated'; mode = $(if ($request.schemaVersion -eq 2) { $request.mode } else { 'CoreToFull' })
            original = $local.original; scope = $local.scope
            liveBaselineVerified = $false; compiledModelVerified = $false; buildSupported = $false; executionSupported = $false
        }
    }
    Package {
        if (-not $PackagingBaselineRoot) { throw 'Package requires the explicitly selected retained clean packaging baseline.' }
        New-GatewayUpgradeCandidate -WorkingRoot $root -PackagingBaselineRoot $PackagingBaselineRoot -WorkspaceRoot $root
    }
    Prepare {
        if (-not $CandidateReceiptPath -or -not $ExpectedCandidateFingerprint) { throw 'Prepare requires the exact candidate receipt and fingerprint.' }
        $validation = Prepare-GatewayUpgradeCandidate -ReceiptPath $CandidateReceiptPath `
            -ExpectedCandidateFingerprint $ExpectedCandidateFingerprint -WorkspaceRoot $root
        $directory = Join-Path $root '.maintenance\validation'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $path = Join-Path $directory "$([guid]::NewGuid().ToString('N')).json"
        $record = @{ schemaVersion = 1; fingerprint = Get-GatewayUpgradeFingerprint $validation; validation = $validation }
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $record -Depth 100))
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        [pscustomobject]@{ validationPath = $path; modelFingerprint = $validation.modelFingerprint; candidateFingerprint = $validation.candidateFingerprint }
    }
    Plan {
        if (-not $StatePath -or -not $ConfigPath -or -not $RequestPath -or -not $ValidationPath) {
            throw 'Plan requires original state/configuration, explicit request and local candidate validation.'
        }
        $validation = Read-GatewayUpgradeJson $ValidationPath
        if ($validation.schemaVersion -ne 1 -or
            (Get-GatewayUpgradeFingerprint $validation.validation) -cne $validation.fingerprint) {
            throw 'Local candidate validation integrity failed.'
        }
        $envelope = New-GatewayUpgradePlanV2 -Request (Read-GatewayUpgradeJson $RequestPath) -StatePath $StatePath `
            -ConfigPath $ConfigPath -Validation $validation.validation -ReviewPath $ReviewPath `
            -ArtifactBundlePath $ArtifactBundlePath -RollbackContractPath $RollbackContractPath
        $path = Save-GatewayUpgradePlan $envelope $root
        [pscustomobject]@{ planPath = $path; planFingerprint = $envelope.planFingerprint
            buildSupported = $envelope.plan.buildSupported; executionSupported = $envelope.plan.executionSupported }
    }
    default {
        if (($Mode -cne 'RestoreSqlAdministrator' -and (-not $StatePath -or -not $ConfigPath)) -or
            -not $PlanPath -or -not $ExpectedPlanFingerprint) {
            throw 'Build/Execute/Verify/Rollback require original state/configuration and the independently approved exact Plan fingerprint.'
        }
        Invoke-GatewayUpgradePipeline -Mode $Mode -Envelope (Read-GatewayUpgradeJson $PlanPath) `
            -ExpectedPlanFingerprint $ExpectedPlanFingerprint -StatePath ([string]$StatePath) -ConfigPath ([string]$ConfigPath) -WorkspaceRoot $root
    }
}
