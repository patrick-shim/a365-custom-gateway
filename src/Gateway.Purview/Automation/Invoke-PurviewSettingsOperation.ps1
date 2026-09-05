[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$CertificatePath,
    [Parameter(Mandatory)][string]$AutomationApplicationId,
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)]
    [ValidateSet(
        'ReadKnowYourData',
        'CreateKnowYourData',
        'ReadDlpProfile',
        'CreateDlpPolicy',
        'CreateDlpRule')]
    [string]$Operation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:ResultPrefix = 'A365GW_SETTINGS_RESULT:'
$script:EnterpriseAiAppsGroupId = 'ee1680d0-702f-4090-b26c-c49091e86531'
$script:InventoryLimit = 2048

function Get-Property {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string[]]$Names,
        [switch]$Optional
    )

    foreach ($name in $Names) {
        $properties = @($InputObject.PSObject.Properties | Where-Object {
            $_.Name.Equals($name, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($properties.Count -eq 1) { return $properties[0].Value }
    }
    if ($Optional) { return $null }
    throw "Purview readback omitted a required typed property."
}

function Assert-BoundedText {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][int]$MaximumLength,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$Value) -or
        ([string]$Value).Length -gt $MaximumLength -or
        [string]$Value -match '[\x00-\x1f\x7f]') {
        throw "Purview $Label is invalid."
    }
    return [string]$Value
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
        throw "Purview $Label is not a canonical non-empty GUID."
    }
    return $parsed.ToString('D')
}

function ConvertTo-Array {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Label,
        [switch]$AllowEmpty
    )

    if ($null -eq $Value) {
        if ($AllowEmpty) { return @() }
        throw "Purview $Label was absent."
    }
    if ($Value -is [string]) {
        try { $Value = $Value | ConvertFrom-Json -Depth 20 -ErrorAction Stop }
        catch { throw "Purview $Label was not valid structured data." }
    }
    $values = @($Value)
    if (-not $AllowEmpty -and $values.Count -eq 0) {
        throw "Purview $Label was empty."
    }
    return $values
}

function Test-ExactSet {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected
    )

    if ($Actual.Count -ne $Expected.Count) { return $false }
    return (@($Actual | Sort-Object) -join "`n") -ceq
        (@($Expected | Sort-Object) -join "`n")
}

function Test-Meaningful {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        return -not ([string]::IsNullOrWhiteSpace($Value) -or
            $Value.Equals('False', [StringComparison]::OrdinalIgnoreCase) -or
            $Value.Equals('None', [StringComparison]::OrdinalIgnoreCase) -or
            $Value -eq '[]' -or
            $Value -eq '{}')
    }
    if ($Value -is [Collections.IEnumerable]) { return @($Value).Count -gt 0 }
    return $true
}

function Assert-NoUnknownMeaningfulProperties {
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][string[]]$AllowedNames,
        [Parameter(Mandatory)][string]$Label
    )

    foreach ($property in $Resource.PSObject.Properties) {
        if ($property.Name -notin $AllowedNames -and
            (Test-Meaningful -Value $property.Value)) {
            throw "Purview $Label returned unsupported meaningful configuration."
        }
    }
}

function Test-NoExclusionsOrBypass {
    param([Parameter(Mandatory)]$Resource)

    foreach ($property in $Resource.PSObject.Properties) {
        if (($property.Name.StartsWith('ExceptIf', [StringComparison]::OrdinalIgnoreCase) -or
            $property.Name.Contains('Exclusion', [StringComparison]::OrdinalIgnoreCase) -or
            $property.Name.Contains('Exception', [StringComparison]::OrdinalIgnoreCase) -or
            $property.Name.Contains('Bypass', [StringComparison]::OrdinalIgnoreCase) -or
            $property.Name.Contains('Override', [StringComparison]::OrdinalIgnoreCase)) -and
            (Test-Meaningful -Value $property.Value)) {
            return $false
        }
    }
    return $true
}

$script:ProviderMetadataProperties = @(
    'Name', 'DisplayName', 'Identity', 'Guid', 'ImmutableId', 'Comment',
    'Description', 'Priority', 'CreatedBy', 'LastModifiedBy', 'WhenCreated',
    'WhenCreatedUTC', 'WhenChanged', 'WhenChangedUTC', 'ExchangeVersion',
    'ObjectState', 'OrganizationId', 'DistinguishedName', 'IsValid',
    'ObjectCategory', 'ObjectClass', 'Status', 'Workload', 'Version',
    'RunspaceId', 'PSComputerName', 'PSShowComputerName',
    'PSSourceJobInstanceId', 'SerializationData'
)

