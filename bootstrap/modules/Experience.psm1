Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:GatewayBootstrapSteps = @(
    'Prerequisites',
    'Azure authentication',
    'Azure provider registration',
    'Azure foundation',
    'Gateway API identity',
    'Immutable workload images',
    'Inert identity deployment',
    'Agent 365 seed blueprint',
    'Workflow v3 Entra configuration',
    'SQL private endpoint',
    'Gateway database',
    'Admin UI identity',
    'Admin UI Key Vault credential',
    'Purview policies',
    'Gateway runtime deployment',
    'Admin UI deployment',
    'Admin UI redirect URIs',
    'Network hardening',
    'End-to-end deployment verification'
)

function ConvertTo-GatewaySafeDisplayText {
    param([AllowNull()][object]$Value, [int]$MaximumLength = 160)

    $text = [string]$Value
    $text = [regex]::Replace($text, '[\x00-\x1f\x7f]', ' ').Trim()
    if ($text.Length -gt $MaximumLength) { return $text.Substring(0, $MaximumLength) + '...' }
    return $text
}

function Write-GatewayExperienceEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('PhaseStarted', 'PhaseCompleted', 'Info', 'Warning', 'Result')][string]$Type,
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][System.Collections.IDictionary]$Data = [ordered]@{},
        [Parameter()][ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text'
    )

    $safeMessage = ConvertTo-GatewaySafeDisplayText -Value $Message -MaximumLength 300
    if ($OutputFormat -eq 'Json') {
        $event = [ordered]@{
            schemaVersion = 1
            timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
            type = $Type
            message = $safeMessage
            data = $Data
        }
        [Console]::Out.WriteLine(($event | ConvertTo-Json -Depth 20 -Compress))
        return
    }

    $color = switch ($Type) {
        'PhaseStarted' { 'Cyan' }
        'PhaseCompleted' { 'Green' }
        'Warning' { 'Yellow' }
        'Result' { 'Green' }
        default { 'Gray' }
    }
    Write-Host $safeMessage -ForegroundColor $color
}

function Write-GatewayResult {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter()][ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text'
    )

    if ($OutputFormat -eq 'Json') {
        [Console]::Out.WriteLine(($Value | ConvertTo-Json -Depth 30 -Compress))
    }
    else {
        return $Value
    }
}

function Format-GatewayCompletionMoment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][DateTimeOffset]$Moment)

    # "When did this finish" is answered in the operator's own wall clock with the
    # offset spelled out, because a bare local time in a log is ambiguous and a
    # bare UTC time makes the operator do arithmetic before they can trust it.
    $local = $Moment.ToLocalTime()
    $offset = $local.Offset
    $sign = if ($offset.Ticks -lt 0) { '-' } else { '+' }
    return '{0} (UTC{1}{2})' -f $local.ToString('yyyy-MM-dd HH:mm:ss'), $sign, $offset.Duration().ToString('hh\:mm')
}

function Write-GatewayCompletionSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Headline,
        [Parameter(Mandatory)][string]$Banner,
        [Parameter(Mandatory)][DateTimeOffset]$CompletedAt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Data,
        [Parameter()][System.Collections.IDictionary]$Facts = [ordered]@{},
        [Parameter()][System.Collections.IDictionary]$Endpoints = [ordered]@{},
        [Parameter()][string[]]$NextSteps = @(),
        [Parameter()][ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text'
    )

    # The completion moment is stamped into the event payload here so the console
    # block and the Setup wizard can never disagree about when the run finished.
    if (-not $Data.Contains('completedAtUtc')) {
        $Data['completedAtUtc'] = $CompletedAt.ToUniversalTime().ToString('o')
    }

    if ($OutputFormat -eq 'Json') {
        Write-GatewayExperienceEvent -Type Result -Message $Headline -Data $Data -OutputFormat Json
        return
    }

    # Write-GatewayExperienceEvent collapses every message into one bounded line,
    # which is correct for streamed progress and wrong for a closing summary. The
    # block is rendered directly instead, with each line still sanitized.
    $emit = {
        param([string]$Line, [string]$LineColor = 'Gray')
        Write-Host (ConvertTo-GatewaySafeDisplayText -Value $Line -MaximumLength 200) -ForegroundColor $LineColor
    }
    $rule = '=' * 74

    $allFacts = [ordered]@{ 'Finished' = Format-GatewayCompletionMoment -Moment $CompletedAt }
    foreach ($key in $Facts.Keys) { $allFacts[$key] = $Facts[$key] }
    $labelWidth = 2
    foreach ($key in @($allFacts.Keys) + @($Endpoints.Keys)) {
        if ([string]$key -and ([string]$key).Length -gt $labelWidth) { $labelWidth = ([string]$key).Length }
    }

    Write-Host ''
    & $emit $rule 'Green'
    & $emit "  $Banner" 'Green'
    & $emit $rule 'Green'
    Write-Host ''
    & $emit "  $Headline" 'Green'
    Write-Host ''
    foreach ($key in $allFacts.Keys) {
        $value = [string]$allFacts[$key]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        & $emit ("  {0}  {1}" -f ([string]$key).PadRight($labelWidth), $value)
    }
    if ($Endpoints.Count -gt 0) {
        Write-Host ''
        & $emit '  Endpoints' 'Cyan'
        foreach ($key in $Endpoints.Keys) {
            $value = [string]$Endpoints[$key]
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            & $emit ("    {0}  {1}" -f ([string]$key).PadRight($labelWidth), $value)
        }
    }
    if ($NextSteps.Count -gt 0) {
        Write-Host ''
        & $emit '  Next steps' 'Cyan'
        for ($index = 0; $index -lt $NextSteps.Count; $index++) {
            & $emit ("    {0}. {1}" -f ($index + 1), $NextSteps[$index])
        }
    }
    Write-Host ''
    & $emit $rule 'Green'
    Write-Host ''
}

function Get-GatewayBootstrapStepNames {
    return @($script:GatewayBootstrapSteps)
}

function Read-GatewayYesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $false)

    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ($answer -match '^(?i:y|yes)$') { return $true }
        if ($answer -match '^(?i:n|no)$') { return $false }
        Write-Host 'Enter y or n.' -ForegroundColor Yellow
    }
}

function Read-GatewayChoice {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][object[]]$Choices,
        [int]$DefaultIndex = 0
    )

    if ($Choices.Count -eq 0) { throw 'At least one choice is required.' }
    if ($DefaultIndex -lt -1 -or $DefaultIndex -ge $Choices.Count) {
        throw 'The choice default index is outside the available choices.'
    }
    $hasDefault = $DefaultIndex -ge 0
    for ($index = 0; $index -lt $Choices.Count; $index++) {
        $marker = if ($hasDefault -and $index -eq $DefaultIndex) { ' (recommended)' } else { '' }
        Write-Host "  $($index + 1). $(ConvertTo-GatewaySafeDisplayText $Choices[$index].label)$marker"
        if (-not [string]::IsNullOrWhiteSpace([string]$Choices[$index].description)) {
            Write-Host "     $(ConvertTo-GatewaySafeDisplayText $Choices[$index].description)" -ForegroundColor DarkGray
        }
    }
    while ($true) {
        $readPrompt = if ($hasDefault) { "$Prompt [$($DefaultIndex + 1)]" } else { $Prompt }
        $answer = (Read-Host $readPrompt).Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) {
            if ($hasDefault) { return $Choices[$DefaultIndex] }
            Write-Host "Enter a number from 1 to $($Choices.Count)." -ForegroundColor Yellow
            continue
        }
        $selected = 0
        if ([int]::TryParse($answer, [ref]$selected) -and $selected -ge 1 -and $selected -le $Choices.Count) {
            return $Choices[$selected - 1]
        }
        Write-Host "Enter a number from 1 to $($Choices.Count)." -ForegroundColor Yellow
    }
}

function Read-GatewayText {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string]$Default = '',
        [Parameter()][string]$Pattern = '.+',
        [Parameter()][string]$ValidationMessage = 'Enter a valid value.'
    )

    while ($true) {
        $label = if ([string]::IsNullOrWhiteSpace($Default)) { $Prompt } else { "$Prompt [$Default]" }
        $answer = (Read-Host $label).Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        if ($answer -match $Pattern -and $answer -notmatch '[\x00-\x1f\x7f]') { return $answer }
        Write-Host $ValidationMessage -ForegroundColor Yellow
    }
}

function ConvertTo-GatewayReviewedManagerApplicationIds {
    param([Parameter(Mandatory)][string]$Value)

    $parts = @($Value.Split(
        [char[]]@(',', ';', ' ', "`t"),
        [StringSplitOptions]::RemoveEmptyEntries -bor [StringSplitOptions]::TrimEntries))
    if ($parts.Count -eq 0 -or $parts.Count -gt 10) {
        throw 'Enter between one and ten reviewed manager application IDs.'
    }
    $normalized = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($part in $parts) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($part, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
            throw 'Each reviewed manager application ID must be a non-empty GUID.'
        }
        $id = $parsed.ToString('D')
        if (-not $seen.Add($id)) { throw 'Reviewed manager application IDs must be unique.' }
        $normalized.Add($id)
    }
    return @($normalized | Sort-Object)
}

function Get-GatewayBootstrapClientIpv4 {
    [CmdletBinding()]
    param()

    # Retained only as accepted-plan schema metadata. The supported private
    # Container Apps Job path never opens SQL public access or a firewall rule.
    return '0.0.0.0'
}

function Invoke-GatewayAzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    try {
        $raw = Invoke-BootstrapCommand `
            -FilePath 'az' `
            -ArgumentList (@($Arguments) + @('--output', 'json', '--only-show-errors')) `
            -CaptureStdoutOnly
    }
    catch {
        throw 'Azure CLI request failed. Run gateway doctor, refresh the Azure sign-in, and try again.'
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try {
        return $raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch {
        throw 'Azure CLI returned malformed JSON. Provider output was suppressed.'
    }
}

function Get-GatewayAzureSubscriptions {
    $accounts = Invoke-GatewayAzJson -Arguments @(
        'account', 'list', '--all',
        '--query', "[?state=='Enabled'].{name:name,id:id,tenantId:tenantId,isDefault:isDefault}"
    )
    return @($accounts | Sort-Object @{ Expression = { -not [bool]$_.isDefault } }, @{ Expression = { [string]$_.name } })
}

function Test-GatewayAzureCliProviderValidationVersion {
    [CmdletBinding()]
    param([AllowNull()][object]$VersionValue)

    if ($VersionValue -isnot [string] -or
        $VersionValue -cnotmatch '\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z') {
        return $false
    }
    $parsedVersion = $null
    if (-not [version]::TryParse($VersionValue, [ref]$parsedVersion)) { return $false }
    return $parsedVersion -ge [version]'2.76.0'
}

function Assert-GatewayAzureCliProviderValidationSupport {
    [CmdletBinding()]
    param()

    $azureCliVersion = Get-GatewayAzureCliVersion
    if (-not (Test-GatewayAzureCliProviderValidationVersion -VersionValue $azureCliVersion)) {
        throw 'Plan requires Azure CLI 2.76.0 or later for Provider validation. Upgrade Azure CLI, then retry.'
    }
    return $azureCliVersion
}

function Test-GatewayRawObjectProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ref]$Value
    )

    $Value.Value = $null
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return $false }
        $Value.Value = $Object[$Name]
    }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $false }
        $Value.Value = $property.Value
    }
    return $true
}

function Test-GatewayExactObjectShape {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string[]]$PropertyNames
    )

    if ($null -eq $Object) { return $false }
    $actualNames = [Collections.Generic.List[string]]::new()
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ($key -isnot [string]) { return $false }
            $actualNames.Add($key)
        }
    }
    elseif ($Object.GetType() -eq [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Object.PSObject.Properties) {
            $actualNames.Add([string]$property.Name)
        }
    }
    else {
        return $false
    }

    if ($actualNames.Count -ne $PropertyNames.Count) { return $false }
    $actualSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($actualName in $actualNames) {
        if (-not $actualSet.Add($actualName)) { return $false }
    }
    foreach ($propertyName in $PropertyNames) {
        if (-not $actualSet.Contains($propertyName)) { return $false }
    }
    return $true
}

function Test-GatewayCanonicalNonEmptyGuidString {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][ref]$CanonicalValue
    )

    $CanonicalValue.Value = ''
    if ($Value -isnot [string]) { return $false }
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($Value, 'D', [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        return $false
    }
    $canonical = $parsed.ToString('D')
    if ($Value -cne $canonical) { return $false }
    $CanonicalValue.Value = $canonical
    return $true
}

function Get-GatewaySelectedTenantGraphMember {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $selectionFailure = 'Azure CLI did not prove the exact selected subscription and tenant. Purview was not opened.'
    $selectedSubscription = [guid]::Empty
    $selectedTenant = [guid]::Empty
    if (-not [guid]::TryParse($SubscriptionId, [ref]$selectedSubscription) -or
        $selectedSubscription -eq [guid]::Empty -or
        -not [guid]::TryParse($TenantId, [ref]$selectedTenant) -or
        $selectedTenant -eq [guid]::Empty) {
        throw $selectionFailure
    }
    $canonicalSubscriptionId = $selectedSubscription.ToString('D')
    $canonicalTenantId = $selectedTenant.ToString('D')

    $account = Invoke-GatewayAzJson -Arguments @(
        'account', 'show',
        '--subscription', $canonicalSubscriptionId,
        '--query', '{id:id,tenantId:tenantId,state:state}'
    )
    if (-not (Test-GatewayExactObjectShape -Object $account -PropertyNames @('id', 'tenantId', 'state'))) {
        throw $selectionFailure
    }
    $accountSubscriptionValue = $null
    $accountTenantValue = $null
    $accountStateValue = $null
    if (-not (Test-GatewayRawObjectProperty -Object $account -Name 'id' -Value ([ref]$accountSubscriptionValue)) -or
        -not (Test-GatewayRawObjectProperty -Object $account -Name 'tenantId' -Value ([ref]$accountTenantValue)) -or
        -not (Test-GatewayRawObjectProperty -Object $account -Name 'state' -Value ([ref]$accountStateValue))) {
        throw $selectionFailure
    }
    $accountSubscriptionId = ''
    $accountTenantId = ''
    if (-not (Test-GatewayCanonicalNonEmptyGuidString -Value $accountSubscriptionValue -CanonicalValue ([ref]$accountSubscriptionId)) -or
        -not (Test-GatewayCanonicalNonEmptyGuidString -Value $accountTenantValue -CanonicalValue ([ref]$accountTenantId)) -or
        $accountSubscriptionId -cne $canonicalSubscriptionId -or
        $accountTenantId -cne $canonicalTenantId -or
        $accountStateValue -isnot [string] -or
        $accountStateValue -cne 'Enabled') {
        throw $selectionFailure
    }

    $graphFailure = 'Microsoft Graph returned an unexpected /me identity response for the selected tenant. Purview was not opened.'
    $graphUser = Invoke-GatewayAzJson -Arguments @(
        'rest', '--method', 'GET',
        '--url', 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName,userType',
        '--resource', 'https://graph.microsoft.com/',
        '--subscription', $canonicalSubscriptionId,
        '--query', '{id:id,userPrincipalName:userPrincipalName,userType:userType}'
    )
    if (-not (Test-GatewayExactObjectShape -Object $graphUser -PropertyNames @('id', 'userPrincipalName', 'userType'))) {
        throw $graphFailure
    }
    $graphUserIdValue = $null
    $userPrincipalNameValue = $null
    $userTypeValue = $null
    if (-not (Test-GatewayRawObjectProperty -Object $graphUser -Name 'id' -Value ([ref]$graphUserIdValue)) -or
        -not (Test-GatewayRawObjectProperty -Object $graphUser -Name 'userPrincipalName' -Value ([ref]$userPrincipalNameValue)) -or
        -not (Test-GatewayRawObjectProperty -Object $graphUser -Name 'userType' -Value ([ref]$userTypeValue))) {
        throw $graphFailure
    }
    $canonicalGraphUserId = ''
    if (-not (Test-GatewayCanonicalNonEmptyGuidString -Value $graphUserIdValue -CanonicalValue ([ref]$canonicalGraphUserId)) -or
        $userPrincipalNameValue -isnot [string] -or
        $userPrincipalNameValue.Length -lt 1 -or
        $userPrincipalNameValue.Length -gt 254 -or
        $userPrincipalNameValue -cne $userPrincipalNameValue.Trim() -or
        $userPrincipalNameValue -match '[\p{Cc}\p{Cf}]' -or
        $userPrincipalNameValue -cnotmatch '\A[^@\s]+@[^@\s]+\.[^@\s]+\z') {
        throw $graphFailure
    }
    if ($userTypeValue -isnot [string] -or $userTypeValue -cne 'Member') {
        throw 'Microsoft Graph did not report the signed-in user as userType Member in the selected tenant. Sign in with an authorized Member account and retry; Purview was not opened.'
    }

    return [pscustomobject][ordered]@{
        tenantId = $canonicalTenantId
        id = $canonicalGraphUserId
        userPrincipalName = $userPrincipalNameValue
        userType = $userTypeValue
    }
}

function Test-GatewayPurviewPolicyAuthoringPlatform {
    [CmdletBinding()]
    param()

    return [bool]$IsWindows
}

function Connect-GatewayPurviewSelectedTenantMember {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId
    )

    if (-not (Test-GatewayPurviewPolicyAuthoringPlatform)) {
        throw 'Purview sensitive-information-type inventory and policy authoring require a Windows workstation because Microsoft currently does not make Connect-IPPSSession available in PowerShell 7 on macOS or Linux. Run Purview selection and bootstrap from Windows, or leave Purview disabled; core Gateway bootstrap remains available on macOS and Linux.'
    }

    $graphUser = Get-GatewaySelectedTenantGraphMember `
        -SubscriptionId $SubscriptionId `
        -TenantId $TenantId
    $connectionId = Connect-BootstrapPurview `
        -TenantId ([string]$graphUser.tenantId) `
        -UserPrincipalName ([string]$graphUser.userPrincipalName)
    return [pscustomobject][ordered]@{
        connectionId = [string]$connectionId
        userId = [string]$graphUser.id
        userPrincipalName = [string]$graphUser.userPrincipalName
        userType = [string]$graphUser.userType
    }
}

function Get-GatewayAzureLocationsNextLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NextLink,
        [Parameter(Mandatory)][string]$CanonicalSubscriptionId
    )

    $paginationFailure = 'Azure CLI returned unsafe or excessive subscription region pagination. No region was selected.'
    if ([string]::IsNullOrWhiteSpace($NextLink) -or
        $NextLink.Length -gt 4096 -or
        $NextLink -cne $NextLink.Trim()) {
        throw $paginationFailure
    }
    $nextUri = $null
    if (-not [uri]::TryCreate($NextLink, [UriKind]::Absolute, [ref]$nextUri) -or
        $nextUri.GetLeftPart([UriPartial]::Authority) -cne 'https://management.azure.com' -or
        -not [string]::IsNullOrEmpty($nextUri.UserInfo) -or
        -not [string]::IsNullOrEmpty($nextUri.Fragment) -or
        $nextUri.AbsolutePath -cne "/subscriptions/$CanonicalSubscriptionId/locations") {
        throw $paginationFailure
    }

    $query = $nextUri.Query
    if ([string]::IsNullOrWhiteSpace($query) -or $query[0] -cne '?') {
        throw $paginationFailure
    }
    $queryParts = @($query.Substring(1).Split([char]'&', [StringSplitOptions]::RemoveEmptyEntries))
    if ($queryParts.Count -lt 2 -or $queryParts.Count -gt 8) { throw $paginationFailure }
    $apiVersionCount = 0
    foreach ($queryPart in $queryParts) {
        $separator = $queryPart.IndexOf('=', [StringComparison]::Ordinal)
        if ($separator -le 0 -or $separator -eq ($queryPart.Length - 1)) { throw $paginationFailure }
        $key = $queryPart.Substring(0, $separator)
        $value = $queryPart.Substring($separator + 1)
        if ($key -cnotmatch '\A[A-Za-z0-9$_.-]{1,64}\z' -or
            $value.Length -gt 2048 -or
            $value -match '[\x00-\x1f\x7f]') {
            throw $paginationFailure
        }
        if ($key.Equals('api-version', [StringComparison]::OrdinalIgnoreCase)) {
            if ($key -cne 'api-version' -or $value -cne '2022-12-01') { throw $paginationFailure }
            $apiVersionCount++
        }
    }
    if ($apiVersionCount -ne 1) { throw $paginationFailure }
    return $nextUri.AbsoluteUri
}

function Get-GatewayAzureLocations {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId)

    Assert-GuidValue -Value $SubscriptionId -Label 'Azure subscription ID'
    $canonicalSubscriptionId = ([guid]$SubscriptionId).ToString('D')
    $locationsUrl = "https://management.azure.com/subscriptions/$canonicalSubscriptionId/locations?api-version=2022-12-01"
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $locations = [Collections.Generic.List[object]]::new()
    $seenPages = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $totalRawLocations = 0
    $pageNumber = 0
    $nextUrl = $locationsUrl
    while (-not [string]::IsNullOrWhiteSpace($nextUrl)) {
        $pageNumber++
        if ($pageNumber -gt 8 -or -not $seenPages.Add($nextUrl)) {
            throw 'Azure CLI returned unsafe or excessive subscription region pagination. No region was selected.'
        }
        $envelope = Invoke-GatewayAzJson -Arguments @(
            'rest', '--method', 'GET', '--url', $nextUrl,
            '--subscription', $canonicalSubscriptionId
        )
        $isEnvelope = $envelope -is [System.Collections.IDictionary] -or
            ($null -ne $envelope -and $envelope.GetType() -eq [System.Management.Automation.PSCustomObject])
        if (-not $isEnvelope) {
            throw 'Azure CLI returned an empty or invalid subscription region inventory. No region was selected.'
        }

        $rawPageLocations = $null
        if (-not (Test-GatewayRawObjectProperty `
                -Object $envelope -Name 'value' -Value ([ref]$rawPageLocations)) -or
            $rawPageLocations -isnot [System.Array]) {
            throw 'Azure CLI returned an empty or invalid subscription region inventory. No region was selected.'
        }
        $pageLocations = @($rawPageLocations)
        $totalRawLocations += $pageLocations.Count
        if ($pageLocations.Count -eq 0 -or $totalRawLocations -gt 256) {
            throw 'Azure CLI returned an empty or invalid subscription region inventory. No region was selected.'
        }

        foreach ($rawLocation in $pageLocations) {
            $isObject = $rawLocation -is [System.Collections.IDictionary] -or
                ($null -ne $rawLocation -and $rawLocation.GetType() -eq [System.Management.Automation.PSCustomObject])
            if (-not $isObject) {
                throw 'Azure CLI returned an empty or invalid subscription region inventory. No region was selected.'
            }
            $metadata = $null
            $metadataExists = Test-GatewayRawObjectProperty `
                -Object $rawLocation -Name 'metadata' -Value ([ref]$metadata)
            $isMetadataObject = $metadata -is [System.Collections.IDictionary] -or
                ($null -ne $metadata -and $metadata.GetType() -eq [System.Management.Automation.PSCustomObject])
            if (-not $metadataExists -or -not $isMetadataObject) {
                throw 'Azure CLI returned an empty or invalid subscription region inventory. No region was selected.'
            }
            $regionType = $null
            $name = $null
            $displayName = $null
            $requiredFieldsExist =
                (Test-GatewayRawObjectProperty -Object $metadata -Name 'regionType' -Value ([ref]$regionType)) -and
                (Test-GatewayRawObjectProperty -Object $rawLocation -Name 'name' -Value ([ref]$name)) -and
                (Test-GatewayRawObjectProperty -Object $rawLocation -Name 'displayName' -Value ([ref]$displayName))
            if (-not $requiredFieldsExist -or
                $regionType -isnot [string] -or
                $name -isnot [string] -or
                $displayName -isnot [string]) {
                throw 'Azure CLI returned an empty or invalid subscription region inventory. No region was selected.'
            }
            if ($regionType -cnotin @('Physical', 'Logical')) {
                throw 'Azure CLI returned an empty or invalid subscription region inventory. No region was selected.'
            }
            if ($name -cnotmatch '\A[a-z0-9]+\z' -or
                [string]::IsNullOrWhiteSpace($displayName) -or
                $displayName -cne $displayName.Trim() -or
                $displayName.Length -gt 160 -or
                $displayName -match '[\x00-\x1f\x7f]') {
                throw 'Azure CLI returned an empty or invalid subscription region inventory. No region was selected.'
            }
            if ($regionType -ceq 'Logical') { continue }
            if (-not $names.Add($name)) {
                throw 'Azure CLI returned an empty or invalid subscription region inventory. No region was selected.'
            }
            $locations.Add([pscustomobject]@{
                name = $name
                displayName = $displayName
            })
        }

        $rawNextLink = $null
        $nextLinkExists = Test-GatewayRawObjectProperty `
            -Object $envelope -Name 'nextLink' -Value ([ref]$rawNextLink)
        if (-not $nextLinkExists -or $null -eq $rawNextLink) {
            $nextUrl = ''
        }
        elseif ($rawNextLink -isnot [string]) {
            throw 'Azure CLI returned unsafe or excessive subscription region pagination. No region was selected.'
        }
        else {
            $nextUrl = Get-GatewayAzureLocationsNextLink `
                -NextLink $rawNextLink `
                -CanonicalSubscriptionId $canonicalSubscriptionId
        }
    }
    if ($locations.Count -eq 0) {
        throw 'Azure CLI returned an empty or invalid subscription region inventory. No region was selected.'
    }
    return @($locations | Sort-Object displayName, name)
}

function Read-GatewayAzureLocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter()][string]$ConfiguredLocation = ''
    )

    $locations = @(Get-GatewayAzureLocations -SubscriptionId $SubscriptionId)
    $choices = @($locations | ForEach-Object {
        [ordered]@{
            label = "$($_.displayName) ($($_.name))"
            description = "Azure canonical name: $($_.name)"
            value = [string]$_.name
        }
    })
    $defaultIndex = -1
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredLocation)) {
        for ($index = 0; $index -lt $locations.Count; $index++) {
            if ([string]$locations[$index].name -ceq $ConfiguredLocation) {
                $defaultIndex = $index
                break
            }
        }
    }
    $choice = Read-GatewayChoice `
        -Prompt 'Choose an Azure region' `
        -Choices $choices `
        -DefaultIndex $defaultIndex
    $selectedName = [string]$choice.value
    if (@($locations | Where-Object { [string]$_.name -ceq $selectedName }).Count -ne 1) {
        throw 'The selected Azure region did not match the current subscription inventory.'
    }
    return $selectedName
}

function New-GatewayBootstrapConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$NonInteractive,
        [switch]$Force
    )

    if ($NonInteractive) {
        throw 'Interactive configuration is disabled. Supply a reviewed config file for non-interactive operation.'
    }
    if ([Console]::IsInputRedirected) {
        throw 'The guided configuration wizard requires an interactive terminal.'
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required for guided tenant/subscription discovery. Run gateway doctor for installation guidance.'
    }

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $existingConfiguration = $null
    $configurationExists = Test-Path -LiteralPath $resolvedPath
    if ($configurationExists) {
        try { $existingConfiguration = Read-BootstrapConfig -Path $resolvedPath } catch { }
    }
    if ($configurationExists -and -not $Force) {
        if (-not (Read-GatewayYesNo -Prompt "Configuration already exists at '$resolvedPath'. Replace it" -Default $false)) {
            throw 'Configuration was not changed.'
        }
    }

    Write-Host ''
    Write-Host 'A365 Custom Gateway setup' -ForegroundColor Cyan
    Write-Host 'This wizard stores only non-secret deployment choices. Azure tokens and credentials are never written to configuration.'

    $subscriptions = @()
    try { $subscriptions = @(Get-GatewayAzureSubscriptions) } catch { }
    if ($subscriptions.Count -eq 0) {
        if (-not (Read-GatewayYesNo -Prompt 'No usable Azure CLI session was found. Sign in now' -Default $true)) {
            throw 'Azure sign-in is required to discover a subscription.'
        }
        & az login --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Azure CLI sign-in did not complete.' }
        $subscriptions = @(Get-GatewayAzureSubscriptions)
    }
    if ($subscriptions.Count -eq 0) { throw 'The signed-in account has no enabled Azure subscriptions.' }

    $subscriptionChoices = @($subscriptions | ForEach-Object {
        [ordered]@{
            label = "$(ConvertTo-GatewaySafeDisplayText $_.name) ($(ConvertTo-GatewaySafeDisplayText -Value $_.id -MaximumLength 8))"
            description = "Tenant $($_.tenantId)"
            value = $_
        }
    })
    $subscriptionChoice = Read-GatewayChoice -Prompt 'Choose an Azure subscription' -Choices $subscriptionChoices -DefaultIndex 0
    $subscription = $subscriptionChoice.value

    $profiles = @(
        [ordered]@{
            label = 'Quick development'
            description = 'Deploys the complete cloud-backed development foundation; Registry preview remains a separate explicit choice.'
            environment = 'dev'
        },
        [ordered]@{
            label = 'Staging foundation'
            description = 'Deploys staging with Registry creation closed.'
            environment = 'staging'
        },
        [ordered]@{
            label = 'Production-safe foundation'
            description = 'Deploys the production foundation while the preview Registry dependency remains closed.'
            environment = 'prod'
        }
    )
    $profile = Read-GatewayChoice -Prompt 'Choose a deployment profile' -Choices $profiles -DefaultIndex 0
    $environment = [string]$profile.environment
    $randomProject = 'gw' + [guid]::NewGuid().ToString('N').Substring(0, 5)
    $projectName = Read-GatewayText -Prompt 'Short project name (used for tenant/global resource isolation)' -Default $randomProject -Pattern '^[a-z][a-z0-9]{1,7}$' -ValidationMessage 'Use 2-8 lowercase letters/digits, starting with a letter.'
    $configuredLocation = ''
    if ($null -ne $existingConfiguration -and
        [string]$existingConfiguration.subscriptionId -ceq [string]$subscription.id -and
        [string]$existingConfiguration.tenantId -ceq [string]$subscription.tenantId) {
        $configuredLocation = [string]$existingConfiguration.location
    }
    $location = Read-GatewayAzureLocation `
        -SubscriptionId ([string]$subscription.id) `
        -ConfiguredLocation $configuredLocation
    $resourceGroupName = Read-GatewayText -Prompt 'Resource group name' -Default "rg-$projectName-$environment" -Pattern '^[A-Za-z0-9._()\-]{1,90}$' -ValidationMessage 'Enter a valid Azure resource group name (1-90 characters).'

    $suggestedEmail = ''
    try {
        $candidate = (& az ad signed-in-user show --query userPrincipalName --output tsv --only-show-errors 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $candidate -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $suggestedEmail = $candidate }
    }
    catch { }
    $alertEmail = Read-GatewayText -Prompt 'Operational alert email' -Default $suggestedEmail -Pattern '^[^@\s]+@[^@\s]+\.[^@\s]+$' -ValidationMessage 'Enter a valid email address.'

    $registryPreview = $false
    if ($environment -eq 'dev') {
        Write-Host ''
        Write-Host 'Agent 365 Registry creation uses a preview, Global-cloud-only dependency that Microsoft does not support for production.' -ForegroundColor Yellow
        $registryPreview = Read-GatewayYesNo -Prompt 'Explicitly enable continuous Registry preview for this development deployment' -Default $false
    }

    Write-Host ''
    Write-Host 'Agent 365 managerApplications grant first-party manager authority and must be independently reviewed for this tenant/provider version.' -ForegroundColor Yellow
    Write-Host 'Do not copy IDs from blueprint discovery alone. Follow the "Reviewed manager applications" section of docs/operations/entra-setup-runbook.md.' -ForegroundColor DarkGray
    $reviewedManagerApplicationIds = @()
    while ($reviewedManagerApplicationIds.Count -eq 0) {
        $managerInput = Read-GatewayText -Prompt 'Reviewed manager application ID(s), comma-separated' -Pattern '^[0-9A-Fa-f,; \-]+$' -ValidationMessage 'Enter one to ten comma-separated GUIDs.'
        try { $reviewedManagerApplicationIds = @(ConvertTo-GatewayReviewedManagerApplicationIds -Value $managerInput) }
        catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }

    $promptShieldEnabled = Read-GatewayYesNo -Prompt 'Provision Azure AI Content Safety Prompt Shields' -Default $false
    $promptShieldSku = 'F0'
    if ($promptShieldEnabled) {
        $skuChoice = Read-GatewayChoice -Prompt 'Choose the Content Safety SKU' -Choices @(
            [ordered]@{ label = 'F0'; description = 'Requests the free tier, subject to regional availability and subscription limits.'; value = 'F0' },
            [ordered]@{ label = 'S0'; description = 'Uses the paid standard tier; Azure charges apply.'; value = 'S0' }
        ) -DefaultIndex 0
        $promptShieldSku = [string]$skuChoice.value
        if ($promptShieldSku -eq 'S0' -and -not (Read-GatewayYesNo -Prompt 'Acknowledge that S0 is a paid Azure resource' -Default $false)) {
            throw 'Paid Prompt Shields SKU was not acknowledged.'
        }
    }

    $purviewEnabled = Read-GatewayYesNo -Prompt 'Author Purview Know Your Data and DLP policies during bootstrap (runtime remains disabled)' -Default $false
    $sensitiveInformationTypeId = ''
    $sensitiveInformationType = ''
    if ($purviewEnabled) {
        Write-Host 'Purview requires tenant licensing and authoring roles. Microsoft Graph /me must report the signed-in user as userType Member in the selected tenant.' -ForegroundColor Yellow
        $purviewConnectionId = ''
        try {
            $purviewSession = Connect-GatewayPurviewSelectedTenantMember `
                -SubscriptionId ([string]$subscription.id) `
                -TenantId ([string]$subscription.tenantId)
            $purviewConnectionId = [string]$purviewSession.connectionId
            $tenantTypes = @(Get-BootstrapPurviewSensitiveInformationTypes)
            $typeChoices = @($tenantTypes | ForEach-Object {
                $publisher = ConvertTo-GatewaySafeDisplayText -Value $_.publisher -MaximumLength 120
                if ([string]::IsNullOrWhiteSpace($publisher)) { $publisher = '(not reported)' }
                [ordered]@{
                    label = "$(ConvertTo-GatewaySafeDisplayText -Value $_.name -MaximumLength 255) — $([string]$_.id)"
                    description = "Publisher: $publisher"
                    value = $_
                }
            })
            $selectedType = (Read-GatewayChoice `
                -Prompt 'Choose a sensitive information type from this tenant' `
                -Choices $typeChoices `
                -DefaultIndex -1).value
            $resolvedType = Resolve-BootstrapPurviewSensitiveInformationType `
                -Id ([string]$selectedType.id) `
                -Name ([string]$selectedType.name)
            $sensitiveInformationTypeId = [string]$resolvedType.id
            $sensitiveInformationType = [string]$resolvedType.name
        }
        finally {
            if (-not [string]::IsNullOrWhiteSpace($purviewConnectionId)) {
                Disconnect-BootstrapPurview -ConnectionId $purviewConnectionId
            }
        }
    }

    $root = Get-RepositoryRoot
    $schemaPath = Join-Path $root 'bootstrap/config.schema.json'
    $configurationDirectory = Split-Path -Parent $resolvedPath
    $relativeSchema = [IO.Path]::GetRelativePath($configurationDirectory, $schemaPath).Replace([IO.Path]::DirectorySeparatorChar, '/')
    if (-not $relativeSchema.StartsWith('.')) { $relativeSchema = "./$relativeSchema" }
    $configuration = [ordered]@{
        '$schema' = $relativeSchema
        subscriptionId = [string]$subscription.id
        tenantId = [string]$subscription.tenantId
        environment = $environment
        location = $location
        projectName = $projectName
        resourceGroupName = $resourceGroupName
        alertEmail = $alertEmail
        sql = [ordered]@{ skuName = 'Basic'; skuTier = 'Basic' }
        agent365 = [ordered]@{
            seedBlueprintName = "A365 Gateway $projectName $environment"
            allowDevelopmentRegistryPreview = $registryPreview
            reviewedManagerApplicationIds = @($reviewedManagerApplicationIds)
        }
        promptShield = [ordered]@{ enabled = $promptShieldEnabled; skuName = $promptShieldSku }
        purview = [ordered]@{
            enabled = $purviewEnabled
            collectionPolicyName = "A365 Gateway $projectName AI collection"
            dlpPolicyName = "A365 Gateway $projectName inline DLP"
            dlpRuleName = "A365 Gateway $projectName inline DLP rule"
            sensitiveInformationTypeId = $sensitiveInformationTypeId
            sensitiveInformationType = $sensitiveInformationType
            policyProvisioningEnabled = $false
            policyProvisioningOrganization = ''
            policyProvisioningApplicationId = ''
            policyProvisioningCertificateSecretUri = ''
        }
    }

    Write-Host ''
    Write-Host "Deployment: $projectName-$environment" -ForegroundColor Cyan
    Write-Host "Subscription: $($subscriptionChoice.label)"
    Write-Host "Region:       $location"
    Write-Host "Resource group: $resourceGroupName"
    Write-Host "Registry preview: $registryPreview"
    Write-Host "Reviewed Agent 365 manager IDs: $($reviewedManagerApplicationIds -join ', ')"
    Write-Host "Prompt Shields:   $promptShieldEnabled ($promptShieldSku)"
    Write-Host "Purview:           $purviewEnabled"
    if (-not (Read-GatewayYesNo -Prompt 'Write this non-secret configuration' -Default $true)) {
        throw 'Configuration was not written.'
    }

    New-Item -ItemType Directory -Path $configurationDirectory -Force | Out-Null
    $temporaryPath = Join-Path $configurationDirectory ".$([IO.Path]::GetFileName($resolvedPath)).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $configuration | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporaryPath -Encoding utf8NoBOM
        $null = Read-BootstrapConfig -Path $temporaryPath
        Move-Item -LiteralPath $temporaryPath -Destination $resolvedPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }

    return [ordered]@{
        configPath = $resolvedPath
        deploymentId = "$projectName-$environment"
        subscriptionId = [string]$subscription.id
        tenantId = [string]$subscription.tenantId
        profile = [string]$profile.label
        registryPreviewEnabled = $registryPreview
        promptShieldEnabled = $promptShieldEnabled
        purviewEnabled = $purviewEnabled
    }
}

function New-GatewayDoctorCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Warning', 'Fail', 'NotRequired', 'NotChecked')][string]$Status,
        [Parameter()][string]$Value = '',
        [Parameter()][string]$Remediation = ''
    )
    return [ordered]@{ name = $Name; status = $Status; value = $Value; remediation = $Remediation }
}

function Get-GatewayCommandVersion {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Arguments)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { return $null }
    try {
        $value = Invoke-BootstrapCommand `
            -FilePath $Name `
            -ArgumentList $Arguments `
            -CaptureStdoutOnly
        return ConvertTo-GatewaySafeDisplayText -Value (($value -split "`r?`n")[0]) -MaximumLength 120
    }
    catch { return $null }
}

function Get-GatewayAzureCliVersion {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $null }
    try {
        $raw = Invoke-BootstrapCommand `
            -FilePath 'az' `
            -ArgumentList @('version', '--output', 'json', '--only-show-errors') `
            -CaptureStdoutOnly
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $metadata = $raw | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        $property = $metadata.PSObject.Properties['azure-cli']
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $null }
        return ConvertTo-GatewaySafeDisplayText -Value ([string]$property.Value) -MaximumLength 120
    }
    catch { return $null }
}

function Get-GatewayDoctorReport {
    [CmdletBinding()]
    param([Parameter()][string]$ConfigPath = '')

    $checks = [Collections.Generic.List[object]]::new()
    $checks.Add((New-GatewayDoctorCheck -Name 'PowerShell' -Status $(if ($PSVersionTable.PSVersion.Major -ge 7) { 'Pass' } else { 'Fail' }) -Value $PSVersionTable.PSVersion.ToString() -Remediation 'Install PowerShell 7 or later.'))

    $gitVersion = Get-GatewayCommandVersion -Name 'git' -Arguments @('--version')
    $checks.Add((New-GatewayDoctorCheck -Name 'Git' -Status $(if ($gitVersion) { 'Pass' } else { 'Fail' }) -Value $gitVersion -Remediation 'Install Git from https://git-scm.com/downloads.'))

    $azVersion = Get-GatewayAzureCliVersion
    $azSupportsProviderValidation = Test-GatewayAzureCliProviderValidationVersion -VersionValue $azVersion
    $azRemediation = if ($azVersion) {
        'Upgrade Azure CLI to version 2.76.0 or later from https://aka.ms/azure-cli.'
    }
    else {
        'Install Azure CLI version 2.76.0 or later from https://aka.ms/azure-cli.'
    }
    $checks.Add((New-GatewayDoctorCheck -Name 'Azure CLI' -Status $(if ($azSupportsProviderValidation) { 'Pass' } else { 'Fail' }) -Value $azVersion -Remediation $azRemediation))

    $bicepVersion = if ($azVersion) { Get-GatewayCommandVersion -Name 'az' -Arguments @('bicep', 'version') } else { $null }
    $checks.Add((New-GatewayDoctorCheck -Name 'Bicep' -Status $(if ($bicepVersion) { 'Pass' } else { 'Fail' }) -Value $bicepVersion -Remediation 'Run az bicep install after installing Azure CLI.'))

    $dotnetVersion = Get-GatewayCommandVersion -Name 'dotnet' -Arguments @('--version')
    $dotnetStatus = if ($dotnetVersion -match '^10\.') { 'Pass' } elseif ($dotnetVersion) { 'Fail' } else { 'Fail' }
    $checks.Add((New-GatewayDoctorCheck -Name '.NET SDK' -Status $dotnetStatus -Value $dotnetVersion -Remediation 'Install the .NET 10 SDK from https://dotnet.microsoft.com/download/dotnet/10.0.'))

    $checks.Add((New-GatewayDoctorCheck -Name 'Agent ID blueprint provider' -Status 'Pass' -Value 'Microsoft Graph v1.0 direct create; no local CLI or blueprint credential'))

    $config = $null
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath)) {
        try {
            $config = Read-BootstrapConfig -Path $ConfigPath
            $checks.Add((New-GatewayDoctorCheck -Name 'Configuration' -Status 'Pass' -Value 'Valid reviewed non-secret configuration'))
        }
        catch {
            $checks.Add((New-GatewayDoctorCheck -Name 'Configuration' -Status 'Fail' -Value 'Configuration validation failed' -Remediation 'Run gateway init or correct the configuration validation errors.'))
        }
    }
    else {
        $checks.Add((New-GatewayDoctorCheck -Name 'Configuration' -Status 'Warning' -Remediation 'Run gateway init to create a non-secret configuration.'))
    }

    $requiresPurview = $config -and $config.purview.enabled -eq $true
    $exchangeInstalled = [bool](Get-Module -ListAvailable -Name ExchangeOnlineManagement)
    $exchangeStatus = if (-not $requiresPurview) { 'NotRequired' } elseif ($exchangeInstalled) { 'Pass' } else { 'Fail' }
    $checks.Add((New-GatewayDoctorCheck -Name 'Exchange Online module' -Status $exchangeStatus -Value $(if ($exchangeInstalled) { 'Installed' } else { '' }) -Remediation 'Install-Module ExchangeOnlineManagement -Scope CurrentUser.'))

    $azureSessionStatus = 'Warning'
    $azureSessionValue = 'Not signed in or unavailable'
    $accountMatchesConfig = $false
    $account = $null
    if ($azSupportsProviderValidation) {
        try {
            $account = Invoke-GatewayAzJson -Arguments @('account', 'show', '--query', '{id:id,tenantId:tenantId}')
            if ($account) {
                $matchesConfig = -not $config -or ([string]$account.id -eq [string]$config.subscriptionId -and [string]$account.tenantId -eq [string]$config.tenantId)
                $accountMatchesConfig = [bool]$matchesConfig
                $azureSessionStatus = if ($matchesConfig) { 'Pass' } else { 'Warning' }
                $azureSessionValue = if ($matchesConfig) { 'Signed in; configured tenant/subscription available' } else { 'Signed in; active tenant/subscription differs from configuration' }
            }
        }
        catch { }
    }
    $checks.Add((New-GatewayDoctorCheck -Name 'Azure session' -Status $azureSessionStatus -Value $azureSessionValue -Remediation 'Run az login, then select or regenerate the intended configuration.'))

    $roleStatus = 'NotChecked'
    $roleValue = 'NotChecked'
    $roleRemediation = 'Sign in with subscription Owner, or Contributor plus User Access Administrator/Role Based Access Control Administrator.'
    if ($config -and $accountMatchesConfig) {
        try {
            $signedInUser = Invoke-GatewayAzJson -Arguments @('ad', 'signed-in-user', 'show', '--query', '{id:id}')
            $scope = "/subscriptions/$($config.subscriptionId)"
            $roles = @(Invoke-GatewayAzJson -Arguments @(
                'role', 'assignment', 'list', '--assignee-object-id', [string]$signedInUser.id,
                '--include-inherited', '--include-groups', '--scope', $scope,
                '--fill-principal-name', 'false',
                '--query', '[].{role:roleDefinitionName,scope:scope}'
            ))
            $roleNames = @($roles | ForEach-Object { [string]$_.role } | Sort-Object -Unique)
            $hasOwner = $roleNames -contains 'Owner'
            $hasContributor = $roleNames -contains 'Contributor'
            $hasAssignmentAdministrator =
                $roleNames -contains 'User Access Administrator' -or
                $roleNames -contains 'Role Based Access Control Administrator'
            if ($hasOwner -or ($hasContributor -and $hasAssignmentAdministrator)) {
                $roleStatus = 'Pass'
                $roleValue = 'Both ARM resource deployment and role-assignment authority were detected at/inherited to subscription scope'
            }
            elseif ($hasContributor) {
                $roleStatus = 'Fail'
                $roleValue = 'Contributor detected without a recognized role-assignment administrator role'
            }
            elseif ($hasAssignmentAdministrator) {
                $roleStatus = 'Fail'
                $roleValue = 'Role-assignment administration was detected without Owner or Contributor resource-deployment authority'
            }
            else {
                $roleValue = 'No recognized built-in role-assignment authority; custom-role permissions were not expanded'
            }
        }
        catch { $roleValue = 'Authorization read was denied or ambiguous' }
    }
    $checks.Add((New-GatewayDoctorCheck -Name 'Azure deployment/RBAC authority' -Status $roleStatus -Value $roleValue -Remediation $roleRemediation))

    $providerStatus = 'NotChecked'
    $providerValue = 'NotChecked'
    if ($config -and $accountMatchesConfig) {
        try {
            $requiredProviders = @('Microsoft.AlertsManagement', 'Microsoft.App', 'Microsoft.ContainerRegistry', 'Microsoft.EventGrid', 'Microsoft.Insights', 'Microsoft.KeyVault', 'Microsoft.ManagedIdentity', 'Microsoft.Network', 'Microsoft.OperationalInsights', 'Microsoft.ServiceBus', 'Microsoft.Sql', 'Microsoft.Storage')
            $unregistered = [Collections.Generic.List[string]]::new()
            foreach ($provider in $requiredProviders) {
                $providerRecord = Invoke-GatewayAzJson -Arguments @('provider', 'show', '--namespace', $provider, '--query', '{state:registrationState}')
                if ([string]$providerRecord.state -ne 'Registered') { $unregistered.Add($provider) }
            }
            if ($unregistered.Count -eq 0) { $providerStatus = 'Pass'; $providerValue = 'All required providers are registered' }
            else { $providerStatus = 'Warning'; $providerValue = "$($unregistered.Count) provider(s) will require registration during Apply" }
        }
        catch { $providerValue = 'Provider registration read was denied or ambiguous' }
    }
    $checks.Add((New-GatewayDoctorCheck -Name 'Azure resource providers' -Status $providerStatus -Value $providerValue -Remediation 'An authorized Apply registers and read-backs each required provider; resolve policy denials first.'))

    $regionStatus = 'NotChecked'
    $regionValue = 'NotChecked'
    if ($config -and $accountMatchesConfig) {
        try {
            $regionCount = @(
                Get-GatewayAzureLocations -SubscriptionId ([string]$config.subscriptionId) |
                    Where-Object { [string]$_.name -ceq [string]$config.location }
            ).Count
            if ($regionCount -eq 1) { $regionStatus = 'Pass'; $regionValue = "Azure region '$($config.location)' is listed for the subscription" }
            else { $regionStatus = 'Fail'; $regionValue = "Azure region '$($config.location)' was not listed for the subscription" }
        }
        catch { $regionValue = 'Region inventory read was denied or ambiguous' }
    }
    $checks.Add((New-GatewayDoctorCheck -Name 'Azure region visibility' -Status $regionStatus -Value $regionValue -Remediation 'Reopen Setup and choose a physical Azure region returned for the configured subscription, then generate a fresh plan.'))

    $sqlRegionStatus = 'NotChecked'
    $sqlRegionValue = 'NotChecked'
    if ($config -and $accountMatchesConfig -and $regionStatus -eq 'Pass') {
        try {
            Assert-GatewaySqlRegionalAvailability -Config $config | Out-Null
            $sqlRegionStatus = 'Pass'
            $sqlRegionValue = "The configured Azure SQL SKU is available in '$($config.location)' for this subscription"
        }
        catch {
            $sqlRegionStatus = 'Fail'
            $sqlRegionValue = 'Exact Azure SQL regional availability was not confirmed'
        }
    }
    elseif ($regionStatus -eq 'Fail') {
        $sqlRegionStatus = 'Fail'
        $sqlRegionValue = 'Azure SQL availability cannot pass because the configured region is unavailable'
    }
    $checks.Add((New-GatewayDoctorCheck -Name 'Azure SQL regional availability' -Status $sqlRegionStatus -Value $sqlRegionValue -Remediation 'Choose a region where the configured Azure SQL SKU is available for this subscription, then generate a fresh plan.'))
    $checks.Add((New-GatewayDoctorCheck -Name 'Generated global-name availability' -Status 'NotChecked' -Value 'NotChecked' -Remediation 'Run an authenticated Plan/What-If. Apply still verifies every created/adopted resource by exact readback.'))
    $checks.Add((New-GatewayDoctorCheck -Name 'Agent 365 tenant eligibility/licensing' -Status 'NotChecked' -Value 'NotChecked' -Remediation 'An authorized tenant administrator must complete the Agent 365 requirements/blueprint checks; bootstrap fails closed if unavailable.'))

    $failures = @($checks | Where-Object status -eq 'Fail').Count
    $warnings = @($checks | Where-Object status -eq 'Warning').Count
    $notChecked = @($checks | Where-Object status -eq 'NotChecked').Count
    $planRequirementNames = @(
        'PowerShell', 'Azure CLI', 'Bicep', 'Configuration', 'Azure session',
        'Azure region visibility', 'Azure SQL regional availability'
    )
    $planBlockingChecks = @($checks | Where-Object {
        $_.name -in $planRequirementNames -and $_.status -notin @('Pass', 'NotRequired')
    })
    return [ordered]@{
        schemaVersion = 1
        checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        ready = $failures -eq 0 -and $notChecked -eq 0
        readyForPlan = $planBlockingChecks.Count -eq 0
        readyForApply = $failures -eq 0 -and $notChecked -eq 0
        failures = $failures
        warnings = $warnings
        notChecked = $notChecked
        checks = @($checks)
    }
}

function Show-GatewayDoctorReport {
    param([Parameter(Mandatory)]$Report, [ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text')
    if ($OutputFormat -eq 'Json') { Write-GatewayResult -Value $Report -OutputFormat Json; return }

    Write-Host ''
    Write-Host 'Gateway doctor' -ForegroundColor Cyan
    foreach ($check in $Report.checks) {
        $symbol = switch ([string]$check.status) { 'Pass' { '[ok]' }; 'NotRequired' { '[--]' }; 'NotChecked' { '[??]' }; 'Warning' { '[!!]' }; default { '[xx]' } }
        $color = switch ([string]$check.status) { 'Pass' { 'Green' }; 'NotRequired' { 'DarkGray' }; 'NotChecked' { 'Yellow' }; 'Warning' { 'Yellow' }; default { 'Red' } }
        $value = if ([string]::IsNullOrWhiteSpace([string]$check.value)) { '' } else { ": $($check.value)" }
        Write-Host "$symbol $($check.name)$value" -ForegroundColor $color
        if ([string]$check.status -in @('Fail', 'Warning', 'NotChecked') -and -not [string]::IsNullOrWhiteSpace([string]$check.remediation)) {
            Write-Host "     $($check.remediation)" -ForegroundColor DarkGray
        }
    }
    if ($Report.readyForPlan) { Write-Host 'Configuration, required tooling, and the matching Azure session are ready for authenticated Plan.' -ForegroundColor Green }
    else { Write-Host 'Resolve the required tooling, configuration, and Azure session checks before Plan.' -ForegroundColor Red }
    if ($Report.readyForApply) { Write-Host 'All Doctor checks needed for Apply are confirmed.' -ForegroundColor Green }
    else { Write-Host 'Apply readiness is not claimed while failed or NotChecked items remain.' -ForegroundColor Yellow }
}

function Get-GatewayPlanDescriptor {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$BootstrapClientIpv4,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    Assert-BootstrapIpv4Value -Value $BootstrapClientIpv4 -Label 'Legacy SQL bootstrap IPv4 metadata'
    Assert-GuidValue -Value $DeploymentOwnershipId -Label 'Plan deployment ownership ID'
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Plan source fingerprint'
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    $plannedBlueprintDisplayName = Get-Agent365SeedBlueprintDisplayName `
        -Config $Config `
        -DeploymentOwnershipId $canonicalOwnershipId `
        -SourceFingerprint $SourceFingerprint
    $blueprintPlanDisposition = Get-GatewaySeedBlueprintPlanDisposition -State $State

    $registryPreview = [string]$Config.environment -eq 'dev' -and $Config.agent365.allowDevelopmentRegistryPreview -eq $true
    $reviewedManagerIds = @($Config.agent365.reviewedManagerApplicationIds | ForEach-Object { ([guid][string]$_).ToString('D') } | Sort-Object -Unique)
    $azureResources = [Collections.Generic.List[string]]::new()
    foreach ($resource in @(
        'Resource group and deployment metadata',
        'Log Analytics workspace',
        'Virtual network and dedicated subnets',
        'Azure Container Registry and digest-pinned image builds',
        'Azure Container Apps environment, Gateway API, workflow-v3 worker, Admin UI, and dormant database-bootstrap job',
        'Azure SQL logical server/database and private endpoint',
        'Service Bus namespace and isolated workflow-v3 queue',
        'Storage, Key Vaults, private endpoints, and private DNS zones',
        'Managed identities, role assignments, diagnostics, and alerts'
    )) { $azureResources.Add($resource) }
    if ($Config.promptShield.enabled -eq $true) { $azureResources.Add('Azure AI Content Safety account with local authentication disabled') }

    $imperative = [Collections.Generic.List[object]]::new()
    $imperative.Add([ordered]@{ system = 'Local workstation'; operation = 'Verify Git, Azure CLI, .NET SDK 10, and Bicep; install supported missing prerequisites when explicitly enabled'; mutation = $true })
    $imperative.Add([ordered]@{ system = 'Local workstation'; operation = 'Install the optional Exchange Online module before Apply when Purview policy authoring is enabled'; mutation = $true })
    $imperative.Add([ordered]@{ system = 'Azure'; operation = 'Register required resource providers and read back Registered state'; mutation = $true })
    $imperative.Add([ordered]@{ system = 'Azure Container Registry'; operation = 'Build API, worker, Admin UI, and database-migrator images and resolve immutable digests'; mutation = $true })
    $imperative.Add([ordered]@{ system = 'Azure network controls'; operation = 'Enforce disabled public access on the project-scoped Key Vaults and verify the hardened state'; mutation = $true })
    $imperative.Add([ordered]@{ system = 'Microsoft Entra'; operation = "Create or safely adopt project-scoped API/Admin applications for $($Config.projectName)-$($Config.environment), service principals, reviewed roles, delegated consent, and one managed-identity OBO federation; fail before mutation on any extra FIC or app-role assignment and perform no permission deletion"; mutation = $true })
    $blueprintOperation = switch ([string]$blueprintPlanDisposition.mode) {
        'FreshCreate' { "Issue at most one direct v1.0 POST for typed seed blueprint '$plannedBlueprintDisplayName'; never create a blueprint credential or adopt a preexisting object; bind the authenticated administrator as the sole owner and sponsor" }
        'GetOnlyReconciliation' { "Perform GET-only exact reconciliation of the previously started typed seed blueprint '$plannedBlueprintDisplayName'; never issue another POST" }
        'ReadOnlyRevalidation' { "Read-only revalidate the completed typed seed blueprint '$plannedBlueprintDisplayName'; never issue another POST" }
        default { throw 'The Agent ID blueprint plan disposition is unsupported.' }
    }
    $imperative.Add([ordered]@{ system = 'Agent 365 / Microsoft Graph'; operation = $blueprintOperation; mutation = [bool]$blueprintPlanDisposition.providerMutationAuthorized })
    $imperative.Add([ordered]@{ system = 'Agent 365 authority input'; operation = "Require the seed blueprint managerApplications to exactly equal this reviewed configuration set: $($reviewedManagerIds -join ', ')"; mutation = $false })
    $imperative.Add([ordered]@{ system = 'Azure SQL'; operation = 'Initialize only an empty database and create the two exact runtime principals through one VNet-private, retry-disabled Container Apps Job; temporarily assign that job identity as the singular Entra administrator, restore the original administrator exactly, keep public access Disabled, and prove zero firewall rules'; mutation = $true })
    $imperative.Add([ordered]@{ system = 'Key Vault'; operation = 'Transfer the one-time Admin UI application credential directly to Key Vault without rendering it'; mutation = $true })
    if ($Config.purview.enabled -eq $true) {
        $imperative.Add([ordered]@{ system = 'Microsoft Purview'; operation = 'Create or verify the fixed tenant-wide Know Your Data Group and the blueprint-specific Individual DLP location through an interactive compliance session'; mutation = $true })
    }
    $imperative.Add([ordered]@{ system = 'Verification'; operation = 'Read back identities, permissions, private-network posture, immutable images, health, and provisioning prerequisites'; mutation = $false })

    return [ordered]@{
        schemaVersion = 1
        deploymentId = "$($Config.projectName)-$($Config.environment)"
        scope = [ordered]@{
            tenantId = [string]$Config.tenantId
            subscriptionId = [string]$Config.subscriptionId
            resourceGroupName = [string]$Config.resourceGroupName
            location = [string]$Config.location
            sqlBootstrapClientIpv4 = $BootstrapClientIpv4
            deploymentOwnershipId = $canonicalOwnershipId
        }
        profile = [string]$Config.environment
        features = [ordered]@{
            developmentRegistryPreview = $registryPreview
            promptShields = [bool]$Config.promptShield.enabled
            promptShieldSku = [string]$Config.promptShield.skuName
            purview = [bool]$Config.purview.enabled
            purviewRuntimeAdapter = $false
            purviewPolicyProfiles = [bool]$Config.purview.policyProvisioningEnabled
            reviewedAgent365ManagerApplicationIds = @($reviewedManagerIds)
        }
        agent365SeedBlueprint = [ordered]@{
            displayName = $plannedBlueprintDisplayName
            deploymentOwnershipId = $canonicalOwnershipId
            sourceFingerprint = $SourceFingerprint
            planDisposition = [string]$blueprintPlanDisposition.mode
            providerMutationAuthorized = [bool]$blueprintPlanDisposition.providerMutationAuthorized
            creationEndpoint = 'https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint'
            ownerAndSponsor = 'Authenticated bootstrap administrator (exact object ID recorded and revalidated at Apply)'
            credentialCreation = $false
            preexistingObjectAdoption = $false
        }
        azureResources = @($azureResources)
        imperativeOperations = @($imperative)
        administratorBoundaries = @(
            'Azure and Microsoft tenant authentication may require interactive sign-in or Conditional Access.',
            'Tenant-wide Entra consent and Agent ID permissions must be held by the signed-in administrator.',
            'Database initialization temporarily replaces the singular Azure SQL Entra administrator with the exact private migration-job identity, then restores and independently reads back the original administrator before continuing.',
            'Purview authoring requires a separate interactive Security & Compliance session when enabled.',
            'Workflow v3 stops at 71% for a signed-in Gateway Administrator Registry action; the worker never calls Registry.'
        )
        costClasses = @(
            'Azure consumption, logs, SQL, registry, networking, storage, and Container Apps can incur charges.',
            $(if ($Config.promptShield.enabled -eq $true) { "Prompt Shields requests SKU $($Config.promptShield.skuName); availability and charges are subscription/region dependent." } else { 'Prompt Shields is not provisioned.' }),
            $(if ($Config.purview.enabled -eq $true) { 'Purview requires eligible Microsoft 365 licensing and tenant capacity.' } else { 'Purview policy authoring is not requested.' })
        )
        preflightLimitations = @(
            'NotChecked: subscription quota and every regional data-plane SKU limit; review Azure quota before Apply.',
            'NotChecked: tenant Agent 365 licensing/eligibility and interactive Conditional Access; the imperative requirements step fails closed.',
            'NotChecked: Purview propagation or synthetic verdict behavior; policy readback is configuration evidence only.',
            $(if ($Config.purview.policyProvisioningEnabled -eq $true) { 'NotChecked: the optional Microsoft 365 automation application certificate binding and Security & Compliance RBAC. Bootstrap verifies enabled Key Vault secret metadata; registrations that select a protection profile remain subject to independent fail-closed validation.' } else { 'Purview protection-profile automation authority is not requested.' }),
            'NotChecked: an authenticated browser session, first Active agent, or downstream Agent 365 landing.',
            'The ARM What-If below covers the subscription foundation only; Entra, Graph, Agent 365, SQL initialization, and Purview are listed separately in the imperative manifest.'
        )
        previewWarning = if ($registryPreview) { 'Development explicitly enables the preview, Global-cloud-only Agent 365 Registry dependency; this is not production support.' } else { 'Registry creation remains closed because the current preview dependency is unsupported for production.' }
        destructiveOperations = @()
    }
}

function Get-GatewaySeedBlueprintPlanDisposition {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)

    if (-not $State.Contains('steps') -or $State.steps -isnot [System.Collections.IDictionary]) {
        throw 'Bootstrap state has no valid step collection for Agent ID blueprint planning.'
    }
    if (-not $State.steps.Contains('Agent 365 seed blueprint')) {
        return [ordered]@{ mode = 'FreshCreate'; providerMutationAuthorized = $true }
    }

    $step = $State.steps['Agent 365 seed blueprint']
    if ($step -isnot [System.Collections.IDictionary]) {
        throw 'The recorded Agent ID blueprint step is malformed; preserve state for diagnosis.'
    }
    switch ([string]$step.status) {
        'Running' { return [ordered]@{ mode = 'GetOnlyReconciliation'; providerMutationAuthorized = $false } }
        'Failed' { return [ordered]@{ mode = 'GetOnlyReconciliation'; providerMutationAuthorized = $false } }
        'Completed' { return [ordered]@{ mode = 'ReadOnlyRevalidation'; providerMutationAuthorized = $false } }
        default { throw 'The recorded Agent ID blueprint step has an unsupported status; preserve state for diagnosis.' }
    }
}

function Get-GatewaySeedBlueprintPlanAuthorityContext {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)

    foreach ($stepName in @('Gateway API identity', 'Inert identity deployment')) {
        if (-not $State.steps.Contains($stepName) -or
            $State.steps[$stepName] -isnot [System.Collections.IDictionary] -or
            [string]$State.steps[$stepName].status -cne 'Completed' -or
            $State.steps[$stepName].evidence -isnot [System.Collections.IDictionary]) {
            throw "The recorded '$stepName' evidence is required for exact Agent ID blueprint recovery planning."
        }
    }

    $ownerObjectId = [string]$State.steps['Gateway API identity'].evidence.ownerObjectId
    $workerPrincipalId = [string]$State.steps['Inert identity deployment'].evidence.workerPrincipalId
    Assert-GuidValue -Value $ownerObjectId -Label 'Agent ID blueprint recovery owner object ID'
    Assert-GuidValue -Value $workerPrincipalId -Label 'Agent ID blueprint recovery worker principal ID'
    $ownerObjectId = ([guid]$ownerObjectId).ToString('D')
    $workerPrincipalId = ([guid]$workerPrincipalId).ToString('D')

    if ($State.steps.Contains('Azure authentication')) {
        $azureStep = $State.steps['Azure authentication']
        if ($azureStep -isnot [System.Collections.IDictionary] -or
            [string]$azureStep.status -cne 'Completed' -or
            $azureStep.evidence -isnot [System.Collections.IDictionary]) {
            throw 'Recorded Azure authentication evidence is malformed during Agent ID blueprint recovery planning.'
        }
        $authenticatedOwnerId = [string]$azureStep.evidence.userObjectId
        Assert-GuidValue -Value $authenticatedOwnerId -Label 'Recorded bootstrap administrator object ID'
        if (-not $ownerObjectId.Equals(([guid]$authenticatedOwnerId).ToString('D'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Recorded Azure authentication and Gateway API ownership disagree; refusing Agent ID blueprint recovery planning.'
        }
    }

    return [ordered]@{
        ownerObjectId = $ownerObjectId
        workerPrincipalId = $workerPrincipalId
    }
}

function Assert-GatewayStablePlanInputs {
    param(
        [Parameter(Mandatory)][string]$SourceFingerprintBefore,
        [Parameter(Mandatory)][string]$SourceFingerprintAfter,
        [Parameter(Mandatory)][string]$ConfigurationFingerprintBefore,
        [Parameter(Mandatory)][string]$ConfigurationFingerprintAfter
    )

    foreach ($entry in @(
        [ordered]@{ value = $SourceFingerprintBefore; label = 'Plan source fingerprint before compilation' },
        [ordered]@{ value = $SourceFingerprintAfter; label = 'Plan source fingerprint after What-If' },
        [ordered]@{ value = $ConfigurationFingerprintBefore; label = 'Plan configuration fingerprint before compilation' },
        [ordered]@{ value = $ConfigurationFingerprintAfter; label = 'Plan configuration fingerprint after What-If' }
    )) {
        Assert-BootstrapFingerprintValue -Value ([string]$entry.value) -Label ([string]$entry.label)
    }
    if ($SourceFingerprintAfter -cne $SourceFingerprintBefore -or
        $ConfigurationFingerprintAfter -cne $ConfigurationFingerprintBefore) {
        throw 'Bootstrap source or configuration changed while Plan was compiling and running What-If. No plan was issued; retry from a stable checkout.'
    }
    return $true
}

function Assert-GatewaySeedBlueprintPlanBoundary {
    param(
        [Parameter(Mandatory)]$Descriptor,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )

    if (-not $Descriptor.agent365SeedBlueprint -or
        [string]::IsNullOrWhiteSpace([string]$Descriptor.agent365SeedBlueprint.displayName) -or
        [string]::IsNullOrWhiteSpace([string]$Descriptor.agent365SeedBlueprint.deploymentOwnershipId) -or
        [string]::IsNullOrWhiteSpace([string]$Descriptor.agent365SeedBlueprint.sourceFingerprint) -or
        $Descriptor.agent365SeedBlueprint.credentialCreation -ne $false -or
        $Descriptor.agent365SeedBlueprint.preexistingObjectAdoption -ne $false) {
        throw 'The Plan omitted the exact credential-free, no-adoption Agent ID blueprint boundary.'
    }
    $expectedDisposition = Get-GatewaySeedBlueprintPlanDisposition -State $State
    if ([string]$Descriptor.agent365SeedBlueprint.planDisposition -cne [string]$expectedDisposition.mode -or
        [bool]$Descriptor.agent365SeedBlueprint.providerMutationAuthorized -ne [bool]$expectedDisposition.providerMutationAuthorized) {
        throw 'The Plan Agent ID blueprint recovery disposition does not match durable state.'
    }

    $existing = Get-Agent365BlueprintByName -DisplayName ([string]$Descriptor.agent365SeedBlueprint.displayName)
    if ([string]$expectedDisposition.mode -eq 'FreshCreate') {
        if ($existing) {
            throw 'The exact source- and ownership-bound Agent ID blueprint name already exists. Plan refuses a tenant-object collision before any Apply authorization.'
        }
        return $true
    }

    $authority = Get-GatewaySeedBlueprintPlanAuthorityContext -State $State
    $blueprintStep = $State.steps['Agent 365 seed blueprint']
    if ([string]$expectedDisposition.mode -eq 'ReadOnlyRevalidation') {
        if ($blueprintStep.evidence -isnot [System.Collections.IDictionary]) {
            throw 'Completed Agent ID blueprint state has no typed evidence for read-only Plan revalidation.'
        }
        return Test-GatewayBlueprintEvidence `
            -Config $Config `
            -Evidence $blueprintStep.evidence `
            -DeploymentOwnershipId ([string]$Descriptor.agent365SeedBlueprint.deploymentOwnershipId) `
            -SourceFingerprint ([string]$Descriptor.agent365SeedBlueprint.sourceFingerprint) `
            -SponsorObjectId ([string]$authority.ownerObjectId) `
            -GatewayManagedIdentityPrincipalId ([string]$authority.workerPrincipalId)
    }

    # A prior create may have failed before Graph made the exact object visible.
    # Plan remains GET-only in that case so Resume can reach the bounded
    # reconciler and report an unresolved outcome without ever repeating POST.
    if (-not $existing) { return $true }
    $current = Assert-Agent365SeedBlueprintSurface `
        -Blueprint $existing `
        -Config $Config `
        -ExpectedDisplayName ([string]$Descriptor.agent365SeedBlueprint.displayName) `
        -DeploymentOwnershipId ([string]$Descriptor.agent365SeedBlueprint.deploymentOwnershipId) `
        -SourceFingerprint ([string]$Descriptor.agent365SeedBlueprint.sourceFingerprint) `
        -SponsorObjectId ([string]$authority.ownerObjectId) `
        -GatewayManagedIdentityPrincipalId ([string]$authority.workerPrincipalId)
    if ($blueprintStep.Contains('evidence') -and $blueprintStep.evidence -is [System.Collections.IDictionary]) {
        foreach ($property in @('objectId', 'applicationId')) {
            if ($blueprintStep.evidence.Contains($property) -and
                [string]$blueprintStep.evidence[$property] -cne [string]$current[$property]) {
                throw 'The provider Agent ID blueprint does not match the exact persisted object identity; refusing name-only recovery.'
            }
        }
    }
    return $true
}

function Assert-GatewayResourceGroupRecoveryBoundary {
    param(
        [Parameter(Mandatory)][ValidateSet('true', 'false')][string]$ResourceGroupExists,
        $FoundationStep
    )

    if ($ResourceGroupExists -eq 'false' -and $FoundationStep -and
        [string]$FoundationStep.status -eq 'Completed') {
        throw 'The recorded Azure resource group was deleted after bootstrap completed its foundation. Automatic rebuild is intentionally unsupported because tenant-scoped Entra and Agent ID objects can survive while resource-group-scoped credential metadata does not. State was preserved; use a separately reviewed disaster-recovery procedure or a new isolated deployment identity.'
    }
    return $true
}

function Test-GatewayPlanSource {
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Plan requires Azure CLI and Bicep; Azure CLI is not available. Run gateway doctor.'
    }
    Assert-GatewayAzureCliProviderValidationSupport | Out-Null
    $bicepVersion = Get-GatewayCommandVersion -Name 'az' -Arguments @('bicep', 'version')
    if ([string]::IsNullOrWhiteSpace($bicepVersion)) {
        throw 'Plan requires an installed Azure Bicep CLI. Run az bicep install, then retry.'
    }

    $required = @(
        'infrastructure/bicep/main.bicep',
        'infrastructure/bicep/admin-ui.bicep',
        'tools/configure-workflow-v3-entra.ps1',
        'operations/test-provisioning-prerequisites.ps1'
    )
    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $path))) { throw "Required file is missing: $path" }
    }

    $templates = @(
        Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'bootstrap/infra') -Filter '*.bicep' -File -Recurse
        Get-Item -LiteralPath (Join-Path $RepositoryRoot 'infrastructure/bicep/main.bicep')
        Get-Item -LiteralPath (Join-Path $RepositoryRoot 'infrastructure/bicep/admin-ui.bicep')
    ) | Sort-Object FullName -Unique
    if ($templates.Count -eq 0) { throw 'No bootstrap Bicep templates were found.' }
    foreach ($template in $templates) {
        Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('bicep', 'build', '--file', $template.FullName, '--stdout') | Out-Null
    }
    return [ordered]@{
        bicepVersion = $bicepVersion
        compiledTemplates = @($templates | ForEach-Object { [IO.Path]::GetRelativePath($RepositoryRoot, $_.FullName).Replace('\', '/') })
    }
}

function Get-GatewayInertWhatIfRecoveryStateContext {
    param(
        [AllowNull()][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter()][string]$ExecutionSourceFingerprint = ''
    )

    if ([string]::IsNullOrWhiteSpace($ExecutionSourceFingerprint)) {
        $ExecutionSourceFingerprint = $SourceFingerprint
    }
    Assert-BootstrapFingerprintValue -Value $ExecutionSourceFingerprint -Label 'What-If execution source fingerprint'

    $sourceCorrection = $null
    if ($null -ne $State -and $State -is [System.Collections.IDictionary] -and
        $State.Contains('preInertSourceCorrectionPlan')) {
        $recordedCorrection = $State.preInertSourceCorrectionPlan
        if ($recordedCorrection -isnot [System.Collections.IDictionary]) { return $null }
        if ([string]$recordedCorrection.status -ceq 'Accepted') {
            $sourceCorrection = Assert-BootstrapPreInertSourceCorrectionPlan `
                -State $State `
                -ExecutionSourceFingerprint $ExecutionSourceFingerprint
        }
        elseif ([string]$recordedCorrection.status -ceq 'Completed') {
            $effectiveDeploymentSourceFingerprint = Get-BootstrapEffectiveDeploymentSourceFingerprint `
                -State $State `
                -ExecutionSourceFingerprint $ExecutionSourceFingerprint
            if ($effectiveDeploymentSourceFingerprint -cne $SourceFingerprint) { return $null }
            # Get-BootstrapEffectiveDeploymentSourceFingerprint validates the
            # completed correction plus any completed database-recovery/manual-
            # repair continuation before composing their source generations.
            $sourceCorrection = $recordedCorrection
        }
        else { return $null }
        if ([string]$sourceCorrection.originalDeploymentSourceFingerprint -cne $SourceFingerprint) {
            return $null
        }
    }

    if ($null -eq $State -or $State -isnot [System.Collections.IDictionary] -or
        -not $State.Contains('steps') -or $State.steps -isnot [System.Collections.IDictionary] -or
        -not $State.Contains('deploymentOwnershipId') -or
        [string]$State.deploymentOwnershipId -cne $DeploymentOwnershipId -or
        -not $State.Contains('configurationFingerprint') -or
        [string]$State.configurationFingerprint -cne (Get-BootstrapConfigurationFingerprint -Config $Config) -or
        -not $State.Contains('source') -or $State.source -isnot [System.Collections.IDictionary]) {
        return $null
    }

    $expectedCreatedSourceFingerprint = $SourceFingerprint
    $expectedLastWrittenSourceFingerprint = if ($null -ne $sourceCorrection) {
        $ExecutionSourceFingerprint
    }
    else {
        $SourceFingerprint
    }
    foreach ($sourceRecord in ([ordered]@{
        created = $expectedCreatedSourceFingerprint
        lastWritten = $expectedLastWrittenSourceFingerprint
    }).GetEnumerator()) {
        if (-not $State.source.Contains([string]$sourceRecord.Key) -or
            $State.source[[string]$sourceRecord.Key] -isnot [System.Collections.IDictionary] -or
            -not $State.source[[string]$sourceRecord.Key].Contains('bootstrapSourceFingerprint') -or
            [string]$State.source[[string]$sourceRecord.Key].bootstrapSourceFingerprint -cne [string]$sourceRecord.Value) {
            return $null
        }
    }

    $testExpectedStepSourceFingerprint = {
        param([int]$StepIndex, [string]$ActualSourceFingerprint)
        if ($null -eq $sourceCorrection) {
            return $ActualSourceFingerprint -ceq $SourceFingerprint
        }
        if ([string]$sourceCorrection.status -ceq 'Accepted') {
            # A correction stays Accepted until the corrected inert step is
            # durably Completed. A crash can therefore leave either always-run
            # step on the corrected snapshot, and can leave step 7 Running,
            # Failed, or Completed on that snapshot. Steps 3-6 remain bound to
            # the original deployment source throughout this transition.
            if ($StepIndex -in 0, 1) {
                return $ActualSourceFingerprint -cin @($SourceFingerprint, $ExecutionSourceFingerprint)
            }
            if ($StepIndex -ge 6) {
                return $ActualSourceFingerprint -ceq $ExecutionSourceFingerprint
            }
            return $ActualSourceFingerprint -ceq $SourceFingerprint
        }
        $correctionExecutionSourceFingerprint = [string]$sourceCorrection.correctedExecutionSourceFingerprint
        # The completed correction deliberately preserves original deployment
        # provenance on steps 3-6 and the exact inert result on the correction
        # source. A later completed database recovery/repair may advance the
        # current execution generation without rewriting those durable steps.
        if ($StepIndex -in 0, 1) {
            return $ActualSourceFingerprint -cin @(
                $correctionExecutionSourceFingerprint,
                $ExecutionSourceFingerprint)
        }
        if ($StepIndex -eq 6) {
            return $ActualSourceFingerprint -ceq $correctionExecutionSourceFingerprint
        }
        if ($StepIndex -ge 10 -and
            $ExecutionSourceFingerprint -cne $correctionExecutionSourceFingerprint) {
            return $ActualSourceFingerprint -ceq $ExecutionSourceFingerprint
        }
        if ($StepIndex -ge 7) {
            return $ActualSourceFingerprint -ceq $correctionExecutionSourceFingerprint
        }
        return $ActualSourceFingerprint -ceq $SourceFingerprint
    }

    $requiredCompletedSteps = @('Azure foundation', 'Gateway API identity', 'Immutable workload images')
    foreach ($stepName in $requiredCompletedSteps) {
        if (-not $State.steps.Contains($stepName)) { return $null }
        $step = $State.steps[$stepName]
        $requiredStepIndex = [Array]::IndexOf(@(Get-GatewayBootstrapStepNames), $stepName)
        if ($step -isnot [System.Collections.IDictionary] -or
            -not $step.Contains('status') -or [string]$step.status -cne 'Completed' -or
            -not $step.Contains('sourceFingerprint') -or
            -not (& $testExpectedStepSourceFingerprint $requiredStepIndex ([string]$step.sourceFingerprint)) -or
            -not $step.Contains('evidence') -or $null -eq $step.evidence) {
            return $null
        }
    }

    $inertStepName = 'Inert identity deployment'
    if (-not $State.steps.Contains($inertStepName)) { return $null }
    $inertStep = $State.steps[$inertStepName]
    $inertStepIndex = [Array]::IndexOf(@(Get-GatewayBootstrapStepNames), $inertStepName)
    if ($inertStep -isnot [System.Collections.IDictionary] -or
        -not $inertStep.Contains('status') -or [string]$inertStep.status -cnotin @('Running', 'Failed', 'Completed') -or
        -not $inertStep.Contains('sourceFingerprint') -or
        -not (& $testExpectedStepSourceFingerprint $inertStepIndex ([string]$inertStep.sourceFingerprint))) {
        return $null
    }

    $stepNames = @(Get-GatewayBootstrapStepNames)
    $inertIndex = [Array]::IndexOf($stepNames, $inertStepName)
    if ($inertIndex -lt 0) { return $null }
    [int[]]$observedIndexes = @()
    foreach ($stepName in @($State.steps.Keys | ForEach-Object { [string]$_ })) {
        $stepIndex = [Array]::IndexOf($stepNames, $stepName)
        if ($stepIndex -lt 0) { return $null }
        $observedIndexes += $stepIndex
    }
    if ($observedIndexes.Count -eq 0) { return $null }
    $lastObservedIndex = [Linq.Enumerable]::Max([int[]]$observedIndexes)
    if ($lastObservedIndex -lt $inertIndex) { return $null }
    for ($index = 0; $index -le $lastObservedIndex; $index++) {
        $stepName = [string]$stepNames[$index]
        if (-not $State.steps.Contains($stepName)) { return $null }
        $step = $State.steps[$stepName]
        if ($step -isnot [System.Collections.IDictionary] -or
            -not $step.Contains('status') -or
            [string]$step.status -cnotin @('Running', 'Failed', 'Completed') -or
            -not $step.Contains('sourceFingerprint') -or
            -not (& $testExpectedStepSourceFingerprint $index ([string]$step.sourceFingerprint))) {
            return $null
        }
        if ($index -lt $lastObservedIndex -and [string]$step.status -cne 'Completed') { return $null }
        if ([string]$step.status -ceq 'Completed' -and
            (-not $step.Contains('evidence') -or $null -eq $step.evidence)) {
            return $null
        }
    }
    if ($lastObservedIndex -gt $inertIndex -and [string]$inertStep.status -cne 'Completed') {
        return $null
    }

    $sqlPrivateEndpoint = $null
    $sqlPrivateEndpointName = 'SQL private endpoint'
    $sqlPrivateEndpointIndex = [Array]::IndexOf($stepNames, $sqlPrivateEndpointName)
    if ($State.steps.Contains($sqlPrivateEndpointName)) {
        $sqlStep = $State.steps[$sqlPrivateEndpointName]
        if ([string]$sqlStep.status -cne 'Completed') { return $null }
        $sqlPrivateEndpoint = $sqlStep.evidence
    }
    if ($lastObservedIndex -gt $sqlPrivateEndpointIndex -and $null -eq $sqlPrivateEndpoint) {
        return $null
    }
    # The Admin UI deployment adds a second independently owned ARM footprint.
    # It remains closed here until its exact typed recovery boundary is reviewed.
    if ($State.steps.Contains('Admin UI deployment')) { return $null }
    # The database step creates a persistent imperative Container Apps Job that
    # is intentionally outside the foundation What-If graph. Preserve its exact
    # evidence in the recovery context so the dedicated Resume preflight can
    # positively validate the receipt, Job, execution, image, and administrator.
    # Fresh Plan still cannot authorize this post-mutation boundary.
    $database = $null
    $databaseReceiptPath = Join-Path (Get-RepositoryRoot) ".bootstrap/evidence/$($Config.resourceGroupName)/database/private-database-bootstrap-receipt.json"
    $databaseReceiptExists = Test-Path -LiteralPath $databaseReceiptPath -PathType Leaf
    if ($State.steps.Contains('Gateway database')) {
        $databaseStep = $State.steps['Gateway database']
        if ([string]$databaseStep.status -ceq 'Completed' -and $databaseReceiptExists) {
            if ($databaseStep.evidence -isnot [System.Collections.IDictionary] -or
                -not $databaseStep.evidence.Contains('databaseBootstrapCompletionReceipt') -or
                [string]$databaseStep.evidence.databaseBootstrapCompletionReceipt -cne $databaseReceiptPath -or
                -not $databaseReceiptExists) {
                return $null
            }
            $database = $databaseStep.evidence
        }
        elseif ([string]$databaseStep.status -cne 'Completed' -and $databaseReceiptExists) {
            # A receipt beside a non-completed step is ambiguous. Only the
            # database-specific recovery contract may classify it.
            return $null
        }
    }

    $images = $State.steps['Immutable workload images'].evidence
    if ([string]::IsNullOrWhiteSpace([string]$images.api) -or
        [string]::IsNullOrWhiteSpace([string]$images.worker) -or
        [string]::IsNullOrWhiteSpace([string]$images.databaseMigrator)) {
        return $null
    }
    return [ordered]@{
        foundation = $State.steps['Azure foundation'].evidence
        identity = $State.steps['Gateway API identity'].evidence
        apiImage = [string]$images.api
        workerImage = [string]$images.worker
        databaseMigratorImage = [string]$images.databaseMigrator
        sqlPrivateEndpoint = $sqlPrivateEndpoint
        database = $database
        sqlServerFqdn = if ($inertStep.Contains('evidence')) { [string]$inertStep.evidence.sqlServerFqdn } else { '' }
    }
}

function Get-GatewayResumeCheckpointContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$ExecutionSourceFingerprint,
        [Parameter(Mandatory)][string]$DeploymentSourceFingerprint
    )

    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    Assert-BootstrapFingerprintValue -Value $ExecutionSourceFingerprint -Label 'Resume execution source fingerprint'
    Assert-BootstrapFingerprintValue -Value $DeploymentSourceFingerprint -Label 'Resume deployment source fingerprint'
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId -or
        -not $State.Contains('deploymentOwnershipId') -or
        [string]$State.deploymentOwnershipId -cne $canonicalOwnershipId -or
        -not $State.Contains('configurationFingerprint') -or
        [string]$State.configurationFingerprint -cne (Get-BootstrapConfigurationFingerprint -Config $Config) -or
        -not $State.Contains('acceptedPlan') -or
        $State.acceptedPlan -isnot [System.Collections.IDictionary] -or
        -not $State.Contains('steps') -or
        $State.steps -isnot [System.Collections.IDictionary]) {
        throw 'Resume checkpoint ownership, configuration, accepted authorization, or step state is incomplete.'
    }

    $allowedSourceFingerprints = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidate in @(
        $ExecutionSourceFingerprint,
        $DeploymentSourceFingerprint,
        [string]$State.acceptedPlan.sourceFingerprint,
        $(if ($State.Contains('source') -and $State.source -is [System.Collections.IDictionary] -and
            $State.source.Contains('created')) { [string]$State.source.created.bootstrapSourceFingerprint } else { '' }),
        $(if ($State.Contains('source') -and $State.source -is [System.Collections.IDictionary] -and
            $State.source.Contains('lastWritten')) { [string]$State.source.lastWritten.bootstrapSourceFingerprint } else { '' }),
        $(if ($State.Contains('preInertSourceCorrectionPlan') -and
            $State.preInertSourceCorrectionPlan -is [System.Collections.IDictionary]) {
                [string]$State.preInertSourceCorrectionPlan.originalDeploymentSourceFingerprint
            } else { '' }),
        $(if ($State.Contains('preInertSourceCorrectionPlan') -and
            $State.preInertSourceCorrectionPlan -is [System.Collections.IDictionary]) {
                [string]$State.preInertSourceCorrectionPlan.correctedExecutionSourceFingerprint
            } else { '' }),
        $(if ($State.Contains('databaseRecoveryPlan') -and
            $State.databaseRecoveryPlan -is [System.Collections.IDictionary]) {
                [string]$State.databaseRecoveryPlan.correctedSourceFingerprint
            } else { '' }),
        $(if ($State.Contains('manualDatabaseRepairPlan') -and
            $State.manualDatabaseRepairPlan -is [System.Collections.IDictionary]) {
                [string]$State.manualDatabaseRepairPlan.repairSourceFingerprint
            } else { '' })
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            Assert-BootstrapFingerprintValue -Value ([string]$candidate) -Label 'Resume checkpoint source fingerprint'
            $null = $allowedSourceFingerprints.Add([string]$candidate)
        }
    }

    $stepNames = @(Get-GatewayBootstrapStepNames)
    [int[]]$observedIndexes = @()
    foreach ($stepName in @($State.steps.Keys | ForEach-Object { [string]$_ })) {
        $stepIndex = [Array]::IndexOf($stepNames, $stepName)
        if ($stepIndex -lt 0) {
            throw 'Resume checkpoint contains an unknown bootstrap step.'
        }
        $observedIndexes += $stepIndex
    }
    if ($observedIndexes.Count -eq 0) {
        throw 'Resume is available only after a bootstrap checkpoint exists.'
    }
    $lastObservedIndex = [Linq.Enumerable]::Max([int[]]$observedIndexes)
    if ($observedIndexes.Count -ne ($lastObservedIndex + 1) -or
        @($observedIndexes | Sort-Object -Unique).Count -ne $observedIndexes.Count) {
        throw 'Resume checkpoint is not one contiguous bootstrap prefix.'
    }

    $completed = [Collections.Generic.List[string]]::new()
    $completedEvidence = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -le $lastObservedIndex; $index++) {
        $stepName = [string]$stepNames[$index]
        if (-not $State.steps.Contains($stepName)) {
            throw 'Resume checkpoint is not one contiguous bootstrap prefix.'
        }
        $record = $State.steps[$stepName]
        if ($record -isnot [System.Collections.IDictionary] -or
            [string]$record.status -cnotin @('Running', 'Failed', 'Completed') -or
            -not $record.Contains('sourceFingerprint') -or
            -not $allowedSourceFingerprints.Contains([string]$record.sourceFingerprint)) {
            throw 'Resume checkpoint contains malformed status or source provenance.'
        }
        if ($index -lt $lastObservedIndex -and [string]$record.status -cne 'Completed') {
            throw 'Resume checkpoint contains a non-completed step before a later step.'
        }
        if ([string]$record.status -ceq 'Completed') {
            if (-not $record.Contains('evidence') -or $null -eq $record.evidence) {
                throw 'Resume checkpoint contains a completed step without durable evidence.'
            }
            $completed.Add($stepName)
            $completedEvidence.Add([ordered]@{
                name = $stepName
                sourceFingerprint = [string]$record.sourceFingerprint
                evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $record.evidence
            })
        }
    }
    if ($completed.Count -eq 0) {
        throw 'Resume is available only after at least one completed bootstrap checkpoint.'
    }

    $currentRecord = $State.steps[[string]$stepNames[$lastObservedIndex]]
    $remainingStartIndex = if ([string]$currentRecord.status -ceq 'Completed') {
        $lastObservedIndex + 1
    }
    else {
        $lastObservedIndex
    }
    [string[]]$remaining = if ($remainingStartIndex -lt $stepNames.Count) {
        @($stepNames[$remainingStartIndex..($stepNames.Count - 1)])
    }
    else { @() }
    if ($remaining.Count -eq 0) {
        throw 'The bootstrap checkpoint has no remaining deployment step. Run gateway verify instead of Resume.'
    }

    $currentRecordEvidence = if ($currentRecord.Contains('evidence') -and $null -ne $currentRecord.evidence) {
        Get-BootstrapObjectFingerprint -InputObject $currentRecord.evidence
    }
    else { '' }
    $currentRecordProjection = [ordered]@{
        name = [string]$stepNames[$lastObservedIndex]
        status = [string]$currentRecord.status
        sourceFingerprint = [string]$currentRecord.sourceFingerprint
        startedAtUtc = if ($currentRecord.Contains('startedAtUtc')) { [string]$currentRecord.startedAtUtc } else { '' }
        completedAtUtc = if ($currentRecord.Contains('completedAtUtc')) { [string]$currentRecord.completedAtUtc } else { '' }
        failedAtUtc = if ($currentRecord.Contains('failedAtUtc')) { [string]$currentRecord.failedAtUtc } else { '' }
        reconciledAtUtc = if ($currentRecord.Contains('reconciledAtUtc')) { [string]$currentRecord.reconciledAtUtc } else { '' }
        message = if ($currentRecord.Contains('message')) { [string]$currentRecord.message } else { '' }
        evidenceFingerprint = $currentRecordEvidence
    }
    $checkpointCore = [ordered]@{
        schemaVersion = 2
        deploymentOwnershipId = $canonicalOwnershipId
        configurationFingerprint = [string]$State.configurationFingerprint
        acceptedPlanFingerprint = [string]$State.acceptedPlan.planFingerprint
        executionSourceFingerprint = $ExecutionSourceFingerprint
        deploymentSourceFingerprint = $DeploymentSourceFingerprint
        completed = @($completedEvidence)
        currentRecord = $currentRecordProjection
        currentStep = [string]$remaining[0]
        remainingSteps = $remaining
    }
    return [ordered]@{
        schemaVersion = 2
        deploymentOwnershipId = $canonicalOwnershipId
        completedSteps = @($completed)
        currentRecord = $currentRecordProjection
        currentStep = [string]$remaining[0]
        remainingSteps = $remaining
        checkpointFingerprint = Get-BootstrapObjectFingerprint -InputObject $checkpointCore
    }
}

function Test-GatewayNetworkHardeningEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Evidence
    )

    try {
        $expectedVaultName = "kv-$($Config.projectName)-$($Config.environment)"
        if ($Evidence -isnot [System.Collections.IDictionary] -or
            [string]$Evidence.sharedKeyVault -cne $expectedVaultName -or
            [string]$Evidence.publicNetworkAccess -cne 'Disabled' -or
            $Evidence.exactPostMutationReadback -ne $true) {
            throw 'mismatch'
        }
        $actual = Invoke-AzTsv -Arguments @(
            'keyvault', 'show', '--resource-group', [string]$Config.resourceGroupName,
            '--name', $expectedVaultName, '--query', 'properties.publicNetworkAccess')
        if ($actual -cne 'Disabled') { throw 'mismatch' }
        return $true
    }
    catch {
        throw 'Network-hardening revalidation was unavailable or mismatched; no network mutation was attempted.'
    }
}

function Test-GatewayRecoveryWhatIfResourceIdLexicalBoundary {
    param(
        [AllowNull()][string]$ResourceId,
        [Parameter(Mandatory)]$Config
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId) -or $ResourceId -match '[\t\r\n?#]' -or
        $ResourceId.Contains('//', [StringComparison]::Ordinal) -or
        $ResourceId.EndsWith('/', [StringComparison]::Ordinal)) {
        return $false
    }
    if ($ResourceId.Contains(' ', [StringComparison]::Ordinal)) {
        $expectedSmartDetectorId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.AlertsManagement/smartDetectorAlertRules/Failure Anomalies - ai-$($Config.projectName)-$($Config.environment)"
        return $ResourceId.Equals($expectedSmartDetectorId, [StringComparison]::OrdinalIgnoreCase)
    }
    return $true
}

function ConvertTo-GatewayRecoveryWhatIfResourceId {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)]$Config,
        [switch]$RequireCanonicalLowercase
    )

    if (-not (Test-GatewayRecoveryWhatIfResourceIdLexicalBoundary -ResourceId $ResourceId -Config $Config)) {
        throw 'Recovery What-If resource ID is malformed.'
    }
    $canonicalSubscriptionId = ([guid][string]$Config.subscriptionId).ToString('D')
    $resourceGroupName = [string]$Config.resourceGroupName
    if ([string]::IsNullOrWhiteSpace($resourceGroupName) -or $resourceGroupName -match '[\s/?#]') {
        throw 'Recovery What-If resource-group boundary is malformed.'
    }
    $normalized = $ResourceId.ToLowerInvariant()
    $expectedPrefix = "/subscriptions/$canonicalSubscriptionId/resourcegroups/$($resourceGroupName.ToLowerInvariant())/providers/"
    if (-not $normalized.StartsWith($expectedPrefix, [StringComparison]::Ordinal) -or
        $normalized.Length -le $expectedPrefix.Length) {
        throw 'Recovery What-If resource ID is outside the exact target resource group.'
    }
    if ($RequireCanonicalLowercase -and $ResourceId -cne $normalized) {
        throw 'Recovery boundary resource IDs must be canonical lowercase values.'
    }
    return $normalized
}

function Assert-GatewayExactDictionaryKeys {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$ExpectedKeys,
        [Parameter(Mandatory)][string]$Label
    )

    [string[]]$actual = @($Value.Keys | ForEach-Object { [string]$_ })
    [string[]]$expected = @($ExpectedKeys)
    [Array]::Sort($actual, [StringComparer]::Ordinal)
    [Array]::Sort($expected, [StringComparer]::Ordinal)
    if ($actual.Count -ne $expected.Count -or ($actual -join "`n") -cne ($expected -join "`n")) {
        throw "$Label has an unexpected property surface."
    }
    return $true
}

function Get-GatewaySqlPrivateEndpointWhatIfRecoveryExtension {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    [object[]]$validation = @(Test-GatewaySqlPrivateEndpointEvidence `
        -Config $Config `
        -Foundation $Foundation `
        -SqlServerFqdn $SqlServerFqdn `
        -Evidence $Evidence `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint)
    if ($validation.Count -ne 1 -or $validation[0] -isnot [bool] -or $validation[0] -ne $true) {
        throw 'Recovered SQL private-endpoint evidence failed exact independent validation.'
    }

    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'SQL private-endpoint recovery source fingerprint'
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'SQL private-endpoint recovery ownership ID is not canonical.'
    }
    $serverName = $SqlServerFqdn.Split('.')[0]
    $providerPrefix = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers"
    $privateEndpointId = "$providerPrefix/Microsoft.Network/privateEndpoints/pe-$serverName"
    $privateEndpoint = Invoke-AzJson -Arguments @(
        'network', 'private-endpoint', 'show', '--ids', $privateEndpointId,
        '--query', '{id:id,name:name,location:location,provisioningState:provisioningState,subnet:subnet,networkInterfaces:networkInterfaces}'
    )
    $networkInterfaces = @($privateEndpoint.networkInterfaces)
    if (-not ([string]$privateEndpoint.id).Equals($privateEndpointId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$privateEndpoint.name -cne "pe-$serverName" -or
        -not ([string]$privateEndpoint.location).Equals([string]$Config.location, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$privateEndpoint.provisioningState -cne 'Succeeded' -or
        -not ([string]$privateEndpoint.subnet.id).Equals([string]$Foundation.privateEndpointSubnetId, [StringComparison]::OrdinalIgnoreCase) -or
        $networkInterfaces.Count -ne 1) {
        throw 'The SQL private endpoint does not expose one exact generated network interface.'
    }

    $nicId = ConvertTo-GatewayRecoveryWhatIfResourceId `
        -ResourceId ([string]$networkInterfaces[0].id) `
        -Config $Config
    $nicPrefix = ("$providerPrefix/Microsoft.Network/networkInterfaces/pe-$serverName.nic.").ToLowerInvariant()
    if (-not $nicId.StartsWith($nicPrefix, [StringComparison]::Ordinal)) {
        throw 'The SQL private-endpoint network-interface name is not reverse-bound to the exact endpoint.'
    }
    $nicGuidText = $nicId.Substring($nicPrefix.Length)
    $nicGuid = [guid]::Empty
    if (-not [guid]::TryParse($nicGuidText, [ref]$nicGuid) -or $nicGuid -eq [guid]::Empty -or
        $nicGuidText -cne $nicGuid.ToString('D')) {
        throw 'The SQL private-endpoint network-interface suffix is not one canonical GUID.'
    }
    $nic = Invoke-AzJson -Arguments @(
        'resource', 'show', '--ids', $nicId, '--api-version', '2023-11-01',
        '--query', '{id:id,type:type,name:name,location:location,properties:properties}'
    )
    $ipConfigurations = @($nic.properties.ipConfigurations)
    if (-not ([string]$nic.id).Equals($nicId, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$nic.type).Equals('Microsoft.Network/networkInterfaces', [StringComparison]::OrdinalIgnoreCase) -or
        [string]$nic.name -cne "pe-$serverName.nic.$nicGuidText" -or
        -not ([string]$nic.location).Equals([string]$Config.location, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$nic.properties.provisioningState -cne 'Succeeded' -or
        -not ([string]$nic.properties.privateEndpoint.id).Equals($privateEndpointId, [StringComparison]::OrdinalIgnoreCase) -or
        $ipConfigurations.Count -ne 1 -or
        -not ([string]$ipConfigurations[0].properties.subnet.id).Equals([string]$Foundation.privateEndpointSubnetId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The SQL private-endpoint network interface does not exactly reverse-bind to the endpoint and foundation subnet.'
    }

    $privateEndpointCanonicalId = ConvertTo-GatewayRecoveryWhatIfResourceId -ResourceId ([string]$Evidence.privateEndpointId) -Config $Config
    $privateDnsZoneCanonicalId = ConvertTo-GatewayRecoveryWhatIfResourceId -ResourceId ([string]$Evidence.privateDnsZoneId) -Config $Config
    $virtualNetworkLinkCanonicalId = ConvertTo-GatewayRecoveryWhatIfResourceId -ResourceId ([string]$Evidence.virtualNetworkLinkId) -Config $Config
    $privateDnsZoneGroupCanonicalId = ConvertTo-GatewayRecoveryWhatIfResourceId -ResourceId ([string]$Evidence.privateDnsZoneGroupId) -Config $Config
    [string[]]$resourceIds = @(
        $nicId,
        $privateDnsZoneCanonicalId,
        $virtualNetworkLinkCanonicalId,
        $privateEndpointCanonicalId
    )
    [Array]::Sort($resourceIds, [StringComparer]::Ordinal)
    if (@($resourceIds | Sort-Object -Unique -CaseSensitive).Count -ne 4) {
        throw 'The SQL private-endpoint recovery extension is not the exact four-resource What-If graph.'
    }
    $typeInventoryResourceIds = [ordered]@{
        'Microsoft.Network/networkInterfaces' = @($nicId)
        'Microsoft.Network/privateDnsZones' = @($privateDnsZoneCanonicalId)
        'Microsoft.Network/privateDnsZones/virtualNetworkLinks' = @($virtualNetworkLinkCanonicalId)
        'Microsoft.Network/privateEndpoints' = @($privateEndpointCanonicalId)
    }
    $extension = [ordered]@{
        schemaVersion = 1
        phase = 'SqlPrivateEndpoint'
        deploymentName = "a365gw-$($Config.projectName)-bootstrap-sql-private-$($Config.environment)"
        deploymentOwnershipId = $canonicalOwnershipId
        sourceFingerprint = $SourceFingerprint
        resourceIds = $resourceIds
        typeInventoryResourceIds = $typeInventoryResourceIds
        generatedNicBinding = [ordered]@{
            nicId = $nicId
            privateEndpointId = $privateEndpointCanonicalId
            subnetId = ([string]$Foundation.privateEndpointSubnetId).ToLowerInvariant()
        }
        privateDnsBinding = [ordered]@{
            zoneId = $privateDnsZoneCanonicalId
            virtualNetworkLinkId = $virtualNetworkLinkCanonicalId
            zoneGroupId = $privateDnsZoneGroupCanonicalId
        }
    }
    $extension.boundaryFingerprint = Get-BootstrapObjectFingerprint -InputObject $extension
    return $extension
}

function Assert-GatewaySqlPrivateEndpointWhatIfRecoveryExtension {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Extension,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    Assert-GatewayExactDictionaryKeys -Value $Extension -ExpectedKeys @(
        'schemaVersion', 'phase', 'deploymentName', 'deploymentOwnershipId',
        'sourceFingerprint', 'resourceIds', 'typeInventoryResourceIds',
        'generatedNicBinding', 'privateDnsBinding', 'boundaryFingerprint'
    ) -Label 'SQL private-endpoint recovery extension' | Out-Null
    if ($Extension.schemaVersion -isnot [int] -or [int]$Extension.schemaVersion -ne 1 -or
        [string]$Extension.phase -cne 'SqlPrivateEndpoint' -or
        [string]$Extension.deploymentName -cne "a365gw-$($Config.projectName)-bootstrap-sql-private-$($Config.environment)" -or
        [string]$Extension.deploymentOwnershipId -cne $DeploymentOwnershipId -or
        [string]$Extension.sourceFingerprint -cne $SourceFingerprint -or
        $Extension.resourceIds -isnot [System.Collections.IList] -or
        @($Extension.resourceIds).Count -ne 4 -or
        $Extension.typeInventoryResourceIds -isnot [System.Collections.IDictionary] -or
        $Extension.generatedNicBinding -isnot [System.Collections.IDictionary] -or
        $Extension.privateDnsBinding -isnot [System.Collections.IDictionary]) {
        throw 'SQL private-endpoint recovery extension does not match the exact reviewed contract.'
    }
    Assert-BootstrapFingerprintValue -Value ([string]$Extension.boundaryFingerprint) -Label 'SQL private-endpoint recovery fingerprint'
    Assert-GatewayExactDictionaryKeys -Value $Extension.typeInventoryResourceIds -ExpectedKeys @(
        'Microsoft.Network/networkInterfaces',
        'Microsoft.Network/privateDnsZones',
        'Microsoft.Network/privateDnsZones/virtualNetworkLinks',
        'Microsoft.Network/privateEndpoints'
    ) -Label 'SQL private-endpoint recovery type inventory' | Out-Null
    Assert-GatewayExactDictionaryKeys -Value $Extension.generatedNicBinding -ExpectedKeys @(
        'nicId', 'privateEndpointId', 'subnetId'
    ) -Label 'SQL private-endpoint generated-NIC binding' | Out-Null
    Assert-GatewayExactDictionaryKeys -Value $Extension.privateDnsBinding -ExpectedKeys @(
        'zoneId', 'virtualNetworkLinkId', 'zoneGroupId'
    ) -Label 'SQL private-endpoint DNS binding' | Out-Null

    [string[]]$resourceIds = @($Extension.resourceIds | ForEach-Object {
        ConvertTo-GatewayRecoveryWhatIfResourceId -ResourceId ([string]$_) -Config $Config -RequireCanonicalLowercase
    })
    [string[]]$sortedResourceIds = @($resourceIds)
    [Array]::Sort($sortedResourceIds, [StringComparer]::Ordinal)
    if (($resourceIds -join "`n") -cne ($sortedResourceIds -join "`n") -or
        @($resourceIds | Sort-Object -Unique -CaseSensitive).Count -ne 4) {
        throw 'SQL private-endpoint recovery resource IDs are not unique canonical ordinal-sorted values.'
    }
    $inventoryIds = [Collections.Generic.List[string]]::new()
    foreach ($resourceType in @(
        'Microsoft.Network/networkInterfaces',
        'Microsoft.Network/privateDnsZones',
        'Microsoft.Network/privateDnsZones/virtualNetworkLinks',
        'Microsoft.Network/privateEndpoints'
    )) {
        $rawIds = $Extension.typeInventoryResourceIds[$resourceType]
        if ($rawIds -isnot [System.Collections.IList] -or @($rawIds).Count -ne 1) {
            throw 'SQL private-endpoint recovery type inventory must contain exactly one resource per reviewed type.'
        }
        $inventoryIds.Add((ConvertTo-GatewayRecoveryWhatIfResourceId `
            -ResourceId ([string]@($rawIds)[0]) -Config $Config -RequireCanonicalLowercase))
    }
    [string[]]$sortedInventoryIds = @($inventoryIds)
    [Array]::Sort($sortedInventoryIds, [StringComparer]::Ordinal)
    if (($sortedInventoryIds -join "`n") -cne ($resourceIds -join "`n")) {
        throw 'SQL private-endpoint recovery type inventory does not match its exact resource graph.'
    }
    foreach ($binding in @(
        [ordered]@{ value = [string]$Extension.generatedNicBinding.nicId; contained = $true },
        [ordered]@{ value = [string]$Extension.generatedNicBinding.privateEndpointId; contained = $true },
        [ordered]@{ value = [string]$Extension.generatedNicBinding.subnetId; contained = $false },
        [ordered]@{ value = [string]$Extension.privateDnsBinding.zoneId; contained = $true },
        [ordered]@{ value = [string]$Extension.privateDnsBinding.virtualNetworkLinkId; contained = $true },
        [ordered]@{ value = [string]$Extension.privateDnsBinding.zoneGroupId; contained = $false }
    )) {
        $bindingId = ConvertTo-GatewayRecoveryWhatIfResourceId -ResourceId $binding.value -Config $Config -RequireCanonicalLowercase
        if ($binding.contained -and $bindingId -notin $resourceIds) {
            throw 'SQL private-endpoint recovery binding is not contained by its exact resource graph.'
        }
    }
    $fingerprintInput = [ordered]@{
        schemaVersion = 1
        phase = 'SqlPrivateEndpoint'
        deploymentName = [string]$Extension.deploymentName
        deploymentOwnershipId = [string]$Extension.deploymentOwnershipId
        sourceFingerprint = [string]$Extension.sourceFingerprint
        resourceIds = $resourceIds
        typeInventoryResourceIds = $Extension.typeInventoryResourceIds
        generatedNicBinding = $Extension.generatedNicBinding
        privateDnsBinding = $Extension.privateDnsBinding
    }
    if ([string]$Extension.boundaryFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $fingerprintInput)) {
        throw 'SQL private-endpoint recovery fingerprint does not match its exact typed resource graph.'
    }
    return [ordered]@{
        resourceIds = $resourceIds
        typeInventoryResourceIds = $Extension.typeInventoryResourceIds
    }
}

function Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$StorageAccountId,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Defender Storage system-topic recovery source fingerprint'
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Defender Storage system-topic recovery ownership ID is not canonical.'
    }

    $canonicalStorageAccountId = ConvertTo-GatewayRecoveryWhatIfResourceId `
        -ResourceId $StorageAccountId -Config $Config
    $storagePrefix = ("/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.Storage/storageAccounts/").ToLowerInvariant()
    if (-not $canonicalStorageAccountId.StartsWith($storagePrefix, [StringComparison]::Ordinal) -or
        $canonicalStorageAccountId.Substring($storagePrefix.Length) -notmatch '^[a-z0-9]{3,24}$') {
        throw 'Defender Storage system-topic recovery requires one exact target storage-account resource ID.'
    }
    $storageAccountName = $canonicalStorageAccountId.Substring($storagePrefix.Length)

    $systemTopicPrefix = ("/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.EventGrid/systemTopics/").ToLowerInvariant()
    [object[]]$topicInventory = @(Invoke-AzJson -Arguments @(
        'resource', 'list', '--resource-group', [string]$Config.resourceGroupName,
        '--resource-type', 'Microsoft.EventGrid/systemTopics', '--query', '[].{id:id}'
    ))
    if ($topicInventory.Count -gt 1) {
        throw 'Defender Storage recovery permits at most one Event Grid system topic in the target resource group.'
    }
    if ($topicInventory.Count -eq 0) {
        $absentExtension = [ordered]@{
            schemaVersion = 2
            phase = 'DefenderStorageSystemTopic'
            present = $false
            deploymentOwnershipId = $canonicalOwnershipId
            sourceFingerprint = $SourceFingerprint
            resourceIds = @()
            typeInventoryResourceIds = [ordered]@{
                'Microsoft.EventGrid/systemTopics' = @()
            }
            systemTopicBinding = $null
            eventSubscriptionBinding = $null
        }
        $absentExtension.boundaryFingerprint = Get-BootstrapObjectFingerprint -InputObject $absentExtension
        return $absentExtension
    }

    $inventoryTopicId = ConvertTo-GatewayRecoveryWhatIfResourceId `
        -ResourceId ([string](Get-GatewayArmObjectProperty -Object $topicInventory[0] -Name 'id')) `
        -Config $Config
    if (-not $inventoryTopicId.StartsWith($systemTopicPrefix, [StringComparison]::Ordinal)) {
        throw 'The Defender Storage recovery inventory did not return a direct Event Grid system topic.'
    }
    $systemTopicName = $inventoryTopicId.Substring($systemTopicPrefix.Length)
    if ($systemTopicName.Contains('/', [StringComparison]::Ordinal) -or
        -not $systemTopicName.StartsWith("$storageAccountName-", [StringComparison]::Ordinal)) {
        throw 'The Defender Storage system-topic name is not reverse-bound to the exact storage account.'
    }
    $topicGuidText = $systemTopicName.Substring($storageAccountName.Length + 1)
    $topicGuid = [guid]::Empty
    if (-not [guid]::TryParse($topicGuidText, [ref]$topicGuid) -or $topicGuid -eq [guid]::Empty -or
        $topicGuidText -cne $topicGuid.ToString('D')) {
        throw 'The Defender Storage system-topic suffix is not one canonical nonempty GUID.'
    }

    $systemTopic = Invoke-AzJson -Arguments @(
        'resource', 'show', '--ids', $inventoryTopicId, '--api-version', '2025-02-15',
        '--query', '{id:id,type:type,name:name,location:location,tags:tags,identity:identity,provisioningState:properties.provisioningState,source:properties.source,topicType:properties.topicType}'
    )
    $topicTags = Get-GatewayArmObjectProperty -Object $systemTopic -Name 'tags'
    $topicIdentity = Get-GatewayArmObjectProperty -Object $systemTopic -Name 'identity'
    if ($null -eq $systemTopic -or
        -not ([string](Get-GatewayArmObjectProperty -Object $systemTopic -Name 'id')).Equals($inventoryTopicId, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string](Get-GatewayArmObjectProperty -Object $systemTopic -Name 'type')).Equals('Microsoft.EventGrid/systemTopics', [StringComparison]::OrdinalIgnoreCase) -or
        [string](Get-GatewayArmObjectProperty -Object $systemTopic -Name 'name') -cne $systemTopicName -or
        -not ([string](Get-GatewayArmObjectProperty -Object $systemTopic -Name 'location')).Equals([string]$Config.location, [StringComparison]::OrdinalIgnoreCase) -or
        [string](Get-GatewayArmObjectProperty -Object $systemTopic -Name 'provisioningState') -cne 'Succeeded' -or
        -not ([string](Get-GatewayArmObjectProperty -Object $systemTopic -Name 'source')).Equals($canonicalStorageAccountId, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string](Get-GatewayArmObjectProperty -Object $systemTopic -Name 'topicType')).Equals('Microsoft.Storage.StorageAccounts', [StringComparison]::OrdinalIgnoreCase) -or
        $null -ne $topicIdentity -or
        ($null -ne $topicTags -and @(Get-GatewayArmObjectPropertyNames -Object $topicTags).Count -ne 0)) {
        throw 'The Event Grid system topic does not match the exact observed Defender Storage recovery envelope.'
    }

    [object[]]$eventSubscriptionInventory = @(Invoke-AzJson -Arguments @(
        'eventgrid', 'system-topic', 'event-subscription', 'list',
        '--resource-group', [string]$Config.resourceGroupName,
        '--system-topic-name', $systemTopicName,
        '--query', '[].{id:id,name:name}'
    ))
    if ($eventSubscriptionInventory.Count -ne 1 -or
        [string](Get-GatewayArmObjectProperty -Object $eventSubscriptionInventory[0] -Name 'name') -cne 'StorageAntimalwareSubscription') {
        throw 'The Defender Storage system topic does not contain the exact single observed malware-scanning event subscription.'
    }
    $eventSubscriptionId = ConvertTo-GatewayRecoveryWhatIfResourceId `
        -ResourceId ([string](Get-GatewayArmObjectProperty -Object $eventSubscriptionInventory[0] -Name 'id')) `
        -Config $Config
    $expectedEventSubscriptionId = "$inventoryTopicId/eventsubscriptions/storageantimalwaresubscription"
    if ($eventSubscriptionId -cne $expectedEventSubscriptionId) {
        throw 'The Defender Storage event-subscription inventory is not nested under the exact system topic.'
    }

    $eventSubscription = Invoke-AzJson -Arguments @(
        'resource', 'show', '--ids', $eventSubscriptionId, '--api-version', '2025-02-15',
        '--query', '{id:id,type:type,name:name,provisioningState:properties.provisioningState,topic:properties.topic,destinationEndpointType:properties.destination.endpointType,eventDeliverySchema:properties.eventDeliverySchema,includedEventTypes:properties.filter.includedEventTypes,subjectBeginsWith:properties.filter.subjectBeginsWith,subjectEndsWith:properties.filter.subjectEndsWith,isSubjectCaseSensitive:properties.filter.isSubjectCaseSensitive,advancedFilters:properties.filter.advancedFilters[].{key:key,operatorType:operatorType,values:values},retryPolicy:properties.retryPolicy,deadLetterDestination:properties.deadLetterDestination,deliveryWithResourceIdentity:properties.deliveryWithResourceIdentity,deadLetterWithResourceIdentity:properties.deadLetterWithResourceIdentity}'
    )
    $rawIncludedEventTypes = Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'includedEventTypes'
    [string[]]$includedEventTypes = @(
        Get-GatewayArmArrayItems -Value $rawIncludedEventTypes |
            ForEach-Object { [string]$_ }
    )
    [Array]::Sort($includedEventTypes, [StringComparer]::Ordinal)
    [string[]]$expectedEventTypes = @('Microsoft.Storage.BlobCreated', 'Microsoft.Storage.BlobRenamed')
    $rawAdvancedFilters = Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'advancedFilters'
    [object[]]$advancedFilters = @(Get-GatewayArmArrayItems -Value $rawAdvancedFilters)
    $rawFilterValues = if ($advancedFilters.Count -eq 1) {
        Get-GatewayArmObjectProperty -Object $advancedFilters[0] -Name 'values'
    }
    else { $null }
    [object[]]$filterValues = if ($advancedFilters.Count -eq 1) {
        @(Get-GatewayArmArrayItems -Value $rawFilterValues)
    }
    else { @() }
    $retryPolicy = Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'retryPolicy'
    $subjectBeginsWith = Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'subjectBeginsWith'
    $subjectEndsWith = Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'subjectEndsWith'
    if ($null -eq $eventSubscription -or
        -not ([string](Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'id')).Equals($eventSubscriptionId, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string](Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'type')).Equals('Microsoft.EventGrid/systemTopics/eventSubscriptions', [StringComparison]::OrdinalIgnoreCase) -or
        [string](Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'name') -cne 'StorageAntimalwareSubscription' -or
        [string](Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'provisioningState') -cne 'Succeeded' -or
        -not ([string](Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'topic')).Equals($inventoryTopicId, [StringComparison]::OrdinalIgnoreCase) -or
        [string](Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'destinationEndpointType') -cne 'WebHook' -or
        [string](Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'eventDeliverySchema') -cne 'EventGridSchema' -or
        $rawIncludedEventTypes -isnot [System.Collections.IList] -or
        $includedEventTypes.Count -ne 2 -or ($includedEventTypes -join "`n") -cne ($expectedEventTypes -join "`n") -or
        $subjectBeginsWith -isnot [string] -or [string]$subjectBeginsWith -cne '' -or
        $subjectEndsWith -isnot [string] -or [string]$subjectEndsWith -cne '' -or
        $null -ne (Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'isSubjectCaseSensitive') -or
        $rawAdvancedFilters -isnot [System.Collections.IList] -or $advancedFilters.Count -ne 1 -or
        [string](Get-GatewayArmObjectProperty -Object $advancedFilters[0] -Name 'key') -cne 'data.blobType' -or
        [string](Get-GatewayArmObjectProperty -Object $advancedFilters[0] -Name 'operatorType') -cne 'StringContains' -or
        $rawFilterValues -isnot [System.Collections.IList] -or
        $filterValues.Count -ne 1 -or [string]$filterValues[0] -cne 'BlockBlob' -or
        $null -eq $retryPolicy -or
        [int](Get-GatewayArmObjectProperty -Object $retryPolicy -Name 'eventTimeToLiveInMinutes') -ne 1440 -or
        [int](Get-GatewayArmObjectProperty -Object $retryPolicy -Name 'maxDeliveryAttempts') -ne 30 -or
        $null -ne (Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'deadLetterDestination') -or
        $null -ne (Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'deliveryWithResourceIdentity') -or
        $null -ne (Get-GatewayArmObjectProperty -Object $eventSubscription -Name 'deadLetterWithResourceIdentity')) {
        throw 'The Defender Storage event subscription does not match the exact bounded live-generation recovery contract.'
    }

    $extension = [ordered]@{
        schemaVersion = 2
        phase = 'DefenderStorageSystemTopic'
        present = $true
        deploymentOwnershipId = $canonicalOwnershipId
        sourceFingerprint = $SourceFingerprint
        resourceIds = @($inventoryTopicId)
        typeInventoryResourceIds = [ordered]@{
            'Microsoft.EventGrid/systemTopics' = @($inventoryTopicId)
        }
        systemTopicBinding = [ordered]@{
            systemTopicId = $inventoryTopicId
            name = $systemTopicName
            location = ([string]$Config.location).ToLowerInvariant()
            provisioningState = 'Succeeded'
            storageAccountId = $canonicalStorageAccountId
            topicType = 'Microsoft.Storage.StorageAccounts'
            identityPresent = $false
            tagsPresent = $false
        }
        eventSubscriptionBinding = [ordered]@{
            eventSubscriptionId = $eventSubscriptionId
            systemTopicId = $inventoryTopicId
            name = 'StorageAntimalwareSubscription'
            provisioningState = 'Succeeded'
            destinationEndpointType = 'WebHook'
            eventDeliverySchema = 'EventGridSchema'
            includedEventTypes = $expectedEventTypes
            subjectBeginsWith = ''
            subjectEndsWith = ''
            isSubjectCaseSensitive = $null
            advancedFilter = [ordered]@{
                key = 'data.blobType'
                operatorType = 'StringContains'
                values = @('BlockBlob')
            }
            retryPolicy = [ordered]@{
                eventTimeToLiveInMinutes = 1440
                maxDeliveryAttempts = 30
            }
            deadLetterDestinationPresent = $false
            deliveryWithResourceIdentityPresent = $false
            deadLetterWithResourceIdentityPresent = $false
        }
    }
    $extension.boundaryFingerprint = Get-BootstrapObjectFingerprint -InputObject $extension
    return $extension
}

function Assert-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Extension,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$StorageAccountId,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    Assert-GatewayExactDictionaryKeys -Value $Extension -ExpectedKeys @(
        'schemaVersion', 'phase', 'present', 'deploymentOwnershipId', 'sourceFingerprint',
        'resourceIds', 'typeInventoryResourceIds', 'systemTopicBinding',
        'eventSubscriptionBinding', 'boundaryFingerprint'
    ) -Label 'Defender Storage system-topic recovery extension' | Out-Null
    if ($Extension.schemaVersion -isnot [int] -or [int]$Extension.schemaVersion -ne 2 -or
        [string]$Extension.phase -cne 'DefenderStorageSystemTopic' -or
        $Extension.present -isnot [bool] -or
        [string]$Extension.deploymentOwnershipId -cne $DeploymentOwnershipId -or
        [string]$Extension.sourceFingerprint -cne $SourceFingerprint -or
        $Extension.resourceIds -isnot [System.Collections.IList] -or
        $Extension.typeInventoryResourceIds -isnot [System.Collections.IDictionary]) {
        throw 'Defender Storage system-topic recovery extension does not match the exact reviewed contract.'
    }
    Assert-BootstrapFingerprintValue -Value ([string]$Extension.boundaryFingerprint) -Label 'Defender Storage system-topic recovery fingerprint'
    Assert-GatewayExactDictionaryKeys -Value $Extension.typeInventoryResourceIds `
        -ExpectedKeys @('Microsoft.EventGrid/systemTopics') `
        -Label 'Defender Storage system-topic recovery type inventory' | Out-Null

    $canonicalStorageAccountId = ConvertTo-GatewayRecoveryWhatIfResourceId -ResourceId $StorageAccountId -Config $Config
    $storagePrefix = ("/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.Storage/storageAccounts/").ToLowerInvariant()
    if (-not $canonicalStorageAccountId.StartsWith($storagePrefix, [StringComparison]::Ordinal) -or
        $canonicalStorageAccountId.Substring($storagePrefix.Length) -notmatch '^[a-z0-9]{3,24}$') {
        throw 'Defender Storage system-topic validation requires one exact target storage-account resource ID.'
    }
    $inventoryIds = $Extension.typeInventoryResourceIds['Microsoft.EventGrid/systemTopics']
    $expectedResourceCount = if ([bool]$Extension.present) { 1 } else { 0 }
    if ($inventoryIds -isnot [System.Collections.IList] -or
        @($Extension.resourceIds).Count -ne $expectedResourceCount -or
        @($inventoryIds).Count -ne $expectedResourceCount) {
        throw 'Defender Storage system-topic presence does not match its exact resource and type inventory.'
    }
    if (-not [bool]$Extension.present) {
        if ($null -ne $Extension.systemTopicBinding -or $null -ne $Extension.eventSubscriptionBinding) {
            throw 'An absent Defender Storage system topic cannot carry provider bindings.'
        }
        $absentFingerprintInput = [ordered]@{
            schemaVersion = 2
            phase = 'DefenderStorageSystemTopic'
            present = $false
            deploymentOwnershipId = [string]$Extension.deploymentOwnershipId
            sourceFingerprint = [string]$Extension.sourceFingerprint
            resourceIds = @()
            typeInventoryResourceIds = $Extension.typeInventoryResourceIds
            systemTopicBinding = $null
            eventSubscriptionBinding = $null
        }
        if ([string]$Extension.boundaryFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $absentFingerprintInput)) {
            throw 'Absent Defender Storage system-topic recovery fingerprint does not match its exact typed inventory.'
        }
        return [ordered]@{ present = $false; resourceIds = @() }
    }

    if ($Extension.systemTopicBinding -isnot [System.Collections.IDictionary] -or
        $Extension.eventSubscriptionBinding -isnot [System.Collections.IDictionary]) {
        throw 'Present Defender Storage system-topic recovery bindings are malformed.'
    }
    Assert-GatewayExactDictionaryKeys -Value $Extension.systemTopicBinding -ExpectedKeys @(
        'systemTopicId', 'name', 'location', 'provisioningState', 'storageAccountId',
        'topicType', 'identityPresent', 'tagsPresent'
    ) -Label 'Defender Storage system-topic binding' | Out-Null
    Assert-GatewayExactDictionaryKeys -Value $Extension.eventSubscriptionBinding -ExpectedKeys @(
        'eventSubscriptionId', 'systemTopicId', 'name', 'provisioningState',
        'destinationEndpointType', 'eventDeliverySchema', 'includedEventTypes',
        'subjectBeginsWith', 'subjectEndsWith', 'isSubjectCaseSensitive',
        'advancedFilter', 'retryPolicy', 'deadLetterDestinationPresent',
        'deliveryWithResourceIdentityPresent', 'deadLetterWithResourceIdentityPresent'
    ) -Label 'Defender Storage event-subscription binding' | Out-Null
    if ($Extension.eventSubscriptionBinding.advancedFilter -isnot [System.Collections.IDictionary] -or
        $Extension.eventSubscriptionBinding.retryPolicy -isnot [System.Collections.IDictionary]) {
        throw 'Defender Storage event-subscription nested bindings are malformed.'
    }
    Assert-GatewayExactDictionaryKeys -Value $Extension.eventSubscriptionBinding.advancedFilter `
        -ExpectedKeys @('key', 'operatorType', 'values') `
        -Label 'Defender Storage event-subscription advanced filter' | Out-Null
    Assert-GatewayExactDictionaryKeys -Value $Extension.eventSubscriptionBinding.retryPolicy `
        -ExpectedKeys @('eventTimeToLiveInMinutes', 'maxDeliveryAttempts') `
        -Label 'Defender Storage event-subscription retry policy' | Out-Null
    $systemTopicId = ConvertTo-GatewayRecoveryWhatIfResourceId `
        -ResourceId ([string]@($Extension.resourceIds)[0]) -Config $Config -RequireCanonicalLowercase
    $systemTopicPrefix = ("/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.EventGrid/systemTopics/").ToLowerInvariant()
    if (-not $systemTopicId.StartsWith($systemTopicPrefix, [StringComparison]::Ordinal) -or
        $systemTopicId.Substring($systemTopicPrefix.Length).Contains('/', [StringComparison]::Ordinal)) {
        throw 'Defender Storage system-topic validation requires one direct target Event Grid system-topic resource ID.'
    }
    if ($inventoryIds -isnot [System.Collections.IList] -or @($inventoryIds).Count -ne 1 -or
        [string]@($inventoryIds)[0] -cne $systemTopicId -or
        [string]$Extension.systemTopicBinding.systemTopicId -cne $systemTopicId -or
        [string]$Extension.systemTopicBinding.storageAccountId -cne $canonicalStorageAccountId -or
        [string]$Extension.systemTopicBinding.location -cne ([string]$Config.location).ToLowerInvariant() -or
        [string]$Extension.systemTopicBinding.provisioningState -cne 'Succeeded' -or
        [string]$Extension.systemTopicBinding.topicType -cne 'Microsoft.Storage.StorageAccounts' -or
        $Extension.systemTopicBinding.identityPresent -isnot [bool] -or $Extension.systemTopicBinding.identityPresent -ne $false -or
        $Extension.systemTopicBinding.tagsPresent -isnot [bool] -or $Extension.systemTopicBinding.tagsPresent -ne $false) {
        throw 'Defender Storage system-topic binding does not match its exact canonical resource graph.'
    }
    $storageAccountName = $canonicalStorageAccountId.Substring($storagePrefix.Length)
    $expectedTopicPrefix = "$storageAccountName-"
    if (-not ([string]$Extension.systemTopicBinding.name).StartsWith($expectedTopicPrefix, [StringComparison]::Ordinal) -or
        -not $systemTopicId.EndsWith("/systemtopics/$([string]$Extension.systemTopicBinding.name)", [StringComparison]::Ordinal)) {
        throw 'Defender Storage system-topic name is not reverse-bound to its canonical resource ID and storage account.'
    }
    $topicGuidText = ([string]$Extension.systemTopicBinding.name).Substring($expectedTopicPrefix.Length)
    $topicGuid = [guid]::Empty
    if (-not [guid]::TryParse($topicGuidText, [ref]$topicGuid) -or $topicGuid -eq [guid]::Empty -or
        $topicGuidText -cne $topicGuid.ToString('D')) {
        throw 'Defender Storage system-topic binding has a noncanonical generated suffix.'
    }

    $eventBinding = $Extension.eventSubscriptionBinding
    $eventSubscriptionId = ConvertTo-GatewayRecoveryWhatIfResourceId `
        -ResourceId ([string]$eventBinding.eventSubscriptionId) -Config $Config -RequireCanonicalLowercase
    [string[]]$includedEventTypes = @($eventBinding.includedEventTypes | ForEach-Object { [string]$_ })
    [string[]]$filterValues = @($eventBinding.advancedFilter.values | ForEach-Object { [string]$_ })
    if ($eventSubscriptionId -cne "$systemTopicId/eventsubscriptions/storageantimalwaresubscription" -or
        [string]$eventBinding.systemTopicId -cne $systemTopicId -or
        [string]$eventBinding.name -cne 'StorageAntimalwareSubscription' -or
        [string]$eventBinding.provisioningState -cne 'Succeeded' -or
        [string]$eventBinding.destinationEndpointType -cne 'WebHook' -or
        [string]$eventBinding.eventDeliverySchema -cne 'EventGridSchema' -or
        $eventBinding.includedEventTypes -isnot [System.Collections.IList] -or
        $includedEventTypes.Count -ne 2 -or
        ($includedEventTypes -join "`n") -cne "Microsoft.Storage.BlobCreated`nMicrosoft.Storage.BlobRenamed" -or
        $eventBinding.subjectBeginsWith -isnot [string] -or [string]$eventBinding.subjectBeginsWith -cne '' -or
        $eventBinding.subjectEndsWith -isnot [string] -or [string]$eventBinding.subjectEndsWith -cne '' -or
        $null -ne $eventBinding.isSubjectCaseSensitive -or
        [string]$eventBinding.advancedFilter.key -cne 'data.blobType' -or
        [string]$eventBinding.advancedFilter.operatorType -cne 'StringContains' -or
        $eventBinding.advancedFilter.values -isnot [System.Collections.IList] -or
        $filterValues.Count -ne 1 -or $filterValues[0] -cne 'BlockBlob' -or
        [int]$eventBinding.retryPolicy.eventTimeToLiveInMinutes -ne 1440 -or
        [int]$eventBinding.retryPolicy.maxDeliveryAttempts -ne 30 -or
        $eventBinding.deadLetterDestinationPresent -isnot [bool] -or $eventBinding.deadLetterDestinationPresent -ne $false -or
        $eventBinding.deliveryWithResourceIdentityPresent -isnot [bool] -or $eventBinding.deliveryWithResourceIdentityPresent -ne $false -or
        $eventBinding.deadLetterWithResourceIdentityPresent -isnot [bool] -or $eventBinding.deadLetterWithResourceIdentityPresent -ne $false) {
        throw 'Defender Storage event-subscription binding does not match the exact bounded live-generation contract.'
    }

    $fingerprintInput = [ordered]@{
        schemaVersion = 2
        phase = 'DefenderStorageSystemTopic'
        present = $true
        deploymentOwnershipId = [string]$Extension.deploymentOwnershipId
        sourceFingerprint = [string]$Extension.sourceFingerprint
        resourceIds = @($systemTopicId)
        typeInventoryResourceIds = $Extension.typeInventoryResourceIds
        systemTopicBinding = $Extension.systemTopicBinding
        eventSubscriptionBinding = $Extension.eventSubscriptionBinding
    }
    if ([string]$Extension.boundaryFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $fingerprintInput)) {
        throw 'Defender Storage system-topic recovery fingerprint does not match its exact typed resource graph.'
    }
    return [ordered]@{ present = $true; resourceIds = @($systemTopicId) }
}

function New-GatewayStateAwareWhatIfRecoveryBoundary {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$InertBoundary,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SqlPrivateEndpointExtension,
        [Parameter(Mandatory)][string[]]$InertResourceIds,
        [Parameter(Mandatory)][string[]]$SqlPrivateEndpointResourceIds,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    [string[]]$resourceIds = @($InertResourceIds + $SqlPrivateEndpointResourceIds)
    [Array]::Sort($resourceIds, [StringComparer]::Ordinal)
    if ($resourceIds.Count -ne 29 -or
        @($resourceIds | Sort-Object -Unique -CaseSensitive).Count -ne 29) {
        throw 'The state-aware recovery boundary is not the exact reviewed 29-resource graph.'
    }
    $boundary = [ordered]@{
        schemaVersion = 3
        phase = 'InertIdentityDeployment+SqlPrivateEndpoint'
        deploymentOwnershipId = $DeploymentOwnershipId
        sourceFingerprint = $SourceFingerprint
        resourceIds = $resourceIds
        inertBoundaryFingerprint = [string]$InertBoundary.boundaryFingerprint
        sqlPrivateEndpointBoundaryFingerprint = [string]$SqlPrivateEndpointExtension.boundaryFingerprint
    }
    $boundary.boundaryFingerprint = Get-BootstrapObjectFingerprint -InputObject $boundary
    return $boundary
}

function New-GatewayDefenderStorageAwareWhatIfRecoveryBoundary {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$BaseBoundary,
        [Parameter(Mandatory)][System.Collections.IDictionary]$DefenderStorageExtension,
        [Parameter(Mandatory)][string[]]$BaseResourceIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$DefenderStorageResourceIds,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $expectedBaseSchemaVersion = if ($BaseResourceIds.Count -eq 25) { 2 } elseif ($BaseResourceIds.Count -eq 29) { 3 } else { -1 }
    $expectedBasePhase = if ($BaseResourceIds.Count -eq 25) {
        'InertIdentityDeployment'
    }
    elseif ($BaseResourceIds.Count -eq 29) {
        'InertIdentityDeployment+SqlPrivateEndpoint'
    }
    else { '' }
    if ($expectedBaseSchemaVersion -lt 0 -or
        [int]$BaseBoundary.schemaVersion -ne $expectedBaseSchemaVersion -or
        [string]$BaseBoundary.phase -cne $expectedBasePhase -or
        [string]$BaseBoundary.deploymentOwnershipId -cne $DeploymentOwnershipId -or
        [string]$BaseBoundary.sourceFingerprint -cne $SourceFingerprint -or
        $BaseBoundary.resourceIds -isnot [System.Collections.IList] -or
        (@($BaseBoundary.resourceIds) -join "`n") -cne ($BaseResourceIds -join "`n")) {
        throw 'The Defender Storage recovery base boundary is not the exact reviewed inert or inert-plus-SQL graph.'
    }
    Assert-BootstrapFingerprintValue -Value ([string]$BaseBoundary.boundaryFingerprint) -Label 'Defender Storage recovery base-boundary fingerprint'
    Assert-BootstrapFingerprintValue -Value ([string]$DefenderStorageExtension.boundaryFingerprint) -Label 'Defender Storage recovery extension fingerprint'
    $expectedDefenderStorageCount = if ($DefenderStorageExtension.present -is [bool] -and
        [bool]$DefenderStorageExtension.present) { 1 } else { 0 }
    if ($DefenderStorageExtension.schemaVersion -isnot [int] -or
        [int]$DefenderStorageExtension.schemaVersion -ne 2 -or
        $DefenderStorageExtension.present -isnot [bool] -or
        $DefenderStorageExtension.resourceIds -isnot [System.Collections.IList] -or
        $DefenderStorageResourceIds.Count -ne $expectedDefenderStorageCount -or
        (@($DefenderStorageExtension.resourceIds) -join "`n") -cne ($DefenderStorageResourceIds -join "`n")) {
        throw 'The Defender Storage recovery extension does not match its exact absent-or-one-resource system-topic graph.'
    }

    [string[]]$resourceIds = @($BaseResourceIds + $DefenderStorageResourceIds)
    [Array]::Sort($resourceIds, [StringComparer]::Ordinal)
    $expectedCount = $BaseResourceIds.Count + $expectedDefenderStorageCount
    if ($expectedCount -notin @(25, 26, 29, 30) -or $resourceIds.Count -ne $expectedCount -or
        @($resourceIds | Sort-Object -Unique -CaseSensitive).Count -ne $expectedCount) {
        throw 'The Defender Storage-aware recovery boundary is not the exact reviewed 25-, 26-, 29-, or 30-resource graph.'
    }
    $boundary = [ordered]@{
        schemaVersion = 4
        phase = "$expectedBasePhase+DefenderStorageSystemTopic"
        defenderStoragePresent = [bool]$DefenderStorageExtension.present
        deploymentOwnershipId = $DeploymentOwnershipId
        sourceFingerprint = $SourceFingerprint
        resourceIds = $resourceIds
        baseBoundaryFingerprint = [string]$BaseBoundary.boundaryFingerprint
        defenderStorageBoundaryFingerprint = [string]$DefenderStorageExtension.boundaryFingerprint
    }
    $boundary.boundaryFingerprint = Get-BootstrapObjectFingerprint -InputObject $boundary
    return $boundary
}

function New-GatewayFoundationGovernanceNsgAwareWhatIfRecoveryBoundary {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$BaseBoundary,
        [Parameter(Mandatory)][string[]]$BaseResourceIds,
        [Parameter(Mandatory)][string[]]$GovernanceNsgResourceIds,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $expectedBasePhase = if ($BaseResourceIds.Count -in @(25, 26)) {
        'InertIdentityDeployment+DefenderStorageSystemTopic'
    }
    elseif ($BaseResourceIds.Count -in @(29, 30)) {
        'InertIdentityDeployment+SqlPrivateEndpoint+DefenderStorageSystemTopic'
    }
    else { '' }
    $expectedDefenderStoragePresent = $BaseResourceIds.Count -in @(26, 30)
    if ([int]$BaseBoundary.schemaVersion -ne 4 -or
        [string]$BaseBoundary.phase -cne $expectedBasePhase -or
        $BaseBoundary.defenderStoragePresent -isnot [bool] -or
        [bool]$BaseBoundary.defenderStoragePresent -ne $expectedDefenderStoragePresent -or
        [string]$BaseBoundary.deploymentOwnershipId -cne $DeploymentOwnershipId -or
        [string]$BaseBoundary.sourceFingerprint -cne $SourceFingerprint -or
        $BaseBoundary.resourceIds -isnot [System.Collections.IList] -or
        (@($BaseBoundary.resourceIds) -join "`n") -cne ($BaseResourceIds -join "`n")) {
        throw 'The governance NSG recovery base is not the exact reviewed state-aware boundary.'
    }
    Assert-BootstrapFingerprintValue `
        -Value ([string]$BaseBoundary.boundaryFingerprint) `
        -Label 'Governance NSG recovery base-boundary fingerprint'

    [string[]]$expectedGovernanceNsgResourceIds = @(
        Get-GatewayFoundationGovernanceNsgWhatIfResourceIds -Config $Config)
    [string[]]$canonicalGovernanceNsgResourceIds = @($GovernanceNsgResourceIds | ForEach-Object {
        ConvertTo-GatewayRecoveryWhatIfResourceId `
            -ResourceId ([string]$_) `
            -Config $Config `
            -RequireCanonicalLowercase
    })
    [Array]::Sort($canonicalGovernanceNsgResourceIds, [StringComparer]::Ordinal)
    if (($canonicalGovernanceNsgResourceIds -join "`n") -cne
        ($expectedGovernanceNsgResourceIds -join "`n")) {
        throw 'The governance NSG recovery extension is not the exact deterministic two-resource pair.'
    }

    [string[]]$resourceIds = @($BaseResourceIds + $canonicalGovernanceNsgResourceIds)
    [Array]::Sort($resourceIds, [StringComparer]::Ordinal)
    $expectedCount = $BaseResourceIds.Count + 2
    if ($expectedCount -notin @(27, 28, 31, 32) -or
        $resourceIds.Count -ne $expectedCount -or
        @($resourceIds | Sort-Object -Unique -CaseSensitive).Count -ne $expectedCount) {
        throw 'The governance NSG-aware recovery boundary is not an exact reviewed resource graph.'
    }
    $boundary = [ordered]@{
        schemaVersion = 5
        phase = "$expectedBasePhase+FoundationGovernanceNsg"
        deploymentOwnershipId = $DeploymentOwnershipId
        sourceFingerprint = $SourceFingerprint
        resourceIds = $resourceIds
        baseBoundaryFingerprint = [string]$BaseBoundary.boundaryFingerprint
        externalGovernanceNsgResourceIds = $expectedGovernanceNsgResourceIds
    }
    $boundary.boundaryFingerprint = Get-BootstrapObjectFingerprint -InputObject $boundary
    return $boundary
}

function Assert-GatewayInertWhatIfRecoveryBoundary {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Boundary,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    Assert-GatewayExactDictionaryKeys -Value $Boundary -ExpectedKeys @(
        'schemaVersion', 'phase', 'deploymentName', 'deploymentOwnershipId',
        'sourceFingerprint', 'resourceIds', 'generatedNicBinding',
        'masterDatabaseBinding', 'boundaryFingerprint'
    ) -Label 'Recovery Ignore boundary' | Out-Null
    if ($Boundary.schemaVersion -isnot [int] -or [int]$Boundary.schemaVersion -ne 2 -or
        [string]$Boundary.phase -cne 'InertIdentityDeployment' -or
        [string]$Boundary.deploymentName -cne "a365gw-$($Config.projectName)-bootstrap-inert-$($Config.environment)" -or
        [string]$Boundary.deploymentOwnershipId -cne $DeploymentOwnershipId -or
        [string]$Boundary.sourceFingerprint -cne $SourceFingerprint -or
        $Boundary.resourceIds -isnot [System.Collections.IList] -or
        @($Boundary.resourceIds).Count -ne 25 -or
        $Boundary.generatedNicBinding -isnot [System.Collections.IDictionary] -or
        $Boundary.masterDatabaseBinding -isnot [System.Collections.IDictionary]) {
        throw 'Recovery Ignore boundary does not match the exact inert deployment contract.'
    }
    Assert-BootstrapFingerprintValue -Value ([string]$Boundary.boundaryFingerprint) -Label 'Recovery Ignore boundary fingerprint'
    Assert-GatewayExactDictionaryKeys -Value $Boundary.generatedNicBinding -ExpectedKeys @(
        'nicId', 'privateEndpointId', 'subnetId'
    ) -Label 'Recovery generated-NIC binding' | Out-Null
    Assert-GatewayExactDictionaryKeys -Value $Boundary.masterDatabaseBinding -ExpectedKeys @(
        'databaseId', 'sqlServerId'
    ) -Label 'Recovery master-database binding' | Out-Null

    [string[]]$resourceIds = @($Boundary.resourceIds | ForEach-Object {
        ConvertTo-GatewayRecoveryWhatIfResourceId -ResourceId ([string]$_) -Config $Config -RequireCanonicalLowercase
    })
    [string[]]$sortedResourceIds = @($resourceIds)
    [Array]::Sort($sortedResourceIds, [StringComparer]::Ordinal)
    if (($resourceIds -join "`n") -cne ($sortedResourceIds -join "`n") -or
        @($resourceIds | Sort-Object -Unique -CaseSensitive).Count -ne $resourceIds.Count) {
        throw 'Recovery Ignore boundary resource IDs are not unique canonical ordinal-sorted values.'
    }

    foreach ($bindingName in @('nicId', 'privateEndpointId', 'subnetId')) {
        $bindingId = ConvertTo-GatewayRecoveryWhatIfResourceId `
            -ResourceId ([string]$Boundary.generatedNicBinding[$bindingName]) `
            -Config $Config `
            -RequireCanonicalLowercase
        if ($bindingName -ne 'subnetId' -and $bindingId -notin $resourceIds) {
            throw 'Recovery generated-NIC binding is not contained by the exact resource graph.'
        }
    }
    foreach ($bindingName in @('databaseId', 'sqlServerId')) {
        $bindingId = ConvertTo-GatewayRecoveryWhatIfResourceId `
            -ResourceId ([string]$Boundary.masterDatabaseBinding[$bindingName]) `
            -Config $Config `
            -RequireCanonicalLowercase
        if ($bindingId -notin $resourceIds) {
            throw 'Recovery master-database binding is not contained by the exact resource graph.'
        }
    }

    $fingerprintInput = [ordered]@{
        schemaVersion = 2
        phase = 'InertIdentityDeployment'
        deploymentName = [string]$Boundary.deploymentName
        deploymentOwnershipId = [string]$Boundary.deploymentOwnershipId
        sourceFingerprint = [string]$Boundary.sourceFingerprint
        resourceIds = $resourceIds
        generatedNicBinding = $Boundary.generatedNicBinding
        masterDatabaseBinding = $Boundary.masterDatabaseBinding
    }
    if ([string]$Boundary.boundaryFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $fingerprintInput)) {
        throw 'Recovery Ignore boundary fingerprint does not match its exact typed resource graph.'
    }
    return $resourceIds
}

function New-GatewayPreInertSourceCorrectionWhatIfBoundary {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CorrectionPlan,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$DeploymentSourceFingerprint,
        [Parameter(Mandatory)][string]$ExecutionSourceFingerprint
    )

    if ([string]$CorrectionPlan.status -cne 'Accepted' -or
        [string]$CorrectionPlan.deploymentOwnershipId -cne $DeploymentOwnershipId -or
        [string]$CorrectionPlan.configurationFingerprint -cne (Get-BootstrapConfigurationFingerprint -Config $Config) -or
        [string]$CorrectionPlan.originalDeploymentSourceFingerprint -cne $DeploymentSourceFingerprint -or
        [string]$CorrectionPlan.correctedExecutionSourceFingerprint -cne $ExecutionSourceFingerprint) {
        throw 'The pending pre-inert source correction is outside the exact plan, configuration, ownership, or source boundary.'
    }

    [string[]]$expectedStepNames = @((Get-GatewayBootstrapStepNames) | Select-Object -First 7)
    [string[]]$actualStepNames = @($State.steps.Keys | ForEach-Object { [string]$_ })
    [Array]::Sort($expectedStepNames, [StringComparer]::Ordinal)
    [Array]::Sort($actualStepNames, [StringComparer]::Ordinal)
    if (($expectedStepNames -join "`n") -cne ($actualStepNames -join "`n") -or
        -not $State.Contains('outputs') -or $State.outputs -isnot [System.Collections.IDictionary] -or
        $State.outputs.Count -ne 0) {
        throw 'The pending pre-inert source correction requires exactly steps 1-7 and an empty output boundary.'
    }

    $prefixStepNames = @((Get-GatewayBootstrapStepNames) | Select-Object -First 6)
    for ($index = 0; $index -lt $prefixStepNames.Count; $index++) {
        $stepName = [string]$prefixStepNames[$index]
        $step = $State.steps[[string]$stepName]
        $isOriginalCompleted = $step -is [System.Collections.IDictionary] -and
            [string]$step.status -ceq 'Completed' -and
            [string]$step.sourceFingerprint -ceq $DeploymentSourceFingerprint -and
            $step.Contains('evidence') -and $null -ne $step.evidence
        $isCorrectedAlwaysRunTransition = $index -lt 2 -and
            $step -is [System.Collections.IDictionary] -and
            [string]$step.status -cin @('Running', 'Failed', 'Completed') -and
            [string]$step.sourceFingerprint -ceq $ExecutionSourceFingerprint -and
            ([string]$step.status -cne 'Completed' -or
                ($step.Contains('evidence') -and $null -ne $step.evidence))
        if (-not $isOriginalCompleted -and -not $isCorrectedAlwaysRunTransition) {
            throw 'The pending pre-inert source correction requires exact completed original-source evidence through immutable images.'
        }
    }
    $inertStep = $State.steps['Inert identity deployment']
    $isOriginalFailure = $inertStep -is [System.Collections.IDictionary] -and
        [string]$inertStep.status -ceq 'Failed' -and
        [string]$inertStep.sourceFingerprint -ceq $DeploymentSourceFingerprint -and
        -not $inertStep.Contains('evidence')
    $isCorrectedStartedOutcome = $inertStep -is [System.Collections.IDictionary] -and
        [string]$inertStep.status -cin @('Running', 'Failed', 'Completed') -and
        [string]$inertStep.sourceFingerprint -ceq $ExecutionSourceFingerprint -and
        ([string]$inertStep.status -cne 'Completed' -or
            ($inertStep.Contains('evidence') -and $null -ne $inertStep.evidence))
    if (-not $isOriginalFailure -and -not $isCorrectedStartedOutcome) {
        throw 'The pending pre-inert source correction has an unsupported step-7 source, status, or evidence boundary.'
    }
    foreach ($record in ([ordered]@{
        created = $DeploymentSourceFingerprint
        lastWritten = $ExecutionSourceFingerprint
    }).GetEnumerator()) {
        if (-not $State.source.Contains([string]$record.Key) -or
            $State.source[[string]$record.Key] -isnot [System.Collections.IDictionary] -or
            [string]$State.source[[string]$record.Key].bootstrapSourceFingerprint -cne [string]$record.Value) {
            throw 'The pending pre-inert source correction state does not preserve distinct deployment and execution source provenance.'
        }
    }
    $foundation = $State.steps['Azure foundation'].evidence
    $images = $State.steps['Immutable workload images'].evidence
    if ([string]$foundation.deploymentOwnershipId -cne $DeploymentOwnershipId -or
        [string]$foundation.sourceFingerprint -cne $DeploymentSourceFingerprint -or
        [string]$images.deploymentOwnershipId -cne $DeploymentOwnershipId -or
        [string]$images.sourceFingerprint -cne $DeploymentSourceFingerprint) {
        throw 'The pending pre-inert source correction evidence does not retain original deployment provenance.'
    }

    $boundary = [ordered]@{
        schemaVersion = 1
        boundaryKind = 'PreInertSourceCorrectionWhatIf'
        correctionKind = [string]$CorrectionPlan.correctionKind
        correctionPlanFingerprint = [string]$CorrectionPlan.planFingerprint
        originalBoundaryFingerprint = [string]$CorrectionPlan.originalBoundaryFingerprint
        deploymentOwnershipId = $DeploymentOwnershipId
        deploymentSourceFingerprint = $DeploymentSourceFingerprint
        executionSourceFingerprint = $ExecutionSourceFingerprint
        currentStateBoundaryFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
            source = $State.source
            steps = $State.steps
            outputs = $State.outputs
        })
    }
    $boundary['boundaryFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $boundary
    return $boundary
}

function Get-GatewayFoundationGovernanceNsgWhatIfResourceIds {
    param([Parameter(Mandatory)]$Config)

    $subscriptionId = ([guid][string]$Config.subscriptionId).ToString('D')
    $resourceGroupName = [string]$Config.resourceGroupName
    $virtualNetworkName = "vnet-$($Config.projectName)-$($Config.environment)"
    $providerBase = "/subscriptions/$subscriptionId/resourcegroups/$($resourceGroupName.ToLowerInvariant())/providers"
    [string[]]$resourceIds = @(
        "$providerBase/microsoft.network/networksecuritygroups/$virtualNetworkName-snet-container-apps-nsg-$($Config.location)"
        "$providerBase/microsoft.network/networksecuritygroups/$virtualNetworkName-snet-private-endpoints-nsg-$($Config.location)"
    ) | ForEach-Object { ([string]$_).ToLowerInvariant() }
    [Array]::Sort($resourceIds, [StringComparer]::Ordinal)
    if ($resourceIds.Count -ne 2 -or
        @($resourceIds | Sort-Object -Unique -CaseSensitive).Count -ne 2 -or
        @($resourceIds | Where-Object {
            -not (Test-GatewayRecoveryWhatIfResourceIdLexicalBoundary -ResourceId $_ -Config $Config)
        }).Count -ne 0) {
        throw 'The deterministic foundation governance NSG resource IDs are malformed.'
    }
    return $resourceIds
}

function New-GatewayPreInertFoundationWhatIfBoundary {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Foundation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SourceCorrectionBoundary,
        [Parameter(Mandatory)][object[]]$Changes
    )

    if ([string]$SourceCorrectionBoundary.boundaryKind -cne 'PreInertSourceCorrectionWhatIf') {
        throw 'The foundation Ignore graph requires the exact pending source-correction boundary.'
    }
    foreach ($fingerprintName in @(
        'correctionPlanFingerprint', 'deploymentSourceFingerprint',
        'executionSourceFingerprint', 'currentStateBoundaryFingerprint', 'boundaryFingerprint'
    )) {
        Assert-BootstrapFingerprintValue `
            -Value ([string]$SourceCorrectionBoundary[$fingerprintName]) `
            -Label "Pre-inert source-correction $fingerprintName"
    }

    $subscriptionId = ([guid][string]$Config.subscriptionId).ToString('D')
    $resourceGroupName = [string]$Config.resourceGroupName
    if ([string]::IsNullOrWhiteSpace($resourceGroupName) -or
        $resourceGroupName -match '[\s/?#]') {
        throw 'The pending correction resource-group boundary is malformed.'
    }
    $resourceGroupId = "/subscriptions/$subscriptionId/resourcegroups/$($resourceGroupName.ToLowerInvariant())"
    $providerBase = "$resourceGroupId/providers"

    $expectedDeploymentName = "a365gw-$($Config.projectName)-bootstrap-foundation-$($Config.environment)"
    $expectedEnvironmentName = "cae-$($Config.projectName)-$($Config.environment)-vnet"
    $expectedVirtualNetworkName = "vnet-$($Config.projectName)-$($Config.environment)"
    $expectedPrivateEndpointSubnetName = 'snet-private-endpoints'
    $expectedLogAnalyticsName = "log-$($Config.projectName)-$($Config.environment)"
    $expectedRuntimeIdentityName = "id-gateway-runtime-pull-$($Config.environment)"
    $expectedEnvironmentId = "$providerBase/microsoft.app/managedenvironments/$expectedEnvironmentName"
    $expectedVirtualNetworkId = "$providerBase/microsoft.network/virtualnetworks/$expectedVirtualNetworkName"
    $expectedPrivateEndpointSubnetId = "$expectedVirtualNetworkId/subnets/$expectedPrivateEndpointSubnetName"
    $expectedRuntimeIdentityId = "$providerBase/microsoft.managedidentity/userassignedidentities/$expectedRuntimeIdentityName"

    $acrName = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'acrName')
    $expectedAcrPrefix = "acr$($Config.projectName)$($Config.environment)"
    if ($acrName -cnotmatch ('^' + [regex]::Escape($expectedAcrPrefix) + '[a-z0-9]{6}$')) {
        throw 'The pending correction foundation evidence has an unexpected registry name.'
    }
    $registryId = "$providerBase/microsoft.containerregistry/registries/$acrName"
    $diagnosticSettingId = "$registryId/providers/microsoft.insights/diagnosticsettings/$acrName-diag"

    $principalId = [string](Get-GatewayOptionalObjectProperty `
        -Object $Foundation -Name 'runtimeImagePullIdentityPrincipalId')
    $parsedPrincipalId = [guid]::Empty
    if (-not [guid]::TryParse($principalId, [ref]$parsedPrincipalId) -or
        $parsedPrincipalId -eq [guid]::Empty -or
        $principalId -cne $parsedPrincipalId.ToString('D')) {
        throw 'The pending correction foundation evidence has an invalid runtime image-pull principal.'
    }

    $roleAssignmentId = [string](Get-GatewayOptionalObjectProperty `
        -Object $Foundation -Name 'runtimeImagePullAcrPullRoleAssignmentId')
    $normalizedRoleAssignmentId = $roleAssignmentId.ToLowerInvariant()
    $roleAssignmentPrefix = "$registryId/providers/microsoft.authorization/roleassignments/"
    $roleAssignmentGuid = if ($normalizedRoleAssignmentId.StartsWith(
        $roleAssignmentPrefix, [StringComparison]::Ordinal)) {
        $normalizedRoleAssignmentId.Substring($roleAssignmentPrefix.Length)
    }
    else { '' }
    $parsedRoleAssignmentId = [guid]::Empty
    if ($roleAssignmentGuid.Contains('/', [StringComparison]::Ordinal) -or
        -not [guid]::TryParse($roleAssignmentGuid, [ref]$parsedRoleAssignmentId) -or
        $parsedRoleAssignmentId -eq [guid]::Empty -or
        $roleAssignmentGuid -cne $parsedRoleAssignmentId.ToString('D')) {
        throw 'The pending correction foundation evidence has an invalid ACR-scoped AcrPull assignment.'
    }

    foreach ($binding in @(
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'deploymentName'); expected = $expectedDeploymentName; label = 'deployment name'; exactCase = $true },
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'deploymentOwnershipId'); expected = [string]$SourceCorrectionBoundary.deploymentOwnershipId; label = 'deployment owner'; exactCase = $true },
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'sourceFingerprint'); expected = [string]$SourceCorrectionBoundary.deploymentSourceFingerprint; label = 'deployment source'; exactCase = $true },
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'resourceGroupName'); expected = $resourceGroupName; label = 'resource group'; exactCase = $true },
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'containerAppsEnvironmentName'); expected = $expectedEnvironmentName; label = 'Container Apps environment name'; exactCase = $true },
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'containerAppsEnvironmentId'); expected = $expectedEnvironmentId; label = 'Container Apps environment ID'; exactCase = $false },
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'virtualNetworkName'); expected = $expectedVirtualNetworkName; label = 'virtual network name'; exactCase = $true },
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'virtualNetworkId'); expected = $expectedVirtualNetworkId; label = 'virtual network ID'; exactCase = $false },
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'privateEndpointSubnetName'); expected = $expectedPrivateEndpointSubnetName; label = 'private-endpoint subnet name'; exactCase = $true },
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'privateEndpointSubnetId'); expected = $expectedPrivateEndpointSubnetId; label = 'private-endpoint subnet ID'; exactCase = $false },
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'logAnalyticsWorkspaceName'); expected = $expectedLogAnalyticsName; label = 'Log Analytics name'; exactCase = $true },
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'acrLoginServer'); expected = "$acrName.azurecr.io"; label = 'registry login server'; exactCase = $true },
        [ordered]@{ actual = [string](Get-GatewayOptionalObjectProperty -Object $Foundation -Name 'runtimeImagePullIdentityId'); expected = $expectedRuntimeIdentityId; label = 'runtime image-pull identity ID'; exactCase = $false }
    )) {
        $matches = if ([bool]$binding.exactCase) {
            [string]$binding.actual -ceq [string]$binding.expected
        }
        else {
            ([string]$binding.actual).Equals([string]$binding.expected, [StringComparison]::OrdinalIgnoreCase)
        }
        if (-not $matches) {
            throw "The pending correction foundation evidence has a mismatched $($binding.label)."
        }
    }

    [string[]]$expectedDeployResourceIds = @(
        $resourceGroupId
        $expectedEnvironmentId
        $registryId
        $normalizedRoleAssignmentId
        $diagnosticSettingId
        $expectedRuntimeIdentityId
        $expectedVirtualNetworkId
        "$providerBase/microsoft.operationalinsights/workspaces/$expectedLogAnalyticsName"
    )
    [Array]::Sort($expectedDeployResourceIds, [StringComparer]::Ordinal)
    [string[]]$expectedGovernanceIgnoreResourceIds = @(
        Get-GatewayFoundationGovernanceNsgWhatIfResourceIds -Config $Config)

    [string[]]$observedDeployResourceIds = @($Changes | Where-Object {
        [string]$_.changeType -ceq 'Deploy'
    } | ForEach-Object {
        if (-not (Test-GatewayRecoveryWhatIfResourceIdLexicalBoundary `
            -ResourceId ([string]$_.resourceId) -Config $Config)) {
            throw 'The pending correction What-If contains a malformed Deploy resource ID.'
        }
        ([string]$_.resourceId).ToLowerInvariant()
    })
    [Array]::Sort($observedDeployResourceIds, [StringComparer]::Ordinal)
    [string[]]$observedIgnoreResourceIds = @($Changes | Where-Object {
        [string]$_.changeType -ceq 'Ignore'
    } | ForEach-Object {
        if (-not (Test-GatewayRecoveryWhatIfResourceIdLexicalBoundary `
            -ResourceId ([string]$_.resourceId) -Config $Config)) {
            throw 'The pending correction What-If contains a malformed Ignore resource ID.'
        }
        ([string]$_.resourceId).ToLowerInvariant()
    })
    [Array]::Sort($observedIgnoreResourceIds, [StringComparer]::Ordinal)
    if (@($Changes | Where-Object { [string]$_.changeType -cnotin @('Deploy', 'Ignore') }).Count -ne 0 -or
        @($observedDeployResourceIds | Sort-Object -Unique -CaseSensitive).Count -ne $observedDeployResourceIds.Count -or
        @($observedIgnoreResourceIds | Sort-Object -Unique -CaseSensitive).Count -ne $observedIgnoreResourceIds.Count -or
        ($observedDeployResourceIds -join "`n") -cne ($expectedDeployResourceIds -join "`n") -or
        ($observedIgnoreResourceIds.Count -ne 0 -and
            ($observedIgnoreResourceIds -join "`n") -cne ($expectedGovernanceIgnoreResourceIds -join "`n")) -or
        $Changes.Count -ne $observedDeployResourceIds.Count + $observedIgnoreResourceIds.Count) {
        throw 'The pending correction What-If does not exactly match the reviewed foundation Deploy graph and optional governance NSG Ignore extension.'
    }

    $inertDeploymentName = "a365gw-$($Config.projectName)-bootstrap-inert-$($Config.environment)"
    $deploymentCountText = Invoke-AzTsv -Arguments @(
        'deployment', 'group', 'list', '--subscription', $subscriptionId,
        '--resource-group', $resourceGroupName,
        '--query', "length([?name=='$inertDeploymentName'])"
    )
    $deploymentCount = 0
    if (-not [int]::TryParse($deploymentCountText, [ref]$deploymentCount) -or $deploymentCount -ne 0) {
        throw 'The pending correction target does not have an exact zero-deployment inert boundary.'
    }
    $targetContainerApps = [ordered]@{}
    foreach ($containerAppName in @(
        "ca-gateway-api-$($Config.environment)",
        "ca-gateway-worker-$($Config.environment)-v3"
    )) {
        $resourceCountText = Invoke-AzTsv -Arguments @(
            'resource', 'list', '--subscription', $subscriptionId,
            '--resource-group', $resourceGroupName,
            '--name', $containerAppName,
            '--resource-type', 'Microsoft.App/containerApps', '--query', 'length(@)'
        )
        $resourceCount = 0
        if (-not [int]::TryParse($resourceCountText, [ref]$resourceCount) -or $resourceCount -ne 0) {
            throw "The pending correction target '$containerAppName' was not proven absent."
        }
        $targetContainerApps[$containerAppName] = $resourceCount
    }

    $boundary = [ordered]@{
        schemaVersion = 2
        boundaryKind = 'PreInertSourceCorrectionFoundationWhatIf'
        correctionKind = [string]$SourceCorrectionBoundary.correctionKind
        correctionPlanFingerprint = [string]$SourceCorrectionBoundary.correctionPlanFingerprint
        sourceCorrectionBoundaryFingerprint = [string]$SourceCorrectionBoundary.boundaryFingerprint
        sourceCorrectionStateBoundaryFingerprint = [string]$SourceCorrectionBoundary.currentStateBoundaryFingerprint
        deploymentOwnershipId = [string]$SourceCorrectionBoundary.deploymentOwnershipId
        deploymentSourceFingerprint = [string]$SourceCorrectionBoundary.deploymentSourceFingerprint
        executionSourceFingerprint = [string]$SourceCorrectionBoundary.executionSourceFingerprint
        foundationEvidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $Foundation
        inertDeployment = [ordered]@{ name = $inertDeploymentName; count = $deploymentCount }
        targetContainerApps = $targetContainerApps
        resourceIds = @($observedDeployResourceIds + $observedIgnoreResourceIds | Sort-Object -CaseSensitive)
        foundationDeployResourceIds = $expectedDeployResourceIds
        externalGovernanceIgnoreResourceIds = $observedIgnoreResourceIds
    }
    $boundary['boundaryFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $boundary
    return $boundary
}

function New-GatewaySourceCorrectionAwareWhatIfBoundary {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$CorrectionPlan,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RecoveryBoundary,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$DeploymentSourceFingerprint,
        [Parameter(Mandatory)][string]$ExecutionSourceFingerprint
    )

    $boundary = [ordered]@{
        schemaVersion = 1
        boundaryKind = 'SourceCorrectionAwareRecoveryWhatIf'
        correctionKind = [string]$CorrectionPlan.correctionKind
        correctionPlanFingerprint = [string]$CorrectionPlan.planFingerprint
        correctionCompletionBoundaryFingerprint = [string]$CorrectionPlan.completionBoundaryFingerprint
        deploymentOwnershipId = $DeploymentOwnershipId
        deploymentSourceFingerprint = $DeploymentSourceFingerprint
        executionSourceFingerprint = $ExecutionSourceFingerprint
        recoveredIgnoreBoundary = $RecoveryBoundary
    }
    $boundary['boundaryFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $boundary
    return $boundary
}

function New-GatewayPendingSourceCorrectionRecoveryWhatIfBoundary {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$SourceCorrectionBoundary,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RecoveryBoundary
    )

    if ([string]$SourceCorrectionBoundary.boundaryKind -cne 'PreInertSourceCorrectionWhatIf') {
        throw 'Pending source-correction recovery requires the exact current correction-state boundary.'
    }
    $boundary = [ordered]@{
        schemaVersion = 1
        boundaryKind = 'PendingSourceCorrectionRecoveryWhatIf'
        correctionKind = [string]$SourceCorrectionBoundary.correctionKind
        correctionPlanFingerprint = [string]$SourceCorrectionBoundary.correctionPlanFingerprint
        sourceCorrectionBoundaryFingerprint = [string]$SourceCorrectionBoundary.boundaryFingerprint
        sourceCorrectionStateBoundaryFingerprint = [string]$SourceCorrectionBoundary.currentStateBoundaryFingerprint
        deploymentOwnershipId = [string]$SourceCorrectionBoundary.deploymentOwnershipId
        deploymentSourceFingerprint = [string]$SourceCorrectionBoundary.deploymentSourceFingerprint
        executionSourceFingerprint = [string]$SourceCorrectionBoundary.executionSourceFingerprint
        recoveredIgnoreBoundary = $RecoveryBoundary
    }
    $boundary['boundaryFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $boundary
    return $boundary
}

function Invoke-GatewayFoundationWhatIf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter()][string]$ExecutionSourceFingerprint = '',
        [AllowNull()][System.Collections.IDictionary]$State
    )

    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Plan ownership ID must be the canonical lowercase GUID from the current bootstrap state.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Plan source fingerprint'
    if ([string]::IsNullOrWhiteSpace($ExecutionSourceFingerprint)) {
        $ExecutionSourceFingerprint = $SourceFingerprint
    }
    Assert-BootstrapFingerprintValue -Value $ExecutionSourceFingerprint -Label 'Plan execution source fingerprint'
    Assert-GatewayAzureCliProviderValidationSupport | Out-Null

    $sourceCorrectionPlan = $null
    $sourceCorrectionBoundary = $null
    if ($null -ne $State -and $State -is [System.Collections.IDictionary] -and
        $State.Contains('preInertSourceCorrectionPlan')) {
        $recordedCorrectionPlan = $State.preInertSourceCorrectionPlan
        if ($recordedCorrectionPlan -isnot [System.Collections.IDictionary]) {
            throw 'The persisted pre-inert source correction has an invalid contract.'
        }
        if ([string]$recordedCorrectionPlan.status -ceq 'Accepted') {
            $sourceCorrectionPlan = Assert-BootstrapPreInertSourceCorrectionPlan `
                -State $State `
                -ExecutionSourceFingerprint $ExecutionSourceFingerprint
        }
        elseif ([string]$recordedCorrectionPlan.status -ceq 'Completed') {
            $effectiveDeploymentSourceFingerprint = Get-BootstrapEffectiveDeploymentSourceFingerprint `
                -State $State `
                -ExecutionSourceFingerprint $ExecutionSourceFingerprint
            if ($effectiveDeploymentSourceFingerprint -cne $SourceFingerprint) {
                throw 'The completed source-correction chain does not map this execution source to the deployment source.'
            }
            $sourceCorrectionPlan = $recordedCorrectionPlan
        }
        else {
            throw 'The persisted pre-inert source correction has an unsupported status.'
        }
        if ([string]$sourceCorrectionPlan.originalDeploymentSourceFingerprint -cne $SourceFingerprint) {
            throw 'The pre-inert source correction does not authorize this deployment source fingerprint.'
        }
        if ([string]$sourceCorrectionPlan.status -ceq 'Accepted') {
            $sourceCorrectionBoundary = New-GatewayPreInertSourceCorrectionWhatIfBoundary `
                -State $State `
                -CorrectionPlan $sourceCorrectionPlan `
                -Config $Config `
                -DeploymentOwnershipId $canonicalOwnershipId `
                -DeploymentSourceFingerprint $SourceFingerprint `
                -ExecutionSourceFingerprint $ExecutionSourceFingerprint
        }
    }
    elseif ($ExecutionSourceFingerprint -cne $SourceFingerprint) {
        throw 'Distinct deployment and execution source fingerprints require an exact durable source-correction plan.'
    }

    Assert-GatewaySqlRegionalAvailability -Config $Config | Out-Null
    $deploymentName = "a365gw-plan-$($Config.projectName)-$($Config.environment)"
    $result = Invoke-AzJson -Arguments @(
        'deployment', 'sub', 'what-if',
        '--subscription', [string]$Config.subscriptionId,
        '--name', $deploymentName,
        '--location', [string]$Config.location,
        '--template-file', (Join-Path $RepositoryRoot 'bootstrap/infra/subscription.bicep'),
        '--parameters',
        "resourceGroupName=$($Config.resourceGroupName)",
        "location=$($Config.location)",
        "environment=$($Config.environment)",
        "projectName=$($Config.projectName)",
        "deploymentOwnershipId=$canonicalOwnershipId",
        "bootstrapSourceFingerprint=$SourceFingerprint",
        '--validation-level', 'Provider',
        '--result-format', 'ResourceIdOnly',
        '--no-pretty-print'
    )
    $resultIsObject = $result -is [System.Collections.IDictionary] -or
        ($null -ne $result -and $result.GetType() -eq [System.Management.Automation.PSCustomObject])
    $statusProperty = if (-not $resultIsObject) {
        $null
    }
    elseif ($result -is [System.Collections.IDictionary]) {
        if ($result.Contains('status')) { $result['status'] } else { $null }
    }
    else {
        $property = $result.PSObject.Properties['status']
        if ($null -ne $property) { $property.Value } else { $null }
    }
    $hasStatusProperty = $resultIsObject -and (
        ($result -is [System.Collections.IDictionary] -and $result.Contains('status')) -or
        ($result -isnot [System.Collections.IDictionary] -and $null -ne $result.PSObject.Properties['status']))
    $errorPropertyPresent = $resultIsObject -and (
        ($result -is [System.Collections.IDictionary] -and $result.Contains('error')) -or
        ($result -isnot [System.Collections.IDictionary] -and $null -ne $result.PSObject.Properties['error']))
    $errorValue = if (-not $errorPropertyPresent) {
        $null
    }
    elseif ($result -is [System.Collections.IDictionary]) {
        $result['error']
    }
    else {
        $result.PSObject.Properties['error'].Value
    }
    $operationSucceeded = $hasStatusProperty -and
        [string]$statusProperty -ceq 'Succeeded' -and
        $null -eq $errorValue
    $topLevelHasChanges = $resultIsObject -and (
        ($result -is [System.Collections.IDictionary] -and $result.Contains('changes')) -or
        ($result -isnot [System.Collections.IDictionary] -and $null -ne $result.PSObject.Properties['changes']))
    $properties = if (-not $resultIsObject) {
        $null
    }
    elseif ($result -is [System.Collections.IDictionary]) {
        if ($result.Contains('properties')) { $result['properties'] } else { $null }
    }
    else {
        $property = $result.PSObject.Properties['properties']
        if ($null -ne $property) { $property.Value } else { $null }
    }
    $propertiesIsObject = $properties -is [System.Collections.IDictionary] -or
        ($null -ne $properties -and $properties.GetType() -eq [System.Management.Automation.PSCustomObject])
    $propertiesHasChanges = $propertiesIsObject -and (
        ($properties -is [System.Collections.IDictionary] -and $properties.Contains('changes')) -or
        ($properties -isnot [System.Collections.IDictionary] -and $null -ne $properties.PSObject.Properties['changes']))
    # Azure CLI's --no-pretty-print contract exposes changes at the top level,
    # while some CLI/API versions return the underlying properties.changes
    # envelope. Accept exactly one reviewed shape and reject ambiguous output.
    $hasExactlyOneChangesSurface = ([int][bool]$topLevelHasChanges + [int][bool]$propertiesHasChanges) -eq 1
    # Assign inside the branch instead of using the branch as pipeline output.
    # PowerShell otherwise collapses an explicit empty array to $null and makes a
    # valid zero-change What-If indistinguishable from a malformed null contract.
    $rawChanges = $null
    if ($topLevelHasChanges -and -not $propertiesHasChanges) {
        if ($result -is [System.Collections.IDictionary]) {
            $rawChanges = $result['changes']
        }
        else {
            $rawChanges = $result.PSObject.Properties['changes'].Value
        }
    }
    elseif ($propertiesHasChanges -and -not $topLevelHasChanges) {
        if ($properties -is [System.Collections.IDictionary]) {
            $rawChanges = $properties['changes']
        }
        else {
            $rawChanges = $properties.PSObject.Properties['changes'].Value
        }
    }
    $changesAreArray = $rawChanges -is [System.Array] -or $rawChanges -is [System.Collections.IList]
    if (-not $resultIsObject -or -not $operationSucceeded -or -not $hasExactlyOneChangesSurface -or -not $changesAreArray) {
        return [ordered]@{
            executed = $true
            applyReady = $false
            reason = 'Azure What-If returned a missing or malformed result contract. No mutation is authorized.'
            deploymentName = $deploymentName
            changeCounts = [ordered]@{}
            recoveryIgnoreBoundary = $sourceCorrectionBoundary
            changes = @()
        }
    }
    $changes = @($rawChanges | ForEach-Object {
        [pscustomobject][ordered]@{ changeType = [string]$_.changeType; resourceId = [string]$_.resourceId }
    })
    $counts = [ordered]@{}
    foreach ($group in @($changes | Group-Object changeType | Sort-Object Name)) { $counts[[string]$group.Name] = [int]$group.Count }
    $unreviewableChanges = @($changes | Where-Object {
        [string]::IsNullOrWhiteSpace([string]$_.resourceId) -or
        [string]$_.resourceId -notmatch "^/subscriptions/$([regex]::Escape(([guid][string]$Config.subscriptionId).ToString('D')))(?:/|$)" -or
        -not (Test-GatewayRecoveryWhatIfResourceIdLexicalBoundary -ResourceId ([string]$_.resourceId) -Config $Config) -or
        [string]$_.changeType -cnotin @('Create', 'Deploy', 'Ignore')
    })
    $canonicalPairs = @($changes | ForEach-Object { "$([string]$_.changeType)|$(([string]$_.resourceId).ToLowerInvariant())" })
    if (@($canonicalPairs | Sort-Object -Unique).Count -ne $canonicalPairs.Count) {
        $unreviewableChanges += [ordered]@{ changeType = 'MalformedDuplicate'; resourceId = '' }
    }
    $canonicalResourceIds = @($changes | ForEach-Object { ([string]$_.resourceId).ToLowerInvariant() })
    if (@($canonicalResourceIds | Sort-Object -Unique).Count -ne $canonicalResourceIds.Count) {
        $unreviewableChanges += [ordered]@{ changeType = 'MalformedDuplicateResource'; resourceId = '' }
    }
    $recoveryIgnoreBoundary = $sourceCorrectionBoundary
    $recoveryFailureCode = ''
    $ignoreChanges = @($changes | Where-Object { [string]$_.changeType -ceq 'Ignore' })
    $pendingCorrectionWithoutInertEvidence = $null -ne $sourceCorrectionPlan -and
        [string]$sourceCorrectionPlan.status -ceq 'Accepted' -and
        $State.steps['Inert identity deployment'] -is [System.Collections.IDictionary] -and
        -not $State.steps['Inert identity deployment'].Contains('evidence')
    if ($pendingCorrectionWithoutInertEvidence -and $unreviewableChanges.Count -eq 0) {
        try {
            $recoveryFailureCode = 'RB15_SOURCE_CORRECTION_WRAPPER'
            $recoveryIgnoreBoundary = New-GatewayPreInertFoundationWhatIfBoundary `
                -Config $Config `
                -Foundation $State.steps['Azure foundation'].evidence `
                -SourceCorrectionBoundary $sourceCorrectionBoundary `
                -Changes $changes
            $recoveryFailureCode = ''
        }
        catch {
            $unreviewableChanges += [ordered]@{ changeType = 'UnauthorizedIgnore'; resourceId = '' }
        }
    }
    elseif ($ignoreChanges.Count -gt 0 -and $unreviewableChanges.Count -eq 0) {
        $recoveryState = Get-GatewayInertWhatIfRecoveryStateContext `
            -State $State `
            -Config $Config `
            -DeploymentOwnershipId $canonicalOwnershipId `
            -SourceFingerprint $SourceFingerprint `
            -ExecutionSourceFingerprint $ExecutionSourceFingerprint
        if ($null -eq $recoveryState) {
            $recoveryFailureCode = 'RB00_STATE_PREFIX'
            $unreviewableChanges += [ordered]@{ changeType = 'UnauthorizedIgnore'; resourceId = '' }
        }
        else {
            try {
                $recoveryFailureCode = 'RB01_IGNORE_ID_NORMALIZATION'
                [string[]]$observedIgnoreIds = @($ignoreChanges | ForEach-Object {
                    ConvertTo-GatewayRecoveryWhatIfResourceId -ResourceId ([string]$_.resourceId) -Config $Config
                })
                if (@($observedIgnoreIds | Sort-Object -Unique -CaseSensitive).Count -ne $observedIgnoreIds.Count) {
                    throw 'What-If returned duplicate normalized Ignore resource IDs.'
                }
                $recoveryFailureCode = 'RB02_GOVERNANCE_AND_TOPIC_SHAPE'
                [string[]]$expectedGovernanceNsgResourceIds = @(
                    Get-GatewayFoundationGovernanceNsgWhatIfResourceIds -Config $Config)
                [string[]]$observedGovernanceNsgResourceIds = @($observedIgnoreIds | Where-Object {
                    $expectedGovernanceNsgResourceIds -ccontains $_
                })
                [Array]::Sort($observedGovernanceNsgResourceIds, [StringComparer]::Ordinal)
                if ($observedGovernanceNsgResourceIds.Count -ne 0 -and
                    ($observedGovernanceNsgResourceIds -join "`n") -cne
                        ($expectedGovernanceNsgResourceIds -join "`n")) {
                    throw 'What-If returned only part of the deterministic foundation governance NSG pair.'
                }
                [string[]]$observedRecoveryIgnoreIds = @($observedIgnoreIds | Where-Object {
                    $expectedGovernanceNsgResourceIds -cnotcontains $_
                })
                $systemTopicPrefix = ("/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.EventGrid/systemTopics/").ToLowerInvariant()
                [string[]]$observedSystemTopicIgnoreIds = @($observedRecoveryIgnoreIds | Where-Object {
                    $_.StartsWith($systemTopicPrefix, [StringComparison]::Ordinal) -and
                    -not $_.Substring($systemTopicPrefix.Length).Contains('/', [StringComparison]::Ordinal)
                })
                if ($observedSystemTopicIgnoreIds.Count -gt 1) {
                    throw 'What-If returned more than one direct Event Grid system-topic Ignore resource.'
                }

                $sqlPrivateEndpointExtension = $null
                $additionalTypeInventoryResourceIds = $null
                if ($null -ne $recoveryState.sqlPrivateEndpoint) {
                    $recoveryFailureCode = 'RB03_SQL_PRIVATE_ENDPOINT_EVIDENCE'
                    [object[]]$extensionResults = @(Get-GatewaySqlPrivateEndpointWhatIfRecoveryExtension `
                        -Config $Config `
                        -Foundation $recoveryState.foundation `
                        -SqlServerFqdn $recoveryState.sqlServerFqdn `
                        -Evidence $recoveryState.sqlPrivateEndpoint `
                        -DeploymentOwnershipId $canonicalOwnershipId `
                        -SourceFingerprint $SourceFingerprint)
                    if ($extensionResults.Count -ne 1 -or $extensionResults[0] -isnot [System.Collections.IDictionary]) {
                        throw 'SQL private-endpoint recovery provider readback returned an invalid result envelope.'
                    }
                    $sqlPrivateEndpointExtension = $extensionResults[0]
                    $recoveryFailureCode = 'RB04_SQL_EXTENSION_CONTRACT'
                    $validatedExtension = Assert-GatewaySqlPrivateEndpointWhatIfRecoveryExtension `
                        -Extension $sqlPrivateEndpointExtension `
                        -Config $Config `
                        -DeploymentOwnershipId $canonicalOwnershipId `
                        -SourceFingerprint $SourceFingerprint
                    $additionalTypeInventoryResourceIds = $validatedExtension.typeInventoryResourceIds
                }
                $recoveryFailureCode = 'RB05_INERT_PROVIDER_BOUNDARY'
                [object[]]$recoveryResults = @(Get-GatewayInertWhatIfRecoveryBoundary `
                    -Config $Config `
                    -Foundation $recoveryState.foundation `
                    -Identity $recoveryState.identity `
                    -ApiImage $recoveryState.apiImage `
                    -WorkerImage $recoveryState.workerImage `
                    -DeploymentOwnershipId $canonicalOwnershipId `
                    -SourceFingerprint $SourceFingerprint `
                    -ExecutionSourceFingerprint $ExecutionSourceFingerprint `
                    -AdditionalTypeInventoryResourceIds $additionalTypeInventoryResourceIds)
                if ($recoveryResults.Count -ne 1 -or $recoveryResults[0] -isnot [System.Collections.IDictionary]) {
                    throw 'Recovery provider readback returned an invalid result envelope.'
                }
                $recovery = $recoveryResults[0]
                Assert-GatewayExactDictionaryKeys -Value $recovery -ExpectedKeys @('evidence', 'boundary') -Label 'Recovery provider readback' | Out-Null
                if ($null -eq $recovery.evidence -or $recovery.boundary -isnot [System.Collections.IDictionary]) {
                    throw 'Recovery provider readback is incomplete.'
                }
                $recoveryFailureCode = 'RB06_INERT_DEPLOYMENT_EVIDENCE'
                [object[]]$deploymentValidation = @(Test-GatewayGroupDeploymentEvidence `
                    -Config $Config `
                    -Foundation $recoveryState.foundation `
                    -Identity $recoveryState.identity `
                    -Evidence $recovery.evidence `
                    -DeploymentOwnershipId $canonicalOwnershipId `
                    -SourceFingerprint $SourceFingerprint `
                    -ApiImage $recoveryState.apiImage `
                    -WorkerImage $recoveryState.workerImage)
                if ($deploymentValidation.Count -ne 1 -or $deploymentValidation[0] -isnot [bool] -or
                    $deploymentValidation[0] -ne $true) {
                    throw 'Recovered inert deployment evidence failed exact independent validation.'
                }
                $recoveryFailureCode = 'RB07_INERT_TYPED_BOUNDARY'
                [string[]]$expectedIgnoreIds = @(Assert-GatewayInertWhatIfRecoveryBoundary `
                    -Boundary $recovery.boundary `
                    -Config $Config `
                    -DeploymentOwnershipId $canonicalOwnershipId `
                    -SourceFingerprint $SourceFingerprint)
                $resolvedRecoveryBoundary = $recovery.boundary
                if ($null -ne $sqlPrivateEndpointExtension) {
                    $recoveryFailureCode = 'RB08_SQL_STATE_AWARE_MERGE'
                    [string[]]$sqlPrivateEndpointResourceIds = @($validatedExtension.resourceIds)
                    $resolvedRecoveryBoundary = New-GatewayStateAwareWhatIfRecoveryBoundary `
                        -InertBoundary $recovery.boundary `
                        -SqlPrivateEndpointExtension $sqlPrivateEndpointExtension `
                        -InertResourceIds $expectedIgnoreIds `
                        -SqlPrivateEndpointResourceIds $sqlPrivateEndpointResourceIds `
                        -DeploymentOwnershipId $canonicalOwnershipId `
                        -SourceFingerprint $SourceFingerprint
                    $expectedIgnoreIds = @($resolvedRecoveryBoundary.resourceIds)
                }

                $recoveryFailureCode = 'RB09_DEFENDER_STORAGE_PROVIDER'
                [object[]]$defenderStorageResults = @(Get-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                    -Config $Config `
                    -StorageAccountId ([string]$recovery.evidence.storageAccountId) `
                    -DeploymentOwnershipId $canonicalOwnershipId `
                    -SourceFingerprint $SourceFingerprint)
                if ($defenderStorageResults.Count -ne 1 -or
                    $defenderStorageResults[0] -isnot [System.Collections.IDictionary]) {
                    throw 'Defender Storage recovery provider readback returned an invalid result envelope.'
                }
                $defenderStorageExtension = $defenderStorageResults[0]
                $recoveryFailureCode = 'RB10_DEFENDER_STORAGE_EXTENSION_CONTRACT'
                $validatedDefenderStorageExtension = Assert-GatewayDefenderStorageSystemTopicWhatIfRecoveryExtension `
                    -Extension $defenderStorageExtension `
                    -Config $Config `
                    -StorageAccountId ([string]$recovery.evidence.storageAccountId) `
                    -DeploymentOwnershipId $canonicalOwnershipId `
                    -SourceFingerprint $SourceFingerprint
                [string[]]$validatedDefenderStorageResourceIds = @($validatedDefenderStorageExtension.resourceIds)
                $recoveryFailureCode = 'RB11_DEFENDER_OBSERVED_PROVIDER_MATCH'
                if ($observedSystemTopicIgnoreIds.Count -ne $validatedDefenderStorageResourceIds.Count -or
                    ($observedSystemTopicIgnoreIds.Count -eq 1 -and
                    $observedSystemTopicIgnoreIds[0] -cne $validatedDefenderStorageResourceIds[0])) {
                    throw 'What-If and provider readback disagree about the exact Defender Storage system-topic presence.'
                }
                $recoveryFailureCode = 'RB12_DEFENDER_AWARE_MERGE'
                $resolvedRecoveryBoundary = New-GatewayDefenderStorageAwareWhatIfRecoveryBoundary `
                    -BaseBoundary $resolvedRecoveryBoundary `
                    -DefenderStorageExtension $defenderStorageExtension `
                    -BaseResourceIds $expectedIgnoreIds `
                    -DefenderStorageResourceIds $validatedDefenderStorageResourceIds `
                    -DeploymentOwnershipId $canonicalOwnershipId `
                    -SourceFingerprint $SourceFingerprint
                $expectedIgnoreIds = @($resolvedRecoveryBoundary.resourceIds)
                $recoveryFailureCode = 'RB13_EXACT_OBSERVED_GRAPH_MATCH'
                [Array]::Sort($observedRecoveryIgnoreIds, [StringComparer]::Ordinal)
                if ($observedRecoveryIgnoreIds.Count -ne $expectedIgnoreIds.Count -or
                    ($observedRecoveryIgnoreIds -join "`n") -cne ($expectedIgnoreIds -join "`n")) {
                    throw 'What-If Ignore predictions did not exactly match the recovered state-aware resource graph.'
                }
                if ($observedGovernanceNsgResourceIds.Count -eq 2) {
                    $recoveryFailureCode = 'RB14_GOVERNANCE_AWARE_MERGE'
                    $resolvedRecoveryBoundary = New-GatewayFoundationGovernanceNsgAwareWhatIfRecoveryBoundary `
                        -Config $Config `
                        -BaseBoundary $resolvedRecoveryBoundary `
                        -BaseResourceIds $expectedIgnoreIds `
                        -GovernanceNsgResourceIds $observedGovernanceNsgResourceIds `
                        -DeploymentOwnershipId $canonicalOwnershipId `
                        -SourceFingerprint $SourceFingerprint
                }
                $recoveryFailureCode = 'RB15_SOURCE_CORRECTION_WRAPPER'
                $recoveryIgnoreBoundary = if ($null -ne $sourceCorrectionPlan -and
                    [string]$sourceCorrectionPlan.status -ceq 'Accepted') {
                    New-GatewayPendingSourceCorrectionRecoveryWhatIfBoundary `
                        -SourceCorrectionBoundary $sourceCorrectionBoundary `
                        -RecoveryBoundary $resolvedRecoveryBoundary
                }
                elseif ($null -ne $sourceCorrectionPlan -and
                    [string]$sourceCorrectionPlan.status -ceq 'Completed') {
                    New-GatewaySourceCorrectionAwareWhatIfBoundary `
                        -CorrectionPlan $sourceCorrectionPlan `
                        -RecoveryBoundary $resolvedRecoveryBoundary `
                        -DeploymentOwnershipId $canonicalOwnershipId `
                        -DeploymentSourceFingerprint $SourceFingerprint `
                        -ExecutionSourceFingerprint $ExecutionSourceFingerprint
                }
                else {
                    $resolvedRecoveryBoundary
                }
                $recoveryFailureCode = ''
            }
            catch {
                if ([string]::IsNullOrWhiteSpace($recoveryFailureCode)) {
                    $recoveryFailureCode = 'RB99_UNEXPECTED_TERMINATING_ERROR'
                }
                $unreviewableChanges += [ordered]@{ changeType = 'UnauthorizedIgnore'; resourceId = '' }
            }
        }
    }
    elseif ($null -ne $sourceCorrectionPlan -and
        [string]$sourceCorrectionPlan.status -ceq 'Accepted' -and
        $unreviewableChanges.Count -eq 0) {
        $unreviewableChanges += [ordered]@{ changeType = 'UnauthorizedIgnore'; resourceId = '' }
    }
    return [ordered]@{
        executed = $true
        applyReady = $unreviewableChanges.Count -eq 0
        reason = if ($unreviewableChanges.Count -gt 0) { 'What-If reported a deletion, unsupported prediction, or malformed resource change. Bootstrap has no destroy mode and will not accept this plan.' } else { '' }
        deploymentName = $deploymentName
        changeCounts = $counts
        recoveryIgnoreBoundary = $recoveryIgnoreBoundary
        recoveryFailureCode = if ($unreviewableChanges.Count -gt 0) { $recoveryFailureCode } else { '' }
        changes = $changes
    }
}

function Invoke-GatewayDatabaseRecoveryWhatIf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$ExpectedPrivateEndpointIpv4Address,
        [Parameter(Mandatory)][string]$DatabaseMigratorImageDigest,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$OriginalAcceptedSourceFingerprint,
        [Parameter(Mandatory)][string]$RecoverySourceFingerprint,
        [Parameter(Mandatory)][string]$RecoveryPlanFingerprint,
        [Parameter(Mandatory)][string]$RecoveryExecutionIntentId,
        [ValidateSet(1, 2)][int]$RecoveryAttemptNumber = 1,
        [Parameter(Mandatory)][string]$OriginalFailedDatabaseBoundaryFingerprint,
        [Parameter()][string]$PriorFailedRecoveryBoundaryFingerprint = '',
        [Parameter(Mandatory)]$ApiPrincipal,
        [Parameter(Mandatory)]$WorkerPrincipal
    )

    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    $canonicalIntentId = ([guid]$RecoveryExecutionIntentId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId -or
        $RecoveryExecutionIntentId -cne $canonicalIntentId -or [guid]$canonicalIntentId -eq [guid]::Empty -or
        $DatabaseMigratorImageDigest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'The database recovery What-If ownership, image, or execution intent boundary is malformed.'
    }
    foreach ($fingerprint in @($OriginalAcceptedSourceFingerprint, $RecoverySourceFingerprint, $RecoveryPlanFingerprint)) {
        Assert-BootstrapFingerprintValue -Value $fingerprint -Label 'Database recovery What-If fingerprint'
    }
    Assert-BootstrapFingerprintValue -Value $OriginalFailedDatabaseBoundaryFingerprint -Label 'Original failed database boundary fingerprint'
    if ($RecoveryAttemptNumber -eq 2) {
        Assert-BootstrapFingerprintValue -Value $PriorFailedRecoveryBoundaryFingerprint -Label 'Prior failed recovery boundary fingerprint'
    }
    Assert-BootstrapIpv4Value -Value $ExpectedPrivateEndpointIpv4Address -Label 'Database recovery private endpoint IPv4 address'
    $recoveryContract = Get-GatewayDatabaseRecoveryAttemptContract -Config $Config -AttemptNumber $RecoveryAttemptNumber
    $jobName = [string]$recoveryContract.jobName
    $deploymentName = [string]$recoveryContract.whatIfDeploymentName
    $result = Invoke-AzJson -Arguments @(
        'deployment', 'group', 'what-if',
        '--resource-group', [string]$Config.resourceGroupName,
        '--name', $deploymentName,
        '--template-file', (Join-Path $RepositoryRoot 'bootstrap/infra/database-migrator-recovery-job.bicep'),
        '--parameters',
        "location=$($Config.location)",
        "environment=$($Config.environment)",
        "projectName=$($Config.projectName)",
        "containerAppsEnvironmentId=$($Foundation.containerAppsEnvironmentId)",
        "databaseMigratorImageDigest=$DatabaseMigratorImageDigest",
        "acrLoginServer=$($Foundation.acrLoginServer)",
        "imagePullIdentityResourceId=$($Foundation.runtimeImagePullIdentityId)",
        "sqlServerFqdn=$SqlServerFqdn",
        "expectedPrivateEndpointIp=$ExpectedPrivateEndpointIpv4Address",
        "deploymentOwnershipId=$canonicalOwnershipId",
        "originalAcceptedSourceFingerprint=$OriginalAcceptedSourceFingerprint",
        "recoverySourceFingerprint=$RecoverySourceFingerprint",
        "recoveryPlanFingerprint=$RecoveryPlanFingerprint",
        "recoveryExecutionIntentId=$canonicalIntentId",
        "recoveryAttemptNumber=$RecoveryAttemptNumber",
        "originalFailedDatabaseBoundaryFingerprint=$OriginalFailedDatabaseBoundaryFingerprint",
        "priorFailedRecoveryBoundaryFingerprint=$PriorFailedRecoveryBoundaryFingerprint",
        "apiDatabasePrincipalName=$($ApiPrincipal.displayName)",
        "apiDatabasePrincipalClientId=$(([guid][string]$ApiPrincipal.clientId).ToString('D'))",
        "workerDatabasePrincipalName=$($WorkerPrincipal.displayName)",
        "workerDatabasePrincipalClientId=$(([guid][string]$WorkerPrincipal.clientId).ToString('D'))",
        'replicaTimeoutSeconds=1800',
        '--result-format', 'ResourceIdOnly',
        '--no-pretty-print'
    )
    $isDictionary = $result -is [System.Collections.IDictionary]
    $isObject = $isDictionary -or ($null -ne $result -and $result.GetType() -eq [System.Management.Automation.PSCustomObject])
    if (-not $isObject) { throw 'Database recovery What-If returned no exact result object.' }
    $status = if ($isDictionary) { [string]$result['status'] } else { [string]$result.status }
    $errorValue = if ($isDictionary) {
        if ($result.Contains('error')) { $result['error'] } else { $null }
    } else {
        if ($result.PSObject.Properties['error']) { $result.error } else { $null }
    }
    $topChanges = if ($isDictionary) {
        if ($result.Contains('changes')) { $result['changes'] } else { $null }
    } else {
        if ($result.PSObject.Properties['changes']) { $result.changes } else { $null }
    }
    $properties = if ($isDictionary) {
        if ($result.Contains('properties')) { $result['properties'] } else { $null }
    } else {
        if ($result.PSObject.Properties['properties']) { $result.properties } else { $null }
    }
    $nestedChanges = if ($properties -is [System.Collections.IDictionary]) {
        if ($properties.Contains('changes')) { $properties['changes'] } else { $null }
    } elseif ($null -ne $properties -and $properties.PSObject.Properties['changes']) { $properties.changes } else { $null }
    $topPresent = $null -ne $topChanges
    $nestedPresent = $null -ne $nestedChanges
    if ($status -cne 'Succeeded' -or $null -ne $errorValue -or ([int]$topPresent + [int]$nestedPresent) -ne 1) {
        throw 'Database recovery What-If returned a failed, ambiguous, or malformed contract.'
    }
    $rawChanges = if ($topPresent) { $topChanges } else { $nestedChanges }
    if ($rawChanges -isnot [System.Array] -and $rawChanges -isnot [System.Collections.IList]) {
        throw 'Database recovery What-If changes were not an exact array.'
    }
    $changes = @($rawChanges | ForEach-Object {
        [ordered]@{ changeType = [string]$_.changeType; resourceId = ([string]$_.resourceId).ToLowerInvariant() }
    } | Sort-Object resourceId, changeType)
    $expectedJobId = ("/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.App/jobs/$jobName").ToLowerInvariant()
    $resourceGroupPrefix = ("/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/").ToLowerInvariant()
    $creates = @($changes | Where-Object { [string]$_.changeType -ceq 'Create' })
    $unsafe = @($changes | Where-Object {
        ([string]$_.changeType -cne 'Create' -and [string]$_.changeType -cne 'Ignore') -or
        -not ([string]$_.resourceId).StartsWith($resourceGroupPrefix, [StringComparison]::Ordinal) -or
        ([string]$_.changeType -ceq 'Ignore' -and [string]$_.resourceId -ceq $expectedJobId)
    })
    if ($creates.Count -ne 1 -or
        [string]$creates[0].resourceId -cne $expectedJobId -or
        $unsafe.Count -ne 0) {
        throw 'Database recovery What-If must contain exactly one Create for the distinct recovery Job; every existing resource may appear only as an in-scope Ignore.'
    }
    return [ordered]@{
        executed = $true
        applyReady = $true
        deploymentName = $deploymentName
        jobName = $jobName
        changes = $changes
        changeFingerprint = Get-BootstrapObjectFingerprint -InputObject $changes
    }
}

function Show-GatewayPlan {
    param(
        [Parameter(Mandatory)]$Descriptor,
        [Parameter(Mandatory)]$SourceValidation,
        [Parameter(Mandatory)]$WhatIf,
        [Parameter(Mandatory)][string]$PlanFingerprint,
        [Parameter(Mandatory)][string]$ConfigurationFingerprint,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text',
        [switch]$EventStreamOnly
    )

    $result = [ordered]@{
        schemaVersion = 1
        plannedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        planFingerprint = $PlanFingerprint
        configurationFingerprint = $ConfigurationFingerprint
        sourceFingerprint = $SourceFingerprint
        applyReady = [bool]$WhatIf.applyReady
        descriptor = $Descriptor
        sourceValidation = $SourceValidation
        azureFoundationWhatIf = $WhatIf
    }
    if ($OutputFormat -eq 'Json') {
        if (-not $EventStreamOnly) { Write-GatewayResult -Value $result -OutputFormat Json }
        return $result
    }

    Write-Host ''
    Write-Host "Deployment plan: $($Descriptor.deploymentId)" -ForegroundColor Cyan
    Write-Host "Tenant/subscription: $($Descriptor.scope.tenantId) / $($Descriptor.scope.subscriptionId)"
    Write-Host "Region/resource group: $($Descriptor.scope.location) / $($Descriptor.scope.resourceGroupName)"
    Write-Host "Legacy SQL bootstrap IPv4 metadata (unused by the private job): $($Descriptor.scope.sqlBootstrapClientIpv4)"
    Write-Host "Plan fingerprint: $PlanFingerprint"
    Write-Host "Configuration fingerprint: $ConfigurationFingerprint"
    Write-Host "Source fingerprint: $SourceFingerprint"
    Write-Host ''
    Write-Host 'Azure resource families' -ForegroundColor Cyan
    foreach ($resource in $Descriptor.azureResources) { Write-Host "  - $resource" }
    Write-Host ''
    Write-Host 'Imperative operation manifest' -ForegroundColor Cyan
    foreach ($operation in $Descriptor.imperativeOperations) {
        $kind = if ($operation.mutation) { 'mutation' } else { 'read-only' }
        Write-Host "  - [$kind] $($operation.system): $($operation.operation)"
    }
    Write-Host ''
    Write-Host 'Administrator checkpoints' -ForegroundColor Cyan
    foreach ($boundary in $Descriptor.administratorBoundaries) { Write-Host "  - $boundary" }
    Write-Host ''
    Write-Host 'Cost and preview boundaries' -ForegroundColor Cyan
    foreach ($cost in $Descriptor.costClasses) { Write-Host "  - $cost" }
    Write-Host "  - $($Descriptor.previewWarning)" -ForegroundColor Yellow
    Write-Host '  - No destroy, retained-message access, Registry replay, or historical cleanup is included.'
    Write-Host ''
    Write-Host 'Not checked by this plan' -ForegroundColor Cyan
    foreach ($limitation in $Descriptor.preflightLimitations) { Write-Host "  - $limitation" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host "Bicep compiled: $($SourceValidation.compiledTemplates.Count)/$($SourceValidation.compiledTemplates.Count) bootstrap templates ($($SourceValidation.bicepVersion))" -ForegroundColor Green
    if ($WhatIf.executed) {
        Write-Host 'Azure subscription-scope What-If completed.' -ForegroundColor Green
        if ($WhatIf.changeCounts.Count -eq 0) { Write-Host '  No ARM changes were reported.' }
        else { foreach ($entry in $WhatIf.changeCounts.GetEnumerator()) { Write-Host "  $($entry.Key): $($entry.Value)" } }
        foreach ($change in @($WhatIf.changes | Sort-Object resourceId, changeType)) {
            Write-Host "  - $($change.changeType): $($change.resourceId)"
        }
        if (-not $WhatIf.applyReady) {
            Write-Host "Plan blocked: $($WhatIf.reason)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Azure What-If not run: $($WhatIf.reason)" -ForegroundColor Yellow
        Write-Host 'This source-only plan is not apply-ready. Sign in and rerun Plan.' -ForegroundColor Yellow
    }
    return $result
}

function Test-GatewayHttpsUrl {
    param([Parameter(Mandatory)][string]$Url)
    $uri = $null
    return [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -and
        $uri.Scheme -eq 'https' -and
        [string]::IsNullOrWhiteSpace($uri.UserInfo) -and
        [string]::IsNullOrWhiteSpace($uri.Query) -and
        [string]::IsNullOrWhiteSpace($uri.Fragment)
}

function Get-GatewayBootstrapStatus {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath
    )

    $stepRows = [Collections.Generic.List[object]]::new()
    foreach ($name in $script:GatewayBootstrapSteps) {
        $record = $State.steps[$name]
        $status = if ($record) { [string]$record.status } else { 'Pending' }
        $timestamp = if ($record -and $record.Contains('completedAtUtc')) { [string]$record.completedAtUtc } elseif ($record -and $record.Contains('failedAtUtc')) { [string]$record.failedAtUtc } elseif ($record -and $record.Contains('startedAtUtc')) { [string]$record.startedAtUtc } else { '' }
        $stepRows.Add([ordered]@{ name = $name; status = $status; timestampUtc = $timestamp })
    }
    $completed = @($stepRows | Where-Object status -eq 'Completed').Count
    $failed = @($stepRows | Where-Object status -eq 'Failed')
    $running = @($stepRows | Where-Object status -eq 'Running')
    $next = @($stepRows | Where-Object status -eq 'Pending' | Select-Object -First 1)
    $overall = if ($failed.Count -gt 0) { 'NeedsAttention' } elseif ($completed -eq $script:GatewayBootstrapSteps.Count) { 'Verified' } elseif ($running.Count -gt 0) { 'InProgress' } elseif ($completed -gt 0) { 'Paused' } else { 'NotStarted' }

    $adminUiUrl = ''
    $apiUrl = ''
    if ($State.outputs.Contains('adminUiUrl') -and (Test-GatewayHttpsUrl -Url ([string]$State.outputs.adminUiUrl))) { $adminUiUrl = [string]$State.outputs.adminUiUrl }
    if ($State.outputs.Contains('apiUrl') -and (Test-GatewayHttpsUrl -Url ([string]$State.outputs.apiUrl))) { $apiUrl = [string]$State.outputs.apiUrl }
    $verification = if ($State.outputs.Contains('verification')) { $State.outputs.verification } else { $null }
    $verificationStep = $State.steps['End-to-end deployment verification']
    $verificationIsCurrent = $verification -and
        $verification -is [System.Collections.IDictionary] -and
        $verificationStep -and [string]$verificationStep.status -eq 'Completed' -and
        $verificationStep.evidence -is [System.Collections.IDictionary] -and
        [string]$verificationStep.evidence.verifiedAtUtc -ceq [string]$verification.verifiedAtUtc

    $infrastructureReady = $State.steps['Azure foundation'] -and [string]$State.steps['Azure foundation'].status -eq 'Completed'
    $controlPlaneReady = $verificationIsCurrent -and
        $State.steps['Network hardening'] -and [string]$State.steps['Network hardening'].status -eq 'Completed' -and
        $State.steps['Network hardening'].evidence -is [System.Collections.IDictionary] -and
        $State.steps['Network hardening'].evidence.exactPostMutationReadback -eq $true -and
        -not [string]::IsNullOrWhiteSpace($adminUiUrl)
    $provisioningReady = $verificationIsCurrent -and
        $verification.Contains('provisioningAdmissionReady') -and $verification.provisioningAdmissionReady -eq $true -and
        $verification.Contains('registrationMode') -and [string]$verification.registrationMode -ceq 'ContinuousDevelopmentPreview' -and
        $verification.Contains('provisioningPreflight') -and [string]$verification.provisioningPreflight -ceq 'ExecutionReadyPassed'
    return [ordered]@{
        schemaVersion = 1
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        deploymentId = "$($Config.projectName)-$($Config.environment)"
        deploymentKey = [string]$State.deploymentKey
        statePath = $StatePath
        statusBasis = 'PersistedBootstrapCheckpoint'
        liveReadbackPerformed = $false
        overallStatus = $overall
        progressPercent = [math]::Floor(($completed / $script:GatewayBootstrapSteps.Count) * 100)
        completedSteps = $completed
        totalSteps = $script:GatewayBootstrapSteps.Count
        nextStep = if ($failed.Count -gt 0) { [string]$failed[0].name } elseif ($running.Count -gt 0) { [string]$running[0].name } elseif ($next.Count -gt 0) { [string]$next[0].name } else { '' }
        readiness = [ordered]@{
            InfrastructureReady = [bool]$infrastructureReady
            ControlPlaneReady = [bool]$controlPlaneReady
            ProvisioningReady = [bool]$provisioningReady
            ProvisioningAdmission = if ($provisioningReady) { 'OpenDevelopmentPreview' } else { 'ClosedOrNotVerified' }
        }
        endpoints = [ordered]@{ adminUi = $adminUiUrl; api = $apiUrl }
        steps = @($stepRows)
    }
}

function Show-GatewayBootstrapStatus {
    param([Parameter(Mandatory)]$Status, [ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text')
    if ($OutputFormat -eq 'Json') { Write-GatewayResult -Value $Status -OutputFormat Json; return }

    Write-Host ''
    Write-Host "Gateway status: $($Status.deploymentId)" -ForegroundColor Cyan
    Write-Host "$($Status.overallStatus) — $($Status.completedSteps)/$($Status.totalSteps) steps ($($Status.progressPercent)%)"
    Write-Host 'Basis: persisted local checkpoints only; run gateway verify for current live readback.' -ForegroundColor DarkGray
    foreach ($step in $Status.steps) {
        $symbol = switch ([string]$step.status) { 'Completed' { '[ok]' }; 'Failed' { '[xx]' }; 'Running' { '[->]' }; default { '[  ]' } }
        $color = switch ([string]$step.status) { 'Completed' { 'Green' }; 'Failed' { 'Red' }; 'Running' { 'Cyan' }; default { 'DarkGray' } }
        Write-Host "$symbol $($step.name)" -ForegroundColor $color
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Status.nextStep)) { Write-Host "Next: $($Status.nextStep)" }
    if (-not [string]::IsNullOrWhiteSpace([string]$Status.endpoints.adminUi)) { Write-Host "Admin UI: $($Status.endpoints.adminUi)" }
    Write-Host 'Creating and activating a registration is a post-deployment use task.' -ForegroundColor DarkGray
}

function Open-GatewayAdminUi {
    param([Parameter(Mandatory)]$Status)

    $url = [string]$Status.endpoints.adminUi
    if ($Status.readiness.ControlPlaneReady -ne $true -or
        [string]::IsNullOrWhiteSpace($url) -or
        -not (Test-GatewayHttpsUrl -Url $url)) {
        throw 'No verified HTTPS Admin UI endpoint is recorded. Run gateway verify first.'
    }
    Start-Process $url
    return [ordered]@{ opened = $true; adminUiUrl = $url }
}

function Write-GatewayDiagnosticBundle {
    param(
        [Parameter()][AllowNull()]$Config,
        [Parameter(Mandatory)]$Doctor,
        [Parameter()][AllowNull()]$Status,
        [Parameter()][ValidateSet('Validated', 'Missing', 'Invalid', 'StateUnavailable', 'Unavailable')]
        [string]$ConfigurationStatus = '',
        [Parameter()][string]$Path = ''
    )

    $root = Get-RepositoryRoot
    $hasConfiguration = $null -ne $Config
    if ([string]::IsNullOrWhiteSpace($ConfigurationStatus)) {
        $ConfigurationStatus = if ($hasConfiguration) { 'Validated' } else { 'Unavailable' }
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $prefix = if ($hasConfiguration) { "$($Config.projectName)-$($Config.environment)" } else { 'gateway-diagnose' }
        $Path = Join-Path $root ".bootstrap/diagnostics/$prefix-$([DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')).json"
    }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $resolvedPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $commit = Get-GatewayCommandVersion -Name 'git' -Arguments @('-C', $root, 'rev-parse', 'HEAD')
    $dirty = $false
    try { $dirty = -not [string]::IsNullOrWhiteSpace((& git -C $root status --porcelain 2>$null | Out-String).Trim()) } catch { }
    $safeDoctorChecks = @($Doctor.checks | ForEach-Object {
        [ordered]@{
            name = [string]$_.name
            status = [string]$_.status
            value = if ([string]$_.name -eq 'Configuration') { 'Present/validated status only; local path omitted' } else { ConvertTo-GatewaySafeDisplayText -Value $_.value -MaximumLength 160 }
            remediation = ConvertTo-GatewaySafeDisplayText -Value $_.remediation -MaximumLength 240
        }
    })
    $safeDeployment = if ($hasConfiguration) {
        [ordered]@{
            available = $true
            configurationStatus = $ConfigurationStatus
            id = "$($Config.projectName)-$($Config.environment)"
            tenantId = [string]$Config.tenantId
            subscriptionId = [string]$Config.subscriptionId
            resourceGroupName = [string]$Config.resourceGroupName
            location = [string]$Config.location
        }
    }
    else {
        [ordered]@{
            available = $false
            configurationStatus = $ConfigurationStatus
            id = 'Unavailable'
        }
    }
    $safeStatus = if ($null -ne $Status) {
        [ordered]@{
            statusBasis = $Status.statusBasis
            liveReadbackPerformed = [bool]$Status.liveReadbackPerformed
            overallStatus = $Status.overallStatus
            progressPercent = $Status.progressPercent
            completedSteps = $Status.completedSteps
            totalSteps = $Status.totalSteps
            nextStep = $Status.nextStep
            readiness = $Status.readiness
            endpoints = $Status.endpoints
            steps = $Status.steps
        }
    }
    else {
        [ordered]@{
            statusBasis = 'ConfigurationUnavailable'
            liveReadbackPerformed = $false
            overallStatus = 'Unavailable'
            progressPercent = 0
            completedSteps = 0
            totalSteps = $script:GatewayBootstrapSteps.Count
            nextStep = 'Configuration'
            readiness = [ordered]@{
                InfrastructureReady = $false
                ControlPlaneReady = $false
                ProvisioningReady = $false
                ProvisioningAdmission = 'ClosedOrNotVerified'
            }
            endpoints = [ordered]@{ adminUi = ''; api = '' }
            steps = @()
        }
    }
    $bundle = [ordered]@{
        schemaVersion = 1
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        deployment = $safeDeployment
        source = [ordered]@{ commit = $commit; workingTreeDirty = $dirty }
        doctor = [ordered]@{
            checkedAtUtc = [string]$Doctor.checkedAtUtc
            readyForPlan = [bool]$Doctor.readyForPlan
            readyForApply = [bool]$Doctor.readyForApply
            failures = [int]$Doctor.failures
            warnings = [int]$Doctor.warnings
            notChecked = [int]$Doctor.notChecked
            checks = $safeDoctorChecks
        }
        status = $safeStatus
        exclusions = @('credentials', 'tokens', 'assertions', 'authorization headers', 'Gateway keys', 'prompts', 'responses', 'raw dependency bodies')
    }
    $temporaryPath = Join-Path $directory ".$([IO.Path]::GetFileName($resolvedPath)).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $bundle | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporaryPath -Encoding utf8NoBOM
        Move-Item -LiteralPath $temporaryPath -Destination $resolvedPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
    return [ordered]@{ diagnosticPath = $resolvedPath; safeFieldsOnly = $true; bundle = $bundle }
}

function Test-GatewayResourceProviderEvidence {
    foreach ($provider in @(
        'Microsoft.AlertsManagement', 'Microsoft.App', 'Microsoft.ContainerRegistry', 'Microsoft.EventGrid', 'Microsoft.Insights', 'Microsoft.KeyVault',
        'Microsoft.ManagedIdentity', 'Microsoft.Network', 'Microsoft.OperationalInsights',
        'Microsoft.ServiceBus', 'Microsoft.Sql', 'Microsoft.Storage'
    )) {
        try {
            $registrationState = Invoke-AzTsv -Arguments @('provider', 'show', '--namespace', $provider, '--query', 'registrationState')
            if ($registrationState -ne 'Registered') { throw 'mismatch' }
        }
        catch { throw 'Resource-provider revalidation was unavailable or mismatched; refusing automatic replay. Review access/policy and run gateway diagnose.' }
    }
    return $true
}

function Assert-GatewayRuntimeImagePullIdentityEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$ExpectedRegistryId,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    try {
        $subscriptionId = ([guid][string]$Config.subscriptionId).ToString('D')
        $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
        Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Runtime image-pull identity source fingerprint'
        if ([string]$Config.subscriptionId -cne $subscriptionId -or
            $DeploymentOwnershipId -cne $canonicalOwnershipId) {
            throw 'mismatch'
        }

        $resourceGroupScope = "/subscriptions/$subscriptionId/resourceGroups/$($Config.resourceGroupName)"
        $registryPrefix = "$resourceGroupScope/providers/Microsoft.ContainerRegistry/registries/"
        $registryId = $ExpectedRegistryId.TrimEnd('/')
        if ($ExpectedRegistryId -cne $registryId -or
            -not $registryId.StartsWith($registryPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            $registryId.Substring($registryPrefix.Length) -cnotmatch '^[A-Za-z0-9]{5,50}$') {
            throw 'mismatch'
        }
        $registryName = $registryId.Substring($registryPrefix.Length)

        $identityName = "id-gateway-runtime-pull-$($Config.environment)"
        $expectedIdentityId = "$resourceGroupScope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$identityName"
        $identityId = [string](Get-GatewayOptionalObjectProperty -Object $Evidence -Name 'runtimeImagePullIdentityId')
        $principalId = [string](Get-GatewayOptionalObjectProperty -Object $Evidence -Name 'runtimeImagePullIdentityPrincipalId')
        $roleAssignmentId = [string](Get-GatewayOptionalObjectProperty -Object $Evidence -Name 'runtimeImagePullAcrPullRoleAssignmentId')
        $parsedPrincipalId = [guid]::Empty
        if (-not $identityId.Equals($expectedIdentityId, [StringComparison]::OrdinalIgnoreCase) -or
            -not [guid]::TryParse($principalId, [ref]$parsedPrincipalId) -or
            $parsedPrincipalId -eq [guid]::Empty -or
            $principalId -cne $parsedPrincipalId.ToString('D')) {
            throw 'mismatch'
        }

        $roleAssignmentPrefix = "$registryId/providers/Microsoft.Authorization/roleAssignments/"
        $roleAssignmentGuidText = if ($roleAssignmentId.StartsWith($roleAssignmentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $roleAssignmentId.Substring($roleAssignmentPrefix.Length)
        }
        else { '' }
        $parsedRoleAssignmentId = [guid]::Empty
        if (-not [guid]::TryParse($roleAssignmentGuidText, [ref]$parsedRoleAssignmentId) -or
            $parsedRoleAssignmentId -eq [guid]::Empty -or
            $roleAssignmentGuidText -cne $parsedRoleAssignmentId.ToString('D')) {
            throw 'mismatch'
        }

        $identity = Invoke-AzJson -Arguments @(
            'identity', 'show', '--subscription', $subscriptionId,
            '--resource-group', [string]$Config.resourceGroupName, '--name', $identityName,
            '--query', '{id:id,name:name,principalId:principalId,type:type,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
        )
        if (-not ([string]$identity.id).Equals($expectedIdentityId, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$identity.name -cne $identityName -or
            [string]$identity.principalId -cne $principalId -or
            [string]$identity.type -cne 'Microsoft.ManagedIdentity/userAssignedIdentities' -or
            [string]$identity.ownershipId -cne $canonicalOwnershipId -or
            [string]$identity.sourceFingerprint -cne $SourceFingerprint) {
            throw 'mismatch'
        }

        $assignments = @(Invoke-AzJsonArray `
            -OperationLabel 'Runtime image-pull identity AcrPull readback' `
            -Arguments @(
                'role', 'assignment', 'list', '--subscription', $subscriptionId,
                '--assignee-object-id', $principalId, '--scope', $registryId, '--include-inherited',
                '--fill-principal-name', 'false', '--fill-role-definition-name', 'false',
                '--query', '[].{id:id,principalId:principalId,principalType:principalType,scope:scope,roleDefinitionId:roleDefinitionId,condition:condition,conditionVersion:conditionVersion,delegatedManagedIdentityResourceId:delegatedManagedIdentityResourceId}'
            ))
        $acrPullRoleId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/7f951dda-4ed3-4680-a7ca-43fe172d538d"
        if ($assignments.Count -ne 1 -or
            -not ([string]$assignments[0].id).Equals($roleAssignmentId, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$assignments[0].principalId).Equals($principalId, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$assignments[0].principalType -cne 'ServicePrincipal' -or
            -not ([string]$assignments[0].scope).Equals($registryId, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$assignments[0].roleDefinitionId).Equals($acrPullRoleId, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::IsNullOrWhiteSpace([string](Get-GatewayOptionalObjectProperty -Object $assignments[0] -Name 'condition')) -or
            -not [string]::IsNullOrWhiteSpace([string](Get-GatewayOptionalObjectProperty -Object $assignments[0] -Name 'conditionVersion')) -or
            -not [string]::IsNullOrWhiteSpace([string](Get-GatewayOptionalObjectProperty -Object $assignments[0] -Name 'delegatedManagedIdentityResourceId'))) {
            throw 'mismatch'
        }

        # The typed `az acr show` projection in Azure CLI 2.89.1 omits
        # azureADAuthenticationAsArmPolicy even when ARM has persisted it. Read the
        # exact registry resource at the same reviewed API version used by Bicep.
        $registry = Invoke-AzJson -Arguments @(
            'resource', 'show', '--subscription', $subscriptionId,
            '--ids', $registryId, '--api-version', '2023-11-01-preview',
            '--query', '{id:id,name:name,adminUserEnabled:properties.adminUserEnabled,armAudienceStatus:properties.policies.azureADAuthenticationAsArmPolicy.status,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
        )
        if (-not ([string]$registry.id).Equals($registryId, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$registry.name -cne $registryName -or
            $registry.adminUserEnabled -ne $false -or
            [string]$registry.armAudienceStatus -cne 'enabled' -or
            [string]$registry.ownershipId -cne $canonicalOwnershipId -or
            [string]$registry.sourceFingerprint -cne $SourceFingerprint) {
            throw 'mismatch'
        }
        return $true
    }
    catch {
        throw 'Dedicated runtime image-pull identity, AcrPull receipt, ACR policy, or ownership/source evidence is unavailable or mismatched.'
    }
}

function Test-GatewaySubscriptionDeploymentEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )
    if (-not $Evidence -or [string]::IsNullOrWhiteSpace([string]$Evidence.deploymentName)) { throw 'Foundation evidence is incomplete; refusing automatic replay.' }
    try {
        $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
        Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Foundation source fingerprint'
        $expectedDeploymentName = "a365gw-$($Config.projectName)-bootstrap-foundation-$($Config.environment)"
        if ([string]$Evidence.deploymentName -ne $expectedDeploymentName -or
            [string]$Evidence.resourceGroupName -ne [string]$Config.resourceGroupName -or
            $DeploymentOwnershipId -cne $canonicalOwnershipId -or
            [string]$Evidence.deploymentOwnershipId -cne $canonicalOwnershipId -or
            [string]$Evidence.sourceFingerprint -cne $SourceFingerprint) { throw 'mismatch' }

        $deployment = Invoke-AzJson -Arguments @(
            'deployment', 'sub', 'show', '--subscription', [string]$Config.subscriptionId,
            '--name', $expectedDeploymentName, '--query', '{state:properties.provisioningState,outputs:properties.outputs,parameters:properties.parameters}'
        )
        if ([string]$deployment.state -ne 'Succeeded' -or
            [string]$deployment.parameters.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
            [string]$deployment.outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
            [string]$deployment.parameters.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
            [string]$deployment.outputs.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
            [string]$deployment.outputs.resourceGroupName.value -ne [string]$Evidence.resourceGroupName -or
            [string]$deployment.outputs.containerAppsEnvironmentId.value -ne [string]$Evidence.containerAppsEnvironmentId -or
            [string]$deployment.outputs.virtualNetworkId.value -ne [string]$Evidence.virtualNetworkId -or
            [string]$deployment.outputs.privateEndpointSubnetId.value -ne [string]$Evidence.privateEndpointSubnetId -or
            [string]$deployment.outputs.acrLoginServer.value -ne [string]$Evidence.acrLoginServer -or
            [string]$deployment.outputs.runtimeImagePullIdentityId.value -ne [string]$Evidence.runtimeImagePullIdentityId -or
            [string]$deployment.outputs.runtimeImagePullIdentityPrincipalId.value -ne [string]$Evidence.runtimeImagePullIdentityPrincipalId -or
            [string]$deployment.outputs.runtimeImagePullAcrPullRoleAssignmentId.value -ne [string]$Evidence.runtimeImagePullAcrPullRoleAssignmentId) { throw 'mismatch' }

        $group = Invoke-AzJson -Arguments @(
            'group', 'show', '--subscription', [string]$Config.subscriptionId,
            '--name', [string]$Config.resourceGroupName,
            '--query', '{name:name,location:location,tags:tags}'
        )
        if ([string]$group.name -ne [string]$Config.resourceGroupName -or
            [string]$group.location -ne [string]$Config.location -or
            [string]$group.tags.projectName -ne [string]$Config.projectName -or
            [string]$group.tags.environment -ne [string]$Config.environment -or
            [string]$group.tags.managedBy -ne 'bootstrap' -or
            [string]$group.tags.deploymentId -ne "$($Config.projectName)-$($Config.environment)" -or
            [string]$group.tags.bootstrapOwnershipId -cne $canonicalOwnershipId -or
            [string]$group.tags.bootstrapSourceFingerprint -cne $SourceFingerprint) { throw 'mismatch' }

        foreach ($resource in @(
            [ordered]@{ id = [string]$Evidence.containerAppsEnvironmentId; type = 'Microsoft.App/managedEnvironments'; name = [string]$Evidence.containerAppsEnvironmentName; tagged = $true },
            [ordered]@{ id = [string]$Evidence.virtualNetworkId; type = 'Microsoft.Network/virtualNetworks'; name = [string]$Evidence.virtualNetworkName; tagged = $true },
            [ordered]@{ id = [string]$Evidence.privateEndpointSubnetId; type = 'Microsoft.Network/virtualNetworks/subnets'; name = [string]$Evidence.privateEndpointSubnetName; tagged = $false }
        )) {
            if ([string]::IsNullOrWhiteSpace($resource.id)) { throw 'mismatch' }
            $actual = Invoke-AzJson -Arguments @('resource', 'show', '--ids', $resource.id, '--query', '{id:id,type:type,name:name,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}')
            if ([string]$actual.id -ne $resource.id -or [string]$actual.type -ne $resource.type -or
                -not ([string]$actual.name).EndsWith([string]$resource.name, [StringComparison]::OrdinalIgnoreCase) -or
                ($resource.tagged -and (
                    [string]$actual.ownershipId -cne $canonicalOwnershipId -or
                    [string]$actual.sourceFingerprint -cne $SourceFingerprint))) { throw 'mismatch' }
        }

        $workspace = Invoke-AzJson -Arguments @(
            'monitor', 'log-analytics', 'workspace', 'show', '--resource-group', [string]$Config.resourceGroupName,
            '--workspace-name', [string]$Evidence.logAnalyticsWorkspaceName, '--query', '{name:name,location:location,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
        )
        $expectedRegistryId = "/subscriptions/$(([guid][string]$Config.subscriptionId).ToString('D'))/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.ContainerRegistry/registries/$($Evidence.acrName)"
        $registry = Invoke-AzJson -Arguments @(
            'resource', 'show', '--subscription', [string]$Config.subscriptionId,
            '--ids', $expectedRegistryId, '--api-version', '2023-11-01-preview',
            '--query', '{id:id,name:name,loginServer:properties.loginServer,adminUserEnabled:properties.adminUserEnabled,armAudienceStatus:properties.policies.azureADAuthenticationAsArmPolicy.status,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
        )
        if ([string]$workspace.name -ne [string]$Evidence.logAnalyticsWorkspaceName -or
            [string]$workspace.location -ne [string]$Config.location -or
            [string]$workspace.ownershipId -cne $canonicalOwnershipId -or
            [string]$workspace.sourceFingerprint -cne $SourceFingerprint -or
            -not ([string]$registry.id).Equals($expectedRegistryId, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$registry.name -ne [string]$Evidence.acrName -or
            [string]$registry.loginServer -ne [string]$Evidence.acrLoginServer -or
            $registry.adminUserEnabled -ne $false -or
            [string]$registry.armAudienceStatus -cne 'enabled' -or
            [string]$registry.ownershipId -cne $canonicalOwnershipId -or
            [string]$registry.sourceFingerprint -cne $SourceFingerprint) { throw 'mismatch' }
        Assert-GatewayRuntimeImagePullIdentityEvidence `
            -Config $Config `
            -Evidence $Evidence `
            -ExpectedRegistryId $expectedRegistryId `
            -DeploymentOwnershipId $canonicalOwnershipId `
            -SourceFingerprint $SourceFingerprint | Out-Null
        return $true
    }
    catch { throw 'Foundation revalidation was unavailable or mismatched; refusing automatic replay. Review access/state and run gateway diagnose.' }
}

function Get-GatewayOptionalObjectProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Assert-GatewayDatabaseAttestationDeploymentContract {
    param(
        [Parameter(Mandatory)]$Parameters,
        [Parameter(Mandatory)]$Outputs,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedValues
    )
    foreach ($entry in $ExpectedValues.GetEnumerator()) {
        $name = [string]$entry.Key
        $expectedValue = [string]$entry.Value
        if ($name -cne 'databaseAttestationDatabaseName') {
            $parameterProperty = Get-GatewayOptionalObjectProperty -Object $Parameters -Name $name
            if ($null -eq $parameterProperty) { throw 'mismatch' }
            $parameterValue = Get-GatewayOptionalObjectProperty -Object $parameterProperty -Name 'value'
            if ($null -eq $parameterValue -or [string]$parameterValue -cne $expectedValue) { throw 'mismatch' }
        }

        $outputProperty = Get-GatewayOptionalObjectProperty -Object $Outputs -Name $name
        $evidenceValue = Get-GatewayOptionalObjectProperty -Object $Evidence -Name $name
        if ($null -eq $outputProperty -or $null -eq $evidenceValue) { throw 'mismatch' }
        $outputValue = Get-GatewayOptionalObjectProperty -Object $outputProperty -Name 'value'
        if ($null -eq $outputValue -or
            [string]$outputValue -cne $expectedValue -or
            [string]$evidenceValue -cne $expectedValue) { throw 'mismatch' }
    }
    return $true
}

function Test-GatewayContainerAppLocationEquivalent {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ActualLocation,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ExpectedLocation
    )

    if ($ActualLocation -notmatch '^[A-Za-z0-9 ]+$' -or
        $ExpectedLocation -notmatch '^[A-Za-z0-9 ]+$') {
        return $false
    }
    $normalizedActual = $ActualLocation.Replace(' ', '')
    $normalizedExpected = $ExpectedLocation.Replace(' ', '')
    if ([string]::IsNullOrEmpty($normalizedActual) -or
        [string]::IsNullOrEmpty($normalizedExpected)) {
        return $false
    }
    return [string]::Equals($normalizedActual, $normalizedExpected, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-GatewayExactContainerEnvironment {
    param(
        [Parameter(Mandatory)]$Entries,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedValues,
        [Parameter()][System.Collections.IDictionary]$ExpectedSecretRefs = ([ordered]@{})
    )

    $actualEntries = @($Entries)
    $expectedNames = @($ExpectedValues.Keys) + @($ExpectedSecretRefs.Keys)
    if ($actualEntries.Count -ne $expectedNames.Count -or
        @($expectedNames | Sort-Object -Unique).Count -ne $expectedNames.Count) {
        throw 'Container environment variable cardinality is not exact.'
    }
    $actualByName = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $actualEntries) {
        $name = [string]$entry.name
        if ([string]::IsNullOrWhiteSpace($name) -or -not $actualByName.TryAdd($name, $entry)) {
            throw 'Container environment variables contain a missing or duplicate exact name.'
        }
    }
    foreach ($name in @($ExpectedValues.Keys)) {
        if (-not $actualByName.ContainsKey([string]$name)) { throw "A required value-backed container environment variable is absent: $name." }
        $entry = $actualByName[[string]$name]
        if (-not [string]::IsNullOrWhiteSpace([string](Get-GatewayOptionalObjectProperty -Object $entry -Name 'secretRef')) -or
            [string](Get-GatewayOptionalObjectProperty -Object $entry -Name 'value') -cne [string]$ExpectedValues[$name]) {
            throw "A value-backed container environment variable does not match its exact reviewed value contract: $name."
        }
    }
    foreach ($name in @($ExpectedSecretRefs.Keys)) {
        if (-not $actualByName.ContainsKey([string]$name)) { throw "A required secret-backed container environment variable is absent: $name." }
        $entry = $actualByName[[string]$name]
        if (-not [string]::IsNullOrWhiteSpace([string](Get-GatewayOptionalObjectProperty -Object $entry -Name 'value')) -or
            [string](Get-GatewayOptionalObjectProperty -Object $entry -Name 'secretRef') -cne [string]$ExpectedSecretRefs[$name]) {
            throw 'A secret-backed container environment variable does not match its exact reviewed reference contract.'
        }
    }
    return $true
}

function Assert-GatewayExactContainerRegistry {
    param(
        [Parameter(Mandatory)]$Registries,
        [Parameter(Mandatory)][string]$ExpectedServer,
        [Parameter(Mandatory)][string]$ExpectedIdentity
    )
    $entries = @($Registries)
    if ($entries.Count -ne 1 -or [string]$entries[0].server -cne $ExpectedServer -or
        -not ([string]$entries[0].identity).Equals($ExpectedIdentity, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-GatewayOptionalObjectProperty -Object $entries[0] -Name 'username')) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-GatewayOptionalObjectProperty -Object $entries[0] -Name 'passwordSecretRef'))) {
        throw 'Container registry configuration is not the one exact managed-identity-backed registry contract.'
    }
    return $true
}

function Assert-GatewayExactSystemContainerAppEnvelope {
    param(
        [Parameter(Mandatory)]$App,
        [Parameter(Mandatory)][string]$ExpectedName,
        [Parameter(Mandatory)][string]$ExpectedLocation,
        [Parameter(Mandatory)][string]$ExpectedPrincipalId,
        [Parameter(Mandatory)][string]$ExpectedImagePullIdentityResourceId,
        [Parameter(Mandatory)][string]$ExpectedManagedEnvironmentId,
        [Parameter(Mandatory)][string]$ExpectedRegistryServer,
        [Parameter(Mandatory)][string]$ExpectedImage,
        [Parameter(Mandatory)][bool]$ExternalIngress,
        [Parameter()][string]$ExpectedFqdn = ''
    )
    $containers = @($App.properties.template.containers)
    $reportedSecrets = Get-GatewayOptionalObjectProperty -Object $App.properties.configuration -Name 'secrets'
    $secrets = @()
    if ($null -ne $reportedSecrets) { $secrets = @($reportedSecrets) }
    $userAssigned = Get-GatewayOptionalObjectProperty -Object $App.identity -Name 'userAssignedIdentities'
    $userAssignedIdentityIds = @(if ($null -ne $userAssigned) {
        $userAssigned.PSObject.Properties | ForEach-Object { [string]$_.Name }
    })
    if ([string]$App.name -cne $ExpectedName -or
        -not (Test-GatewayContainerAppLocationEquivalent -ActualLocation ([string]$App.location) -ExpectedLocation $ExpectedLocation) -or
        [string]$App.properties.provisioningState -cne 'Succeeded' -or
        [string]$App.identity.type -cne 'SystemAssigned, UserAssigned' -or
        $userAssignedIdentityIds.Count -ne 1 -or
        -not ([string]$userAssignedIdentityIds[0]).Equals($ExpectedImagePullIdentityResourceId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$App.identity.principalId -cne $ExpectedPrincipalId -or
        -not ([string]$App.properties.managedEnvironmentId).Equals($ExpectedManagedEnvironmentId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$App.properties.configuration.activeRevisionsMode -cne 'Single' -or
        $secrets.Count -ne 0 -or $containers.Count -ne 1 -or
        [string]$containers[0].name -cne $ExpectedName -or [string]$containers[0].image -cne $ExpectedImage) {
        throw 'Container App identity, environment, revision, secret, or immutable-image envelope is not exact.'
    }
    Assert-GatewayExactContainerRegistry -Registries $App.properties.configuration.registries -ExpectedServer $ExpectedRegistryServer -ExpectedIdentity $ExpectedImagePullIdentityResourceId | Out-Null
    $ingress = Get-GatewayOptionalObjectProperty -Object $App.properties.configuration -Name 'ingress'
    if ($ExternalIngress) {
        if ($null -eq $ingress -or $ingress.external -ne $true -or $ingress.allowInsecure -ne $false -or
            [int]$ingress.targetPort -ne 8080 -or
            -not ([string]$ingress.transport).Equals('auto', [StringComparison]::OrdinalIgnoreCase) -or
            [string]$ingress.fqdn -cne $ExpectedFqdn) {
            throw 'Container App ingress is not the exact external HTTPS-only contract.'
        }
    }
    elseif ($null -ne $ingress) {
        throw 'The worker Container App unexpectedly exposes an ingress configuration.'
    }
    return $true
}

function Test-GatewayGroupDeploymentEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$ApiImage,
        [Parameter(Mandatory)][string]$WorkerImage,
        [Parameter()]$Database,
        [switch]$AllowRuntimeSupersession
    )
    if (-not $Evidence -or [string]::IsNullOrWhiteSpace([string]$Evidence.deploymentName)) { throw 'Deployment evidence is incomplete; refusing automatic replay.' }
    try {
        $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
        Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Deployment source fingerprint'
        if ($DeploymentOwnershipId -cne $canonicalOwnershipId -or
            [string]$Foundation.deploymentOwnershipId -cne $canonicalOwnershipId -or
            [string]$Foundation.sourceFingerprint -cne $SourceFingerprint -or
            [string]$Evidence.deploymentOwnershipId -cne $canonicalOwnershipId -or
            [string]$Evidence.sourceFingerprint -cne $SourceFingerprint -or
            [string]$Evidence.apiImage -cne $ApiImage -or
            [string]$Evidence.workerImage -cne $WorkerImage -or
            [string]$Evidence.runtimeImagePullIdentityId -cne [string]$Foundation.runtimeImagePullIdentityId -or
            [string]$Evidence.runtimeImagePullIdentityPrincipalId -cne [string]$Foundation.runtimeImagePullIdentityPrincipalId -or
            [string]$Evidence.runtimeImagePullAcrPullRoleAssignmentId -cne [string]$Foundation.runtimeImagePullAcrPullRoleAssignmentId) { throw 'mismatch' }
        $inertDeploymentName = "a365gw-$($Config.projectName)-bootstrap-inert-$($Config.environment)"
        $runtimeDeploymentName = "a365gw-$($Config.projectName)-bootstrap-runtime-$($Config.environment)"
        if ([string]$Evidence.deploymentName -notin @($inertDeploymentName, $runtimeDeploymentName)) { throw 'mismatch' }
        $isRuntime = [string]$Evidence.deploymentName -eq $runtimeDeploymentName
        if ($isRuntime -and (-not $Database -or
            [string]$Database.deploymentOwnershipId -cne $canonicalOwnershipId -or
            [string]$Database.acceptedSourceFingerprint -cne $SourceFingerprint -or
            [string]$Database.server -cne [string]$Evidence.sqlServerFqdn -or
            [string]$Database.database -cne 'GatewayDb' -or
            [string]$Database.schemaFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$Database.apiPrincipalObjectId -cne ([guid][string]$Evidence.apiPrincipalId).ToString('D') -or
            [string]$Database.workerPrincipalObjectId -cne ([guid][string]$Evidence.workerPrincipalId).ToString('D'))) { throw 'mismatch' }
        $deployment = Invoke-AzJson -Arguments @(
            'deployment', 'group', 'show', '--subscription', [string]$Config.subscriptionId,
            '--resource-group', [string]$Config.resourceGroupName, '--name', [string]$Evidence.deploymentName,
            '--query', '{state:properties.provisioningState,outputs:properties.outputs,parameters:properties.parameters}'
        )
        if ([string]$deployment.state -ne 'Succeeded' -or
            [string]$deployment.parameters.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
            [string]$deployment.outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
            [string]$deployment.parameters.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
            [string]$deployment.outputs.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
            [string]$deployment.parameters.apiContainerImage.value -cne $ApiImage -or
            [string]$deployment.parameters.workerContainerImage.value -cne $WorkerImage -or
            [string]$deployment.outputs.apiContainerImage.value -cne $ApiImage -or
            [string]$deployment.outputs.workerContainerImage.value -cne $WorkerImage -or
            [string]$deployment.parameters.containerAppsEnvironmentName.value -cne [string]$Foundation.containerAppsEnvironmentName -or
            [string]$deployment.parameters.entraIdTenantId.value -cne [string]$Config.tenantId -or
            [string]$deployment.parameters.entraIdClientId.value -cne [string]$Identity.gatewayApiClientId -or
            [string]$deployment.parameters.entraIdAudience.value -cne [string]$Identity.gatewayApiTokenAudience -or
            [string]$deployment.parameters.workerContainerAppName.value -cne "ca-gateway-worker-$($Config.environment)-v3" -or
            [string]$deployment.parameters.runtimeImagePullIdentityId.value -cne [string]$Foundation.runtimeImagePullIdentityId -or
            [string]$deployment.parameters.runtimeImagePullIdentityPrincipalId.value -cne [string]$Foundation.runtimeImagePullIdentityPrincipalId -or
            [string]$deployment.parameters.runtimeImagePullAcrPullRoleAssignmentId.value -cne [string]$Foundation.runtimeImagePullAcrPullRoleAssignmentId -or
            [string]$deployment.outputs.runtimeImagePullIdentityId.value -cne [string]$Foundation.runtimeImagePullIdentityId -or
            [string]$deployment.outputs.runtimeImagePullIdentityPrincipalId.value -cne [string]$Foundation.runtimeImagePullIdentityPrincipalId -or
            [string]$deployment.outputs.runtimeImagePullAcrPullRoleAssignmentId.value -cne [string]$Foundation.runtimeImagePullAcrPullRoleAssignmentId -or
            [bool]$deployment.parameters.databaseAttestationEnabled.value -ne [bool]$isRuntime -or
            [bool]$deployment.outputs.databaseAttestationEnabled.value -ne [bool]$isRuntime) { throw 'mismatch' }
        $outputEvidenceNames = [ordered]@{
            apiFqdn = 'apiFqdn'
            apiPrincipalId = 'apiPrincipalId'
            workerPrincipalId = 'workerPrincipalId'
            runtimeImagePullIdentityId = 'runtimeImagePullIdentityId'
            runtimeImagePullIdentityPrincipalId = 'runtimeImagePullIdentityPrincipalId'
            runtimeImagePullAcrPullRoleAssignmentId = 'runtimeImagePullAcrPullRoleAssignmentId'
            acrLoginServer = 'acrLoginServer'
            containerRegistryId = 'containerRegistryId'
            keyVaultUri = 'keyVaultUri'
            sharedKeyVaultId = 'sharedKeyVaultId'
            storageAccountId = 'storageAccountId'
            sqlServerFqdn = 'sqlServerFqdn'
            serviceBusQueueName = 'serviceBusQueueName'
            serviceBusQueueId = 'serviceBusQueueId'
        }
        Assert-GatewayDeploymentOutputEvidenceMap `
            -Outputs $deployment.outputs `
            -Evidence $Evidence `
            -OutputToEvidenceName $outputEvidenceNames | Out-Null
        $expectedRegistryId = "/subscriptions/$(([guid][string]$Config.subscriptionId).ToString('D'))/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.ContainerRegistry/registries/$($Foundation.acrName)"
        if (-not ([string]$Evidence.containerRegistryId).Equals($expectedRegistryId, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'mismatch'
        }
        Assert-GatewayRuntimeImagePullIdentityEvidence `
            -Config $Config `
            -Evidence $Evidence `
            -ExpectedRegistryId $expectedRegistryId `
            -DeploymentOwnershipId $canonicalOwnershipId `
            -SourceFingerprint $SourceFingerprint | Out-Null
        foreach ($property in @('provisioningExecutionEnabled', 'workerProcessingEnabled')) {
            if ([bool]$deployment.outputs.$property.value -ne [bool]$Evidence.$property) { throw 'mismatch' }
        }
        $expectedDatabaseValues = if ($isRuntime) {
            [ordered]@{
                databaseAttestationExpectedSchemaFingerprint = [string]$Database.schemaFingerprint
                databaseAttestationApiPrincipalName = [string]$Database.apiPrincipalName
                databaseAttestationApiPrincipalClientId = [string]$Database.apiPrincipalClientId
                databaseAttestationWorkerPrincipalName = [string]$Database.workerPrincipalName
                databaseAttestationWorkerPrincipalClientId = [string]$Database.workerPrincipalClientId
                databaseAttestationDatabaseName = 'GatewayDb'
            }
        }
        else {
            [ordered]@{
                databaseAttestationExpectedSchemaFingerprint = ''
                databaseAttestationApiPrincipalName = ''
                databaseAttestationApiPrincipalClientId = ''
                databaseAttestationWorkerPrincipalName = ''
                databaseAttestationWorkerPrincipalClientId = ''
                databaseAttestationDatabaseName = ''
            }
        }
        Assert-GatewayDatabaseAttestationDeploymentContract `
            -Parameters $deployment.parameters `
            -Outputs $deployment.outputs `
            -Evidence $Evidence `
            -ExpectedValues $expectedDatabaseValues | Out-Null
        $expectedPreview = $isRuntime -and [string]$Config.environment -eq 'dev' -and
            $Config.agent365.allowDevelopmentRegistryPreview -eq $true
        if ([bool]$Evidence.workerProcessingEnabled -ne $isRuntime -or
            [bool]$Evidence.provisioningExecutionEnabled -ne $expectedPreview) { throw 'mismatch' }

        $api = Invoke-AzJson -Arguments @('containerapp', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', "ca-gateway-api-$($Config.environment)")
        $worker = Invoke-AzJson -Arguments @('containerapp', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', "ca-gateway-worker-$($Config.environment)-v3")
        if ([string]$api.name -ne "ca-gateway-api-$($Config.environment)" -or
            [string]$api.properties.configuration.ingress.fqdn -ne [string]$Evidence.apiFqdn -or
            [string]$api.identity.principalId -ne [string]$Evidence.apiPrincipalId -or
            [string]$api.properties.provisioningState -ne 'Succeeded' -or
            [string]$api.tags.bootstrapOwnershipId -cne $canonicalOwnershipId -or
            [string]$api.tags.bootstrapSourceFingerprint -cne $SourceFingerprint -or
            [string]$api.properties.template.containers[0].image -cne $ApiImage -or
            [string]$worker.name -ne "ca-gateway-worker-$($Config.environment)-v3" -or
            [string]$worker.identity.principalId -ne [string]$Evidence.workerPrincipalId -or
            [string]$worker.properties.provisioningState -ne 'Succeeded' -or
            [string]$worker.tags.bootstrapOwnershipId -cne $canonicalOwnershipId -or
            [string]$worker.tags.bootstrapSourceFingerprint -cne $SourceFingerprint -or
            [string]$worker.properties.template.containers[0].image -cne $WorkerImage) { throw 'mismatch' }

        if ($isRuntime -or -not $AllowRuntimeSupersession) {
            $expectedManagerIds = @(
                if ($isRuntime) {
                    $Config.agent365.reviewedManagerApplicationIds |
                        ForEach-Object { ([guid][string]$_).ToString('D') } |
                        Sort-Object -Unique
                }
            )
            $deploymentManagerIds = @($deployment.parameters.agent365ManagerApplicationIds.value | ForEach-Object { ([guid][string]$_).ToString('D') })
            if (($deploymentManagerIds -join '|') -cne ($expectedManagerIds -join '|')) { throw 'mismatch' }

            $appInsightsConnectionString = Invoke-AzTsv -Arguments @(
                'monitor', 'app-insights', 'component', 'show', '--resource-group', [string]$Config.resourceGroupName,
                '--app', "ai-$($Config.projectName)-$($Config.environment)", '--query', 'connectionString'
            )
            if ([string]::IsNullOrWhiteSpace($appInsightsConnectionString)) { throw 'mismatch' }
            $storagePattern = "^/subscriptions/$([regex]::Escape([string]$Config.subscriptionId))/resourceGroups/$([regex]::Escape([string]$Config.resourceGroupName))/providers/Microsoft\.Storage/storageAccounts/(?<name>[a-z0-9]{3,24})$"
            if ([string]$Evidence.storageAccountId -cnotmatch $storagePattern) { throw 'mismatch' }
            $storageName = [string]$Matches.name
            $sqlConnection = "Server=tcp:$($Evidence.sqlServerFqdn),1433;Database=GatewayDb;Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;"
            $serviceBusNamespace = "sb-$($Config.projectName)-$($Config.environment).servicebus.windows.net"
            $expectedPurviewEnabled = $false
            $booleanEnvironment = Get-GatewayArmBooleanEnvironmentContract `
                -RuntimeEnabled ([bool]$isRuntime) `
                -RegistryPreviewEnabled ([bool]$expectedPreview) `
                -PurviewEnabled $expectedPurviewEnabled `
                -PurviewPolicyProvisioningEnabled ([bool]($expectedPurviewEnabled -and $Config.purview.policyProvisioningEnabled -eq $true)) `
                -PromptShieldEnabled ([bool]$Config.promptShield.enabled)
            $apiEnvironment = [ordered]@{
                'ConnectionStrings__GatewayDb' = $sqlConnection
                'ServiceBus__FullyQualifiedNamespace' = $serviceBusNamespace
                'ServiceBus__QueueName' = [string]$Evidence.serviceBusQueueName
                'Provisioning__ExecutionEnabled' = $booleanEnvironment.Api['Provisioning__ExecutionEnabled']
                'Provisioning__AllowContinuousDevelopmentAccess' = $booleanEnvironment.Api['Provisioning__AllowContinuousDevelopmentAccess']
                'BlobStorage__ServiceUri' = "https://$storageName.blob.core.windows.net/"
                'BlobStorage__ContainerName' = 'a365-gateway-interactions'
                'Observability__ApplicationInsightsConnectionString' = $appInsightsConnectionString
                'EntraId__TenantId' = [string]$Config.tenantId
                'EntraId__ClientId' = [string]$Identity.gatewayApiClientId
                'EntraId__Audience' = [string]$Identity.gatewayApiTokenAudience
                'EntraId__ClientCredentials__0__SourceType' = 'SignedAssertionFromManagedIdentity'
                'EntraId__ClientCredentials__0__TokenExchangeUrl' = 'api://AzureADTokenExchange'
                'KeyVault__VaultUri' = [string]$Evidence.keyVaultUri
                'Agent365__TenantId' = [string]$Config.tenantId
                'Agent365__DelegatedRegistry__Enabled' = $booleanEnvironment.Api['Agent365__DelegatedRegistry__Enabled']
                'Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess' = $booleanEnvironment.Api['Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess']
                'Agent365__DelegatedRegistry__Scopes__0' = 'https://graph.microsoft.com/AgentRegistration.ReadWrite.All'
                'Agent365__DelegatedRegistry__Scopes__1' = 'https://graph.microsoft.com/AgentRegistration.Read.All'
                'Purview__Enabled' = $booleanEnvironment.Api['Purview__Enabled']
                'PromptShield__Enabled' = $booleanEnvironment.Api['PromptShield__Enabled']
                'PromptShield__Endpoint' = $(if ($Config.promptShield.enabled -eq $true) { [string]$Evidence.promptShieldEndpoint } else { '' })
                'PromptShield__ApiVersion' = '2024-09-01'
                'DatabaseAttestation__Enabled' = $booleanEnvironment.Api['DatabaseAttestation__Enabled']
                'DatabaseAttestation__DeploymentOwnershipId' = $(if ($isRuntime) { $canonicalOwnershipId } else { '' })
                'DatabaseAttestation__AcceptedSourceFingerprint' = $(if ($isRuntime) { $SourceFingerprint } else { '' })
                'DatabaseAttestation__ExpectedSchemaFingerprint' = $(if ($isRuntime) { [string]$Database.schemaFingerprint } else { '' })
                'DatabaseAttestation__SqlServerFqdn' = $(if ($isRuntime) { [string]$Database.server } else { '' })
                'DatabaseAttestation__DatabaseName' = $(if ($isRuntime) { 'GatewayDb' } else { '' })
                'DatabaseAttestation__ApiPrincipalName' = $(if ($isRuntime) { [string]$Database.apiPrincipalName } else { '' })
                'DatabaseAttestation__ApiPrincipalClientId' = $(if ($isRuntime) { [string]$Database.apiPrincipalClientId } else { '' })
                'DatabaseAttestation__WorkerPrincipalName' = $(if ($isRuntime) { [string]$Database.workerPrincipalName } else { '' })
                'DatabaseAttestation__WorkerPrincipalClientId' = $(if ($isRuntime) { [string]$Database.workerPrincipalClientId } else { '' })
                'OutboxRelay__PollingIntervalSeconds' = '5'
                'OutboxRelay__BatchSize' = '10'
                'ASPNETCORE_ENVIRONMENT' = 'Production'
            }
            $workerEnvironment = [ordered]@{
                'ConnectionStrings__GatewayDb' = $sqlConnection
                'ServiceBus__FullyQualifiedNamespace' = $serviceBusNamespace
                'ServiceBus__QueueName' = [string]$Evidence.serviceBusQueueName
                'OutboxRelay__Enabled' = 'false'
                'Observability__ApplicationInsightsConnectionString' = $appInsightsConnectionString
                'KeyVault__VaultUri' = [string]$Evidence.keyVaultUri
                'Agent365__TenantId' = [string]$Config.tenantId
                'Agent365__ObservabilityServerAddress' = [string]$Evidence.apiFqdn
                'Agent365__ProvisioningManagedIdentityPrincipalId' = $(if ($isRuntime) { [string]$Evidence.workerPrincipalId } else { '' })
                'ProvisioningWorker__QueueName' = [string]$Evidence.serviceBusQueueName
                'ProvisioningWorker__MaxConcurrentCalls' = $(if ($expectedPreview) { '1' } else { '5' })
                'ProvisioningWorker__ProcessingEnabled' = $booleanEnvironment.Worker['ProvisioningWorker__ProcessingEnabled']
                'ProvisioningWorker__ProvisioningExecutionEnabled' = $booleanEnvironment.Worker['ProvisioningWorker__ProvisioningExecutionEnabled']
                'Purview__Enabled' = $booleanEnvironment.Worker['Purview__Enabled']
                'Purview__PolicyProvisioningEnabled' = $booleanEnvironment.Worker['Purview__PolicyProvisioningEnabled']
                'Purview__PolicyProvisioningOrganization' = [string]$Config.purview.policyProvisioningOrganization
                'Purview__PolicyProvisioningApplicationId' = [string]$Config.purview.policyProvisioningApplicationId
                'Purview__PolicyProvisioningCertificateSecretUri' = [string]$Config.purview.policyProvisioningCertificateSecretUri
                'Purview__DefaultSensitiveInformationTypeId' = [string]$Config.purview.sensitiveInformationTypeId
                'Purview__DefaultSensitiveInformationType' = [string]$Config.purview.sensitiveInformationType
                'DOTNET_ENVIRONMENT' = 'Production'
            }
            for ($index = 0; $index -lt $expectedManagerIds.Count; $index++) {
                $apiEnvironment["Agent365__ManagerApplicationIds__$index"] = [string]$expectedManagerIds[$index]
                $workerEnvironment["Agent365__ManagerApplicationIds__$index"] = [string]$expectedManagerIds[$index]
            }

            Assert-GatewayExactSystemContainerAppEnvelope -App $api -ExpectedName "ca-gateway-api-$($Config.environment)" `
                -ExpectedLocation ([string]$Config.location) -ExpectedPrincipalId ([string]$Evidence.apiPrincipalId) `
                -ExpectedImagePullIdentityResourceId ([string]$Evidence.runtimeImagePullIdentityId) `
                -ExpectedManagedEnvironmentId ([string]$Foundation.containerAppsEnvironmentId) -ExpectedRegistryServer ([string]$Evidence.acrLoginServer) `
                -ExpectedImage $ApiImage -ExternalIngress $true -ExpectedFqdn ([string]$Evidence.apiFqdn) | Out-Null
            Assert-GatewayExactSystemContainerAppEnvelope -App $worker -ExpectedName "ca-gateway-worker-$($Config.environment)-v3" `
                -ExpectedLocation ([string]$Config.location) -ExpectedPrincipalId ([string]$Evidence.workerPrincipalId) `
                -ExpectedImagePullIdentityResourceId ([string]$Evidence.runtimeImagePullIdentityId) `
                -ExpectedManagedEnvironmentId ([string]$Foundation.containerAppsEnvironmentId) -ExpectedRegistryServer ([string]$Evidence.acrLoginServer) `
                -ExpectedImage $WorkerImage -ExternalIngress $false | Out-Null
            Assert-GatewayExactContainerEnvironment -Entries $api.properties.template.containers[0].env -ExpectedValues $apiEnvironment | Out-Null
            Assert-GatewayExactContainerEnvironment -Entries $worker.properties.template.containers[0].env -ExpectedValues $workerEnvironment | Out-Null
        }

        $registryName = ([string]$Evidence.acrLoginServer).Split('.')[0]
        $registryLogin = Invoke-AzTsv -Arguments @('acr', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $registryName, '--query', 'loginServer')
        $vaultName = ([Uri][string]$Evidence.keyVaultUri).Host.Split('.')[0]
        $vaultUri = Invoke-AzTsv -Arguments @('keyvault', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $vaultName, '--query', 'properties.vaultUri')
        $sqlName = ([string]$Evidence.sqlServerFqdn).Split('.')[0]
        $sqlFqdn = Invoke-AzTsv -Arguments @('sql', 'server', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $sqlName, '--query', 'fullyQualifiedDomainName')
        $queueName = Invoke-AzTsv -Arguments @(
            'servicebus', 'queue', 'show', '--resource-group', [string]$Config.resourceGroupName,
            '--namespace-name', "sb-$($Config.projectName)-$($Config.environment)",
            '--name', [string]$Evidence.serviceBusQueueName, '--query', 'name'
        )
        if ($registryLogin -ne [string]$Evidence.acrLoginServer -or
            $vaultUri -ne [string]$Evidence.keyVaultUri -or
            $sqlFqdn -ne [string]$Evidence.sqlServerFqdn -or
            $queueName -ne [string]$Evidence.serviceBusQueueName) { throw 'mismatch' }

        if ($Config.promptShield.enabled -eq $true) {
            if ([string]::IsNullOrWhiteSpace([string]$Evidence.promptShieldAccountId) -or
                [string]::IsNullOrWhiteSpace([string]$Evidence.promptShieldEndpoint)) { throw 'mismatch' }
            $contentSafety = Invoke-AzJson -Arguments @('resource', 'show', '--ids', [string]$Evidence.promptShieldAccountId, '--api-version', '2023-05-01', '--query', '{id:id,kind:kind}')
            if ([string]$contentSafety.id -ne [string]$Evidence.promptShieldAccountId -or [string]$contentSafety.kind -ne 'ContentSafety') { throw 'mismatch' }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$Evidence.promptShieldAccountId) -or
            -not [string]::IsNullOrWhiteSpace([string]$Evidence.promptShieldEndpoint)) { throw 'mismatch' }
        return $true
    }
    catch { throw "ARM deployment revalidation was unavailable or mismatched; refusing automatic replay. Review access/state and run gateway diagnose. Cause: $($_.Exception.Message)" }
}

function Assert-GatewayDeploymentOutputEvidenceMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Outputs,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][System.Collections.IDictionary]$OutputToEvidenceName
    )

    foreach ($entry in $OutputToEvidenceName.GetEnumerator()) {
        $output = Get-GatewayOptionalObjectProperty -Object $Outputs -Name ([string]$entry.Key)
        $evidenceValue = Get-GatewayOptionalObjectProperty -Object $Evidence -Name ([string]$entry.Value)
        if ($null -eq $output -or $null -eq $evidenceValue -or
            [string]$output.value -ne [string]$evidenceValue) {
            throw 'Deployment output evidence does not match the reviewed output-to-evidence contract.'
        }
    }
    return $true
}

function Test-GatewayNamedGroupDeployment {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$AdminIdentity,
        [Parameter(Mandatory)]$AdminCredential,
        [Parameter(Mandatory)][string]$DeploymentName,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$AdminUiImage
    )
    try {
        $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
        Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Admin UI source fingerprint'
        $expectedName = "a365gw-$($Config.projectName)-bootstrap-admin-$($Config.environment)"
        if ($DeploymentName -ne $expectedName -or -not $Evidence -or
            $DeploymentOwnershipId -cne $canonicalOwnershipId -or
            [string]$Evidence.deploymentOwnershipId -cne $canonicalOwnershipId -or
            [string]$Evidence.sourceFingerprint -cne $SourceFingerprint -or
            [string]$Evidence.adminUiImage -cne $AdminUiImage -or
            -not (Test-GatewayHttpsUrl -Url ([string]$Evidence.adminUiUrl))) { throw 'mismatch' }
        $deployment = Invoke-AzJson -Arguments @(
            'deployment', 'group', 'show', '--subscription', [string]$Config.subscriptionId,
            '--resource-group', [string]$Config.resourceGroupName, '--name', $DeploymentName,
            '--query', '{state:properties.provisioningState,outputs:properties.outputs,parameters:properties.parameters}'
        )
        if ([string]$deployment.state -ne 'Succeeded' -or
            [string]$deployment.parameters.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
            [string]$deployment.outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
            [string]$deployment.parameters.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
            [string]$deployment.outputs.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
            [string]$deployment.parameters.adminUiContainerImage.value -cne $AdminUiImage -or
            [string]$deployment.outputs.adminUiContainerImage.value -cne $AdminUiImage -or
            [string]$deployment.parameters.containerAppsEnvironmentName.value -cne [string]$Foundation.containerAppsEnvironmentName -or
            [string]$deployment.parameters.entraIdTenantId.value -cne [string]$Config.tenantId -or
            [string]$deployment.parameters.adminUiEntraClientId.value -cne [string]$AdminIdentity.adminUiClientId -or
            [string]$deployment.parameters.adminUiGatewayApiScope.value -cne "$($Identity.gatewayApiScopeBaseUri)/access_as_user" -or
            [string]$deployment.outputs.adminUiFqdn.value -ne [string]$Evidence.adminUiFqdn -or
            [string]$deployment.outputs.adminUiUrl.value -ne [string]$Evidence.adminUiUrl -or
            [string]$deployment.outputs.adminUiPrincipalId.value -ne [string]$Evidence.adminUiPrincipalId -or
            [string]$deployment.outputs.adminUiSignInRedirectUri.value -ne [string]$Evidence.signInRedirectUri -or
            [string]$deployment.outputs.adminUiSignedOutCallbackUri.value -ne [string]$Evidence.signedOutCallbackUri) { throw 'mismatch' }
        $admin = Invoke-AzJson -Arguments @(
            'containerapp', 'show', '--resource-group', [string]$Config.resourceGroupName,
            '--name', "ca-gateway-admin-$($Config.environment)"
        )
        $adminManagedIdentity = Invoke-AzJson -Arguments @(
            'identity', 'show', '--resource-group', [string]$Config.resourceGroupName,
            '--name', "id-gateway-admin-$($Config.environment)",
            '--query', '{id:id,name:name,principalId:principalId,ownershipId:tags.bootstrapOwnershipId}'
        )
        $attachedIdentityIds = @($admin.identity.userAssignedIdentities.PSObject.Properties.Name)
        if ([string]$admin.name -ne "ca-gateway-admin-$($Config.environment)" -or
            [string]$admin.properties.configuration.ingress.fqdn -ne [string]$Evidence.adminUiFqdn -or
            [string]$admin.properties.provisioningState -ne 'Succeeded' -or
            [string]$admin.tags.bootstrapOwnershipId -cne $canonicalOwnershipId -or
            [string]$admin.tags.bootstrapSourceFingerprint -cne $SourceFingerprint -or
            @($admin.properties.template.containers).Count -ne 1 -or
            [string]$admin.properties.template.containers[0].image -cne $AdminUiImage -or
            [string]$adminManagedIdentity.name -ne "id-gateway-admin-$($Config.environment)" -or
            [string]$adminManagedIdentity.principalId -ne [string]$Evidence.adminUiPrincipalId -or
            [string]$adminManagedIdentity.ownershipId -cne $canonicalOwnershipId -or
            $attachedIdentityIds.Count -ne 1 -or
            -not ([string]$attachedIdentityIds[0]).Equals([string]$adminManagedIdentity.id, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$Evidence.adminUiUrl -ne "https://$($Evidence.adminUiFqdn)" -or
            [string]$Evidence.signInRedirectUri -ne "$(([string]$Evidence.adminUiUrl).TrimEnd('/'))/signin-oidc" -or
            [string]$Evidence.signedOutCallbackUri -ne "$(([string]$Evidence.adminUiUrl).TrimEnd('/'))/signout-callback-oidc") { throw 'mismatch' }

        if (-not (Test-GatewayContainerAppLocationEquivalent -ActualLocation ([string]$admin.location) -ExpectedLocation ([string]$Config.location)) -or
            [string]$admin.identity.type -cne 'UserAssigned' -or
            -not [string]::IsNullOrWhiteSpace([string](Get-GatewayOptionalObjectProperty -Object $admin.identity -Name 'principalId')) -or
            -not ([string]$admin.properties.managedEnvironmentId).Equals([string]$Foundation.containerAppsEnvironmentId, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$admin.properties.configuration.activeRevisionsMode -cne 'Single') { throw 'mismatch' }
        Assert-GatewayExactContainerRegistry -Registries $admin.properties.configuration.registries `
            -ExpectedServer ([string]$Runtime.acrLoginServer) -ExpectedIdentity ([string]$adminManagedIdentity.id) | Out-Null
        $adminSecrets = @($admin.properties.configuration.secrets)
        if ($adminSecrets.Count -ne 1 -or [string]$adminSecrets[0].name -cne 'admin-ui-entra-client-secret' -or
            [string]$adminSecrets[0].keyVaultUrl -cne [string]$AdminCredential.secretUri -or
            -not ([string]$adminSecrets[0].identity).Equals([string]$adminManagedIdentity.id, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::IsNullOrWhiteSpace([string](Get-GatewayOptionalObjectProperty -Object $adminSecrets[0] -Name 'value'))) { throw 'mismatch' }
        $adminIngress = $admin.properties.configuration.ingress
        if ($adminIngress.external -ne $true -or $adminIngress.allowInsecure -ne $false -or
            [int]$adminIngress.targetPort -ne 8080 -or
            -not ([string]$adminIngress.transport).Equals('auto', [StringComparison]::OrdinalIgnoreCase) -or
            [string]$adminIngress.fqdn -cne [string]$Evidence.adminUiFqdn -or
            [string]$adminIngress.stickySessions.affinity -cne 'sticky') { throw 'mismatch' }
        $adminEnvironment = [ordered]@{
            'ASPNETCORE_ENVIRONMENT' = 'Production'
            'ASPNETCORE_HTTP_PORTS' = '8080'
            'ASPNETCORE_FORWARDEDHEADERS_ENABLED' = 'true'
            'EntraId__Instance' = 'https://login.microsoftonline.com/'
            'EntraId__TenantId' = [string]$Config.tenantId
            'EntraId__ClientId' = [string]$AdminIdentity.adminUiClientId
            'EntraId__CallbackPath' = '/signin-oidc'
            'EntraId__SignedOutCallbackPath' = '/signout-callback-oidc'
            'GatewayApi__BaseUrl' = "https://$($Runtime.apiFqdn)/"
            'GatewayApi__Scopes__0' = "$($Identity.gatewayApiScopeBaseUri)/access_as_user"
            'GatewayApi__TimeoutSeconds' = '120'
        }
        Assert-GatewayExactContainerEnvironment -Entries $admin.properties.template.containers[0].env `
            -ExpectedValues $adminEnvironment `
            -ExpectedSecretRefs ([ordered]@{ 'EntraId__ClientSecret' = 'admin-ui-entra-client-secret' }) | Out-Null
        if ([int]$admin.properties.template.scale.minReplicas -ne 1 -or
            [int]$admin.properties.template.scale.maxReplicas -ne 1) { throw 'mismatch' }

        $adminSecretScope = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.KeyVault/vaults/kv-$($Config.projectName)-$($Config.environment)/secrets/admin-ui-entra-client-secret"
        $secretAssignments = @(Invoke-AzJson -Arguments @(
            'role', 'assignment', 'list', '--assignee-object-id', [string]$Evidence.adminUiPrincipalId,
            '--scope', $adminSecretScope, '--include-inherited',
            '--query', '[].{principalId:principalId,scope:scope,roleDefinitionId:roleDefinitionId}'
        ))
        if ($secretAssignments.Count -ne 1 -or
            -not ([string]$secretAssignments[0].principalId).Equals([string]$Evidence.adminUiPrincipalId, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$secretAssignments[0].scope).Equals($adminSecretScope, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$secretAssignments[0].roleDefinitionId).EndsWith('/4633458b-17de-408a-b874-0445c86b69e6', [StringComparison]::OrdinalIgnoreCase)) { throw 'mismatch' }
        return $true
    }
    catch { throw "Named ARM deployment revalidation was unavailable or mismatched; refusing automatic replay. Review access/state and run gateway diagnose. Cause: $($_.Exception.Message)" }
}

function Test-GatewayApplicationEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$ObjectIdProperty,
        [Parameter(Mandatory)][string]$ClientIdProperty,
        [Parameter(Mandatory)][ValidateSet('GatewayApi', 'AdminUi')][string]$ApplicationKind,
        [Parameter()][string]$ExpectedAdminUiUrl = ''
    )
    if (-not $Evidence) { throw 'Application evidence is incomplete; refusing automatic replay.' }
    $objectId = [string]$Evidence[$ObjectIdProperty]
    $clientId = [string]$Evidence[$ClientIdProperty]
    $ownershipId = [string]$Evidence.deploymentOwnershipId
    $ownerObjectId = [string]$Evidence.ownerObjectId
    if ([string]::IsNullOrWhiteSpace($objectId) -or [string]::IsNullOrWhiteSpace($clientId) -or
        [string]::IsNullOrWhiteSpace($ownershipId) -or [string]::IsNullOrWhiteSpace($ownerObjectId)) {
        throw 'Application evidence is incomplete; refusing automatic replay.'
    }
    try {
        foreach ($identifier in @($objectId, $clientId, $ownershipId, $ownerObjectId)) {
            Assert-GuidValue -Value $identifier -Label 'Entra application evidence identifier'
        }
        $application = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/applications/${objectId}?`$select=id,appId,displayName,signInAudience,identifierUris,tags,api,appRoles,requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient")
        $expectedTags = @('A365GatewayBootstrap', "A365GatewayOwnership:$(([guid]$ownershipId).ToString('D'))")
        $actualTags = @($application.tags | ForEach-Object { [string]$_ })
        if ([string]$application.id -ne $objectId -or [string]$application.appId -ne $clientId -or
            (@($actualTags | Sort-Object -Unique) -join '|') -cne (@($expectedTags | Sort-Object -Unique) -join '|') -or
            $actualTags.Count -ne $expectedTags.Count -or [string]$application.signInAudience -cne 'AzureADMyOrg') { throw 'mismatch' }
        if (@($application.keyCredentials).Count -ne 0 -or
            @($application.spa.redirectUris).Count -ne 0 -or
            @($application.publicClient.redirectUris).Count -ne 0) { throw 'mismatch' }
        Assert-ExactApplicationAuthenticationSurface -Application $application -ApplicationLabel "$ApplicationKind application" | Out-Null
        $ownerIds = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/applications/$objectId/owners?`$select=id" | ForEach-Object { [string]$_.id })
        if ($ownerIds.Count -ne 1 -or -not $ownerIds[0].Equals($ownerObjectId, [StringComparison]::OrdinalIgnoreCase)) { throw 'mismatch' }
        if ($ApplicationKind -eq 'GatewayApi') {
            $expectedDisplayName = "A365 Gateway API - $($Config.projectName)-$($Config.environment)"
            $expectedAudience = "api://a365-gateway-$($Config.projectName)-$($Config.environment)"
            $expectedRoles = @('Gateway.Administrator', 'Gateway.Operator', 'Gateway.Auditor', 'Gateway.SupportReader')
            $actualRoles = @($application.appRoles | ForEach-Object { [string]$_.value })
            $adminRoles = @($application.appRoles | Where-Object { [string]$_.value -ceq 'Gateway.Administrator' })
            if ([string]$Evidence.gatewayApiScopeBaseUri -cne $expectedAudience -or
                [string]$Evidence.gatewayApiTokenAudience -cne $clientId -or
                [string]$application.displayName -cne $expectedDisplayName -or
                @($application.identifierUris).Count -ne 1 -or [string]$application.identifierUris[0] -cne $expectedAudience -or
                @($application.passwordCredentials).Count -ne 0 -or
                @($application.web.redirectUris).Count -ne 0 -or
                -not [string]::IsNullOrWhiteSpace([string]$application.web.logoutUrl) -or
                -not [string]::IsNullOrWhiteSpace([string]$application.web.homePageUrl) -or
                [int]$application.api.requestedAccessTokenVersion -ne 2 -or
                @($application.api.oauth2PermissionScopes).Count -ne 1 -or [string]$application.api.oauth2PermissionScopes[0].value -cne 'access_as_user' -or
                (@($actualRoles | Sort-Object -Unique) -join '|') -cne (@($expectedRoles | Sort-Object -Unique) -join '|') -or
                $actualRoles.Count -ne $expectedRoles.Count -or
                $adminRoles.Count -ne 1 -or [string]$adminRoles[0].id -ne [string]$Evidence.gatewayAdministratorRoleId -or
                [string]$application.api.oauth2PermissionScopes[0].id -ne [string]$Evidence.gatewayApiAccessScopeId -or
                @($application.appRoles | Where-Object { $_.isEnabled -ne $true -or @($_.allowedMemberTypes).Count -ne 1 -or [string]$_.allowedMemberTypes[0] -cne 'User' }).Count -gt 0) { throw 'mismatch' }

            $principals = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId%20eq%20'$clientId'&`$select=id,appId,passwordCredentials,keyCredentials,accountEnabled,appRoleAssignmentRequired,servicePrincipalType,servicePrincipalNames,tags,alternativeNames,appRoles,oauth2PermissionScopes")
            if ($principals.Count -ne 1 -or [string]$principals[0].id -ne [string]$Evidence.gatewayApiServicePrincipalId -or
                [string]$principals[0].appId -ne $clientId) { throw 'mismatch' }
            Assert-ExactBootstrapServicePrincipalBoundary `
                -ServicePrincipal $principals[0] `
                -ExpectedId ([string]$Evidence.gatewayApiServicePrincipalId) `
                -ExpectedAppId $clientId `
                -ServicePrincipalLabel 'Gateway API service principal' `
                -ExpectedServicePrincipalNames @($clientId, $expectedAudience) `
                -ExpectedTags $expectedTags `
                -ExpectedAppRoles @($application.appRoles) `
                -ExpectedOauth2PermissionScopes @($application.api.oauth2PermissionScopes) `
                -ExpectedAppRoleAssigneePrincipalId $ownerObjectId `
                -ExpectedAppRoleId ([string]$Evidence.gatewayAdministratorRoleId) | Out-Null
            Assert-GatewayApiDelegatedPermissionBoundary -Identity $Evidence | Out-Null
        }
        else {
            $expectedDisplayName = "A365 Gateway Admin UI - $($Config.projectName)-$($Config.environment)"
            $expectedRoles = @(Assert-ExactAdminUiGatewayRoleContract `
                -AppRoles @($application.appRoles) `
                -DeploymentOwnershipId $ownershipId)
            $adminRole = @($expectedRoles | Where-Object { [string]$_.value -ceq 'Administrator' })
            $requirements = @($application.requiredResourceAccess)
            $credentials = @($application.passwordCredentials)
            $expectedRedirect = if ([string]::IsNullOrWhiteSpace($ExpectedAdminUiUrl)) { '' } else { "$($ExpectedAdminUiUrl.TrimEnd('/'))/signin-oidc" }
            $expectedLogout = if ([string]::IsNullOrWhiteSpace($ExpectedAdminUiUrl)) { '' } else { "$($ExpectedAdminUiUrl.TrimEnd('/'))/signout-callback-oidc" }
            $actualRedirects = @($application.web.redirectUris)
            if ([string]$application.displayName -cne $expectedDisplayName -or @($application.identifierUris).Count -ne 0 -or
                @($application.api.oauth2PermissionScopes).Count -ne 0 -or
                $actualRedirects.Count -ne $(if ([string]::IsNullOrWhiteSpace($ExpectedAdminUiUrl)) { 0 } else { 1 }) -or
                ($actualRedirects.Count -eq 1 -and [string]$actualRedirects[0] -cne $expectedRedirect) -or
                [string]$application.web.logoutUrl -cne $expectedLogout -or
                -not [string]::IsNullOrWhiteSpace([string]$application.web.homePageUrl) -or
                $requirements.Count -ne 1 -or
                -not ([string]$requirements[0].resourceAppId).Equals([string]$Evidence.gatewayApiClientId, [StringComparison]::OrdinalIgnoreCase) -or
                @($requirements[0].resourceAccess).Count -ne 1 -or
                -not ([string]$requirements[0].resourceAccess[0].id).Equals([string]$Evidence.gatewayApiAccessScopeId, [StringComparison]::OrdinalIgnoreCase) -or
                [string]$requirements[0].resourceAccess[0].type -cne 'Scope' -or
                $credentials.Count -gt 1 -or @($credentials | Where-Object { [string]$_.displayName -cne 'a365gw-bootstrap-admin-ui' }).Count -gt 0) { throw 'mismatch' }

            foreach ($identifier in @(
                [string]$Evidence.adminUiServicePrincipalId,
                [string]$Evidence.gatewayApiClientId,
                [string]$Evidence.gatewayApiAccessScopeId
            )) { Assert-GuidValue -Value $identifier -Label 'Admin UI delegated-consent evidence identifier' }
            $adminPrincipals = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId%20eq%20'$clientId'&`$select=id,appId,passwordCredentials,keyCredentials,accountEnabled,appRoleAssignmentRequired,servicePrincipalType,servicePrincipalNames,tags,alternativeNames,appRoles,oauth2PermissionScopes")
            if ($adminPrincipals.Count -ne 1 -or [string]$adminPrincipals[0].id -ne [string]$Evidence.adminUiServicePrincipalId -or
                [string]$adminPrincipals[0].appId -ne $clientId) { throw 'mismatch' }
            Assert-ExactBootstrapServicePrincipalBoundary `
                -ServicePrincipal $adminPrincipals[0] `
                -ExpectedId ([string]$Evidence.adminUiServicePrincipalId) `
                -ExpectedAppId $clientId `
                -ServicePrincipalLabel 'Admin UI service principal' `
                -ExpectedServicePrincipalNames @($clientId) `
                -ExpectedTags $expectedTags `
                -ExpectedAppRoles @($application.appRoles) `
                -ExpectedOauth2PermissionScopes @() `
                -ExpectedAppRoleAssigneePrincipalId $ownerObjectId `
                -ExpectedAppRoleId ([string]$adminRole[0].id) | Out-Null
            $gatewayPrincipals = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId%20eq%20'$($Evidence.gatewayApiClientId)'&`$select=id,appId")
            if ($gatewayPrincipals.Count -ne 1 -or
                [string]$gatewayPrincipals[0].appId -ne [string]$Evidence.gatewayApiClientId) { throw 'mismatch' }
            $grants = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId%20eq%20'$($Evidence.adminUiServicePrincipalId)'&`$select=id,resourceId,consentType,scope")
            $grantScopes = @(
                if ($grants.Count -eq 1) {
                    ([string]$grants[0].scope).Split(
                        ' ',
                        [StringSplitOptions]::RemoveEmptyEntries -bor [StringSplitOptions]::TrimEntries)
                }
            )
            if ($grants.Count -ne 1 -or
                [string]$grants[0].resourceId -ne [string]$gatewayPrincipals[0].id -or
                [string]$grants[0].consentType -cne 'AllPrincipals' -or
                $grantScopes.Count -ne 1 -or [string]$grantScopes[0] -cne 'access_as_user') { throw 'mismatch' }
        }
        return $true
    }
    catch { throw 'Entra application revalidation was unavailable or mismatched; refusing automatic replay. Review access/state and run gateway diagnose.' }
}

function Test-GatewayWorkflowIdentityEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$Inert,
        [Parameter(Mandatory)]$Evidence
    )

    if (-not $Evidence -or
        $Evidence.workerApplicationRoles -isnot [System.Collections.IDictionary] -or
        $Evidence.apiApplicationRoles -isnot [System.Collections.IDictionary]) {
        throw 'Workflow identity evidence is incomplete; refusing automatic replay.'
    }
    try {
        $graphAppId = '00000003-0000-0000-c000-000000000000'
        $graphMatches = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId%20eq%20'$graphAppId'&`$select=id,appId,appRoles,oauth2PermissionScopes")
        if ($graphMatches.Count -ne 1) { throw 'mismatch' }
        $graph = $graphMatches[0]

        $expectedWorkerRoles = @(
            'Application.Read.All',
            'AppRoleAssignment.ReadWrite.All',
            'AgentIdentityBlueprint.Create',
            'AgentIdentityBlueprint.AddRemoveCreds.All',
            'AgentIdentityBlueprintPrincipal.Create',
            'AgentIdentityBlueprint.Read.All',
            'AgentIdentity.Create.All',
            'AgentIdentity.Read.All'
        )
        $expectedApiRoles = [Collections.Generic.List[string]]::new()
        $expectedApiRoles.Add('AgentIdentityBlueprint.Read.All')
        if ($Config.purview.enabled -eq $true) {
            foreach ($role in @('ProtectionScopes.Compute.User', 'Content.Process.User', 'ContentActivity.Write')) { $expectedApiRoles.Add($role) }
        }

        $workerEvidenceRoles = @($Evidence.workerApplicationRoles.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        $apiEvidenceRoles = @($Evidence.apiApplicationRoles.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        $delegatedEvidenceScopes = @($Evidence.delegatedRegistryScopes | ForEach-Object { [string]$_ } | Sort-Object)
        if (($workerEvidenceRoles -join '|') -ne (($expectedWorkerRoles | Sort-Object) -join '|') -or
            ($apiEvidenceRoles -join '|') -ne ((@($expectedApiRoles) | Sort-Object) -join '|') -or
            ($delegatedEvidenceScopes -join '|') -ne 'AgentRegistration.Read.All|AgentRegistration.ReadWrite.All') { throw 'mismatch' }

        foreach ($principal in @(
            [ordered]@{ id = [string]$Inert.workerPrincipalId; expected = $expectedWorkerRoles },
            [ordered]@{ id = [string]$Inert.apiPrincipalId; expected = @($expectedApiRoles) }
        )) {
            $allAssignments = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.id)/appRoleAssignments?`$select=id,resourceId,appRoleId")
            $graphAssignments = @($allAssignments | Where-Object { [string]$_.resourceId -eq [string]$graph.id })
            $actualValues = [Collections.Generic.List[string]]::new()
            foreach ($assignment in $graphAssignments) {
                $published = @($graph.appRoles | Where-Object { [string]$_.id -eq [string]$assignment.appRoleId -and $_.isEnabled -eq $true })
                if ($published.Count -ne 1) { throw 'mismatch' }
                $actualValues.Add([string]$published[0].value)
            }
            if ((@($actualValues | Sort-Object -Unique) -join '|') -ne ((@($principal.expected) | Sort-Object) -join '|')) { throw 'mismatch' }
            if ($actualValues.Count -ne @($principal.expected).Count -or $allAssignments.Count -ne @($principal.expected).Count) { throw 'mismatch' }
        }

        $application = Invoke-AzJson -Arguments @(
            'rest', '--method', 'GET', '--url',
            "https://graph.microsoft.com/v1.0/applications/$($Identity.gatewayApiApplicationObjectId)?`$select=id,appId,requiredResourceAccess"
        )
        if ([string]$application.appId -ne [string]$Identity.gatewayApiClientId) { throw 'mismatch' }
        $requiredScopeValues = @('AgentRegistration.Read.All', 'AgentRegistration.ReadWrite.All')
        $publishedScopes = @($graph.oauth2PermissionScopes | Where-Object { $_.isEnabled -eq $true -and [string]$_.value -in $requiredScopeValues })
        if ($publishedScopes.Count -ne 2) { throw 'mismatch' }
        $graphRequirements = @($application.requiredResourceAccess | Where-Object { [string]$_.resourceAppId -eq $graphAppId })
        if ($graphRequirements.Count -ne 1 -or @($application.requiredResourceAccess).Count -ne 1) { throw 'mismatch' }
        $requiredIds = @($publishedScopes | ForEach-Object { [string]$_.id } | Sort-Object)
        $actualRequiredIds = @($graphRequirements[0].resourceAccess | Where-Object type -eq 'Scope' | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
        if (($requiredIds -join '|') -ne ($actualRequiredIds -join '|') -or @($graphRequirements[0].resourceAccess).Count -ne 2) { throw 'mismatch' }

        $grants = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId%20eq%20'$($Identity.gatewayApiServicePrincipalId)'&`$select=id,resourceId,consentType,scope")
        if ($grants.Count -ne 1 -or [string]$grants[0].resourceId -ne [string]$graph.id -or
            [string]$grants[0].consentType -ne 'AllPrincipals') { throw 'mismatch' }
        $consentedScopes = @(([string]$grants[0].scope).Split(' ', [StringSplitOptions]::RemoveEmptyEntries) | Sort-Object -Unique)
        if (($consentedScopes -join '|') -ne (($requiredScopeValues | Sort-Object) -join '|')) { throw 'mismatch' }

        $ficName = "a365gw-$($Config.projectName)-api-obo-$($Config.environment)"
        if ([string]$Evidence.federatedCredentialName -ne $ficName) { throw 'mismatch' }
        $allFics = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/applications/$($Identity.gatewayApiApplicationObjectId)/federatedIdentityCredentials?`$select=id,name,issuer,subject,audiences")
        $fics = @($allFics | Where-Object name -eq $ficName)
        if ($fics.Count -ne 1 -or $allFics.Count -ne 1 -or
            [string]$fics[0].issuer -ne "https://login.microsoftonline.com/$($Config.tenantId)/v2.0" -or
            [string]$fics[0].subject -ne [string]$Inert.apiPrincipalId -or
            @($fics[0].audiences).Count -ne 1 -or
            [string]$fics[0].audiences[0] -ne 'api://AzureADTokenExchange') { throw 'mismatch' }
        return $true
    }
    catch {
        throw 'Workflow-v3 Entra revalidation was unavailable or mismatched; refusing automatic replay. Review identity/consent evidence and run gateway diagnose.'
    }
}

function Test-GatewayDatabaseEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Inert,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][System.Collections.IDictionary]$StepRecord,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$DatabaseMigratorImage,
        [Parameter()][AllowNull()][System.Collections.IDictionary]$DatabaseRecoveryPlan,
        [Parameter()][AllowNull()][System.Collections.IDictionary]$ManualDatabaseRepairPlan
    )

    try {
        $isRecovery = $null -ne $DatabaseRecoveryPlan
        $isManualRepair = $null -ne $ManualDatabaseRepairPlan
        if ($isRecovery -and $isManualRepair) { throw 'mismatch' }
        $isResumeAfterSchema = $isRecovery -or $isManualRepair
        $recoveryAttemptNumber = if ($isRecovery) { Get-GatewayDatabaseRecoveryAttemptNumber -RecoveryPlan $DatabaseRecoveryPlan } else { 0 }
        $recoveryContract = if ($isRecovery) { Get-GatewayDatabaseRecoveryAttemptContract -Config $Config -AttemptNumber $recoveryAttemptNumber } elseif ($isManualRepair) { Get-GatewayManualDatabaseRepairContract -Config $Config } else { $null }
        $expectedJobName = if ($isResumeAfterSchema) { [string]$recoveryContract.jobName } else { "job-$($Config.projectName)-db-init-$($Config.environment)" }
        $expectedJobImage = if ($isResumeAfterSchema) { [string]$Evidence.databaseBootstrapJobImage } else { $DatabaseMigratorImage }
        $expectedExecutionPattern = "^$([regex]::Escape($expectedJobName))-[a-z0-9]{5,16}$"
        $privateEndpointAddressTuple = Assert-GatewaySqlPrivateEndpointAddressEvidenceTuple `
            -Config $Config -SqlServerFqdn ([string]$Inert.sqlServerFqdn) -Evidence $Evidence
        if (-not $Evidence -or
            [string]$Evidence.database -ne 'GatewayDb' -or
            [string]$Evidence.server -ne [string]$Inert.sqlServerFqdn -or
            [string]$Evidence.networkMode -cne 'PrivateContainerAppsJob' -or
            $Evidence.privateNetworkExecutionVerified -ne $true -or
            $Evidence.publicNetworkRestoredToDisabled -ne $true -or
            $Evidence.temporaryFirewallRuleAbsenceVerified -ne $true -or
            $Evidence.networkRecoveryRecordCleared -ne $true -or
            -not ([string]$Evidence.networkOperationId).Equals(([guid]$DeploymentOwnershipId).ToString('D'), [StringComparison]::OrdinalIgnoreCase) -or
            [string]$Evidence.deploymentOwnershipId -cne ([guid]$DeploymentOwnershipId).ToString('D') -or
            [string]$Evidence.acceptedSourceFingerprint -cne $SourceFingerprint -or
            [string]$Evidence.schemaFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$Evidence.apiPrincipalName -cne "ca-gateway-api-$($Config.environment)" -or
            [string]$Evidence.workerPrincipalName -cne "ca-gateway-worker-$($Config.environment)-v3" -or
            [string]$Evidence.apiPrincipalObjectId -cne ([guid][string]$Inert.apiPrincipalId).ToString('D') -or
            [string]$Evidence.workerPrincipalObjectId -cne ([guid][string]$Inert.workerPrincipalId).ToString('D') -or
            [string]$Evidence.apiPrincipalClientId -cne ([guid][string]$Evidence.apiPrincipalClientId).ToString('D') -or
            [string]$Evidence.workerPrincipalClientId -cne ([guid][string]$Evidence.workerPrincipalClientId).ToString('D') -or
            [string]$Evidence.apiPrincipalClientId -ceq [string]$Evidence.workerPrincipalClientId -or
            $Evidence.legacyPublicBootstrapClientIpv4Unused -ne $true -or
            [string]$Evidence.databaseBootstrapJobName -cne $expectedJobName -or
            [string]$Evidence.databaseBootstrapJobId -cne "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.App/jobs/$expectedJobName" -or
            [string]$Evidence.databaseBootstrapJobPrincipalId -cne ([guid][string]$Evidence.databaseBootstrapJobPrincipalId).ToString('D') -or
            [string]$Evidence.databaseBootstrapJobImage -cne $expectedJobImage -or
            [string]$expectedJobImage -cnotmatch "^$([regex]::Escape([string]$Foundation.acrLoginServer))/gateway-db-migrator@sha256:[0-9a-f]{64}$" -or
            [string]$Evidence.databaseBootstrapExecutionName -cnotmatch $expectedExecutionPattern -or
            [string]$Evidence.databaseBootstrapExecutionIntentId -cne ([guid][string]$Evidence.databaseBootstrapExecutionIntentId).ToString('D') -or
            [guid][string]$Evidence.databaseBootstrapExecutionIntentId -eq [guid]::Empty -or
            [string]$Evidence.databaseBootstrapEvidenceFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$Evidence.originalSqlAdministratorObjectId -cne ([guid][string]$Evidence.originalSqlAdministratorObjectId).ToString('D') -or
            [string]::IsNullOrWhiteSpace([string]$Evidence.originalSqlAdministratorLogin) -or
            $Evidence.originalSqlAdministratorRestored -ne $true -or
            (@($Evidence.apiDirectPermissions | ForEach-Object { [string]$_ } | Sort-Object) -join '|') -cne 'VIEW DEFINITION' -or
            @($Evidence.workerDirectPermissions).Count -ne 0 -or
            $StepRecord.status -ne 'Completed' -or
            -not $StepRecord.Contains('startedAtUtc') -or
            -not $StepRecord.Contains('completedAtUtc')) { throw 'mismatch' }
        if ($isRecovery -and (
            [string]$DatabaseRecoveryPlan.status -cne 'Completed' -or
            [string]$Evidence.databaseRecoveryMode -cne 'ResumeAfterSchemaCompleted' -or
            [int]$Evidence.databaseRecoveryAttemptNumber -ne $recoveryAttemptNumber -or
            [string]$Evidence.databaseRecoveryPlanFingerprint -cne [string]$DatabaseRecoveryPlan.planFingerprint -or
            [string]$Evidence.recoverySourceFingerprint -cne [string]$DatabaseRecoveryPlan.correctedSourceFingerprint -or
            [string]$Evidence.originalFailedDatabaseBootstrapBoundaryFingerprint -cne [string]$DatabaseRecoveryPlan.failedJob.boundaryFingerprint -or
            ($recoveryAttemptNumber -eq 2 -and (
                [string]$Evidence.priorFailedDatabaseRecoveryBoundaryFingerprint -cne [string]$DatabaseRecoveryPlan.priorFailedRecovery.boundaryFingerprint -or
                [string]$Evidence.priorFailedDatabaseRecoveryPlanFingerprint -cne [string]$DatabaseRecoveryPlan.previousRecoveryPlanFingerprint)))) {
            throw 'mismatch'
        }
        if ($isManualRepair -and (
            [string]$ManualDatabaseRepairPlan.status -cne 'Completed' -or
            $ManualDatabaseRepairPlan.correctedImage -isnot [System.Collections.IDictionary] -or
            [string]$ManualDatabaseRepairPlan.correctedImage.state -cne 'DigestCheckpointed' -or
            [string]$ManualDatabaseRepairPlan.correctedImage.sourceFingerprint -cne [string]$ManualDatabaseRepairPlan.repairSourceFingerprint -or
            [string]$ManualDatabaseRepairPlan.correctedImage.deploymentOwnershipId -cne ([guid]$DeploymentOwnershipId).ToString('D') -or
            [string]$ManualDatabaseRepairPlan.correctedImage.recoveryPlanFingerprint -cne [string]$ManualDatabaseRepairPlan.planFingerprint -or
            [string]$ManualDatabaseRepairPlan.correctedImage.intentId -cne [string]$ManualDatabaseRepairPlan.repairJob.imageIntentId -or
            [string]$Evidence.databaseBootstrapJobImage -cne [string]$ManualDatabaseRepairPlan.correctedImage.image -or
            [string]$Evidence.manualDatabaseRepairMode -cne 'ResumeAfterSchemaCompleted' -or
            [string]$Evidence.manualDatabaseRepairPlanFingerprint -cne [string]$ManualDatabaseRepairPlan.planFingerprint -or
            [string]$Evidence.manualDatabaseRepairSourceFingerprint -cne [string]$ManualDatabaseRepairPlan.repairSourceFingerprint -or
            [string]$Evidence.exhaustedDatabaseRecoveryPlanFingerprint -cne [string]$ManualDatabaseRepairPlan.exhaustedRecoveryPlanFingerprint -or
            [string]$Evidence.originalFailedDatabaseBootstrapBoundaryFingerprint -cne [string]$ManualDatabaseRepairPlan.originalFailedJob.boundaryFingerprint -or
            [string]$Evidence.firstFailedDatabaseRecoveryBoundaryFingerprint -cne [string]$ManualDatabaseRepairPlan.firstFailedRecovery.boundaryFingerprint -or
            [string]$Evidence.secondFailedDatabaseRecoveryBoundaryFingerprint -cne [string]$ManualDatabaseRepairPlan.secondFailedRecovery.boundaryFingerprint)) {
            throw 'mismatch'
        }

        $serverName = ([string]$Evidence.server).Split('.')[0]
        $database = Invoke-AzJson -Arguments @('sql', 'db', 'show', '--resource-group', [string]$Config.resourceGroupName, '--server', $serverName, '--name', 'GatewayDb', '--query', '{name:name,status:status}')
        if ([string]$database.name -ne 'GatewayDb' -or [string]$database.status -ne 'Online') { throw 'mismatch' }
        $publicAccess = Invoke-AzTsv -Arguments @('sql', 'server', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $serverName, '--query', 'publicNetworkAccess')
        $azureAdOnly = Invoke-AzTsv -Arguments @('sql', 'server', 'ad-only-auth', 'get', '--resource-group', [string]$Config.resourceGroupName, '--name', $serverName, '--query', 'azureAdOnlyAuthentication')
        if ($publicAccess -ne 'Disabled' -or $azureAdOnly -cne 'true') { throw 'mismatch' }
        $operationMaterial = "$(([guid]$DeploymentOwnershipId).ToString('D').ToLowerInvariant())|$(([string]$Config.resourceGroupName).ToLowerInvariant())|$($serverName.ToLowerInvariant())|gatewaydb"
        $operationHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($operationMaterial))).ToLowerInvariant()
        $firewallRuleName = "temp-a365gw-migration-$($operationHash.Substring(0, 24))"
        $firewallRules = @(Invoke-AzJson -Arguments @('sql', 'server', 'firewall-rule', 'list', '--resource-group', [string]$Config.resourceGroupName, '--server', $serverName, '--query', '[].{name:name}'))
        if ($firewallRules.Count -ne 0 -or [string]$Evidence.temporaryFirewallRuleName -cne $firewallRuleName) { throw 'mismatch' }

        $sqlAdministrator = Get-GatewaySqlEntraAdministrator -Config $Config -ServerName $serverName
        if ([string]$sqlAdministrator.objectId -cne [string]$Evidence.originalSqlAdministratorObjectId -or
            [string]$sqlAdministrator.login -cne [string]$Evidence.originalSqlAdministratorLogin -or
            [string]$sqlAdministrator.tenantId -cne ([guid][string]$Config.tenantId).ToString('D')) { throw 'mismatch' }
        $apiPrincipal = [ordered]@{ displayName = [string]$Evidence.apiPrincipalName; clientId = [string]$Evidence.apiPrincipalClientId }
        $workerPrincipal = [ordered]@{ displayName = [string]$Evidence.workerPrincipalName; clientId = [string]$Evidence.workerPrincipalClientId }
        $job = Get-GatewayDatabaseBootstrapJobEvidence `
            -Config $Config -Foundation $Foundation -SqlServerFqdn ([string]$Evidence.server) `
            -ExpectedPrivateEndpointIpv4Address ([string]$privateEndpointAddressTuple.privateEndpointIpv4Address) `
            -JobImage $expectedJobImage `
            -DeploymentOwnershipId $DeploymentOwnershipId -SourceFingerprint $SourceFingerprint `
            -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
            -ExecutionIntentId ([string]$Evidence.databaseBootstrapExecutionIntentId) `
            -Recovery:$isRecovery `
            -ManualRepair:$isManualRepair `
            -RecoveryAttemptNumber $(if ($isRecovery) { $recoveryAttemptNumber } else { 1 }) `
            -RecoverySourceFingerprint $(if ($isRecovery) { [string]$DatabaseRecoveryPlan.correctedSourceFingerprint } else { '' }) `
            -RecoveryPlanFingerprint $(if ($isRecovery) { [string]$DatabaseRecoveryPlan.planFingerprint } else { '' }) `
            -ManualRepairSourceFingerprint $(if ($isManualRepair) { [string]$ManualDatabaseRepairPlan.repairSourceFingerprint } else { '' }) `
            -ManualRepairPlanFingerprint $(if ($isManualRepair) { [string]$ManualDatabaseRepairPlan.planFingerprint } else { '' }) `
            -OriginalFailedBoundaryFingerprint $(if ($isRecovery) { [string]$DatabaseRecoveryPlan.failedJob.boundaryFingerprint } elseif ($isManualRepair) { [string]$ManualDatabaseRepairPlan.originalFailedJob.boundaryFingerprint } else { '' }) `
            -PriorFailedRecoveryBoundaryFingerprint $(if ($isRecovery -and $recoveryAttemptNumber -eq 2) { [string]$DatabaseRecoveryPlan.priorFailedRecovery.boundaryFingerprint } else { '' }) `
            -FirstFailedRecoveryBoundaryFingerprint $(if ($isManualRepair) { [string]$ManualDatabaseRepairPlan.firstFailedRecovery.boundaryFingerprint } else { '' }) `
            -SecondFailedRecoveryBoundaryFingerprint $(if ($isManualRepair) { [string]$ManualDatabaseRepairPlan.secondFailedRecovery.boundaryFingerprint } else { '' })
        if ([string]$job.jobId -cne [string]$Evidence.databaseBootstrapJobId -or
            [string]$job.jobPrincipalId -cne [string]$Evidence.databaseBootstrapJobPrincipalId) { throw 'mismatch' }
        $executions = @(Get-GatewayDatabaseBootstrapExecutions -Config $Config -JobName ([string]$Evidence.databaseBootstrapJobName))
        if ($executions.Count -ne 1 -or
            [string]$executions[0].name -cne [string]$Evidence.databaseBootstrapExecutionName -or
            [string]$executions[0].status -cne 'Succeeded') { throw 'mismatch' }
        $execution = Get-GatewayDatabaseBootstrapExecutionEvidence `
            -Config $Config -JobName ([string]$Evidence.databaseBootstrapJobName) `
            -ExecutionName ([string]$Evidence.databaseBootstrapExecutionName) `
            -JobImage $expectedJobImage -SqlServerFqdn ([string]$Evidence.server) `
            -ExpectedPrivateEndpointIpv4Address ([string]$privateEndpointAddressTuple.privateEndpointIpv4Address) `
            -DeploymentOwnershipId $DeploymentOwnershipId -SourceFingerprint $SourceFingerprint `
            -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
            -ExecutionIntentId ([string]$Evidence.databaseBootstrapExecutionIntentId) -Recovery:$isRecovery `
            -ManualRepair:$isManualRepair `
            -RecoveryAttemptNumber $(if ($isRecovery) { $recoveryAttemptNumber } else { 1 })

        $ready = Invoke-WebRequest -Uri "https://$($Inert.apiFqdn)/health/ready" -Method Get -TimeoutSec 30 -SkipHttpErrorCheck
        if ([int]$ready.StatusCode -lt 200 -or [int]$ready.StatusCode -ge 300) { throw 'mismatch' }

        $root = Get-RepositoryRoot
        $evidenceRoot = [IO.Path]::GetFullPath((Join-Path $root '.bootstrap/evidence'))
        $databaseEvidenceRoot = [IO.Path]::GetFullPath((Join-Path $evidenceRoot "$($Config.resourceGroupName)/database"))
        $expectedDirectory = if ($isResumeAfterSchema) { [IO.Path]::GetFullPath((Join-Path $databaseEvidenceRoot ([string]$recoveryContract.evidenceDirectoryName))) } else { $databaseEvidenceRoot }
        if (-not $expectedDirectory.StartsWith($evidenceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFullPath([string]$Evidence.evidenceDirectory) -ne $expectedDirectory) { throw 'mismatch' }
        if (Test-Path -LiteralPath (Join-Path $databaseEvidenceRoot 'GatewayDb-network-recovery.json')) { throw 'mismatch' }
        $receiptPath = [IO.Path]::GetFullPath((Join-Path $databaseEvidenceRoot $(if ($isResumeAfterSchema) { [string]$recoveryContract.receiptFileName } else { 'private-database-bootstrap-receipt.json' })))
        if ([IO.Path]::GetFullPath([string]$Evidence.databaseBootstrapCompletionReceipt) -ne $receiptPath) { throw 'mismatch' }
        $receipt = Read-GatewayPrivateDatabaseBootstrapRecord -Path $receiptPath
        if ($isRecovery) {
            Assert-GatewayPrivateDatabaseRecoveryRecord `
                -Record $receipt -Config $Config -SqlServerFqdn ([string]$Evidence.server) `
                -JobImage ([string]$Evidence.databaseBootstrapJobImage) -DeploymentOwnershipId $DeploymentOwnershipId `
                -OriginalSourceFingerprint $SourceFingerprint -RecoverySourceFingerprint ([string]$DatabaseRecoveryPlan.correctedSourceFingerprint) `
                -RecoveryPlanFingerprint ([string]$DatabaseRecoveryPlan.planFingerprint) -FailedJob $DatabaseRecoveryPlan.failedJob `
                -ExpectedExecutionIntentId ([string]$DatabaseRecoveryPlan.recoveryJob.executionIntentId) `
                -RecoveryAttemptNumber $recoveryAttemptNumber `
                -PriorFailedRecovery $(if ($recoveryAttemptNumber -eq 2) { $DatabaseRecoveryPlan.priorFailedRecovery } else { $null }) `
                -OriginalAdministratorObjectId ([string]$Evidence.originalSqlAdministratorObjectId) `
                -OriginalAdministratorLogin ([string]$Evidence.originalSqlAdministratorLogin) `
                -SqlPrivateEndpoint $privateEndpointAddressTuple | Out-Null
        }
        elseif ($isManualRepair) {
            Assert-GatewayPrivateDatabaseManualRepairRecord `
                -Record $receipt -Config $Config -SqlServerFqdn ([string]$Evidence.server) `
                -JobImage ([string]$Evidence.databaseBootstrapJobImage) -DeploymentOwnershipId $DeploymentOwnershipId `
                -ManualRepairPlan $ManualDatabaseRepairPlan `
                -OriginalAdministratorObjectId ([string]$Evidence.originalSqlAdministratorObjectId) `
                -OriginalAdministratorLogin ([string]$Evidence.originalSqlAdministratorLogin) `
                -SqlPrivateEndpoint $privateEndpointAddressTuple | Out-Null
        }
        else {
            Assert-GatewayPrivateDatabaseBootstrapRecord `
                -Record $receipt -Config $Config -SqlServerFqdn ([string]$Evidence.server) `
                -JobName ([string]$Evidence.databaseBootstrapJobName) `
                -JobImage ([string]$Evidence.databaseBootstrapJobImage) `
                -DeploymentOwnershipId $DeploymentOwnershipId -SourceFingerprint $SourceFingerprint `
                -OriginalAdministratorObjectId ([string]$Evidence.originalSqlAdministratorObjectId) `
                -OriginalAdministratorLogin ([string]$Evidence.originalSqlAdministratorLogin) `
                -SqlPrivateEndpoint $privateEndpointAddressTuple | Out-Null
        }
        if ([string]::IsNullOrWhiteSpace([string]$receipt.completedAtUtc) -or
            [string]$receipt.executionName -cne [string]$Evidence.databaseBootstrapExecutionName -or
            [string]$receipt.executionIntentId -cne [string]$Evidence.databaseBootstrapExecutionIntentId -or
            [string]$receipt.evidenceFingerprint -cne [string]$Evidence.databaseBootstrapEvidenceFingerprint -or
            [string]$receipt.jobPrincipalId -cne [string]$Evidence.databaseBootstrapJobPrincipalId) { throw 'mismatch' }
        if ($isRecovery) {
            $originalFailure = Get-GatewayFailedDatabaseBootstrapBoundary `
                -Config $Config -Foundation $Foundation -SqlPrivateEndpoint $privateEndpointAddressTuple `
                -SqlServerFqdn ([string]$Evidence.server) -OriginalJobImage ([string]$DatabaseRecoveryPlan.failedJob.jobImage) `
                -DeploymentOwnershipId $DeploymentOwnershipId -OriginalSourceFingerprint $SourceFingerprint `
                -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
                -OriginalAdministratorObjectId ([string]$Evidence.originalSqlAdministratorObjectId) `
                -OriginalAdministratorLogin ([string]$Evidence.originalSqlAdministratorLogin)
            if ([string]$originalFailure.boundaryFingerprint -cne [string]$DatabaseRecoveryPlan.failedJob.boundaryFingerprint) {
                throw 'mismatch'
            }
            if ($recoveryAttemptNumber -eq 2) {
                $priorFailure = Get-GatewayFailedDatabaseRecoveryBoundary `
                    -Config $Config -Foundation $Foundation -SqlPrivateEndpoint $privateEndpointAddressTuple `
                    -SqlServerFqdn ([string]$Evidence.server) -RecoveryPlan $DatabaseRecoveryPlan.previousRecoveryPlan `
                    -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
                    -OriginalAdministratorObjectId ([string]$Evidence.originalSqlAdministratorObjectId) `
                    -OriginalAdministratorLogin ([string]$Evidence.originalSqlAdministratorLogin)
                if ([string]$priorFailure.boundaryFingerprint -cne [string]$DatabaseRecoveryPlan.priorFailedRecovery.boundaryFingerprint) {
                    throw 'mismatch'
                }
            }
        }
        elseif ($isManualRepair) {
            $originalFailure = Get-GatewayFailedDatabaseBootstrapBoundary `
                -Config $Config -Foundation $Foundation -SqlPrivateEndpoint $privateEndpointAddressTuple `
                -SqlServerFqdn ([string]$Evidence.server) -OriginalJobImage ([string]$ManualDatabaseRepairPlan.originalFailedJob.jobImage) `
                -DeploymentOwnershipId $DeploymentOwnershipId -OriginalSourceFingerprint $SourceFingerprint `
                -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
                -OriginalAdministratorObjectId ([string]$Evidence.originalSqlAdministratorObjectId) `
                -OriginalAdministratorLogin ([string]$Evidence.originalSqlAdministratorLogin)
            $firstFailure = Get-GatewayFailedDatabaseRecoveryBoundary `
                -Config $Config -Foundation $Foundation -SqlPrivateEndpoint $privateEndpointAddressTuple `
                -SqlServerFqdn ([string]$Evidence.server) -RecoveryPlan $ManualDatabaseRepairPlan.exhaustedRecoveryPlan.previousRecoveryPlan `
                -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
                -OriginalAdministratorObjectId ([string]$Evidence.originalSqlAdministratorObjectId) `
                -OriginalAdministratorLogin ([string]$Evidence.originalSqlAdministratorLogin)
            $secondFailure = Get-GatewayFailedDatabaseRecoveryBoundary `
                -Config $Config -Foundation $Foundation -SqlPrivateEndpoint $privateEndpointAddressTuple `
                -SqlServerFqdn ([string]$Evidence.server) -RecoveryPlan $ManualDatabaseRepairPlan.exhaustedRecoveryPlan `
                -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
                -OriginalAdministratorObjectId ([string]$Evidence.originalSqlAdministratorObjectId) `
                -OriginalAdministratorLogin ([string]$Evidence.originalSqlAdministratorLogin)
            if ([string]$originalFailure.boundaryFingerprint -cne [string]$ManualDatabaseRepairPlan.originalFailedJob.boundaryFingerprint -or
                [string]$firstFailure.boundaryFingerprint -cne [string]$ManualDatabaseRepairPlan.firstFailedRecovery.boundaryFingerprint -or
                [string]$secondFailure.boundaryFingerprint -cne [string]$ManualDatabaseRepairPlan.secondFailedRecovery.boundaryFingerprint) {
                throw 'mismatch'
            }
        }
        $executionStarted = [DateTimeOffset]::ParseExact(
            [string]$receipt.executionStartedAtUtc, 'O', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        $executionCompleted = [DateTimeOffset]::ParseExact(
            [string]$receipt.executionSucceededAtUtc, 'O', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        if ([string]$execution.startTimeUtc -cne $executionStarted.ToUniversalTime().ToString('O') -or
            [string]$execution.endTimeUtc -cne $executionCompleted.ToUniversalTime().ToString('O') -or
            $executionCompleted -lt $executionStarted) { throw 'mismatch' }
        $records = @()
        $expectedEvidenceNames = @(
            'GatewayDb-private-initialize.json',
            'GatewayDb-private-principal-api.json',
            'GatewayDb-private-principal-worker.json'
        )
        $actualEvidenceFiles = @(Get-ChildItem -LiteralPath $expectedDirectory -Filter 'GatewayDb-*.json' -File | Sort-Object Name)
        if ($actualEvidenceFiles.Count -ne 3 -or
            (@($actualEvidenceFiles.Name) -join '|') -cne (($expectedEvidenceNames | Sort-Object) -join '|')) { throw 'mismatch' }
        foreach ($fileName in $expectedEvidenceNames) {
            $parsedRecords = @(ConvertFrom-GatewayDatabaseEvidenceJson -Json (Get-Content -LiteralPath (Join-Path $expectedDirectory $fileName) -Raw))
            if ($parsedRecords.Count -ne 1) { throw 'mismatch' }
            $record = $parsedRecords[0]
            $verified = [DateTimeOffset]::Parse([string]$record.VerifiedAtUtc)
            if ($verified -lt $executionStarted.AddMinutes(-1) -or $verified -gt $executionCompleted.AddMinutes(1) -or
                [string]$record.ExecutionIntentId -cne [string]$Evidence.databaseBootstrapExecutionIntentId) { throw 'mismatch' }
            $records += $record
        }
        $initialize = @($records | Where-Object { [string]$_.Phase -eq 'initialize' -and [string]$_.Server -eq [string]$Evidence.server -and [string]$_.Database -eq 'GatewayDb' })
        if ($initialize.Count -ne 1 -or
            $initialize[0].Verification.CurrentEfModelReady -ne $true -or
            $initialize[0].Verification.WorkflowV2Ready -ne $true -or
            [string]$initialize[0].Verification.CurrentSchemaFingerprint -cne [string]$Evidence.schemaFingerprint -or
            [string]$initialize[0].InitializationIntent.MarkerName -cne 'A365GatewayBootstrapInitializationIntent' -or
            [int]$initialize[0].InitializationIntent.SchemaVersion -ne 1 -or
            [string]$initialize[0].InitializationIntent.DeploymentOwnershipId -cne ([guid]$DeploymentOwnershipId).ToString('D') -or
            [string]$initialize[0].InitializationIntent.AcceptedSourceFingerprint -cne $SourceFingerprint -or
            ($isResumeAfterSchema -and [string]$initialize[0].InitializationIntent.RecoveryMode -cne 'ResumeAfterSchemaCompleted') -or
            [string]$initialize[0].InitializationIntent.Server -cne [string]$Evidence.server -or
            [string]$initialize[0].InitializationIntent.Database -cne 'GatewayDb' -or
            [string]$initialize[0].InitializationIntent.DatabaseCollation -cne 'SQL_Latin1_General_CP1_CI_AS' -or
            [string]$initialize[0].InitializationIntent.CatalogCollation -cne 'SQL_Latin1_General_CP1_CI_AS' -or
            [string]$initialize[0].InitializationIntent.DatabaseOwnerSidSha256 -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            $initialize[0].InitializationIntent.ExactReadbackVerified -ne $true -or
            [string]$Evidence.initializationIntent.markerName -cne [string]$initialize[0].InitializationIntent.MarkerName -or
            [int]$Evidence.initializationIntent.schemaVersion -ne [int]$initialize[0].InitializationIntent.SchemaVersion -or
            [string]$Evidence.initializationIntent.deploymentOwnershipId -cne [string]$initialize[0].InitializationIntent.DeploymentOwnershipId -or
            [string]$Evidence.initializationIntent.acceptedSourceFingerprint -cne [string]$initialize[0].InitializationIntent.AcceptedSourceFingerprint -or
            [string]$Evidence.initializationIntent.server -cne [string]$initialize[0].InitializationIntent.Server -or
            [string]$Evidence.initializationIntent.database -cne [string]$initialize[0].InitializationIntent.Database -or
            [string]$Evidence.initializationIntent.databaseOwnerSidSha256 -cne [string]$initialize[0].InitializationIntent.DatabaseOwnerSidSha256 -or
            [string]$Evidence.initializationIntent.databaseCollation -cne [string]$initialize[0].InitializationIntent.DatabaseCollation -or
            [string]$Evidence.initializationIntent.catalogCollation -cne [string]$initialize[0].InitializationIntent.CatalogCollation -or
            $Evidence.initializationIntent.exactReadbackVerified -ne $true) { throw 'mismatch' }

        foreach ($expectedPrincipal in @(
            [ordered]@{ name = "ca-gateway-api-$($Config.environment)"; clientId = [string]$Evidence.apiPrincipalClientId },
            [ordered]@{ name = "ca-gateway-worker-$($Config.environment)-v3"; clientId = [string]$Evidence.workerPrincipalClientId }
        )) {
            $principalRecords = @($records | Where-Object {
                [string]$_.Phase -eq 'principal' -and
                [string]$_.RuntimePrincipal.Name -eq [string]$expectedPrincipal.name -and
                [string]$_.RuntimePrincipal.ClientId -eq [string]$expectedPrincipal.clientId
            })
            if ($principalRecords.Count -ne 1 -or
                $principalRecords[0].Verification.CurrentEfModelReady -ne $true -or
                $principalRecords[0].Verification.WorkflowV2Ready -ne $true -or
                [string]$principalRecords[0].Verification.CurrentSchemaFingerprint -cne [string]$Evidence.schemaFingerprint) { throw 'mismatch' }
            $roles = @($principalRecords[0].RuntimePrincipal.DatabaseRoles | ForEach-Object { [string]$_ } | Sort-Object)
            if (($roles -join '|') -ne 'db_datareader|db_datawriter') { throw 'mismatch' }
            $directPermissions = @($principalRecords[0].RuntimePrincipal.DirectPermissions | ForEach-Object { [string]$_ } | Sort-Object)
            $expectedDirectPermissions = if ([string]$expectedPrincipal.name -ceq [string]$Evidence.apiPrincipalName) { @('VIEW DEFINITION') } else { @() }
            if (($directPermissions -join '|') -cne ($expectedDirectPermissions -join '|')) { throw 'mismatch' }
        }
        if ([string]$Evidence.databaseBootstrapEvidenceFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject @($records))) { throw 'mismatch' }
        return $true
    }
    catch {
        throw 'Gateway database revalidation was unavailable or mismatched; refusing automatic initialization or principal replay. Review SQL/evidence and run gateway diagnose.'
    }
}

function Test-GatewayAdminCredentialEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AdminIdentity,
        [Parameter(Mandatory)]$Inert,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    try {
        $ownershipId = [guid]::Empty
        $credentialKeyId = [guid]::Empty
        if (-not [guid]::TryParse($DeploymentOwnershipId, [ref]$ownershipId) -or
            $ownershipId -eq [guid]::Empty -or
            $DeploymentOwnershipId -cne $ownershipId.ToString('D') -or
            [string]$AdminIdentity.deploymentOwnershipId -cne $ownershipId.ToString('D')) {
            throw 'mismatch'
        }
        Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Admin UI credential evidence source fingerprint'
        $evidenceNames = @(Get-GatewayArmObjectPropertyNames -Object $Evidence)
        $expectedEvidenceNames = @(
            'secretUri', 'credentialKeyId', 'credentialExpiresAtUtc',
            'deploymentOwnershipId', 'sourceFingerprint', 'contentType'
        )
        if ($evidenceNames.Count -ne $expectedEvidenceNames.Count -or
            @($expectedEvidenceNames | Where-Object { $evidenceNames -cnotcontains $_ }).Count -ne 0 -or
            -not [guid]::TryParse([string]$Evidence.credentialKeyId, [ref]$credentialKeyId) -or
            $credentialKeyId -eq [guid]::Empty -or
            [string]$Evidence.credentialKeyId -cne $credentialKeyId.ToString('D') -or
            [string]$Evidence.deploymentOwnershipId -cne $ownershipId.ToString('D') -or
            [string]$Evidence.sourceFingerprint -cne $SourceFingerprint -or
            [string]$Evidence.contentType -cne 'application/vnd.a365-gateway.admin-ui-entra-client-secret') {
            throw 'mismatch'
        }
        $expectedSecretUri = "$(([string]$Inert.keyVaultUri).TrimEnd('/'))/secrets/admin-ui-entra-client-secret"
        if ([string]$Evidence.secretUri -ne $expectedSecretUri) { throw 'mismatch' }

        $application = Invoke-AzJson -Arguments @(
            'rest', '--method', 'GET', '--url',
            "https://graph.microsoft.com/v1.0/applications/$($AdminIdentity.adminUiApplicationObjectId)?`$select=id,appId,passwordCredentials"
        )
        if ([string]$application.appId -ne [string]$AdminIdentity.adminUiClientId) { throw 'mismatch' }
        $credentials = @($application.passwordCredentials | Where-Object { [string]$_.keyId -eq [string]$Evidence.credentialKeyId -and [string]$_.displayName -eq 'a365gw-bootstrap-admin-ui' })
        if ($credentials.Count -ne 1) { throw 'mismatch' }
        $expires = [DateTimeOffset]::Parse(
            [string]$credentials[0].endDateTime,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        $evidenceExpires = [DateTimeOffset]::Parse(
            [string]$Evidence.credentialExpiresAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        if ($expires -le [DateTimeOffset]::UtcNow -or
            $expires.ToUniversalTime() -ne $evidenceExpires.ToUniversalTime()) { throw 'mismatch' }

        # This helper uses an exact management-plane projection and rejects any
        # value-bearing or extra metadata before returning the safe shape.
        $secretMetadata = Get-GatewayAdminUiCredentialSecretArmMetadata `
            -Config $Config `
            -KeyVaultUri ([string]$Inert.keyVaultUri) `
            -DeploymentOwnershipId $ownershipId.ToString('D') `
            -SourceFingerprint $SourceFingerprint
        if ([string]$secretMetadata.status -cne 'Present' -or
            [string]$secretMetadata.tags.credentialKeyId -cne $credentialKeyId.ToString('D')) {
            throw 'mismatch'
        }
        return $true
    }
    catch {
        throw 'Admin UI credential metadata revalidation was unavailable or mismatched; refusing automatic credential creation. No secret value was requested. Review Entra/Key Vault metadata and run gateway diagnose.'
    }
}

function Test-GatewayPurviewEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Blueprint,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [switch]$NonInteractive
    )

    if ($Config.purview.enabled -ne $true) {
        if ($Evidence -and $Evidence.configured -eq $false -and $Evidence.enabled -eq $false) { return $true }
        throw 'Disabled Purview evidence is inconsistent; refusing automatic replay.'
    }
    if ($NonInteractive) {
        throw 'Purview revalidation requires an interactive Security & Compliance session; refusing automatic policy replay in non-interactive mode.'
    }
    try {
        if (-not $Evidence -or $Evidence.configured -ne $true -or
            [string]$Evidence.blueprintApplicationId -ne [string]$Blueprint.applicationId -or
            [string]$Evidence.enforcementPlane -ne 'Application' -or
            $Evidence.exactTypedReadback -ne $true) { throw 'mismatch' }
        $connectionId = Connect-BootstrapPurview -UserPrincipalName $UserPrincipalName -TenantId ([string]$Config.tenantId)
        $readback = Get-BootstrapPurviewPolicyEvidence -Config $Config -Blueprint $Blueprint -MaximumAttempts 1
        if ($readback.exactTypedReadback -ne $true -or
            [string]$readback.collectionPolicyName -cne [string]$Evidence.collectionPolicyName -or
            [string]$readback.dlpPolicyName -cne [string]$Evidence.dlpPolicyName -or
            [string]$readback.dlpRuleName -cne [string]$Evidence.dlpRuleName) { throw 'mismatch' }
        return $true
    }
    catch {
        throw 'Purview policy revalidation was unavailable or mismatched; refusing automatic policy replay. Reauthenticate interactively and review the tenant policies.'
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($connectionId)) { Disconnect-BootstrapPurview -ConnectionId $connectionId }
    }
}

function Test-GatewayBlueprintEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$SponsorObjectId,
        [Parameter(Mandatory)][string]$GatewayManagedIdentityPrincipalId
    )
    if (-not $Evidence) { throw 'Blueprint evidence is incomplete; refusing automatic replay.' }
    try {
        $expectedDisplayName = Get-Agent365SeedBlueprintDisplayName `
            -Config $Config `
            -DeploymentOwnershipId $DeploymentOwnershipId `
            -SourceFingerprint $SourceFingerprint
        $blueprint = Get-Agent365BlueprintByName -DisplayName $expectedDisplayName
        if (-not $blueprint) { throw 'mismatch' }
        $current = Assert-Agent365SeedBlueprintSurface `
            -Blueprint $blueprint `
            -Config $Config `
            -ExpectedDisplayName $expectedDisplayName `
            -DeploymentOwnershipId $DeploymentOwnershipId `
            -SourceFingerprint $SourceFingerprint `
            -SponsorObjectId $SponsorObjectId `
            -GatewayManagedIdentityPrincipalId $GatewayManagedIdentityPrincipalId
        $evidenceManagers = @(Get-Agent365CanonicalIdentifierCollection -Values @($Evidence.managerApplicationIds) -Label 'Persisted Agent ID manager applications' -RequireNonEmpty)
        if ([int]$Evidence.schemaVersion -ne 2 -or
            [string]$Evidence.provenance -cne 'BootstrapOwnedDirectGraphV1' -or
            [string]$Evidence.objectId -cne [string]$current.objectId -or
            [string]$Evidence.applicationId -cne [string]$current.applicationId -or
            [string]$Evidence.displayName -cne $expectedDisplayName -or
            [string]$Evidence.deploymentOwnershipId -cne ([guid]$DeploymentOwnershipId).ToString('D') -or
            [string]$Evidence.sourceFingerprint -cne $SourceFingerprint -or
            [string]$Evidence.ownerObjectId -cne ([guid]$SponsorObjectId).ToString('D') -or
            [string]$Evidence.sponsorObjectId -cne ([guid]$SponsorObjectId).ToString('D') -or
            @($Evidence.ownerObjectIds).Count -ne 1 -or [string]$Evidence.ownerObjectIds[0] -cne ([guid]$SponsorObjectId).ToString('D') -or
            @($Evidence.sponsorObjectIds).Count -ne 1 -or [string]$Evidence.sponsorObjectIds[0] -cne ([guid]$SponsorObjectId).ToString('D') -or
            $Evidence.managerApplicationsPreflightConfirmed -ne $true -or
            $Evidence.credentialCreationPerformed -ne $false -or
            $Evidence.pristineAuthoritySurfaceConfirmed -ne $true -or
            ($evidenceManagers -join '|') -cne (@($current.managerApplicationIds) -join '|')) { throw 'mismatch' }
        return $true
    }
    catch { throw 'Agent ID blueprint revalidation was unavailable or mismatched; refusing automatic replay. Review access/state and run gateway diagnose.' }
}

function Test-GatewaySqlPrivateEndpointEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $validationStage = 'persisted evidence'
    try {
        $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
        Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'SQL private-endpoint source fingerprint'
        if ($DeploymentOwnershipId -cne $canonicalOwnershipId) { throw 'mismatch' }
        $serverName = $SqlServerFqdn.Split('.')[0]
        $resourceGroupScope = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)"
        $serverId = "$resourceGroupScope/providers/Microsoft.Sql/servers/$serverName"
        $privateEndpointId = "$resourceGroupScope/providers/Microsoft.Network/privateEndpoints/pe-$serverName"
        $zoneId = "$resourceGroupScope/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net"
        $linkId = "$zoneId/virtualNetworkLinks/link-$($Config.projectName)-$($Config.environment)-sql"
        $zoneGroupId = "$privateEndpointId/privateDnsZoneGroups/sqlDnsGroup"
        $recordSetId = "$zoneId/A/$serverName"
        $deploymentName = "a365gw-$($Config.projectName)-bootstrap-sql-private-$($Config.environment)"
        foreach ($property in @(
            [ordered]@{ name = 'deploymentName'; expected = $deploymentName },
            [ordered]@{ name = 'deploymentOwnershipId'; expected = $canonicalOwnershipId },
            [ordered]@{ name = 'sourceFingerprint'; expected = $SourceFingerprint },
            [ordered]@{ name = 'privateEndpointId'; expected = $privateEndpointId },
            [ordered]@{ name = 'privateDnsZoneId'; expected = $zoneId },
            [ordered]@{ name = 'virtualNetworkLinkId'; expected = $linkId },
            [ordered]@{ name = 'privateDnsZoneGroupId'; expected = $zoneGroupId },
            [ordered]@{ name = 'sqlServerId'; expected = $serverId },
            [ordered]@{ name = 'privateEndpointSubnetId'; expected = [string]$Foundation.privateEndpointSubnetId },
            [ordered]@{ name = 'virtualNetworkId'; expected = [string]$Foundation.virtualNetworkId },
            [ordered]@{ name = 'privateDnsARecordSetId'; expected = $recordSetId },
            [ordered]@{ name = 'privateDnsARecordName'; expected = $serverName }
        )) {
            if (-not ([string]$Evidence[$property.name]).Equals([string]$property.expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'mismatch' }
        }
        Assert-BootstrapIpv4Value -Value ([string]$Evidence.privateEndpointIpv4Address) -Label 'Persisted SQL private-endpoint IPv4 address'
        Assert-BootstrapIpv4Value -Value ([string]$Evidence.privateDnsARecordIpv4Address) -Label 'Persisted SQL private DNS A-record IPv4 address'
        if ([string]$Evidence.privateEndpointIpv4Address -cne [string]$Evidence.privateDnsARecordIpv4Address -or
            [string]::IsNullOrWhiteSpace([string]$Evidence.privateEndpointNetworkInterfaceId)) { throw 'mismatch' }

        $validationStage = 'ARM deployment readback'
        $deployment = Invoke-AzJson -Arguments @(
            'deployment', 'group', 'show', '--resource-group', [string]$Config.resourceGroupName,
            '--name', $deploymentName, '--query', '{state:properties.provisioningState,parameters:properties.parameters,outputs:properties.outputs}'
        )
        if ([string]$deployment.state -cne 'Succeeded' -or
            [string]$deployment.parameters.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
            [string]$deployment.parameters.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
            -not ([string]$deployment.parameters.privateEndpointSubnetId.value).Equals([string]$Foundation.privateEndpointSubnetId, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$deployment.parameters.virtualNetworkId.value).Equals([string]$Foundation.virtualNetworkId, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$deployment.parameters.sqlServerName.value -cne $serverName -or
            -not ([string]$deployment.outputs.privateEndpointId.value).Equals($privateEndpointId, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$deployment.outputs.privateDnsZoneId.value).Equals($zoneId, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$deployment.outputs.virtualNetworkLinkId.value).Equals($linkId, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$deployment.outputs.privateDnsZoneGroupId.value).Equals($zoneGroupId, [StringComparison]::OrdinalIgnoreCase)) { throw 'mismatch' }

        $validationStage = 'private endpoint readback'
        $privateEndpoint = Invoke-AzJson -Arguments @('network', 'private-endpoint', 'show', '--ids', $privateEndpointId)
        $connections = @($privateEndpoint.privateLinkServiceConnections)
        $manualConnections = @($privateEndpoint.manualPrivateLinkServiceConnections)
        $validationStage = 'private endpoint identity and ownership readback'
        if (-not ([string]$privateEndpoint.id).Equals($privateEndpointId, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$privateEndpoint.name -cne "pe-$serverName" -or
            [string]$privateEndpoint.location -cne [string]$Config.location -or
            [string]$privateEndpoint.provisioningState -cne 'Succeeded' -or
            [string]$privateEndpoint.tags.bootstrapOwnershipId -cne $canonicalOwnershipId -or
            [string]$privateEndpoint.tags.bootstrapSourceFingerprint -cne $SourceFingerprint) { throw 'mismatch' }
        $validationStage = 'private endpoint subnet and connection cardinality readback'
        if (-not ([string]$privateEndpoint.subnet.id).Equals([string]$Foundation.privateEndpointSubnetId, [StringComparison]::OrdinalIgnoreCase) -or
            $manualConnections.Count -ne 0 -or $connections.Count -ne 1) { throw 'mismatch' }
        $connectionGroupIds = @($connections[0].groupIds | ForEach-Object { [string]$_ })
        $validationStage = 'private endpoint SQL connection name readback'
        if ([string]$connections[0].name -cne "peconn-$serverName") { throw 'mismatch' }
        $validationStage = 'private endpoint SQL resource binding readback'
        if (-not ([string]$connections[0].privateLinkServiceId).Equals($serverId, [StringComparison]::OrdinalIgnoreCase)) { throw 'mismatch' }
        $validationStage = 'private endpoint SQL group binding readback'
        if ($connectionGroupIds.Count -ne 1 -or
            -not [string]::Equals([string]($connectionGroupIds[0]), 'sqlServer', [StringComparison]::Ordinal)) { throw 'mismatch' }
        $validationStage = 'private endpoint SQL approval readback'
        if ([string]$connections[0].privateLinkServiceConnectionState.status -cne 'Approved') { throw 'mismatch' }

        $validationStage = 'private DNS zone readback'
        $zone = Invoke-AzJson -Arguments @('network', 'private-dns', 'zone', 'show', '--ids', $zoneId)
        if (-not ([string]$zone.id).Equals($zoneId, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$zone.name -cne 'privatelink.database.windows.net' -or
            [string]$zone.location -cne 'global' -or
            [string]$zone.tags.bootstrapOwnershipId -cne $canonicalOwnershipId -or
            [string]$zone.tags.bootstrapSourceFingerprint -cne $SourceFingerprint) { throw 'mismatch' }

        $validationStage = 'private DNS virtual-network link readback'
        $link = Invoke-AzJson -Arguments @('network', 'private-dns', 'link', 'vnet', 'show', '--ids', $linkId)
        if (-not ([string]$link.id).Equals($linkId, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$link.name -cne "link-$($Config.projectName)-$($Config.environment)-sql" -or
            [string]$link.location -cne 'global' -or
            [string]$link.provisioningState -cne 'Succeeded' -or
            $link.registrationEnabled -ne $false -or
            -not ([string]$link.virtualNetwork.id).Equals([string]$Foundation.virtualNetworkId, [StringComparison]::OrdinalIgnoreCase)) { throw 'mismatch' }

        $validationStage = 'private DNS zone-group readback'
        $zoneGroup = Invoke-AzJson -Arguments @('network', 'private-endpoint', 'dns-zone-group', 'show', '--ids', $zoneGroupId)
        $zoneConfigs = @($zoneGroup.privateDnsZoneConfigs)
        if (-not ([string]$zoneGroup.id).Equals($zoneGroupId, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$zoneGroup.name -cne 'sqlDnsGroup' -or [string]$zoneGroup.provisioningState -cne 'Succeeded' -or
            $zoneConfigs.Count -ne 1 -or [string]$zoneConfigs[0].name -cne 'sql' -or
            -not ([string]$zoneConfigs[0].privateDnsZoneId).Equals($zoneId, [StringComparison]::OrdinalIgnoreCase)) { throw 'mismatch' }

        $validationStage = 'SQL server connection enumeration'
        $serverConnections = @(Invoke-AzJsonArray -OperationLabel 'SQL server private-endpoint connection discovery' -Arguments @(
            'network', 'private-endpoint-connection', 'list', '--id', $serverId,
            '--query', '[].{id:id,privateEndpointId:properties.privateEndpoint.id,status:properties.privateLinkServiceConnectionState.status}'
        ))
        if ($serverConnections.Count -ne 1 -or
            -not ([string]$serverConnections[0].privateEndpointId).Equals($privateEndpointId, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$serverConnections[0].status -cne 'Approved') { throw 'mismatch' }
        $validationStage = 'private endpoint NIC and private DNS A-record convergence readback'
        $addressEvidence = Get-GatewaySqlPrivateEndpointReadyAddressEvidence `
            -Config $Config -Foundation $Foundation -SqlServerFqdn $SqlServerFqdn
        foreach ($propertyName in @(
            'privateEndpointNetworkInterfaceId', 'privateEndpointIpv4Address',
            'privateDnsARecordSetId', 'privateDnsARecordName', 'privateDnsARecordIpv4Address'
        )) {
            if (-not ([string]$addressEvidence[$propertyName]).Equals(
                    [string]$Evidence[$propertyName], [StringComparison]::OrdinalIgnoreCase)) { throw 'mismatch' }
        }
        return $true
    }
    catch {
        throw "SQL private endpoint, approval, subnet, and private-DNS evidence failed at the reviewed $validationStage boundary; refusing automatic replay."
    }
}

function Test-GatewayImmutableImageEvidence {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId
    )
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Image-build source fingerprint'
    if (-not $Evidence -or [int]$Evidence.schemaVersion -ne 3 -or
        [string]$Evidence.registry -cnotmatch '^[a-z0-9]{5,50}$' -or
        [string]$Evidence.sourceFingerprint -cne $SourceFingerprint -or
        [string]$Evidence.deploymentOwnershipId -cne $DeploymentOwnershipId -or
        [string]$Evidence.provenance -cne 'BootstrapPreMutationIntentV3' -or
        $Evidence.buildIntents -isnot [System.Collections.IDictionary] -or
        (@($Evidence.buildIntents.Keys | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join '|') -cne 'adminUi|api|databaseMigrator|worker' -or
        @($Evidence.buildIntents.Keys).Count -ne 4 -or
        (@($Evidence.checkpointedComponents | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join '|') -cne 'adminUi|api|databaseMigrator|worker' -or
        @($Evidence.checkpointedComponents).Count -ne 4) { throw 'Immutable-image evidence is incomplete or belongs to different state/source; refusing automatic replay.' }
    try {
        $loginServer = Invoke-AzTsv -Arguments @('acr', 'show', '--name', [string]$Evidence.registry, '--query', 'loginServer')
        if ([string]::IsNullOrWhiteSpace($loginServer)) { throw 'mismatch' }
    }
    catch { throw 'Immutable-image registry revalidation was unavailable or mismatched; refusing automatic rebuild. Review access/state and run gateway diagnose.' }
    $repositories = [ordered]@{
        api = 'gateway-api'
        worker = 'gateway-worker'
        adminUi = 'gateway-admin'
        databaseMigrator = 'gateway-db-migrator'
    }
    foreach ($name in @('api', 'worker', 'adminUi', 'databaseMigrator')) {
        $intent = $Evidence.buildIntents[$name]
        try {
            $canonicalIntentId = ([guid][string]$intent.intentId).ToString('D')
            $expectedTag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $DeploymentOwnershipId `
                -SourceFingerprint $SourceFingerprint `
                -IntentId $canonicalIntentId
        }
        catch { throw 'Immutable-image intent evidence is malformed; refusing automatic replay.' }
        $repository = [string]$repositories[$name]
        $image = [string]$Evidence[$name]
        $recordedDigest = [string]$Evidence["${name}Digest"]
        $runId = [string]$intent.runId
        if ([string]$intent.component -cne $name -or [string]$intent.repository -cne $repository -or
            [string]$intent.intentId -cne $canonicalIntentId -or [string]$intent.tag -cne $expectedTag -or
            [string]$intent.state -cne 'DigestCheckpointed' -or $runId -cnotmatch '^[A-Za-z0-9-]{1,64}$' -or
            [string]$intent.digest -cne $recordedDigest -or
            [string]$intent.image -cne $image) {
            throw 'Immutable-image intent and digest evidence are incomplete or mismatched; refusing automatic replay.'
        }
        if ($image -cnotmatch '^[a-z0-9.-]+/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$' -or
            -not [string]::Equals($image, "$loginServer/$repository@$recordedDigest", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Immutable-image evidence is malformed; refusing automatic replay.'
        }
        try {
            $run = Invoke-AzJson -Arguments @(
                'acr', 'task', 'show-run', '--registry', [string]$Evidence.registry, '--run-id', $runId,
                '--query', '{runId:runId,status:status,runType:runType,outputImages:outputImages}'
            )
            $runImages = @($run.outputImages)
            if ([string]$run.runId -cne $runId -or [string]$run.status -cne 'Succeeded' -or
                [string]$run.runType -cne 'QuickRun' -or $runImages.Count -ne 1 -or
                [string]$runImages[0].repository -cne $repository -or
                [string]$runImages[0].tag -cne $expectedTag -or
                [string]$runImages[0].digest -cne $recordedDigest) { throw 'mismatch' }
            $digest = Invoke-AzTsv -Arguments @('acr', 'manifest', 'show-metadata', '--registry', [string]$Evidence.registry, '--name', "${repository}:$expectedTag", '--query', 'digest')
            if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
                $recordedDigest -cne $digest -or
                -not $image.EndsWith("@$digest", [StringComparison]::Ordinal)) { throw 'mismatch' }
        }
        catch { throw 'Immutable-image revalidation was unavailable or mismatched; refusing automatic rebuild. Review access/state and run gateway diagnose.' }
    }
    return $true
}

function Test-GatewayAdminRedirectEvidence {
    param([Parameter(Mandatory)]$AdminIdentity, [Parameter(Mandatory)]$AdminUi)
    if (-not $AdminIdentity -or -not $AdminUi -or -not (Test-GatewayHttpsUrl -Url ([string]$AdminUi.adminUiUrl))) { throw 'Admin redirect evidence is incomplete; refusing automatic replay.' }
    try {
        $application = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/applications/$($AdminIdentity.adminUiApplicationObjectId)?`$select=web,spa,publicClient,keyCredentials")
        $base = ([string]$AdminUi.adminUiUrl).TrimEnd('/')
        if (@($application.web.redirectUris).Count -ne 1 -or
            [string]$application.web.redirectUris[0] -cne "$base/signin-oidc" -or
            [string]$application.web.logoutUrl -cne "$base/signout-callback-oidc" -or
            -not [string]::IsNullOrWhiteSpace([string]$application.web.homePageUrl) -or
            @($application.spa.redirectUris).Count -ne 0 -or
            @($application.publicClient.redirectUris).Count -ne 0 -or
            @($application.keyCredentials).Count -ne 0) { throw 'mismatch' }
        return $true
    }
    catch { throw 'Admin redirect revalidation was unavailable or mismatched; refusing automatic replay. Review access/state and run gateway diagnose.' }
}

Export-ModuleMember -Function *
