Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BootstrapStateSchemaVersion = 2
$script:BootstrapVersion = '2.0.0'
$script:BootstrapEventWriter = $null
$script:BootstrapStructuredOutput = $false
$script:BootstrapExecutionSourceRoot = ''
$script:BootstrapAzureSubscriptionId = ''
$script:BootstrapAzureTenantId = ''
$script:BootstrapGraphAccessToken = ''
$script:BootstrapGraphAccessTokenExpiresOn = 0L
$script:BootstrapGraphHttpClient = $null

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

function Set-BootstrapStructuredOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Enabled)

    $script:BootstrapStructuredOutput = $Enabled
}

function Set-BootstrapEventWriter {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][scriptblock]$Writer)

    $script:BootstrapEventWriter = $Writer
}

function Write-BootstrapEvent {
    param(
        [Parameter(Mandatory)][ValidateSet('Started', 'Completed', 'Failed')][string]$Status,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 .:/()_-]{0,127}$')][string]$StepName,
        [switch]$Reused,
        [switch]$Revalidated
    )

    if ($null -eq $script:BootstrapEventWriter) { return }
    $event = [ordered]@{
        event = 'bootstrap.step'
        status = $Status.ToLowerInvariant()
        step = $StepName
        timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
        reused = [bool]$Reused
        revalidated = [bool]$Revalidated
    }
    try {
        & $script:BootstrapEventWriter $event | Out-Null
    }
    catch {
        if (-not $script:BootstrapStructuredOutput) {
            Write-Warning 'The bootstrap progress event writer failed; deployment state remains authoritative.'
        }
    }
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

function Get-BootstrapDeterministicGuid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Material)

    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Material))
    try {
        $guidBytes = [byte[]]::new(16)
        [Array]::Copy($bytes, $guidBytes, 16)
        # RFC 4122 variant and version 5 bits make the persisted identifier's
        # deterministic provenance explicit without weakening its uniqueness.
        $guidBytes[7] = [byte](($guidBytes[7] -band 0x0f) -bor 0x50)
        $guidBytes[8] = [byte](($guidBytes[8] -band 0x3f) -bor 0x80)
        return ([guid]::new($guidBytes)).ToString('D')
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function ConvertTo-GatewayArmBooleanText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Value)

    # The reviewed Bicep string(bool) deployments are persisted and read back by
    # ARM as invariant .NET Boolean text. Exact Container App validation therefore
    # requires ordinal `True` / `False` casing rather than JSON-style lowercase.
    return $Value.ToString()
}

function Get-GatewayArmBooleanEnvironmentContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$RuntimeEnabled,
        [Parameter(Mandatory)][bool]$RegistryPreviewEnabled,
        [Parameter(Mandatory)][bool]$PurviewEnabled,
        [Parameter(Mandatory)][bool]$PurviewPolicyProvisioningEnabled,
        [Parameter(Mandatory)][bool]$PromptShieldEnabled
    )

    $runtimeText = ConvertTo-GatewayArmBooleanText -Value $RuntimeEnabled
    $previewText = ConvertTo-GatewayArmBooleanText -Value $RegistryPreviewEnabled
    $closedBindingText = ConvertTo-GatewayArmBooleanText -Value (-not $RegistryPreviewEnabled)
    $purviewText = ConvertTo-GatewayArmBooleanText -Value $PurviewEnabled
    $policyText = ConvertTo-GatewayArmBooleanText -Value $PurviewPolicyProvisioningEnabled
    $promptShieldText = ConvertTo-GatewayArmBooleanText -Value $PromptShieldEnabled

    return [ordered]@{
        Api = [ordered]@{
            'Provisioning__ExecutionEnabled' = $previewText
            'Provisioning__RequireExactAdmissionBinding' = $closedBindingText
            'Provisioning__AllowContinuousDevelopmentAccess' = $previewText
            'Agent365__DelegatedRegistry__Enabled' = $previewText
            'Agent365__DelegatedRegistry__RequireExactActionBinding' = $closedBindingText
            'Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess' = $previewText
            'Purview__Enabled' = $purviewText
            'PromptShield__Enabled' = $promptShieldText
            'DatabaseAttestation__Enabled' = $runtimeText
        }
        Worker = [ordered]@{
            'ProvisioningWorker__ProcessingEnabled' = $runtimeText
            'ProvisioningWorker__ProvisioningExecutionEnabled' = $previewText
            'Agent365__DirectRegistryPreviewEnabled' = $previewText
            'Purview__Enabled' = $purviewText
            'Purview__PolicyProvisioningEnabled' = $policyText
        }
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
        [string[]]$names = @($Value.PSObject.Properties.Name)
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

    if ($normalized.Contains('purview') -and $normalized['purview'] -is [System.Collections.IDictionary]) {
        foreach ($entry in ([ordered]@{
            policyProvisioningEnabled = $false
            policyProvisioningOrganization = ''
            policyProvisioningApplicationId = ''
            policyProvisioningCertificateSecretUri = ''
        }).GetEnumerator()) {
            if (-not $normalized['purview'].Contains($entry.Key)) {
                $normalized['purview'][$entry.Key] = $entry.Value
            }
        }

        $applicationId = [string]$normalized['purview']['policyProvisioningApplicationId']
        if (-not [string]::IsNullOrWhiteSpace($applicationId)) {
            $parsed = [guid]::Empty
            if ([guid]::TryParse($applicationId, [ref]$parsed)) {
                $normalized['purview']['policyProvisioningApplicationId'] = $parsed.ToString('D')
            }
        }

        # Defaults were added after the first canonical pass; restore ordinal key order.
        $normalized['purview'] = ConvertTo-BootstrapCanonicalValue -Value $normalized['purview']
    }

    if ($normalized.Contains('agent365') -and $normalized['agent365'] -is [System.Collections.IDictionary]) {
        if (-not $normalized['agent365'].Contains('reviewedManagerApplicationIds')) {
            $normalized['agent365']['reviewedManagerApplicationIds'] = @()
        }
        $normalized['agent365']['reviewedManagerApplicationIds'] = @(
            $normalized['agent365']['reviewedManagerApplicationIds'] |
                ForEach-Object {
                    $parsedManagerId = [guid]::Empty
                    if ([guid]::TryParse([string]$_, [ref]$parsedManagerId)) { $parsedManagerId.ToString('D') }
                    else { [string]$_ }
                } |
                Sort-Object -Unique
        )
        $normalized['agent365'] = ConvertTo-BootstrapCanonicalValue -Value $normalized['agent365']
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

function Write-BootstrapStep {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-BootstrapSuccess {
    param([string]$Message)
    Write-Host "[ok] $Message" -ForegroundColor Green
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
    $resourceCommandGroups = @(
        'acr', 'containerapp', 'deployment', 'eventgrid', 'group', 'identity',
        'keyvault', 'monitor', 'network', 'provider', 'resource', 'role', 'servicebus',
        'sql', 'storage'
    )
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
        if ($effectiveArguments.Count -lt 2 -or
            @('build', 'install', 'version') -cnotcontains [string]$effectiveArguments[1]) {
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
        if ($exitCode -ne 0 -and -not $AllowFailure) {
            throw "Command '$FilePath' failed with exit code $exitCode. Provider output was not included at this trust boundary."
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
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Command '$FilePath' failed with exit code $exitCode. Provider output was suppressed at this trust boundary."
    }
    return ($output | Out-String).Trim()
}

function Get-BootstrapGraphAccessToken {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($script:BootstrapAzureSubscriptionId) -or
        [string]::IsNullOrWhiteSpace($script:BootstrapAzureTenantId)) {
        throw 'Microsoft Graph access requires the exact bootstrap subscription and tenant context.'
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
        $rawTokenResponse = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @(
            'account', 'get-access-token',
            '--subscription', $script:BootstrapAzureSubscriptionId,
            '--resource', 'https://graph.microsoft.com/',
            '--output', 'json', '--only-show-errors'
        )
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
            [string]$tokenResponse.subscription -cne $script:BootstrapAzureSubscriptionId -or
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
        return $raw | ConvertFrom-Json -Depth 100
    }
    try {
        return $raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
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

function Get-BootstrapImageBuildTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Image-build ownership ID must be a canonical lowercase GUID from the current bootstrap state.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Image-build source fingerprint'
    $tag = "bootstrap-$($canonicalOwnershipId.Replace('-', ''))-$($SourceFingerprint.Substring(7))"
    if ($tag.Length -gt 128 -or $tag -cnotmatch '^bootstrap-[0-9a-f]{32}-[0-9a-f]{64}$') {
        throw 'The deterministic image-build tag could not be derived from the accepted state and source.'
    }
    return $tag
}

function Get-BootstrapImageBuildIntentTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$IntentId
    )

    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    $canonicalIntentId = ([guid]$IntentId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId -or $IntentId -cne $canonicalIntentId) {
        throw 'Image-build ownership and intent IDs must be canonical lowercase GUIDs.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Image-build source fingerprint'
    $tag = "bootstrap-$($canonicalOwnershipId.Replace('-', ''))-$($SourceFingerprint.Substring(7, 32))-$($canonicalIntentId.Replace('-', ''))"
    if ($tag.Length -gt 128 -or $tag -cnotmatch '^bootstrap-[0-9a-f]{32}-[0-9a-f]{32}-[0-9a-f]{32}$') {
        throw 'The image-build intent tag could not be derived from the accepted state, source, and durable intent.'
    }
    return $tag
}

function Get-RepositoryRoot {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (-not (Test-Path (Join-Path $root 'src/A365Gateway.slnx'))) {
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

    $current = Get-Item -LiteralPath $rootFullPath -Force -ErrorAction Stop
    if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Bootstrap source roots must not contain symbolic links or reparse points. Use a regular repository checkout before planning.'
    }
    $partial = $rootFullPath
    foreach ($segment in $RelativePath.Replace('\', '/').Split('/', [StringSplitOptions]::RemoveEmptyEntries)) {
        $partial = Join-Path $partial $segment
        if (-not (Test-Path -LiteralPath $partial)) { break }
        $current = Get-Item -LiteralPath $partial -Force -ErrorAction Stop
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Bootstrap source must not contain symbolic links or reparse points. Replace the linked deployment input with a regular file or directory before planning.'
        }
    }
    return $true
}

function Test-BootstrapSourcePathIsSensitive {
    param([Parameter(Mandatory)][string]$RelativePath)

    $path = $RelativePath.Replace('\', '/')
    $name = [IO.Path]::GetFileName($path)
    if ($path -match '(?i)(^|/)(\.azure|\.aws|\.ssh|\.kube|\.docker|\.gnupg)(/|$)' -or
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
        'tools/Gateway.DatabaseMigrator',
        'tools/Gateway.Setup',
        'tools/apply-migrations.ps1',
        'tools/_common.ps1',
        'tools/configure-workflow-v3-entra.ps1',
        'operations/test-provisioning-prerequisites.ps1',
        'gateway',
        'gateway.cmd',
        'gateway.ps1',
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
        $_ -notmatch '(?i)(^|/)(bin|obj|node_modules|\.bootstrap|\.git)(/|$)' -and
        $_ -ine 'bootstrap/config.json' -and
        $_ -notmatch '(?i)(^|/)\.secrets(?:\.|/|$)' -and
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
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)

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
        -not (Test-Path -LiteralPath $snapshot -PathType Container) -or
        (Get-BootstrapSourceFingerprint -Root $snapshot) -cne [string]$State.acceptedPlan.sourceFingerprint) {
        throw 'The accepted plan execution snapshot is absent, modified, or outside its managed boundary.'
    }
    return $snapshot
}

function Resolve-BootstrapDatabaseRecoveryPlanSourceRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    foreach ($name in @('planFingerprint', 'correctedSourceFingerprint', 'executionSource')) {
        if (-not $Plan.Contains($name) -or [string]::IsNullOrWhiteSpace([string]$Plan[$name])) {
            throw 'The accepted database recovery plan is missing its corrected execution-source boundary.'
        }
    }
    Assert-BootstrapFingerprintValue -Value ([string]$Plan.planFingerprint) -Label 'Database recovery plan fingerprint'
    Assert-BootstrapFingerprintValue -Value ([string]$Plan.correctedSourceFingerprint) -Label 'Database recovery corrected source fingerprint'
    $canonicalOwnershipId = ([guid][string]$State.deploymentOwnershipId).ToString('D')
    $expectedRelative = ".bootstrap/accepted-source/$canonicalOwnershipId/$(([string]$Plan.planFingerprint).Substring(7))"
    if ([string]$Plan.executionSource -cne $expectedRelative) {
        throw 'The database recovery execution snapshot is not bound to this exact ownership and recovery plan fingerprint.'
    }
    $root = Get-RepositoryRoot
    $acceptedRoot = [IO.Path]::GetFullPath((Join-Path $root '.bootstrap/accepted-source'))
    $snapshot = [IO.Path]::GetFullPath((Join-Path $root ([string]$Plan.executionSource)))
    if (-not $snapshot.StartsWith($acceptedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal) -or
        -not (Test-Path -LiteralPath $snapshot -PathType Container) -or
        (Get-BootstrapSourceFingerprint -Root $snapshot) -cne [string]$Plan.correctedSourceFingerprint) {
        throw 'The database recovery execution snapshot is absent, modified, or outside its managed boundary.'
    }
    return $snapshot
}

function Resolve-BootstrapDatabaseRecoverySourceRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)

    if (-not $State.Contains('databaseRecoveryPlan') -or
        $State.databaseRecoveryPlan -isnot [System.Collections.IDictionary]) {
        throw 'No accepted database recovery plan exists for this bootstrap state.'
    }
    return Resolve-BootstrapDatabaseRecoveryPlanSourceRoot -State $State -Plan $State.databaseRecoveryPlan
}

function Get-BootstrapEffectiveDeploymentSourceFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter()][string]$ExecutionSourceFingerprint = ''
    )

    if ([string]::IsNullOrWhiteSpace($ExecutionSourceFingerprint)) {
        $ExecutionSourceFingerprint = Get-BootstrapSourceFingerprint
    }
    Assert-BootstrapFingerprintValue -Value $ExecutionSourceFingerprint -Label 'Bootstrap execution source fingerprint'
    if (-not $State.Contains('databaseRecoveryPlan') -or
        $State.databaseRecoveryPlan -isnot [System.Collections.IDictionary] -or
        [string]$State.databaseRecoveryPlan.status -cne 'Completed') {
        return $ExecutionSourceFingerprint
    }
    $recoveryPlan = $State.databaseRecoveryPlan
    Assert-BootstrapFingerprintValue -Value ([string]$recoveryPlan.correctedSourceFingerprint) -Label 'Completed database recovery corrected source fingerprint'
    Assert-BootstrapFingerprintValue -Value ([string]$recoveryPlan.originalSourceFingerprint) -Label 'Completed database recovery original source fingerprint'
    Assert-BootstrapFingerprintValue -Value ([string]$recoveryPlan.databaseEvidenceFingerprint) -Label 'Completed database recovery evidence fingerprint'
    if ([string]$recoveryPlan.correctedSourceFingerprint -cne $ExecutionSourceFingerprint -or
        [string]$recoveryPlan.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D')) {
        throw 'The completed database recovery does not authorize this execution source or deployment ownership.'
    }
    return [string]$recoveryPlan.originalSourceFingerprint
}

