#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('Common','Experience','Runtime')) {
    Import-Module "$PSScriptRoot/../modules/$name.psm1" -Force -DisableNameChecking
}

# Every combination must present both integrations, including declining both.
& (Get-Module Experience) {
    function script:Write-Host { }
    function script:Read-GatewayChoice { param($Prompt,$Choices,$DefaultIndex) return $Choices[0] }
    function script:Read-GatewayYesNo {
        param($Prompt,$Default)
        $script:questions.Add($Prompt)
        if ($Prompt -like 'Enable development agent registration*') { return $false }
        if ($Prompt -like 'Provision Azure AI Content Safety*') { return $script:contentSafety }
        if ($Prompt -like 'Set up the Microsoft Purview connection*') { return $script:purview }
        if ($Prompt -like 'Acknowledge*' -or $Prompt -like 'Authorize setup*') { return $true }
        throw 'Unexpected setup question.'
    }
    foreach ($contentSafety in @($false,$true)) {
        foreach ($purview in @($false,$true)) {
            $script:contentSafety=$contentSafety; $script:purview=$purview
            $script:questions=[Collections.Generic.List[string]]::new()
            $result=Read-GatewayBootstrapCapabilities -Environment dev
            if ($result.promptShield.enabled -ne $contentSafety -or $result.purview.enabled -ne $purview -or
                @($script:questions | Where-Object {$_ -like 'Provision Azure AI Content Safety*'}).Count -ne 1 -or
                @($script:questions | Where-Object {$_ -like 'Set up the Microsoft Purview connection*'}).Count -ne 1 -or
                $result.promptShield.costAndQuotaAcknowledged -ne $contentSafety -or
                $result.purview.authorityRequirementsAcknowledged -ne $purview) {
                throw 'Setup skipped an integration choice or inferred consent.'
            }
        }
    }
}

$fixture=Join-Path ([IO.Path]::GetTempPath()) ('gateway-setup-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $config=Get-Content "$PSScriptRoot/../config.example.runtime.json" -Raw | ConvertFrom-Json -AsHashtable
    $config.promptShield.enabled=$false
    $config.promptShield.costAndQuotaAcknowledged=$false
    foreach($name in @('subscriptionId','resourceGroupName','location')) { $config.Remove($name) }
    $config.purview.enabled=$true
    $config.purview.authorityRequirementsAcknowledged=$true
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fixture
    $read=Read-BootstrapConfig -Path $fixture
    if ($read.subscriptionId -ne '' -or -not $read.purview.enabled) { throw 'Purview-only setup must not require an Azure subscription.' }
    foreach ($oldField in @('collectionPolicyName','dlpPolicyName','sensitiveInformationTypeId','policyProvisioningEnabled')) {
        $config.purview[$oldField]='old'
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fixture
        $rejected=$false
        try { Read-BootstrapConfig -Path $fixture | Out-Null } catch { $rejected=$true }
        if (-not $rejected) { throw 'Retired policy-authoring input was accepted.' }
        $config.purview.Remove($oldField)
    }
    $config.purview.authorityRequirementsAcknowledged=$false
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fixture
    $rejected=$false
    try { Read-BootstrapConfig -Path $fixture | Out-Null } catch { $rejected=$true }
    if (-not $rejected) { throw 'Purview authority was inferred instead of explicitly acknowledged.' }
} finally { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture } }
'Setup choice matrix, tenant-only configuration, explicit consent and retired-input rejection passed (no network).'
