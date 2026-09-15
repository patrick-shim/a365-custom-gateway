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
$script:SettingsStage = 1
$script:SettingsSchemaCode = $null

function Get-Property {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string[]]$Names,
        [switch]$Optional
    )

    foreach ($name in $Names) {
        if ($InputObject -is [Collections.IDictionary]) {
            $keys = @($InputObject.Keys | Where-Object { [string]$_ -ieq $name })
            if ($keys.Count -eq 1) { return $InputObject[$keys[0]] }
            if ($keys.Count -gt 1) {
                $script:SettingsSchemaCode = 'AmbiguousProperty'
                throw 'Purview readback has ambiguous property names.'
            }
            continue
        }
        $properties = @($InputObject.PSObject.Properties | Where-Object {
            $_.Name.Equals($name, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($properties.Count -eq 1) { return $properties[0].Value }
    }
    if ($Optional) { return $null }
    $script:SettingsSchemaCode = if ($Names -contains 'Locations') { 'MissingLocations' }
        elseif ($Names -contains 'EnforcementPlanes') { 'MissingEnforcementPlanes' }
        elseif ($Names -contains 'Mode') { 'MissingMode' }
        elseif ($Names -contains 'ContentContainsSensitiveInformation') { 'MissingSensitiveCondition' }
        elseif ($Names -contains 'RestrictAccess') { 'MissingRestrictAccess' }
        elseif ($Names -contains 'DistributionStatus') { 'MissingDistributionStatus' }
        elseif ($Names -contains 'Identity' -or $Names -contains 'Guid' -or $Names -contains 'Id') { 'MissingProviderIdentity' }
        else { 'MissingRequiredProperty' }
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
        $script:SettingsSchemaCode = 'InvalidTypedProperty'
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
        catch {
            $script:SettingsSchemaCode = 'InvalidStructuredArray'
            throw "Purview $Label was not valid structured data."
        }
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

    $properties=if ($Resource -is [Collections.IDictionary]) {
        @($Resource.Keys | ForEach-Object { [pscustomobject]@{Name=[string]$_;Value=$Resource[$_]} })
    } else { @($Resource.PSObject.Properties) }
    foreach ($property in $properties) {
        if ($property.Name -notin $AllowedNames -and
            (Test-Meaningful -Value $property.Value)) {
            $script:SettingsSchemaCode = switch -CaseSensitive ($property.Name) {
                'DistributionStatus' { 'UnexpectedDistributionStatus' }
                'DistributionResults' { 'UnexpectedDistributionResults' }
                'LastStatusUpdateTime' { 'UnexpectedLastStatusUpdateTime' }
                'Scenario' { 'UnexpectedScenario' }
                'Type' { 'UnexpectedType' }
                'PolicyType' { 'UnexpectedPolicyType' }
                'PolicyVersion' { 'UnexpectedPolicyVersion' }
                'IsDefaultPolicy' { 'UnexpectedIsDefaultPolicy' }
                'PolicyRBACScopes' { 'UnexpectedPolicyRBACScopes' }
                'Rules' { 'UnexpectedRules' }
                'PolicyRulesMetaData' { 'UnexpectedPolicyRulesMetaData' }
                'Keys' { 'UnexpectedDictionaryMetadata' }
                'Values' { 'UnexpectedDictionaryMetadata' }
                'Count' { 'UnexpectedDictionaryMetadata' }
                default { 'UnknownMeaningfulProperty' }
            }
            throw "Purview $Label returned unsupported meaningful configuration."
        }
    }
}

function Get-ProviderReadbackMember {
    param([Parameter(Mandatory)]$Resource,[Parameter(Mandatory)][string]$Name)
    if ($Resource -is [Collections.IDictionary]) {
        $keys=@($Resource.Keys | Where-Object { [string]$_ -ieq $Name })
        if ($keys.Count -gt 1) { throw 'Provider metadata has ambiguous fields.' }
        if ($keys.Count -eq 1) { return ,$Resource[$keys[0]] }
        return $null
    }
    $properties=@($Resource.PSObject.Properties | Where-Object Name -IEQ $Name)
    if ($properties.Count -gt 1) { throw 'Provider metadata has ambiguous fields.' }
    if ($properties.Count -eq 1) { return ,$properties[0].Value }
    return $null
}

function Assert-ProviderTenantInclusion {
    param([Parameter(Mandatory)]$Inclusion)
    foreach ($name in @('Type','Identity','DisplayName','Name')) {
        $value=Get-ProviderReadbackMember $Inclusion $name
        $expected=if ($name -ceq 'Type') { 'Tenant' } else { 'All' }
        if (($name -cin @('Type','Identity') -or $null -ne $value) -and [string]$value -cne $expected) {
            throw 'Provider tenant inclusion does not match the exact reviewed scope.'
        }
    }
    foreach ($name in @('ScopingGroup','LocationType','LocationSource')) {
        $value=Get-ProviderReadbackMember $Inclusion $name
        if ($null -ne $value -and [string]$value -cne 'Unknown') {
            throw 'Provider tenant inclusion has additional scope restrictions.'
        }
    }
}

function Assert-ProviderDlpMetadata {
    param([Parameter(Mandatory)]$Policy,[Parameter(Mandatory)][string[]]$ExpectedIds,
        [Parameter(Mandatory)][ValidateSet('Individual','Group')][string]$ExpectedType,
        [Parameter(Mandatory)][ValidateSet('Enable','Disable','TestWithNotifications','TestWithoutNotifications')][string]$ExpectedProviderMode)
    $type=Get-ProviderReadbackMember $Policy 'Type'
    $category=Get-ProviderReadbackMember $Policy 'PolicyCategory'
    $enabled=Get-ProviderReadbackMember $Policy 'Enabled'
    if (($null -ne $type -and [string]$type -cne 'Dlp') -or
        ($null -ne $category -and [string]$category -cne 'Unknown') -or
        ($null -ne $enabled -and ($enabled -isnot [bool] -or $enabled -ne ($ExpectedProviderMode -cne 'Disable')))) {
        throw 'Provider policy classification or enabled state differs from the reviewed policy.'
    }
    $ruleMetadata = Get-ProviderReadbackMember $Policy 'PolicyRulesMetaData'
    if ($ruleMetadata -is [string] -and $ruleMetadata.Length -eq 0) {
        $ruleMetadata = $null
    }
    if ($null -ne $ruleMetadata) {
        if ($ruleMetadata -is [string]) {
            if ($ruleMetadata.Length -gt 16384) { throw 'Provider policy rule metadata exceeds its safe bound.' }
            $ruleMetadata = ConvertFrom-Json -InputObject $ruleMetadata -Depth 4 -NoEnumerate -ErrorAction Stop
        }
        if ($null -eq $ruleMetadata -or $ruleMetadata -is [array] -or
            $ruleMetadata -is [string] -or $ruleMetadata -is [ValueType]) {
            throw 'Provider policy rule metadata has unsupported configuration.'
        }
        $names = @(if ($ruleMetadata -is [Collections.IDictionary]) { @($ruleMetadata.Keys) }
            else { @($ruleMetadata.PSObject.Properties.Name) })
        $changed = Get-ProviderReadbackMember $ruleMetadata 'WhenRulesChangedUtc'
        $instant = [DateTimeOffset]::MinValue
        if ($names.Count -ne 1 -or [string]$names[0] -cne 'WhenRulesChangedUtc' -or
            ($changed -isnot [datetime] -and $changed -isnot [DateTimeOffset] -and
                ($changed -isnot [string] -or $changed.Length -gt 64 -or
                    -not [DateTimeOffset]::TryParse($changed,[ref]$instant)))) {
            throw 'Provider policy rule metadata has unsupported configuration.'
        }
    }
    $constraints=Get-ProviderReadbackMember $Policy 'PolicyConstraints'
    if ($null -ne $constraints) {
        if ($constraints -is [string]) {
            if ($constraints.Length -gt 16384) { throw 'Provider policy constraints exceed the safe bound.' }
            $constraints=$constraints | ConvertFrom-Json -Depth 10 -ErrorAction Stop
        }
        if ($null -eq $constraints -or $constraints -is [array] -or $constraints -is [string] -or $constraints -is [ValueType]) {
            throw 'Provider policy constraints have an unsupported shape.'
        }
        $names=if ($constraints -is [Collections.IDictionary]) { @($constraints.Keys) } else { @($constraints.PSObject.Properties.Name) }
        $units=Get-ProviderReadbackMember $constraints 'AdministrativeUnit'
        if (@($names | Where-Object { [string]$_ -cne 'AdministrativeUnit' }).Count -ne 0 -or
            ($names -contains 'AdministrativeUnit' -and ($units -isnot [array] -or $units.Count -ne 0))) {
            throw 'Provider policy has unreviewed administrative or additional constraints.'
        }
    }
    $identity=Get-ProviderReadbackMember $Policy 'Identity'
    $id=Get-ProviderReadbackMember $Policy 'Id'
    if ($null -ne $id -and [string]$id -cne [string]$identity) {
        throw 'Provider policy identity aliases disagree.'
    }
    $hasBindings=if ($Policy -is [Collections.IDictionary]) {
        @($Policy.Keys | Where-Object { [string]$_ -ieq 'LocationInclusions' }).Count -gt 0
    } else { @($Policy.PSObject.Properties | Where-Object Name -IEQ 'LocationInclusions').Count -gt 0 }
    if (-not $hasBindings) { return }
    $bindingValue=Get-ProviderReadbackMember $Policy 'LocationInclusions'
    if ($null -eq $bindingValue) { throw 'Provider policy internal bindings are absent.' }
    $bindings=@($bindingValue)
    if ($bindings.Count -ne $ExpectedIds.Count) { throw 'Provider policy has additional or missing internal bindings.' }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($binding in $bindings) {
        $source=[guid]::Empty
        if (-not [guid]::TryParse([string](Get-ProviderReadbackMember $binding 'SourceType'),[ref]$source) -or
            $source.ToString('D') -notin $ExpectedIds -or -not $seen.Add($source.ToString('D'))) {
            throw 'Provider internal binding does not match the exact application scope.'
        }
        foreach ($name in @('ImmutableIdentity','Name','DisplayName')) {
            if ([string](Get-ProviderReadbackMember $binding $name) -cne 'All') {
                throw 'Provider internal binding is not tenant-wide.'
            }
        }
        $entry=Get-ProviderReadbackMember $binding 'SourceEntryType'
        $provider=Get-ProviderReadbackMember $binding 'SourceProvider'
        $bindingType=Get-ProviderReadbackMember $binding 'Type'
        $scoping=Get-ProviderReadbackMember $binding 'ScopingGroup'
        $schema=Get-ProviderReadbackMember $binding 'SchemaVersion'
        $resources=Get-ProviderReadbackMember $binding 'Resources'
        if ($null -eq $entry -or $null -eq $provider -or $null -eq $bindingType -or $null -eq $scoping -or $null -eq $schema -or
            ([string]$entry -cne $ExpectedType -and -not ($ExpectedType -ceq 'Individual' -and [int]$entry -eq 1)) -or
            ([string]$provider -cne 'Entra' -and [int]$provider -ne 3) -or
            ([string]$bindingType -cne 'Tenant' -and [int]$bindingType -ne 1) -or
            ([string]$scoping -cne 'Unknown' -and [int]$scoping -ne 0) -or
            [string](Get-ProviderReadbackMember $binding 'Workload') -cne 'Applications' -or
            [string](Get-ProviderReadbackMember $binding 'GroupSet') -cne 'Default' -or
            [int]$schema -ne 0 -or
            ($null -ne $resources -and ($resources -isnot [array] -or $resources.Count -ne 0))) {
            throw 'Provider internal binding has unreviewed workload or scope semantics.'
        }
        Assert-NoUnknownMeaningfulProperties -Resource $binding -AllowedNames @(
            'DisplayName','Name','ImmutableIdentity','Type','Status','Workload','SourceType',
            'SourceTypeDisplayName','SourceProvider','SourceEntryType','SchemaVersion','Resources','ScopingGroup','GroupSet'
        ) -Label 'internal application binding'
    }
}

function Test-NoExclusionsOrBypass {
    param([Parameter(Mandatory)]$Resource)

    $properties=if ($Resource -is [Collections.IDictionary]) {
        @($Resource.Keys | ForEach-Object { [pscustomobject]@{Name=[string]$_;Value=$Resource[$_]} })
    } else { @($Resource.PSObject.Properties) }
    foreach ($property in $properties) {
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
    'PSSourceJobInstanceId', 'SerializationData',
    'Id', 'ObjectVersion', 'DirectoryObjectVersion', 'ExchangeObjectId', 'OrganizationalUnitRoot',
    'CreationTimeUtc', 'ModificationTimeUtc', 'ExpectedLocations', 'CompletedLocations',
    'FailedLocations', 'DistributionStatus', 'DistributionSyncStatus', 'DistributionResults'
)

function Assert-NoExtraDlpRuleBehavior {
    param([Parameter(Mandatory)]$Rule)

    $providerCondition = @(Get-CanonicalProviderDlpTypes -Rule $Rule)
    $providerDefaults = @()
    if ($providerCondition.Count -gt 0) {
        Assert-CanonicalProviderDlpRuleMetadata -Rule $Rule
        $providerDefaults = @('AdvancedRule', 'EnforcePortalAccess',
            'NotifyEmailExchangeIncludeAttachment', 'ReportSeverityLevel')
    }
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
        if ($name -in $providerDefaults) { continue }
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
        $(if ($providerCondition.Count -gt 0) {
            @('AdvancedRule','IsAdvancedRule','EnforcePortalAccess',
                'NotifyEmailExchangeIncludeAttachment','ReportSeverityLevel',
                'ExternalScenarioDependancies','Mode','MaximumBlobRuleLength')
        })
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
    param([Parameter(Mandatory)]$InputObject, [object[]]$Inventory)

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
    if ($null -eq $Inventory) { $Inventory = @(Get-DlpSensitiveInformationType -ErrorAction Stop) }
    if ($inventory.Count -eq 0 -or $inventory.Count -gt $script:InventoryLimit) {
        throw 'Purview sensitive-information-type inventory is outside its safe bound.'
    }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $match = $null
    foreach ($entry in $inventory) {
        $id = ConvertFrom-ProviderGuid `
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

function Get-SelectedSensitiveInformationTypes {
    param([Parameter(Mandatory)]$InputObject)
    $selections = @(Get-Property -InputObject $InputObject -Names @('sensitiveInformationTypes') -Optional)
    if ($selections.Count -eq 0) {
        throw 'PURVIEW_SIT_THRESHOLDS_REVIEW_REQUIRED: Explicit reviewed SIT thresholds are required.'
    }
    if ($selections.Count -gt 100) { throw 'Too many selected sensitive information types.' }
    $inventory = @(Get-DlpSensitiveInformationType -ErrorAction Stop)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($selection in $selections) {
        if (-not $ids.Add([string]$selection.id)) { throw 'Duplicate selected sensitive information type.' }
        $selected = Get-SelectedSensitiveInformationType -InputObject ([pscustomobject]@{
            sensitiveInformationTypeId = [string]$selection.id
            sensitiveInformationTypeName = [string]$selection.exactName
            sensitiveInformationTypePublisher = [string]$selection.publisher
        }) -Inventory $inventory
        $thresholds = Get-DlpSitThresholds -Value $selection
        foreach ($key in $thresholds.Keys) { $selected[$key] = $thresholds[$key] }
        $selected
    }
}

function Get-DlpSitThresholds {
    param([Parameter(Mandatory)]$Value, [switch]$AllowMissing)

    $result = [ordered]@{}
    foreach ($name in @('minCount', 'maxCount', 'minConfidence', 'maxConfidence')) {
        $raw = Get-Property -InputObject $Value -Names @($name) -Optional
        if ($null -eq $raw -and $AllowMissing) {
            $result[$name] = $null
            continue
        }
        $number = 0
        if ($null -eq $raw -or
            ($raw -isnot [int] -and $raw -isnot [long] -and $raw -isnot [string]) -or
            [string]$raw -cnotmatch '^-?[0-9]+$' -or
            -not [int]::TryParse([string]$raw, [ref]$number)) {
            throw 'PURVIEW_SIT_THRESHOLDS_REVIEW_REQUIRED: Provider or intent omitted a valid integer threshold.'
        }
        $result[$name] = $number
    }
    if (($null -ne $result.minCount -and $result.minCount -lt 1) -or
        ($null -ne $result.maxCount -and $result.maxCount -ne -1 -and
            ($result.maxCount -lt 1 -or ($null -ne $result.minCount -and $result.maxCount -lt $result.minCount))) -or
        ($null -ne $result.minConfidence -and ($result.minConfidence -lt 1 -or $result.minConfidence -gt 100)) -or
        ($null -ne $result.maxConfidence -and ($result.maxConfidence -lt 1 -or $result.maxConfidence -gt 100 -or
            ($null -ne $result.minConfidence -and $result.maxConfidence -lt $result.minConfidence)))) {
        throw 'PURVIEW_SIT_THRESHOLDS_REVIEW_REQUIRED: Count or confidence bounds are invalid.'
    }
    return $result
}

function Assert-DlpConditionProperties {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string[]]$AllowedNames)
    $names = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
    foreach ($name in $names) {
        if ($name -notin $AllowedNames) {
            throw 'Purview DLP classifier contains unsupported condition configuration.'
        }
    }
}

function Get-DlpConditionTypes {
    param([Parameter(Mandatory)]$Value, [switch]$AllowUnverifiedThresholdReplacement)
    $conditions = @(ConvertTo-Array -Value $Value -Label 'DLP classifier')
    if ($conditions.Count -ne 1 -and -not $AllowUnverifiedThresholdReplacement) {
        throw 'Purview DLP classifier did not expose explicit ANY/OR semantics.'
    }
    $semanticsVerified = $conditions.Count -eq 1
    $groupsValue = if ($conditions.Count -eq 1) {
        Get-Property -InputObject $conditions[0] -Names @('groups') -Optional
    } else { $null }
    if ($null -ne $groupsValue) {
        Assert-DlpConditionProperties -Value $conditions[0] -AllowedNames @('operator', 'groups')
        $outerOperator = [string](Get-Property -InputObject $conditions[0] -Names @('operator'))
        $groups = @(ConvertTo-Array -Value $groupsValue -Label 'DLP classifier groups')
        if ($outerOperator -cnotin @('And', 'Or') -or $groups.Count -ne 1) {
            throw 'Purview DLP classifier group semantics are unsupported.'
        }
        Assert-DlpConditionProperties -Value $groups[0] -AllowedNames @('operator', 'name', 'sensitivetypes')
        if ([string](Get-Property -InputObject $groups[0] -Names @('operator')) -cne 'Or') {
            throw 'Purview DLP classifier group is not ANY/OR.'
        }
        $conditions = @(ConvertTo-Array -Value (
            Get-Property -InputObject $groups[0] -Names @('sensitivetypes')) -Label 'DLP sensitive types')
    }
    # A single flat predicate has no ambiguous boolean semantics. Multiple flat predicates do.
    if ($conditions.Count -lt 1 -or $conditions.Count -gt 100) { throw 'Invalid provider classifier count.' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($condition in $conditions) {
        Assert-DlpConditionProperties -Value $condition -AllowedNames @(
            'Id', 'Name', 'minCount', 'maxCount', 'minConfidence', 'maxConfidence')
        $id = ConvertFrom-ProviderGuid -Value ([string](Get-Property -InputObject $condition -Names @('Id'))) -Label 'DLP classifier ID'
        if (-not $ids.Add($id)) { throw 'Duplicate provider classifier identity.' }
        $name = Assert-BoundedText -Value (Get-Property -InputObject $condition -Names @('Name')) -MaximumLength 255 -Label 'DLP classifier Name'
        $thresholds = Get-DlpSitThresholds -Value $condition -AllowMissing:$AllowUnverifiedThresholdReplacement
        [ordered]@{
            id = $id; exactName = $name
            minCount = $thresholds.minCount; maxCount = $thresholds.maxCount
            minConfidence = $thresholds.minConfidence; maxConfidence = $thresholds.maxConfidence
            semanticsVerified = $semanticsVerified
        }
    }
}

function ConvertFrom-CanonicalProviderDlpTypes {
    param([Parameter(Mandatory)]$Value)
    $conditions = @(ConvertTo-Array -Value $Value -Label 'canonical DLP classifiers')
    if ($conditions.Count -lt 1 -or $conditions.Count -gt 100) { throw 'Invalid provider classifier count.' }
    $normalized = @($conditions | ForEach-Object {
        Assert-DlpConditionProperties -Value $_ -AllowedNames @(
            'id','name','mincount','maxcount','minconfidence','maxconfidence','classifiertype','confidencelevel')
        $thresholds = Get-DlpSitThresholds -Value $_
        $confidence = [string](Get-Property -InputObject $_ -Names @('confidencelevel'))
        $expectedConfidence = switch ($thresholds.minConfidence) {
            65 { 'Low' }; 75 { 'Medium' }; 85 { 'High' }; default { $null }
        }
        if ([string](Get-Property -InputObject $_ -Names @('classifiertype')) -cne 'Content' -or
            $null -eq $expectedConfidence -or $confidence -cne $expectedConfidence) {
            throw 'Provider classifier metadata disagrees with explicit thresholds.'
        }
        [ordered]@{
            Id = Get-Property -InputObject $_ -Names @('id')
            Name = Get-Property -InputObject $_ -Names @('name')
            minCount = $thresholds.minCount; maxCount = $thresholds.maxCount
            minConfidence = $thresholds.minConfidence; maxConfidence = $thresholds.maxConfidence
        }
    })
    # One ContentContainsSensitiveInformation predicate has ANY-value semantics.
    # Require its complete canonical expression, not an unanchored flat projection.
    Get-DlpConditionTypes -Value @(@{operator='And';groups=@(
        @{operator='Or';name='Provider content predicate';sensitivetypes=$normalized})})
}

function Get-CanonicalProviderDlpTypes {
    param([Parameter(Mandatory)]$Rule)
    $advanced = Get-Property -InputObject $Rule -Names @('AdvancedRule') -Optional
    if (-not (Test-Meaningful $advanced)) { return }
    if ($advanced -isnot [string] -or $advanced.Length -gt 65536) {
        throw 'Provider canonical rule expression has an unsupported shape.'
    }
    $tree = ConvertFrom-Json -InputObject $advanced -Depth 12 -ErrorAction Stop
    Assert-DlpConditionProperties -Value $tree -AllowedNames @('Version','Condition')
    $isAdvanced = Get-Property $Rule @('IsAdvancedRule')
    if ([string](Get-Property $tree @('Version')) -cne '1.0' -or
        $isAdvanced -isnot [bool] -or $isAdvanced) {
        throw 'Provider canonical rule version or classification is unsupported.'
    }
    $condition = Get-Property $tree @('Condition')
    Assert-DlpConditionProperties -Value $condition -AllowedNames @('Operator','SubConditions')
    if ([string](Get-Property $condition @('Operator')) -cnotin @('And','Or')) {
        throw 'Provider canonical rule operator is unsupported.'
    }
    $predicates = @(ConvertTo-Array (Get-Property $condition @('SubConditions')) 'canonical DLP predicates')
    if ($predicates.Count -ne 1) { throw 'Provider canonical rule has additional conditions.' }
    $predicate = $predicates[0]
    Assert-DlpConditionProperties -Value $predicate -AllowedNames @('ConditionName','Value')
    if ([string](Get-Property $predicate @('ConditionName')) -cne 'ContentContainsSensitiveInformation') {
        throw 'Provider canonical rule condition is unsupported.'
    }
    $canonical = @(ConvertFrom-CanonicalProviderDlpTypes (Get-Property $predicate @('Value')))
    $projection = @(ConvertFrom-CanonicalProviderDlpTypes (
        Get-Property $Rule @('ContentContainsSensitiveInformation')))
    $canonicalKeys = @($canonical | ForEach-Object { "$($_.id)`n$($_.exactName)`n$($_.minCount)`n$($_.maxCount)`n$($_.minConfidence)`n$($_.maxConfidence)" })
    $projectionKeys = @($projection | ForEach-Object { "$($_.id)`n$($_.exactName)`n$($_.minCount)`n$($_.maxCount)`n$($_.minConfidence)`n$($_.maxConfidence)" })
    if (-not (Test-ExactSet $canonicalKeys $projectionKeys)) {
        throw 'Provider canonical rule and classifier projection disagree.'
    }
    return $canonical
}

function Assert-CanonicalProviderDlpRuleMetadata {
    param([Parameter(Mandatory)]$Rule)
    $portal = Get-Property $Rule @('EnforcePortalAccess')
    $attachment = Get-Property $Rule @('NotifyEmailExchangeIncludeAttachment')
    if ($portal -isnot [bool] -or -not $portal -or
        $attachment -isnot [bool] -or -not $attachment -or
        [string](Get-Property $Rule @('ReportSeverityLevel')) -cne 'Low' -or
        [string](Get-Property $Rule @('Mode')) -cne 'Enforce') {
        throw 'Provider rule operational defaults differ from the supported representation.'
    }
    # The attachment default is inert only with no notification or report action;
    # Assert-NoExtraDlpRuleBehavior still rejects every such action and all overrides.
    $dependencies = Get-Property $Rule @('ExternalScenarioDependancies') -Optional
    if ($null -ne $dependencies) {
        $empty = if ($dependencies -is [Collections.IDictionary]) { $dependencies.Count -eq 0 }
            elseif ($dependencies -is [Collections.IEnumerable] -and $dependencies -isnot [string]) { @($dependencies).Count -eq 0 }
            else { $dependencies -is [pscustomobject] -and @($dependencies.PSObject.Properties).Count -eq 0 }
        if (-not $empty) { throw 'Provider rule has external scenario dependencies.' }
    }
    $limit = Get-Property $Rule @('MaximumBlobRuleLength') -Optional
    if ($null -ne $limit) {
        $number = 0L
        if (-not [long]::TryParse([string]$limit,[ref]$number) -or $number -lt 0 -or $number -gt 67108864) {
            throw 'Provider rule serialization bound is invalid.'
        }
    }
}

function New-DlpSensitiveInformationCondition {
    param([Parameter(Mandatory)][object[]]$SelectedTypes)
    $types = @($SelectedTypes | Sort-Object { [string]$_.id } | ForEach-Object {
        $thresholds = Get-DlpSitThresholds -Value $_
        @{
            name = [string]$_.name
            minCount = $thresholds.minCount; maxCount = $thresholds.maxCount
            minConfidence = $thresholds.minConfidence; maxConfidence = $thresholds.maxConfidence
        }
    })
    # Microsoft advanced syntax: one OR group, so matching any reviewed SIT satisfies the condition.
    return @{ operator = 'And'; groups = @(@{ operator = 'Or'; name = 'Reviewed SITs'; sensitivetypes = $types }) }
}

function Get-DlpPolicyMode {
    param([Parameter(Mandatory)]$InputObject)
    if ([string]$InputObject.mode -cnotin @('AuditOnly', 'Enforce')) {
        throw 'The reviewed legacy Mode is unsupported.'
    }
    $mode = [string](Get-Property -InputObject $InputObject -Names @('policyMode') -Optional)
    if ([string]::IsNullOrEmpty($mode)) {
        if ([string]$InputObject.mode -ceq 'Enforce') { return 'Enforce' }
        return 'SimulationWithoutTips'
    }
    if ($mode -cnotin @('Enforce', 'SimulationWithTips', 'SimulationWithoutTips', 'Disabled') -or
        (($mode -ceq 'Enforce') -ne ([string]$InputObject.mode -ceq 'Enforce'))) {
        throw 'The reviewed DLP policy mode is incompatible with legacy Mode.'
    }
    return $mode
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
    if ($Mode -ceq 'SimulationWithTips') { return 'TestWithNotifications' }
    if ($Mode -ceq 'SimulationWithoutTips') { return 'TestWithoutNotifications' }
    if ($Mode -ceq 'Disabled') { return 'Disable' }
    throw 'The reviewed Purview policy mode is unsupported.'
}

function ConvertTo-KnowYourDataProviderMode {
    param([Parameter(Mandatory)][string]$Mode)
    # Collection policies only support Enable/Disable. DLP enforcement is separate
    # from the legacy Gateway choice retained in the collection configuration.
    if ($Mode -cin @('AuditOnly','Enforce')) { return 'Enable' }
    throw 'The reviewed Know Your Data mode is unsupported.'
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
    $actualId = ConvertFrom-ProviderGuid `
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
    Assert-ProviderTenantInclusion -Inclusion $inclusions[0]
    Assert-NoUnknownMeaningfulProperties -Resource $inclusions[0] `
        -AllowedNames @('Type', 'Identity', 'DisplayName', 'Name', 'ScopingGroup', 'LocationType', 'LocationSource') `
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
            @('Enable', 'Disable') -or
        -not (Test-ExactApplicationLocation -Value (
            Get-Property -InputObject $policy -Names @('Locations')) `
            -ExpectedType 'Group' -ExpectedId $script:EnterpriseAiAppsGroupId) -or
        -not (Test-NoExclusionsOrBypass -Resource $policy)) {
        throw 'The provider-ID-bound Know Your Data policy is not safe for update.'
    }
    ConvertFrom-ProviderGuid -Value $sensitiveTypeIds[0] `
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
            @('Enable', 'TestWithNotifications', 'TestWithoutNotifications', 'Disable') -or
        -not (Test-ExactSet -Actual $planes -Expected @('Application')) -or
        -not (Test-ExactApplicationLocation -Value (
            Get-Property -InputObject $policy -Names @('Locations')) `
            -ExpectedType 'Individual' -ExpectedId $blueprintId) -or
        -not (Test-NoExclusionsOrBypass -Resource $policy)) {
        throw 'The provider-ID-bound DLP policy is not safe for update.'
    }
    Assert-ProviderDlpMetadata -Policy $policy -ExpectedIds @($blueprintId) -ExpectedType Individual `
        -ExpectedProviderMode ([string](Get-Property -InputObject $policy -Names @('Mode')))
    Assert-NoUnknownMeaningfulProperties -Resource $policy -AllowedNames @(
        $script:ProviderMetadataProperties
        'Mode'
        'Locations'
        'EnforcementPlanes'
        'Type'
        'PolicyCategory'
        'PolicyConstraints'
        'PolicyRulesMetaData'
        'Enabled'
        'LocationInclusions'
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

    $script:SettingsStage = 9
    $parentName = [string](Get-Property -InputObject $rule `
        -Names @('ParentPolicyName', 'PolicyName', 'Policy'))
    $conditions = @(ConvertTo-Array -Value (
        Get-Property -InputObject $rule -Names @('ContentContainsSensitiveInformation')) `
        -Label 'DLP classifier')
    $actions = @(ConvertTo-Array -Value (
        Get-Property -InputObject $rule -Names @('RestrictAccess')) `
        -Label 'DLP actions')
    if ($parentName -cne [string]$InputObject.policyName -or
        $conditions.Count -lt 1 -or $conditions.Count -gt 100 -or
        $actions.Count -ne 1 -or
        -not (Test-NoExclusionsOrBypass -Resource $rule)) {
        throw 'The provider-ID-bound DLP rule is not safe for update.'
    }
    Assert-NoExtraDlpRuleBehavior -Rule $rule
    $allowReplacement = (Get-Property -InputObject $InputObject -Names @('allowUnverifiedThresholdReplacement') -Optional) -eq $true
    if (@(Get-CanonicalProviderDlpTypes -Rule $rule).Count -eq 0) {
        $null = @(Get-DlpConditionTypes -Value $conditions -AllowUnverifiedThresholdReplacement:$allowReplacement)
    }
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
        ForEach-Object { ConvertFrom-ProviderGuid -Value ([string]$_) -Label 'sensitive information type ID' })
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
            (ConvertTo-KnowYourDataProviderMode -Mode ([string]$InputObject.mode)) -and
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
        [Parameter(Mandatory)][object[]]$ExpectedActions,
        [object[]]$SelectedTypes
    )

    if ($null -eq $SelectedTypes) { $SelectedTypes = @($SelectedType) }
    $policyMode = Get-DlpPolicyMode -InputObject $InputObject
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
    $policyRules = @($rules | Where-Object {
        $parent = [string](Get-Property $_ @('ParentPolicyName','PolicyName','Policy') -Optional)
        $parent.Equals([string]$InputObject.policyName,[StringComparison]::OrdinalIgnoreCase) -or
            $parent.Equals([string](Get-Property $policy @('Identity')),[StringComparison]::OrdinalIgnoreCase)
    })
    if ($policyRules.Count -ne [int]($null -ne $rule)) {
        throw 'The owned DLP policy contains additional or unbound rules.'
    }

    $observedTypes = @()
    if ($null -ne $rule) {
        $script:SettingsStage = 9
        $allowReplacement = (Get-Property -InputObject $InputObject -Names @('allowUnverifiedThresholdReplacement') -Optional) -eq $true
        $observedTypes = @(Get-CanonicalProviderDlpTypes -Rule $rule)
        if ($observedTypes.Count -eq 0) {
            $observedTypes = @(Get-DlpConditionTypes -Value (
                Get-Property -InputObject $rule -Names @('ContentContainsSensitiveInformation')) `
                -AllowUnverifiedThresholdReplacement:$allowReplacement)
        }
    }
    $script:SettingsStage = 8
    $planes = @((Get-Property -InputObject $policy -Names @('EnforcementPlanes')) |
        ForEach-Object { [string]$_ })
    $policyExact = [string](Get-Property -InputObject $policy -Names @('Mode')) -ceq
            (ConvertTo-ProviderMode -Mode $policyMode) -and
        (Test-ExactSet -Actual $planes -Expected @('Application')) -and
        (Test-ExactApplicationLocation -Value (
            Get-Property -InputObject $policy -Names @('Locations')) `
            -ExpectedType 'Individual' -ExpectedId $blueprintId) -and
        (Test-NoExclusionsOrBypass -Resource $policy)
    Assert-ProviderDlpMetadata -Policy $policy -ExpectedIds @($blueprintId) -ExpectedType Individual `
        -ExpectedProviderMode ([string](Get-Property -InputObject $policy -Names @('Mode')))
    Assert-NoUnknownMeaningfulProperties -Resource $policy -AllowedNames @(
        $script:ProviderMetadataProperties
        'Mode'
        'Locations'
        'EnforcementPlanes'
        'Type'
        'PolicyCategory'
        'PolicyConstraints'
        'PolicyRulesMetaData'
        'Enabled'
        'LocationInclusions'
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
        policyMode = $policyMode
        sensitiveInformationTypes = @()
        sensitiveInformationTypesOperator = $null
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

    $script:SettingsStage = 9
    $parentName = [string](Get-Property -InputObject $rule `
        -Names @('ParentPolicyName', 'PolicyName', 'Policy'))
    $conditions = @(ConvertTo-Array -Value (
        Get-Property -InputObject $rule -Names @('ContentContainsSensitiveInformation')) `
        -Label 'DLP classifier')
    $providerActions = @(ConvertTo-Array -Value (
        Get-Property -InputObject $rule -Names @('RestrictAccess')) `
        -Label 'DLP actions')
    if ($parentName -cne [string]$InputObject.policyName -or
        $conditions.Count -lt 1 -or $conditions.Count -gt 100 -or
        $providerActions.Count -ne $ExpectedActions.Count -or
        -not (Test-NoExclusionsOrBypass -Resource $rule)) {
        return [ordered]@{ state = 'Mismatch' }
    }
    Assert-NoExtraDlpRuleBehavior -Rule $rule
    $base.ruleProviderId = [string](Get-Property -InputObject $rule -Names @('Identity'))
    $actualTypes = @($observedTypes | ForEach-Object {
        "$($_.id)`n$($_.exactName)`n$($_.minCount)`n$($_.maxCount)`n$($_.minConfidence)`n$($_.maxConfidence)"
    })
    $expectedTypes = @($SelectedTypes | ForEach-Object {
        "$($_.id)`n$($_.name)`n$($_.minCount)`n$($_.maxCount)`n$($_.minConfidence)`n$($_.maxConfidence)"
    })
    if (@($observedTypes | Where-Object { -not $_.semanticsVerified }).Count -ne 0 -or
        -not (Test-ExactSet -Actual $actualTypes -Expected $expectedTypes)) {
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

    $base.sensitiveInformationTypes = @($observedTypes | Sort-Object { [string]$_.id } | ForEach-Object {
        $actual = $_
        $catalog = @($SelectedTypes | Where-Object { [string]$_.id -ceq [string]$actual.id })[0]
        $actual.publisher = [string]$catalog.publisher
        $actual.sortOrder = 0
        $actual.Remove('semanticsVerified')
        $actual
    })
    $base.sensitiveInformationTypesOperator = 'Or'
    $base.state = 'Exact'
    return $base
}

function Write-SafeSettingsFailure {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$Record)
    [Console]::Error.WriteLine("A365GW_VERIFIER_STAGE:$($script:SettingsStage)")
    $markers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($script:SettingsSchemaCode -cin @('AmbiguousProperty', 'MissingLocations',
            'MissingEnforcementPlanes', 'MissingMode', 'MissingSensitiveCondition',
            'MissingRestrictAccess', 'MissingDistributionStatus', 'MissingProviderIdentity',
            'MissingRequiredProperty', 'InvalidTypedProperty', 'UnknownMeaningfulProperty',
            'InvalidStructuredArray', 'UnexpectedDistributionStatus',
            'UnexpectedDistributionResults', 'UnexpectedLastStatusUpdateTime',
            'UnexpectedScenario', 'UnexpectedType', 'UnexpectedPolicyType',
            'UnexpectedPolicyVersion', 'UnexpectedIsDefaultPolicy', 'UnexpectedPolicyRBACScopes',
            'UnexpectedRules', 'UnexpectedPolicyRulesMetaData', 'UnexpectedDictionaryMetadata')) {
        $marker = "A365GW_VERIFIER_ERROR:InvalidData:Other:00000000:$($script:SettingsSchemaCode)"
        $null = $markers.Add($marker)
        [Console]::Error.WriteLine($marker)
    }
    # The fixed sibling is part of the already-attested executor manifest; only its classifier is loaded.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Verify-PurviewTenantConnection.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { return }
    $helpers = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-SafeVerifierErrors'
    }, $false))
    if ($helpers.Count -ne 1) { return }
    . ([scriptblock]::Create($helpers[0].Extent.Text))
    foreach ($marker in @(Get-SafeVerifierErrors $Record)) {
        if ($markers.Count -ge 8) { break }
        if ($markers.Add($marker)) { [Console]::Error.WriteLine($marker) }
    }
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
    $script:SettingsStage = 2
    $input = Get-Content -LiteralPath $InputPath -Raw |
        ConvertFrom-Json -Depth 20 -ErrorAction Stop
    $expectedTenantId = ConvertTo-CanonicalGuid `
        -Value ([string]$input.tenantId) `
        -Label 'tenant ID'
    $script:SettingsStage = 3
    Import-Module ExchangeOnlineManagement -MinimumVersion 3.10.1 -ErrorAction Stop
    $existingConnections = @(Get-ConnectionInformation -ErrorAction Stop)
    if (@($existingConnections | Where-Object { $_.IsEopSession -eq $true }).Count -ne 0) {
        throw 'An existing Security & Compliance session makes tenant authority ambiguous.'
    }
    $existingConnectionIds = @($existingConnections | ForEach-Object {
        [string]$_.ConnectionId
    })
    $requiredProviderCommands = @(
        'Get-DlpSensitiveInformationType',
        'Get-FeatureConfiguration', 'New-FeatureConfiguration', 'Set-FeatureConfiguration',
        'Get-DlpCompliancePolicy', 'New-DlpCompliancePolicy', 'Set-DlpCompliancePolicy',
        'Get-DlpComplianceRule', 'New-DlpComplianceRule', 'Set-DlpComplianceRule')
    $providerWorkspace = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($InputPath))
    $script:SettingsStage = 4
    Connect-IPPSSession `
        -AppId $AutomationApplicationId `
        -Certificate $certificate `
        -Organization $Organization `
        -CommandName $requiredProviderCommands `
        -EXOModuleBasePath $providerWorkspace `
        -LogDirectoryPath $providerWorkspace `
        -ShowBanner:$false |
        Out-Null
    $script:SettingsStage = 5
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
    $connectedTenantId = ConvertFrom-ProviderGuid `
        -Value ([string](Get-Property `
            -InputObject $activeConnections[0] `
            -Names @('TenantID'))) `
        -Label 'connected tenant ID'
    if ($connectedTenantId -cne $expectedTenantId) {
        throw 'The connected Security & Compliance tenant does not match the reviewed operation.'
    }
    foreach ($command in $requiredProviderCommands) {
        Get-Command $command -ErrorAction Stop | Out-Null
    }

    $script:SettingsStage = 6
    $selectedType = Assert-Intent -InputObject $input
    if ($Operation -in @('ReadKnowYourData', 'CreateKnowYourData')) {
        $script:SettingsStage = 7
        $state = Get-KnowYourDataReadback `
            -InputObject $input `
            -SelectedType $selectedType
        if ($Operation -ceq 'CreateKnowYourData') {
            $script:SettingsStage = 10
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
                ConvertTo-Json -Depth 10 -Compress -AsArray
            if ([string]$state.state -ceq 'Absent') {
                New-FeatureConfiguration `
                    -FeatureScenario KnowYourData `
                    -Name ([string]$input.policyName) `
                    -Mode (ConvertTo-KnowYourDataProviderMode -Mode ([string]$input.mode)) `
                    -ScenarioConfig $scenarioConfig `
                    -Locations $locations `
                    -Confirm:$false |
                    Out-Null
            }
            elseif ([string]$state.state -ceq 'Mismatch') {
                $policy = Get-KnowYourDataUpdateTarget -InputObject $input
                Set-FeatureConfiguration `
                    -Identity $policy.Identity `
                    -Mode (ConvertTo-KnowYourDataProviderMode -Mode ([string]$input.mode)) `
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
    $selectedTypes = @(Get-SelectedSensitiveInformationTypes -InputObject $input)
    $policyMode = Get-DlpPolicyMode -InputObject $input
    $script:SettingsStage = 8
    $state = Get-DlpReadback `
        -InputObject $input `
        -SelectedType $selectedType `
        -ExpectedActions $actions `
        -SelectedTypes $selectedTypes
    if ($Operation -ceq 'ReadDlpProfile') {
        Write-TypedResult -Value $state
        return
    }

    if ($Operation -ceq 'CreateDlpPolicy') {
        $script:SettingsStage = 10
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
            ConvertTo-Json -Depth 10 -Compress -AsArray
        if ([string]$state.state -ceq 'Absent') {
            New-DlpCompliancePolicy `
                -Name ([string]$input.policyName) `
                -Mode (ConvertTo-ProviderMode -Mode $policyMode) `
                -Locations $locations `
                -EnforcementPlanes @('Application') `
                -Confirm:$false |
                Out-Null
        }
        elseif ([string]$state.state -ceq 'Mismatch') {
            $policy = Get-DlpPolicyUpdateTarget -InputObject $input
            Set-DlpCompliancePolicy `
                -Identity $policy.Identity `
                -Mode (ConvertTo-ProviderMode -Mode $policyMode) `
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
    $script:SettingsStage = 11
    $providerActions = @($actions | ForEach-Object {
        @{
            setting = [string]$_.activity
            value = [string]$_.action
        }
    })
    $providerSensitiveTypes = New-DlpSensitiveInformationCondition -SelectedTypes $selectedTypes
    if ([string]::IsNullOrWhiteSpace([string]$state.ruleProviderId)) {
        if (-not [string]::IsNullOrWhiteSpace(
                [string]$input.expectedRuleProviderId)) {
            throw 'A provider-ID-bound DLP rule is absent and cannot be recreated.'
        }
        New-DlpComplianceRule `
            -Name ([string]$input.ruleName) `
            -Policy ([string]$input.policyName) `
            -ContentContainsSensitiveInformation $providerSensitiveTypes `
            -RestrictAccess $providerActions `
            -WarningAction SilentlyContinue `
            -Confirm:$false |
            Out-Null
    }
    else {
        $rule = Get-DlpRuleUpdateTarget -InputObject $input
        Set-DlpComplianceRule `
            -Identity $rule.Identity `
            -ContentContainsSensitiveInformation $providerSensitiveTypes `
            -RestrictAccess $providerActions `
            -WarningAction SilentlyContinue `
            -Confirm:$false |
            Out-Null
    }
    Write-TypedResult -Value @{ state = 'MutationAccepted' }
}
catch {
    try { Write-SafeSettingsFailure -Record $_ } catch { }
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
        catch { }
    }
    $certificate.Dispose()
    $securePassword.Dispose()
}
