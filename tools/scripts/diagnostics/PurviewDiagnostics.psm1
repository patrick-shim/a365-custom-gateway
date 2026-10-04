Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:BootstrapPurviewSensitiveInformationTypeMaximum = 2048

function Test-BootstrapSecurityCompliancePlatformSupported {
    return [bool]$IsWindows
}

function Connect-BootstrapPurview {
    param(
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [Parameter(Mandatory)][string]$TenantId,
        [AllowEmptyString()][string]$AccessToken = '',
        [switch]$Device
    )
    if (-not (Test-BootstrapSecurityCompliancePlatformSupported)) {
        throw 'Run this Security & Compliance PowerShell diagnostic from Windows.'
    }
    Assert-GuidValue -Value $TenantId -Label 'Purview tenant ID'
    $canonicalTenantId = ([guid]$TenantId).ToString('D')
    if ($TenantId -cne $canonicalTenantId -or
        [string]::IsNullOrWhiteSpace($UserPrincipalName) -or
        $UserPrincipalName -match '[\x00-\x1f\x7f]') {
        throw 'Purview connection identity must use the canonical reviewed tenant and signed-in user.'
    }
    if (-not [string]::IsNullOrWhiteSpace($AccessToken) -and
        ($AccessToken -match '[\x00-\x20\x7f]' -or $AccessToken.Split('.').Count -ne 3)) {
        throw 'The externally acquired Purview access token is malformed.'
    }
    if ($Device -and -not [string]::IsNullOrWhiteSpace($AccessToken)) {
        throw 'Purview device authentication and external-token authentication cannot be combined.'
    }
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    $existingConnections = @(Get-ConnectionInformation -ErrorAction Stop)
    $existingEopConnections = @($existingConnections | Where-Object { $_.IsEopSession -eq $true })
    if ($existingEopConnections.Count -ne 0) {
        throw 'An existing Security & Compliance session is active. Disconnect it before bootstrap so tenant authority cannot be ambiguous.'
    }
    $existingIds = @($existingConnections | ForEach-Object { [string]$_.ConnectionId })
    $authorizationEndpoint = "https://login.microsoftonline.com/$canonicalTenantId"
    $newConnectionIds = @()
    try {
        if ($Device) {
            Connect-ExchangeOnline `
                -ConnectionUri 'https://ps.compliance.protection.outlook.com/PowerShell-LiveId' `
                -AzureADAuthorizationEndpointUri $authorizationEndpoint `
                -UserPrincipalName $UserPrincipalName `
                -Device `
                -ShowBanner:$false | Out-Null
        }
        else {
            $connectionParameters = @{
                UserPrincipalName = $UserPrincipalName
                AzureADAuthorizationEndpointUri = $authorizationEndpoint
                ShowBanner = $false
            }
            if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
                $connectionParameters.AccessToken = $AccessToken
            }
            Connect-IPPSSession @connectionParameters | Out-Null
        }
        $connections = @(Get-ConnectionInformation -ErrorAction Stop)
        $newConnections = @($connections | Where-Object { [string]$_.ConnectionId -notin $existingIds })
        $newConnectionIds = @($newConnections | ForEach-Object { [string]$_.ConnectionId })
        $activeEopConnections = @($connections | Where-Object {
            $_.IsEopSession -eq $true -and [string]$_.State -ceq 'Connected'
        })
        if ($newConnections.Count -ne 1 -or
            $activeEopConnections.Count -ne 1 -or
            [string]$newConnections[0].ConnectionId -cne [string]$activeEopConnections[0].ConnectionId -or
            [string]$activeEopConnections[0].TokenStatus -cne 'Active' -or
            -not ([string]$activeEopConnections[0].TenantID).Equals($canonicalTenantId, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$activeEopConnections[0].UserPrincipalName).Equals($UserPrincipalName, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'connection-mismatch'
        }
        $actualEndpoint = [Uri][string]$activeEopConnections[0].AzureAdAuthorizationEndpointUri
        if ($actualEndpoint.Scheme -cne 'https' -or
            -not $actualEndpoint.Host.Equals('login.microsoftonline.com', [StringComparison]::OrdinalIgnoreCase) -or
            $actualEndpoint.AbsolutePath.Trim('/') -cne $canonicalTenantId -or
            -not [string]::IsNullOrEmpty($actualEndpoint.Query) -or
            -not [string]::IsNullOrEmpty($actualEndpoint.Fragment)) {
            throw 'connection-endpoint-mismatch'
        }
        foreach ($command in @('Get-DlpSensitiveInformationType')) {
            if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw 'required-command-unavailable' }
        }
        return [string]$activeEopConnections[0].ConnectionId
    }
    catch {
        if ($newConnectionIds.Count -eq 0) {
            try {
                $newConnectionIds = @(Get-ConnectionInformation -ErrorAction SilentlyContinue |
                    Where-Object { [string]$_.ConnectionId -notin $existingIds } |
                    ForEach-Object { [string]$_.ConnectionId })
            }
            catch { }
        }
        foreach ($connectionId in $newConnectionIds) {
            try { Disconnect-ExchangeOnline -ConnectionId $connectionId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
        throw 'Security & Compliance tenant/session authority could not be proven exactly. The session must match the selected tenant and account.'
    }
}

function Disconnect-BootstrapPurview {
    param([Parameter(Mandatory)][string]$ConnectionId)
    Assert-GuidValue -Value $ConnectionId -Label 'Owned Security & Compliance connection ID'
    Disconnect-ExchangeOnline -ConnectionId $ConnectionId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

function Assert-BootstrapPurviewSensitiveInformationTypeName {
    param([Parameter(Mandatory)]$Value)

    if ($Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$Value) -or
        ([string]$Value).Length -gt 255 -or
        [string]$Value -match '[\x00-\x1f\x7f]') {
        throw 'Purview sensitive-information-type inventory returned an invalid Name.'
    }
    return [string]$Value
}

function ConvertTo-BootstrapPurviewSensitiveInformationTypeProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$InputObject)

    $items = @($InputObject)
    if ($items.Count -eq 0) {
        throw 'Purview sensitive-information-type inventory was empty.'
    }
    if ($items.Count -gt $script:BootstrapPurviewSensitiveInformationTypeMaximum) {
        throw 'Purview sensitive-information-type inventory exceeded the safe 2048-item limit.'
    }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $projected = [Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        if ($null -eq $item) {
            throw 'Purview sensitive-information-type inventory returned a malformed item.'
        }
        $idValue = Get-BootstrapPurviewProperty -InputObject $item -Names @('Id')
        $parsedId = [guid]::Empty
        if ($idValue -isnot [guid] -and $idValue -isnot [string]) {
            throw 'Purview sensitive-information-type inventory returned an invalid Id.'
        }
        if (-not [guid]::TryParse([string]$idValue, [ref]$parsedId) -or $parsedId -eq [guid]::Empty) {
            throw 'Purview sensitive-information-type inventory returned an invalid Id.'
        }
        $canonicalId = $parsedId.ToString('D')
        $name = Assert-BootstrapPurviewSensitiveInformationTypeName `
            -Value (Get-BootstrapPurviewProperty -InputObject $item -Names @('Name'))
        $publisherValue = Get-BootstrapPurviewProperty -InputObject $item -Names @('Publisher') -Optional
        if ($null -eq $publisherValue) { $publisher = '' }
        elseif ($publisherValue -isnot [string] -or
            ([string]$publisherValue).Length -gt 200 -or
            [string]$publisherValue -match '[\x00-\x1f\x7f]') {
            throw 'Purview sensitive-information-type inventory returned an invalid Publisher.'
        }
        else { $publisher = [string]$publisherValue }

        if (-not $ids.Add($canonicalId)) {
            throw 'Purview sensitive-information-type inventory returned a duplicate Id.'
        }
        if (-not $names.Add($name)) {
            throw 'Purview sensitive-information-type inventory returned a duplicate exact Name.'
        }
        $projected.Add([pscustomobject][ordered]@{
            id = $canonicalId
            name = $name
            publisher = $publisher
        })
    }

    $projected.Sort([Comparison[object]]{
        param($left, $right)
        $nameComparison = [StringComparer]::Ordinal.Compare([string]$left.name, [string]$right.name)
        if ($nameComparison -ne 0) { return $nameComparison }
        return [StringComparer]::Ordinal.Compare([string]$left.id, [string]$right.id)
    })
    return @($projected)
}

function Get-BootstrapPurviewSensitiveInformationTypes {
    [CmdletBinding()]
    param()

    try {
        $providerItems = @(Get-DlpSensitiveInformationType -ErrorAction Stop)
    }
    catch {
        throw 'Purview sensitive-information-type inventory could not be read through the authorized Security & Compliance session.'
    }
    return @(ConvertTo-BootstrapPurviewSensitiveInformationTypeProjection -InputObject $providerItems)
}

function Get-BootstrapPurviewProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string[]]$Names,
        [switch]$Optional
    )
    foreach ($name in $Names) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            $keys = @($InputObject.Keys | Where-Object { ([string]$_).Equals($name, [StringComparison]::OrdinalIgnoreCase) })
            if ($keys.Count -eq 1) { return $InputObject[$keys[0]] }
            continue
        }
        $property = @($InputObject.PSObject.Properties | Where-Object { $_.Name.Equals($name, [StringComparison]::OrdinalIgnoreCase) })
        if ($property.Count -eq 1) { return $property[0].Value }
    }
    if ($Optional) { return $null }
    throw "Purview readback omitted required typed property '$($Names -join '/')'."
}

Export-ModuleMember -Function *
