#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [string]$CertificatePath,

    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter(Mandatory)]
    [string]$AutomationApplicationId,

    [Parameter(Mandatory)]
    [string]$AutomationServicePrincipalObjectId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resultPrefix = 'A365GW_CONNECTION_VERIFICATION:'
$inventoryLimit = 2048

function ConvertTo-CanonicalGuid {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Label
    )

    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref]$parsed) -or
        $parsed -eq [Guid]::Empty -or
        $Value -cne $parsed.ToString('D')) {
        throw "$Label is not a canonical non-empty identifier."
    }
    return $parsed.ToString('D')
}

function Assert-BoundedText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][int]$MaximumLength,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt $MaximumLength -or
        $Value.ToCharArray().Where({
            [int]$_ -le 31 -or [int]$_ -eq 127
        }).Count -ne 0) {
        throw "$Label is invalid."
    }
    return $Value
}

function Get-ExactProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $properties = @($InputObject.PSObject.Properties |
        Where-Object { $_.Name -ceq $Name })
    if ($properties.Count -ne 1) {
        throw "Provider property '$Name' is missing or ambiguous."
    }
    return $properties[0].Value
}

$passwordText = [Console]::In.ReadLine()
if ([string]::IsNullOrWhiteSpace($passwordText)) {
    throw 'Certificate password was not supplied.'
}
$securePassword = ConvertTo-SecureString $passwordText -AsPlainText -Force
$passwordText = $null
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $CertificatePath,
    $securePassword,
    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
$ownedConnectionIds = @()

try {
    $input = Get-Content -LiteralPath $InputPath -Raw |
        ConvertFrom-Json -Depth 8 -ErrorAction Stop
    $operationId = ConvertTo-CanonicalGuid `
        -Value ([string]$input.operationId) `
        -Label 'Operation ID'
    $tenantId = ConvertTo-CanonicalGuid `
        -Value ([string]$input.tenantId) `
        -Label 'Tenant ID'
    $administratorObjectId = ConvertTo-CanonicalGuid `
        -Value ([string]$input.administratorObjectId) `
        -Label 'Administrator object ID'
    $applicationId = ConvertTo-CanonicalGuid `
        -Value $AutomationApplicationId `
        -Label 'Automation application ID'
    $servicePrincipalObjectId = ConvertTo-CanonicalGuid `
        -Value $AutomationServicePrincipalObjectId `
        -Label 'Automation service principal object ID'

    Import-Module ExchangeOnlineManagement -MinimumVersion 3.10.1 -ErrorAction Stop
    $existingConnections = @(Get-ConnectionInformation -ErrorAction Stop)
    if (@($existingConnections |
            Where-Object { $_.IsEopSession -eq $true }).Count -ne 0) {
        throw 'An existing Security and Compliance session is ambiguous.'
    }
    $existingConnectionIds = @($existingConnections | ForEach-Object {
        [string]$_.ConnectionId
    })

    Connect-IPPSSession `
        -AppId $applicationId `
        -Certificate $certificate `
        -Organization $Organization `
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
        throw 'Purview verification did not prove one exact owned session.'
    }
    $connectedTenantId = ConvertTo-CanonicalGuid `
        -Value ([string](Get-ExactProperty `
            -InputObject $activeConnections[0] `
            -Name 'TenantID')) `
        -Label 'Connected tenant ID'
    if ($connectedTenantId -cne $tenantId) {
        throw 'The connected provider tenant does not match the operation.'
    }
    $connectedApplicationId = ConvertTo-CanonicalGuid `
        -Value ([string](Get-ExactProperty `
            -InputObject $activeConnections[0] `
            -Name 'AppId')) `
        -Label 'Connected application ID'
    if ($connectedApplicationId -cne $applicationId) {
        throw 'The connected provider application does not match the capability.'
    }

    foreach ($command in @(
        'Get-ServicePrincipal',
        'Get-User',
        'Get-DlpSensitiveInformationType')) {
        Get-Command $command -ErrorAction Stop | Out-Null
    }
    $servicePrincipals = @(
        Get-ServicePrincipal `
            -Identity $servicePrincipalObjectId `
            -ErrorAction Stop)
    if ($servicePrincipals.Count -ne 1) {
        throw 'The automation service principal was not resolved exactly.'
    }
    $resolvedServicePrincipalObjectId = ConvertTo-CanonicalGuid `
        -Value ([string](Get-ExactProperty `
            -InputObject $servicePrincipals[0] `
            -Name 'ObjectId')) `
        -Label 'Resolved service principal object ID'
    $resolvedServicePrincipalApplicationId = ConvertTo-CanonicalGuid `
        -Value ([string](Get-ExactProperty `
            -InputObject $servicePrincipals[0] `
            -Name 'AppId')) `
        -Label 'Resolved service principal application ID'
    if ($resolvedServicePrincipalObjectId -cne $servicePrincipalObjectId -or
        $resolvedServicePrincipalApplicationId -cne $applicationId) {
        throw 'The provider service principal does not match the capability.'
    }
    $users = @(Get-User -Identity $administratorObjectId -ErrorAction Stop)
    if ($users.Count -ne 1) {
        throw 'The operation administrator was not resolved exactly.'
    }
    $resolvedAdministrator = ConvertTo-CanonicalGuid `
        -Value ([string](Get-ExactProperty `
            -InputObject $users[0] `
            -Name 'ExternalDirectoryObjectId')) `
        -Label 'Resolved administrator object ID'
    if ($resolvedAdministrator -cne $administratorObjectId) {
        throw 'The provider administrator does not match the operation.'
    }

    $providerItems = @(Get-DlpSensitiveInformationType -ErrorAction Stop)
    if ($providerItems.Count -eq 0 -or
        $providerItems.Count -gt $inventoryLimit) {
        throw 'The provider inventory is outside its safe bound.'
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $inventory = [Collections.Generic.List[object]]::new()
    foreach ($providerItem in $providerItems) {
        $id = ConvertTo-CanonicalGuid `
            -Value ([string](Get-ExactProperty -InputObject $providerItem -Name 'Id')) `
            -Label 'Sensitive information type ID'
        $name = Assert-BoundedText `
            -Value ([string](Get-ExactProperty -InputObject $providerItem -Name 'Name')) `
            -MaximumLength 255 `
            -Label 'Sensitive information type Name'
        $publisher = Assert-BoundedText `
            -Value ([string](Get-ExactProperty -InputObject $providerItem -Name 'Publisher')) `
            -MaximumLength 200 `
            -Label 'Sensitive information type Publisher'
        if (-not $ids.Add($id) -or -not $names.Add($name)) {
            throw 'The provider inventory contains duplicate identity.'
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
    $result = [ordered]@{
        operationId = $operationId
        tenantId = $connectedTenantId
        administratorObjectId = $resolvedAdministrator
        authorityApplicationId = $connectedApplicationId
        authorityServicePrincipalObjectId = $resolvedServicePrincipalObjectId
        observedAtUtc = $observedAt.ToString('O')
        expiresAtUtc = $observedAt.AddMinutes(15).ToString('O')
        items = $orderedInventory
    }
    $json = $result | ConvertTo-Json -Depth 8 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    [Console]::Out.WriteLine("$resultPrefix$encoded")
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
        catch {
        }
    }
    if ($null -ne $certificate) {
        $certificate.Dispose()
    }
}
