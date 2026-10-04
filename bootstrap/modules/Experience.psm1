Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-GatewayBootstrapStepNames { return @(Get-GatewayRuntimeBootstrapStepNames) }

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

function Get-GatewaySetupConfigurationMember {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    # A previously written configuration may be partial or hand-edited, so a
    # missing member reads as absent rather than terminating the wizard.
    if ($null -eq $InputObject) { return '' }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return [string]$InputObject[$Name] }
        return ''
    }
    $member = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $member) { return '' }
    return [string]$member.Value
}

function Get-GatewaySetupIdentityDefaults {
    [CmdletBinding()]
    param(
        [AllowNull()]$ExistingConfiguration,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SubscriptionId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TenantId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Environment,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FallbackProjectName
    )

    # Subscription, tenant, environment, location, project name, and resource
    # group together pin the deployment identity that recorded evidence
    # describes. Offer the project name and resource group back only when the
    # subscription, tenant, and environment all match, because that is the only
    # case where reusing them reconciles the existing deployment rather than
    # naming a different one. A region is an account-scoped choice, so it keeps
    # its wider account-level condition.
    $recordedSubscriptionId = Get-GatewaySetupConfigurationMember -InputObject $ExistingConfiguration -Name 'subscriptionId'
    $recordedTenantId = Get-GatewaySetupConfigurationMember -InputObject $ExistingConfiguration -Name 'tenantId'
    $recordedEnvironment = Get-GatewaySetupConfigurationMember -InputObject $ExistingConfiguration -Name 'environment'

    $sameAccount = ($null -ne $ExistingConfiguration) -and
        ($recordedSubscriptionId -ceq $SubscriptionId) -and
        ($recordedTenantId -ceq $TenantId) -and
        (-not [string]::IsNullOrWhiteSpace($recordedSubscriptionId)) -and
        (-not [string]::IsNullOrWhiteSpace($recordedTenantId))
    $sameDeployment = $sameAccount -and ($recordedEnvironment -ceq $Environment)

    $projectName = $FallbackProjectName
    $resourceGroupName = ''
    $location = ''
    if ($sameAccount) {
        $location = Get-GatewaySetupConfigurationMember -InputObject $ExistingConfiguration -Name 'location'
    }
    if ($sameDeployment) {
        $recordedProjectName = Get-GatewaySetupConfigurationMember -InputObject $ExistingConfiguration -Name 'projectName'
        if (-not [string]::IsNullOrWhiteSpace($recordedProjectName)) { $projectName = $recordedProjectName }
        $resourceGroupName = Get-GatewaySetupConfigurationMember -InputObject $ExistingConfiguration -Name 'resourceGroupName'
    }

    return [ordered]@{
        sameAccount = [bool]$sameAccount
        sameDeployment = [bool]$sameDeployment
        projectName = [string]$projectName
        resourceGroupName = [string]$resourceGroupName
        location = [string]$location
    }
}

