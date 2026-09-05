[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OperationId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$AdministratorObjectId,
    [Parameter(Mandatory)][string]$InventoryGenerationId,
    [Parameter(Mandatory)][string]$ExpiresAtUtc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:ResultPrefix = 'A365GW_CONNECTION_RESULT:'
$script:InventoryLimit = 2048

function ConvertTo-CanonicalGuid {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Label
    )

    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref]$parsed) -or
        $parsed -eq [Guid]::Empty -or
        $Value -cne $parsed.ToString('D')) {
        throw "$Label must be a canonical non-empty GUID."
    }
    return $parsed.ToString('D')
}

function Get-ExactProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $properties = @($InputObject.PSObject.Properties | Where-Object {
        $_.Name.Equals($Name, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($properties.Count -ne 1) {
        throw "Purview typed evidence omitted '$Name'."
    }
    return $properties[0].Value
}

function Assert-BoundedText {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][int]$MaximumLength,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$Value) -or
        ([string]$Value).Length -gt $MaximumLength -or
        [string]$Value -match '[\x00-\x1f\x7f]') {
        throw "$Label is invalid."
    }
    return [string]$Value
}

if (-not $IsWindows) {
    throw 'Interactive Microsoft Purview connection requires Windows.'
}

$operationIdValue = ConvertTo-CanonicalGuid -Value $OperationId -Label 'OperationId'
$tenantIdValue = ConvertTo-CanonicalGuid -Value $TenantId -Label 'TenantId'
$administratorObjectIdValue = ConvertTo-CanonicalGuid `
    -Value $AdministratorObjectId -Label 'AdministratorObjectId'
$generationIdValue = ConvertTo-CanonicalGuid `
    -Value $InventoryGenerationId -Label 'InventoryGenerationId'
$expiry = [DateTimeOffset]::MinValue
if (-not [DateTimeOffset]::TryParseExact(
        $ExpiresAtUtc,
        'O',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$expiry) -or
    $expiry.Offset -ne [TimeSpan]::Zero -or
    $expiry -le [DateTimeOffset]::UtcNow -or
    $expiry -gt [DateTimeOffset]::UtcNow.AddMinutes(15)) {
    throw 'The companion operation expiry is invalid or outside its bounded lifetime.'
}

Import-Module ExchangeOnlineManagement -MinimumVersion 3.10.1 -ErrorAction Stop
$existingConnections = @(Get-ConnectionInformation -ErrorAction Stop)
if (@($existingConnections | Where-Object { $_.IsEopSession -eq $true }).Count -ne 0) {
    throw 'An existing Security & Compliance session makes tenant authority ambiguous.'
}
$existingConnectionIds = @($existingConnections | ForEach-Object {
    [string]$_.ConnectionId
})
$ownedConnectionIds = @()

