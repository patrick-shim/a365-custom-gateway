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
$script:BootstrapPreInertCorrectionStepNames = @(
    'Prerequisites',
    'Azure authentication',
    'Azure provider registration',
    'Azure foundation',
    'Gateway API identity',
    'Immutable workload images',
    'Inert identity deployment'
)
$script:BootstrapPreInertCorrectionChangedPaths = @(
    'bootstrap/bootstrap.ps1',
    'bootstrap/modules/Azure.psm1',
    'bootstrap/modules/Common.psm1',
    'bootstrap/modules/Database.psm1',
    'bootstrap/modules/Experience.psm1',
    'infrastructure/bicep/main.bicep'
)
$script:BootstrapPreInertCorrectionAmendableSourceFingerprint = 'sha256:4bf5bd7cc1feb19f40f1c5f2185050893c896047272fe6418f5636d37658796a'
$script:BootstrapPreInertCorrectionAmendmentChangedPaths = @(
    'bootstrap/modules/Common.psm1',
    'bootstrap/modules/Experience.psm1'
)
$script:BootstrapPreInertCorrectionBicepPath = 'infrastructure/bicep/main.bicep'
$script:BootstrapPreInertCorrectionOriginalBicepLine = '  name: contentSafety!.outputs.accountName'
$script:BootstrapPreInertCorrectionCorrectedBicepLine = '  name: names.contentSafety'

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
    $purviewText = ConvertTo-GatewayArmBooleanText -Value $PurviewEnabled
    $policyText = ConvertTo-GatewayArmBooleanText -Value $PurviewPolicyProvisioningEnabled
    $promptShieldText = ConvertTo-GatewayArmBooleanText -Value $PromptShieldEnabled

    return [ordered]@{
        Api = [ordered]@{
            'Provisioning__ExecutionEnabled' = $previewText
            'Provisioning__AllowContinuousDevelopmentAccess' = $previewText
            'Agent365__DelegatedRegistry__Enabled' = $previewText
            'Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess' = $previewText
            'Purview__Enabled' = $purviewText
            'PromptShield__Enabled' = $promptShieldText
            'DatabaseAttestation__Enabled' = $runtimeText
        }
        Worker = [ordered]@{
            'ProvisioningWorker__ProcessingEnabled' = $runtimeText
            'ProvisioningWorker__ProvisioningExecutionEnabled' = $previewText
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

function Get-BootstrapPreInertSourceCorrectionSnapshotRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][ValidateSet('Original', 'Corrected')][string]$Generation
    )

    $canonicalOwnershipId = ([guid][string]$State.deploymentOwnershipId).ToString('D')
    if ($Generation -ceq 'Original') {
        if ($Plan.originalAcceptedPlan -isnot [System.Collections.IDictionary]) {
            throw 'The pre-inert source correction has no preserved original accepted-plan metadata.'
        }
        $snapshotPlanFingerprint = [string]$Plan.originalAcceptedPlan.planFingerprint
        $sourceFingerprint = [string]$Plan.originalDeploymentSourceFingerprint
        $relative = [string]$Plan.originalAcceptedPlan.executionSource
        $label = 'original accepted'
    }
    else {
        $snapshotPlanFingerprint = [string]$Plan.planFingerprint
        $sourceFingerprint = [string]$Plan.correctedExecutionSourceFingerprint
        $relative = [string]$Plan.correctedExecutionSource
        $label = 'corrected execution'
    }
    Assert-BootstrapFingerprintValue -Value $snapshotPlanFingerprint -Label "Pre-inert correction $label plan fingerprint"
    Assert-BootstrapFingerprintValue -Value $sourceFingerprint -Label "Pre-inert correction $label source fingerprint"
    $expectedRelative = ".bootstrap/accepted-source/$canonicalOwnershipId/$($snapshotPlanFingerprint.Substring(7))"
    if ($relative -cne $expectedRelative) {
        throw "The pre-inert correction $label snapshot is not bound to its exact ownership and plan fingerprint."
    }

    $root = Get-RepositoryRoot
    $acceptedRoot = [IO.Path]::GetFullPath((Join-Path $root '.bootstrap/accepted-source'))
    $snapshot = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $snapshot.StartsWith($acceptedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal) -or
        -not (Test-Path -LiteralPath $snapshot -PathType Container) -or
        (Get-BootstrapSourceFingerprint -Root $snapshot) -cne $sourceFingerprint) {
        throw "The pre-inert correction $label snapshot is absent, modified, or outside its managed boundary."
    }
    return $snapshot
}

function Get-BootstrapBytePatternOffsets {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][byte[]]$Pattern
    )

    $offsets = [Collections.Generic.List[int]]::new()
    if ($Pattern.Length -eq 0 -or $Bytes.Length -lt $Pattern.Length) { return @() }
    for ($offset = 0; $offset -le $Bytes.Length - $Pattern.Length; $offset++) {
        $matches = $true
        for ($index = 0; $index -lt $Pattern.Length; $index++) {
            if ($Bytes[$offset + $index] -ne $Pattern[$index]) {
                $matches = $false
                break
            }
        }
        if ($matches) { $offsets.Add($offset) }
    }
    return @($offsets)
}

function Assert-BootstrapExactPreInertBicepCorrection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OriginalRoot,
        [Parameter(Mandatory)][string]$CorrectedRoot
    )

    $originalPath = Join-Path $OriginalRoot $script:BootstrapPreInertCorrectionBicepPath
    $correctedPath = Join-Path $CorrectedRoot $script:BootstrapPreInertCorrectionBicepPath
    if (-not (Test-Path -LiteralPath $originalPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $correctedPath -PathType Leaf)) {
        throw 'The pre-inert source correction requires both exact infrastructure/bicep/main.bicep generations.'
    }
    $originalBytes = [IO.File]::ReadAllBytes($originalPath)
    $correctedBytes = [IO.File]::ReadAllBytes($correctedPath)
    $oldBytes = [Text.Encoding]::UTF8.GetBytes($script:BootstrapPreInertCorrectionOriginalBicepLine)
    $newBytes = [Text.Encoding]::UTF8.GetBytes($script:BootstrapPreInertCorrectionCorrectedBicepLine)
    $offsets = @(Get-BootstrapBytePatternOffsets -Bytes $originalBytes -Pattern $oldBytes)
    if ($offsets.Count -ne 1) {
        throw 'The original pre-inert Bicep source does not contain exactly one reviewed Prompt Shields account-name reference.'
    }
    $offset = [int]$offsets[0]
    $expectedLength = $originalBytes.Length - $oldBytes.Length + $newBytes.Length
    $expectedBytes = [byte[]]::new($expectedLength)
    if ($offset -gt 0) { [Array]::Copy($originalBytes, 0, $expectedBytes, 0, $offset) }
    [Array]::Copy($newBytes, 0, $expectedBytes, $offset, $newBytes.Length)
    $suffixLength = $originalBytes.Length - ($offset + $oldBytes.Length)
    if ($suffixLength -gt 0) {
        [Array]::Copy(
            $originalBytes,
            $offset + $oldBytes.Length,
            $expectedBytes,
            $offset + $newBytes.Length,
            $suffixLength)
    }
    if (-not [Linq.Enumerable]::SequenceEqual[byte]($expectedBytes, $correctedBytes)) {
        throw 'The pre-inert Bicep correction must be the exact reviewed one-line Prompt Shields account-name replacement.'
    }
    return $true
}

function Get-BootstrapPreInertSourceCorrectionDelta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OriginalRoot,
        [Parameter(Mandatory)][string]$CorrectedRoot
    )

    $original = [ordered]@{}
    foreach ($entry in @(Get-BootstrapSourceManifest -Root $OriginalRoot)) {
        $path = [string]$entry.path
        $hash = [string]$entry.sha256
        if ([string]::IsNullOrWhiteSpace($path) -or $hash -cnotmatch '^[0-9a-f]{64}$' -or $original.Contains($path)) {
            throw 'The original accepted source manifest is malformed or contains duplicate paths.'
        }
        $original[$path] = $hash
    }
    $corrected = [ordered]@{}
    foreach ($entry in @(Get-BootstrapSourceManifest -Root $CorrectedRoot)) {
        $path = [string]$entry.path
        $hash = [string]$entry.sha256
        if ([string]::IsNullOrWhiteSpace($path) -or $hash -cnotmatch '^[0-9a-f]{64}$' -or $corrected.Contains($path)) {
            throw 'The corrected execution source manifest is malformed or contains duplicate paths.'
        }
        $corrected[$path] = $hash
    }

    [string[]]$allPaths = @($original.Keys + $corrected.Keys | Sort-Object -Unique)
    $delta = [Collections.Generic.List[object]]::new()
    foreach ($path in $allPaths) {
        if (-not $original.Contains($path) -or -not $corrected.Contains($path)) {
            throw 'The pre-inert source correction may not add or remove deployment source files.'
        }
        if ([string]$original[$path] -cne [string]$corrected[$path]) {
            if ($script:BootstrapPreInertCorrectionChangedPaths -cnotcontains $path) {
                throw "The pre-inert source correction changed non-allowlisted deployment source '$path'."
            }
            $delta.Add([ordered]@{
                path = $path
                originalSha256 = [string]$original[$path]
                correctedSha256 = [string]$corrected[$path]
            })
        }
    }
    [string[]]$changedPaths = @($delta | ForEach-Object { [string]$_.path })
    [Array]::Sort($changedPaths, [StringComparer]::Ordinal)
    [string[]]$expectedPaths = @($script:BootstrapPreInertCorrectionChangedPaths)
    [Array]::Sort($expectedPaths, [StringComparer]::Ordinal)
    if (($changedPaths -join "`n") -cne ($expectedPaths -join "`n")) {
        throw 'The pre-inert source correction must change exactly the reviewed source-bridge files and no others.'
    }
    Assert-BootstrapExactPreInertBicepCorrection -OriginalRoot $OriginalRoot -CorrectedRoot $CorrectedRoot | Out-Null
    return @($delta | Sort-Object { [string]$_.path })
}

