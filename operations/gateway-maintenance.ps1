#Requires -Version 7.0
<#
.SYNOPSIS
Creates or validates a separate read-only in-place upgrade review.
.DESCRIPTION
Does not run bootstrap, Resume, recovery, SQL, builds or deployments. Execute,
Verify (post-upgrade acceptance), and Rollback deliberately fail until their
reviewed integrations exist. Plan invokes the current canonical read-only
verifier without changing original bootstrap state or the selected CLI account.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'ValidatePlan', 'Execute', 'Verify', 'Rollback')][string]$Mode,
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$SourceRoot,
    [string]$RequestPath,
    [string]$PlanPath,
    [string]$ExpectedPlanFingerprint
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1') -Force

if ($Mode -ceq 'Plan') {
    if (-not $RequestPath -or $PlanPath -or $ExpectedPlanFingerprint) {
        throw 'Plan requires RequestPath only; it never accepts existing approval or overwrites a plan.'
    }
    $request = Read-GatewayUpgradeJson $RequestPath
    $envelope = New-GatewayUpgradePlan -Request $request -StatePath $StatePath -ConfigPath $ConfigPath -SourceRoot $SourceRoot
    $path = Save-GatewayUpgradePlan -Envelope $envelope -WorkspaceRoot (Split-Path -Parent $PSScriptRoot)
    [pscustomobject]@{ status = 'ReviewOnly'; planPath = $path; planFingerprint = $envelope.planFingerprint; executionSupported = $false }
}
else {
    if ($RequestPath -or -not $PlanPath -or -not $ExpectedPlanFingerprint) {
        throw 'Validation/stages require PlanPath and the independently selected ExpectedPlanFingerprint.'
    }
    $arguments = @{
        Envelope = Read-GatewayUpgradeJson $PlanPath
        ExpectedPlanFingerprint = $ExpectedPlanFingerprint
        StatePath = $StatePath; ConfigPath = $ConfigPath; SourceRoot = $SourceRoot
    }
    if ($Mode -ceq 'ValidatePlan') {
        $null = Test-GatewayUpgradePlan @arguments
        [pscustomobject]@{ status = 'LocalBindingValid'; currentLiveBaselineReverified = $false; executionSupported = $false }
    }
    else { Invoke-GatewayUpgradeStage -Mode $Mode @arguments }
}
