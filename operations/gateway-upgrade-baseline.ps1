#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$ExpectedStateSha256,
    [Parameter(Mandatory)][string]$ExpectedConfigSha256,
    [ValidateSet('B1', 'B2')][string]$AcceptedExecutorPlanSku
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1') -Force

try {
    $result = & (Get-Module GatewayUpgrade) {
        param($StatePath, $ConfigPath, $ExpectedStateSha256, $ExpectedConfigSha256, $AcceptedExecutorPlanSku)
        Assert-GatewayUpgradeHash $ExpectedStateSha256
        Assert-GatewayUpgradeHash $ExpectedConfigSha256
        foreach ($entry in @(@($StatePath, $ExpectedStateSha256), @($ConfigPath, $ExpectedConfigSha256))) {
            if ((Get-GatewayUpgradeFileHash $entry[0]) -cne $entry[1]) { throw 'Original input binding changed.' }
        }
        $inputs = @{ state = Read-GatewayUpgradeJson $StatePath; config = Read-GatewayUpgradeJson $ConfigPath }
        if (-not [string]::IsNullOrEmpty($AcceptedExecutorPlanSku)) {
            if (-not $inputs.state.Contains('freshPurviewExecutor')) {
                throw 'A hosting selection requires an existing Full executor installation.'
            }
            $inputs['acceptedExecutorPlanSku'] = $AcceptedExecutorPlanSku
        }
        $stateObjectHash = Get-GatewayUpgradeFingerprint $inputs.state
        try {
            $verification = Invoke-GatewayUpgradeCanonicalVerifierCore $inputs
            $result = @{
                status = 'Passed'; verifiedAtUtc = [string]$verification.verifiedAtUtc
                verifierResultFingerprint = Get-GatewayUpgradeFingerprint $verification
            }
            if ($inputs.Contains('acceptedExecutorPlanSku')) {
                $result['acceptedExecutorPlanSku'] = $verification.executorHostingSelection.currentSku
            }
            return $result
        }
        finally {
            if ((Get-GatewayUpgradeFileHash $StatePath) -cne $ExpectedStateSha256 -or
                (Get-GatewayUpgradeFileHash $ConfigPath) -cne $ExpectedConfigSha256 -or
                (Get-GatewayUpgradeFingerprint $inputs.state) -cne $stateObjectHash) {
                throw 'Original evidence changed during verification.'
            }
        }
    } $StatePath $ConfigPath $ExpectedStateSha256 $ExpectedConfigSha256 $AcceptedExecutorPlanSku
    [Console]::Out.WriteLine('A365GW_UPGRADE_BASELINE:' + (ConvertTo-Json -InputObject $result -Depth 10 -Compress))
}
catch {
    [Console]::Error.WriteLine('UpgradeBaseline: verification failed; provider output suppressed. Original history was not rewritten.')
    exit 1
}