function Get-BootstrapPreInertSourceCorrectionAmendmentDelta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PriorCorrectedRoot,
        [Parameter(Mandatory)][string]$AmendedRoot
    )

    $prior = [ordered]@{}
    foreach ($entry in @(Get-BootstrapSourceManifest -Root $PriorCorrectedRoot)) {
        $path = [string]$entry.path
        $hash = [string]$entry.sha256
        if ([string]::IsNullOrWhiteSpace($path) -or $hash -cnotmatch '^[0-9a-f]{64}$' -or $prior.Contains($path)) {
            throw 'The prior corrected source manifest is malformed or contains duplicate paths.'
        }
        $prior[$path] = $hash
    }
    $amended = [ordered]@{}
    foreach ($entry in @(Get-BootstrapSourceManifest -Root $AmendedRoot)) {
        $path = [string]$entry.path
        $hash = [string]$entry.sha256
        if ([string]::IsNullOrWhiteSpace($path) -or $hash -cnotmatch '^[0-9a-f]{64}$' -or $amended.Contains($path)) {
            throw 'The amended corrected source manifest is malformed or contains duplicate paths.'
        }
        $amended[$path] = $hash
    }

    [string[]]$allPaths = @($prior.Keys + $amended.Keys | Sort-Object -Unique)
    $delta = [Collections.Generic.List[object]]::new()
    foreach ($path in $allPaths) {
        if (-not $prior.Contains($path) -or -not $amended.Contains($path)) {
            throw 'The pre-inert source amendment may not add or remove deployment source files.'
        }
        if ([string]$prior[$path] -cne [string]$amended[$path]) {
            if ($script:BootstrapPreInertCorrectionAmendmentChangedPaths -cnotcontains $path) {
                throw "The pre-inert source amendment changed non-allowlisted deployment source '$path'."
            }
            $delta.Add([ordered]@{
                path = $path
                priorSha256 = [string]$prior[$path]
                amendedSha256 = [string]$amended[$path]
            })
        }
    }
    [string[]]$changedPaths = @($delta | ForEach-Object { [string]$_.path } | Sort-Object -CaseSensitive)
    [string[]]$expectedPaths = @($script:BootstrapPreInertCorrectionAmendmentChangedPaths | Sort-Object -CaseSensitive)
    if (($changedPaths -join "`n") -cne ($expectedPaths -join "`n")) {
        throw 'The pre-inert source amendment must change exactly Common.psm1 and Experience.psm1.'
    }
    return @($delta | Sort-Object { [string]$_.path })
}

function Get-BootstrapPreInertSourceCorrectionBoundaryFingerprint {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$OriginalSourceFingerprint,
        [Parameter()][string]$CorrectedSourceFingerprint = '',
        [switch]$Completed
    )

    if ($Completed) {
        Assert-BootstrapFingerprintValue -Value $CorrectedSourceFingerprint -Label 'Completed pre-inert correction source fingerprint'
    }

    $expectedSteps = @($script:BootstrapPreInertCorrectionStepNames)
    [string[]]$actualSteps = @($State.steps.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($actualSteps, [StringComparer]::Ordinal)
    [string[]]$sortedExpectedSteps = @($expectedSteps)
    [Array]::Sort($sortedExpectedSteps, [StringComparer]::Ordinal)
    if (($actualSteps -join "`n") -cne ($sortedExpectedSteps -join "`n")) {
        throw 'Pre-inert source correction requires exactly bootstrap steps 1-7 and no later or unknown step state.'
    }
    if (-not $Completed -and $State.outputs.Count -ne 0) {
        throw 'Pre-inert source correction requires an empty output boundary before the inert deployment succeeds.'
    }

    for ($index = 0; $index -lt 6; $index++) {
        $name = [string]$expectedSteps[$index]
        $step = $State.steps[$name]
        $expectedSourceFingerprint = if ($Completed -and $index -lt 2) {
            $CorrectedSourceFingerprint
        }
        else {
            $OriginalSourceFingerprint
        }
        if ($step -isnot [System.Collections.IDictionary] -or
            [string]$step.status -cne 'Completed' -or
            [string]$step.sourceFingerprint -cne $expectedSourceFingerprint -or
            -not $step.Contains('evidence') -or $null -eq $step.evidence) {
            throw "Pre-inert source correction requires the exact completed source/evidence generation for bootstrap step '$name'."
        }
    }
    $inertStep = $State.steps[[string]$expectedSteps[6]]
    if ($inertStep -isnot [System.Collections.IDictionary] -or
        -not $inertStep.Contains('sourceFingerprint')) {
        throw 'Pre-inert source correction requires the exact inert-deployment step boundary.'
    }
    if (-not $Completed) {
        if ([string]$inertStep.status -cne 'Failed' -or
            [string]$inertStep.sourceFingerprint -cne $OriginalSourceFingerprint -or
            $inertStep.Contains('evidence')) {
            throw 'Pre-inert source correction is allowed only when step 7 failed under the original source without any persisted evidence.'
        }
    }
    elseif ([string]$inertStep.status -cne 'Completed' -or
        [string]$inertStep.sourceFingerprint -cne $CorrectedSourceFingerprint -or
        -not $inertStep.Contains('evidence') -or $null -eq $inertStep.evidence) {
        throw 'Pre-inert source correction completion requires exact completed corrected-source step-7 evidence.'
    }

    $boundary = [ordered]@{
        deploymentOwnershipId = ([guid][string]$State.deploymentOwnershipId).ToString('D')
        configurationFingerprint = [string]$State.configurationFingerprint
        source = ConvertTo-BootstrapCanonicalValue -Value $State.source
        steps = ConvertTo-BootstrapCanonicalValue -Value $State.steps
        outputs = ConvertTo-BootstrapCanonicalValue -Value $State.outputs
    }
    return Get-BootstrapObjectFingerprint -InputObject $boundary
}

function Assert-BootstrapPreInertSourceCorrectionCreationBoundary {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)

    if (-not $State.Contains('acceptedPlan') -or $State.acceptedPlan -isnot [System.Collections.IDictionary]) {
        throw 'Pre-inert source correction requires the preserved original accepted deployment plan.'
    }
    if ($State.Contains('databaseRecoveryPlan') -or $State.Contains('manualDatabaseRepairPlan')) {
        throw 'Pre-inert source correction cannot be combined with database recovery or repair state.'
    }
    $acceptedPlan = $State.acceptedPlan
    foreach ($name in @('planFingerprint', 'configurationFingerprint', 'sourceFingerprint', 'bootstrapClientIpv4', 'executionSource', 'bootstrapVersion', 'acceptedAtUtc')) {
        if (-not $acceptedPlan.Contains($name)) {
            throw 'The original accepted deployment plan is missing required immutable snapshot metadata.'
        }
    }
    Assert-BootstrapFingerprintValue -Value ([string]$acceptedPlan.planFingerprint) -Label 'Original accepted plan fingerprint'
    Assert-BootstrapFingerprintValue -Value ([string]$acceptedPlan.sourceFingerprint) -Label 'Original accepted source fingerprint'
    if ([string]$acceptedPlan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$acceptedPlan.bootstrapVersion -cne $script:BootstrapVersion) {
        throw 'The original accepted deployment plan does not match this exact configuration and bootstrap version.'
    }
    foreach ($recordName in @('created', 'lastWritten')) {
        if (-not $State.source.Contains($recordName) -or
            $State.source[$recordName] -isnot [System.Collections.IDictionary] -or
            [string]$State.source[$recordName].bootstrapSourceFingerprint -cne [string]$acceptedPlan.sourceFingerprint) {
            throw 'Pre-inert source correction requires exact original source provenance for the recorded deployment state.'
        }
    }
    $originalRoot = Resolve-BootstrapAcceptedSourceRoot -State $State
    $boundaryFingerprint = Get-BootstrapPreInertSourceCorrectionBoundaryFingerprint `
        -State $State `
        -OriginalSourceFingerprint ([string]$acceptedPlan.sourceFingerprint)
    return [ordered]@{
        originalRoot = $originalRoot
        boundaryFingerprint = $boundaryFingerprint
    }
}

