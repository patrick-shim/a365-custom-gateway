Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BootstrapStateSchemaVersion = 2
$script:BootstrapVersion = '2.0.0'
# Bounded audit trail of reconciled configuration changes kept in bootstrap state.
$script:BootstrapConfigurationChangeHistoryLimit = 20
$script:BootstrapStructuredOutput = $false
$script:BootstrapDiagnosticsDirectory = ''
$script:BootstrapProgressSink = $null
$script:BootstrapAzureSubscriptionId = ''
$script:BootstrapAzureTenantId = ''
$script:BootstrapGraphAccessToken = ''
$script:BootstrapGraphAccessTokenExpiresOn = 0L
$script:BootstrapGraphHttpClient = $null
$script:BootstrapConfigurationMaximumBytes = 1048576

function Clear-BootstrapAzureSubscriptionContext {
    $script:BootstrapAzureSubscriptionId = ''
    $script:BootstrapAzureTenantId = ''
    $script:BootstrapGraphAccessToken = ''
    $script:BootstrapGraphAccessTokenExpiresOn = 0L
    [Environment]::SetEnvironmentVariable('A365GW_BOOTSTRAP_SUBSCRIPTION_ID', $null, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('A365GW_BOOTSTRAP_TENANT_ID', $null, [EnvironmentVariableTarget]::Process)
}

function Set-BootstrapAzureSubscriptionContext {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId
    )

    Assert-GuidValue -Value $SubscriptionId -Label 'Azure subscription context'
    Assert-GuidValue -Value $TenantId -Label 'Azure tenant context'
    $canonicalSubscription = ([guid]$SubscriptionId).ToString('D')
    $canonicalTenant = ([guid]$TenantId).ToString('D')
    if ($SubscriptionId -cne $canonicalSubscription) {
        throw 'Azure subscription context must be a canonical lowercase GUID.'
    }
    if ($TenantId -cne $canonicalTenant) {
        throw 'Azure tenant context must be a canonical lowercase GUID.'
    }
    $script:BootstrapAzureSubscriptionId = $canonicalSubscription
    $script:BootstrapAzureTenantId = $canonicalTenant
    $script:BootstrapGraphAccessToken = ''
    $script:BootstrapGraphAccessTokenExpiresOn = 0L
    # This is a non-secret identifier used only by reviewed child scripts so their
    # direct Azure CLI calls cannot drift to another default subscription.
    [Environment]::SetEnvironmentVariable('A365GW_BOOTSTRAP_SUBSCRIPTION_ID', $canonicalSubscription, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable('A365GW_BOOTSTRAP_TENANT_ID', $canonicalTenant, [EnvironmentVariableTarget]::Process)
}

function Set-BootstrapTenantOnlyContext {
    param([Parameter(Mandatory)][string]$TenantId)
    Assert-GuidValue -Value $TenantId -Label 'Microsoft tenant'
    Clear-BootstrapAzureSubscriptionContext
    $script:BootstrapAzureTenantId = ([guid]$TenantId).ToString('D')
    [Environment]::SetEnvironmentVariable('A365GW_BOOTSTRAP_TENANT_ID', $script:BootstrapAzureTenantId, [EnvironmentVariableTarget]::Process)
}

function Set-BootstrapStructuredOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Enabled)

    $script:BootstrapStructuredOutput = $Enabled
}

function Get-BootstrapSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash($bytes)
    }
    finally {
        $algorithm.Dispose()
    }
    $hex = ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    return "sha256:$hex"
}

function Get-BootstrapByteFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    $hash = [Security.Cryptography.SHA256]::HashData($Bytes)
    try {
        $hex = ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
        return "sha256:$hex"
    }
    finally {
        [Array]::Clear($hash, 0, $hash.Length)
    }
}

function ConvertTo-BootstrapCanonicalValue {
    param(
        [Parameter()][AllowNull()]$Value,
        [switch]$IsRoot,
        [switch]$ExcludeSchemaAnnotation
    )

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        [string[]]$keys = @($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) {
            if ($IsRoot -and $ExcludeSchemaAnnotation -and $key -eq '$schema') { continue }
            $result[$key] = ConvertTo-BootstrapCanonicalValue -Value $Value[$key] -ExcludeSchemaAnnotation:$ExcludeSchemaAnnotation
        }
        return $result
    }

    if ($Value.GetType() -eq [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        [string[]]$names = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
        [Array]::Sort($names, [StringComparer]::Ordinal)
        foreach ($name in $names) {
            if ($IsRoot -and $ExcludeSchemaAnnotation -and $name -eq '$schema') { continue }
            $result[$name] = ConvertTo-BootstrapCanonicalValue -Value $Value.$name -ExcludeSchemaAnnotation:$ExcludeSchemaAnnotation
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        [object[]]$items = @($Value | ForEach-Object {
            ConvertTo-BootstrapCanonicalValue -Value $_ -ExcludeSchemaAnnotation:$ExcludeSchemaAnnotation
        })
        return ,$items
    }

    return $Value
}

function Get-BootstrapObjectFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [switch]$ExcludeSchemaAnnotation
    )

    $canonical = ConvertTo-BootstrapCanonicalValue -Value $InputObject -IsRoot -ExcludeSchemaAnnotation:$ExcludeSchemaAnnotation
    $json = ConvertTo-Json -InputObject $canonical -Depth 100 -Compress
    return Get-BootstrapSha256 -Text $json
}

function Get-NormalizedBootstrapConfiguration {
    param([Parameter(Mandatory)]$Config)

    $normalized = ConvertTo-BootstrapCanonicalValue -Value $Config -IsRoot -ExcludeSchemaAnnotation
    if ($normalized -isnot [System.Collections.IDictionary]) {
        throw 'Bootstrap configuration must be a JSON object.'
    }

    foreach ($name in @('subscriptionId', 'tenantId')) {
        if ($normalized.Contains($name)) {
            $parsed = [guid]::Empty
            if ([guid]::TryParse([string]$normalized[$name], [ref]$parsed)) {
                $normalized[$name] = $parsed.ToString('D')
            }
        }
    }

    if ($normalized.Contains('agent365') -and $normalized['agent365'] -is [Collections.IDictionary]) {
        $normalized['agent365']['reviewedManagerApplicationIds'] = @(
            $normalized['agent365']['reviewedManagerApplicationIds'] | ForEach-Object {
                $parsed = [guid]::Empty
                if ([guid]::TryParse([string]$_, [ref]$parsed)) { $parsed.ToString('D') }
                else { [string]$_ }
            } | Sort-Object -Unique
        )
    }
    return ConvertTo-BootstrapCanonicalValue -Value $normalized -IsRoot
}

function Get-BootstrapConfigurationFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $normalized = Get-NormalizedBootstrapConfiguration -Config $Config
    $json = ConvertTo-Json -InputObject $normalized -Depth 100 -Compress
    return Get-BootstrapSha256 -Text $json
}