try {
    $authorizationEndpoint = "https://login.microsoftonline.com/$tenantIdValue"
    Connect-IPPSSession `
        -AzureADAuthorizationEndpointUri $authorizationEndpoint `
        -ShowBanner:$false |
        Out-Null

    $connections = @(Get-ConnectionInformation -ErrorAction Stop)
    $newConnections = @($connections | Where-Object {
        [string]$_.ConnectionId -notin $existingConnectionIds
    })
    $ownedConnectionIds = @($newConnections | ForEach-Object {
        [string]$_.ConnectionId
    })
    $activeConnections = @($connections | Where-Object {
        $_.IsEopSession -eq $true -and
        [string]$_.State -ceq 'Connected' -and
        [string]$_.TokenStatus -ceq 'Active'
    })
    if ($newConnections.Count -ne 1 -or
        $activeConnections.Count -ne 1 -or
        [string]$newConnections[0].ConnectionId -cne
            [string]$activeConnections[0].ConnectionId) {
        throw 'The companion could not prove one exact owned Security & Compliance session.'
    }

    $connection = $activeConnections[0]
    $actualTenant = ConvertTo-CanonicalGuid `
        -Value ([string](Get-ExactProperty -InputObject $connection -Name 'TenantID')) `
        -Label 'Connected tenant'
    if ($actualTenant -cne $tenantIdValue) {
        throw 'The connected Security & Compliance tenant does not match the operation tenant.'
    }
    $actualEndpoint = [Uri][string](Get-ExactProperty `
        -InputObject $connection -Name 'AzureAdAuthorizationEndpointUri')
    if ($actualEndpoint.Scheme -cne 'https' -or
        -not $actualEndpoint.Host.Equals(
            'login.microsoftonline.com',
            [StringComparison]::OrdinalIgnoreCase) -or
        $actualEndpoint.AbsolutePath.Trim('/') -cne $tenantIdValue -or
        -not [string]::IsNullOrEmpty($actualEndpoint.Query) -or
        -not [string]::IsNullOrEmpty($actualEndpoint.Fragment)) {
        throw 'The connected Security & Compliance authorization endpoint is invalid.'
    }

    foreach ($command in @(
        'Get-User',
        'Get-DlpSensitiveInformationType',
        'Get-FeatureConfiguration',
        'New-FeatureConfiguration',
        'Get-DlpCompliancePolicy',
        'New-DlpCompliancePolicy',
        'Get-DlpComplianceRule',
        'New-DlpComplianceRule')) {
        Get-Command $command -ErrorAction Stop | Out-Null
    }

    $userPrincipalName = Assert-BoundedText `
        -Value ([string](Get-ExactProperty -InputObject $connection -Name 'UserPrincipalName')) `
        -MaximumLength 320 `
        -Label 'Connected user'
    $users = @(Get-User -Identity $userPrincipalName -ErrorAction Stop)
    if ($users.Count -ne 1) {
        throw 'The connected Purview administrator did not resolve exactly once.'
    }
    $resolvedUserPrincipalName = Assert-BoundedText `
        -Value ([string](Get-ExactProperty -InputObject $users[0] -Name 'UserPrincipalName')) `
        -MaximumLength 320 `
        -Label 'Resolved user'
    $resolvedObjectId = ConvertTo-CanonicalGuid `
        -Value ([string](Get-ExactProperty `
            -InputObject $users[0] -Name 'ExternalDirectoryObjectId')) `
        -Label 'Resolved user object ID'
    if (-not $resolvedUserPrincipalName.Equals(
            $userPrincipalName,
            [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedObjectId -cne $administratorObjectIdValue) {
        throw 'The connected Purview administrator does not match the operation user.'
    }

    $providerItems = @(Get-DlpSensitiveInformationType -ErrorAction Stop)
    if ($providerItems.Count -eq 0 -or $providerItems.Count -gt $script:InventoryLimit) {
        throw 'The tenant sensitive-information-type inventory is empty or outside its safe bound.'
    }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $inventory = [Collections.Generic.List[object]]::new()
    foreach ($providerItem in $providerItems) {
        $id = ConvertTo-CanonicalGuid `
            -Value ([string](Get-ExactProperty -InputObject $providerItem -Name 'Id')) `
            -Label 'Sensitive information type ID'
        $name = Assert-BoundedText `
            -Value (Get-ExactProperty -InputObject $providerItem -Name 'Name') `
            -MaximumLength 255 `
            -Label 'Sensitive information type Name'
        $publisher = Assert-BoundedText `
            -Value (Get-ExactProperty -InputObject $providerItem -Name 'Publisher') `
            -MaximumLength 200 `
            -Label 'Sensitive information type Publisher'
        if (-not $ids.Add($id) -or -not $names.Add($name)) {
            throw 'The tenant sensitive-information-type inventory contains duplicate identity.'
        }
        $inventory.Add([ordered]@{
            id = $id
            exactName = $name
            publisher = $publisher
        })
    }

    $orderedInventory = @($inventory | Sort-Object `
        @{ Expression = { [string]$_.exactName }; Ascending = $true },
        @{ Expression = { [string]$_.id }; Ascending = $true })
    $observedAt = [DateTimeOffset]::UtcNow
    if ($observedAt -ge $expiry) {
        throw 'The companion operation expired before evidence could be completed.'
    }
    $result = [ordered]@{
        operationId = $operationIdValue
        tenantId = $tenantIdValue
        administratorObjectId = $resolvedObjectId
        inventoryGenerationId = $generationIdValue
        observedAtUtc = $observedAt.ToString('O')
        inventoryExpiresAtUtc = $expiry.ToString('O')
        authorizedCapabilities = @(
            'DlpPolicy.ReadWrite',
            'DlpRule.ReadWrite',
            'KnowYourData.ReadWrite',
            'SensitiveInformationTypes.Read'
        )
        sensitiveInformationTypes = $orderedInventory
    }
    $json = $result | ConvertTo-Json -Depth 8 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    [Console]::Out.WriteLine("$($script:ResultPrefix)$encoded")
}
finally {
    foreach ($connectionId in $ownedConnectionIds) {
        try {
            Disconnect-ExchangeOnline `
                -ConnectionId $connectionId `
                -Confirm:$false `
                -ErrorAction SilentlyContinue |
                Out-Null
        }
        catch { }
    }
}