function Assert-BootstrapPreInertSourceCorrectionAmendmentBoundary {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    if ($State.Contains('acceptedPlan') -or
        $State.Contains('databaseRecoveryPlan') -or
        $State.Contains('manualDatabaseRepairPlan') -or
        [string]$Plan.status -cne 'Accepted' -or
        [int]$Plan.schemaVersion -ne 1 -or
        [int]$Plan.generation -ne 1 -or
        [string]$Plan.correctedExecutionSourceFingerprint -cne $script:BootstrapPreInertCorrectionAmendableSourceFingerprint) {
        throw 'Pre-inert source amendment is allowed only for the exact accepted failed-Plan correction generation.'
    }

    [string[]]$actualSteps = @($State.steps.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($actualSteps, [StringComparer]::Ordinal)
    [string[]]$expectedSteps = @($script:BootstrapPreInertCorrectionStepNames)
    [Array]::Sort($expectedSteps, [StringComparer]::Ordinal)
    if (($actualSteps -join "`n") -cne ($expectedSteps -join "`n") -or
        $State.outputs -isnot [System.Collections.IDictionary] -or
        $State.outputs.Count -ne 0) {
        throw 'Pre-inert source amendment requires exactly failed Plan state at steps 1-7 with no deployment outputs.'
    }
    for ($index = 0; $index -lt 6; $index++) {
        $step = $State.steps[[string]$script:BootstrapPreInertCorrectionStepNames[$index]]
        if ($step -isnot [System.Collections.IDictionary] -or
            [string]$step.status -cne 'Completed' -or
            [string]$step.sourceFingerprint -cne [string]$Plan.originalDeploymentSourceFingerprint -or
            -not $step.Contains('evidence') -or $null -eq $step.evidence) {
            throw 'Pre-inert source amendment requires unchanged original-source evidence for steps 1-6.'
        }
    }
    $inertStep = $State.steps['Inert identity deployment']
    if ($inertStep -isnot [System.Collections.IDictionary] -or
        [string]$inertStep.status -cne 'Failed' -or
        [string]$inertStep.sourceFingerprint -cne [string]$Plan.originalDeploymentSourceFingerprint -or
        $inertStep.Contains('evidence')) {
        throw 'Pre-inert source amendment requires the unchanged original-source step-7 failure without evidence.'
    }
    if ($State.source -isnot [System.Collections.IDictionary] -or
        $State.source.created -isnot [System.Collections.IDictionary] -or
        $State.source.lastWritten -isnot [System.Collections.IDictionary] -or
        [string]$State.source.created.bootstrapSourceFingerprint -cne [string]$Plan.originalDeploymentSourceFingerprint -or
        [string]$State.source.lastWritten.bootstrapSourceFingerprint -cne [string]$Plan.correctedExecutionSourceFingerprint) {
        throw 'Pre-inert source amendment requires the exact original-to-corrected source provenance pair.'
    }
    return $true
}

function Get-BootstrapPreInertSourceCorrectionPlanCore {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan)

    $core = [ordered]@{
        schemaVersion = [int]$Plan.schemaVersion
        correctionKind = [string]$Plan.correctionKind
        generation = [int]$Plan.generation
        configurationFingerprint = [string]$Plan.configurationFingerprint
        deploymentOwnershipId = [string]$Plan.deploymentOwnershipId
        originalDeploymentSourceFingerprint = [string]$Plan.originalDeploymentSourceFingerprint
        correctedExecutionSourceFingerprint = [string]$Plan.correctedExecutionSourceFingerprint
        originalAcceptedPlanFingerprint = [string]$Plan.originalAcceptedPlanFingerprint
        originalAcceptedPlan = ConvertTo-BootstrapCanonicalValue -Value $Plan.originalAcceptedPlan
        originalBoundaryFingerprint = [string]$Plan.originalBoundaryFingerprint
        allowedChangedPaths = @($Plan.allowedChangedPaths)
        sourceDelta = ConvertTo-BootstrapCanonicalValue -Value $Plan.sourceDelta
        semanticCorrection = ConvertTo-BootstrapCanonicalValue -Value $Plan.semanticCorrection
    }
    if ([int]$Plan.schemaVersion -eq 2 -and [int]$Plan.generation -eq 2) {
        $core['supersededCorrectionPlanFingerprint'] = [string]$Plan.supersededCorrectionPlanFingerprint
        $core['supersededCorrectionPlan'] = ConvertTo-BootstrapCanonicalValue -Value $Plan.supersededCorrectionPlan
        $core['amendmentChangedPaths'] = @($Plan.amendmentChangedPaths)
        $core['amendmentSourceDelta'] = ConvertTo-BootstrapCanonicalValue -Value $Plan.amendmentSourceDelta
    }
    return $core
}