function Assert-NoExtraDlpRuleBehavior {
    param([Parameter(Mandatory)]$Rule)

    $knownExtraConditions = @(
        'AccessScope', 'ActivationDate', 'AdvancedRule',
        'AnyOfRecipientAddressContainsWords',
        'AnyOfRecipientAddressMatchesPatterns', 'AttachmentIsNotLabeled',
        'ContentCharacterSetContainsWords', 'ContentExtensionMatchesWords',
        'ContentFileTypeMatches', 'ContentIsNotLabeled', 'ContentIsShared',
        'ContentPropertyContainsWords', 'DocumentContainsWords', 'DocumentCreatedBy',
        'DocumentCreatedByMemberOf', 'DocumentIsPasswordProtected',
        'DocumentIsUnsupported', 'DocumentMatchesPatterns',
        'DocumentNameMatchesPatterns', 'DocumentNameMatchesWords', 'DocumentSizeOver',
        'EvaluateRulePerComponent', 'ExpiryDate', 'From',
        'FromAddressContainsWords', 'FromAddressMatchesPatterns',
        'FromMemberOf', 'FromScope', 'HasActivity', 'HasSenderOverride',
        'HeaderContainsWords', 'HeaderMatchesPatterns', 'MessageIsNotLabeled',
        'MessageSizeOver', 'MessageTypeMatches', 'NonBifurcatingAccessScope',
        'ProcessingLimitExceeded', 'RecipientADAttributeContainsWords',
        'RecipientADAttributeMatchesPatterns', 'RecipientDomainIs',
        'SenderADAttributeContainsWords', 'SenderADAttributeMatchesPatterns',
        'SenderAddressLocation', 'SenderDomainIs', 'SenderIPRanges', 'SentTo',
        'SentToMemberOf', 'SharedByIRMUserRisk', 'SubjectContainsWords',
        'SubjectMatchesPatterns', 'SubjectOrBodyContainsWords',
        'SubjectOrBodyMatchesPatterns', 'UnscannableDocumentExtensionIs',
        'WithImportance'
    )
    $knownExtraActions = @(
        'AddRecipients', 'AlertProperties', 'ApplyBrandingTemplate',
        'ApplyHtmlDisclaimer', 'BlockAccess', 'BlockAccessScope',
        'EncryptRMSTemplate', 'EndpointDlpRestrictions', 'EnforcePortalAccess',
        'GenerateAlert', 'GenerateIncidentReport', 'IncidentReportContent',
        'MipRestrictAccess', 'Moderate', 'ModifySubject', 'NotifyAllowOverride',
        'NotifyEmailCustomSenderDisplayName', 'NotifyEmailCustomSubject',
        'NotifyEmailCustomText', 'NotifyEmailExchangeIncludeAttachment',
        'NotifyEmailOnedriveRemediationActions', 'NotifyOverrideRequirements',
        'NotifyPolicyTipCustomDialog', 'NotifyPolicyTipCustomText',
        'NotifyPolicyTipCustomTextTranslations', 'NotifyPolicyTipDisplayOption',
        'NotifyPolicyTipUrl', 'NotifyUser', 'NotifyUserType',
        'OnPremisesScannerDlpRestrictions', 'PrependSubject', 'Quarantine',
        'RedirectMessageTo', 'RemoveHeader', 'RemoveRMSTemplate',
        'ReportSeverityLevel', 'RestrictWebGrounding', 'RuleErrorAction',
        'SetHeader', 'SharepointMoveToQuarantineLocation', 'StopPolicyProcessing',
        'TriggerPowerAutomateFlow'
    )
    foreach ($name in @($knownExtraConditions + $knownExtraActions)) {
        $value = Get-Property -InputObject $Rule -Names @($name) -Optional
        if (Test-Meaningful -Value $value) {
            throw 'Purview DLP rule contains unsupported condition or action configuration.'
        }
    }
    $disabled = Get-Property -InputObject $Rule -Names @('Disabled') -Optional
    if (Test-Meaningful -Value $disabled) {
        throw 'Purview DLP rule is disabled.'
    }
    Assert-NoUnknownMeaningfulProperties -Resource $Rule -AllowedNames @(
        $script:ProviderMetadataProperties
        'ParentPolicyName'
        'PolicyName'
        'Policy'
        'PolicyId'
        'ContentContainsSensitiveInformation'
        'RestrictAccess'
        'Disabled'
        $knownExtraConditions
        $knownExtraActions
    ) -Label 'DLP rule'
}

