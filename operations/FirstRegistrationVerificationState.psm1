Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:VerificationStateSchemaVersion = 3
$script:VerificationBindingNames = @(
    'subscriptionId',
    'tenantId',
    'projectName',
    'environment',
    'resourceGroup',
    'apiBaseUrl',
    'gatewayApiApplicationClientId',
    'agentRegistrationId',
    'externalAgentId',
    'tenantUserObjectId',
    'promptShieldExpected',
    'purviewExpected',
    'wrapperSha256',
    'helperBundleSha256',
    'verificationBundleSha256',
    'preChildDisplayName',
    'childArmedDisplayName',
    'executionTag'
)
$script:VerificationStateNames = @('schemaVersion') + $script:VerificationBindingNames + @(
    'status',
    'temporaryApplicationObjectId',
    'temporaryApplicationClientId',
    'temporaryServicePrincipalId',
    'temporaryGrantId',
    'recoveryCredentialId',
    'createdAtUtc',
    'updatedAtUtc',
    'completedAtUtc'
)
$script:VerificationStatuses = @(
    'Prepared',
    'ApplicationCreateStarted',
    'ApplicationObserved',
    'OwnerAddStarted',
    'OwnerObserved',
    'ServicePrincipalCreateStarted',
    'ServicePrincipalObserved',
    'GrantCreateStarted',
    'AuthorityReady',
    'ArmStarted',
    'ChildArmed',
    'ChildLaunchStarted',
    'CredentialObserved',
    'Completed'
)
function Assert-VerificationExactPropertySet {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    $actual = @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    $required = @($Expected | Sort-Object)
    if ($actual.Count -ne $required.Count -or
        ($actual -join '|') -cne ($required -join '|')) {
        throw "$Label has an unexpected property set."
    }
}

function Assert-VerificationCanonicalGuid {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Label,
        [switch]$AllowEmpty
    )

    if ($AllowEmpty -and [string]::IsNullOrEmpty($Value)) { return }
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($Value, 'D', [ref]$parsed) -or
        $parsed -eq [guid]::Empty -or
        $Value -cne $parsed.ToString('D')) {
        throw "$Label must be one canonical lowercase non-empty GUID."
    }
}

function Assert-VerificationTimestamp {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Label,
        [switch]$AllowEmpty
    )

    if ($AllowEmpty -and [string]::IsNullOrEmpty($Value)) { return }
    $parsed = [DateTimeOffset]::MinValue
    if ($Value.Length -gt 64 -or
        -not [DateTimeOffset]::TryParse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        throw "$Label must be a bounded round-trip timestamp."
    }
    if ($parsed.Offset -ne [TimeSpan]::Zero -or
        $Value -cne $parsed.ToUniversalTime().ToString('O')) {
        throw "$Label must be one canonical UTC round-trip timestamp."
    }
}

function Assert-FirstRegistrationVerificationBindings {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Bindings)

    Assert-VerificationExactPropertySet -Value $Bindings -Expected $script:VerificationBindingNames -Label 'Verification bindings'
    foreach ($name in @(
        'subscriptionId',
        'tenantId',
        'gatewayApiApplicationClientId',
        'agentRegistrationId',
        'tenantUserObjectId'
    )) {
        Assert-VerificationCanonicalGuid -Value ([string]$Bindings[$name]) -Label "Verification binding $name"
    }
    if ([string]$Bindings.projectName -cnotmatch '^[a-z][a-z0-9]{2,19}$' -or
        [string]$Bindings.environment -cne 'dev' -or
        [string]$Bindings.resourceGroup -cnotmatch '^[A-Za-z0-9._()\-]{1,90}$' -or
        [string]$Bindings.externalAgentId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:\-]{0,255}$' -or
        [string]$Bindings.apiBaseUrl -cnotmatch '^https://[^/?#]+/$' -or
        ([string]$Bindings.apiBaseUrl).Length -gt 2048 -or
        [string]$Bindings.promptShieldExpected -cnotmatch '^(true|false)$' -or
        [string]$Bindings.purviewExpected -cnotmatch '^(true|false)$' -or
        [string]$Bindings.wrapperSha256 -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        [string]$Bindings.helperBundleSha256 -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        [string]$Bindings.verificationBundleSha256 -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        [string]$Bindings.preChildDisplayName -cnotmatch '^A365 Gateway First Registration Verification - [a-z0-9-]{3,88} - PreChild$' -or
        [string]$Bindings.childArmedDisplayName -cnotmatch '^A365 Gateway First Registration Verification - [a-z0-9-]{3,88} - ChildArmed$' -or
        [string]$Bindings.executionTag -cnotmatch '^a365gw:first-registration-verification:[0-9a-f]{32}$') {
        throw 'Verification bindings do not match the bounded non-secret contract.'
    }
}