function Assert-BootstrapPendingPreInertSourceCorrectionBoundary {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    [string[]]$actualSteps = @($State.steps.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($actualSteps, [StringComparer]::Ordinal)
    [string[]]$expectedSteps = @($script:BootstrapPreInertCorrectionStepNames)
    [Array]::Sort($expectedSteps, [StringComparer]::Ordinal)
    if (($actualSteps -join "`n") -cne ($expectedSteps -join "`n") -or
        $State.outputs -isnot [System.Collections.IDictionary] -or $State.outputs.Count -ne 0) {
        throw 'The pending pre-inert source correction requires exactly steps 1-7, no later step, and no deployment outputs.'
    }
    for ($index = 0; $index -lt 6; $index++) {
        $name = [string]$script:BootstrapPreInertCorrectionStepNames[$index]
        $step = $State.steps[$name]
        if ($step -isnot [System.Collections.IDictionary]) {
            throw 'The pending pre-inert source correction has malformed step evidence.'
        }
        $isOriginalCompleted = [string]$step.status -ceq 'Completed' -and
            [string]$step.sourceFingerprint -ceq [string]$Plan.originalDeploymentSourceFingerprint -and
            $step.Contains('evidence') -and $null -ne $step.evidence
        $isCorrectedAlwaysRun = $index -lt 2 -and
            [string]$step.status -cin @('Running', 'Failed', 'Completed') -and
            [string]$step.sourceFingerprint -ceq [string]$Plan.correctedExecutionSourceFingerprint -and
            ([string]$step.status -cne 'Completed' -or
                ($step.Contains('evidence') -and $null -ne $step.evidence))
        if (-not $isOriginalCompleted -and -not $isCorrectedAlwaysRun) {
            throw 'The pending pre-inert source correction no longer has its exact original prefix or corrected AlwaysRun transition.'
        }
    }
    $inertStep = $State.steps['Inert identity deployment']
    if ($inertStep -isnot [System.Collections.IDictionary]) {
        throw 'The pending pre-inert source correction has malformed inert-deployment state.'
    }
    $isOriginalFailure = [string]$inertStep.status -ceq 'Failed' -and
        [string]$inertStep.sourceFingerprint -ceq [string]$Plan.originalDeploymentSourceFingerprint -and
        -not $inertStep.Contains('evidence')
    $isCorrectedStartedOutcome = [string]$inertStep.status -cin @('Running', 'Failed') -and
        [string]$inertStep.sourceFingerprint -ceq [string]$Plan.correctedExecutionSourceFingerprint
    $isCorrectedCompleted = [string]$inertStep.status -ceq 'Completed' -and
        [string]$inertStep.sourceFingerprint -ceq [string]$Plan.correctedExecutionSourceFingerprint -and
        $inertStep.Contains('evidence') -and $null -ne $inertStep.evidence
    if (-not $isOriginalFailure -and -not $isCorrectedStartedOutcome -and -not $isCorrectedCompleted) {
        throw 'The pending pre-inert source correction no longer has an exact original failure, corrected started outcome, or corrected completion at step 7.'
    }
    foreach ($recordName in @('created', 'lastWritten')) {
        if (-not $State.source.Contains($recordName) -or
            $State.source[$recordName] -isnot [System.Collections.IDictionary] -or
            -not $State.source[$recordName].Contains('bootstrapSourceFingerprint')) {
            throw 'The pending pre-inert source correction has incomplete source provenance.'
        }
    }
    if ([string]$State.source.created.bootstrapSourceFingerprint -cne [string]$Plan.originalDeploymentSourceFingerprint -or
        [string]$State.source.lastWritten.bootstrapSourceFingerprint -cnotin @(
            [string]$Plan.originalDeploymentSourceFingerprint,
            [string]$Plan.correctedExecutionSourceFingerprint)) {
        throw 'The pending pre-inert source correction no longer preserves the exact original/corrected source provenance pair.'
    }
    return $true
}

function Assert-BootstrapPreInertSourceCorrectionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter()][string]$ExecutionSourceFingerprint = ''
    )

    if (-not $State.Contains('preInertSourceCorrectionPlan') -or
        $State.preInertSourceCorrectionPlan -isnot [System.Collections.IDictionary]) {
        throw 'No bounded pre-inert source correction plan exists for this bootstrap state.'
    }
    $plan = $State.preInertSourceCorrectionPlan
    if ([string]$plan.status -cnotin @('Accepted', 'Completed')) {
        throw 'The pre-inert source correction plan has an unsupported state.'
    }
    [string[]]$requiredKeys = @(
        'allowedChangedPaths', 'configurationFingerprint', 'correctedExecutionSource',
        'correctedExecutionSourceFingerprint', 'correctionKind', 'createdAtUtc',
        'deploymentOwnershipId', 'generation', 'originalAcceptedPlan',
        'originalAcceptedPlanFingerprint', 'originalBoundaryFingerprint',
        'originalDeploymentSourceFingerprint', 'planFingerprint', 'schemaVersion',
        'semanticCorrection', 'sourceDelta', 'status'
    )
    if ([string]$plan.status -ceq 'Completed') {
        $requiredKeys += @('completedAtUtc', 'completionBoundaryFingerprint', 'inertEvidenceFingerprint')
    }
    [string[]]$actualKeys = @($plan.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($requiredKeys, [StringComparer]::Ordinal)
    [Array]::Sort($actualKeys, [StringComparer]::Ordinal)
    if (($requiredKeys -join "`n") -cne ($actualKeys -join "`n")) {
        throw 'The pre-inert source correction plan contains incomplete or unsupported metadata.'
    }
    if ([int]$plan.schemaVersion -ne 1 -or
        [string]$plan.correctionKind -cne 'PromptShieldPreInertBicepReference' -or
        [int]$plan.generation -ne 1 -or
        [string]$plan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$plan.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D')) {
        throw 'The pre-inert source correction plan does not match its one-generation configuration and ownership boundary.'
    }
    foreach ($name in @(
        'planFingerprint', 'originalAcceptedPlanFingerprint', 'originalBoundaryFingerprint',
        'originalDeploymentSourceFingerprint', 'correctedExecutionSourceFingerprint')) {
        Assert-BootstrapFingerprintValue -Value ([string]$plan[$name]) -Label "Pre-inert source correction $name"
    }
    if ([string]$plan.originalDeploymentSourceFingerprint -ceq [string]$plan.correctedExecutionSourceFingerprint) {
        throw 'The pre-inert source correction must bind two distinct source generations.'
    }
    if ($plan.originalAcceptedPlan -isnot [System.Collections.IDictionary] -or
        (Get-BootstrapObjectFingerprint -InputObject $plan.originalAcceptedPlan) -cne [string]$plan.originalAcceptedPlanFingerprint -or
        [string]$plan.originalAcceptedPlan.sourceFingerprint -cne [string]$plan.originalDeploymentSourceFingerprint -or
        [string]$plan.originalAcceptedPlan.configurationFingerprint -cne [string]$State.configurationFingerprint) {
        throw 'The pre-inert source correction no longer matches its preserved original accepted-plan metadata.'
    }
    $core = Get-BootstrapPreInertSourceCorrectionPlanCore -Plan $plan
    if ((Get-BootstrapObjectFingerprint -InputObject $core) -cne [string]$plan.planFingerprint) {
        throw 'The pre-inert source correction plan fingerprint no longer matches its immutable contract.'
    }
    [string[]]$allowedPaths = @($plan.allowedChangedPaths | ForEach-Object { [string]$_ })
    [Array]::Sort($allowedPaths, [StringComparer]::Ordinal)
    [string[]]$expectedPaths = @($script:BootstrapPreInertCorrectionChangedPaths)
    [Array]::Sort($expectedPaths, [StringComparer]::Ordinal)
    if (($allowedPaths -join "`n") -cne ($expectedPaths -join "`n") -or
        [string]$plan.semanticCorrection.path -cne $script:BootstrapPreInertCorrectionBicepPath -or
        [string]$plan.semanticCorrection.originalLine -cne $script:BootstrapPreInertCorrectionOriginalBicepLine -or
        [string]$plan.semanticCorrection.correctedLine -cne $script:BootstrapPreInertCorrectionCorrectedBicepLine -or
        [int]$plan.semanticCorrection.replacementCount -ne 1) {
        throw 'The pre-inert source correction does not match the exact reviewed path and semantic delta allowlist.'
    }

    $originalRoot = Get-BootstrapPreInertSourceCorrectionSnapshotRoot -State $State -Plan $plan -Generation Original
    $correctedRoot = Get-BootstrapPreInertSourceCorrectionSnapshotRoot -State $State -Plan $plan -Generation Corrected
    $actualDelta = @(Get-BootstrapPreInertSourceCorrectionDelta -OriginalRoot $originalRoot -CorrectedRoot $correctedRoot)
    if ((Get-BootstrapObjectFingerprint -InputObject $actualDelta) -cne
        (Get-BootstrapObjectFingerprint -InputObject $plan.sourceDelta)) {
        throw 'The pre-inert source correction delta no longer matches its immutable source snapshots.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExecutionSourceFingerprint)) {
        Assert-BootstrapFingerprintValue -Value $ExecutionSourceFingerprint -Label 'Pre-inert corrected execution source fingerprint'
        if ($ExecutionSourceFingerprint -cne [string]$plan.correctedExecutionSourceFingerprint) {
            throw 'The pre-inert source correction does not authorize this execution source generation.'
        }
    }
    if ([string]$plan.status -ceq 'Accepted') {
        Assert-BootstrapPendingPreInertSourceCorrectionBoundary -State $State -Plan $plan | Out-Null
    }
    else {
        foreach ($name in @('completionBoundaryFingerprint', 'inertEvidenceFingerprint')) {
            Assert-BootstrapFingerprintValue -Value ([string]$plan[$name]) -Label "Completed pre-inert correction $name"
        }
        $inertStep = $State.steps['Inert identity deployment']
        $allowedAlwaysRunSources = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $null = $allowedAlwaysRunSources.Add([string]$plan.correctedExecutionSourceFingerprint)
        if ($State.Contains('manualDatabaseRepairPlan') -and
            $State.manualDatabaseRepairPlan -is [System.Collections.IDictionary] -and
            [string]$State.manualDatabaseRepairPlan.status -ceq 'Completed' -and
            [string]$State.manualDatabaseRepairPlan.originalSourceFingerprint -ceq [string]$plan.correctedExecutionSourceFingerprint -and
            [string]$State.manualDatabaseRepairPlan.deploymentOwnershipId -ceq ([guid][string]$State.deploymentOwnershipId).ToString('D')) {
            Assert-BootstrapFingerprintValue -Value ([string]$State.manualDatabaseRepairPlan.repairSourceFingerprint) -Label 'Completed manual repair continuation source fingerprint'
            $null = $allowedAlwaysRunSources.Add([string]$State.manualDatabaseRepairPlan.repairSourceFingerprint)
        }
        elseif ($State.Contains('databaseRecoveryPlan') -and
            $State.databaseRecoveryPlan -is [System.Collections.IDictionary] -and
            [string]$State.databaseRecoveryPlan.status -ceq 'Completed' -and
            [string]$State.databaseRecoveryPlan.originalSourceFingerprint -ceq [string]$plan.correctedExecutionSourceFingerprint -and
            [string]$State.databaseRecoveryPlan.deploymentOwnershipId -ceq ([guid][string]$State.deploymentOwnershipId).ToString('D')) {
            Assert-BootstrapFingerprintValue -Value ([string]$State.databaseRecoveryPlan.correctedSourceFingerprint) -Label 'Completed database recovery continuation source fingerprint'
            $null = $allowedAlwaysRunSources.Add([string]$State.databaseRecoveryPlan.correctedSourceFingerprint)
        }
        for ($index = 0; $index -lt 6; $index++) {
            $name = [string]$script:BootstrapPreInertCorrectionStepNames[$index]
            $step = $State.steps[$name]
            if ($step -isnot [System.Collections.IDictionary] -or
                [string]$step.status -cne 'Completed' -or
                -not $step.Contains('evidence') -or $null -eq $step.evidence) {
                throw 'The completed pre-inert correction no longer matches the exact step 1-6 source/evidence generations.'
            }
            if ($index -lt 2) {
                if (-not $allowedAlwaysRunSources.Contains([string]$step.sourceFingerprint)) {
                    throw 'The completed pre-inert correction has an unauthorized AlwaysRun source generation.'
                }
            }
            elseif ([string]$step.sourceFingerprint -cne [string]$plan.originalDeploymentSourceFingerprint) {
                throw 'The completed pre-inert correction no longer matches original-source evidence for steps 3-6.'
            }
        }
        if ($inertStep -isnot [System.Collections.IDictionary] -or
            [string]$inertStep.status -cne 'Completed' -or
            [string]$inertStep.sourceFingerprint -cne [string]$plan.correctedExecutionSourceFingerprint -or
            -not $inertStep.Contains('evidence') -or $null -eq $inertStep.evidence -or
            (Get-BootstrapObjectFingerprint -InputObject $inertStep.evidence) -cne [string]$plan.inertEvidenceFingerprint) {
            throw 'The completed pre-inert correction no longer matches exact corrected step-7 evidence.'
        }
    }
    return $plan
}

function Set-BootstrapPreInertSourceCorrectionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath
    )

    $currentSourceFingerprint = Get-BootstrapSourceFingerprint
    Assert-BootstrapFingerprintValue -Value $currentSourceFingerprint -Label 'Current bootstrap source fingerprint'
    if ($State.Contains('preInertSourceCorrectionPlan')) {
        $plan = Assert-BootstrapPreInertSourceCorrectionPlan -State $State
        if ($currentSourceFingerprint -ceq [string]$plan.correctedExecutionSourceFingerprint) {
            return $plan
        }
        if (($State.Contains('databaseRecoveryPlan') -and
                $State.databaseRecoveryPlan -is [System.Collections.IDictionary] -and
                [string]$State.databaseRecoveryPlan.status -ceq 'Completed') -or
            ($State.Contains('manualDatabaseRepairPlan') -and
                $State.manualDatabaseRepairPlan -is [System.Collections.IDictionary] -and
                [string]$State.manualDatabaseRepairPlan.status -ceq 'Completed')) {
            $effective = Get-BootstrapEffectiveDeploymentSourceFingerprint `
                -State $State `
                -ExecutionSourceFingerprint $currentSourceFingerprint
            if ($effective -ceq [string]$plan.originalDeploymentSourceFingerprint) {
                return $plan
            }
        }
        throw 'The existing pre-inert source correction does not authorize this source generation.'
    }
    $recordedSourceFingerprint = [string]$State.source.lastWritten.bootstrapSourceFingerprint
    Assert-BootstrapFingerprintValue -Value $recordedSourceFingerprint -Label 'Recorded bootstrap evidence source fingerprint'
    if ($currentSourceFingerprint -ceq $recordedSourceFingerprint) { return $null }
    if (-not (Test-BootstrapStateHasEvidence -State $State)) { return $null }
    if ($State.Contains('databaseRecoveryPlan') -or $State.Contains('manualDatabaseRepairPlan')) {
        # Established database recovery/repair helpers own their corrected source
        # generations. The pre-inert bridge must not reinterpret or replace them.
        return $null
    }

    $creation = Assert-BootstrapPreInertSourceCorrectionCreationBoundary -State $State
    $originalAcceptedPlan = ConvertTo-BootstrapCanonicalValue -Value $State.acceptedPlan
    $sourceDelta = @(Get-BootstrapPreInertSourceCorrectionDelta `
        -OriginalRoot ([string]$creation.originalRoot) `
        -CorrectedRoot (Get-RepositoryRoot))
    $core = [ordered]@{
        schemaVersion = 1
        correctionKind = 'PromptShieldPreInertBicepReference'
        generation = 1
        configurationFingerprint = [string]$State.configurationFingerprint
        deploymentOwnershipId = ([guid][string]$State.deploymentOwnershipId).ToString('D')
        originalDeploymentSourceFingerprint = [string]$State.acceptedPlan.sourceFingerprint
        correctedExecutionSourceFingerprint = $currentSourceFingerprint
        originalAcceptedPlanFingerprint = Get-BootstrapObjectFingerprint -InputObject $originalAcceptedPlan
        originalAcceptedPlan = $originalAcceptedPlan
        originalBoundaryFingerprint = [string]$creation.boundaryFingerprint
        allowedChangedPaths = @($script:BootstrapPreInertCorrectionChangedPaths)
        sourceDelta = ConvertTo-BootstrapCanonicalValue -Value $sourceDelta
        semanticCorrection = [ordered]@{
            path = $script:BootstrapPreInertCorrectionBicepPath
            originalLine = $script:BootstrapPreInertCorrectionOriginalBicepLine
            correctedLine = $script:BootstrapPreInertCorrectionCorrectedBicepLine
            replacementCount = 1
        }
    }
    $planFingerprint = Get-BootstrapObjectFingerprint -InputObject $core
    $correctedExecutionSource = New-BootstrapAcceptedSourceSnapshot `
        -State $State `
        -PlanFingerprint $planFingerprint `
        -SourceFingerprint $currentSourceFingerprint
    $plan = ConvertTo-BootstrapCanonicalValue -Value $core
    $plan['planFingerprint'] = $planFingerprint
    $plan['correctedExecutionSource'] = $correctedExecutionSource
    $plan['status'] = 'Accepted'
    $plan['createdAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    $State['preInertSourceCorrectionPlan'] = $plan
    Save-BootstrapState -State $State -Path $StatePath
    return $plan
}

function Complete-BootstrapPreInertSourceCorrectionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath
    )

    if (-not $State.Contains('preInertSourceCorrectionPlan')) { return $null }
    $plan = Assert-BootstrapPreInertSourceCorrectionPlan -State $State
    if ([string]$plan.status -ceq 'Completed') { return $plan }
    $expectedSteps = @($script:BootstrapPreInertCorrectionStepNames)
    [string[]]$actualSteps = @($State.steps.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($actualSteps, [StringComparer]::Ordinal)
    [string[]]$sortedExpectedSteps = @($expectedSteps)
    [Array]::Sort($sortedExpectedSteps, [StringComparer]::Ordinal)
    if (($actualSteps -join "`n") -cne ($sortedExpectedSteps -join "`n")) {
        throw 'Pre-inert source correction may complete only immediately after exact corrected step-7 evidence and before any later step.'
    }
    for ($index = 0; $index -lt 6; $index++) {
        $step = $State.steps[[string]$expectedSteps[$index]]
        $expectedSourceFingerprint = if ($index -lt 2) {
            [string]$plan.correctedExecutionSourceFingerprint
        }
        else {
            [string]$plan.originalDeploymentSourceFingerprint
        }
        if ($step -isnot [System.Collections.IDictionary] -or
            [string]$step.status -cne 'Completed' -or
            [string]$step.sourceFingerprint -cne $expectedSourceFingerprint -or
            -not $step.Contains('evidence') -or $null -eq $step.evidence) {
            throw 'Pre-inert source correction completion requires corrected steps 1-2 and unchanged original-source evidence for steps 3-6.'
        }
    }
    $inertStep = $State.steps['Inert identity deployment']
    if ($inertStep -isnot [System.Collections.IDictionary] -or
        [string]$inertStep.status -cne 'Completed' -or
        [string]$inertStep.sourceFingerprint -cne [string]$plan.correctedExecutionSourceFingerprint -or
        -not $inertStep.Contains('evidence') -or $null -eq $inertStep.evidence) {
        throw 'Pre-inert source correction completion requires exact completed corrected-source step-7 evidence.'
    }
    $plan['status'] = 'Completed'
    $plan['completedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    $plan['inertEvidenceFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $inertStep.evidence
    $plan['completionBoundaryFingerprint'] = Get-BootstrapPreInertSourceCorrectionBoundaryFingerprint `
        -State $State `
        -OriginalSourceFingerprint ([string]$plan.originalDeploymentSourceFingerprint) `
        -CorrectedSourceFingerprint ([string]$plan.correctedExecutionSourceFingerprint) `
        -Completed
    Save-BootstrapState -State $State -Path $StatePath
    return Assert-BootstrapPreInertSourceCorrectionPlan -State $State
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
    $effectiveSourceFingerprint = $ExecutionSourceFingerprint
    if ($State.Contains('manualDatabaseRepairPlan') -and
        $State.manualDatabaseRepairPlan -is [System.Collections.IDictionary] -and
        [string]$State.manualDatabaseRepairPlan.status -ceq 'Completed') {
        Assert-BootstrapManualDatabaseRepairPrerequisite -State $State | Out-Null
        $repair = $State.manualDatabaseRepairPlan
        foreach ($name in @('originalSourceFingerprint', 'repairSourceFingerprint', 'databaseEvidenceFingerprint')) {
            Assert-BootstrapFingerprintValue -Value ([string]$repair[$name]) -Label "Completed manual database repair $name"
        }
        if ([string]$repair.repairSourceFingerprint -cne $ExecutionSourceFingerprint -or
            [string]$repair.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D')) {
            throw 'The completed manual database repair does not authorize this execution source or deployment ownership.'
        }
        $effectiveSourceFingerprint = [string]$repair.originalSourceFingerprint
    }
    elseif ($State.Contains('databaseRecoveryPlan') -and
        $State.databaseRecoveryPlan -is [System.Collections.IDictionary] -and
        [string]$State.databaseRecoveryPlan.status -ceq 'Completed') {
        $recoveryPlan = $State.databaseRecoveryPlan
        Assert-BootstrapFingerprintValue -Value ([string]$recoveryPlan.correctedSourceFingerprint) -Label 'Completed database recovery corrected source fingerprint'
        Assert-BootstrapFingerprintValue -Value ([string]$recoveryPlan.originalSourceFingerprint) -Label 'Completed database recovery original source fingerprint'
        Assert-BootstrapFingerprintValue -Value ([string]$recoveryPlan.databaseEvidenceFingerprint) -Label 'Completed database recovery evidence fingerprint'
        if ([string]$recoveryPlan.correctedSourceFingerprint -cne $ExecutionSourceFingerprint -or
            [string]$recoveryPlan.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D')) {
            throw 'The completed database recovery does not authorize this execution source or deployment ownership.'
        }
        $effectiveSourceFingerprint = [string]$recoveryPlan.originalSourceFingerprint
    }

    if ($State.Contains('preInertSourceCorrectionPlan')) {
        $correction = Assert-BootstrapPreInertSourceCorrectionPlan -State $State
        if ($effectiveSourceFingerprint -ceq [string]$correction.correctedExecutionSourceFingerprint) {
            $effectiveSourceFingerprint = [string]$correction.originalDeploymentSourceFingerprint
        }
        elseif ($effectiveSourceFingerprint -cne [string]$correction.originalDeploymentSourceFingerprint) {
            throw 'The pre-inert source correction does not map this effective execution source to the original deployment generation.'
        }
    }
    return $effectiveSourceFingerprint
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

    # Setup briefly emitted this property with the only supported value, false.
    # Accept that exact legacy output long enough to migrate it in memory, while
    # continuing to reject true, non-boolean values, casing variants, and every
    # other undeclared property through the current schema.
    $schemaInput = $raw
    $purviewProperties = @($config.PSObject.Properties | Where-Object { $_.Name -ceq 'purview' })
    if ($purviewProperties.Count -eq 1 -and $null -ne $purviewProperties[0].Value) {
        $purview = $purviewProperties[0].Value
        $legacyProperties = @($purview.PSObject.Properties | Where-Object {
            $_.Name -ceq 'activateGatewayAdapterAfterPolicyReadback'
        })
        if ($legacyProperties.Count -eq 1) {
            if ($legacyProperties[0].Value -isnot [bool] -or [bool]$legacyProperties[0].Value) {
                throw 'Bootstrap configuration failed JSON Schema validation. Review property names, types, formats, and allowed values against bootstrap/config.schema.json; rejected input values were suppressed.'
            }
            $purview.PSObject.Properties.Remove('activateGatewayAdapterAfterPolicyReadback')
            $schemaInput = $config | ConvertTo-Json -Depth 30 -Compress
        }
    }

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
        throw 'Agent Registration preview can be enabled only for the dev environment.'
    }
    if ($config.purview.enabled -eq $true -and [string]::IsNullOrWhiteSpace([string]$config.purview.sensitiveInformationType)) {
        throw 'purview.sensitiveInformationType is required when Purview is enabled; the bootstrap never invents a tenant DLP classifier.'
    }
    if ($config.purview.enabled -eq $true) {
        foreach ($name in @('collectionPolicyName', 'dlpPolicyName', 'dlpRuleName')) {
            if ([string]::IsNullOrWhiteSpace([string]$config.purview.$name)) { throw "purview.$name is required when Purview is enabled." }
        }
    }
    if ($config.purview.policyProvisioningEnabled -eq $true) {
        if ($config.purview.enabled -ne $true) {
            throw 'Purview policy-profile automation requires purview.enabled=true.'
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
        if ($State.Contains('manualDatabaseRepairPlan') -and
            $State.manualDatabaseRepairPlan -is [System.Collections.IDictionary] -and
            [string]$State.manualDatabaseRepairPlan.status -ceq 'Completed') {
            Assert-BootstrapManualDatabaseRepairPrerequisite -State $State | Out-Null
            $repair = $State.manualDatabaseRepairPlan
            foreach ($name in @('planFingerprint', 'originalSourceFingerprint', 'repairSourceFingerprint', 'databaseEvidenceFingerprint')) {
                Assert-BootstrapFingerprintValue -Value ([string]$repair[$name]) -Label "Completed manual database repair $name"
            }
            $databaseStep = if ($State.steps -is [System.Collections.IDictionary]) { $State.steps['Gateway database'] } else { $null }
            if ([string]$repair.repairSourceFingerprint -ceq $current -and
                [string]$repair.deploymentOwnershipId -ceq ([guid][string]$State.deploymentOwnershipId).ToString('D') -and
                $databaseStep -is [System.Collections.IDictionary] -and
                [string]$databaseStep.status -ceq 'Completed' -and
                [string]$databaseStep.completionMode -ceq 'ManualDatabaseRepair' -and
                $databaseStep.evidence -is [System.Collections.IDictionary] -and
                [string]$databaseStep.evidence.manualDatabaseRepairPlanFingerprint -ceq [string]$repair.planFingerprint -and
                (Get-BootstrapObjectFingerprint -InputObject $databaseStep.evidence) -ceq [string]$repair.databaseEvidenceFingerprint) {
                return $true
            }
        }
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
        if ($State.Contains('preInertSourceCorrectionPlan')) {
            $correction = Assert-BootstrapPreInertSourceCorrectionPlan `
                -State $State `
                -ExecutionSourceFingerprint $current
            if ([string]$correction.originalDeploymentSourceFingerprint -ceq $recorded) {
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

function Get-BootstrapCompletedDatabaseValidationPlans {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)

    $hasAutomatic = $State.Contains('databaseRecoveryPlan')
    $hasManual = $State.Contains('manualDatabaseRepairPlan')
    $automaticCompleted = $hasAutomatic -and
        $State.databaseRecoveryPlan -is [System.Collections.IDictionary] -and
        [string]$State.databaseRecoveryPlan.status -ceq 'Completed'
    $manualCompleted = $hasManual -and
        $State.manualDatabaseRepairPlan -is [System.Collections.IDictionary] -and
        [string]$State.manualDatabaseRepairPlan.status -ceq 'Completed'

    if ($automaticCompleted -and $manualCompleted) {
        throw 'Automatic database recovery and manual database repair cannot both be completed.'
    }
    if ($manualCompleted) {
        Assert-BootstrapManualDatabaseRepairPrerequisite -State $State | Out-Null
        return [ordered]@{
            databaseRecoveryPlan = $null
            manualDatabaseRepairPlan = $State.manualDatabaseRepairPlan
        }
    }
    if ($automaticCompleted) {
        Assert-BootstrapDatabaseRecoveryHistory -State $State -CurrentPlan $State.databaseRecoveryPlan | Out-Null
        return [ordered]@{
            databaseRecoveryPlan = $State.databaseRecoveryPlan
            manualDatabaseRepairPlan = $null
        }
    }
    if ($hasAutomatic -or $hasManual) {
        throw 'Standard bootstrap validation cannot adopt an incomplete database recovery or repair boundary.'
    }
    return [ordered]@{
        databaseRecoveryPlan = $null
        manualDatabaseRepairPlan = $null
    }
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

function Get-GatewayManualDatabaseRepairContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    return [ordered]@{
        jobName = "job-$($Config.projectName)-db-repair-$($Config.environment)"
        containerName = 'database-manual-repair'
        workloadTag = 'database-bootstrap-manual-repair'
        deploymentName = "a365gw-$($Config.projectName)-bootstrap-database-manual-repair-$($Config.environment)"
        receiptFileName = 'private-database-bootstrap-manual-repair-receipt.json'
        evidenceDirectoryName = 'manual-repair'
    }
}

function Resolve-BootstrapManualDatabaseRepairPlanSourceRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter()][AllowNull()][System.Collections.IDictionary]$Plan
    )

    if ($null -eq $Plan) {
        if (-not $State.Contains('manualDatabaseRepairPlan') -or
            $State.manualDatabaseRepairPlan -isnot [System.Collections.IDictionary]) {
            throw 'No accepted manual database repair plan exists for this bootstrap state.'
        }
        $Plan = $State.manualDatabaseRepairPlan
    }
    foreach ($name in @('planFingerprint', 'repairSourceFingerprint', 'executionSource')) {
        if (-not $Plan.Contains($name) -or [string]::IsNullOrWhiteSpace([string]$Plan[$name])) {
            throw 'The manual database repair plan is missing its immutable execution-source boundary.'
        }
    }
    Assert-BootstrapFingerprintValue -Value ([string]$Plan.planFingerprint) -Label 'Manual database repair plan fingerprint'
    Assert-BootstrapFingerprintValue -Value ([string]$Plan.repairSourceFingerprint) -Label 'Manual database repair source fingerprint'
    $canonicalOwnershipId = ([guid][string]$State.deploymentOwnershipId).ToString('D')
    $expectedRelative = ".bootstrap/accepted-source/$canonicalOwnershipId/$(([string]$Plan.planFingerprint).Substring(7))"
    if ([string]$Plan.executionSource -cne $expectedRelative) {
        throw 'The manual database repair source snapshot is not bound to this exact deployment ownership and plan fingerprint.'
    }
    $root = Get-RepositoryRoot
    $acceptedRoot = [IO.Path]::GetFullPath((Join-Path $root '.bootstrap/accepted-source'))
    $snapshot = [IO.Path]::GetFullPath((Join-Path $root ([string]$Plan.executionSource)))
    if (-not $snapshot.StartsWith($acceptedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal) -or
        -not (Test-Path -LiteralPath $snapshot -PathType Container) -or
        (Get-BootstrapSourceFingerprint -Root $snapshot) -cne [string]$Plan.repairSourceFingerprint) {
        throw 'The manual database repair source snapshot is absent, modified, or outside its managed boundary.'
    }
    return $snapshot
}

function Assert-BootstrapManualDatabaseRepairPrerequisite {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)

    if (-not $State.Contains('databaseRecoveryPlan') -or
        $State.databaseRecoveryPlan -isnot [System.Collections.IDictionary] -or
        (Get-BootstrapDatabaseRecoveryAttemptNumber -Plan $State.databaseRecoveryPlan) -ne 2 -or
        [string]$State.databaseRecoveryPlan.status -cne 'Failed' -or
        $State.databaseRecoveryPlan.manualOnly -ne $true -or
        $State.databaseRecoveryPlan.failedRecovery -isnot [System.Collections.IDictionary]) {
        throw 'Manual database repair requires the exact terminal Failed/manualOnly second recovery attempt.'
    }
    Assert-BootstrapDatabaseRecoveryHistory -State $State -CurrentPlan $State.databaseRecoveryPlan | Out-Null
    if ([string]$State.databaseRecoveryPlan.failedRecovery.recoveryPlanFingerprint -cne
        [string]$State.databaseRecoveryPlan.planFingerprint) {
        throw 'The terminal second recovery failure no longer matches its preserved recovery plan.'
    }
    foreach ($fingerprint in @(
        [string]$State.databaseRecoveryPlan.failedJob.boundaryFingerprint,
        [string]$State.databaseRecoveryPlan.priorFailedRecovery.boundaryFingerprint,
        [string]$State.databaseRecoveryPlan.failedRecovery.boundaryFingerprint
    )) {
        Assert-BootstrapFingerprintValue -Value $fingerprint -Label 'Manual database repair failed-boundary fingerprint'
    }
    return $true
}

function Set-BootstrapAcceptedManualDatabaseRepairPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    Assert-BootstrapManualDatabaseRepairPrerequisite -State $State | Out-Null
    if ($State.Contains('manualDatabaseRepairPlan')) {
        throw 'A manual database repair plan already exists. It is one-shot and cannot be replaced.'
    }
    foreach ($name in @(
        'schemaVersion', 'planFingerprint', 'configurationFingerprint', 'deploymentOwnershipId',
        'originalSourceFingerprint', 'repairSourceFingerprint', 'originalAcceptedPlan',
        'exhaustedRecoveryPlanFingerprint', 'exhaustedRecoveryPlan', 'originalFailedJob',
        'firstFailedRecovery', 'secondFailedRecovery', 'correctedImage', 'repairJob'
    )) {
        if (-not $Plan.Contains($name)) { throw "The manual database repair plan is missing '$name'." }
    }
    if (-not $State.Contains('acceptedPlan') -or
        $State.acceptedPlan -isnot [System.Collections.IDictionary] -or
        $Plan.originalAcceptedPlan -isnot [System.Collections.IDictionary]) {
        throw 'The manual database repair plan requires the complete preserved original accepted plan.'
    }
    $recovery = $State.databaseRecoveryPlan
    if ([int]$Plan.schemaVersion -ne 1 -or
        [string]$Plan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$Plan.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D') -or
        [string]$Plan.originalSourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint -or
        (Get-BootstrapObjectFingerprint -InputObject $Plan.originalAcceptedPlan) -cne
            (Get-BootstrapObjectFingerprint -InputObject $State.acceptedPlan) -or
        [string]$Plan.exhaustedRecoveryPlanFingerprint -cne [string]$recovery.planFingerprint -or
        (Get-BootstrapObjectFingerprint -InputObject $Plan.exhaustedRecoveryPlan) -cne
            (Get-BootstrapObjectFingerprint -InputObject $recovery) -or
        [string]$Plan.originalFailedJob.boundaryFingerprint -cne [string]$recovery.failedJob.boundaryFingerprint -or
        [string]$Plan.firstFailedRecovery.boundaryFingerprint -cne [string]$recovery.priorFailedRecovery.boundaryFingerprint -or
        [string]$Plan.secondFailedRecovery.boundaryFingerprint -cne [string]$recovery.failedRecovery.boundaryFingerprint -or
        [string]$Plan.repairJob.imageIntentId -cne [string]$Plan.correctedImage.intentId -or
        [string]$Plan.repairJob.repairMode -cne 'ResumeAfterSchemaCompleted' -or
        [int]$Plan.repairJob.replicaRetryLimit -ne 0 -or
        [int]$Plan.repairJob.maximumExecutions -ne 1) {
        throw 'The manual database repair plan does not preserve the exact original and exhausted recovery boundaries.'
    }
    foreach ($fingerprint in @(
        [string]$Plan.planFingerprint,
        [string]$Plan.configurationFingerprint,
        [string]$Plan.originalSourceFingerprint,
        [string]$Plan.repairSourceFingerprint,
        [string]$Plan.exhaustedRecoveryPlanFingerprint
    )) {
        Assert-BootstrapFingerprintValue -Value $fingerprint -Label 'Manual database repair fingerprint'
    }
    $currentSource = Get-BootstrapSourceFingerprint
    if ([string]$Plan.repairSourceFingerprint -cne $currentSource -or
        [string]$Plan.repairSourceFingerprint -ceq [string]$Plan.originalSourceFingerprint -or
        [string]$Plan.repairSourceFingerprint -ceq [string]$recovery.correctedSourceFingerprint -or
        [string]$Plan.repairSourceFingerprint -ceq [string]$recovery.previousRecoveryPlan.correctedSourceFingerprint) {
        throw 'Manual database repair requires one new reviewed source generation distinct from the original and both failed recovery sources.'
    }
    $planCore = [ordered]@{}
    foreach ($key in $Plan.Keys) {
        if ([string]$key -cne 'planFingerprint') { $planCore[[string]$key] = $Plan[$key] }
    }
    if ((Get-BootstrapObjectFingerprint -InputObject $planCore) -cne [string]$Plan.planFingerprint) {
        throw 'The manual database repair plan fingerprint does not cover its complete one-shot contract.'
    }
    $executionSource = New-BootstrapAcceptedSourceSnapshot `
        -State $State -PlanFingerprint ([string]$Plan.planFingerprint) -SourceFingerprint $currentSource
    $accepted = ConvertTo-BootstrapCanonicalValue -Value $Plan
    $accepted['status'] = 'Accepted'
    $accepted['executionSource'] = $executionSource
    $accepted['acceptedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    $accepted['databaseEvidenceFingerprint'] = ''
    $accepted['completedAtUtc'] = ''
    $accepted['failedAtUtc'] = ''
    $accepted['manualOnly'] = $true
    $State['manualDatabaseRepairPlan'] = $accepted
    Save-BootstrapState -State $State -Path $StatePath
    return $State.manualDatabaseRepairPlan
}