function Get-ExactResource {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Resources,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$ExpectedProviderId
    )

    $matches = @($Resources | Where-Object {
        [string]$_.Name -ceq $Name -or
        [string]$_.Identity -ceq $Name -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedProviderId) -and
            [string]$_.Identity -ceq $ExpectedProviderId)
    })
    if ($matches.Count -gt 1) {
        throw 'Purview provider discovery returned duplicate managed objects.'
    }
    if ($matches.Count -eq 0) { return $null }

    $identity = Assert-BoundedText `
        -Value ([string](Get-Property -InputObject $matches[0] -Names @('Identity'))) `
        -MaximumLength 256 `
        -Label 'provider identity'
    if (([string](Get-Property -InputObject $matches[0] -Names @('Name'))) -cne $Name -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedProviderId) -and
            $identity -cne $ExpectedProviderId)) {
        throw 'Purview managed-object identity does not match the reviewed intent.'
    }
    return $matches[0]
}

function Get-SelectedSensitiveInformationType {
    param([Parameter(Mandatory)]$InputObject)

    $expectedId = ConvertTo-CanonicalGuid `
        -Value ([string]$InputObject.sensitiveInformationTypeId) `
        -Label 'sensitive information type ID'
    $expectedName = Assert-BoundedText `
        -Value $InputObject.sensitiveInformationTypeName `
        -MaximumLength 255 `
        -Label 'sensitive information type Name'
    $expectedPublisher = Assert-BoundedText `
        -Value $InputObject.sensitiveInformationTypePublisher `
        -MaximumLength 200 `
        -Label 'sensitive information type Publisher'
    $inventory = @(Get-DlpSensitiveInformationType -ErrorAction Stop)
    if ($inventory.Count -eq 0 -or $inventory.Count -gt $script:InventoryLimit) {
        throw 'Purview sensitive-information-type inventory is outside its safe bound.'
    }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $match = $null
    foreach ($entry in $inventory) {
        $id = ConvertTo-CanonicalGuid `
            -Value ([string](Get-Property -InputObject $entry -Names @('Id'))) `
            -Label 'sensitive information type ID'
        $name = Assert-BoundedText `
            -Value (Get-Property -InputObject $entry -Names @('Name')) `
            -MaximumLength 255 `
            -Label 'sensitive information type Name'
        $publisher = Assert-BoundedText `
            -Value (Get-Property -InputObject $entry -Names @('Publisher')) `
            -MaximumLength 200 `
            -Label 'sensitive information type Publisher'
        if (-not $ids.Add($id) -or -not $names.Add($name)) {
            throw 'Purview sensitive-information-type inventory contains duplicate identity.'
        }
        if ($id -ceq $expectedId) {
            if ($null -ne $match) {
                throw 'The selected sensitive information type did not resolve exactly once.'
            }
            $match = [ordered]@{ id = $id; name = $name; publisher = $publisher }
        }
    }
    if ($null -eq $match -or
        [string]$match.name -cne $expectedName -or
        [string]$match.publisher -cne $expectedPublisher) {
        throw 'The selected sensitive information type no longer matches the tenant inventory.'
    }
    return $match
}

function Assert-Intent {
    param([Parameter(Mandatory)]$InputObject)

    ConvertTo-CanonicalGuid -Value ([string]$InputObject.operationId) `
        -Label 'operation ID' | Out-Null
    ConvertTo-CanonicalGuid -Value ([string]$InputObject.tenantId) `
        -Label 'tenant ID' | Out-Null
    ConvertTo-CanonicalGuid -Value ([string]$InputObject.inventoryGenerationId) `
        -Label 'inventory generation ID' | Out-Null
    $expiresAt = [DateTimeOffset]$InputObject.inventoryExpiresAtUtc
    if ($expiresAt.Offset -ne [TimeSpan]::Zero -or
        $expiresAt -le [DateTimeOffset]::UtcNow) {
        throw 'The selected Purview inventory generation is expired or invalid.'
    }
    Assert-BoundedText -Value $InputObject.policyName `
        -MaximumLength 256 -Label 'policy Name' | Out-Null
    if ([string]$InputObject.mode -notin @('AuditOnly', 'Enforce')) {
        throw 'The reviewed Purview policy mode is unsupported.'
    }
    $activities = @($InputObject.activities | ForEach-Object { [string]$_ })
    if ($activities.Count -eq 0 -or
        $activities.Count -gt 2 -or
        @($activities | Sort-Object -Unique).Count -ne $activities.Count -or
        @($activities | Where-Object { $_ -notin @('UploadText', 'DownloadText') }).Count -ne 0) {
        throw 'The reviewed Purview activities are invalid or unsupported.'
    }
    return Get-SelectedSensitiveInformationType -InputObject $InputObject
}

function ConvertTo-ProviderMode {
    param([Parameter(Mandatory)][string]$Mode)

    if ($Mode -ceq 'Enforce') { return 'Enable' }
    if ($Mode -ceq 'AuditOnly') { return 'TestWithoutNotifications' }
    throw 'The reviewed Purview policy mode is unsupported.'
}

function Test-ExactApplicationLocation {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$ExpectedType,
        [Parameter(Mandatory)][string]$ExpectedId
    )

    $locations = @(ConvertTo-Array -Value $Value -Label 'Application locations')
    if ($locations.Count -ne 1) { return $false }
    $location = $locations[0]
    if ([string](Get-Property -InputObject $location -Names @('Workload')) -cne 'Applications' -or
        [string](Get-Property -InputObject $location -Names @('LocationSource')) -cne 'Entra' -or
        [string](Get-Property -InputObject $location -Names @('LocationType')) -cne $ExpectedType) {
        return $false
    }
    $actualId = ConvertTo-CanonicalGuid `
        -Value ([string](Get-Property -InputObject $location -Names @('Location'))) `
        -Label 'Application location ID'
    $inclusions = @(ConvertTo-Array -Value (
        Get-Property -InputObject $location -Names @('Inclusions')) `
        -Label 'Application location inclusions')
    if ($inclusions.Count -ne 1 -or
        [string](Get-Property -InputObject $inclusions[0] -Names @('Type')) -cne 'Tenant' -or
        [string](Get-Property -InputObject $inclusions[0] -Names @('Identity')) -cne 'All') {
        return $false
    }
    Assert-NoUnknownMeaningfulProperties -Resource $inclusions[0] `
        -AllowedNames @('Type', 'Identity') `
        -Label 'Application location inclusion'
    Assert-NoUnknownMeaningfulProperties -Resource $location -AllowedNames @(
        'Workload', 'Location', 'LocationDisplayName', 'LocationSource',
        'LocationType', 'Inclusions', 'Exclusions', 'ExcludedLocations',
        'Exceptions', 'Bypass', 'BypassRules'
    ) -Label 'Application location'
    return $actualId -ceq $ExpectedId -and
        (Test-NoExclusionsOrBypass -Resource $location)
}