function Assert-FirstRegistrationVerificationState {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Bindings
    )

    Assert-FirstRegistrationVerificationBindings -Bindings $Bindings
    Assert-VerificationExactPropertySet -Value $State -Expected $script:VerificationStateNames -Label 'Verification state'
    if ([string]$State.schemaVersion -cne [string]$script:VerificationStateSchemaVersion) {
        throw 'Verification state has an unsupported schema version.'
    }
    foreach ($name in $script:VerificationBindingNames) {
        if ([string]$State[$name] -cne [string]$Bindings[$name]) {
            throw "Verification state binding '$name' does not match this exact invocation."
        }
    }
    if ($script:VerificationStatuses -cnotcontains [string]$State.status) {
        throw 'Verification state has an unsupported lifecycle status.'
    }

    foreach ($name in @(
        'temporaryApplicationObjectId',
        'temporaryApplicationClientId',
        'temporaryServicePrincipalId',
        'recoveryCredentialId'
    )) {
        Assert-VerificationCanonicalGuid -Value ([string]$State[$name]) -Label "Verification state $name" -AllowEmpty
    }
    if ([string]$State.temporaryGrantId -cnotmatch '^$|^[A-Za-z0-9_-]{1,256}$') {
        throw 'Verification state temporaryGrantId is not a bounded opaque identifier.'
    }
    Assert-VerificationTimestamp -Value ([string]$State.createdAtUtc) -Label 'Verification state createdAtUtc'
    Assert-VerificationTimestamp -Value ([string]$State.updatedAtUtc) -Label 'Verification state updatedAtUtc'
    Assert-VerificationTimestamp -Value ([string]$State.completedAtUtc) -Label 'Verification state completedAtUtc' -AllowEmpty
    $createdAt = [DateTimeOffset]::Parse([string]$State.createdAtUtc, [Globalization.CultureInfo]::InvariantCulture)
    $updatedAt = [DateTimeOffset]::Parse([string]$State.updatedAtUtc, [Globalization.CultureInfo]::InvariantCulture)
    if ($updatedAt -lt $createdAt) {
        throw 'Verification state updatedAtUtc cannot precede createdAtUtc.'
    }

    $applicationObjectId = [string]$State.temporaryApplicationObjectId
    $applicationClientId = [string]$State.temporaryApplicationClientId
    $servicePrincipalId = [string]$State.temporaryServicePrincipalId
    $grantId = [string]$State.temporaryGrantId
    $credentialId = [string]$State.recoveryCredentialId
    if ([string]::IsNullOrEmpty($applicationObjectId) -ne [string]::IsNullOrEmpty($applicationClientId) -or
        (-not [string]::IsNullOrEmpty($servicePrincipalId) -and [string]::IsNullOrEmpty($applicationClientId)) -or
        (-not [string]::IsNullOrEmpty($grantId) -and [string]::IsNullOrEmpty($servicePrincipalId))) {
        throw 'Verification state contains an impossible partial-authority identifier ordering.'
    }

    $status = [string]$State.status
    $requiresApplication = @(
        'ApplicationObserved',
        'OwnerAddStarted',
        'OwnerObserved',
        'ServicePrincipalCreateStarted',
        'ServicePrincipalObserved',
        'GrantCreateStarted',
        'AuthorityReady',
        'ArmStarted',
        'ChildArmed',
        'ChildLaunchStarted',
        'CredentialObserved',
        'Completed'
    ) -ccontains $status
    $requiresServicePrincipal = @(
        'ServicePrincipalObserved',
        'GrantCreateStarted',
        'AuthorityReady',
        'ArmStarted',
        'ChildArmed',
        'ChildLaunchStarted',
        'CredentialObserved',
        'Completed'
    ) -ccontains $status
    $requiresGrant = @(
        'AuthorityReady',
        'ArmStarted',
        'ChildArmed',
        'ChildLaunchStarted',
        'CredentialObserved',
        'Completed'
    ) -ccontains $status
    if (($requiresApplication -and
         ([string]::IsNullOrEmpty($applicationObjectId) -or
          [string]::IsNullOrEmpty($applicationClientId))) -or
        ($requiresServicePrincipal -and [string]::IsNullOrEmpty($servicePrincipalId)) -or
        ($requiresGrant -and [string]::IsNullOrEmpty($grantId))) {
        throw 'Verification state status is missing an earlier observed authority binding.'
    }
    if (($status -ceq 'Prepared' -or $status -ceq 'ApplicationCreateStarted') -and
        (-not [string]::IsNullOrEmpty($applicationObjectId) -or
         -not [string]::IsNullOrEmpty($applicationClientId) -or
         -not [string]::IsNullOrEmpty($servicePrincipalId) -or
         -not [string]::IsNullOrEmpty($grantId))) {
        throw 'Verification state records authority before the application was durably observed.'
    }
    if (@(
            'ApplicationObserved',
            'OwnerAddStarted',
            'OwnerObserved',
            'ServicePrincipalCreateStarted'
        ) -ccontains $status -and
        (-not [string]::IsNullOrEmpty($servicePrincipalId) -or
         -not [string]::IsNullOrEmpty($grantId))) {
        throw 'Verification state records authority before the service principal was durably observed.'
    }
    if (($status -ceq 'ServicePrincipalObserved' -or $status -ceq 'GrantCreateStarted') -and
        -not [string]::IsNullOrEmpty($grantId)) {
        throw 'Verification state records a grant before it was durably observed.'
    }
    if ($status -cne 'CredentialObserved' -and $status -cne 'Completed') {
        if (-not [string]::IsNullOrEmpty($credentialId) -or
            -not [string]::IsNullOrEmpty([string]$State.completedAtUtc)) {
            throw 'Verification state records a credential or completion before the permitted lifecycle stage.'
        }
    }
    elseif ([string]::IsNullOrEmpty($credentialId)) {
        throw 'Verification state must bind the exact observed credential before recovery or completion.'
    }
    if ([string]$State.status -ceq 'Completed') {
        if ([string]::IsNullOrEmpty([string]$State.completedAtUtc)) {
            throw 'Completed verification state requires its completion timestamp.'
        }
        $completedAt = [DateTimeOffset]::Parse([string]$State.completedAtUtc, [Globalization.CultureInfo]::InvariantCulture)
        if ($completedAt -lt $createdAt) {
            throw 'Verification state completedAtUtc cannot precede createdAtUtc.'
        }
    }
    elseif (-not [string]::IsNullOrEmpty([string]$State.completedAtUtc)) {
        throw 'Only Completed verification state may carry a completion timestamp.'
    }
}

