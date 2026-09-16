#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1')

function ConvertFrom-GatewayUpgradeArmJson {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return @{} }
    $document = $null
    try {
        # Preserve literal environment timestamps instead of materializing DateTime values.
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
        $value = & (Get-Module GatewayUpgrade) {
            param($element)
            ConvertFrom-GatewayUpgradeJsonElement $element
        } $document.RootElement
        if ($value -isnot [Collections.IDictionary]) {
            throw 'UpgradeContract: ARM response must be a JSON object.'
        }
        return $value
    }
    catch [System.Text.Json.JsonException] {
        throw 'UpgradeContract: invalid ARM response JSON; provider content suppressed.'
    }
    finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}

Export-ModuleMember -Function ConvertFrom-GatewayUpgradeArmJson