function Read-GatewayBootstrapCapabilities {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('dev', 'staging', 'prod')][string]$Environment,
        [ValidateSet('runtime')][string]$DeployProfile = 'runtime'
    )

    Write-Host ''
    Write-Host 'Capabilities to install' -ForegroundColor Cyan
    # Every installation reviews both integrations. A preset must never suppress
    # the tenant-access question or silently consent to provisioning.
    $registryPreview = $false

    $registryBetaAcknowledged = $false
    if ($Environment -eq 'dev') {
        Write-Host 'Agent registration currently uses the Microsoft Graph Registry preview. It is limited to this development environment.' -ForegroundColor Yellow
        $registryPreview = Read-GatewayYesNo -Prompt 'Enable development agent registration using the Registry preview' -Default $false
        if ($registryPreview) {
            $registryBetaAcknowledged = Read-GatewayYesNo -Prompt 'Acknowledge that Registry preview is unsupported for production' -Default $false
            if (-not $registryBetaAcknowledged) { throw 'Registry preview was not acknowledged.' }
        }
    }
    $promptShieldEnabled = $true
    $promptShieldSku = 'F0'
    $promptShieldCostAndQuotaAcknowledged = $false
    Write-Host ''
    Write-Host 'Prompt Shields uses Azure AI Content Safety (product API). The gateway host itself does not require Azure compute.' -ForegroundColor Cyan
    $promptShieldEnabled = Read-GatewayYesNo `
        -Prompt 'Provision Azure AI Content Safety for Prompt Shields in the selected subscription' `
        -Default $false
    if ($promptShieldEnabled) {
        Write-Host 'F0 has limited subscription quota; soft-deleted accounts can retain that quota; S0 plus usage can incur Azure cost.' -ForegroundColor Yellow
        $skuChoice = Read-GatewayChoice -Prompt 'Choose the Content Safety SKU' -Choices @(
            [ordered]@{ label = 'F0'; description = 'Free tier, subject to regional availability and subscription limits.'; value = 'F0' },
            [ordered]@{ label = 'S0'; description = 'Paid standard tier; Azure charges apply.'; value = 'S0' }
        ) -DefaultIndex 0
        $promptShieldSku = [string]$skuChoice.value
        $promptShieldCostAndQuotaAcknowledged = Read-GatewayYesNo `
            -Prompt "Acknowledge the Prompt Shields quota and cost boundary for $promptShieldSku" `
            -Default $false
        if (-not $promptShieldCostAndQuotaAcknowledged) {
            throw 'Prompt Shields quota and cost requirements were not acknowledged.'
        }
    }
    else {
        $promptShieldSku = 'F0'
        $promptShieldCostAndQuotaAcknowledged = $false
    }

    Write-Host ''
    Write-Host 'Microsoft Purview connects the gateway to existing DLP policies. Setup creates its dedicated certificate identity and verifies management access; policy authoring stays in Purview.' -ForegroundColor Cyan
    $purviewEnabled = Read-GatewayYesNo `
        -Prompt 'Set up the Microsoft Purview connection during this installation' `
        -Default $false
    $purviewAuthorityRequirementsAcknowledged = $false
    if ($purviewEnabled) {
        Write-Host 'Purview management access requires a dedicated tenant-approved identity and a Windows catalog-host account. Policy definitions remain in Purview.' -ForegroundColor Yellow
        $purviewAuthorityRequirementsAcknowledged = Read-GatewayYesNo `
            -Prompt 'Authorize setup of the dedicated certificate identity and DLP management permissions in this tenant' `
            -Default $false
        if (-not $purviewAuthorityRequirementsAcknowledged) {
            throw 'Microsoft Purview authority requirements were not acknowledged.'
        }
    }

    return [ordered]@{
        registryPreview = $registryPreview
        registryBetaAcknowledged = $registryBetaAcknowledged
        promptShield = [ordered]@{
            enabled = $promptShieldEnabled
            skuName = $promptShieldSku
            costAndQuotaAcknowledged = $promptShieldCostAndQuotaAcknowledged
        }
        purview = [ordered]@{
            enabled = $purviewEnabled
            authorityRequirementsAcknowledged = $purviewAuthorityRequirementsAcknowledged
        }
    }
}