function Get-BootstrapAzureCliArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $effectiveArguments = @($Arguments)
    if ([string]::IsNullOrWhiteSpace($script:BootstrapAzureSubscriptionId)) {
        if (-not [string]::IsNullOrWhiteSpace($script:BootstrapAzureTenantId) -and
            ($Arguments.Count -eq 0 -or $Arguments[0] -notin @('ad','account','version','bicep'))) {
            throw 'Azure resource operations require an explicitly selected subscription.'
        }
        return $effectiveArguments
    }
    if ([string]::IsNullOrWhiteSpace($script:BootstrapAzureTenantId)) {
        throw 'Azure CLI invocation requires the exact bootstrap tenant context after authentication.'
    }
    if ($effectiveArguments.Count -eq 0) {
        throw 'Azure CLI invocation requires a command group after bootstrap authentication.'
    }

    $explicitSubscriptions = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $effectiveArguments.Count; $index++) {
        $argument = [string]$effectiveArguments[$index]
        if ($argument -ceq '--subscription') {
            if ($index + 1 -ge $effectiveArguments.Count -or
                [string]::IsNullOrWhiteSpace([string]$effectiveArguments[$index + 1])) {
                throw 'Azure CLI --subscription requires the exact bootstrap subscription ID.'
            }
            $explicitSubscriptions.Add([string]$effectiveArguments[$index + 1])
        }
        elseif ($argument.StartsWith('--subscription=', [StringComparison]::Ordinal)) {
            $explicitSubscriptions.Add($argument.Substring('--subscription='.Length))
        }
    }
    if ($explicitSubscriptions.Count -gt 1) {
        throw 'Azure CLI arguments contain more than one explicit subscription target.'
    }
    if ($explicitSubscriptions.Count -eq 1 -and
        $explicitSubscriptions[0] -cne $script:BootstrapAzureSubscriptionId) {
        throw 'Azure CLI arguments do not match the exact bootstrap subscription context.'
    }

    $commandGroup = [string]$effectiveArguments[0]
    if ($commandGroup -ceq 'resource') {
        $typeIndex = [Array]::IndexOf($effectiveArguments, '--resource-type')
        if ($effectiveArguments.Count -lt 4 -or $effectiveArguments[1] -cne 'list' -or
            $typeIndex -lt 2 -or $typeIndex + 1 -ge $effectiveArguments.Count -or
            $effectiveArguments[$typeIndex + 1] -cne 'Microsoft.CognitiveServices/accounts') {
            throw 'Only Content Safety account inventory is allowed through Azure CLI resource commands.'
        }
        if ($explicitSubscriptions.Count -eq 0) {
            $effectiveArguments += @('--subscription', $script:BootstrapAzureSubscriptionId)
        }
        return $effectiveArguments
    }
    $resourceCommandGroups = @('cognitiveservices', 'deployment', 'group', 'role')
    if ($resourceCommandGroups -ccontains $commandGroup) {
        if ($explicitSubscriptions.Count -eq 0) {
            $effectiveArguments += @('--subscription', $script:BootstrapAzureSubscriptionId)
        }
        return $effectiveArguments
    }

    if ($commandGroup -ceq 'account') {
        if ($effectiveArguments.Count -lt 2) {
            throw 'Azure CLI account invocation requires one reviewed subcommand.'
        }
        $accountSubcommand = [string]$effectiveArguments[1]
        if ($accountSubcommand -ceq 'show') {
            if ($explicitSubscriptions.Count -ne 0) {
                throw 'Post-authentication account show is an active-context probe and must not name a subscription.'
            }
            return $effectiveArguments
        }
        if ($accountSubcommand -ceq 'get-access-token') {
            if ($explicitSubscriptions.Count -eq 0) {
                $effectiveArguments += @('--subscription', $script:BootstrapAzureSubscriptionId)
            }
            return $effectiveArguments
        }
        throw "Azure CLI account subcommand '$accountSubcommand' is not allowed after bootstrap authentication."
    }

    if ($commandGroup -ceq 'bicep') {
        if ($explicitSubscriptions.Count -ne 0) {
            throw 'Local Azure CLI Bicep commands must not carry a subscription selector.'
        }
        $bicepSubcommand = if ($effectiveArguments.Count -ge 2) {
            [string]$effectiveArguments[1]
        }
        else {
            ''
        }
        $isExactUninstall =
            $effectiveArguments.Count -eq 2 -and $bicepSubcommand -ceq 'uninstall'
        if (@('build', 'install', 'version') -cnotcontains $bicepSubcommand -and
            -not $isExactUninstall) {
            throw 'Only reviewed local Azure CLI Bicep commands are allowed after bootstrap authentication.'
        }
        return $effectiveArguments
    }

    if ($commandGroup -ceq 'version') {
        if ($explicitSubscriptions.Count -ne 0) {
            throw 'Local Azure CLI version inspection must not carry a subscription selector.'
        }
        return $effectiveArguments
    }

    if ($commandGroup -ceq 'rest') {
        throw 'Native Azure CLI rest is not allowed after bootstrap authentication. Microsoft Graph must use the exact-account in-process Graph boundary.'
    }
    if ($commandGroup -ceq 'ad') {
        throw 'Tenant-scoped Azure CLI ad commands are not allowed after bootstrap authentication. Microsoft Graph must use the exact-account in-process Graph boundary.'
    }
    if ($commandGroup -ceq 'login') {
        throw 'Azure CLI login is not allowed after the exact bootstrap authentication context is established.'
    }
    throw "Azure CLI command group '$commandGroup' is not in the reviewed post-authentication allowlist."
}

function Set-BootstrapDiagnosticsDirectory {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Path)

    $script:BootstrapDiagnosticsDirectory = if ([string]::IsNullOrWhiteSpace($Path)) {
        ''
    }
    else {
        [IO.Path]::GetFullPath($Path)
    }
}

function Get-BootstrapProviderFailureSignature {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Output)

    # Only two tightly bounded token shapes are allowed to cross this trust
    # boundary: a provider error code whose entire value is a short identifier,
    # and a correlation GUID. Provider prose, request/response bodies, headers,
    # identities, and credentials can never match either shape, so a signature
    # is safe to place in an error message, a checkpoint, or the Setup UI.
    $signature = [ordered]@{ codes = @(); correlationIds = @() }
    if ([string]::IsNullOrWhiteSpace($Output)) { return $signature }

    $codes = [ordered]@{}
    # Azure CLI can render this policy denial as prose without a JSON error code.
    if ($Output.Contains('without authenticating through MFA', [StringComparison]::OrdinalIgnoreCase) -and
        $Output -match 'https://aka\.ms/MFAforAzure(?:\.(?=\s|$)|(?=\s|$))') {
        $codes['AzureMfaRequired'] = $true
    }
    foreach ($match in [regex]::Matches($Output, '"(?:code|errorCode)"\s*:\s*"([A-Za-z][A-Za-z0-9._-]{0,63})"')) {
        $codes[[string]$match.Groups[1].Value] = $true
        if ($codes.Count -ge 8) { break }
    }
    $correlationIds = [ordered]@{}
    $correlationPattern =
        '(?i)(?:tracking\s+id\s+is|correlation[-_ ]?(?:request[-_ ]?)?id)\D{0,4}' +
        '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
    foreach ($match in [regex]::Matches($Output, $correlationPattern)) {
        $correlationIds[([string]$match.Groups[1].Value).ToLowerInvariant()] = $true
        if ($correlationIds.Count -ge 4) { break }
    }
    $signature.codes = @($codes.Keys | ForEach-Object { [string]$_ })
    $signature.correlationIds = @($correlationIds.Keys | ForEach-Object { [string]$_ })
    return $signature
}