function New-ApplicationLocation {
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Id
    )

    return [ordered]@{
        Workload = 'Applications'
        Location = $Id
        LocationSource = 'Entra'
        LocationType = $Type
        Inclusions = @(@{ Type = 'Tenant'; Identity = 'All' })
    }
}

function Get-KnowYourDataUpdateTarget {
    param([Parameter(Mandatory)]$InputObject)

    if ([string]::IsNullOrWhiteSpace(
            [string]$InputObject.expectedPolicyProviderId)) {
        throw 'Know Your Data update requires persisted provider-ID authority.'
    }
    $resources = @(Get-FeatureConfiguration -FeatureScenario KnowYourData `
        -ErrorAction Stop | Where-Object { $null -ne $_ })
    $policy = Get-ExactResource -Resources $resources `
        -Name ([string]$InputObject.policyName) `
        -ExpectedProviderId ([string]$InputObject.expectedPolicyProviderId)
    if ($null -eq $policy) {
        throw 'The provider-ID-bound Know Your Data policy is absent.'
    }

    $scenario = Get-Property -InputObject $policy -Names @('ScenarioConfig')
    if ($scenario -is [string]) {
        $scenario = $scenario | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    }
    $activities = @((Get-Property -InputObject $scenario -Names @('Activities')) |
        ForEach-Object { [string]$_ })
    $planes = @((Get-Property -InputObject $scenario -Names @('EnforcementPlanes')) |
        ForEach-Object { [string]$_ })
    $sensitiveTypeIds = @((Get-Property -InputObject $scenario `
        -Names @('SensitiveTypeIds')) | ForEach-Object { [string]$_ })
    $ingestionEnabled = Get-Property -InputObject $scenario `
        -Names @('IsIngestionEnabled')
    if ($activities.Count -lt 1 -or
        $activities.Count -gt 2 -or
        @($activities | Sort-Object -Unique).Count -ne $activities.Count -or
        @($activities | Where-Object {
            $_ -notin @('UploadText', 'DownloadText')
        }).Count -ne 0 -or
        -not (Test-ExactSet -Actual $planes -Expected @('Application')) -or
        $sensitiveTypeIds.Count -ne 1 -or
        $ingestionEnabled -isnot [bool] -or
        [string](Get-Property -InputObject $policy -Names @('Mode')) -notin
            @('Enable', 'TestWithoutNotifications') -or
        -not (Test-ExactApplicationLocation -Value (
            Get-Property -InputObject $policy -Names @('Locations')) `
            -ExpectedType 'Group' -ExpectedId $script:EnterpriseAiAppsGroupId) -or
        -not (Test-NoExclusionsOrBypass -Resource $policy)) {
        throw 'The provider-ID-bound Know Your Data policy is not safe for update.'
    }
    ConvertTo-CanonicalGuid -Value $sensitiveTypeIds[0] `
        -Label 'existing sensitive information type ID' | Out-Null
    Assert-NoUnknownMeaningfulProperties -Resource $scenario -AllowedNames @(
        'Activities', 'EnforcementPlanes', 'SensitiveTypeIds', 'IsIngestionEnabled'
    ) -Label 'Know Your Data ScenarioConfig'
    Assert-NoUnknownMeaningfulProperties -Resource $policy -AllowedNames @(
        $script:ProviderMetadataProperties
        'Mode'
        'FeatureScenario'
        'Scenario'
        'ScenarioConfig'
        'Locations'
        'Exclusions'
        'ExcludedLocations'
        'Exceptions'
        'Bypass'
        'BypassRules'
    ) -Label 'Know Your Data policy'
    return $policy
}

function Get-DlpPolicyUpdateTarget {
    param([Parameter(Mandatory)]$InputObject)

    if ([string]::IsNullOrWhiteSpace(
            [string]$InputObject.expectedPolicyProviderId)) {
        throw 'DLP policy update requires persisted provider-ID authority.'
    }
    $policies = @(Get-DlpCompliancePolicy -ErrorAction Stop |
        Where-Object { $null -ne $_ })
    $policy = Get-ExactResource -Resources $policies `
        -Name ([string]$InputObject.policyName) `
        -ExpectedProviderId ([string]$InputObject.expectedPolicyProviderId)
    if ($null -eq $policy) {
        throw 'The provider-ID-bound DLP policy is absent.'
    }

    $blueprintId = ConvertTo-CanonicalGuid `
        -Value ([string]$InputObject.blueprintApplicationId) `
        -Label 'blueprint Application ID'
    $planes = @((Get-Property -InputObject $policy -Names @('EnforcementPlanes')) |
        ForEach-Object { [string]$_ })
    if ([string](Get-Property -InputObject $policy -Names @('Mode')) -notin
            @('Enable', 'TestWithoutNotifications') -or
        -not (Test-ExactSet -Actual $planes -Expected @('Application')) -or
        -not (Test-ExactApplicationLocation -Value (
            Get-Property -InputObject $policy -Names @('Locations')) `
            -ExpectedType 'Individual' -ExpectedId $blueprintId) -or
        -not (Test-NoExclusionsOrBypass -Resource $policy)) {
        throw 'The provider-ID-bound DLP policy is not safe for update.'
    }
    Assert-NoUnknownMeaningfulProperties -Resource $policy -AllowedNames @(
        $script:ProviderMetadataProperties
        'Mode'
        'Locations'
        'EnforcementPlanes'
        'Exclusions'
        'ExcludedLocations'
        'Exceptions'
        'Bypass'
        'BypassRules'
    ) -Label 'DLP policy'
    return $policy
}

