#Requires -Version 7.0

<#
.SYNOPSIS
    Performs a read-only provisioning deployment preflight.

.DESCRIPTION
    Verifies that the API and worker target the approved VNet-integrated Container
    Apps environment, Azure SQL has an approved private endpoint, the worker has
    exactly the required Microsoft Graph application roles, and the Gateway API has
    the exact OBO federated credential plus tenant-wide delegated Registry consent.

    This script never creates role assignments, grants tenant consent, reads secret
    values, receives messages, replays messages, purges a DLQ, or changes Azure state.

    RequireExecutionReady normally expects both execution gates enabled. During the
    required worker-first canary staging step, ExpectApiAdmissionClosed instead
    requires the worker execution gates on while API registration admission remains
    off.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedSubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedTenantId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = 'rg-agent-gateway',

    [Parameter(Mandatory = $false)]
    [string]$ProjectName = 'a365gw',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ContainerAppsEnvironmentName,

    [Parameter(Mandatory = $false)]
    [string]$WorkerContainerAppName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedServiceBusQueueName = 'gateway-provisioning-v3',

    [Parameter(Mandatory = $false)]
    [bool]$WorkerProcessingEnabled = $false,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedGatewayApiApplicationClientId,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedCredentialKeyVaultUri,

    [Parameter(Mandatory = $false)]
    [string[]]$ExpectedManagerApplicationIds = @(),

    [Parameter(Mandatory = $false)]
    [ValidateSet('Disabled', 'DirectRegistryPreview')]
    [string]$RegistryProvider = 'Disabled',

    [switch]$DirectRegistryPreviewEnabled,

    [switch]$DelegatedRegistryEnabled,

    [switch]$ExpectLegacyWorkerCredentialKeyVaultRole,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedGatewayApiFederatedCredentialName = 'a365gw-api-obo-dev',

    [switch]$RequireExecutionReady,

    [switch]$ExpectContinuousDevelopmentAccess,

    [switch]$ExpectApiAdmissionClosed,

    [switch]$ExpectDelegatedRegistryActionOpen,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedProvisioningAuthorizedExternalAgentId = '',

    [Parameter(Mandatory = $false)]
    [string]$ExpectedProvisioningAuthorizedRetryAgentId = '',

    [Parameter(Mandatory = $false)]
    [string]$ExpectedProvisioningAdmissionExpiresAtUtc = '',

    [Parameter(Mandatory = $false)]
    [string]$ExpectedDelegatedRegistryActionExpiresAtUtc = '',

    [Parameter(Mandatory = $false)]
    [string]$ExpectedDelegatedRegistryAuthorizedOperationId = '',

    [switch]$ManagerApplicationsPreflightConfirmed,

    [switch]$AllowMissingWorkloads,

    [switch]$RequireDeployedConfigurationMatch
)

$ErrorActionPreference = 'Stop'

$parsedExpectedSubscriptionId = [guid]::Empty
if (-not [guid]::TryParse($ExpectedSubscriptionId, [ref]$parsedExpectedSubscriptionId) -or
    $parsedExpectedSubscriptionId -eq [guid]::Empty -or
    $ExpectedSubscriptionId -cne $parsedExpectedSubscriptionId.ToString('D')) {
    throw 'ExpectedSubscriptionId must be one canonical lowercase non-empty GUID.'
}
$parsedExpectedTenantId = [guid]::Empty
if (-not [guid]::TryParse($ExpectedTenantId, [ref]$parsedExpectedTenantId) -or
    $parsedExpectedTenantId -eq [guid]::Empty -or
    $ExpectedTenantId -cne $parsedExpectedTenantId.ToString('D')) {
    throw 'ExpectedTenantId must be one canonical lowercase non-empty GUID.'
}

$MicrosoftGraphAppId = '00000003-0000-0000-c000-000000000000'
$Agent365ObservabilityAppId = '9b975845-388f-4429-889e-eab1ef63949c'
$RequiredAgent365Role = 'Agent365.Observability.OtelWrite'
$LegacyKeyVaultRole = 'Key Vault Secrets Officer'
$RequiredGraphApplicationPermissions = @(
    'Application.Read.All',
    'AppRoleAssignment.ReadWrite.All',
    'AgentIdentityBlueprint.Create',
    'AgentIdentityBlueprint.AddRemoveCreds.All',
    'AgentIdentityBlueprintPrincipal.Create',
    'AgentIdentityBlueprint.Read.All',
    'AgentIdentity.Create.All',
    'AgentIdentity.Read.All'
)
$ProhibitedWorkerGraphApplicationPermissions = @(
    'AgentRegistration.Read.All',
    'AgentRegistration.ReadWrite.All'
)
$RequiredApiGraphApplicationPermissions = @(
    'AgentIdentityBlueprint.Read.All'
)
$RequiredApiGraphDelegatedRegistryScopes = @(
    'AgentRegistration.Read.All',
    'AgentRegistration.ReadWrite.All'
)
$TokenExchangeAudience = 'api://AzureADTokenExchange'

$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Write-Check {
    param([string]$Message)
    Write-Host "[CHECK] $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Add-PreflightWarning {
    param([string]$Message)
    $warnings.Add($Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function ConvertFrom-JsonElementPreservingStrings {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.Json.JsonElement]$Element
    )

    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $properties = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                $properties[$property.Name] =
                    ConvertFrom-JsonElementPreservingStrings -Element $property.Value
            }
            return [pscustomobject]$properties
        }
        ([System.Text.Json.JsonValueKind]::Array) {
            $values = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                $values.Add(
                    (ConvertFrom-JsonElementPreservingStrings -Element $item))
            }
            return ,($values.ToArray())
        }
        ([System.Text.Json.JsonValueKind]::String) {
            return $Element.GetString()
        }
        ([System.Text.Json.JsonValueKind]::Number) {
            $integerValue = 0L
            if ($Element.TryGetInt64([ref]$integerValue)) {
                return $integerValue
            }

            $decimalValue = 0D
            if ($Element.TryGetDecimal([ref]$decimalValue)) {
                return $decimalValue
            }

            return $Element.GetDouble()
        }
        ([System.Text.Json.JsonValueKind]::True) {
            return $true
        }
        ([System.Text.Json.JsonValueKind]::False) {
            return $false
        }
        ([System.Text.Json.JsonValueKind]::Null) {
            return $null
        }
        default {
            throw "Unsupported JSON value kind '$($Element.ValueKind)'."
        }
    }
}

function ConvertFrom-AzJsonPreservingStrings {
    param([Parameter(Mandatory = $true)][string]$RawJson)

    $convertFromJson = Get-Command ConvertFrom-Json -CommandType Cmdlet
    if ($convertFromJson.Parameters.ContainsKey('DateKind')) {
        return $RawJson | ConvertFrom-Json -Depth 100 -DateKind String
    }

    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 100
    $document = [System.Text.Json.JsonDocument]::Parse($RawJson, $options)
    try {
        return ConvertFrom-JsonElementPreservingStrings -Element $document.RootElement
    }
    finally {
        $document.Dispose()
    }
}

function Invoke-AzAccountShowRaw {
    $azCommand = Get-Command az -ErrorAction Stop
    $azPython = if ($IsWindows -and $azCommand.Source.EndsWith(
            '.cmd',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        Join-Path (Split-Path $azCommand.Source -Parent) '..\python.exe'
    }
    else {
        $null
    }
    $output = if ($null -ne $azPython -and (Test-Path -LiteralPath $azPython)) {
        & $azPython -IBm azure.cli account show --output json --only-show-errors 2>$null
    }
    else {
        & az account show --output json --only-show-errors 2>$null
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to recheck the active Azure account and tenant.'
    }
    $json = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw 'The active Azure account recheck returned no JSON.'
    }
    try { return ConvertFrom-AzJsonPreservingStrings -RawJson $json }
    catch { throw 'The active Azure account recheck returned malformed JSON.' }
}

function Assert-ActiveAzureAccountBoundary {
    $activeAccount = Invoke-AzAccountShowRaw
    if ([string]$activeAccount.id -cne $ExpectedSubscriptionId -or
        [string]$activeAccount.tenantId -cne $ExpectedTenantId -or
        [string]$activeAccount.state -cne 'Enabled' -or
        $activeAccount.isDefault -isnot [bool] -or
        $activeAccount.isDefault -ne $true) {
        throw 'The active Azure CLI subscription or tenant left the exact expected enabled default-account boundary.'
    }
    return $activeAccount
}

