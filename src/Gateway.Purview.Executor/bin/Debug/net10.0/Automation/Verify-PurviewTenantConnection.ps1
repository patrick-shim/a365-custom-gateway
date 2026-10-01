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

function Get-SafeVerifierErrors {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$Record)

    $category = [string]$Record.CategoryInfo.Category
    if ($category -cnotin @('NotSpecified', 'OpenError', 'InvalidArgument', 'InvalidOperation',
            'PermissionDenied', 'ObjectNotFound', 'AuthenticationError', 'SecurityError',
            'ResourceUnavailable', 'ConnectionError', 'ProtocolError', 'OperationTimeout',
            'NotImplemented', 'InvalidData', 'InvalidResult', 'ReadError', 'WriteError', 'OperationStopped')) {
        $category = 'Other'
    }
    $types = @{
        'System.Management.Automation.RuntimeException' = 'PowerShellRuntime'
        'System.Management.Automation.CmdletInvocationException' = 'CmdletInvocation'
        'System.Management.Automation.MethodInvocationException' = 'MethodInvocation'
        'System.Management.Automation.ParameterBindingException' = 'ParameterBinding'
        'System.Management.Automation.CommandNotFoundException' = 'CommandNotFound'
        'System.Management.Automation.PSNotSupportedException' = 'NotSupported'
        'System.Management.Automation.PSInvalidOperationException' = 'InvalidOperation'
        'System.InvalidOperationException' = 'InvalidOperation'
        'System.NotSupportedException' = 'NotSupported'
        'System.PlatformNotSupportedException' = 'PlatformNotSupported'
        'System.Security.Cryptography.CryptographicException' = 'Cryptography'
        'System.UnauthorizedAccessException' = 'AccessDenied'
        'System.IO.FileNotFoundException' = 'FileNotFound'
        'System.IO.FileLoadException' = 'FileLoad'
        'System.TypeLoadException' = 'TypeLoad'
        'System.Net.Http.HttpRequestException' = 'HttpRequest'
        'System.Net.WebException' = 'WebRequest'
        'System.Security.Authentication.AuthenticationException' = 'Authentication'
        'Microsoft.Identity.Client.MsalServiceException' = 'MsalService'
        'Microsoft.Identity.Client.MsalClientException' = 'MsalClient'
        'Microsoft.Identity.Client.MsalUiRequiredException' = 'MsalUiRequired'
        'System.ArgumentException' = 'Argument'
        'System.ArgumentNullException' = 'ArgumentNull'
        'System.NullReferenceException' = 'NullReference'
    }
    $codes = @('invalid_client', 'invalid_grant', 'unauthorized_client', 'access_denied',
        'invalid_scope', 'interaction_required', 'consent_required', 'temporarily_unavailable',
        'service_not_available', 'unknown_error', 'authentication_canceled', 'http_request_failed',
        'client_assertion_signing_failed', 'certificate_not_found', 'cryptographic_exception',
        'unsupported_key_algorithm', 'multiple_matching_tokens_detected')
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $error = $Record.Exception
    for ($depth = 0; $null -ne $error -and $depth -lt 8; $depth++) {
        $type = $types[$error.GetType().FullName]
        if ($null -eq $type) { $type = 'Other' }
        $hresult = $error.HResult.ToString('X8', [Globalization.CultureInfo]::InvariantCulture)
        if ($hresult -cnotin @('80004005', '80004001', '80070002', '80070005', '80070057',
                '80090003', '80090005', '80090008', '8009000B', '8009000D', '80090010',
                '80090014', '80090016', '8009001D', '80090020', '80090022', '80090029',
                '80131500', '80131509', '80131515', '80131522', '80131621', '80131501',
                '80131502', '80131505', '80131506')) {
            $hresult = '00000000'
        }
        $code = 'Other'
        if ($type -cin @('MsalService', 'MsalClient', 'MsalUiRequired')) {
            if ($error.ErrorCode -cin $codes) { $code = [string]$error.ErrorCode }
        }
        if ($type -ceq 'CommandNotFound' -and $Record.TargetObject -is [string] -and
            $Record.TargetObject -cin @('Update-ModuleManifest', 'Update-FormatData',
                'Get-FormatData', 'Import-Module', 'New-PSSession')) {
            $code = [string]$Record.TargetObject
        }
        $site = $error.TargetSite
        if ($null -ne $site -and $null -ne $site.DeclaringType) {
            $siteType = $site.DeclaringType.FullName
            if ($siteType.StartsWith('System.IO.', [StringComparison]::Ordinal) -or
                $siteType -ceq 'Microsoft.Win32.SafeHandles.SafeFileHandle') {
                $code = switch -CaseSensitive ($site.Name) {
                    'CreateDirectory' { 'FileSystemCreateDirectory' }
                    'CreateFile' { 'FileSystemCreateFile' }
                    'OpenHandle' { 'FileSystemOpenHandle' }
                    default { 'FileSystemAccess' }
                }
            }
            elseif ($siteType.StartsWith('Microsoft.Win32.Registry', [StringComparison]::Ordinal)) { $code = 'RegistryAccess' }
        }
        $marker = "A365GW_VERIFIER_ERROR:${category}:${type}:${hresult}:${code}"
        if ($seen.Add($marker)) { $marker }
        $error = $error.InnerException
    }
}

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