function Set-BootstrapExecutionSourceRoot {
    param([Parameter(Mandatory)][string]$Path)
    $script:BootstrapExecutionSourceRoot = [IO.Path]::GetFullPath($Path)
}

function Get-BootstrapExecutionSourceRoot {
    if ([string]::IsNullOrWhiteSpace([string]$script:BootstrapExecutionSourceRoot)) {
        return Get-RepositoryRoot
    }
    return $script:BootstrapExecutionSourceRoot
}

function Read-BootstrapConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $raw = Get-Content -LiteralPath $resolved -Raw
    try {
        $config = $raw | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    }
    catch {
        throw "Bootstrap configuration '$resolved' is not valid JSON."
    }

    $schemaPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../config.schema.json'))
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        throw "Bootstrap configuration schema is missing at '$schemaPath'."
    }
    $schemaErrors = @()
    $schemaValid = Test-Json -Json $raw -SchemaFile $schemaPath -ErrorVariable +schemaErrors `
        -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -InformationAction SilentlyContinue
    if (-not $schemaValid) {
        throw 'Bootstrap configuration failed JSON Schema validation. Review property names, types, formats, and allowed values against bootstrap/config.schema.json; rejected input values were suppressed.'
    }

    foreach ($entry in ([ordered]@{
        policyProvisioningEnabled = $false
        policyProvisioningOrganization = ''
        policyProvisioningApplicationId = ''
        policyProvisioningCertificateSecretUri = ''
    }).GetEnumerator()) {
        if ($config.purview.PSObject.Properties.Name -notcontains $entry.Key) {
            $config.purview | Add-Member -MemberType NoteProperty -Name $entry.Key -Value $entry.Value
        }
    }
    if ($config.agent365.PSObject.Properties.Name -notcontains 'reviewedManagerApplicationIds') {
        $config.agent365 | Add-Member -MemberType NoteProperty -Name reviewedManagerApplicationIds -Value @()
    }
    foreach ($name in @('subscriptionId', 'tenantId', 'environment', 'location', 'projectName', 'resourceGroupName', 'alertEmail')) {
        if ([string]::IsNullOrWhiteSpace([string]$config.$name)) { throw "Config property '$name' is required." }
    }
    Assert-GuidValue -Value ([string]$config.subscriptionId) -Label 'subscriptionId'
    Assert-GuidValue -Value ([string]$config.tenantId) -Label 'tenantId'
    $config.subscriptionId = ([guid][string]$config.subscriptionId).ToString('D')
    $config.tenantId = ([guid][string]$config.tenantId).ToString('D')
    if ([string]$config.environment -notin @('dev', 'staging', 'prod')) { throw 'environment must be dev, staging, or prod.' }
    if ([string]$config.projectName -notmatch '^[a-z][a-z0-9]{1,7}$') { throw 'projectName must be 2-8 lowercase alphanumeric characters starting with a letter so every generated Key Vault name remains valid.' }
    if ([string]$config.resourceGroupName -notmatch '^(?=.{1,90}$)[A-Za-z0-9._()\-]*[A-Za-z0-9_()\-]$') { throw 'resourceGroupName is invalid or ends with a period.' }
    if ([string]$config.location -notmatch '^[a-z0-9]+$') { throw 'location must be an Azure region name such as koreacentral.' }
    if ([string]$config.alertEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'alertEmail must be a valid email address.' }
    if ([string]$config.sql.skuName -notin @('Basic', 'S0', 'S1', 'S2', 'S3', 'P1', 'P2', 'GP_S_Gen5_1', 'GP_S_Gen5_2')) { throw 'sql.skuName is unsupported by the deployment template.' }
    if ([string]$config.sql.skuTier -notin @('Basic', 'Standard', 'Premium', 'GeneralPurpose')) { throw 'sql.skuTier is unsupported by the deployment template.' }
    $expectedSqlTier = switch -Regex ([string]$config.sql.skuName) {
        '^Basic$' { 'Basic'; break }
        '^S[0-3]$' { 'Standard'; break }
        '^P[12]$' { 'Premium'; break }
        '^GP_S_Gen5_[12]$' { 'GeneralPurpose'; break }
        default { $null }
    }
    if ([string]$config.sql.skuTier -ne $expectedSqlTier) {
        throw 'sql.skuName and sql.skuTier must describe the same supported Azure SQL service tier.'
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
        throw 'Agent Registration beta preview can be enabled only for the dev environment.'
    }
    if ($config.purview.enabled -eq $true -and [string]::IsNullOrWhiteSpace([string]$config.purview.sensitiveInformationType)) {
        throw 'purview.sensitiveInformationType is required when Purview is enabled; the bootstrap never invents a tenant DLP classifier.'
    }
    if ($config.purview.enabled -eq $true) {
        foreach ($name in @('collectionPolicyName', 'dlpPolicyName', 'dlpRuleName')) {
            if ([string]::IsNullOrWhiteSpace([string]$config.purview.$name)) { throw "purview.$name is required when Purview is enabled." }
        }
    }
    if ($config.purview.activateGatewayAdapterAfterPolicyReadback -eq $true -and $config.purview.enabled -ne $true) {
        throw 'Purview adapter activation requires purview.enabled=true.'
    }
    if ($config.purview.policyProvisioningEnabled -eq $true) {
        if ($config.purview.enabled -ne $true) {
            throw 'Purview policy-profile automation requires purview.enabled=true.'
        }
        if ($config.purview.activateGatewayAdapterAfterPolicyReadback -ne $true) {
            throw 'Purview policy-profile automation requires activateGatewayAdapterAfterPolicyReadback=true so the requested worker feature cannot be silently deployed disabled.'
        }
        if ([string]$config.purview.policyProvisioningOrganization -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$') {
            throw 'purview.policyProvisioningOrganization must be the verified Microsoft 365 organization domain.'
        }
        Assert-GuidValue -Value ([string]$config.purview.policyProvisioningApplicationId) -Label 'purview.policyProvisioningApplicationId'
        $config.purview.policyProvisioningApplicationId = ([guid][string]$config.purview.policyProvisioningApplicationId).ToString('D')
        $certificateSecretUri = $null
        if (-not [Uri]::TryCreate([string]$config.purview.policyProvisioningCertificateSecretUri, [UriKind]::Absolute, [ref]$certificateSecretUri) -or
            $certificateSecretUri.Scheme -ne 'https' -or
            -not $certificateSecretUri.IsDefaultPort -or
            $certificateSecretUri.Host -notlike '*.vault.azure.net' -or
            $certificateSecretUri.AbsolutePath -notmatch '^/secrets/[A-Za-z0-9-]{1,127}$' -or
            -not [string]::IsNullOrEmpty($certificateSecretUri.Query) -or
            -not [string]::IsNullOrEmpty($certificateSecretUri.Fragment)) {
            throw 'purview.policyProvisioningCertificateSecretUri must be a versionless HTTPS Azure Key Vault secret URI.'
        }
    }
    return $config
}

function Get-BootstrapStatePath {
    param([Parameter(Mandatory)]$Config)
    $root = Get-RepositoryRoot
    return Join-Path $root ".bootstrap/state/$($Config.subscriptionId)-$($Config.resourceGroupName)-$($Config.environment).json"
}

function New-BootstrapState {
    param([Parameter(Mandatory)]$Config)

    $source = Get-BootstrapSourceMetadata
    return [ordered]@{
        schemaVersion = $script:BootstrapStateSchemaVersion
        bootstrapVersion = $script:BootstrapVersion
        deploymentKey = "$($Config.subscriptionId)/$($Config.resourceGroupName)/$($Config.environment)"
        deploymentOwnershipId = [guid]::NewGuid().ToString('D')
        configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $Config
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        configuration = [ordered]@{
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

function Assert-BootstrapStateAllowsSourcePlan {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)

    if (-not (Test-BootstrapStateHasEvidence -State $State)) { return $true }
    if (-not $State.Contains('source') -or $State.source -isnot [System.Collections.IDictionary] -or
        -not $State.source.Contains('lastWritten') -or $State.source.lastWritten -isnot [System.Collections.IDictionary]) {
        throw 'Existing bootstrap evidence has no source provenance. Preserve it for diagnosis and choose a distinct clean deployment identity.'
    }
    $recorded = [string]$State.source.lastWritten.bootstrapSourceFingerprint
    Assert-BootstrapFingerprintValue -Value $recorded -Label 'Recorded evidence source fingerprint'
    $current = Get-BootstrapSourceFingerprint
    if ($recorded -cne $current) {
        if ($State.Contains('databaseRecoveryPlan') -and
            $State.databaseRecoveryPlan -is [System.Collections.IDictionary] -and
            [string]$State.databaseRecoveryPlan.status -ceq 'Completed') {
            $recovery = $State.databaseRecoveryPlan
            Assert-BootstrapDatabaseRecoveryHistory -State $State -CurrentPlan $recovery | Out-Null
            foreach ($name in @('planFingerprint', 'originalSourceFingerprint', 'correctedSourceFingerprint', 'databaseEvidenceFingerprint')) {
                if (-not $recovery.Contains($name)) {
                    throw 'Completed database recovery metadata is incomplete; preserve it for exact reconciliation.'
                }
                Assert-BootstrapFingerprintValue -Value ([string]$recovery[$name]) -Label "Completed database recovery $name"
            }
            $databaseStep = if ($State.steps -is [System.Collections.IDictionary]) { $State.steps['Gateway database'] } else { $null }
            if ([string]$recovery.originalSourceFingerprint -ceq $recorded -and
                [string]$recovery.correctedSourceFingerprint -ceq $current -and
                [string]$recovery.deploymentOwnershipId -ceq ([guid][string]$State.deploymentOwnershipId).ToString('D') -and
                $databaseStep -is [System.Collections.IDictionary] -and
                [string]$databaseStep.status -ceq 'Completed' -and
                $databaseStep.evidence -is [System.Collections.IDictionary] -and
                [string]$databaseStep.evidence.databaseRecoveryPlanFingerprint -ceq [string]$recovery.planFingerprint -and
                (Get-BootstrapObjectFingerprint -InputObject $databaseStep.evidence) -ceq [string]$recovery.databaseEvidenceFingerprint) {
                return $true
            }
        }
        throw 'Bootstrap source changed after durable state evidence was recorded. Clean bootstrap will not mix source generations in one deployment state; restore the exact prior source or choose a distinct project/resource group.'
    }
    return $true
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

function Assert-BootstrapIpv4Value {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Label
    )

    $address = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $address.ToString() -cne $Value) {
        throw "$Label must be one canonical IPv4 address."
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
            elseif ($child -is [System.Collections.IDictionary] -or
                ($child -is [System.Collections.IList] -and $child -isnot [string])) {
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
            elseif ($child -is [System.Collections.IDictionary] -or
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

    $expected = "$($Config.subscriptionId)/$($Config.resourceGroupName)/$($Config.environment)"
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

    if ($schemaVersion -eq 1) {
        if (Test-BootstrapStateHasEvidence -State $state) {
            throw 'Legacy bootstrap state contains reusable evidence but no full configuration fingerprint. Refusing to reuse it because a safe configuration match cannot be proven. Preserve the state and use the original configuration/version for review, or choose a distinct deployment identity.'
        }

        $migrated = New-BootstrapState -Config $Config
        if ($state.Contains('createdAtUtc') -and -not [string]::IsNullOrWhiteSpace([string]$state['createdAtUtc'])) {
            $migrated.createdAtUtc = [string]$state['createdAtUtc']
        }
        $migrated.migration = [ordered]@{
            fromSchemaVersion = 1
            migratedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            reusedEvidence = $false
        }
        return $migrated
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
            throw 'Bootstrap configuration changed after state evidence was recorded. Refusing to reuse completed, running, or failed steps. Restore the exact original configuration or choose a distinct deployment identity; do not edit the state file.'
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
        $acceptedSourceRoot = Resolve-BootstrapAcceptedSourceRoot -State $State
        Get-BootstrapSourceMetadata -Root $acceptedSourceRoot
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
        [Parameter()][string]$SourceFingerprint = '',
        [Parameter(Mandatory)][string]$BootstrapClientIpv4
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
    Assert-BootstrapIpv4Value -Value $BootstrapClientIpv4 -Label 'Legacy SQL bootstrap IPv4 metadata'

    $executionSource = New-BootstrapAcceptedSourceSnapshot `
        -State $State `
        -PlanFingerprint $PlanFingerprint `
        -SourceFingerprint $SourceFingerprint
    $State['acceptedPlan'] = [ordered]@{
        planFingerprint = $PlanFingerprint
        configurationFingerprint = $ConfigurationFingerprint
        sourceFingerprint = $SourceFingerprint
        bootstrapClientIpv4 = $BootstrapClientIpv4
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

function Get-GatewayDatabaseRecoveryAttemptContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [ValidateSet(1, 2)][int]$AttemptNumber = 1
    )

    $suffix = if ($AttemptNumber -eq 1) { '' } else { '2' }
    $jobStem = if ($AttemptNumber -eq 1) { 'db-recover' } else { 'db-recov2' }
    return [ordered]@{
        attemptNumber = $AttemptNumber
        jobName = "job-$($Config.projectName)-$jobStem-$($Config.environment)"
        containerName = "database-recovery$suffix"
        workloadTag = "database-bootstrap-recovery$suffix"
        deploymentName = "a365gw-$($Config.projectName)-bootstrap-database-recovery$suffix-$($Config.environment)"
        whatIfDeploymentName = "a365gw-$($Config.projectName)-bootstrap-database-recovery$suffix-whatif-$($Config.environment)"
        receiptFileName = "private-database-bootstrap-recovery$suffix-receipt.json"
        evidenceDirectoryName = "recovery$suffix"
    }
}