function Assert-BootstrapAcceptedManualDatabaseRepairPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$PlanFingerprint,
        [Parameter()][TimeSpan]$MaximumAge = ([TimeSpan]::FromMinutes(60)),
        [switch]$AllowCompleted
    )

    Assert-BootstrapManualDatabaseRepairPrerequisite -State $State | Out-Null
    Assert-BootstrapFingerprintValue -Value $PlanFingerprint -Label 'Manual database repair plan fingerprint'
    if (-not $State.Contains('manualDatabaseRepairPlan') -or
        $State.manualDatabaseRepairPlan -isnot [System.Collections.IDictionary]) {
        throw 'No accepted manual database repair plan exists.'
    }
    $plan = $State.manualDatabaseRepairPlan
    $contract = Get-GatewayManualDatabaseRepairContract -Config ([pscustomobject]@{
        projectName = [string]$State.configuration.projectName
        environment = [string]$State.configuration.environment
    })
    if ([string]$plan.planFingerprint -cne $PlanFingerprint -or
        [string]$plan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$plan.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D') -or
        $plan.originalAcceptedPlan -isnot [System.Collections.IDictionary] -or
        $State.acceptedPlan -isnot [System.Collections.IDictionary] -or
        (Get-BootstrapObjectFingerprint -InputObject $plan.originalAcceptedPlan) -cne
            (Get-BootstrapObjectFingerprint -InputObject $State.acceptedPlan) -or
        [string]$plan.exhaustedRecoveryPlanFingerprint -cne [string]$State.databaseRecoveryPlan.planFingerprint -or
        [string]$plan.repairSourceFingerprint -cne (Get-BootstrapSourceFingerprint) -or
        [string]$plan.repairJob.name -cne [string]$contract.jobName -or
        [string]$plan.repairJob.repairMode -cne 'ResumeAfterSchemaCompleted' -or
        [int]$plan.repairJob.replicaRetryLimit -ne 0 -or
        [int]$plan.repairJob.maximumExecutions -ne 1) {
        throw 'The accepted manual database repair plan no longer matches its exact source, ownership, or one-shot Job contract.'
    }
    $validStatuses = if ($AllowCompleted) { @('Accepted', 'Running', 'Completed') } else { @('Accepted', 'Running') }
    if ([string]$plan.status -cnotin $validStatuses) {
        throw 'The manual database repair plan is not executable. Its one-shot boundary is consumed.'
    }
    $null = Resolve-BootstrapManualDatabaseRepairPlanSourceRoot -State $State -Plan $plan
    if ([string]$plan.status -ceq 'Accepted') {
        $acceptedAt = [DateTimeOffset]::MinValue
        $age = [TimeSpan]::MaxValue
        if ([DateTimeOffset]::TryParseExact(
                [string]$plan.acceptedAtUtc, 'O', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$acceptedAt)) {
            $age = [DateTimeOffset]::UtcNow - $acceptedAt.ToUniversalTime()
        }
        if ($age -lt [TimeSpan]::FromMinutes(-5) -or $age -gt $MaximumAge) {
            throw 'The accepted manual database repair plan is outside its 60-minute execution window.'
        }
    }
    return $true
}

function Start-BootstrapManualDatabaseRepairPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$PlanFingerprint
    )

    Assert-BootstrapAcceptedManualDatabaseRepairPlan -State $State -PlanFingerprint $PlanFingerprint | Out-Null
    if ([string]$State.manualDatabaseRepairPlan.status -ceq 'Accepted') {
        $State.manualDatabaseRepairPlan.status = 'Running'
        $State.manualDatabaseRepairPlan.startedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Save-BootstrapState -State $State -Path $StatePath
    }
    elseif ([string]$State.manualDatabaseRepairPlan.status -cne 'Running') {
        throw 'Manual database repair is not in an executable one-shot state.'
    }
    return $State.manualDatabaseRepairPlan
}

function Set-BootstrapFailedManualDatabaseRepairPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$FailedRepair
    )

    if (-not $State.Contains('manualDatabaseRepairPlan') -or
        $State.manualDatabaseRepairPlan -isnot [System.Collections.IDictionary] -or
        [string]$State.manualDatabaseRepairPlan.status -cne 'Running' -or
        [string]$FailedRepair.manualDatabaseRepairPlanFingerprint -cne
            [string]$State.manualDatabaseRepairPlan.planFingerprint) {
        throw 'Only the exact Running manual database repair may be marked failed.'
    }
    $State.manualDatabaseRepairPlan.status = 'Failed'
    $State.manualDatabaseRepairPlan.failedRepair = ConvertTo-BootstrapCanonicalValue -Value $FailedRepair
    $State.manualDatabaseRepairPlan.failedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    $State.manualDatabaseRepairPlan.manualOnly = $true
    Save-BootstrapState -State $State -Path $StatePath
    return $State.manualDatabaseRepairPlan
}

function Complete-BootstrapManualDatabaseRepairPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$PlanFingerprint,
        [Parameter(Mandatory)][System.Collections.IDictionary]$DatabaseEvidence
    )

    Assert-BootstrapAcceptedManualDatabaseRepairPlan -State $State -PlanFingerprint $PlanFingerprint | Out-Null
    $plan = $State.manualDatabaseRepairPlan
    if ($plan.correctedImage -isnot [System.Collections.IDictionary] -or
        [string]$plan.correctedImage.state -cne 'DigestCheckpointed' -or
        [string]$plan.correctedImage.component -cne 'databaseMigratorRecovery' -or
        [string]$plan.correctedImage.sourceFingerprint -cne [string]$plan.repairSourceFingerprint -or
        [string]$plan.correctedImage.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D') -or
        [string]$plan.correctedImage.recoveryPlanFingerprint -cne $PlanFingerprint -or
        [string]$plan.correctedImage.intentId -cne [string]$plan.repairJob.imageIntentId -or
        [string]$plan.correctedImage.image -cnotmatch '^[a-z0-9.-]+/gateway-db-migrator@sha256:[0-9a-f]{64}$' -or
        [string]$DatabaseEvidence.databaseBootstrapJobImage -cne [string]$plan.correctedImage.image -or
        [string]$DatabaseEvidence.manualDatabaseRepairPlanFingerprint -cne $PlanFingerprint -or
        [string]$DatabaseEvidence.exhaustedDatabaseRecoveryPlanFingerprint -cne [string]$plan.exhaustedRecoveryPlanFingerprint -or
        [string]$DatabaseEvidence.acceptedSourceFingerprint -cne [string]$plan.originalSourceFingerprint -or
        [string]$DatabaseEvidence.manualDatabaseRepairSourceFingerprint -cne [string]$plan.repairSourceFingerprint -or
        [string]$DatabaseEvidence.originalFailedDatabaseBootstrapBoundaryFingerprint -cne [string]$plan.originalFailedJob.boundaryFingerprint -or
        [string]$DatabaseEvidence.firstFailedDatabaseRecoveryBoundaryFingerprint -cne [string]$plan.firstFailedRecovery.boundaryFingerprint -or
        [string]$DatabaseEvidence.secondFailedDatabaseRecoveryBoundaryFingerprint -cne [string]$plan.secondFailedRecovery.boundaryFingerprint -or
        [string]$DatabaseEvidence.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D')) {
        throw 'Manual database repair evidence does not match its complete accepted failure/source/ownership chain.'
    }
    $completedAt = [DateTimeOffset]::UtcNow.ToString('O')
    $evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $DatabaseEvidence
    $priorStep = ConvertTo-BootstrapCanonicalValue -Value $State.steps['Gateway database']
    $State.manualDatabaseRepairPlan.status = 'Completed'
    $State.manualDatabaseRepairPlan.databaseEvidenceFingerprint = $evidenceFingerprint
    $State.manualDatabaseRepairPlan.completedAtUtc = $completedAt
    $State.steps['Gateway database'] = [ordered]@{
        status = 'Completed'
        startedAtUtc = [string]$State.manualDatabaseRepairPlan.startedAtUtc
        completedAtUtc = $completedAt
        sourceFingerprint = [string]$plan.repairSourceFingerprint
        completionMode = 'ManualDatabaseRepair'
        priorFailedStepFingerprint = Get-BootstrapObjectFingerprint -InputObject $priorStep
        evidence = $DatabaseEvidence
    }
    Save-BootstrapState -State $State -Path $StatePath
    return $State.manualDatabaseRepairPlan
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
        [switch]$ValidateAndReuseOnly,
        [switch]$AlwaysRun
    )
    Write-BootstrapStep $Name
    if ($ValidateAndReuseOnly -and $AlwaysRun) {
        throw "Bootstrap step '$Name' cannot combine validation/reuse-only mode with AlwaysRun behavior."
    }
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
    if ($ValidateAndReuseOnly) {
        if ($existing -isnot [System.Collections.IDictionary] -or
            [string]$existing.status -cne 'Completed' -or
            -not $existing.Contains('evidence') -or $null -eq $existing.evidence) {
            Write-BootstrapEvent -Status Failed -StepName $Name
            throw "Bootstrap step '$Name' is validation/reuse-only for this source correction, but no exact completed evidence exists. No action was executed and state was preserved."
        }
        if (-not $Validate) {
            Write-BootstrapEvent -Status Failed -StepName $Name
            throw "Bootstrap step '$Name' is validation/reuse-only for this source correction and requires an independent read-only validator. No action was executed and state was preserved."
        }
        try {
            [object[]]$validationResult = @(& $Validate)
            if ($validationResult.Count -ne 1 -or $validationResult[0] -isnot [bool]) {
                throw 'Validator must return exactly one Boolean value.'
            }
            if ([bool]$validationResult[0] -ne $true) {
                throw 'Exact completed evidence did not pass independent readback.'
            }
        }
        catch {
            Write-BootstrapEvent -Status Failed -StepName $Name
            throw "Bootstrap step '$Name' could not be revalidated under its validation/reuse-only source-correction boundary. No action was executed and the exact completed record was preserved."
        }
        Write-BootstrapSuccess "$Name already complete and revalidated"
        Write-BootstrapEvent -Status Completed -StepName $Name -Reused -Revalidated
        return $existing.evidence
    }
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