function Write-BootstrapProviderDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Output
    )

    if ([string]::IsNullOrWhiteSpace($script:BootstrapDiagnosticsDirectory)) { return '' }
    if ([string]::IsNullOrWhiteSpace($Output)) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $script:BootstrapDiagnosticsDirectory)) {
            New-Item -ItemType Directory -Path $script:BootstrapDiagnosticsDirectory -Force | Out-Null
        }
        $safeCommand = [regex]::Replace([IO.Path]::GetFileNameWithoutExtension($CommandName), '[^A-Za-z0-9._-]', '-')
        if ([string]::IsNullOrWhiteSpace($safeCommand)) { $safeCommand = 'command' }
        if ($safeCommand.Length -gt 24) { $safeCommand = $safeCommand.Substring(0, 24) }
        $fileName = '{0}-{1}-{2}.json' -f `
            [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ'), $safeCommand, [guid]::NewGuid().ToString('N').Substring(0, 8)
        $path = Join-Path $script:BootstrapDiagnosticsDirectory $fileName
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
        Set-BootstrapRestrictedFilePermission -Path $path
        # Ignored files and filesystem ACLs do not authorize retaining raw provider
        # bodies. Persist only the same bounded signature allowed in the UI/state.
        $signature = Get-BootstrapProviderFailureSignature -Output $Output
        $record = [ordered]@{
            schemaVersion = 1
            kind = 'ProviderFailureSignature'
            command = $safeCommand
            exitCode = $ExitCode
            capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            codes = @($signature.codes)
            correlationIds = @($signature.correlationIds)
        }
        [IO.File]::WriteAllText($path, ($record | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
        return $path
    }
    catch {
        # Diagnostics are best effort. A failure to persist them must never
        # replace or mask the provider failure that is already being reported.
        return ''
    }
}

function Set-BootstrapRestrictedFilePermission {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ($IsWindows) {
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $currentSid = $currentIdentity.User
        $currentIdentity.Dispose()
        if ($null -eq $currentSid) {
            throw 'Could not resolve the current Windows identity for a restricted bootstrap file.'
        }
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($existingRule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($existingRule) }
        $acl.SetOwner($currentSid)
        $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $currentSid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow))
        Set-Acl -LiteralPath $Path -AclObject $acl
        return
    }
    $chmod = Get-BootstrapSingleApplicationCommand -Name 'chmod'
    if ($null -eq $chmod) { throw 'Could not locate chmod before writing a restricted bootstrap file.' }
    & $chmod.Source 600 $Path
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict a bootstrap file to the current user.' }
}

function Get-BootstrapSingleApplicationCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Name)

    $commands = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0) { return $null }
    return $commands |
        Sort-Object -Property Source |
        Select-Object -First 1
}

function New-BootstrapProviderFailureException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Output,
        [switch]$OutputWasNotCaptured
    )

    $signature = Get-BootstrapProviderFailureSignature -Output $Output
    $parts = @("Command '$CommandName' failed with exit code $ExitCode.")
    if ($signature.codes.Count -gt 0) {
        $parts += "Provider error codes: $($signature.codes -join ' > ')."
    }
    elseif ($OutputWasNotCaptured) {
        $parts += 'Provider output was not captured at this trust boundary.'
    }
    else {
        $parts += 'The provider returned no structured error code.'
    }
    if ($signature.correlationIds.Count -gt 0) {
        $parts += "Provider correlation IDs: $($signature.correlationIds -join ', ')."
    }
    $diagnosticPath = if ($OutputWasNotCaptured) {
        ''
    }
    else {
        Write-BootstrapProviderDiagnostic -CommandName $CommandName -ExitCode $ExitCode -Output $Output
    }
    if (-not [string]::IsNullOrWhiteSpace($diagnosticPath)) {
        $parts += "A bounded provider failure signature was written to the local operator file '$diagnosticPath'."
    }
    else {
        $parts += 'Provider output was suppressed at this trust boundary.'
    }
    $exception = [InvalidOperationException]::new(($parts -join ' '))
    $exception.Data['GatewayProviderErrorCodes'] = [string[]]@($signature.codes)
    $exception.Data['GatewayProviderCorrelationIds'] = [string[]]@($signature.correlationIds)
    $exception.Data['GatewayProviderDiagnosticPath'] = [string]$diagnosticPath
    return $exception
}

function Get-BootstrapExceptionProviderErrorCodes {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][Exception]$Exception)

    $current = $Exception
    for ($depth = 0; $depth -lt 8 -and $null -ne $current; $depth++) {
        $codes = $current.Data['GatewayProviderErrorCodes']
        # Revalidate exception metadata at the consuming boundary using the same
        # bounds as Get-BootstrapProviderFailureSignature, never arbitrary text.
        if ($codes -is [string[]] -and $codes.Count -gt 0 -and $codes.Count -le 8 -and
            @($codes | Where-Object { $_ -cnotmatch '^[A-Za-z][A-Za-z0-9._-]{0,63}$' }).Count -eq 0) {
            return @($codes)
        }
        $current = $current.InnerException
    }
    return @()
}

function Get-BootstrapCommandProgressLabel {
    <#
        .SYNOPSIS
        Builds a safe display label for a child command from its leading verbs.

        .DESCRIPTION
        Only leading arguments whose entire value is a short lowercase verb token
        are kept, and at most three of them. Flags, flag values, URLs, file paths,
        resource IDs, GUIDs, image references, and credentials cannot match that
        shape, so the label carries the command vocabulary and nothing else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][AllowEmptyCollection()][string[]]$ArgumentList = @()
    )

    $name = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'command' }
    $verbs = @()
    foreach ($argument in $ArgumentList) {
        if ($verbs.Count -ge 3) { break }
        if ([string]$argument -cnotmatch '^[a-z][a-z0-9-]{0,20}$') { break }
        $verbs += [string]$argument
    }
    return (@($name) + $verbs) -join ' '
}

function Write-BootstrapCommandProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][ValidateSet('Started', 'Completed')][string]$Phase,
        [Parameter()][int]$DurationMilliseconds = 0
    )

    if ($null -eq $script:BootstrapProgressSink) { return }
    try {
        & $script:BootstrapProgressSink $Label $Phase $DurationMilliseconds
    }
    catch {
        # Progress rendering is decorative. A sink failure must never mask or
        # replace the provider result the caller is waiting for.
    }
}





function Invoke-BootstrapCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [switch]$AllowFailure,
        [switch]$NoCapture,
        [switch]$CaptureStdoutOnly
    )

    if ($NoCapture -and $CaptureStdoutOnly) {
        throw 'NoCapture and CaptureStdoutOnly cannot be combined.'
    }

    $progressLabel = Get-BootstrapCommandProgressLabel -FilePath $FilePath -ArgumentList $ArgumentList
    $progressTimer = [Diagnostics.Stopwatch]::StartNew()
    Write-BootstrapCommandProgress -Label $progressLabel -Phase Started

    $resolvedFile = $FilePath
    $effectiveArguments = @($ArgumentList)
    if ($FilePath -eq 'az') {
        $effectiveArguments = @(Get-BootstrapAzureCliArguments -Arguments $effectiveArguments)
    }
    if ($IsWindows -and $FilePath -eq 'az') {
        $azCommand = Get-Command az -ErrorAction Stop
        if ($azCommand.Source.EndsWith('.cmd', [StringComparison]::OrdinalIgnoreCase)) {
            $azPython = [IO.Path]::GetFullPath((Join-Path (Split-Path $azCommand.Source -Parent) '..\python.exe'))
            if (Test-Path -LiteralPath $azPython) {
                $resolvedFile = $azPython
                $effectiveArguments = @('-IBm', 'azure.cli') + $effectiveArguments
            }
        }
    }

    # This wrapper owns native exit-code handling and emits the fixed redacted
    # failure contract below, regardless of the caller's PowerShell preference.
    $PSNativeCommandUseErrorActionPreference = $false

    if ($NoCapture) {
        # A no-capture child may still emit dependency bodies, identities, or
        # credentials on stderr. Progress is represented by trusted bootstrap
        # events, so never stream an untrusted child directly to either text or
        # structured UI output.
        & $resolvedFile @effectiveArguments *> $null
        $exitCode = $LASTEXITCODE
        $progressTimer.Stop()
        Write-BootstrapCommandProgress -Label $progressLabel -Phase Completed -DurationMilliseconds ([int]$progressTimer.ElapsedMilliseconds)
        if ($exitCode -ne 0 -and -not $AllowFailure) {
            throw (New-BootstrapProviderFailureException -CommandName $FilePath -ExitCode $exitCode -Output '' -OutputWasNotCaptured)
        }
        return $exitCode
    }

    if ($CaptureStdoutOnly) {
        # Some successful native commands write informational provider text to
        # stderr before returning machine-readable JSON. This opt-in boundary
        # captures only stdout and discards stderr without persisting it.
        $output = & $resolvedFile @effectiveArguments 2>$null
    }
    else {
        $output = & $resolvedFile @effectiveArguments 2>&1
    }
    $exitCode = $LASTEXITCODE
    $progressTimer.Stop()
    Write-BootstrapCommandProgress -Label $progressLabel -Phase Completed -DurationMilliseconds ([int]$progressTimer.ElapsedMilliseconds)
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        # The captured text stays inside this boundary. Only the bounded provider
        # error codes, correlation GUIDs, and a local operator file path are
        # reported onward, so the failure is diagnosable without leaking bodies.
        throw (New-BootstrapProviderFailureException -CommandName $FilePath -ExitCode $exitCode -Output ($output | Out-String))
    }
    return ($output | Out-String).Trim()
}

function Get-BootstrapGraphAccessToken {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($script:BootstrapAzureTenantId)) {
        throw 'Microsoft Graph access requires the exact bootstrap tenant context.'
    }

    $minimumExpiry = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300
    if (-not [string]::IsNullOrWhiteSpace($script:BootstrapGraphAccessToken) -and
        $script:BootstrapGraphAccessTokenExpiresOn -gt $minimumExpiry) {
        return $script:BootstrapGraphAccessToken
    }

    $rawTokenResponse = $null
    $tokenResponse = $null
    $accessToken = ''
    try {
        $tokenArguments = @(
            'account', 'get-access-token',
            '--resource', 'https://graph.microsoft.com/',
            '--output', 'json', '--only-show-errors'
        )
        if ($script:BootstrapAzureSubscriptionId) { $tokenArguments += @('--subscription',$script:BootstrapAzureSubscriptionId) }
        else { $tokenArguments += @('--tenant',$script:BootstrapAzureTenantId) }
        $rawTokenResponse = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList $tokenArguments
        if ([string]::IsNullOrWhiteSpace($rawTokenResponse)) {
            throw 'Exact-account Microsoft Graph token acquisition returned no metadata.'
        }
        try {
            $tokenResponse = ConvertFrom-Json -InputObject $rawTokenResponse -Depth 20 -ErrorAction Stop
        }
        catch {
            throw 'Exact-account Microsoft Graph token acquisition returned malformed metadata.'
        }

        $expiresOn = 0L
        if ($null -eq $tokenResponse -or
            ($script:BootstrapAzureSubscriptionId -and [string]$tokenResponse.subscription -cne $script:BootstrapAzureSubscriptionId) -or
            [string]$tokenResponse.tenant -cne $script:BootstrapAzureTenantId -or
            [string]$tokenResponse.tokenType -cne 'Bearer' -or
            -not [long]::TryParse(
                [string]$tokenResponse.expires_on,
                [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$expiresOn) -or
            $expiresOn -le $minimumExpiry) {
            throw 'Exact-account Microsoft Graph token metadata did not match the reviewed subscription, tenant, type, and lifetime.'
        }
        $accessToken = [string]$tokenResponse.accessToken
        if ([string]::IsNullOrWhiteSpace($accessToken) -or
            $accessToken.Length -gt 131072 -or $accessToken -match '\s') {
            throw 'Exact-account Microsoft Graph token material had an invalid bounded shape.'
        }

        $script:BootstrapGraphAccessToken = $accessToken
        $script:BootstrapGraphAccessTokenExpiresOn = $expiresOn
        return $script:BootstrapGraphAccessToken
    }
    finally {
        $accessToken = ''
        $tokenResponse = $null
        $rawTokenResponse = $null
    }
}

function ConvertFrom-BootstrapGraphAzRestArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    if ($Arguments.Count -lt 1 -or [string]$Arguments[0] -cne 'rest') {
        throw 'The Microsoft Graph boundary requires one Azure CLI rest-shaped argument contract.'
    }

    $method = ''
    $url = ''
    $body = $null
    $output = 'json'
    $headers = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $seenOnlyShowErrors = $false
    for ($index = 1; $index -lt $Arguments.Count; $index++) {
        $argument = [string]$Arguments[$index]
        switch -CaseSensitive ($argument) {
            '--method' {
                if (-not [string]::IsNullOrWhiteSpace($method) -or $index + 1 -ge $Arguments.Count) {
                    throw 'Microsoft Graph request contains a missing or duplicate method.'
                }
                $method = ([string]$Arguments[++$index]).ToUpperInvariant()
            }
            { $_ -ceq '--url' -or $_ -ceq '--uri' } {
                if (-not [string]::IsNullOrWhiteSpace($url) -or $index + 1 -ge $Arguments.Count) {
                    throw 'Microsoft Graph request contains a missing or duplicate URL.'
                }
                $url = [string]$Arguments[++$index]
            }
            '--body' {
                if ($null -ne $body -or $index + 1 -ge $Arguments.Count) {
                    throw 'Microsoft Graph request contains a missing or duplicate body.'
                }
                $body = [string]$Arguments[++$index]
            }
            '--headers' {
                $headerCount = 0
                while ($index + 1 -lt $Arguments.Count -and
                    -not ([string]$Arguments[$index + 1]).StartsWith('--', [StringComparison]::Ordinal)) {
                    $headerText = [string]$Arguments[++$index]
                    $separator = $headerText.IndexOf('=')
                    if ($separator -le 0 -or $separator -eq $headerText.Length - 1) {
                        throw 'Microsoft Graph request header must use the reviewed name=value shape.'
                    }
                    $name = $headerText.Substring(0, $separator)
                    $value = $headerText.Substring($separator + 1)
                    if ($headers.ContainsKey($name)) {
                        throw 'Microsoft Graph request contains a duplicate header.'
                    }
                    if (($name -ceq 'Content-Type' -and $value -cne 'application/json') -or
                        ($name -ceq 'OData-Version' -and $value -cne '4.0') -or
                        $name -cnotin @('Content-Type', 'OData-Version')) {
                        throw 'Microsoft Graph request contains a header outside the reviewed JSON/OData boundary.'
                    }
                    $headers.Add($name, $value)
                    $headerCount++
                }
                if ($headerCount -eq 0) {
                    throw 'Microsoft Graph request declared headers without a reviewed value.'
                }
            }
            { $_ -ceq '--output' -or $_ -ceq '-o' } {
                if ($index + 1 -ge $Arguments.Count) {
                    throw 'Microsoft Graph request output selector is missing its value.'
                }
                $output = [string]$Arguments[++$index]
                if ($output -cnotin @('json', 'none')) {
                    throw 'Microsoft Graph request output selector must be json or none.'
                }
            }
            '--only-show-errors' {
                if ($seenOnlyShowErrors) {
                    throw 'Microsoft Graph request contains a duplicate error-output selector.'
                }
                $seenOnlyShowErrors = $true
            }
            default {
                throw "Microsoft Graph request argument '$argument' is outside the reviewed boundary."
            }
        }
    }

    if ($method -cnotin @('GET', 'POST', 'PATCH', 'DELETE')) {
        throw 'Microsoft Graph request method is outside the reviewed GET/POST/PATCH/DELETE boundary.'
    }
    if (($method -cin @('POST', 'PATCH') -and [string]::IsNullOrWhiteSpace([string]$body)) -or
        ($method -cin @('GET', 'DELETE') -and $null -ne $body)) {
        throw 'Microsoft Graph request body does not match the reviewed method contract.'
    }
    if ($null -ne $body) {
        if ($body.Length -gt 1048576) {
            throw 'Microsoft Graph request body exceeds the reviewed one-megabyte boundary.'
        }
        try { $null = ConvertFrom-Json -InputObject $body -Depth 100 -ErrorAction Stop }
        catch { throw 'Microsoft Graph request body is not valid JSON.' }
    }

    $uri = $null
    if ([string]::IsNullOrWhiteSpace($url) -or $url.Length -gt 16384 -or
        -not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or
        -not $uri.DnsSafeHost.Equals('graph.microsoft.com', [StringComparison]::OrdinalIgnoreCase) -or
        (-not $uri.IsDefaultPort -and $uri.Port -ne 443) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or
        -not $uri.AbsolutePath.StartsWith('/v1.0/', [StringComparison]::Ordinal)) {
        throw 'Microsoft Graph request URL must remain on the exact public-cloud HTTPS v1.0 boundary.'
    }

    return [pscustomobject]@{
        method = $method
        uri = $uri
        body = $body
        output = $output
        headers = $headers
    }
}

function Get-BootstrapGraphHttpClient {
    if ($null -eq $script:BootstrapGraphHttpClient) {
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [Net.Http.HttpClient]::new($handler, $true)
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        $script:BootstrapGraphHttpClient = $client
    }
    return $script:BootstrapGraphHttpClient
}

function Invoke-BootstrapGraphAzRest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $descriptor = ConvertFrom-BootstrapGraphAzRestArguments -Arguments $Arguments
    $token = Get-BootstrapGraphAccessToken
    $request = $null
    $response = $null
    $responseText = $null
    $responseStream = $null
    $responseBuffer = $null
    $readCancellation = $null
    $readBuffer = $null
    try {
        $request = [Net.Http.HttpRequestMessage]::new(
            [Net.Http.HttpMethod]::new([string]$descriptor.method),
            [Uri]$descriptor.uri)
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        $request.Headers.Accept.Add([Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json'))
        if ($descriptor.headers.ContainsKey('OData-Version')) {
            if (-not $request.Headers.TryAddWithoutValidation('OData-Version', [string]$descriptor.headers['OData-Version'])) {
                throw 'Microsoft Graph OData header could not be applied at the trusted request boundary.'
            }
        }
        if ($null -ne $descriptor.body) {
            $request.Content = [Net.Http.StringContent]::new(
                [string]$descriptor.body,
                [Text.Encoding]::UTF8,
                'application/json')
        }

        try {
            $response = (Get-BootstrapGraphHttpClient).SendAsync(
                $request,
                [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        }
        catch {
            throw 'Microsoft Graph request failed before a trusted HTTP response was available; provider details were suppressed.'
        }
        if (-not $response.IsSuccessStatusCode) {
            throw "Microsoft Graph request returned HTTP $([int]$response.StatusCode); provider body was suppressed."
        }
        if ($null -eq $response.Content) { return $null }
        $contentLength = $response.Content.Headers.ContentLength
        if ($null -ne $contentLength -and [long]$contentLength -gt 16777216) {
            throw 'Microsoft Graph response exceeded the reviewed sixteen-megabyte boundary.'
        }

        $readCancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(60))
        try {
            # Keep compatibility with the repository's PowerShell 7.0 floor
            # (.NET Core 3.1); the cancellable size-bounded reads below enforce
            # the independent content timeout.
            $responseStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        }
        catch {
            throw 'Microsoft Graph response content was unavailable within the trusted read boundary; provider details were suppressed.'
        }
        $responseBuffer = [IO.MemoryStream]::new()
        $readBuffer = [byte[]]::new(81920)
        $totalBytes = 0L
        while ($true) {
            try {
                $bytesRead = $responseStream.ReadAsync(
                    $readBuffer,
                    0,
                    $readBuffer.Length,
                    $readCancellation.Token).GetAwaiter().GetResult()
            }
            catch {
                throw 'Microsoft Graph response content was not read within the trusted time and size boundary; provider details were suppressed.'
            }
            if ($bytesRead -eq 0) { break }
            $totalBytes += [long]$bytesRead
            if ($totalBytes -gt 16777216) {
                throw 'Microsoft Graph response exceeded the reviewed sixteen-megabyte boundary.'
            }
            $responseBuffer.Write($readBuffer, 0, $bytesRead)
        }
        try {
            $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
            $responseText = $strictUtf8.GetString($responseBuffer.ToArray())
        }
        catch {
            throw 'Microsoft Graph returned malformed UTF-8 JSON; provider content was suppressed.'
        }
        if ([string]::IsNullOrWhiteSpace($responseText)) { return $null }
        try {
            return ConvertFrom-Json -InputObject $responseText -Depth 100 -ErrorAction Stop
        }
        catch {
            throw 'Microsoft Graph returned malformed JSON; provider content was suppressed.'
        }
    }
    finally {
        $token = ''
        $responseText = $null
        if ($null -ne $readBuffer) { [Array]::Clear($readBuffer, 0, $readBuffer.Length) }
        if ($null -ne $responseBuffer) { $responseBuffer.Dispose() }
        if ($null -ne $responseStream) { $responseStream.Dispose() }
        if ($null -ne $readCancellation) { $readCancellation.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
    }
}

function ConvertFrom-BootstrapJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json)

    $convertParameters = @{ Depth = 100; NoEnumerate = $true; ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $convertParameters.DateKind = 'String'
    }
    # The wrapper also normalizes a root timestamp on PowerShell 7.0-7.4,
    # without changing JSON objects into hashtables or losing nested arrays.
    $parsed = @{ value = ConvertFrom-Json -InputObject $Json @convertParameters }
    Convert-BootstrapParsedJsonDatesToStrings -Value $parsed
    return $parsed.value
}

function Invoke-AzJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$CaptureStdoutOnly
    )
    if ($Arguments.Count -gt 0 -and [string]$Arguments[0] -ceq 'rest') {
        if ($CaptureStdoutOnly) {
            throw 'Stdout-only Azure JSON capture is not available for Microsoft Graph requests.'
        }
        return Invoke-BootstrapGraphAzRest -Arguments ($Arguments + @('--output', 'json', '--only-show-errors'))
    }
    $command = @{
        FilePath = 'az'
        ArgumentList = $Arguments + @('--output', 'json', '--only-show-errors')
    }
    if ($CaptureStdoutOnly) { $command.CaptureStdoutOnly = $true }
    $raw = Invoke-BootstrapCommand @command
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    if (-not $CaptureStdoutOnly) {
        return ConvertFrom-BootstrapJson -Json $raw
    }
    try {
        return ConvertFrom-BootstrapJson -Json $raw
    }
    catch {
        throw 'Azure CLI returned malformed JSON; provider output was suppressed.'
    }
}

function Invoke-AzTsv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    return (Invoke-BootstrapCommand -FilePath 'az' -ArgumentList ($Arguments + @('--output', 'tsv', '--only-show-errors'))).Trim()
}

function Assert-GuidValue {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Label)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Label must be a non-empty GUID."
    }
}

function Get-RepositoryRoot {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (-not (Test-Path (Join-Path $root 'Gateway.slnx'))) {
        throw 'Bootstrap must run from a complete A365 Custom Gateway repository checkout.'
    }
    return $root
}

function Assert-BootstrapSourcePathIsRegular {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )

    if ([IO.Path]::IsPathRooted($RelativePath) -or
        @($RelativePath.Replace('\', '/').Split('/') | Where-Object { $_ -eq '..' }).Count -gt 0) {
        throw 'Bootstrap source discovery returned a path outside the repository boundary.'
    }
    $rootFullPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFullPath $RelativePath))
    if (-not $candidate.StartsWith($rootFullPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
        throw 'Bootstrap source discovery returned a path outside the repository boundary.'
    }

    if (([IO.File]::GetAttributes($rootFullPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Bootstrap source roots must not contain symbolic links or reparse points. Use a regular repository checkout before planning.'
    }
    $partial = $rootFullPath
    foreach ($segment in $RelativePath.Replace('\', '/').Split('/', [StringSplitOptions]::RemoveEmptyEntries)) {
        $partial = [IO.Path]::Combine($partial, $segment)
        if (([IO.File]::GetAttributes($partial) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Bootstrap source must not contain symbolic links or reparse points. Replace the linked deployment input with a regular file or directory before planning.'
        }
    }
    return $true
}

function Test-BootstrapSourcePathIsSensitive {
    param([Parameter(Mandatory)][string]$RelativePath)

    $path = $RelativePath.Replace('\', '/')
    $name = [IO.Path]::GetFileName($path)
    if ($path -match '(?i)(^|/)\.secrets?(?:\.|/|$)' -or
        $path -match '(?i)(^|/)(\.azure|\.aws|\.ssh|\.kube|\.docker|\.gnupg)(/|$)' -or
        $name -match '(?i)^(\.npmrc|\.yarnrc(?:\.yml)?|\.pypirc|\.netrc|id_(rsa|dsa|ecdsa|ed25519)(\.pub)?|authorized_keys|credentials\.json|secrets\.json|service[-_.]?account.*\.json|accessTokens\.json|azureProfile\.json|tokenCache\.dat)$' -or
        $name -match '(?i)^(credentials?|secrets?|tokens?|passwords?|apikeys?|private[-_.]?settings)[-_.]?.*\.(json|ya?ml|xml|ini|config|txt)$' -or
        $name -match '(?i)^appsettings\.(?!json$).+\.json$' -or
        $name -match '(?i)\.(pfx|p12|pem|key|jks|keystore|kdbx|mobileprovision|suo|user)$') {
        return $true
    }
    return $false
}

function Get-BootstrapSourceManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $root = [IO.Path]::GetFullPath($Root)
    [string[]]$sourceRoots = @(
        'bootstrap',
        'infrastructure',
        'src',
        'web/console',
        'web/setup',
        'deploy/runtime',
        'tools/Gateway.Setup',
        'gateway',
        'gateway.cmd',
        'Gateway.slnx',
        '.dockerignore',
        'global.json',
        'nuget.config',
        'Directory.Build.props',
        'Directory.Build.targets',
        'Directory.Packages.props'
    ) | Sort-Object -Unique

    $relativePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git -and (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        foreach ($mode in @('tracked', 'untracked')) {
            $arguments = if ($mode -eq 'tracked') {
                @('-C', $root, 'ls-files', '--') + $sourceRoots
            }
            else {
                @('-C', $root, 'ls-files', '--others', '--exclude-standard', '--') + $sourceRoots
            }
            $listed = & $git.Source @arguments 2>$null
            if ($LASTEXITCODE -eq 0) {
                foreach ($path in @($listed)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
                        $null = $relativePaths.Add(([string]$path).Replace('\', '/'))
                    }
                }
            }
        }
    }

    if ($relativePaths.Count -eq 0) {
        foreach ($sourceRoot in $sourceRoots) {
            $fullSourceRoot = Join-Path $root $sourceRoot
            if (Test-Path -LiteralPath $fullSourceRoot -PathType Leaf) {
                $null = $relativePaths.Add($sourceRoot.Replace('\', '/'))
                continue
            }
            if (Test-Path -LiteralPath $fullSourceRoot -PathType Container) {
                foreach ($file in Get-ChildItem -LiteralPath $fullSourceRoot -File -Recurse) {
                    $null = $relativePaths.Add([IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/'))
                }
            }
        }
    }

    [string[]]$safeRelativePaths = @($relativePaths | Where-Object {
        $_ -notmatch '(?i)(^|/)(bin|obj|dist|node_modules|\.bootstrap|\.git)(/|$)' -and
        $_ -notmatch '(?i)\.tsbuildinfo$' -and
        $_ -ine 'bootstrap/config.json' -and
        $_ -notmatch '(?i)(^|/)\.secrets?(?:\.|/|$)' -and
        $_ -notmatch '(?i)(^|/)\.env(?:\.|$)' -and
        $_ -notmatch '(?i)(^|/)appsettings\.(development|local)\.json$' -and
        -not (Test-BootstrapSourcePathIsSensitive -RelativePath ([string]$_))
    })
    [Array]::Sort($safeRelativePaths, [StringComparer]::Ordinal)
    if ($safeRelativePaths.Count -eq 0) {
        throw 'No deployment source files were found for bootstrap plan binding.'
    }

    return @($safeRelativePaths | ForEach-Object {
        $relativePath = $_
        $path = Join-Path $root $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        Assert-BootstrapSourcePathIsRegular -Root $root -RelativePath $relativePath | Out-Null
        $contentHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        [ordered]@{
            path = $relativePath
            sha256 = $contentHash
        }
    })
}

function Get-BootstrapSourceFingerprint {
    [CmdletBinding()]
    param([Parameter()][string]$Root = '')

    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Get-RepositoryRoot }
    $manifest = @(Get-BootstrapSourceManifest -Root $Root)
    if ($manifest.Count -eq 0) { throw 'No deployment source files were found for bootstrap plan binding.' }
    return Get-BootstrapObjectFingerprint -InputObject $manifest
}

function Get-BootstrapSourceMetadata {
    param([Parameter()][string]$Root = '')
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Get-RepositoryRoot }
    $root = [IO.Path]::GetFullPath($Root)
    $commit = 'unknown'
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git -and (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        $commitOutput = & $git.Source -C $root rev-parse --verify HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and [string]$commitOutput -match '^[0-9a-fA-F]{40,64}$') {
            $commit = ([string]$commitOutput).Trim().ToLowerInvariant()
        }
    }

    return [ordered]@{
        repositoryCommit = $commit
        bootstrapSourceFingerprint = Get-BootstrapSourceFingerprint -Root $root
    }
}

function New-BootstrapAcceptedSourceSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$PlanFingerprint,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    Assert-BootstrapFingerprintValue -Value $PlanFingerprint -Label 'PlanFingerprint'
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'SourceFingerprint'
    $root = Get-RepositoryRoot
    $currentManifest = @(Get-BootstrapSourceManifest -Root $root)
    if ((Get-BootstrapObjectFingerprint -InputObject $currentManifest) -cne $SourceFingerprint) {
        throw 'Bootstrap source changed while the accepted execution snapshot was being prepared.'
    }
    $ownershipId = ([guid][string]$State.deploymentOwnershipId).ToString('D')
    $relative = ".bootstrap/accepted-source/$ownershipId/$($PlanFingerprint.Substring(7))"
    $destination = [IO.Path]::GetFullPath((Join-Path $root $relative))
    $acceptedRoot = [IO.Path]::GetFullPath((Join-Path $root '.bootstrap/accepted-source'))
    if (-not $destination.StartsWith($acceptedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
        throw 'Accepted execution snapshot path escaped its managed local boundary.'
    }
    if (Test-Path -LiteralPath $destination) {
        if ((Get-BootstrapSourceFingerprint -Root $destination) -cne $SourceFingerprint) {
            throw 'An existing accepted execution snapshot does not match the reviewed source fingerprint.'
        }
        return $relative
    }

    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    $temporary = "$destination.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.Directory]::CreateDirectory($temporary) | Out-Null
        foreach ($entry in $currentManifest) {
            $source = [IO.Path]::GetFullPath((Join-Path $root ([string]$entry.path)))
            $target = [IO.Path]::GetFullPath((Join-Path $temporary ([string]$entry.path)))
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            $sourceStream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $targetStream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $sourceStream.CopyTo($targetStream)
                    $targetStream.Flush($true)
                }
                finally { $targetStream.Dispose() }
            }
            finally { $sourceStream.Dispose() }
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry.sha256) {
                throw 'A deployment source file changed while its accepted execution snapshot was being copied.'
            }
            try { [IO.File]::SetAttributes($target, [IO.File]::GetAttributes($target) -bor [IO.FileAttributes]::ReadOnly) } catch { }
        }
        if ((Get-BootstrapSourceFingerprint -Root $temporary) -cne $SourceFingerprint) {
            throw 'The completed accepted execution snapshot does not match the reviewed source fingerprint.'
        }
        [IO.Directory]::Move($temporary, $destination)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Get-ChildItem -LiteralPath $temporary -File -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { try { $_.IsReadOnly = $false } catch { } }
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
    return $relative
}

function Resolve-BootstrapAcceptedSourceRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State, [ref]$SourceMetadata)

    if (-not $State.Contains('acceptedPlan') -or $State.acceptedPlan -isnot [System.Collections.IDictionary] -or
        -not $State.acceptedPlan.Contains('executionSource') -or
        [string]$State.acceptedPlan.executionSource -cnotmatch '^\.bootstrap/accepted-source/[0-9a-f-]{36}/[0-9a-f]{64}$') {
        throw 'The accepted plan has no valid content-addressed execution snapshot.'
    }
    Assert-BootstrapFingerprintValue -Value ([string]$State.acceptedPlan.planFingerprint) -Label 'Accepted plan fingerprint'
    Assert-BootstrapFingerprintValue -Value ([string]$State.acceptedPlan.sourceFingerprint) -Label 'Accepted source fingerprint'
    $canonicalOwnershipId = ([guid][string]$State.deploymentOwnershipId).ToString('D')
    $expectedRelative = ".bootstrap/accepted-source/$canonicalOwnershipId/$(([string]$State.acceptedPlan.planFingerprint).Substring(7))"
    if ([string]$State.acceptedPlan.executionSource -cne $expectedRelative) {
        throw 'The accepted plan execution snapshot is not bound to this exact state ownership and plan fingerprint.'
    }
    $root = Get-RepositoryRoot
    $acceptedRoot = [IO.Path]::GetFullPath((Join-Path $root '.bootstrap/accepted-source'))
    $snapshot = [IO.Path]::GetFullPath((Join-Path $root ([string]$State.acceptedPlan.executionSource)))
    if (-not $snapshot.StartsWith($acceptedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal) -or
        -not (Test-Path -LiteralPath $snapshot -PathType Container)) {
        throw 'The accepted plan execution snapshot is absent, modified, or outside its managed boundary.'
    }
    $metadata = Get-BootstrapSourceMetadata -Root $snapshot
    if ($metadata.bootstrapSourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint) {
        throw 'The accepted plan execution snapshot is absent, modified, or outside its managed boundary.'
    }
    if ($null -ne $SourceMetadata) { $SourceMetadata.Value = $metadata }
    return $snapshot
}

function Read-BootstrapConfigurationFileBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][int]$MaximumBytes = $script:BootstrapConfigurationMaximumBytes
    )

    if ($MaximumBytes -le 0) {
        throw 'Bootstrap configuration byte limit must be greater than zero.'
    }

    $stream = $null
    $content = $null
    $buffer = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read)
        $content = [IO.MemoryStream]::new()
        $buffer = [byte[]]::new(81920)
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($content.Length + $read -gt $MaximumBytes) {
                throw "Bootstrap configuration exceeds the $MaximumBytes-byte maximum."
            }
            $content.Write($buffer, 0, $read)
        }
        return ,$content.ToArray()
    }
    finally {
        if ($null -ne $buffer) { [Array]::Clear($buffer, 0, $buffer.Length) }
        if ($null -ne $content) { $content.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-BootstrapConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][string]$ExpectedConfigurationFileFingerprint = ''
    )

    $expectedFingerprintSupplied = $PSBoundParameters.ContainsKey('ExpectedConfigurationFileFingerprint')
    if ($expectedFingerprintSupplied) {
        if ($ExpectedConfigurationFileFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
            throw 'Expected configuration file fingerprint must be a canonical SHA-256 fingerprint.'
        }
    }

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    [byte[]]$bytes = Read-BootstrapConfigurationFileBytes -Path $resolved
    $raw = ''
    try {
        if ($expectedFingerprintSupplied) {
            $actualFingerprint = Get-BootstrapByteFingerprint -Bytes $bytes
            if ($actualFingerprint -cne $ExpectedConfigurationFileFingerprint) {
                throw 'Bootstrap configuration file fingerprint did not match the expected reviewed bytes.'
            }
        }
        try {
            $raw = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xfeff) {
                $raw = $raw.Substring(1)
            }
        }
        catch {
            throw "Bootstrap configuration '$resolved' is not valid UTF-8 JSON."
        }
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
    try {
        $config = ConvertFrom-Json -InputObject $raw -Depth 30 -ErrorAction Stop
    }
    catch {
        throw "Bootstrap configuration '$resolved' is not valid JSON."
    }

    $null = Get-GatewayDeployProfile -Config $config

    $schemaInput = $raw
    $schemaPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../config.schema.json'))
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        throw "Bootstrap configuration schema is missing at '$schemaPath'."
    }
    $schemaErrors = @()
    $schemaValid = Test-Json -Json $schemaInput -SchemaFile $schemaPath -ErrorVariable +schemaErrors `
        -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -InformationAction SilentlyContinue
    if (-not $schemaValid) {
        throw 'Bootstrap configuration failed JSON Schema validation. Review property names, types, formats, and allowed values against bootstrap/config.schema.json; rejected input values were suppressed.'
    }

    $deployProfile = Get-GatewayDeployProfile -Config $config
    $requiresAzureProductResources = $config.promptShield.enabled -eq $true

    # Optional Azure product fields are absent when Content Safety is disabled.
    # Populate internal empty values only after validating the submitted JSON.
    foreach ($optional in @('subscriptionId', 'location', 'resourceGroupName')) {
        if ($config.PSObject.Properties.Name -notcontains $optional) {
            $config | Add-Member -MemberType NoteProperty -Name $optional -Value ''
        }
    }

    foreach ($name in @('tenantId', 'environment', 'projectName')) {
        if ([string]::IsNullOrWhiteSpace([string]$config.$name)) { throw "Config property '$name' is required." }
    }
    if ($requiresAzureProductResources) {
        foreach ($name in @('subscriptionId', 'location', 'resourceGroupName')) {
            if ([string]::IsNullOrWhiteSpace([string]$config.$name)) {
                throw "Config property '$name' is required for this deploy profile / Prompt Shields selection."
            }
        }
    }

    Assert-GuidValue -Value ([string]$config.tenantId) -Label 'tenantId'
    $config.tenantId = ([guid][string]$config.tenantId).ToString('D')
    if (-not [string]::IsNullOrWhiteSpace([string]$config.subscriptionId)) {
        Assert-GuidValue -Value ([string]$config.subscriptionId) -Label 'subscriptionId'
        $config.subscriptionId = ([guid][string]$config.subscriptionId).ToString('D')
    }
    if ([string]$config.environment -notin @('dev', 'staging', 'prod')) { throw 'environment must be dev, staging, or prod.' }
    if ([string]$config.projectName -notmatch '^[a-z][a-z0-9]{1,7}$') { throw 'projectName must be 2-8 lowercase alphanumeric characters starting with a letter.' }
    if (-not [string]::IsNullOrWhiteSpace([string]$config.resourceGroupName) -and
        [string]$config.resourceGroupName -notmatch '^(?=.{1,90}$)[A-Za-z0-9._()\-]*[A-Za-z0-9_()\-]$') {
        throw 'resourceGroupName is invalid or ends with a period.'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$config.location) -and
        [string]$config.location -notmatch '^[a-z0-9]+$') {
        throw 'location must be an Azure region name such as koreacentral.'
    }

    if ($null -eq $config.runtime -or [string]::IsNullOrWhiteSpace([string]$config.runtime.apiHostPort)) {
            throw 'runtime.apiHostPort is required for the runtime deploy profile.'
        }
        $apiHostPort = 0
        if (-not [int]::TryParse([string]$config.runtime.apiHostPort, [ref]$apiHostPort) -or
            $apiHostPort -lt 1 -or $apiHostPort -gt 65535) {
            throw 'runtime.apiHostPort must be an integer between 1 and 65535.'
        }
    if ($config.runtime.apiHostPort -eq $config.runtime.consoleHostPort) {
        throw 'API and Console ports must be different.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.agent365.seedBlueprintName) -or ([string]$config.agent365.seedBlueprintName).Length -gt 100) { throw 'agent365.seedBlueprintName must contain 1-100 characters.' }
    $reviewedManagerIds = [Collections.Generic.List[string]]::new()
    $seenManagerIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (@($config.agent365.reviewedManagerApplicationIds).Count -gt 10) {
        throw 'agent365.reviewedManagerApplicationIds accepts at most ten independently reviewed Microsoft first-party application IDs.'
    }
    foreach ($value in @($config.agent365.reviewedManagerApplicationIds)) {
        $managerId = [guid]::Empty
        if (-not [guid]::TryParse([string]$value, [ref]$managerId) -or $managerId -eq [guid]::Empty) {
            throw 'agent365.reviewedManagerApplicationIds must contain only non-empty GUIDs.'
        }
        $normalizedManagerId = $managerId.ToString('D')
        if (-not $seenManagerIds.Add($normalizedManagerId)) {
            throw 'agent365.reviewedManagerApplicationIds must not contain duplicates.'
        }
        $reviewedManagerIds.Add($normalizedManagerId)
    }
    if ($reviewedManagerIds.Count -eq 0) {
        throw 'agent365.reviewedManagerApplicationIds requires at least one independently reviewed tenant/provider manager application ID; blueprint discovery alone is not authorization.'
    }
    $config.agent365.reviewedManagerApplicationIds = @($reviewedManagerIds | Sort-Object)
    if ($config.environment -ne 'dev' -and $config.agent365.allowDevelopmentRegistryPreview -eq $true) {
        throw 'Agent 365 Registry beta cannot be enabled for staging or production.'
    }
    if ($config.agent365.allowDevelopmentRegistryPreview -eq $true -and
        $config.agent365.registryBetaAcknowledged -ne $true) {
        throw 'Agent 365 Registry beta requires explicit acknowledgement that it is unsupported for production.'
    }
    if ($config.promptShield.enabled -eq $true -and
        $config.promptShield.costAndQuotaAcknowledged -ne $true) {
        throw 'Prompt Shields requires explicit review of quota and Azure cost.'
    }
    if ($config.purview.enabled -eq $true -and
        $config.purview.authorityRequirementsAcknowledged -ne $true) {
        throw 'Microsoft Purview prerequisites require explicit review of tenant authority and post-deployment administration requirements.'
    }
    return $config
}