function New-FirstRegistrationVerificationState {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Bindings)

    Assert-FirstRegistrationVerificationBindings -Bindings $Bindings
    $now = [DateTimeOffset]::UtcNow.ToString('O')
    $state = [ordered]@{
        schemaVersion = $script:VerificationStateSchemaVersion
    }
    foreach ($name in $script:VerificationBindingNames) {
        $state[$name] = [string]$Bindings[$name]
    }
    $state.status = 'Prepared'
    $state.temporaryApplicationObjectId = ''
    $state.temporaryApplicationClientId = ''
    $state.temporaryServicePrincipalId = ''
    $state.temporaryGrantId = ''
    $state.recoveryCredentialId = ''
    $state.createdAtUtc = $now
    $state.updatedAtUtc = $now
    $state.completedAtUtc = ''
    Assert-FirstRegistrationVerificationState -State $state -Bindings $Bindings
    return $state
}

function Convert-VerificationParsedJsonDatesToStrings {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $child = $Value[$key]
            if ($child -is [DateTime]) {
                $Value[$key] = ([DateTimeOffset]$child).ToUniversalTime().ToString(
                    'O',
                    [Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($child -is [DateTimeOffset]) {
                $Value[$key] = $child.ToUniversalTime().ToString(
                    'O',
                    [Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($child -is [System.Collections.IDictionary] -or
                ($child -is [System.Collections.IList] -and $child -isnot [string])) {
                Convert-VerificationParsedJsonDatesToStrings -Value $child
            }
        }
        return
    }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            $child = $Value[$index]
            if ($child -is [DateTime]) {
                $Value[$index] = ([DateTimeOffset]$child).ToUniversalTime().ToString(
                    'O',
                    [Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($child -is [DateTimeOffset]) {
                $Value[$index] = $child.ToUniversalTime().ToString(
                    'O',
                    [Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($child -is [System.Collections.IDictionary] -or
                ($child -is [System.Collections.IList] -and $child -isnot [string])) {
                Convert-VerificationParsedJsonDatesToStrings -Value $child
            }
        }
    }
}

function Read-VerificationStateJson {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -le 0 -or $file.Length -gt 32768) {
        throw 'Verification state is empty or exceeds the bounded safe-identifier size.'
    }
    try {
        $parameters = @{ Depth = 20; AsHashtable = $true; ErrorAction = 'Stop' }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $parameters.DateKind = 'String'
        }
        $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json @parameters
        # PowerShell 7.0-7.4 automatically materializes ISO-8601 JSON strings as
        # DateTime and has no ConvertFrom-Json -DateKind switch. Restore those
        # values to the canonical persisted string contract before validation.
        Convert-VerificationParsedJsonDatesToStrings -Value $state
    }
    catch {
        throw 'Verification state is not valid bounded JSON. Preserve it for manual review.'
    }
    if ($state -isnot [System.Collections.IDictionary]) {
        throw 'Verification state must contain one JSON object.'
    }
    return $state
}

function Read-FirstRegistrationVerificationState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Bindings
    )

    Assert-FirstRegistrationVerificationBindings -Bindings $Bindings
    $state = Read-VerificationStateJson -Path $Path
    if ($null -eq $state) { return $null }
    Assert-FirstRegistrationVerificationState -State $state -Bindings $Bindings
    return $state
}

function Set-FirstRegistrationVerificationStateStatus {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Bindings,
        [Parameter(Mandatory)]
        [ValidateSet(
            'Prepared',
            'ApplicationCreateStarted',
            'ApplicationObserved',
            'OwnerAddStarted',
            'OwnerObserved',
            'ServicePrincipalCreateStarted',
            'ServicePrincipalObserved',
            'GrantCreateStarted',
            'AuthorityReady',
            'ArmStarted',
            'ChildArmed',
            'ChildLaunchStarted',
            'CredentialObserved',
            'Completed'
        )]
        [string]$Status,
        [AllowEmptyString()][string]$TemporaryApplicationObjectId,
        [AllowEmptyString()][string]$TemporaryApplicationClientId,
        [AllowEmptyString()][string]$TemporaryServicePrincipalId,
        [AllowEmptyString()][string]$TemporaryGrantId,
        [AllowEmptyString()][string]$RecoveryCredentialId
    )

    Assert-FirstRegistrationVerificationState -State $State -Bindings $Bindings
    $allowed = @{
        Prepared = @('ApplicationCreateStarted')
        ApplicationCreateStarted = @('ApplicationObserved')
        ApplicationObserved = @('OwnerAddStarted', 'OwnerObserved')
        OwnerAddStarted = @('OwnerObserved')
        OwnerObserved = @('ServicePrincipalCreateStarted')
        ServicePrincipalCreateStarted = @('ServicePrincipalObserved')
        ServicePrincipalObserved = @('GrantCreateStarted')
        GrantCreateStarted = @('AuthorityReady')
        AuthorityReady = @('ArmStarted')
        ArmStarted = @('ChildArmed')
        ChildArmed = @('ChildLaunchStarted')
        ChildLaunchStarted = @('CredentialObserved')
        CredentialObserved = @('Completed')
        Completed = @()
    }
    if ($allowed[[string]$State.status] -cnotcontains $Status) {
        throw "Verification state transition $($State.status) -> $Status is not allowed."
    }
    $candidate = [ordered]@{}
    foreach ($propertyName in $script:VerificationStateNames) {
        $candidate[$propertyName] = $State[$propertyName]
    }
    foreach ($name in @(
        'TemporaryApplicationObjectId',
        'TemporaryApplicationClientId',
        'TemporaryServicePrincipalId',
        'TemporaryGrantId',
        'RecoveryCredentialId'
    )) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $stateName = $name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)
            $candidate[$stateName] = [string]$PSBoundParameters[$name]
        }
    }
    $candidate.status = $Status
    if ($Status -ceq 'Completed') {
        $candidate.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
    Assert-FirstRegistrationVerificationState -State $candidate -Bindings $Bindings
    foreach ($propertyName in $script:VerificationStateNames) {
        $State[$propertyName] = $candidate[$propertyName]
    }
    return $State
}

function Save-FirstRegistrationVerificationState {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Bindings
    )

    Assert-FirstRegistrationVerificationState -State $State -Bindings $Bindings
    $State.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    Assert-FirstRegistrationVerificationState -State $State -Bindings $Bindings

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ".$([IO.Path]::GetFileName($fullPath)).$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject $State -Depth 20
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        if ($bytes.Length -le 0 -or $bytes.Length -gt 32768) {
            throw 'Verification state serialization exceeds the bounded safe-identifier size.'
        }
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
        [IO.File]::Move($temporary, $fullPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Test-FirstRegistrationVerificationStateRequiresPreservation {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Bindings
    )

    Assert-FirstRegistrationVerificationState -State $State -Bindings $Bindings
    return [string]$State.status -cne 'Prepared' -and [string]$State.status -cne 'Completed'
}

Export-ModuleMember -Function @(
    'Assert-FirstRegistrationVerificationBindings',
    'Assert-FirstRegistrationVerificationState',
    'New-FirstRegistrationVerificationState',
    'Read-FirstRegistrationVerificationState',
    'Set-FirstRegistrationVerificationStateStatus',
    'Save-FirstRegistrationVerificationState',
    'Test-FirstRegistrationVerificationStateRequiresPreservation'
)