function Test-BootstrapDatabaseRecoveryFailureReceiptCandidate {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][System.Collections.IDictionary]$Receipt)

    if ($null -eq $Receipt) { return $false }
    return -not [string]::IsNullOrWhiteSpace([string]$Receipt.jobStartIntentAtUtc) -and
        -not [string]::IsNullOrWhiteSpace([string]$Receipt.executionName) -and
        -not [string]::IsNullOrWhiteSpace([string]$Receipt.administratorRestoredAtUtc) -and
        [string]::IsNullOrWhiteSpace([string]$Receipt.executionSucceededAtUtc) -and
        [string]::IsNullOrWhiteSpace([string]$Receipt.evidenceFingerprint) -and
        [string]::IsNullOrWhiteSpace([string]$Receipt.evidenceRecoveredAtUtc) -and
        [string]::IsNullOrWhiteSpace([string]$Receipt.completedAtUtc)
}

function Test-BootstrapDatabaseRecoveryRequiresNarrowContinuation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string[]]$ContinuationStepNames
    )

    if (-not $State.Contains('databaseRecoveryPlan') -or
        $State.databaseRecoveryPlan -isnot [System.Collections.IDictionary] -or
        [string]$State.databaseRecoveryPlan.status -cne 'Completed') {
        return $false
    }
    if ($ContinuationStepNames.Count -eq 0) {
        throw 'The recovered-bootstrap continuation step boundary is empty.'
    }
    foreach ($name in $ContinuationStepNames) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw 'The recovered-bootstrap continuation contains an empty step name.'
        }
    }
    # A completed database recovery permanently changes the accepted-source boundary.
    # Even after all continuation steps are marked Completed, only the narrow
    # continuation may reconcile/finalize its receipt after an interruption.
    return $true
}