function Get-DlpRuleUpdateTarget {
    param([Parameter(Mandatory)]$InputObject)

    if ([string]::IsNullOrWhiteSpace(
            [string]$InputObject.expectedRuleProviderId)) {
        throw 'DLP rule update requires persisted provider-ID authority.'
    }
    $rules = @(Get-DlpComplianceRule -ErrorAction Stop |
        Where-Object { $null -ne $_ })
    $rule = Get-ExactResource -Resources $rules `
        -Name ([string]$InputObject.ruleName) `
        -ExpectedProviderId ([string]$InputObject.expectedRuleProviderId)
    if ($null -eq $rule) {
        throw 'The provider-ID-bound DLP rule is absent.'
    }

    $parentName = [string](Get-Property -InputObject $rule `
        -Names @('ParentPolicyName', 'PolicyName', 'Policy'))
    $conditions = @(ConvertTo-Array -Value (
        Get-Property -InputObject $rule -Names @('ContentContainsSensitiveInformation')) `
        -Label 'DLP classifier')
    $actions = @(ConvertTo-Array -Value (
        Get-Property -InputObject $rule -Names @('RestrictAccess')) `
        -Label 'DLP actions')
    if ($parentName -cne [string]$InputObject.policyName -or
        $conditions.Count -ne 1 -or
        $actions.Count -ne 1 -or
        -not (Test-NoExclusionsOrBypass -Resource $rule)) {
        throw 'The provider-ID-bound DLP rule is not safe for update.'
    }
    Assert-NoExtraDlpRuleBehavior -Rule $rule
    return $rule
}

function Get-KnowYourDataReadback {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)]$SelectedType
    )

    $resources = @(Get-FeatureConfiguration -FeatureScenario KnowYourData `
        -ErrorAction Stop | Where-Object { $null -ne $_ })
    $policy = Get-ExactResource -Resources $resources `
        -Name ([string]$InputObject.policyName) `
        -ExpectedProviderId ([string]$InputObject.expectedPolicyProviderId
    )
    if ($null -eq $policy) {
        if (-not [string]::IsNullOrWhiteSpace(
                [string]$InputObject.expectedPolicyProviderId)) {
            return [ordered]@{ state = 'Mismatch' }
        }
        return [ordered]@{ state = 'Absent' }
    }

    $scenario = Get-Property -InputObject $policy -Names @('ScenarioConfig')
    if ($scenario -is [string]) {
        $scenario = $scenario | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    }
    $actualActivities = @((Get-Property -InputObject $scenario -Names @('Activities')) |
        ForEach-Object { [string]$_ })
    $expectedActivities = @($InputObject.activities | ForEach-Object { [string]$_ })
    $actualPlanes = @((Get-Property -InputObject $scenario -Names @('EnforcementPlanes')) |
        ForEach-Object { [string]$_ })
    $actualTypes = @((Get-Property -InputObject $scenario -Names @('SensitiveTypeIds')) |
        ForEach-Object { [string]$_ })
    Assert-NoUnknownMeaningfulProperties -Resource $scenario -AllowedNames @(
        'Activities', 'EnforcementPlanes', 'SensitiveTypeIds', 'IsIngestionEnabled'
    ) -Label 'Know Your Data ScenarioConfig'
    Assert-NoUnknownMeaningfulProperties -Resource $policy -AllowedNames @(
        $script:ProviderMetadataProperties
        'Mode'
        'FeatureScenario'
        'Scenario'
        'ScenarioConfig'
        'Locations'
        'Exclusions'
        'ExcludedLocations'
        'Exceptions'
        'Bypass'
        'BypassRules'
    ) -Label 'Know Your Data policy'
    $exact = [string](Get-Property -InputObject $policy -Names @('Mode')) -ceq
            (ConvertTo-ProviderMode -Mode ([string]$InputObject.mode)) -and
        (Test-ExactSet -Actual $actualActivities -Expected $expectedActivities) -and
        (Test-ExactSet -Actual $actualPlanes -Expected @('Application')) -and
        (Test-ExactSet -Actual $actualTypes -Expected @([string]$SelectedType.id)) -and
        [bool](Get-Property -InputObject $scenario -Names @('IsIngestionEnabled')) -eq
            [bool]$InputObject.ingestionEnabled -and
        (Test-ExactApplicationLocation -Value (
            Get-Property -InputObject $policy -Names @('Locations')) `
            -ExpectedType 'Group' -ExpectedId $script:EnterpriseAiAppsGroupId) -and
        (Test-NoExclusionsOrBypass -Resource $policy)
    if (-not $exact) { return [ordered]@{ state = 'Mismatch' } }

    return [ordered]@{
        state = 'Exact'
        policyProviderId = [string](Get-Property -InputObject $policy -Names @('Identity'))
        tenantId = [string]$InputObject.tenantId
        groupId = $script:EnterpriseAiAppsGroupId
        scopeType = 'Group'
        enforcementPlane = 'Application'
        sensitiveInformationTypeId = [string]$SelectedType.id
        sensitiveInformationTypeName = [string]$SelectedType.name
        sensitiveInformationTypePublisher = [string]$SelectedType.publisher
        mode = [string]$InputObject.mode
        activities = $expectedActivities
        ingestionEnabled = [bool]$InputObject.ingestionEnabled
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
}

function Assert-DlpActions {
    param([Parameter(Mandatory)]$InputObject)

    $actions = @($InputObject.actions)
    if ($actions.Count -ne 1) {
        throw 'The reviewed DLP actions are invalid or unsupported.'
    }
    $projected = [Collections.Generic.List[object]]::new()
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($action in $actions) {
        $activity = [string]$action.activity
        $value = [string]$action.action
        if ($activity -cne 'UploadText' -or
            $value -cne 'Block' -or
            -not $keys.Add("$activity`n$value")) {
            throw 'The reviewed DLP actions are invalid or unsupported.'
        }
        $projected.Add([ordered]@{ activity = $activity; action = $value })
    }
    return @($projected)
}