function Test-AzArgumentsTargetAzureResource {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if ($Arguments.Count -eq 0 -or $Arguments[0] -in @('account', 'ad')) { return $false }
    if ($Arguments[0] -ne 'rest') { return $true }
    $urlIndex = [Array]::IndexOf($Arguments, '--url')
    if ($urlIndex -ge 0 -and $urlIndex + 1 -lt $Arguments.Count) {
        $uri = $null
        if ([Uri]::TryCreate([string]$Arguments[$urlIndex + 1], [UriKind]::Absolute, [ref]$uri) -and
            $uri.Scheme -ceq 'https' -and
            $uri.Host.Equals('graph.microsoft.com', [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Get-SubscriptionPinnedAzArguments {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if (-not (Test-AzArgumentsTargetAzureResource -Arguments $Arguments)) {
        return @($Arguments)
    }
    $subscriptionIndexes = @(0..($Arguments.Count - 1) | Where-Object { $Arguments[$_] -eq '--subscription' })
    if ($subscriptionIndexes.Count -gt 1) {
        throw 'An Azure resource read contained duplicate subscription selectors.'
    }
    if ($subscriptionIndexes.Count -eq 1) {
        $index = $subscriptionIndexes[0]
        if ($index + 1 -ge $Arguments.Count -or [string]$Arguments[$index + 1] -cne $ExpectedSubscriptionId) {
            throw 'An Azure resource read attempted to use a subscription outside ExpectedSubscriptionId.'
        }
        return @($Arguments)
    }
    return @($Arguments + @('--subscription', $ExpectedSubscriptionId))
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    $isAccountShow = $Arguments.Count -ge 2 -and $Arguments[0] -eq 'account' -and $Arguments[1] -eq 'show'
    if (-not $isAccountShow) {
        Assert-ActiveAzureAccountBoundary | Out-Null
    }
    $effectiveArguments = @(Get-SubscriptionPinnedAzArguments -Arguments $Arguments)

    # The Windows Azure CLI entry point is a .cmd wrapper. Invoke its bundled
    # Python module directly so Graph query-string separators remain part of the
    # single --url argument instead of being interpreted by cmd.exe.
    $azCommand = Get-Command az -ErrorAction Stop
    $azPython = if ($IsWindows -and $azCommand.Source.EndsWith(
            '.cmd',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        Join-Path (Split-Path $azCommand.Source -Parent) '..\python.exe'
    }
    else {
        $null
    }
    $output = if ($null -ne $azPython -and (Test-Path -LiteralPath $azPython)) {
        & $azPython -IBm azure.cli @effectiveArguments --output json --only-show-errors 2>$null
    }
    else {
        & az @effectiveArguments --output json --only-show-errors 2>$null
    }
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }

    $json = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    try {
        return ConvertFrom-AzJsonPreservingStrings -RawJson $json
    }
    catch {
        throw $FailureMessage
    }
}

function Test-ContainerAppExists {
    param([string]$Name)

    try {
        Invoke-AzJson -Arguments @(
            'containerapp', 'show', '--name', $Name, '--resource-group', $ResourceGroup
        ) -FailureMessage "Unable to inspect Container App '$Name'." | Out-Null
        return $true
    }
    catch {
        Assert-ActiveAzureAccountBoundary | Out-Null
        return $false
    }
}

function Test-KeyVaultExists {
    param([string]$Name)

    try {
        Invoke-AzJson -Arguments @(
            'keyvault', 'show', '--name', $Name, '--resource-group', $ResourceGroup
        ) -FailureMessage "Unable to inspect Key Vault '$Name'." | Out-Null
        return $true
    }
    catch {
        Assert-ActiveAzureAccountBoundary | Out-Null
        return $false
    }
}

function Get-ContainerApp {
    param([string]$Name)

    return Invoke-AzJson -Arguments @(
        'containerapp', 'show',
        '--name', $Name,
        '--resource-group', $ResourceGroup
    ) -FailureMessage "Unable to inspect Container App '$Name'."
}

function Get-ContainerEnvironmentValue {
    param(
        [object]$ContainerApp,
        [string]$Name
    )

    $container = @($ContainerApp.properties.template.containers) | Select-Object -First 1
    $setting = @($container.env | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
    if ($null -eq $setting) {
        return $null
    }

    return [string]$setting.value
}

function Get-ExactPlainContainerEnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][object]$ContainerApp,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $containers = @($ContainerApp.properties.template.containers)
    if ($containers.Count -ne 1) {
        Add-Failure 'The deployed API must contain exactly one container before security-critical settings can be verified.'
        return $null
    }

    $settings = @($containers[0].env | Where-Object {
        [string]::Equals(
            [string]$_.name,
            $Name,
            [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($settings.Count -ne 1) {
        Add-Failure "Deployed API setting '$Name' must appear exactly once."
        return $null
    }

    $setting = $settings[0]
    $valueProperty = $setting.PSObject.Properties['value']
    $secretReference = if ($null -ne $setting.PSObject.Properties['secretRef']) {
        [string]$setting.secretRef
    }
    else {
        ''
    }
    if ($null -eq $valueProperty -or -not [string]::IsNullOrWhiteSpace($secretReference)) {
        Add-Failure "Deployed API setting '$Name' must use one plain value and no secret reference."
        return $null
    }

    return [string]$setting.value
}

function Get-ContainerEnvironmentEntriesWithPrefix {
    param(
        [object]$ContainerApp,
        [string]$Prefix
    )

    $container = @($ContainerApp.properties.template.containers) | Select-Object -First 1
    return @($container.env |
        Where-Object { $_.name.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase) })
}

function Test-DeployedGatewayApiEntraCredentialConfiguration {
    param(
        [Parameter(Mandatory = $true)][object]$ContainerApp,
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$Audience
    )

    if (-not [string]::Equals($Audience, $ClientId, [StringComparison]::Ordinal)) {
        Add-Failure 'The Microsoft identity platform v2 token audience must exactly equal the canonical Gateway API client ID.'
        return
    }

    $containers = @($ContainerApp.properties.template.containers)
    if ($containers.Count -ne 1) {
        Add-Failure 'The deployed API must contain exactly one container before Entra credential configuration can be verified.'
        return
    }
    $entraEntries = @($containers[0].env | Where-Object {
        ([string]$_.name).StartsWith('EntraId__', [StringComparison]::OrdinalIgnoreCase)
    })
    $expectedSettings = [ordered]@{
        'EntraId__TenantId' = $TenantId
        'EntraId__ClientId' = $ClientId
        'EntraId__Audience' = $Audience
        'EntraId__ClientCredentials__0__SourceType' = 'SignedAssertionFromManagedIdentity'
        'EntraId__ClientCredentials__0__TokenExchangeUrl' = $TokenExchangeAudience
    }
    $configurationIsExact = $true
    $duplicateNames = @($entraEntries | Group-Object { ([string]$_.name).ToLowerInvariant() } | Where-Object Count -ne 1)
    if ($duplicateNames.Count -ne 0) {
        Add-Failure 'The deployed API contains duplicate Entra environment-setting names.'
        $configurationIsExact = $false
    }
    $dangerousCredentialEntries = @($entraEntries | Where-Object {
        [string]$_.name -match '(?i)(clientsecret|clientcertificates?|password|certificate)'
    })
    if ($dangerousCredentialEntries.Count -ne 0) {
        Add-Failure 'The deployed API contains a prohibited secret, password, or certificate Entra credential setting.'
        $configurationIsExact = $false
    }
    if ($entraEntries.Count -ne $expectedSettings.Count -or
        @($entraEntries | Where-Object { -not $expectedSettings.Contains([string]$_.name) }).Count -ne 0) {
        Add-Failure 'The deployed API Entra environment surface must contain only the exact tenant, client, audience, and index-0 signed-assertion settings.'
        $configurationIsExact = $false
    }

    foreach ($expectedSetting in $expectedSettings.GetEnumerator()) {
        $matches = @($entraEntries | Where-Object { [string]$_.name -ceq $expectedSetting.Key })
        if ($matches.Count -ne 1) {
            Add-Failure "The deployed API Entra setting '$($expectedSetting.Key)' is missing, duplicated, or uses noncanonical casing."
            $configurationIsExact = $false
            continue
        }
        $entry = $matches[0]
        $secretReference = $entry.PSObject.Properties['secretRef']
        $valueProperty = $entry.PSObject.Properties['value']
        if (($null -ne $secretReference -and
             -not [string]::IsNullOrWhiteSpace([string]$secretReference.Value)) -or
            $null -eq $valueProperty -or
            [string]$valueProperty.Value -cne [string]$expectedSetting.Value) {
            Add-Failure "The deployed API Entra setting '$($expectedSetting.Key)' is secret-backed or does not match its exact reviewed value."
            $configurationIsExact = $false
        }
    }
    if ($configurationIsExact) {
        Write-Pass 'The deployed API uses only the exact managed-identity signed-assertion OBO environment boundary.'
    }
}

function Test-GatewayApiV2TokenApplicationContract {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Applications,
        [Parameter(Mandatory = $true)][string]$ClientId
    )

    $matches = @($Applications | Where-Object {
        [string]::Equals([string]$_.appId, $ClientId, [StringComparison]::Ordinal)
    })
    if ($Applications.Count -ne 1 -or $matches.Count -ne 1) {
        Add-Failure 'The Gateway API client ID must resolve to exactly one canonical Entra application.'
        return
    }
    if ([int]$matches[0].api.requestedAccessTokenVersion -ne 2) {
        Add-Failure 'The Gateway API application must explicitly request v2 access tokens before the bare client ID can be used as its token audience.'
        return
    }

    Write-Pass 'The Gateway API application explicitly requests v2 access tokens.'
}

function Test-DeployedManagerApplicationConfiguration {
    param(
        [object]$ContainerApp,
        [string]$Label,
        [string[]]$ExpectedIds
    )

    $prefix = 'Agent365__ManagerApplicationIds__'
    $entries = @(Get-ContainerEnvironmentEntriesWithPrefix `
        -ContainerApp $ContainerApp `
        -Prefix $prefix)
    $configurationIsValid = $true
    if ($entries.Count -gt 10) {
        Add-Failure "Deployed $Label contains more than ten manager application IDs."
        $configurationIsValid = $false
    }

    $deployedIds = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $expectedName = "$prefix$index"
        $matchingEntries = @($entries | Where-Object {
            [string]::Equals(
                [string]$_.name,
                $expectedName,
                [System.StringComparison]::Ordinal)
        })
        if ($matchingEntries.Count -ne 1) {
            Add-Failure "Deployed $Label manager application settings are not an exact contiguous indexed collection."
            $configurationIsValid = $false
            continue
        }

        $entry = $matchingEntries[0]
        $secretReferenceProperty = $entry.PSObject.Properties['secretRef']
        $valueProperty = $entry.PSObject.Properties['value']
        if (($null -ne $secretReferenceProperty -and
             -not [string]::IsNullOrWhiteSpace([string]$secretReferenceProperty.Value)) -or
            $null -eq $valueProperty -or
            [string]::IsNullOrWhiteSpace([string]$valueProperty.Value)) {
            Add-Failure "Deployed $Label contains an empty or secret-backed manager application ID."
            $configurationIsValid = $false
            continue
        }

        $parsedId = [guid]::Empty
        if (-not [guid]::TryParse([string]$valueProperty.Value, [ref]$parsedId) -or
            $parsedId -eq [guid]::Empty) {
            Add-Failure "Deployed $Label contains an invalid manager application ID."
            $configurationIsValid = $false
            continue
        }
        $deployedIds.Add($parsedId.ToString('D'))
    }

    if (@($deployedIds | Sort-Object -Unique).Count -ne $deployedIds.Count) {
        Add-Failure "Deployed $Label contains duplicate manager application IDs."
        $configurationIsValid = $false
    }
    if (-not $configurationIsValid) {
        return
    }

    $expectedFingerprint = [string]::Join('|', @($ExpectedIds | Sort-Object))
    $deployedFingerprint = [string]::Join('|', @($deployedIds | Sort-Object))
    if (-not [string]::Equals(
        $expectedFingerprint,
        $deployedFingerprint,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Failure "Deployed $Label manager application IDs do not match the independently verified deployment input."
    }
    else {
        Write-Pass "Deployed $Label manager application IDs match the independently verified deployment input."
    }
}

function Test-AppEnvironment {
    param(
        [string]$AppName,
        [string]$TargetEnvironmentId,
        [bool]$Required
    )

    if (-not (Test-ContainerAppExists -Name $AppName)) {
        if ($Required) {
            Add-Failure "Required Container App '$AppName' does not exist."
        }
        else {
            Add-PreflightWarning "Optional Container App '$AppName' is not deployed."
        }
        return $null
    }

    $app = Get-ContainerApp -Name $AppName
    if ($app.properties.environmentId -ne $TargetEnvironmentId) {
        Add-Failure "Container App '$AppName' is not attached to the approved environment '$ContainerAppsEnvironmentName'. Container Apps cannot be treated as topology-ready until an explicitly approved recreation or migration is completed."
    }
    else {
        Write-Pass "Container App '$AppName' uses the approved VNet environment."
    }

    return $app
}

function Get-ServicePrincipalAssignments {
    param([string]$ServicePrincipalObjectId)

    $url = "https://graph.microsoft.com/v1.0/servicePrincipals/$ServicePrincipalObjectId/appRoleAssignments?`$select=resourceId,appRoleId"
    return Invoke-AzJson -Arguments @(
        'rest',
        '--method', 'GET',
        '--url', $url
    ) -FailureMessage 'Unable to read the worker managed identity app-role assignments. A tenant administrator or directory reader must perform this preflight.'
}

function Get-ResourceServicePrincipal {
    param(
        [string]$ApplicationId,
        [string]$DisplayLabel
    )

    return Invoke-AzJson -Arguments @(
        'ad', 'sp', 'show',
        '--id', $ApplicationId
    ) -FailureMessage "Unable to inspect the $DisplayLabel enterprise application."
}

function Test-ApplicationRoles {
    param(
        [object]$Assignments,
        [string]$ResourceApplicationId,
        [string[]]$RequiredRoles,
        [string]$DisplayLabel,
        [string]$PrincipalLabel,
        [bool]$FailWhenMissing
    )

    $resourceServicePrincipal = Get-ResourceServicePrincipal `
        -ApplicationId $ResourceApplicationId `
        -DisplayLabel $DisplayLabel

    $applicationRoles = @($resourceServicePrincipal.appRoles | Where-Object {
        $_.isEnabled -and $_.allowedMemberTypes -contains 'Application'
    })
    $resourceAssignments = @($Assignments.value | Where-Object {
        $_.resourceId -eq $resourceServicePrincipal.id
    })

    foreach ($roleName in $RequiredRoles) {
        $role = $applicationRoles | Where-Object { $_.value -eq $roleName } | Select-Object -First 1
        if ($null -eq $role) {
            Add-Failure "$DisplayLabel does not publish the documented application role '$roleName' in this tenant. Do not substitute a broader or invented role."
            continue
        }

        $assigned = $resourceAssignments | Where-Object { $_.appRoleId -eq $role.id } | Select-Object -First 1
        if ($null -eq $assigned) {
            $message = "$PrincipalLabel is missing $DisplayLabel application role '$roleName'."
            if ($FailWhenMissing) {
                Add-Failure $message
            }
            else {
                Add-PreflightWarning $message
            }
        }
        else {
            Write-Pass "$DisplayLabel application role '$roleName' is assigned."
        }
    }
}

function Test-ProhibitedApplicationRoles {
    param(
        [object]$Assignments,
        [string]$ResourceApplicationId,
        [string[]]$ProhibitedRoles,
        [string]$DisplayLabel,
        [string]$PrincipalLabel,
        [bool]$FailWhenPresent
    )

    $resourceServicePrincipal = Get-ResourceServicePrincipal `
        -ApplicationId $ResourceApplicationId `
        -DisplayLabel $DisplayLabel
    $applicationRoles = @($resourceServicePrincipal.appRoles | Where-Object {
        $_.isEnabled -and $_.allowedMemberTypes -contains 'Application'
    })
    $resourceAssignments = @($Assignments.value | Where-Object {
        $_.resourceId -eq $resourceServicePrincipal.id
    })

    foreach ($roleName in $ProhibitedRoles) {
        $role = $applicationRoles | Where-Object {
            $_.value -eq $roleName
        } | Select-Object -First 1
        if ($null -eq $role) {
            continue
        }

        $assigned = $resourceAssignments | Where-Object {
            $_.appRoleId -eq $role.id
        } | Select-Object -First 1
        if ($null -ne $assigned) {
            $message = "$PrincipalLabel retains prohibited $DisplayLabel application role '$roleName'; workflow v3 Registry completion belongs to the Gateway API delegated OBO boundary."
            if ($FailWhenPresent) {
                Add-Failure $message
            }
            else {
                Add-PreflightWarning $message
            }
        }
        else {
            Write-Pass "$PrincipalLabel does not hold obsolete $DisplayLabel application role '$roleName'."
        }
    }
}

function Test-ApplicationRolesPublished {
    param(
        [string]$ResourceApplicationId,
        [string[]]$RequiredRoles,
        [string]$DisplayLabel
    )

    $resourceServicePrincipal = Get-ResourceServicePrincipal `
        -ApplicationId $ResourceApplicationId `
        -DisplayLabel $DisplayLabel
    $applicationRoles = @($resourceServicePrincipal.appRoles | Where-Object {
        $_.isEnabled -and $_.allowedMemberTypes -contains 'Application'
    })

    foreach ($roleName in $RequiredRoles) {
        $roles = @($applicationRoles | Where-Object { $_.value -eq $roleName })
        if ($roles.Count -ne 1) {
            Add-Failure "$DisplayLabel does not publish one enabled application role named '$roleName' in this tenant."
        }
        else {
            Write-Pass "$DisplayLabel publishes application role '$roleName' for provisioned Agent Identities."
        }
    }
}

function Test-EquivalentOptionalUtcInstant {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Actual,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Expected
    )

    $actualMissing = [string]::IsNullOrWhiteSpace($Actual)
    $expectedMissing = [string]::IsNullOrWhiteSpace($Expected)
    if ($actualMissing -or $expectedMissing) {
        return $actualMissing -and $expectedMissing
    }

    $actualInstant = [datetimeoffset]::MinValue
    $expectedInstant = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($Actual, [ref]$actualInstant) -or
        -not [datetimeoffset]::TryParse($Expected, [ref]$expectedInstant)) {
        return $false
    }

    return $actualInstant.ToUniversalTime().Ticks -eq
        $expectedInstant.ToUniversalTime().Ticks
}

function Test-DeployedDelegatedRegistryConfiguration {
    param(
        [Parameter(Mandatory = $true)][object]$ContainerApp,
        [Parameter(Mandatory = $true)][bool]$ExpectedEnabled,
        [Parameter(Mandatory = $true)][bool]$ExpectedContinuousDevelopmentAccess,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedActionExpiresAtUtc,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedAuthorizedOperationId
    )

    $expectedSettings = [ordered]@{
        'Agent365__DelegatedRegistry__Enabled' = $ExpectedEnabled.ToString().ToLowerInvariant()
        'Agent365__DelegatedRegistry__RequireExactActionBinding' = (-not $ExpectedContinuousDevelopmentAccess).ToString().ToLowerInvariant()
        'Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess' = $ExpectedContinuousDevelopmentAccess.ToString().ToLowerInvariant()
        'Agent365__DelegatedRegistry__Scopes__0' = 'https://graph.microsoft.com/AgentRegistration.ReadWrite.All'
        'Agent365__DelegatedRegistry__Scopes__1' = 'https://graph.microsoft.com/AgentRegistration.Read.All'
        'EntraId__ClientCredentials__0__SourceType' = 'SignedAssertionFromManagedIdentity'
        'EntraId__ClientCredentials__0__TokenExchangeUrl' = $TokenExchangeAudience
    }

    foreach ($setting in $expectedSettings.GetEnumerator()) {
        $actual = Get-ExactPlainContainerEnvironmentValue `
            -ContainerApp $ContainerApp `
            -Name $setting.Key
        if (-not [string]::Equals(
            $actual,
            [string]$setting.Value,
            [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-Failure "Deployed API setting '$($setting.Key)' does not match the reviewed delegated Registry configuration."
        }
        else {
            Write-Pass "Deployed API setting '$($setting.Key)' matches."
        }
    }

    $scopeEntries = @(Get-ContainerEnvironmentEntriesWithPrefix `
        -ContainerApp $ContainerApp `
        -Prefix 'Agent365__DelegatedRegistry__Scopes__')
    if ($scopeEntries.Count -ne 2) {
        Add-Failure 'The deployed API delegated Registry scope collection must contain exactly two indexed entries.'
    }

    $deployedActionExpiresAtUtc = Get-ExactPlainContainerEnvironmentValue `
        -ContainerApp $ContainerApp `
        -Name 'Agent365__DelegatedRegistry__ActionExpiresAtUtc'
    $deployedAuthorizedOperationId = Get-ExactPlainContainerEnvironmentValue `
        -ContainerApp $ContainerApp `
        -Name 'Agent365__DelegatedRegistry__AuthorizedOperationId'
    if (-not (Test-EquivalentOptionalUtcInstant `
            -Actual ([string]$deployedActionExpiresAtUtc) `
            -Expected $ExpectedActionExpiresAtUtc) -or
        -not [string]::Equals(
            [string]$deployedAuthorizedOperationId,
            $ExpectedAuthorizedOperationId,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Failure 'The deployed delegated Registry action expiry or exact operation binding does not match the reviewed state.'
    }
    elseif ($ExpectedContinuousDevelopmentAccess -and -not $ExpectedEnabled) {
        Add-Failure 'Continuous development delegated Registry access requires the delegated Registry feature to be enabled.'
    }
    elseif ($ExpectedContinuousDevelopmentAccess) {
        if (-not [string]::IsNullOrWhiteSpace($ExpectedActionExpiresAtUtc) -or
            -not [string]::IsNullOrWhiteSpace($ExpectedAuthorizedOperationId)) {
            Add-Failure 'Continuous development delegated Registry access must not carry an exact action expiry or operation binding.'
        }
        else {
            Write-Pass 'The delegated Registry action matches the explicit continuous development access contract.'
        }
    }
    elseif ($ExpectedEnabled) {
        $parsedExpiry = [datetimeoffset]::MinValue
        $parsedOperationId = [guid]::Empty
        if ([string]::IsNullOrWhiteSpace($ExpectedActionExpiresAtUtc) -or
            -not $ExpectedActionExpiresAtUtc.EndsWith('Z', [System.StringComparison]::Ordinal) -or
            -not [datetimeoffset]::TryParse($ExpectedActionExpiresAtUtc, [ref]$parsedExpiry) -or
            $parsedExpiry.ToUniversalTime() -le [datetimeoffset]::UtcNow -or
            -not [guid]::TryParse($ExpectedAuthorizedOperationId, [ref]$parsedOperationId) -or
            $parsedOperationId -eq [guid]::Empty) {
            Add-Failure 'An open delegated Registry action requires a future UTC expiry and one exact non-empty operation ID.'
        }
        else {
            Write-Pass 'The delegated Registry action has an independent future expiry and exact operation binding.'
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ExpectedActionExpiresAtUtc) -or
            -not [string]::IsNullOrWhiteSpace($ExpectedAuthorizedOperationId)) {
        Add-Failure 'A closed delegated Registry action must not retain an expiry or operation binding.'
    }
}

function Test-DeployedProvisioningBindings {
    param(
        [Parameter(Mandatory = $true)][object]$ContainerApp,
        [Parameter(Mandatory = $true)][bool]$ExpectedEnabled,
        [Parameter(Mandatory = $true)][bool]$ExpectedContinuousDevelopmentAccess,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedExternalAgentId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedRetryAgentId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedAdmissionExpiresAtUtc
    )

    $requireExactBinding = Get-ExactPlainContainerEnvironmentValue `
        -ContainerApp $ContainerApp `
        -Name 'Provisioning__RequireExactAdmissionBinding'
    $expectedExactBinding = (-not $ExpectedContinuousDevelopmentAccess).ToString().ToLowerInvariant()
    if (-not [string]::Equals(
            [string]$requireExactBinding,
            $expectedExactBinding,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Failure 'The deployed API exact registration/retry admission-binding mode does not match the reviewed contract.'
    }
    else {
        Write-Pass 'The deployed API exact registration/retry admission-binding mode matches.'
    }
    $allowContinuousDevelopment = Get-ExactPlainContainerEnvironmentValue `
        -ContainerApp $ContainerApp `
        -Name 'Provisioning__AllowContinuousDevelopmentAccess'
    if (-not [string]::Equals(
            [string]$allowContinuousDevelopment,
            $ExpectedContinuousDevelopmentAccess.ToString().ToLowerInvariant(),
            [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Failure 'The deployed API continuous development admission mode does not match the reviewed contract.'
    }
    else {
        Write-Pass 'The deployed API continuous development admission mode matches.'
    }

    $deployedExternalAgentId = Get-ExactPlainContainerEnvironmentValue `
        -ContainerApp $ContainerApp `
        -Name 'Provisioning__AuthorizedExternalAgentId'
    $deployedRetryAgentId = Get-ExactPlainContainerEnvironmentValue `
        -ContainerApp $ContainerApp `
        -Name 'Provisioning__AuthorizedRetryAgentId'
    $deployedAdmissionExpiresAtUtc = Get-ExactPlainContainerEnvironmentValue `
        -ContainerApp $ContainerApp `
        -Name 'Provisioning__AdmissionExpiresAtUtc'
    if (-not [string]::Equals(
            [string]$deployedExternalAgentId,
            $ExpectedExternalAgentId,
            [System.StringComparison]::Ordinal) -or
        -not [string]::Equals(
            [string]$deployedRetryAgentId,
            $ExpectedRetryAgentId,
            [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-EquivalentOptionalUtcInstant `
            -Actual ([string]$deployedAdmissionExpiresAtUtc) `
            -Expected $ExpectedAdmissionExpiresAtUtc)) {
        Add-Failure 'The deployed registration/retry expiry or bindings do not match the exact reviewed API admission state.'
    }
    elseif ($ExpectedContinuousDevelopmentAccess -and -not $ExpectedEnabled) {
        Add-Failure 'Continuous development admission requires the API execution gate to be enabled.'
    }
    elseif ($ExpectedContinuousDevelopmentAccess) {
        if (-not [string]::IsNullOrWhiteSpace($ExpectedExternalAgentId) -or
            -not [string]::IsNullOrWhiteSpace($ExpectedRetryAgentId) -or
            -not [string]::IsNullOrWhiteSpace($ExpectedAdmissionExpiresAtUtc)) {
            Add-Failure 'Continuous development admission must not carry exact registration/retry bindings or an admission expiry.'
        }
        else {
            Write-Pass 'The API admission bindings match the explicit continuous development access contract.'
        }
    }
    elseif ($ExpectedEnabled -and
            ([string]::IsNullOrWhiteSpace($ExpectedExternalAgentId) -eq
             [string]::IsNullOrWhiteSpace($ExpectedRetryAgentId))) {
        Add-Failure 'Open API admission requires exactly one external-registration or retry binding.'
    }
    elseif (-not $ExpectedEnabled -and
            (-not [string]::IsNullOrWhiteSpace($ExpectedExternalAgentId) -or
             -not [string]::IsNullOrWhiteSpace($ExpectedRetryAgentId) -or
             -not [string]::IsNullOrWhiteSpace($ExpectedAdmissionExpiresAtUtc))) {
        Add-Failure 'Closed API admission must not retain an expiry or registration/retry bindings.'
    }
    elseif ($ExpectedEnabled) {
        $parsedExpiry = [datetimeoffset]::MinValue
        if ([string]::IsNullOrWhiteSpace($ExpectedAdmissionExpiresAtUtc) -or
            -not $ExpectedAdmissionExpiresAtUtc.EndsWith('Z', [System.StringComparison]::Ordinal) -or
            -not [datetimeoffset]::TryParse(
                $ExpectedAdmissionExpiresAtUtc,
                [ref]$parsedExpiry) -or
            $parsedExpiry.ToUniversalTime() -le [datetimeoffset]::UtcNow) {
            Add-Failure 'Open API admission requires its own future UTC expiry.'
        }
        else {
            Write-Pass 'The API admission expiry and exact registration/retry binding match the reviewed boundary.'
        }
    }
    else {
        Write-Pass 'The API admission bindings match the exact reviewed registration/retry boundary.'
    }
}

function Test-ContinuousDevelopmentAccessInputContract {
    param(
        [Parameter(Mandatory = $true)][bool]$ContinuousDevelopmentAccessExpected,
        [Parameter(Mandatory = $true)][bool]$ExecutionReadyRequired,
        [Parameter(Mandatory = $true)][bool]$ApiAdmissionClosedExpected,
        [Parameter(Mandatory = $true)][bool]$DelegatedRegistryActionOpenExpected,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ProvisioningAuthorizedExternalAgentId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ProvisioningAuthorizedRetryAgentId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ProvisioningAdmissionExpiresAtUtc,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$DelegatedRegistryActionExpiresAtUtc,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$DelegatedRegistryAuthorizedOperationId
    )

    if (-not $ContinuousDevelopmentAccessExpected) {
        return
    }

    $hasExactBoundInput =
        $ApiAdmissionClosedExpected -or
        $DelegatedRegistryActionOpenExpected -or
        -not [string]::IsNullOrWhiteSpace($ProvisioningAuthorizedExternalAgentId) -or
        -not [string]::IsNullOrWhiteSpace($ProvisioningAuthorizedRetryAgentId) -or
        -not [string]::IsNullOrWhiteSpace($ProvisioningAdmissionExpiresAtUtc) -or
        -not [string]::IsNullOrWhiteSpace($DelegatedRegistryActionExpiresAtUtc) -or
        -not [string]::IsNullOrWhiteSpace($DelegatedRegistryAuthorizedOperationId)
    if (-not $ExecutionReadyRequired -or $hasExactBoundInput) {
        Add-Failure 'Continuous development access requires execution-ready development and cannot be combined with exact-bound flags or binding inputs.'
    }
}

function Test-GatewayApiFederatedCredential {
    param(
        [Parameter(Mandatory = $true)][guid]$ApplicationClientId,
        [Parameter(Mandatory = $true)][guid]$ManagedIdentityPrincipalId,
        [Parameter(Mandatory = $true)][guid]$TenantId
    )

    $filter = [uri]::EscapeDataString("appId eq '$($ApplicationClientId.ToString('D'))'")
    $applications = Invoke-AzJson -Arguments @(
        'rest',
        '--method', 'GET',
        '--url', "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId"
    ) -FailureMessage 'Unable to inspect the Gateway API application for its managed-identity federated credential.'
    $applicationRows = @($applications.value)
    if ($applicationRows.Count -ne 1) {
        Add-Failure 'The Gateway API client ID did not resolve to exactly one Entra application.'
        return
    }

    $applicationObjectId = [guid]::Empty
    if (-not [guid]::TryParse([string]$applicationRows[0].id, [ref]$applicationObjectId) -or
        $applicationObjectId -eq [guid]::Empty) {
        Add-Failure 'The Gateway API Entra application object ID is invalid.'
        return
    }

    $credentials = Invoke-AzJson -Arguments @(
        'rest',
        '--method', 'GET',
        '--url', "https://graph.microsoft.com/v1.0/applications/$($applicationObjectId.ToString('D'))/federatedIdentityCredentials?`$select=id,name,issuer,subject,audiences"
    ) -FailureMessage 'Unable to inspect the Gateway API managed-identity federated credential.'

    $expectedIssuer = "https://login.microsoftonline.com/$($TenantId.ToString('D'))/v2.0"
    $subjectMatches = @($credentials.value | Where-Object {
        [string]::Equals(
            [string]$_.subject,
            $ManagedIdentityPrincipalId.ToString('D'),
            [System.StringComparison]::OrdinalIgnoreCase)
    })
    $exactMatches = @($subjectMatches | Where-Object {
        [string]::Equals(
            [string]$_.name,
            $ExpectedGatewayApiFederatedCredentialName,
            [System.StringComparison]::Ordinal) -and
        [string]::Equals(
            [string]$_.issuer,
            $expectedIssuer,
            [System.StringComparison]::OrdinalIgnoreCase) -and
        @($_.audiences).Count -eq 1 -and
        [string]::Equals(
            [string](@($_.audiences)[0]),
            $TokenExchangeAudience,
            [System.StringComparison]::Ordinal)
    })
    if ($subjectMatches.Count -ne 1 -or $exactMatches.Count -ne 1) {
        Add-Failure "The Gateway API application must have exactly one federated credential named '$ExpectedGatewayApiFederatedCredentialName' with the API Container App managed-identity subject, tenant v2 issuer, and sole '$TokenExchangeAudience' audience."
    }
    else {
        Write-Pass 'The Gateway API managed-identity federated credential matches the exact OBO boundary.'
    }
}

function Test-GatewayApiDelegatedRegistryConsent {
    param([Parameter(Mandatory = $true)][guid]$ApplicationClientId)

    $gatewayServicePrincipal = Get-ResourceServicePrincipal `
        -ApplicationId $ApplicationClientId.ToString('D') `
        -DisplayLabel 'Gateway API'
    $graphServicePrincipal = Get-ResourceServicePrincipal `
        -ApplicationId $MicrosoftGraphAppId `
        -DisplayLabel 'Microsoft Graph'
    $filterText = "clientId eq '$([string]$gatewayServicePrincipal.id)' and resourceId eq '$([string]$graphServicePrincipal.id)'"
    $filter = [uri]::EscapeDataString($filterText)
    $grants = Invoke-AzJson -Arguments @(
        'rest',
        '--method', 'GET',
        '--url', "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=$filter&`$select=consentType,scope,clientId,resourceId,principalId"
    ) -FailureMessage 'Unable to inspect tenant-wide delegated Microsoft Graph consent for the Gateway API.'

    $adminGrantedScopes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($grant in @($grants.value | Where-Object {
        [string]::Equals(
            [string]$_.consentType,
            'AllPrincipals',
            [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::IsNullOrWhiteSpace([string]$_.principalId)
    })) {
        foreach ($scope in @(([string]$grant.scope).Split(
            ' ',
            [System.StringSplitOptions]::RemoveEmptyEntries))) {
            $null = $adminGrantedScopes.Add($scope)
        }
    }

    foreach ($scope in $RequiredApiGraphDelegatedRegistryScopes) {
        if (-not $adminGrantedScopes.Contains($scope)) {
            Add-Failure "Gateway API is missing tenant-wide admin consent for delegated Microsoft Graph scope '$scope'."
        }
        else {
            Write-Pass "Gateway API has tenant-wide admin consent for delegated Microsoft Graph scope '$scope'."
        }
    }
}

Write-Host ''
Write-Host 'A365 provisioning deployment preflight (read-only)' -ForegroundColor Cyan
Write-Host "Environment: $Environment | Resource group: $ResourceGroup" -ForegroundColor White
Write-Host ''

$account = Assert-ActiveAzureAccountBoundary
$parsedTenantId = $parsedExpectedTenantId

$parsedGatewayApiClientId = [guid]::Empty
$gatewayApiClientIdIsValid =
    -not [string]::IsNullOrWhiteSpace($ExpectedGatewayApiApplicationClientId) -and
    [guid]::TryParse($ExpectedGatewayApiApplicationClientId, [ref]$parsedGatewayApiClientId) -and
    $parsedGatewayApiClientId -ne [guid]::Empty

[uri]$parsedCredentialVaultUri = $null
$credentialVaultUriIsValid =
    -not [string]::IsNullOrWhiteSpace($ExpectedCredentialKeyVaultUri) -and
    [uri]::TryCreate($ExpectedCredentialKeyVaultUri, [System.UriKind]::Absolute, [ref]$parsedCredentialVaultUri) -and
    $parsedCredentialVaultUri.Scheme -eq [System.Uri]::UriSchemeHttps -and
    $parsedCredentialVaultUri.Host.EndsWith('.vault.azure.net', [System.StringComparison]::OrdinalIgnoreCase)

if (-not $gatewayApiClientIdIsValid -or
    $ExpectedGatewayApiApplicationClientId -cne $parsedGatewayApiClientId.ToString('D')) {
    Add-Failure 'ExpectedGatewayApiApplicationClientId must be one canonical lowercase non-empty GUID.'
}
if (-not $credentialVaultUriIsValid -and -not [string]::IsNullOrWhiteSpace($ExpectedCredentialKeyVaultUri)) {
    Add-Failure 'The expected provisioning credential vault URI is not a valid Azure Key Vault HTTPS URI.'
}

$normalizedManagerApplicationIds = [System.Collections.Generic.List[string]]::new()
$seenManagerApplicationIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
if ($ExpectedManagerApplicationIds.Count -gt 10) {
    Add-Failure 'At most ten Agent 365 manager application IDs may be configured.'
}
foreach ($managerApplicationId in $ExpectedManagerApplicationIds) {
    $parsedManagerApplicationId = [guid]::Empty
    if (-not [guid]::TryParse($managerApplicationId, [ref]$parsedManagerApplicationId) -or
        $parsedManagerApplicationId -eq [guid]::Empty) {
        Add-Failure 'Every Agent 365 manager application ID must be a valid non-empty GUID.'
        continue
    }

    $normalizedManagerApplicationId = $parsedManagerApplicationId.ToString('D')
    if (-not $seenManagerApplicationIds.Add($normalizedManagerApplicationId)) {
        Add-Failure 'Agent 365 manager application IDs must be unique.'
        continue
    }
    $normalizedManagerApplicationIds.Add($normalizedManagerApplicationId)
}

if ($RequireExecutionReady) {
    if (-not $WorkerProcessingEnabled) {
        Add-Failure 'Provisioning execution requires shared worker processing to remain enabled.'
    }
    if ($Environment -ne 'dev') {
        Add-Failure 'Provisioning execution is currently authorized only for development.'
    }
    if ($RegistryProvider -ne 'DirectRegistryPreview') {
        Add-Failure 'Execution requires Agent365__RegistryProvider=DirectRegistryPreview.'
    }
    if (-not $DirectRegistryPreviewEnabled) {
        Add-Failure 'Execution requires Agent365__DirectRegistryPreviewEnabled=true.'
    }
    if (-not $DelegatedRegistryEnabled) {
        Add-Failure 'Execution requires the Gateway API delegated administrator Registry action to be explicitly enabled for the bounded development gate.'
    }
    if (-not $ManagerApplicationsPreflightConfirmed) {
        Add-Failure 'Execution requires independent confirmation of the Agent 365 managerApplications platform prerequisite. Do not invent a first-party application ID.'
    }
    if ($normalizedManagerApplicationIds.Count -eq 0) {
        Add-Failure 'Execution requires at least one independently verified Microsoft first-party manager application ID.'
    }
}
elseif ($RegistryProvider -ne 'Disabled' -or
        $DirectRegistryPreviewEnabled -or
        $DelegatedRegistryEnabled) {
    Add-PreflightWarning 'A preview provider setting is staged while provisioning execution remains disabled.'
}

if ($ExpectApiAdmissionClosed -and -not $RequireExecutionReady) {
    Add-Failure 'ExpectApiAdmissionClosed is valid only with RequireExecutionReady for the worker-first canary staging state.'
}
Test-ContinuousDevelopmentAccessInputContract `
    -ContinuousDevelopmentAccessExpected $ExpectContinuousDevelopmentAccess.IsPresent `
    -ExecutionReadyRequired $RequireExecutionReady.IsPresent `
    -ApiAdmissionClosedExpected $ExpectApiAdmissionClosed.IsPresent `
    -DelegatedRegistryActionOpenExpected $ExpectDelegatedRegistryActionOpen.IsPresent `
    -ProvisioningAuthorizedExternalAgentId $ExpectedProvisioningAuthorizedExternalAgentId `
    -ProvisioningAuthorizedRetryAgentId $ExpectedProvisioningAuthorizedRetryAgentId `
    -ProvisioningAdmissionExpiresAtUtc $ExpectedProvisioningAdmissionExpiresAtUtc `
    -DelegatedRegistryActionExpiresAtUtc $ExpectedDelegatedRegistryActionExpiresAtUtc `
    -DelegatedRegistryAuthorizedOperationId $ExpectedDelegatedRegistryAuthorizedOperationId
if ($ExpectDelegatedRegistryActionOpen -and
    (-not $RequireExecutionReady -or -not $ExpectApiAdmissionClosed)) {
    Add-Failure 'A delegated Registry action window requires execution-ready worker state while registration/retry admission remains closed.'
}

Write-Check "Inspecting approved Container Apps environment '$ContainerAppsEnvironmentName'."
$containerAppsEnvironment = Invoke-AzJson -Arguments @(
    'containerapp', 'env', 'show',
    '--name', $ContainerAppsEnvironmentName,
    '--resource-group', $ResourceGroup
) -FailureMessage "Approved Container Apps environment '$ContainerAppsEnvironmentName' was not found."

$infrastructureSubnetId = [string]$containerAppsEnvironment.properties.vnetConfiguration.infrastructureSubnetId
if ([string]::IsNullOrWhiteSpace($infrastructureSubnetId)) {
    Add-Failure "Container Apps environment '$ContainerAppsEnvironmentName' is not VNet integrated."
}
else {
    Write-Pass 'Approved Container Apps environment has an infrastructure subnet.'
}

$suffix = "$ProjectName-$Environment"
$serviceBusNamespaceName = "sb-$suffix"
$apiAppName = "ca-gateway-api-$Environment"
$workerAppName = if ([string]::IsNullOrWhiteSpace($WorkerContainerAppName)) {
    "ca-gateway-worker-$Environment"
}
else {
    $WorkerContainerAppName
}
$adminUiAppName = "ca-gateway-admin-$Environment"

$serviceBusQueueExists = $false
try {
    Invoke-AzJson -Arguments @(
        'servicebus', 'queue', 'show',
        '--resource-group', $ResourceGroup,
        '--namespace-name', $serviceBusNamespaceName,
        '--name', $ExpectedServiceBusQueueName
    ) -FailureMessage "Unable to inspect Service Bus queue '$ExpectedServiceBusQueueName'." | Out-Null
    $serviceBusQueueExists = $true
}
catch { Assert-ActiveAzureAccountBoundary | Out-Null }
if ($serviceBusQueueExists) {
    Write-Pass "Service Bus queue '$ExpectedServiceBusQueueName' exists."
}
elseif ($AllowMissingWorkloads) {
    Add-PreflightWarning "Service Bus queue '$ExpectedServiceBusQueueName' is not deployed yet."
}
else {
    Add-Failure "Service Bus queue '$ExpectedServiceBusQueueName' does not exist in '$serviceBusNamespaceName'."
}

$apiApp = Test-AppEnvironment `
    -AppName $apiAppName `
    -TargetEnvironmentId $containerAppsEnvironment.id `
    -Required (-not $AllowMissingWorkloads.IsPresent)
$workerApp = Test-AppEnvironment `
    -AppName $workerAppName `
    -TargetEnvironmentId $containerAppsEnvironment.id `
    -Required ($RequireExecutionReady.IsPresent -or -not $AllowMissingWorkloads.IsPresent)
$null = Test-AppEnvironment `
    -AppName $adminUiAppName `
    -TargetEnvironmentId $containerAppsEnvironment.id `
    -Required $false

if ($null -ne $apiApp -and $gatewayApiClientIdIsValid) {
    $gatewayApiClientId = $parsedGatewayApiClientId.ToString('D')
    $gatewayApiFilter = [uri]::EscapeDataString("appId eq '$gatewayApiClientId'")
    $gatewayApiApplications = Invoke-AzJson -Arguments @(
        'rest',
        '--method', 'GET',
        '--url', "https://graph.microsoft.com/v1.0/applications?`$filter=$gatewayApiFilter&`$select=id,appId,api"
    ) -FailureMessage 'Unable to inspect the Gateway API application token-version contract.'
    Test-GatewayApiV2TokenApplicationContract `
        -Applications @($gatewayApiApplications.value) `
        -ClientId $gatewayApiClientId
    Test-DeployedGatewayApiEntraCredentialConfiguration `
        -ContainerApp $apiApp `
        -TenantId $ExpectedTenantId `
        -ClientId $gatewayApiClientId `
        -Audience $gatewayApiClientId
}

if ($RequireDeployedConfigurationMatch -and $null -ne $apiApp) {
    $deployedRegistrationGate = Get-ExactPlainContainerEnvironmentValue `
        -ContainerApp $apiApp `
        -Name 'Provisioning__ExecutionEnabled'
    $expectedRegistrationEnabled =
        $RequireExecutionReady.IsPresent -and
        -not $ExpectApiAdmissionClosed.IsPresent -and
        -not $ExpectDelegatedRegistryActionOpen.IsPresent
    $expectedRegistrationGate = $expectedRegistrationEnabled.ToString().ToLowerInvariant()
    if (-not [string]::Equals(
        $deployedRegistrationGate,
        $expectedRegistrationGate,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Failure 'The deployed API registration gate does not match the expected staged canary state.'
    }
    else {
        if ($ExpectDelegatedRegistryActionOpen) {
            Write-Pass 'Registration/retry admission remains closed during the independently bounded delegated Registry action.'
        }
        elseif ($ExpectApiAdmissionClosed) {
            Write-Pass 'The worker-first staging state keeps API registration admission closed.'
        }
        else {
            Write-Pass 'The deployed API registration gate matches the expected execution state.'
        }
    }

    Test-DeployedDelegatedRegistryConfiguration `
        -ContainerApp $apiApp `
        -ExpectedEnabled ($ExpectDelegatedRegistryActionOpen.IsPresent -or $ExpectContinuousDevelopmentAccess.IsPresent) `
        -ExpectedContinuousDevelopmentAccess $ExpectContinuousDevelopmentAccess.IsPresent `
        -ExpectedActionExpiresAtUtc $ExpectedDelegatedRegistryActionExpiresAtUtc `
        -ExpectedAuthorizedOperationId $ExpectedDelegatedRegistryAuthorizedOperationId
    Test-DeployedProvisioningBindings `
        -ContainerApp $apiApp `
        -ExpectedEnabled $expectedRegistrationEnabled `
        -ExpectedContinuousDevelopmentAccess $ExpectContinuousDevelopmentAccess.IsPresent `
        -ExpectedExternalAgentId $ExpectedProvisioningAuthorizedExternalAgentId `
        -ExpectedRetryAgentId $ExpectedProvisioningAuthorizedRetryAgentId `
        -ExpectedAdmissionExpiresAtUtc $ExpectedProvisioningAdmissionExpiresAtUtc

    $deployedApiQueueName = Get-ContainerEnvironmentValue `
        -ContainerApp $apiApp `
        -Name 'ServiceBus__QueueName'
    if (-not [string]::Equals(
        $deployedApiQueueName,
        $ExpectedServiceBusQueueName,
        [System.StringComparison]::Ordinal)) {
        Add-Failure 'The deployed API does not publish to the intended workflow-v3 Service Bus queue.'
    }
    else {
        Write-Pass 'The deployed API publishes to the intended workflow-v3 Service Bus queue.'
    }

    if ($gatewayApiClientIdIsValid) {
        $deployedApiClientId = Get-ContainerEnvironmentValue `
            -ContainerApp $apiApp `
            -Name 'EntraId__ClientId'
        if (-not [string]::Equals(
            $deployedApiClientId,
            $parsedGatewayApiClientId.ToString('D'),
            [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-Failure 'The deployed API client ID does not match the reviewed Gateway API application.'
        }
        else {
            Write-Pass 'The deployed API client ID matches the reviewed Gateway API application.'
        }
    }

    if ($RequireExecutionReady -or $normalizedManagerApplicationIds.Count -gt 0) {
        Test-DeployedManagerApplicationConfiguration `
            -ContainerApp $apiApp `
            -Label 'API' `
            -ExpectedIds $normalizedManagerApplicationIds.ToArray()
    }
}

if ($null -ne $apiApp) {
    $apiPrincipalId = [string]$apiApp.identity.principalId
    if ([string]::IsNullOrWhiteSpace($apiPrincipalId)) {
        Add-Failure 'Gateway API Container App has no system-assigned managed identity.'
    }
    else {
        Write-Check 'Inspecting the API managed identity blueprint-catalog permission.'
        try {
            $apiAssignments = Get-ServicePrincipalAssignments `
                -ServicePrincipalObjectId $apiPrincipalId
            Test-ApplicationRoles `
                -Assignments $apiAssignments `
                -ResourceApplicationId $MicrosoftGraphAppId `
                -RequiredRoles $RequiredApiGraphApplicationPermissions `
                -DisplayLabel 'Microsoft Graph' `
                -PrincipalLabel 'API managed identity' `
                -FailWhenMissing $RequireExecutionReady.IsPresent
        }
        catch {
            $message = 'The API managed-identity blueprint-catalog permission could not be verified read-only. A tenant administrator or directory reader must run this preflight.'
            if ($RequireExecutionReady) {
                Add-Failure $message
            }
            else {
                Add-PreflightWarning $message
            }
        }

        if ($RequireExecutionReady) {
            $parsedApiPrincipalId = [guid]::Empty
            if (-not $gatewayApiClientIdIsValid) {
                Add-Failure 'Execution requires a reviewed Gateway API application client ID.'
            }
            elseif (-not [guid]::TryParse($apiPrincipalId, [ref]$parsedApiPrincipalId) -or
                $parsedApiPrincipalId -eq [guid]::Empty -or
                $parsedTenantId -eq [guid]::Empty) {
                Add-Failure 'The Gateway API managed-identity subject or active tenant ID is invalid.'
            }
            else {
                Write-Check 'Inspecting the exact Gateway API OBO federated credential and delegated Registry consent.'
                try {
                    Test-GatewayApiFederatedCredential `
                        -ApplicationClientId $parsedGatewayApiClientId `
                        -ManagedIdentityPrincipalId $parsedApiPrincipalId `
                        -TenantId $parsedTenantId
                    Test-GatewayApiDelegatedRegistryConsent `
                        -ApplicationClientId $parsedGatewayApiClientId
                }
                catch {
                    Add-Failure 'The Gateway API OBO federation or delegated Registry consent could not be verified read-only. A tenant administrator or directory reader must run this preflight.'
                }
            }
        }
    }
}

Write-Check 'Inspecting Azure SQL private-network posture.'
$sqlServer = Invoke-AzJson -Arguments @(
    'sql', 'server', 'show',
    '--name', "sql-$suffix",
    '--resource-group', $ResourceGroup
) -FailureMessage "Unable to inspect Azure SQL server 'sql-$suffix'."

if ($sqlServer.publicNetworkAccess -ne 'Disabled') {
    Add-Failure 'Azure SQL public network access is not disabled.'
}
else {
    Write-Pass 'Azure SQL public network access is disabled.'
}

$approvedPrivateEndpoints = @($sqlServer.privateEndpointConnections | Where-Object {
    $_.properties.privateLinkServiceConnectionState.status -eq 'Approved'
})
if ($approvedPrivateEndpoints.Count -lt 1) {
    Add-Failure 'Azure SQL has no approved private endpoint connection.'
}
else {
    Write-Pass 'Azure SQL has an approved private endpoint connection.'
}

$subnetMarker = '/subnets/'
$subnetMarkerIndex = $infrastructureSubnetId.LastIndexOf(
    $subnetMarker,
    [System.StringComparison]::OrdinalIgnoreCase)
$containerAppsVirtualNetworkId = if ($subnetMarkerIndex -gt 0) {
    $infrastructureSubnetId.Substring(0, $subnetMarkerIndex)
}
else {
    $null
}
if ([string]::IsNullOrWhiteSpace($containerAppsVirtualNetworkId)) {
    Add-Failure 'The approved Container Apps environment subnet does not resolve to a virtual network resource ID.'
}
elseif ($approvedPrivateEndpoints.Count -gt 0) {
    Write-Check 'Verifying the SQL private endpoint is reachable from the approved Container Apps virtual network.'
    $reachableSqlPrivateEndpointFound = $false
    foreach ($connection in $approvedPrivateEndpoints) {
        $privateEndpointId = [string]$connection.properties.privateEndpoint.id
        if ([string]::IsNullOrWhiteSpace($privateEndpointId)) {
            continue
        }

        $privateEndpoint = Invoke-AzJson -Arguments @(
            'network', 'private-endpoint', 'show',
            '--ids', $privateEndpointId
        ) -FailureMessage 'Unable to inspect an approved Azure SQL private endpoint.'
        $privateEndpointSubnetId = [string]$privateEndpoint.subnet.id
        $privateEndpointSubnetMarkerIndex = $privateEndpointSubnetId.LastIndexOf(
            $subnetMarker,
            [System.StringComparison]::OrdinalIgnoreCase)
        if ($privateEndpointSubnetMarkerIndex -le 0) {
            continue
        }

        $privateEndpointVirtualNetworkId = $privateEndpointSubnetId.Substring(
            0,
            $privateEndpointSubnetMarkerIndex)
        if ([string]::Equals(
            $privateEndpointVirtualNetworkId,
            $containerAppsVirtualNetworkId,
            [System.StringComparison]::OrdinalIgnoreCase)) {
            $reachableSqlPrivateEndpointFound = $true
            break
        }
    }

    if ($reachableSqlPrivateEndpointFound) {
        Write-Pass 'Azure SQL has an approved private endpoint in the approved Container Apps virtual network.'
    }
    else {
        Add-Failure 'No approved Azure SQL private endpoint is in the virtual network used by the approved Container Apps environment.'
    }

    Write-Check 'Verifying private SQL DNS is linked to the approved Container Apps virtual network.'
    $privateDnsZones = Invoke-AzJson -Arguments @(
        'network', 'private-dns', 'zone', 'list'
    ) -FailureMessage 'Unable to inspect private DNS zones for Azure SQL.'
    $sqlPrivateDnsZones = @($privateDnsZones | Where-Object {
        $_.name -eq 'privatelink.database.windows.net'
    })
    $sqlPrivateDnsLinkFound = $false
    foreach ($privateDnsZone in $sqlPrivateDnsZones) {
        $privateDnsLinks = Invoke-AzJson -Arguments @(
            'network', 'private-dns', 'link', 'vnet', 'list',
            '--resource-group', [string]$privateDnsZone.resourceGroup,
            '--zone-name', [string]$privateDnsZone.name
        ) -FailureMessage 'Unable to inspect Azure SQL private DNS virtual-network links.'
        if (@($privateDnsLinks | Where-Object {
            [string]::Equals(
                [string]$_.virtualNetwork.id,
                $containerAppsVirtualNetworkId,
                [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0) {
            $sqlPrivateDnsLinkFound = $true
            break
        }
    }

    if ($sqlPrivateDnsLinkFound) {
        Write-Pass 'Azure SQL private DNS is linked to the approved Container Apps virtual network.'
    }
    else {
        Add-Failure 'The Azure SQL private DNS zone is not linked to the virtual network used by the approved Container Apps environment.'
    }
}

if ($null -ne $workerApp) {
    if ($RequireDeployedConfigurationMatch) {
        Write-Check 'Verifying deployed worker gates match the intended configuration.'
        $expectedSettings = @{
            'ProvisioningWorker__ProcessingEnabled' = $WorkerProcessingEnabled.ToString().ToLowerInvariant()
            'ProvisioningWorker__ProvisioningExecutionEnabled' = $RequireExecutionReady.IsPresent.ToString().ToLowerInvariant()
            'ProvisioningWorker__QueueName' = $ExpectedServiceBusQueueName
            'ServiceBus__QueueName' = $ExpectedServiceBusQueueName
            'Agent365__RegistryProvider' = $RegistryProvider
            'Agent365__DirectRegistryPreviewEnabled' = $DirectRegistryPreviewEnabled.IsPresent.ToString().ToLowerInvariant()
        }

        if ($gatewayApiClientIdIsValid) {
            $expectedSettings['Agent365__GatewayApiApplicationClientId'] = $parsedGatewayApiClientId.ToString('D')
            $expectedSettings['Agent365__GatewayApiAudience'] = $parsedGatewayApiClientId.ToString('D')
        }
        if ($credentialVaultUriIsValid) {
            $expectedSettings['Agent365__CredentialKeyVaultUri'] = $parsedCredentialVaultUri.AbsoluteUri
        }

        foreach ($settingName in $expectedSettings.Keys) {
            $deployedValue = Get-ContainerEnvironmentValue -ContainerApp $workerApp -Name $settingName
            if (-not [string]::Equals(
                $deployedValue,
                $expectedSettings[$settingName],
                [System.StringComparison]::OrdinalIgnoreCase)) {
                Add-Failure "Deployed worker setting '$settingName' does not match the intended fail-closed configuration."
            }
            else {
                Write-Pass "Deployed worker setting '$settingName' matches."
            }
        }


        if ($RequireExecutionReady -or $normalizedManagerApplicationIds.Count -gt 0) {
            Test-DeployedManagerApplicationConfiguration `
                -ContainerApp $workerApp `
                -Label 'worker' `
                -ExpectedIds $normalizedManagerApplicationIds.ToArray()
        }

        if ($RequireExecutionReady) {
            $deployedMaxReplicas = [int]$workerApp.properties.template.scale.maxReplicas
            $deployedMaxConcurrentCalls = Get-ContainerEnvironmentValue `
                -ContainerApp $workerApp `
                -Name 'ProvisioningWorker__MaxConcurrentCalls'

            if ($deployedMaxReplicas -ne 1 -or $deployedMaxConcurrentCalls -ne '1') {
                Add-Failure 'The provisioning canary is not constrained to one worker replica and one Service Bus callback.'
            }
            else {
                Write-Pass 'The provisioning canary is constrained to one worker replica and one Service Bus callback.'
            }
        }
    }

    $workerPrincipalId = [string]$workerApp.identity.principalId
    if ([string]::IsNullOrWhiteSpace($workerPrincipalId)) {
        Add-Failure 'Worker Container App has no system-assigned managed identity.'
    }
    else {
        if ($RequireDeployedConfigurationMatch) {
            $deployedWorkerPrincipalId = Get-ContainerEnvironmentValue `
                -ContainerApp $workerApp `
                -Name 'Agent365__ProvisioningManagedIdentityPrincipalId'
            if (-not [string]::Equals(
                $deployedWorkerPrincipalId,
                $workerPrincipalId,
                [System.StringComparison]::OrdinalIgnoreCase)) {
                Add-Failure 'The deployed worker has not pinned its own managed-identity principal ID.'
            }
            else {
                Write-Pass 'The deployed worker managed-identity principal ID is pinned.'
            }
        }

        # Workflow v3 uses the Gateway worker managed identity federated to the
        # selected blueprint. A credential vault is legacy compatibility only;
        # inspect it when explicitly supplied, but never gate N:N execution on it.
        if ($credentialVaultUriIsValid) {
            Write-Check 'Inspecting optional legacy provisioning credential-vault access.'
            $credentialKeyVaultName = $parsedCredentialVaultUri.Host.Split('.')[0]
            if (-not (Test-KeyVaultExists -Name $credentialKeyVaultName)) {
                Add-PreflightWarning 'The optional legacy provisioning credential vault does not exist. Workflow v3 does not require it.'
            }
            else {
                $keyVault = Invoke-AzJson -Arguments @(
                    'keyvault', 'show',
                    '--name', $credentialKeyVaultName,
                    '--resource-group', $ResourceGroup
                ) -FailureMessage 'Unable to inspect the optional legacy provisioning credential vault.'

                $keyVaultAssignments = Invoke-AzJson -Arguments @(
                    'role', 'assignment', 'list',
                    '--assignee-object-id', $workerPrincipalId,
                    '--scope', $keyVault.id,
                    '--include-inherited'
                ) -FailureMessage 'Unable to inspect optional legacy provisioning-vault role assignments.'

                $hasLegacyKeyVaultRole = @($keyVaultAssignments | Where-Object {
                    $_.roleDefinitionName -eq $LegacyKeyVaultRole
                }).Count -gt 0

                if ($hasLegacyKeyVaultRole -and $ExpectLegacyWorkerCredentialKeyVaultRole) {
                    Write-Pass "Worker has explicitly requested legacy role '$LegacyKeyVaultRole'."
                }
                elseif ($hasLegacyKeyVaultRole) {
                    $message = "Worker retains legacy role '$LegacyKeyVaultRole', which workflow v3 does not require."
                    if ($RequireExecutionReady) {
                        Add-Failure $message
                    }
                    else {
                        Add-PreflightWarning $message
                    }
                }
                elseif ($ExpectLegacyWorkerCredentialKeyVaultRole) {
                    Add-Failure "Worker is missing explicitly requested legacy role '$LegacyKeyVaultRole'."
                }
                else {
                    Write-Pass 'Worker has no legacy provisioning credential-vault role, as required by workflow v3 least privilege.'
                }
            }
        }

        Write-Check 'Inspecting worker enterprise-application roles without acquiring or printing a token.'
        try {
            $workerAssignments = Get-ServicePrincipalAssignments -ServicePrincipalObjectId $workerPrincipalId
            Test-ApplicationRoles `
                -Assignments $workerAssignments `
                -ResourceApplicationId $MicrosoftGraphAppId `
                -RequiredRoles $RequiredGraphApplicationPermissions `
                -DisplayLabel 'Microsoft Graph' `
                -PrincipalLabel 'Worker managed identity' `
                -FailWhenMissing $RequireExecutionReady.IsPresent

            Test-ProhibitedApplicationRoles `
                -Assignments $workerAssignments `
                -ResourceApplicationId $MicrosoftGraphAppId `
                -ProhibitedRoles $ProhibitedWorkerGraphApplicationPermissions `
                -DisplayLabel 'Microsoft Graph' `
                -PrincipalLabel 'Worker managed identity' `
                -FailWhenPresent $RequireExecutionReady.IsPresent

            Test-ApplicationRolesPublished `
                -ResourceApplicationId $Agent365ObservabilityAppId `
                -RequiredRoles @($RequiredAgent365Role) `
                -DisplayLabel 'Agent 365 observability'
        }
        catch {
            $message = 'Enterprise-application role assignments could not be verified read-only. A tenant administrator or directory reader must run this preflight.'
            if ($RequireExecutionReady -or $WorkerProcessingEnabled) {
                Add-Failure $message
            }
            else {
                Add-PreflightWarning $message
            }
        }
    }
}
elseif ($WorkerProcessingEnabled) {
    Add-Failure 'Worker does not yet exist, so its managed identity and provisioning permissions cannot be verified.'
}

Write-Host ''
Write-Host 'Tenant administrator action (this script does not grant permissions):' -ForegroundColor Cyan
Write-Host '- Grant admin consent for this Microsoft Graph application permission to the API managed identity:' -ForegroundColor White
foreach ($permission in $RequiredApiGraphApplicationPermissions) {
    Write-Host "  - $permission" -ForegroundColor White
}
Write-Host '- Grant tenant-wide admin consent for these delegated Microsoft Graph scopes to the Gateway API application:' -ForegroundColor White
foreach ($scope in $RequiredApiGraphDelegatedRegistryScopes) {
    Write-Host "  - $scope" -ForegroundColor White
}
Write-Host "- Configure exactly one Gateway API application federated credential named '$ExpectedGatewayApiFederatedCredentialName' for the API Container App managed identity, tenant v2 issuer, and sole '$TokenExchangeAudience' audience." -ForegroundColor White
Write-Host '- Grant admin consent for these Microsoft Graph application permissions to the worker enterprise application:' -ForegroundColor White
foreach ($permission in $RequiredGraphApplicationPermissions) {
    Write-Host "  - $permission" -ForegroundColor White
}
Write-Host "- Do not grant '$RequiredAgent365Role' to the worker. Workflow v3 assigns it to each provisioned Agent Identity." -ForegroundColor White
Write-Host '- Independently confirm the DirectRegistryPreview managerApplications platform prerequisite; do not invent a first-party application ID.' -ForegroundColor White
Write-Host '- Workflow v3 does not require worker AgentRegistration application roles, an ExternalAgent app-role assignment, or a generated application-password vault.' -ForegroundColor White
Write-Host '- Do not receive, peek, settle, replay, or purge any retained workflow-v2 or historical provisioning message.' -ForegroundColor White

if ($warnings.Count -gt 0) {
    Write-Host ''
    Write-Host "Warnings: $($warnings.Count)" -ForegroundColor Yellow
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "Preflight failed with $($failures.Count) blocking issue(s). No Azure state was changed." -ForegroundColor Red
    throw 'Provisioning deployment preflight failed. Review the redacted blocking issues above.'
}

Write-Host ''
Write-Host 'Preflight passed. No Azure state was changed.' -ForegroundColor Green