function Get-BootstrapDatabaseRecoveryAttemptNumber {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan)

    $attemptNumber = if ($Plan.Contains('attemptNumber')) { [int]$Plan.attemptNumber } else { 1 }
    if ($attemptNumber -notin @(1, 2)) {
        throw 'Database recovery is capped at exactly two independently planned attempts.'
    }
    return $attemptNumber
}

function Assert-BootstrapDatabaseRecoveryHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CurrentPlan
    )

    $attemptNumber = Get-BootstrapDatabaseRecoveryAttemptNumber -Plan $CurrentPlan
    if ($attemptNumber -eq 1) {
        if ($State.Contains('databaseRecoveryHistory') -and @($State.databaseRecoveryHistory).Count -ne 0) {
            throw 'A first database recovery attempt cannot coexist with prior recovery history.'
        }
        return $true
    }
    if (-not $State.Contains('databaseRecoveryHistory') -or @($State.databaseRecoveryHistory).Count -ne 1) {
        throw 'The second database recovery attempt requires exactly one immutable failed-attempt history record.'
    }
    $history = @($State.databaseRecoveryHistory)[0]
    if ($history -isnot [System.Collections.IDictionary] -or
        [int]$history.schemaVersion -ne 1 -or [int]$history.attemptNumber -ne 1 -or
        [string]$history.status -cne 'Failed' -or $history.manualOnly -ne $false -or
        $history.archivedPlan -isnot [System.Collections.IDictionary] -or
        $history.failedRecovery -isnot [System.Collections.IDictionary]) {
        throw 'The database recovery history record is malformed.'
    }
    $historyCore = [ordered]@{}
    foreach ($key in $history.Keys) {
        if ([string]$key -cne 'archiveFingerprint') { $historyCore[[string]$key] = $history[$key] }
    }
    Assert-BootstrapFingerprintValue -Value ([string]$history.archiveFingerprint) -Label 'Database recovery history archive fingerprint'
    if ((Get-BootstrapObjectFingerprint -InputObject $historyCore) -cne [string]$history.archiveFingerprint -or
        [string]$history.planFingerprint -cne [string]$history.archivedPlan.planFingerprint -or
        [string]$history.failureBoundaryFingerprint -cne [string]$history.failedRecovery.boundaryFingerprint -or
        [string]$CurrentPlan.previousRecoveryPlanFingerprint -cne [string]$history.planFingerprint -or
        [string]$CurrentPlan.priorFailedRecovery.boundaryFingerprint -cne [string]$history.failureBoundaryFingerprint -or
        (Get-BootstrapObjectFingerprint -InputObject $CurrentPlan.previousRecoveryPlan) -cne
            (Get-BootstrapObjectFingerprint -InputObject $history.archivedPlan)) {
        throw 'The database recovery history or second-attempt prior-failure binding changed after acceptance.'
    }
    $null = Resolve-BootstrapDatabaseRecoveryPlanSourceRoot -State $State -Plan $history.archivedPlan
    return $true
}

function Set-BootstrapAcceptedDatabaseRecoveryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    if ($State.Contains('databaseRecoveryPlan') -or
        ($State.Contains('databaseRecoveryHistory') -and @($State.databaseRecoveryHistory).Count -ne 0)) {
        throw 'A database recovery plan already exists for this deployment. Recovery is run-once and cannot be replaced.'
    }
    if (-not $State.Contains('acceptedPlan') -or $State.acceptedPlan -isnot [System.Collections.IDictionary]) {
        throw 'Database recovery requires the original accepted deployment plan to remain present.'
    }
    foreach ($name in @(
        'schemaVersion', 'planFingerprint', 'configurationFingerprint', 'deploymentOwnershipId',
        'originalSourceFingerprint', 'correctedSourceFingerprint', 'originalAcceptedPlan',
        'failedJob', 'correctedImage', 'recoveryJob', 'whatIf'
    )) {
        if (-not $Plan.Contains($name)) {
            throw "Database recovery plan is missing '$name'."
        }
    }
    if ([int]$Plan.schemaVersion -ne 1 -or
        [string]$Plan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$Plan.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D') -or
        [string]$Plan.originalSourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint -or
        [string]$Plan.originalAcceptedPlan.planFingerprint -cne [string]$State.acceptedPlan.planFingerprint -or
        [string]$Plan.originalAcceptedPlan.executionSource -cne [string]$State.acceptedPlan.executionSource) {
        throw 'Database recovery plan does not preserve the exact original plan, source, configuration, and ownership boundary.'
    }
    foreach ($fingerprint in @('planFingerprint', 'configurationFingerprint', 'originalSourceFingerprint', 'correctedSourceFingerprint')) {
        Assert-BootstrapFingerprintValue -Value ([string]$Plan[$fingerprint]) -Label "Database recovery $fingerprint"
    }
    $currentSource = Get-BootstrapSourceFingerprint
    if ([string]$Plan.correctedSourceFingerprint -cne $currentSource -or
        [string]$Plan.correctedSourceFingerprint -ceq [string]$Plan.originalSourceFingerprint) {
        throw 'Database recovery requires one reviewed corrected source generation distinct from the failed source.'
    }
    $executionSource = New-BootstrapAcceptedSourceSnapshot `
        -State $State `
        -PlanFingerprint ([string]$Plan.planFingerprint) `
        -SourceFingerprint $currentSource
    $accepted = ConvertTo-BootstrapCanonicalValue -Value $Plan
    $accepted['status'] = 'Accepted'
    $accepted['executionSource'] = $executionSource
    $accepted['acceptedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    $accepted['databaseEvidenceFingerprint'] = ''
    $accepted['completedAtUtc'] = ''
    $State['databaseRecoveryPlan'] = $accepted
    Save-BootstrapState -State $State -Path $StatePath
    return $State.databaseRecoveryPlan
}

function Set-BootstrapAcceptedDatabaseRecoveryContinuationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][System.Collections.IDictionary]$FailedRecovery
    )

    if (-not $State.Contains('databaseRecoveryPlan') -or
        $State.databaseRecoveryPlan -isnot [System.Collections.IDictionary]) {
        throw 'Database recovery continuation requires the preserved first recovery plan.'
    }
    $priorPlan = $State.databaseRecoveryPlan
    if ((Get-BootstrapDatabaseRecoveryAttemptNumber -Plan $priorPlan) -ne 1 -or
        [string]$priorPlan.status -cne 'Running' -or
        ($State.Contains('databaseRecoveryHistory') -and @($State.databaseRecoveryHistory).Count -ne 0)) {
        throw 'Database recovery continuation is allowed only from the sole Running first attempt with no prior history.'
    }
    $null = Resolve-BootstrapDatabaseRecoveryPlanSourceRoot -State $State -Plan $priorPlan
    foreach ($name in @(
        'schemaVersion', 'attemptNumber', 'planFingerprint', 'configurationFingerprint', 'deploymentOwnershipId',
        'originalSourceFingerprint', 'correctedSourceFingerprint', 'originalAcceptedPlan', 'failedJob',
        'previousRecoveryPlanFingerprint', 'previousRecoveryPlan', 'priorFailedRecovery',
        'correctedImage', 'recoveryJob', 'whatIf'
    )) {
        if (-not $Plan.Contains($name)) { throw "The second database recovery plan is missing '$name'." }
    }
    if ([int]$Plan.schemaVersion -ne 2 -or [int]$Plan.attemptNumber -ne 2 -or
        [string]$Plan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$Plan.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D') -or
        [string]$Plan.originalSourceFingerprint -cne [string]$priorPlan.originalSourceFingerprint -or
        [string]$Plan.previousRecoveryPlanFingerprint -cne [string]$priorPlan.planFingerprint -or
        [string]$Plan.priorFailedRecovery.boundaryFingerprint -cne [string]$FailedRecovery.boundaryFingerprint -or
        [string]$FailedRecovery.recoveryPlanFingerprint -cne [string]$priorPlan.planFingerprint -or
        [string]$FailedRecovery.recoverySourceFingerprint -cne [string]$priorPlan.correctedSourceFingerprint -or
        (Get-BootstrapObjectFingerprint -InputObject $Plan.previousRecoveryPlan) -cne
            (Get-BootstrapObjectFingerprint -InputObject $priorPlan)) {
        throw 'The second database recovery plan does not preserve the exact original and prior failed-recovery boundaries.'
    }
    foreach ($fingerprint in @('planFingerprint', 'configurationFingerprint', 'originalSourceFingerprint', 'correctedSourceFingerprint', 'previousRecoveryPlanFingerprint')) {
        Assert-BootstrapFingerprintValue -Value ([string]$Plan[$fingerprint]) -Label "Database recovery continuation $fingerprint"
    }
    $currentSource = Get-BootstrapSourceFingerprint
    if ([string]$Plan.correctedSourceFingerprint -cne $currentSource -or
        [string]$Plan.correctedSourceFingerprint -ceq [string]$Plan.originalSourceFingerprint -or
        [string]$Plan.correctedSourceFingerprint -ceq [string]$priorPlan.correctedSourceFingerprint) {
        throw 'The second database recovery attempt requires a newly reviewed corrected source distinct from both earlier source generations.'
    }
    $executionSource = New-BootstrapAcceptedSourceSnapshot `
        -State $State -PlanFingerprint ([string]$Plan.planFingerprint) -SourceFingerprint $currentSource
    $failedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    $archivedPlan = ConvertTo-BootstrapCanonicalValue -Value $priorPlan
    $historyCore = [ordered]@{
        schemaVersion = 1
        attemptNumber = 1
        status = 'Failed'
        manualOnly = $false
        planFingerprint = [string]$priorPlan.planFingerprint
        failureBoundaryFingerprint = [string]$FailedRecovery.boundaryFingerprint
        failedAtUtc = $failedAtUtc
        failedRecovery = ConvertTo-BootstrapCanonicalValue -Value $FailedRecovery
        archivedPlan = $archivedPlan
    }
    $history = ConvertTo-BootstrapCanonicalValue -Value $historyCore
    $history['archiveFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $historyCore
    $accepted = ConvertTo-BootstrapCanonicalValue -Value $Plan
    $accepted['status'] = 'Accepted'
    $accepted['executionSource'] = $executionSource
    $accepted['acceptedAtUtc'] = $failedAtUtc
    $accepted['databaseEvidenceFingerprint'] = ''
    $accepted['completedAtUtc'] = ''
    $State['databaseRecoveryHistory'] = @($history)
    $State['databaseRecoveryPlan'] = $accepted
    Save-BootstrapState -State $State -Path $StatePath
    return $State.databaseRecoveryPlan
}