function Get-DlpReadback {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)]$SelectedType,
        [Parameter(Mandatory)][object[]]$ExpectedActions
    )

    $blueprintId = ConvertTo-CanonicalGuid `
        -Value ([string]$InputObject.blueprintApplicationId) `
        -Label 'blueprint Application ID'
    $policies = @(Get-DlpCompliancePolicy -ErrorAction Stop |
        Where-Object { $null -ne $_ })
    $rules = @(Get-DlpComplianceRule -ErrorAction Stop |
        Where-Object { $null -ne $_ })
    $policy = Get-ExactResource -Resources $policies `
        -Name ([string]$InputObject.policyName) `
        -ExpectedProviderId ([string]$InputObject.expectedPolicyProviderId)
    $rule = Get-ExactResource -Resources $rules `
        -Name ([string]$InputObject.ruleName) `
        -ExpectedProviderId ([string]$InputObject.expectedRuleProviderId)
    if ($null -eq $policy -and $null -eq $rule) {
        if (-not [string]::IsNullOrWhiteSpace(
                [string]$InputObject.expectedPolicyProviderId) -or
            -not [string]::IsNullOrWhiteSpace(
                [string]$InputObject.expectedRuleProviderId)) {
            return [ordered]@{ state = 'Mismatch' }
        }
        return [ordered]@{ state = 'Absent' }
    }
    if ($null -eq $policy) { return [ordered]@{ state = 'Mismatch' } }

    $planes = @((Get-Property -InputObject $policy -Names @('EnforcementPlanes')) |
        ForEach-Object { [string]$_ })
    $policyExact = [string](Get-Property -InputObject $policy -Names @('Mode')) -ceq
            (ConvertTo-ProviderMode -Mode ([string]$InputObject.mode)) -and
        (Test-ExactSet -Actual $planes -Expected @('Application')) -and
        (Test-ExactApplicationLocation -Value (
            Get-Property -InputObject $policy -Names @('Locations')) `
            -ExpectedType 'Individual' -ExpectedId $blueprintId) -and
        (Test-NoExclusionsOrBypass -Resource $policy)
    Assert-NoUnknownMeaningfulProperties -Resource $policy -AllowedNames @(
        $script:ProviderMetadataProperties
        'Mode'
        'Locations'
        'EnforcementPlanes'
        'Exclusions'
        'ExcludedLocations'
        'Exceptions'
        'Bypass'
        'BypassRules'
    ) -Label 'DLP policy'
    if (-not $policyExact) { return [ordered]@{ state = 'Mismatch' } }

    $base = [ordered]@{
        policyProviderId = [string](Get-Property -InputObject $policy -Names @('Identity'))
        ruleProviderId = $null
        tenantId = [string]$InputObject.tenantId
        blueprintApplicationIds = @($blueprintId)
        scopeType = 'Individual'
        enforcementPlane = 'Application'
        sensitiveInformationTypeId = [string]$SelectedType.id
        sensitiveInformationTypeName = [string]$SelectedType.name
        sensitiveInformationTypePublisher = [string]$SelectedType.publisher
        mode = [string]$InputObject.mode
        activities = @($InputObject.activities | ForEach-Object { [string]$_ })
        actions = @($ExpectedActions)
        hasExclusions = $false
        hasBypass = $false
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
    if ($null -eq $rule) {
        $base.state = 'PolicyOnlyExact'
        return $base
    }

    $parentName = [string](Get-Property -InputObject $rule `
        -Names @('ParentPolicyName', 'PolicyName', 'Policy'))
    $conditions = @(ConvertTo-Array -Value (
        Get-Property -InputObject $rule -Names @('ContentContainsSensitiveInformation')) `
        -Label 'DLP classifier')
    $providerActions = @(ConvertTo-Array -Value (
        Get-Property -InputObject $rule -Names @('RestrictAccess')) `
        -Label 'DLP actions')
    if ($parentName -cne [string]$InputObject.policyName -or
        $conditions.Count -ne 1 -or
        $providerActions.Count -ne $ExpectedActions.Count -or
        -not (Test-NoExclusionsOrBypass -Resource $rule)) {
        return [ordered]@{ state = 'Mismatch' }
    }
    Assert-NoExtraDlpRuleBehavior -Rule $rule
    $base.ruleProviderId = [string](Get-Property -InputObject $rule -Names @('Identity'))
    $conditionId = ConvertTo-CanonicalGuid `
        -Value ([string](Get-Property -InputObject $conditions[0] -Names @('Id'))) `
        -Label 'DLP classifier ID'
    $conditionName = [string](Get-Property -InputObject $conditions[0] -Names @('Name'))
    if ($conditionId -cne [string]$SelectedType.id -or
        $conditionName -cne [string]$SelectedType.name) {
        $base.state = 'PolicyOnlyExact'
        return $base
    }
    $actualActions = @($providerActions | ForEach-Object {
        [ordered]@{
            activity = [string](Get-Property -InputObject $_ -Names @('setting', 'Setting'))
            action = [string](Get-Property -InputObject $_ -Names @('value', 'Value'))
        }
    })
    $actualActionKeys = @($actualActions | ForEach-Object {
        "$([string]$_.activity)`n$([string]$_.action)"
    })
    $expectedActionKeys = @($ExpectedActions | ForEach-Object {
        "$([string]$_.activity)`n$([string]$_.action)"
    })
    if (-not (Test-ExactSet -Actual $actualActionKeys -Expected $expectedActionKeys)) {
        $base.state = 'PolicyOnlyExact'
        return $base
    }

    $base.state = 'Exact'
    return $base
}