function ConvertFrom-ProviderGuid {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Label
    )

    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [Guid]::Empty) {
        throw "$Label must be a valid non-empty GUID."
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
$verifierStage = 1

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

    $verifierStage = 2
    $requiredProviderCommands = @('Get-ServicePrincipal', 'Get-User', 'Get-DlpSensitiveInformationType')
    Import-Module ExchangeOnlineManagement -MinimumVersion 3.10.1 -ErrorAction Stop
    $verifierStage = 3
    $existingConnections = @(Get-ConnectionInformation -ErrorAction Stop)
    if (@($existingConnections |
            Where-Object { $_.IsEopSession -eq $true }).Count -ne 0) {
        throw 'An existing Security and Compliance session is ambiguous.'
    }
    $existingConnectionIds = @($existingConnections | ForEach-Object {
        [string]$_.ConnectionId
    })

    $verifierStage = 4
    $providerWorkspace = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($InputPath))
    Connect-IPPSSession `
        -AppId $applicationId `
        -Certificate $certificate `
        -Organization $Organization `
        -CommandName $requiredProviderCommands `
        -EXOModuleBasePath $providerWorkspace `
        -LogDirectoryPath $providerWorkspace `
        -ShowBanner:$false |
        Out-Null
    $verifierStage = 5
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
    $verifierStage = 6
    $connectedTenantId = ConvertFrom-ProviderGuid `
        -Value ([string](Get-ExactProperty `
            -InputObject $activeConnections[0] `
            -Name 'TenantID')) `
        -Label 'Connected tenant ID'
    if ($connectedTenantId -cne $tenantId) {
        throw 'The connected provider tenant does not match the operation.'
    }
    $connectedApplicationId = ConvertFrom-ProviderGuid `
        -Value ([string](Get-ExactProperty `
            -InputObject $activeConnections[0] `
            -Name 'AppId')) `
        -Label 'Connected application ID'
    if ($connectedApplicationId -cne $applicationId) {
        throw 'The connected provider application does not match the capability.'
    }

    $verifierStage = 7
    foreach ($command in $requiredProviderCommands) {
        Get-Command $command -ErrorAction Stop | Out-Null
    }
    $verifierStage = 8
    $servicePrincipals = @(
        Get-ServicePrincipal `
            -Identity $servicePrincipalObjectId `
            -ErrorAction Stop)
    if ($servicePrincipals.Count -ne 1) {
        throw 'The automation service principal was not resolved exactly.'
    }
    $resolvedServicePrincipalObjectId = ConvertFrom-ProviderGuid `
        -Value ([string](Get-ExactProperty `
            -InputObject $servicePrincipals[0] `
            -Name 'ObjectId')) `
        -Label 'Resolved service principal object ID'
    $resolvedServicePrincipalApplicationId = ConvertFrom-ProviderGuid `
        -Value ([string](Get-ExactProperty `
            -InputObject $servicePrincipals[0] `
            -Name 'AppId')) `
        -Label 'Resolved service principal application ID'
    if ($resolvedServicePrincipalObjectId -cne $servicePrincipalObjectId -or
        $resolvedServicePrincipalApplicationId -cne $applicationId) {
        throw 'The provider service principal does not match the capability.'
    }
    $verifierStage = 9
    $users = @(Get-User -Identity $administratorObjectId -ErrorAction Stop)
    if ($users.Count -ne 1) {
        throw 'The operation administrator was not resolved exactly.'
    }
    $resolvedAdministrator = ConvertFrom-ProviderGuid `
        -Value ([string](Get-ExactProperty `
            -InputObject $users[0] `
            -Name 'ExternalDirectoryObjectId')) `
        -Label 'Resolved administrator object ID'
    if ($resolvedAdministrator -cne $administratorObjectId) {
        throw 'The provider administrator does not match the operation.'
    }

    $verifierStage = 10
    $providerItems = @(Get-DlpSensitiveInformationType -ErrorAction Stop)
    if ($providerItems.Count -eq 0 -or
        $providerItems.Count -gt $inventoryLimit) {
        throw 'The provider inventory is outside its safe bound.'
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $inventory = [Collections.Generic.List[object]]::new()
    foreach ($providerItem in $providerItems) {
        $id = ConvertFrom-ProviderGuid `
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
    $verifierStage = 11
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
catch {
    [Console]::Error.WriteLine("A365GW_VERIFIER_STAGE:$verifierStage")
    try {
        foreach ($marker in @(Get-SafeVerifierErrors -Record $_)) {
            [Console]::Error.WriteLine($marker)
        }
    }
    catch {
        [Console]::Error.WriteLine('A365GW_VERIFIER_ERROR:Other:Other:00000000:Other')
    }
    throw
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