function Set-BootstrapFailedDatabaseRecoveryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$FailedRecovery
    )

    if (-not $State.Contains('databaseRecoveryPlan') -or
        $State.databaseRecoveryPlan -isnot [System.Collections.IDictionary] -or
        (Get-BootstrapDatabaseRecoveryAttemptNumber -Plan $State.databaseRecoveryPlan) -ne 2 -or
        [string]$State.databaseRecoveryPlan.status -cne 'Running' -or
        [string]$FailedRecovery.recoveryPlanFingerprint -cne [string]$State.databaseRecoveryPlan.planFingerprint) {
        throw 'Only the exact Running second database recovery attempt may be marked manual-only.'
    }
    Assert-BootstrapDatabaseRecoveryHistory -State $State -CurrentPlan $State.databaseRecoveryPlan | Out-Null
    $State.databaseRecoveryPlan.status = 'Failed'
    $State.databaseRecoveryPlan.manualOnly = $true
    $State.databaseRecoveryPlan.failedRecovery = ConvertTo-BootstrapCanonicalValue -Value $FailedRecovery
    $State.databaseRecoveryPlan.failedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    Save-BootstrapState -State $State -Path $StatePath
    return $State.databaseRecoveryPlan
}

function Assert-BootstrapAcceptedDatabaseRecoveryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$PlanFingerprint,
        [Parameter()][TimeSpan]$MaximumAge = ([TimeSpan]::FromMinutes(60)),
        [switch]$AllowCompleted
    )

    Assert-BootstrapFingerprintValue -Value $PlanFingerprint -Label 'Database recovery plan fingerprint'
    if (-not $State.Contains('databaseRecoveryPlan') -or
        $State.databaseRecoveryPlan -isnot [System.Collections.IDictionary]) {
        throw 'No accepted database recovery plan exists for this deployment.'
    }
    $plan = $State.databaseRecoveryPlan
    $attemptNumber = Get-BootstrapDatabaseRecoveryAttemptNumber -Plan $plan
    $activePlanMatchesOriginal = [string]$State.acceptedPlan.sourceFingerprint -ceq [string]$plan.originalSourceFingerprint -and
        [string]$State.acceptedPlan.planFingerprint -ceq [string]$plan.originalAcceptedPlan.planFingerprint -and
        [string]$State.acceptedPlan.executionSource -ceq [string]$plan.originalAcceptedPlan.executionSource
    $activePlanMatchesCorrected = [string]$plan.status -ceq 'Completed' -and
        [string]$State.acceptedPlan.sourceFingerprint -ceq [string]$plan.correctedSourceFingerprint
    if ([string]$plan.planFingerprint -cne $PlanFingerprint -or
        [string]$plan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$plan.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D') -or
        [string]$plan.originalSourceFingerprint -cne [string]$plan.originalAcceptedPlan.sourceFingerprint -or
        (-not $activePlanMatchesOriginal -and -not $activePlanMatchesCorrected) -or
        [string]$plan.correctedSourceFingerprint -cne (Get-BootstrapSourceFingerprint)) {
        throw 'The accepted database recovery plan no longer matches its original or corrected source boundary.'
    }
    if ([string]$plan.recoveryJob.recoveryMode -cne 'ResumeAfterSchemaCompleted' -or
        [int]$plan.recoveryJob.replicaRetryLimit -ne 0 -or [int]$plan.recoveryJob.maximumExecutions -ne 1 -or
        ($attemptNumber -eq 2 -and (
            [int]$plan.schemaVersion -ne 2 -or [int]$plan.attemptNumber -ne 2 -or
            $plan.previousRecoveryPlan -isnot [System.Collections.IDictionary] -or
            $plan.priorFailedRecovery -isnot [System.Collections.IDictionary]))) {
        throw 'The accepted database recovery plan is outside its bounded attempt, mode, or execution contract.'
    }
    Assert-BootstrapDatabaseRecoveryHistory -State $State -CurrentPlan $plan | Out-Null
    $validStatuses = if ($AllowCompleted) { @('Accepted', 'Running', 'Completed') } else { @('Accepted', 'Running') }
    if ([string]$plan.status -cnotin $validStatuses) {
        throw 'The database recovery plan is not in an executable state. Recovery is run-once.'
    }
    $null = Resolve-BootstrapDatabaseRecoverySourceRoot -State $State
    if ([string]$plan.status -ceq 'Accepted') {
        $acceptedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParseExact(
            [string]$plan.acceptedAtUtc, 'O', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$acceptedAt) -or
            ([DateTimeOffset]::UtcNow - $acceptedAt.ToUniversalTime()) -gt $MaximumAge -or
            ([DateTimeOffset]::UtcNow - $acceptedAt.ToUniversalTime()) -lt [TimeSpan]::FromMinutes(-5)) {
            throw 'The accepted database recovery plan is outside its 60-minute validity window.'
        }
    }
    return $true
}

function Complete-BootstrapDatabaseRecoveryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$PlanFingerprint,
        [Parameter(Mandatory)][System.Collections.IDictionary]$DatabaseEvidence
    )

    Assert-BootstrapAcceptedDatabaseRecoveryPlan -State $State -PlanFingerprint $PlanFingerprint | Out-Null
    $attemptNumber = Get-BootstrapDatabaseRecoveryAttemptNumber -Plan $State.databaseRecoveryPlan
    if ([string]$DatabaseEvidence.databaseRecoveryPlanFingerprint -cne $PlanFingerprint -or
        [string]$DatabaseEvidence.acceptedSourceFingerprint -cne [string]$State.databaseRecoveryPlan.originalSourceFingerprint -or
        [string]$DatabaseEvidence.recoverySourceFingerprint -cne [string]$State.databaseRecoveryPlan.correctedSourceFingerprint -or
        [int]$DatabaseEvidence.databaseRecoveryAttemptNumber -ne $attemptNumber -or
        ($attemptNumber -eq 2 -and (
            [string]$DatabaseEvidence.priorFailedDatabaseRecoveryBoundaryFingerprint -cne [string]$State.databaseRecoveryPlan.priorFailedRecovery.boundaryFingerprint -or
            [string]$DatabaseEvidence.priorFailedDatabaseRecoveryPlanFingerprint -cne [string]$State.databaseRecoveryPlan.previousRecoveryPlanFingerprint)) -or
        [string]$DatabaseEvidence.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D')) {
        throw 'Recovered database evidence does not match the exact accepted recovery plan.'
    }
    $State.databaseRecoveryPlan.status = 'Completed'
    $State.databaseRecoveryPlan.databaseEvidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $DatabaseEvidence
    $State.databaseRecoveryPlan.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    $State.steps['Gateway database'] = [ordered]@{
        status = 'Completed'
        startedAtUtc = [string]$State.databaseRecoveryPlan.acceptedAtUtc
        completedAtUtc = [string]$State.databaseRecoveryPlan.completedAtUtc
        sourceFingerprint = [string]$State.databaseRecoveryPlan.correctedSourceFingerprint
        evidence = $DatabaseEvidence
    }
    Save-BootstrapState -State $State -Path $StatePath
    return $State.databaseRecoveryPlan
}

function Start-BootstrapDatabaseRecoveryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$PlanFingerprint
    )

    Assert-BootstrapAcceptedDatabaseRecoveryPlan -State $State -PlanFingerprint $PlanFingerprint | Out-Null
    if ([string]$State.databaseRecoveryPlan.status -ceq 'Accepted') {
        $State.databaseRecoveryPlan.status = 'Running'
        $State.databaseRecoveryPlan.startedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Save-BootstrapState -State $State -Path $StatePath
    }
    elseif ([string]$State.databaseRecoveryPlan.status -cne 'Running') {
        throw 'Database recovery is not in an executable run-once state.'
    }
    return $State.databaseRecoveryPlan
}

function Assert-BootstrapAcceptedPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$PlanFingerprint,
        [Parameter()][string]$ConfigurationFingerprint = '',
        [Parameter()][string]$SourceFingerprint = '',
        [Parameter()][TimeSpan]$MaximumAge = ([TimeSpan]::FromMinutes(60))
    )

    Assert-BootstrapFingerprintValue -Value $PlanFingerprint -Label 'PlanFingerprint'
    if ($MaximumAge -le [TimeSpan]::Zero) {
        throw 'MaximumAge must be greater than zero.'
    }
    if (-not $State.Contains('acceptedPlan') -or $State['acceptedPlan'] -isnot [System.Collections.IDictionary]) {
        throw 'No accepted deployment plan exists for this state. Generate and accept a fresh plan before applying.'
    }
    if (-not $State['acceptedPlan'].Contains('bootstrapClientIpv4')) {
        throw 'The accepted deployment plan predates the reviewed SQL network boundary. Generate and accept a fresh plan before applying.'
    }
    Assert-BootstrapIpv4Value -Value ([string]$State['acceptedPlan']['bootstrapClientIpv4']) -Label 'Accepted legacy SQL bootstrap IPv4 metadata'
    if ([string]::IsNullOrWhiteSpace($ConfigurationFingerprint)) {
        $ConfigurationFingerprint = if ($State.Contains('configurationFingerprint')) { [string]$State['configurationFingerprint'] } else { '' }
    }
    Assert-BootstrapFingerprintValue -Value $ConfigurationFingerprint -Label 'ConfigurationFingerprint'
    if ($ConfigurationFingerprint -cne [string]$State['configurationFingerprint']) {
        throw 'The accepted plan configuration fingerprint does not match the current bootstrap state.'
    }

    if ([string]::IsNullOrWhiteSpace($SourceFingerprint)) {
        $SourceFingerprint = [string]$State['acceptedPlan']['sourceFingerprint']
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'SourceFingerprint'

    if ([string]$State['acceptedPlan']['planFingerprint'] -cne $PlanFingerprint -or
        [string]$State['acceptedPlan']['configurationFingerprint'] -cne $ConfigurationFingerprint -or
        [string]$State['acceptedPlan']['sourceFingerprint'] -cne $SourceFingerprint -or
        [string]$State['acceptedPlan']['bootstrapVersion'] -cne $script:BootstrapVersion) {
        throw 'The accepted deployment plan is stale or belongs to different configuration/source. Generate and accept a fresh plan before applying.'
    }

    $executionSourceRoot = Resolve-BootstrapAcceptedSourceRoot -State $State
    Set-BootstrapExecutionSourceRoot -Path $executionSourceRoot

    $acceptedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact(
        [string]$State['acceptedPlan']['acceptedAtUtc'],
        'O',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$acceptedAt)) {
        throw 'The accepted deployment plan has invalid acceptance-time metadata. Generate and accept a fresh plan before applying.'
    }
    $age = [DateTimeOffset]::UtcNow - $acceptedAt.ToUniversalTime()
    if ($age -lt [TimeSpan]::FromMinutes(-5) -or $age -gt $MaximumAge) {
        throw "The accepted deployment plan is outside its $([int][Math]::Ceiling($MaximumAge.TotalMinutes))-minute validity window. Generate and accept a fresh plan before applying."
    }
    return $true
}