function Write-TypedResult {
    param([Parameter(Mandatory)]$Value)

    $json = $Value | ConvertTo-Json -Depth 12 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    [Console]::Out.WriteLine("$($script:ResultPrefix)$encoded")
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
        ConvertFrom-Json -Depth 20 -ErrorAction Stop
    $expectedTenantId = ConvertTo-CanonicalGuid `
        -Value ([string]$input.tenantId) `
        -Label 'tenant ID'
    Import-Module ExchangeOnlineManagement -MinimumVersion 3.10.1 -ErrorAction Stop
    $existingConnections = @(Get-ConnectionInformation -ErrorAction Stop)
    if (@($existingConnections | Where-Object { $_.IsEopSession -eq $true }).Count -ne 0) {
        throw 'An existing Security & Compliance session makes tenant authority ambiguous.'
    }
    $existingConnectionIds = @($existingConnections | ForEach-Object {
        [string]$_.ConnectionId
    })
    Connect-IPPSSession `
        -AppId $AutomationApplicationId `
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
        throw 'Purview automation could not prove one exact owned Security & Compliance session.'
    }
    $connectedTenantId = ConvertTo-CanonicalGuid `
        -Value ([string](Get-Property `
            -InputObject $activeConnections[0] `
            -Names @('TenantID'))) `
        -Label 'connected tenant ID'
    if ($connectedTenantId -cne $expectedTenantId) {
        throw 'The connected Security & Compliance tenant does not match the reviewed operation.'
    }
    foreach ($command in @(
        'Get-DlpSensitiveInformationType',
        'Get-FeatureConfiguration',
        'New-FeatureConfiguration',
        'Set-FeatureConfiguration',
        'Get-DlpCompliancePolicy',
        'New-DlpCompliancePolicy',
        'Set-DlpCompliancePolicy',
        'Get-DlpComplianceRule',
        'New-DlpComplianceRule',
        'Set-DlpComplianceRule')) {
        Get-Command $command -ErrorAction Stop | Out-Null
    }

    $selectedType = Assert-Intent -InputObject $input
    if ($Operation -in @('ReadKnowYourData', 'CreateKnowYourData')) {
        $state = Get-KnowYourDataReadback `
            -InputObject $input `
            -SelectedType $selectedType
        if ($Operation -ceq 'CreateKnowYourData') {
            if ([string]$state.state -ceq 'Exact') {
                Write-TypedResult -Value @{ state = 'MutationAccepted' }
                return
            }
            $scenarioConfig = @{
                Activities = @($input.activities | ForEach-Object { [string]$_ })
                EnforcementPlanes = @('Application')
                SensitiveTypeIds = @([string]$selectedType.id)
                IsIngestionEnabled = [bool]$input.ingestionEnabled
            } | ConvertTo-Json -Compress
            $locations = @((New-ApplicationLocation `
                -Type 'Group' `
                -Id $script:EnterpriseAiAppsGroupId)) |
                ConvertTo-Json -Depth 10 -Compress
            if ([string]$state.state -ceq 'Absent') {
                New-FeatureConfiguration `
                    -FeatureScenario KnowYourData `
                    -Name ([string]$input.policyName) `
                    -Mode (ConvertTo-ProviderMode -Mode ([string]$input.mode)) `
                    -ScenarioConfig $scenarioConfig `
                    -Locations $locations `
                    -Confirm:$false |
                    Out-Null
            }
            elseif ([string]$state.state -ceq 'Mismatch') {
                $policy = Get-KnowYourDataUpdateTarget -InputObject $input
                Set-FeatureConfiguration `
                    -Identity $policy.Identity `
                    -Mode (ConvertTo-ProviderMode -Mode ([string]$input.mode)) `
                    -ScenarioConfig $scenarioConfig `
                    -Locations $locations `
                    -Confirm:$false |
                    Out-Null
            }
            else {
                throw 'Know Your Data provider state is not safe for mutation.'
            }
            Write-TypedResult -Value @{ state = 'MutationAccepted' }
            return
        }
        Write-TypedResult -Value $state
        return
    }

    $actions = @(Assert-DlpActions -InputObject $input)
    $state = Get-DlpReadback `
        -InputObject $input `
        -SelectedType $selectedType `
        -ExpectedActions $actions
    if ($Operation -ceq 'ReadDlpProfile') {
        Write-TypedResult -Value $state
        return
    }

    if ($Operation -ceq 'CreateDlpPolicy') {
        if ([string]$state.state -in @('PolicyOnlyExact', 'Exact')) {
            Write-TypedResult -Value @{ state = 'MutationAccepted' }
            return
        }
        $blueprintId = ConvertTo-CanonicalGuid `
            -Value ([string]$input.blueprintApplicationId) `
            -Label 'blueprint Application ID'
        $locations = @((New-ApplicationLocation `
            -Type 'Individual' `
            -Id $blueprintId)) |
            ConvertTo-Json -Depth 10 -Compress
        if ([string]$state.state -ceq 'Absent') {
            New-DlpCompliancePolicy `
                -Name ([string]$input.policyName) `
                -Mode (ConvertTo-ProviderMode -Mode ([string]$input.mode)) `
                -Locations $locations `
                -EnforcementPlanes @('Application') `
                -Confirm:$false |
                Out-Null
        }
        elseif ([string]$state.state -ceq 'Mismatch') {
            $policy = Get-DlpPolicyUpdateTarget -InputObject $input
            Set-DlpCompliancePolicy `
                -Identity $policy.Identity `
                -Mode (ConvertTo-ProviderMode -Mode ([string]$input.mode)) `
                -Locations $locations `
                -EnforcementPlanes @('Application') `
                -Confirm:$false |
                Out-Null
        }
        else {
            throw 'DLP provider state is not safe for policy mutation.'
        }
        Write-TypedResult -Value @{ state = 'MutationAccepted' }
        return
    }

    if ([string]$state.state -ceq 'Exact') {
        Write-TypedResult -Value @{ state = 'MutationAccepted' }
        return
    }
    if ([string]$state.state -cne 'PolicyOnlyExact') {
        throw 'DLP policy exact readback is required before rule creation.'
    }
    $providerActions = @($actions | ForEach-Object {
        @{
            setting = [string]$_.activity
            value = [string]$_.action
        }
    })
    if ([string]::IsNullOrWhiteSpace([string]$state.ruleProviderId)) {
        if (-not [string]::IsNullOrWhiteSpace(
                [string]$input.expectedRuleProviderId)) {
            throw 'A provider-ID-bound DLP rule is absent and cannot be recreated.'
        }
        New-DlpComplianceRule `
            -Name ([string]$input.ruleName) `
            -Policy ([string]$input.policyName) `
            -ContentContainsSensitiveInformation @{
                Name = [string]$selectedType.name
            } `
            -RestrictAccess $providerActions `
            -Confirm:$false |
            Out-Null
    }
    else {
        $rule = Get-DlpRuleUpdateTarget -InputObject $input
        Set-DlpComplianceRule `
            -Identity $rule.Identity `
            -ContentContainsSensitiveInformation @{
                Name = [string]$selectedType.name
            } `
            -RestrictAccess $providerActions `
            -Confirm:$false |
            Out-Null
    }
    Write-TypedResult -Value @{ state = 'MutationAccepted' }
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
        catch { }
    }
    $certificate.Dispose()
    $securePassword.Dispose()
}