function Get-BootstrapStatePath {
    param([Parameter(Mandatory)]$Config)
    $root = Get-RepositoryRoot
    $profile = Get-GatewayDeployProfile -Config $Config
    return Join-Path $root ".bootstrap/state/runtime-$($Config.tenantId)-$($Config.projectName)-$($Config.environment).json"

}

function New-BootstrapState {
    param([Parameter(Mandatory)]$Config)

    $source = Get-BootstrapSourceMetadata
    $profile = Get-GatewayDeployProfile -Config $Config
    $deploymentKey = "runtime/$($Config.tenantId)/$($Config.projectName)/$($Config.environment)"
    return [ordered]@{
        schemaVersion = $script:BootstrapStateSchemaVersion
        bootstrapVersion = $script:BootstrapVersion
        deploymentKey = $deploymentKey
        deploymentOwnershipId = [guid]::NewGuid().ToString('D')
        configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $Config
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        configuration = [ordered]@{
            deployProfile = $profile
            subscriptionId = [string]$Config.subscriptionId
            tenantId = [string]$Config.tenantId
            environment = [string]$Config.environment
            location = [string]$Config.location
            projectName = [string]$Config.projectName
            resourceGroupName = [string]$Config.resourceGroupName
        }
        source = [ordered]@{
            created = $source
            lastWritten = $source
        }
        steps = [ordered]@{}
        outputs = [ordered]@{}
    }
}

