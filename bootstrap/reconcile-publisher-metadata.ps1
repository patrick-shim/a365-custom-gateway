#Requires -Version 7.0
<#
.SYNOPSIS
Reviews or receipts a bounded publisher metadata tooling reconciliation.
.DESCRIPTION
Plan and Execute perform provider readback only. Execute adds a separate local
receipt after exact confirmation; it does not advance publication or deployment.
Only a later independently authorized normal Resume may continue deployment.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Execute', 'AmendmentPlan', 'AmendmentExecute')][string]$Mode,
    [string]$Config = (Join-Path $PSScriptRoot 'config.json'),
    [string]$ExpectedPlanFingerprint = '',
    [switch]$Yes
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    foreach ($module in @('Common', 'Experience', 'Azure', 'Entra', 'PurviewPackage', 'PurviewExecutor', 'PublisherRecovery')) {
        Import-Module (Join-Path $PSScriptRoot "modules/$module.psm1") -Force -DisableNameChecking
    }
    $configuration = Read-BootstrapConfig -Path $Config
    if ($Mode -cin @('AmendmentPlan', 'AmendmentExecute')) {
        Invoke-BootstrapHostSettingsAmendment -Mode $Mode.Substring(9) -Config $configuration `
            -StatePath (Get-BootstrapStatePath -Config $configuration) -ExpectedPlanFingerprint $ExpectedPlanFingerprint -Yes:$Yes |
            ConvertTo-Json -Depth 5
    }
    else {
        Invoke-BootstrapPublisherMetadataReconciliation -Mode $Mode -Config $configuration `
            -StatePath (Get-BootstrapStatePath -Config $configuration) -ExpectedPlanFingerprint $ExpectedPlanFingerprint -Yes:$Yes |
            ConvertTo-Json -Depth 5
    }
}
catch {
    [Console]::Error.WriteLine('Publisher metadata reconciliation stopped. Preserve the original state and reviewed plan. No deployment continuation is authorized by this failure.')
    exit 1
}
