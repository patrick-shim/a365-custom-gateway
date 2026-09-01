#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$UserPrincipalName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

$connectionId = ''
try {
    $bootstrapRoot = $PSScriptRoot
    Import-Module (Join-Path $bootstrapRoot 'modules/Common.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue
    Import-Module (Join-Path $bootstrapRoot 'modules/Purview.psm1') -Force -DisableNameChecking -WarningAction SilentlyContinue

    Assert-GuidValue -Value $TenantId -Label 'Purview tenant ID'
    $canonicalTenantId = ([guid]$TenantId).ToString('D')
    $connectionId = Connect-BootstrapPurview `
        -TenantId $canonicalTenantId `
        -UserPrincipalName $UserPrincipalName
    $types = @(Get-BootstrapPurviewSensitiveInformationTypes)

    [ordered]@{
        schemaVersion = 1
        tenantId = $canonicalTenantId
        types = @($types | ForEach-Object {
            [ordered]@{
                id = [string]$_.id
                name = [string]$_.name
                publisher = [string]$_.publisher
            }
        })
    } | ConvertTo-Json -Depth 5 -Compress
}
catch {
    [Console]::Error.WriteLine('Purview sensitive-information-type discovery failed safely. Confirm the selected-tenant Graph Member sign-in and Security & Compliance permissions, then retry.')
    exit 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($connectionId)) {
        try { Disconnect-BootstrapPurview -ConnectionId $connectionId } catch { }
    }
}