function Test-BootstrapStateHasEvidence {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)

    foreach ($name in @('steps', 'outputs')) {
        if (-not $State.Contains($name) -or $null -eq $State[$name]) { continue }
        if ($State[$name] -isnot [System.Collections.IDictionary]) { return $true }
        if ($State[$name].Count -gt 0) { return $true }
    }
    return $false
}

function Get-BootstrapDeploymentIdentityFieldNames {
    # Deployment identity pins which Azure objects the recorded evidence describes.
    # New-BootstrapState persists exactly these fields under state.configuration.
    return @('subscriptionId', 'tenantId', 'environment', 'location', 'projectName', 'resourceGroupName')
}

function Assert-BootstrapDeploymentIdentityUnchanged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)]$Config
    )

    if (-not $State.Contains('configuration') -or $State['configuration'] -isnot [System.Collections.IDictionary]) {
        throw 'Bootstrap state contains reusable evidence but no recorded deployment identity. Refusing to reconcile a configuration change; preserve the state for review and choose a distinct deployment identity.'
    }

    $recordedIdentity = $State['configuration']
    $changed = [Collections.Generic.List[string]]::new()
    foreach ($field in (Get-BootstrapDeploymentIdentityFieldNames)) {
        $recorded = if ($recordedIdentity.Contains($field)) { [string]$recordedIdentity[$field] } else { '' }
        $current = [string]$Config.$field
        # GUID identity fields are compared in canonical form so a pure formatting
        # difference is never mistaken for a different deployment.
        if ($field -cin @('subscriptionId', 'tenantId')) {
            $recordedGuid = [guid]::Empty
            $currentGuid = [guid]::Empty
            if ([guid]::TryParse($recorded, [ref]$recordedGuid) -and [guid]::TryParse($current, [ref]$currentGuid)) {
                $recorded = $recordedGuid.ToString('D')
                $current = $currentGuid.ToString('D')
            }
        }
        # Case-insensitive, matching the deploymentKey comparison above.
        if ($recorded -ne $current) { $changed.Add($field) }
    }
    if ($changed.Count -gt 0) {
        throw "Bootstrap deployment identity changed after state evidence was recorded ($($changed -join ', ')). Refusing to reuse completed, running, or failed steps. Restore the recorded deployment identity or choose a distinct deployment identity; do not edit the state file."
    }
    return $true
}

function Add-BootstrapConfigurationChangeRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$PreviousFingerprint,
        [Parameter(Mandatory)][string]$Fingerprint
    )

    # Fingerprints only. Configuration is non-secret by contract but still names
    # operators, tenants, and resources, so the audit trail records the transition
    # rather than the content. The reopened steps are the reviewable diff.
    $records = [Collections.Generic.List[object]]::new()
    if ($State.Contains('configurationChanges') -and
        $State['configurationChanges'] -is [System.Collections.IEnumerable] -and
        $State['configurationChanges'] -isnot [string]) {
        foreach ($record in $State['configurationChanges']) { $records.Add($record) }
    }

    $records.Add([ordered]@{
        changedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        bootstrapVersion = $script:BootstrapVersion
        previousConfigurationFingerprint = $PreviousFingerprint
        configurationFingerprint = $Fingerprint
    })
    while ($records.Count -gt $script:BootstrapConfigurationChangeHistoryLimit) { $records.RemoveAt(0) }
    $State['configurationChanges'] = @($records)
}

function Assert-BootstrapFingerprintValue {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Value -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "$Label must be a canonical SHA-256 fingerprint."
    }
}

function Convert-BootstrapParsedJsonDatesToStrings {
    param([Parameter()][AllowNull()]$Value)

    if ($null -eq $Value) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $child = $Value[$key]
            if ($child -is [DateTime]) {
                $Value[$key] = ([DateTimeOffset]$child).ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($child -is [DateTimeOffset]) {
                $Value[$key] = $child.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($child -is [System.Collections.IDictionary] -or $child -is [pscustomobject] -or
                ($child -is [System.Collections.IList] -and $child -isnot [string])) {
                Convert-BootstrapParsedJsonDatesToStrings -Value $child
            }
        }
        return
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            $child = $property.Value
            if ($child -is [DateTime]) {
                $property.Value = ([DateTimeOffset]$child).ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($child -is [DateTimeOffset]) {
                $property.Value = $child.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                Convert-BootstrapParsedJsonDatesToStrings -Value $child
            }
        }
        return
    }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            $child = $Value[$index]
            if ($child -is [DateTime]) {
                $Value[$index] = ([DateTimeOffset]$child).ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($child -is [DateTimeOffset]) {
                $Value[$index] = $child.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
            }
            elseif ($child -is [System.Collections.IDictionary] -or $child -is [pscustomobject] -or
                ($child -is [System.Collections.IList] -and $child -isnot [string])) {
                Convert-BootstrapParsedJsonDatesToStrings -Value $child
            }
        }
    }
}