function Read-GatewaySetupPort {
    param([string]$Prompt,[int]$Default,[int]$DifferentFrom=0)
    while ($true) {
        $value=Read-GatewayText -Prompt $Prompt -Default ([string]$Default) -Pattern '^[1-9][0-9]{0,4}$' -ValidationMessage 'Enter a TCP port from 1 to 65535.'
        if ([int]$value -le 65535 -and [int]$value -ne $DifferentFrom) { return [int]$value }
        Write-Host 'Choose a port from 1 to 65535 that differs from the other gateway port.' -ForegroundColor Yellow
    }
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
    Write-Host 'Guided setup only — you should not hand-edit JSON. Tokens and passwords are never written to configuration.'
    Write-Host ''

    $deployProfile = 'runtime'

    # The entry point imports the shared modules once. Reimporting Runtime here
    # removes its global commands and hides them inside this module, breaking the
    # Common configuration validator at the end of the interactive wizard.
    try { Assert-GatewayRuntimePrerequisites -Install:$false | Out-Null }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        if (-not (Read-GatewayYesNo -Prompt 'Resolve the prerequisite reported above, then continue' -Default $true)) {
            throw 'Runtime setup requires Docker Engine with the compose plugin.'
        }
        Assert-GatewayRuntimePrerequisites -Install:$false | Out-Null
    }

    $profiles = @(
        [ordered]@{
            label = 'Quick development'
            description = 'Development environment defaults.'
            environment = 'dev'
        },
        [ordered]@{
            label = 'Staging foundation'
            description = 'Staging with Registry creation closed.'
            environment = 'staging'
        },
        [ordered]@{
            label = 'Production-safe foundation'
            description = 'Production foundation; Registry preview remains closed.'
            environment = 'prod'
        }
    )
    $profile = Read-GatewayChoice -Prompt 'Choose an environment' -Choices $profiles -DefaultIndex 0
    $environment = [string]$profile.environment
    $capabilities = Read-GatewayBootstrapCapabilities -Environment $environment -DeployProfile $deployProfile
    $subscriptions = @()
    try { $subscriptions = @(Get-GatewayAzureSubscriptions) } catch { }
    if ($capabilities.promptShield.enabled) {
        if ($subscriptions.Count -eq 0) {
            if (-not (Read-GatewayYesNo -Prompt 'Sign in to Microsoft to select the Content Safety subscription' -Default $true)) { throw 'Microsoft sign-in is required.' }
            & az login --output none --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw 'Microsoft sign-in did not complete.' }
            $subscriptions = @(Get-GatewayAzureSubscriptions)
        }
        if ($subscriptions.Count -eq 0) { throw 'Content Safety provisioning requires an enabled Azure subscription.' }
        $choices = @($subscriptions | ForEach-Object {
            @{label=(ConvertTo-GatewaySafeDisplayText $_.name);description="Tenant $($_.tenantId) / $($_.id)";value=$_}
        })
        $subscriptionChoice = Read-GatewayChoice -Prompt 'Azure subscription for Content Safety' -Choices $choices -DefaultIndex 0
        $subscription = $subscriptionChoice.value
    } else {
        $suggestedTenant = ''
        try { $suggestedTenant = (& az account show --query tenantId -o tsv --only-show-errors 2>$null | Out-String).Trim() } catch { }
        $tenant = Read-GatewayText -Prompt 'Microsoft tenant ID (Azure subscription is not needed)' -Default $suggestedTenant -Pattern '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' -ValidationMessage 'Enter the Microsoft tenant GUID.'
        Assert-GuidValue -Value $tenant -Label 'Microsoft tenant'
        & az login --tenant $tenant --allow-no-subscriptions --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Microsoft tenant sign-in did not complete.' }
        $subscription = @{id='';tenantId=([guid]$tenant).ToString('D')}
        $subscriptionChoice = @{label='Not required'}
    }
    $randomProject = 'gw' + [guid]::NewGuid().ToString('N').Substring(0, 5)
    $identityDefaults = Get-GatewaySetupIdentityDefaults `
        -ExistingConfiguration $existingConfiguration `
        -SubscriptionId ([string]$subscription.id) `
        -TenantId ([string]$subscription.tenantId) `
        -Environment $environment `
        -FallbackProjectName $randomProject
    if ($identityDefaults.sameDeployment) {
        Write-Host "Reusing the recorded deployment identity '$($identityDefaults.projectName)' in $environment. Accepting these defaults reconfigures that deployment; entering a different project name provisions a separate one." -ForegroundColor Cyan
    }
    $projectName = Read-GatewayText -Prompt 'Short project name (used for tenant/global resource isolation)' -Default $identityDefaults.projectName -Pattern '^[a-z][a-z0-9]{1,7}$' -ValidationMessage 'Use 2-8 lowercase letters/digits, starting with a letter.'


    $registryPreview = $capabilities.registryPreview
    $registryBetaAcknowledged = $capabilities.registryBetaAcknowledged
    $promptShieldEnabled = $capabilities.promptShield.enabled
    $promptShieldSku = $capabilities.promptShield.skuName
    $promptShieldCostAndQuotaAcknowledged = $capabilities.promptShield.costAndQuotaAcknowledged
    $purviewEnabled = $capabilities.purview.enabled
    $purviewAuthorityRequirementsAcknowledged = $capabilities.purview.authorityRequirementsAcknowledged

    $location = ''
    $resourceGroupName = ''
    if ($promptShieldEnabled) {
        $configuredLocation = [string]$identityDefaults.location
        $location = Read-GatewayAzureLocation `
            -SubscriptionId ([string]$subscription.id) `
            -ConfiguredLocation $configuredLocation
        $defaultResourceGroupName = "rg-$projectName-$environment"
        if ($identityDefaults.sameDeployment -and
            $projectName -ceq [string]$identityDefaults.projectName -and
            -not [string]::IsNullOrWhiteSpace([string]$identityDefaults.resourceGroupName)) {
            $defaultResourceGroupName = [string]$identityDefaults.resourceGroupName
        }
        $rgPrompt = 'Azure resource group for Content Safety (Prompt Shields only)'
        $resourceGroupName = Read-GatewayText -Prompt $rgPrompt -Default $defaultResourceGroupName -Pattern '^[A-Za-z0-9._()\-]{1,90}$' -ValidationMessage 'Enter a valid Azure resource group name (1-90 characters).'
    }

    $apiHostPort = Read-GatewaySetupPort -Prompt 'Local API host port' -Default 5080
    $consoleHostPort = Read-GatewaySetupPort -Prompt 'Local Console host port' -Default 5081 -DifferentFrom $apiHostPort
    $seedBlueprintName = Read-GatewayText -Prompt 'Agent 365 seed blueprint name' -Default "A365 Gateway $projectName $environment" -Pattern '^.{1,100}$' -ValidationMessage 'Use 1 to 100 characters.'
    Write-Host ''
    Write-Host 'Agent 365 managerApplications grant first-party manager authority and must be independently reviewed for this tenant/provider version.' -ForegroundColor Yellow
    Write-Host 'Do not copy IDs from blueprint discovery alone. Follow the "Reviewed manager applications" section of bootstrap/README.md.' -ForegroundColor DarkGray
    $reviewedManagerApplicationIds = @()
    while ($reviewedManagerApplicationIds.Count -eq 0) {
        $managerInput = Read-GatewayText -Prompt 'Reviewed manager application ID(s), comma-separated' -Pattern '^[0-9A-Fa-f,; \-]+$' -ValidationMessage 'Enter one to ten comma-separated GUIDs.'
        try { $reviewedManagerApplicationIds = @(ConvertTo-GatewayReviewedManagerApplicationIds -Value $managerInput) }
        catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }

    $root = Get-RepositoryRoot
    $schemaPath = Join-Path $root 'bootstrap/config.schema.json'
    $configurationDirectory = Split-Path -Parent $resolvedPath
    $relativeSchema = [IO.Path]::GetRelativePath($configurationDirectory, $schemaPath).Replace([IO.Path]::DirectorySeparatorChar, '/')
    if (-not $relativeSchema.StartsWith('.')) { $relativeSchema = "./$relativeSchema" }
    $configuration = [ordered]@{
        '$schema' = $relativeSchema
        deployProfile = $deployProfile
        tenantId = [string]$subscription.tenantId
        environment = $environment
        projectName = $projectName
        agent365 = [ordered]@{
            seedBlueprintName = $seedBlueprintName
            allowDevelopmentRegistryPreview = $registryPreview
            registryBetaAcknowledged = $registryBetaAcknowledged
            reviewedManagerApplicationIds = @($reviewedManagerApplicationIds)
        }
        promptShield = [ordered]@{
            enabled = $promptShieldEnabled
            skuName = $promptShieldSku
            costAndQuotaAcknowledged = $promptShieldCostAndQuotaAcknowledged
        }
        purview = [ordered]@{
            enabled = $purviewEnabled
            authorityRequirementsAcknowledged = $purviewAuthorityRequirementsAcknowledged
        }
    }
    if ($promptShieldEnabled) { $configuration.subscriptionId = [string]$subscription.id }
    if (-not [string]::IsNullOrWhiteSpace($location)) {
        $configuration.location = $location
    }
    if (-not [string]::IsNullOrWhiteSpace($resourceGroupName)) {
        $configuration.resourceGroupName = $resourceGroupName
    }
    $configuration.runtime = [ordered]@{
            apiHostPort = $apiHostPort
            consoleHostPort = $consoleHostPort
        }

    Write-Host ''
    if ($null -ne $existingConfiguration -and
        $existingConfiguration.tenantId -eq $configuration.tenantId -and
        $existingConfiguration.projectName -eq $configuration.projectName -and
        $existingConfiguration.environment -eq $configuration.environment) {
        foreach ($bindingName in @('composeProjectName', 'credentialLabelPrefix')) {
            $binding = Get-OptionalObjectPropertyValue $existingConfiguration.runtime $bindingName
            if (-not [string]::IsNullOrWhiteSpace([string]$binding)) {
                $configuration.runtime[$bindingName] = [string]$binding
            }
        }
    }
    Write-Host "Deployment: $projectName-$environment" -ForegroundColor Cyan
    Write-Host "Host profile:  $deployProfile"
    Write-Host "Subscription:  $($subscriptionChoice.label)"
    if (-not [string]::IsNullOrWhiteSpace($location)) {
        Write-Host "Region:        $location"
        Write-Host "Resource group: $resourceGroupName"
    }
    Write-Host "API port:      $apiHostPort"
        Write-Host "Console port:  $consoleHostPort"
    Write-Host "Registry preview: $registryPreview"
    Write-Host "Reviewed Agent 365 manager IDs: $($reviewedManagerApplicationIds -join ', ')"
    Write-Host "Prompt Shields:   $promptShieldEnabled $(if ($promptShieldEnabled) { "($promptShieldSku)" } else { '' })"
    Write-Host "Purview:           $purviewEnabled"
    if (-not (Read-GatewayYesNo -Prompt 'Accept and continue (writes non-secret configuration, then you can run plan/apply)' -Default $true)) {
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
        tenantId = [string]$subscription.tenantId
        deployProfile = $deployProfile
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
    param([Parameter(Mandatory)][string]$ConfigPath)
    try { $configuration = Read-BootstrapConfig -Path $ConfigPath }
    catch {
        return [ordered]@{
            schemaVersion = 1; checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            ready = $false; readyForPlan = $false; readyForApply = $false
            failures = 1; warnings = 0; notChecked = 0
            checks = @((New-GatewayDoctorCheck -Name Configuration -Status Fail -Value 'Missing, invalid, or retired deployment profile' -Remediation 'Use gateway init to configure a runtime deployment.'))
        }
    }
    return Get-GatewayRuntimeDoctorReport -Config $configuration
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
    $runtime = Test-GatewayRuntimeDeployProfile -Config $Config
    $steps = @(Get-GatewayRuntimeBootstrapStepNames)
    foreach ($name in $steps) {
        $record = $State.steps[$name]
        $status = if ($record) { [string]$record.status } else { 'Pending' }
        $timestamp = if ($record -and $record.Contains('completedAtUtc')) { [string]$record.completedAtUtc } elseif ($record -and $record.Contains('failedAtUtc')) { [string]$record.failedAtUtc } elseif ($record -and $record.Contains('startedAtUtc')) { [string]$record.startedAtUtc } else { '' }
        $stepRows.Add([ordered]@{ name = $name; status = $status; timestampUtc = $timestamp })
    }
    $completed = @($stepRows | Where-Object status -eq 'Completed').Count
    $failed = @($stepRows | Where-Object status -eq 'Failed')
    $running = @($stepRows | Where-Object status -eq 'Running')
    $next = @($stepRows | Where-Object status -eq 'Pending' | Select-Object -First 1)
    $overall = if ($failed.Count -gt 0) { 'NeedsAttention' } elseif ($completed -eq $steps.Count) { 'Verified' } elseif ($running.Count -gt 0) { 'InProgress' } elseif ($completed -gt 0) { 'Paused' } else { 'NotStarted' }

    $adminUiUrl = ''
    $apiUrl = ''
    $verificationStep = $State.steps['End-to-end deployment verification']
    if ($runtime) {
        $runtimeStep = $State.steps['Gateway runtime']
        $infrastructureReady = $runtimeStep -and [string]$runtimeStep.status -eq 'Completed'
        $controlPlaneReady = $infrastructureReady -and $verificationStep -and
            [string]$verificationStep.status -eq 'Completed' -and
            $verificationStep.evidence -is [System.Collections.IDictionary] -and
            $verificationStep.evidence.healthy -eq $true
        if ($infrastructureReady -and $runtimeStep.evidence -is [System.Collections.IDictionary]) {
            $adminUiUrl = [string]$runtimeStep.evidence.consoleUrl
            $apiUrl = "http://127.0.0.1:$([int]$Config.runtime.apiHostPort)/"
        }
        # Runtime health does not prove Registry admission or downstream delivery.
        $provisioningReady = $false
    }
    return [ordered]@{
        schemaVersion = 1
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        deploymentId = "$($Config.projectName)-$($Config.environment)"
        deploymentKey = [string]$State.deploymentKey
        statePath = $StatePath
        statusBasis = 'PersistedBootstrapCheckpoint'
        liveReadbackPerformed = $false
        overallStatus = $overall
        deployProfile = 'runtime'
        progressPercent = [math]::Floor(($completed / $steps.Count) * 100)
        completedSteps = $completed
        totalSteps = $steps.Count
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
            totalSteps = (Get-GatewayRuntimeBootstrapStepNames).Count
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

Export-ModuleMember -Function *