function Invoke-BootstrapStateStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 .:/()_-]{0,127}$')][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter()][scriptblock]$Validate,
        [Parameter()][scriptblock]$Reconcile,
        [switch]$NoAutomaticReplayAfterStart,
        [switch]$AlwaysRun
    )
    Write-BootstrapStep $Name
    $stepSourceFingerprint = if ($State.Contains('acceptedPlan') -and
        $State.acceptedPlan -is [System.Collections.IDictionary] -and
        $State.acceptedPlan.Contains('sourceFingerprint')) {
        [string]$State.acceptedPlan.sourceFingerprint
    }
    else {
        (Get-BootstrapSourceFingerprint)
    }
    Assert-BootstrapFingerprintValue -Value $stepSourceFingerprint -Label "Bootstrap step '$Name' source fingerprint"
    $existing = $State.steps[$Name]
    if (-not $AlwaysRun -and $existing -and $existing.status -in @('Running', 'Failed') -and $NoAutomaticReplayAfterStart) {
        if (-not $Reconcile) {
            Write-BootstrapEvent -Status Failed -StepName $Name
            throw "Bootstrap step '$Name' has a prior started outcome and is not safe to replay automatically. State was preserved for exact provider reconciliation."
        }
        try {
            [object[]]$reconciliation = @(& $Reconcile)
            if ($reconciliation.Count -ne 1 -or $reconciliation[0] -isnot [System.Collections.IDictionary] -or
                -not $reconciliation[0].Contains('recovered') -or $reconciliation[0].recovered -isnot [bool]) {
                throw 'Reconciler must return exactly one typed disposition.'
            }
            if ($reconciliation[0].recovered -ne $true -or -not $reconciliation[0].Contains('evidence') -or $null -eq $reconciliation[0].evidence) {
                throw 'Prior outcome remains unresolved.'
            }
            $recoveredEvidence = $reconciliation[0].evidence
            $State.steps[$Name] = [ordered]@{
                status = 'Completed'
                startedAtUtc = if ($existing.Contains('startedAtUtc')) { [string]$existing.startedAtUtc } else { [DateTimeOffset]::UtcNow.ToString('O') }
                completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                reconciledAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                sourceFingerprint = $stepSourceFingerprint
                evidence = $recoveredEvidence
            }
            Save-BootstrapState -State $State -Path $StatePath
            Write-BootstrapSuccess "$Name recovered by exact provider readback"
            Write-BootstrapEvent -Status Completed -StepName $Name -Reused -Revalidated
            return $recoveredEvidence
        }
        catch {
            Write-BootstrapEvent -Status Failed -StepName $Name
            throw "Bootstrap step '$Name' has a prior started outcome that could not be reconciled exactly. No mutation was repeated; preserve state and follow the recovery guidance."
        }
    }
    if (-not $AlwaysRun -and $existing -and $existing.status -eq 'Completed') {
        if (-not $Validate) {
            $State.steps[$Name] = [ordered]@{
                status = 'Failed'
                startedAtUtc = if ($existing.Contains('startedAtUtc')) { [string]$existing.startedAtUtc } else { '' }
                completedAtUtc = if ($existing.Contains('completedAtUtc')) { [string]$existing.completedAtUtc } else { '' }
                failedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                sourceFingerprint = $stepSourceFingerprint
                evidence = $existing.evidence
                message = "Bootstrap step '$Name' failed independent revalidation. Prior evidence was preserved for exact reconciliation."
            }
            Save-BootstrapState -State $State -Path $StatePath
            Write-BootstrapEvent -Status Failed -StepName $Name
            throw "Completed bootstrap step '$Name' cannot be reused without an independent read-only validator. State was preserved; supply the required validator before resuming."
        }

        $validationSucceeded = $false
        try {
            [object[]]$validationResult = @(& $Validate)
            if ($validationResult.Count -ne 1 -or $validationResult[0] -isnot [bool]) {
                throw 'Validator must return exactly one Boolean value.'
            }
            $validationSucceeded = [bool]$validationResult[0]
        }
        catch {
            $State.steps[$Name] = [ordered]@{
                status = 'Failed'
                startedAtUtc = if ($existing.Contains('startedAtUtc')) { [string]$existing.startedAtUtc } else { '' }
                completedAtUtc = if ($existing.Contains('completedAtUtc')) { [string]$existing.completedAtUtc } else { '' }
                failedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                sourceFingerprint = $stepSourceFingerprint
                evidence = $existing.evidence
                message = "Bootstrap step '$Name' failed independent revalidation. Prior evidence was preserved for exact reconciliation."
            }
            Save-BootstrapState -State $State -Path $StatePath
            Write-BootstrapEvent -Status Failed -StepName $Name
            throw "Completed bootstrap step '$Name' could not be independently revalidated. State was preserved; correct the validation prerequisite before resuming."
        }
        if ($validationSucceeded) {
            Write-BootstrapSuccess "$Name already complete and revalidated"
            Write-BootstrapEvent -Status Completed -StepName $Name -Reused -Revalidated
            return $existing.evidence
        }
        if ($NoAutomaticReplayAfterStart) {
            $State.steps[$Name] = [ordered]@{
                status = 'Failed'
                startedAtUtc = if ($existing.Contains('startedAtUtc')) { [string]$existing.startedAtUtc } else { '' }
                completedAtUtc = if ($existing.Contains('completedAtUtc')) { [string]$existing.completedAtUtc } else { '' }
                failedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                sourceFingerprint = $stepSourceFingerprint
                evidence = $existing.evidence
                message = "Bootstrap step '$Name' failed independent revalidation. Prior evidence was preserved for exact reconciliation."
            }
            Save-BootstrapState -State $State -Path $StatePath
            Write-BootstrapEvent -Status Failed -StepName $Name
            throw "Completed bootstrap step '$Name' no longer matches exact provider readback and is not safe to replay automatically. No mutation was repeated; preserve state and follow the recovery guidance."
        }
        if (-not $script:BootstrapStructuredOutput) {
            Write-Warning "$Name state was stale; running it again."
        }
    }

    Write-BootstrapEvent -Status Started -StepName $Name
    $priorPartialEvidence = if ($existing -and $existing.Contains('evidence')) { $existing.evidence } else { $null }
    $State.steps[$Name] = [ordered]@{ status = 'Running'; startedAtUtc = [DateTimeOffset]::UtcNow.ToString('O'); sourceFingerprint = $stepSourceFingerprint }
    if ($null -ne $priorPartialEvidence) { $State.steps[$Name].evidence = $priorPartialEvidence }
    Save-BootstrapState -State $State -Path $StatePath
    try {
        [object[]]$actionOutput = @(& $Action)
        if ($actionOutput.Count -ne 1 -or $null -eq $actionOutput[0]) {
            throw "Bootstrap step '$Name' did not return exactly one non-null evidence object. Provider output was not persisted; correct the action contract and Resume."
        }
        $evidence = $actionOutput[0]
        $State.steps[$Name] = [ordered]@{
            status = 'Completed'
            startedAtUtc = $State.steps[$Name].startedAtUtc
            completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            sourceFingerprint = $stepSourceFingerprint
            evidence = $evidence
        }
        Save-BootstrapState -State $State -Path $StatePath
        Write-BootstrapSuccess $Name
        Write-BootstrapEvent -Status Completed -StepName $Name
        return $evidence
    }
    catch {
        $partialEvidence = if ($State.steps[$Name].Contains('evidence')) { $State.steps[$Name].evidence } else { $null }
        $State.steps[$Name] = [ordered]@{
            status = 'Failed'
            startedAtUtc = $State.steps[$Name].startedAtUtc
            failedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            sourceFingerprint = $stepSourceFingerprint
            message = "Bootstrap step '$Name' failed. Review the local terminal output, correct the cause, and run Resume."
        }
        if ($null -ne $partialEvidence) { $State.steps[$Name].evidence = $partialEvidence }
        Save-BootstrapState -State $State -Path $StatePath
        Write-BootstrapEvent -Status Failed -StepName $Name
        throw
    }
}

function Enter-BootstrapLock {
    param([Parameter(Mandatory)][string]$StatePath)
    $lockPath = "$StatePath.lock"
    New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force | Out-Null
    try {
        $stream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        $bytes = [Text.Encoding]::UTF8.GetBytes("$PID $([DateTimeOffset]::UtcNow.ToString('O'))")
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        return $stream
    }
    catch {
        throw "Another bootstrap process holds '$lockPath'. Wait for it to finish or terminate that process cleanly."
    }
}

Export-ModuleMember -Function *