function Read-BootstrapState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Config)
    if (-not (Test-Path -LiteralPath $Path)) { return New-BootstrapState -Config $Config }

    try {
        $rawState = Get-Content -LiteralPath $Path -Raw
        $convertParameters = @{ Depth = 100; AsHashtable = $true; ErrorAction = 'Stop' }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $convertParameters['DateKind'] = 'String'
        }
        $state = $rawState | ConvertFrom-Json @convertParameters
        # PowerShell versions before 7.5 have no DateKind switch and Json.NET
        # coerces ISO-8601 state strings to DateTime. Normalize those values back
        # to the persisted string contract before any restart validation.
        Convert-BootstrapParsedJsonDatesToStrings -Value $state
    }
    catch {
        throw "Bootstrap state '$Path' is not valid JSON. Preserve it for diagnosis; do not edit it to claim completion."
    }
    if ($state -isnot [System.Collections.IDictionary]) {
        throw "Bootstrap state '$Path' must contain a JSON object."
    }

    $profile = Get-GatewayDeployProfile -Config $Config
    $expected = "runtime/$($Config.tenantId)/$($Config.projectName)/$($Config.environment)"
    $recordedDeploymentKey = if ($state.Contains('deploymentKey')) { [string]$state['deploymentKey'] } else { '' }
    if ($recordedDeploymentKey -ne $expected) { throw "State belongs to '$recordedDeploymentKey', not '$expected'." }

    $schemaVersion = 0
    $recordedSchemaVersion = if ($state.Contains('schemaVersion')) { [string]$state['schemaVersion'] } else { '' }
    if (-not [int]::TryParse($recordedSchemaVersion, [ref]$schemaVersion)) {
        throw "Bootstrap state '$Path' has no supported schema version."
    }
    if ($schemaVersion -gt $script:BootstrapStateSchemaVersion) {
        throw "Bootstrap state schema $schemaVersion is newer than this bootstrap supports ($script:BootstrapStateSchemaVersion). Upgrade the repository before continuing."
    }
    if ($schemaVersion -lt 1) {
        throw "Bootstrap state schema $schemaVersion is unsupported. Preserve the file for diagnosis."
    }

    if ($schemaVersion -ne $script:BootstrapStateSchemaVersion) {
        throw "Bootstrap state schema $schemaVersion is unsupported by bootstrap $script:BootstrapVersion."
    }
    if (-not $state.Contains('bootstrapVersion') -or [string]$state['bootstrapVersion'] -notmatch '^\d+\.\d+\.\d+$') {
        throw "Bootstrap state '$Path' is missing valid bootstrap version metadata."
    }
    if (-not $state.Contains('steps') -or $state['steps'] -isnot [System.Collections.IDictionary] -or
        -not $state.Contains('outputs') -or $state['outputs'] -isnot [System.Collections.IDictionary]) {
        throw "Bootstrap state '$Path' has invalid step or output collections."
    }
    if (-not $state.Contains('deploymentOwnershipId') -or
        [string]::IsNullOrWhiteSpace([string]$state['deploymentOwnershipId'])) {
        if (Test-BootstrapStateHasEvidence -State $state) {
            throw 'Bootstrap state contains reusable evidence but no deployment ownership identifier. Refusing Entra application adoption; preserve the state for review and use the original bootstrap version.'
        }
        return New-BootstrapState -Config $Config
    }
    Assert-GuidValue -Value ([string]$state['deploymentOwnershipId']) -Label 'State deploymentOwnershipId'
    if (-not $state.Contains('source') -or $state['source'] -isnot [System.Collections.IDictionary] -or
        -not $state['source'].Contains('created') -or $state['source']['created'] -isnot [System.Collections.IDictionary] -or
        -not $state['source'].Contains('lastWritten') -or $state['source']['lastWritten'] -isnot [System.Collections.IDictionary]) {
        throw "Bootstrap state '$Path' is missing source metadata."
    }

    $recordedFingerprint = if ($state.Contains('configurationFingerprint')) { [string]$state['configurationFingerprint'] } else { '' }
    Assert-BootstrapFingerprintValue -Value $recordedFingerprint -Label 'State configurationFingerprint'
    $expectedFingerprint = Get-BootstrapConfigurationFingerprint -Config $Config
    if ($recordedFingerprint -cne $expectedFingerprint) {
        if (Test-BootstrapStateHasEvidence -State $state) {
            # Deployment identity is immutable for a state file; every other setting is a
            # reconcilable deployment input. Rebind the fingerprint and let each step's own
            # Validate block decide which recorded evidence still matches the new
            # configuration. This never widens what may run: the accepted plan is bound to
            # the state fingerprint, so Apply and Up stay closed until the operator
            # reviews a fresh plan for the changed configuration.
            Assert-BootstrapDeploymentIdentityUnchanged -State $state -Config $Config | Out-Null
            Add-BootstrapConfigurationChangeRecord `
                -State $state `
                -PreviousFingerprint $recordedFingerprint `
                -Fingerprint $expectedFingerprint
            $state['configurationFingerprint'] = $expectedFingerprint
            return $state
        }
        return New-BootstrapState -Config $Config
    }

    return $state
}

function Save-BootstrapState {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State, [Parameter(Mandatory)][string]$Path)

    $stateSchemaVersion = if ($State.Contains('schemaVersion')) { [string]$State['schemaVersion'] } else { '' }
    if ($stateSchemaVersion -notmatch '^\d+$' -or [int]$stateSchemaVersion -ne $script:BootstrapStateSchemaVersion) {
        throw "Refusing to write bootstrap state schema '$stateSchemaVersion' with bootstrap $script:BootstrapVersion."
    }
    $stateConfigurationFingerprint = if ($State.Contains('configurationFingerprint')) { [string]$State['configurationFingerprint'] } else { '' }
    Assert-BootstrapFingerprintValue -Value $stateConfigurationFingerprint -Label 'State configurationFingerprint'
    $stateOwnershipId = if ($State.Contains('deploymentOwnershipId')) { [string]$State['deploymentOwnershipId'] } else { '' }
    Assert-GuidValue -Value $stateOwnershipId -Label 'State deploymentOwnershipId'

    $source = if ($State.Contains('acceptedPlan')) {
        $verifiedMetadata = $null
        $null = Resolve-BootstrapAcceptedSourceRoot -State $State -SourceMetadata ([ref]$verifiedMetadata)
        $verifiedMetadata
    }
    else {
        Get-BootstrapSourceMetadata
    }
    if ($State.Contains('acceptedPlan')) {
        $acceptedPlan = $State['acceptedPlan']
        if ($acceptedPlan -isnot [System.Collections.IDictionary] -or
            -not $acceptedPlan.Contains('sourceFingerprint') -or
            -not $acceptedPlan.Contains('configurationFingerprint') -or
            [string]$acceptedPlan['sourceFingerprint'] -cne [string]$source.bootstrapSourceFingerprint -or
            [string]$acceptedPlan['configurationFingerprint'] -cne $stateConfigurationFingerprint) {
            throw 'Bootstrap source or configuration changed after plan acceptance. No further state transition or mutation is authorized; restore the reviewed bytes and generate a fresh plan.'
        }
    }
    $State['bootstrapVersion'] = $script:BootstrapVersion
    if (-not $State.Contains('source') -or $State['source'] -isnot [System.Collections.IDictionary]) {
        $State['source'] = [ordered]@{ created = $source; lastWritten = $source }
    }
    else {
        if (-not $State['source'].Contains('created') -or $State['source']['created'] -isnot [System.Collections.IDictionary]) {
            $State['source']['created'] = $source
        }
        $State['source']['lastWritten'] = $source
    }
    $State['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ".$([IO.Path]::GetFileName($fullPath)).$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject $State -Depth 100
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
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

function Set-BootstrapAcceptedPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$PlanFingerprint,
        [Parameter()][string]$ConfigurationFingerprint = '',
        [Parameter()][string]$SourceFingerprint = ''
    )

    Assert-BootstrapFingerprintValue -Value $PlanFingerprint -Label 'PlanFingerprint'
    if ([string]::IsNullOrWhiteSpace($ConfigurationFingerprint)) {
        $ConfigurationFingerprint = if ($State.Contains('configurationFingerprint')) { [string]$State['configurationFingerprint'] } else { '' }
    }
    Assert-BootstrapFingerprintValue -Value $ConfigurationFingerprint -Label 'ConfigurationFingerprint'
    if ($ConfigurationFingerprint -cne [string]$State['configurationFingerprint']) {
        throw 'The plan configuration fingerprint does not match this bootstrap state.'
    }

    $currentSourceFingerprint = Get-BootstrapSourceFingerprint
    if ([string]::IsNullOrWhiteSpace($SourceFingerprint)) { $SourceFingerprint = $currentSourceFingerprint }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'SourceFingerprint'
    if ($SourceFingerprint -cne $currentSourceFingerprint) {
        throw 'Bootstrap source changed before plan acceptance. Generate and review a fresh plan.'
    }

    $executionSource = New-BootstrapAcceptedSourceSnapshot `
        -State $State `
        -PlanFingerprint $PlanFingerprint `
        -SourceFingerprint $SourceFingerprint
    $State['acceptedPlan'] = [ordered]@{
        planFingerprint = $PlanFingerprint
        configurationFingerprint = $ConfigurationFingerprint
        sourceFingerprint = $SourceFingerprint
        executionSource = $executionSource
        bootstrapVersion = $script:BootstrapVersion
        acceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
    Save-BootstrapState -State $State -Path $StatePath
    return $State['acceptedPlan']
}

function Clear-BootstrapAcceptedPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath
    )

    if ($State.Contains('acceptedPlan')) {
        $State.Remove('acceptedPlan')
    }
    Save-BootstrapState -State $State -Path $StatePath
}

Export-ModuleMember -Function *
