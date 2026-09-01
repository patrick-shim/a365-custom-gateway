[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$CertificatePath,
    [Parameter(Mandatory)][string]$AutomationApplicationId,
    [Parameter(Mandatory)][string]$Organization,
    [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:EnterpriseAiAppsCollectionLocationId = 'ee1680d0-702f-4090-b26c-c49091e86531'
$script:SensitiveInformationTypeInventoryLimit = 2048

function Get-ExactProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string[]]$Names,
        [switch]$Optional
    )

    foreach ($name in $Names) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            $keys = @($InputObject.Keys | Where-Object {
                ([string]$_).Equals($name, [StringComparison]::OrdinalIgnoreCase)
            })
            if ($keys.Count -eq 1) { return $InputObject[$keys[0]] }
            continue
        }

        $properties = @($InputObject.PSObject.Properties | Where-Object {
            $_.Name.Equals($name, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($properties.Count -eq 1) { return $properties[0].Value }
    }

    if ($Optional) { return $null }
    throw "Purview readback omitted required typed property '$($Names -join '/')'."
}

function Convert-ToStructuredValue {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Label,
        [switch]$AllowNull
    )

    if ($null -eq $Value) {
        if ($AllowNull) { return $null }
        throw "Purview $Label readback was null."
    }
    if ($Value -isnot [string]) { return $Value }
    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($AllowNull) { return $null }
        throw "Purview $Label readback was empty."
    }

    try { return $Value | ConvertFrom-Json -Depth 50 -ErrorAction Stop }
    catch { throw "Purview $Label readback was not valid structured JSON." }
}

function Convert-ToStructuredArray {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Label,
        [switch]$AllowEmpty
    )

    if ($null -eq $Value) {
        if ($AllowEmpty) { return @() }
        throw "Purview $Label readback was null."
    }
    $structured = Convert-ToStructuredValue -Value $Value -Label $Label -AllowNull:$AllowEmpty
    if ($null -eq $structured) { return @() }
    $items = @($structured)
    if (-not $AllowEmpty -and $items.Count -eq 0) {
        throw "Purview $Label readback was empty."
    }
    return $items
}

function Test-ExactSet {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected
    )

    if ($Actual.Count -ne $Expected.Count) { return $false }
    return (@($Actual | Sort-Object) -join '|') -ceq (@($Expected | Sort-Object) -join '|')
}

function Convert-ToExactGuidSet {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Label
    )

    $items = @($Value)
    if ($items.Count -gt 512) { throw "Purview $Label exceeds the safe Application scope limit." }
    $normalized = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $items) {
        $parsed = [Guid]::Empty
        if ($item -isnot [string] -or
            -not [Guid]::TryParse([string]$item, [ref]$parsed) -or
            $parsed -eq [Guid]::Empty) {
            throw "Purview $Label contains an invalid Application ID."
        }
        $canonical = $parsed.ToString('D')
        if ($normalized.Contains($canonical)) {
            throw "Purview $Label contains a duplicate Application ID."
        }
        $normalized.Add($canonical)
    }
    return @($normalized | Sort-Object)
}

function Test-ValidSensitiveInformationTypeName {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 255) {
        return $false
    }
    foreach ($character in $Value.ToCharArray()) {
        $codePoint = [int][char]$character
        if ($codePoint -le 0x1f -or $codePoint -eq 0x7f) {
            return $false
        }
    }
    return $true
}

function Get-ExactSensitiveInformationType {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$ExpectedName
    )

    $selectedId = [Guid]::Empty
    if (-not [Guid]::TryParse($Id, [ref]$selectedId) -or
        $selectedId -eq [Guid]::Empty -or
        $Id -cne $selectedId.ToString('D') -or
        -not (Test-ValidSensitiveInformationTypeName -Value $ExpectedName)) {
        throw 'The configured Purview sensitive information type is invalid.'
    }

    # Identity lookup is intentionally not used: the documented cmdlet can
    # return the full catalog for a missing identity. Enumerate once and filter
    # locally by the stable GUID.
    $inventory = @(Get-DlpSensitiveInformationType -ErrorAction Stop |
        Where-Object { $null -ne $_ })
    if ($inventory.Count -eq 0 -or
        $inventory.Count -gt $script:SensitiveInformationTypeInventoryLimit) {
        throw 'The Purview sensitive information type catalog was empty or exceeded its safe limit.'
    }

    $seenIds = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $seenNames = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $matches = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $inventory) {
        $entryIdValue = [string](Get-ExactProperty -InputObject $entry -Names @('Id'))
        $entryName = [string](Get-ExactProperty -InputObject $entry -Names @('Name'))
        $entryId = [Guid]::Empty
        if (-not [Guid]::TryParse($entryIdValue, [ref]$entryId) -or
            $entryId -eq [Guid]::Empty -or
            -not (Test-ValidSensitiveInformationTypeName -Value $entryName)) {
            throw 'The Purview sensitive information type catalog returned an invalid typed entry.'
        }
        $entryIdText = $entryId.ToString('D')
        if (-not $seenIds.Add($entryIdText)) {
            throw 'The Purview sensitive information type catalog returned duplicate identifiers.'
        }
        if (-not $seenNames.Add($entryName)) {
            throw 'The Purview sensitive information type catalog returned duplicate exact Names.'
        }
        if ($entryIdText -ceq $selectedId.ToString('D')) {
            $matches.Add([pscustomobject]@{ Id = $entryIdText; Name = $entryName })
        }
    }

    if ($matches.Count -ne 1) {
        throw 'The configured sensitive information type did not resolve exactly once in the Purview catalog.'
    }
    if ($matches[0].Name -cne $ExpectedName) {
        throw 'The configured sensitive information type Name does not match the current Purview catalog Name.'
    }
    return $matches[0]
}

function Test-MeaningfulValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        return -not ([string]::IsNullOrWhiteSpace($Value) -or
            $Value.Equals('False', [StringComparison]::OrdinalIgnoreCase) -or
            $Value.Equals('None', [StringComparison]::OrdinalIgnoreCase) -or
            $Value.Equals('NotSet', [StringComparison]::OrdinalIgnoreCase) -or
            $Value -eq '[]' -or $Value -eq '{}')
    }
    if ($Value -is [System.Collections.IEnumerable]) { return @($Value).Count -gt 0 }
    return $true
}

function Assert-NoNamedValues {
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Label
    )

    foreach ($name in $Names) {
        $value = Get-ExactProperty -InputObject $Resource -Names @($name) -Optional
        if (Test-MeaningfulValue -Value $value) {
            throw "Purview $Label contains unreviewed '$name' configuration."
        }
    }
}

function Get-ResourcePropertyEntries {
    param([Parameter(Mandatory)]$Resource)

    if ($Resource -is [System.Collections.IDictionary]) {
        foreach ($entry in $Resource.GetEnumerator()) {
            [pscustomobject]@{ Name = [string]$entry.Key; Value = $entry.Value }
        }
        return
    }
    foreach ($property in $Resource.PSObject.Properties) {
        [pscustomobject]@{ Name = $property.Name; Value = $property.Value }
    }
}

function Assert-NoUnknownMeaningfulProperties {
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][string[]]$AllowedNames,
        [Parameter(Mandatory)][string]$Label
    )

    foreach ($entry in @(Get-ResourcePropertyEntries -Resource $Resource)) {
        $recognized = @($AllowedNames | Where-Object {
            $_.Equals($entry.Name, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if (-not $recognized -and (Test-MeaningfulValue -Value $entry.Value)) {
            throw "Purview $Label returned unrecognized meaningful property '$($entry.Name)'."
        }
    }
}

function Get-ResourceName {
    param([Parameter(Mandatory)]$Resource)
    return [string](Get-ExactProperty -InputObject $Resource -Names @('Name'))
}

function Get-ResourceIdentity {
    param([Parameter(Mandatory)]$Resource, [Parameter(Mandatory)][string]$Label)
    $identity = [string](Get-ExactProperty -InputObject $Resource -Names @('Identity'))
    if ([string]::IsNullOrWhiteSpace($identity) -or $identity.Length -gt 256) {
        throw "Purview $Label returned an invalid resource identity."
    }
    return $identity
}

function Get-ExactCollectionPolicy {
    param([Parameter(Mandatory)][string]$Name)

    # Enumerate with terminating error semantics and filter locally. A failed
    # provider lookup must never be translated into absence followed by create.
    $matches = @(Get-FeatureConfiguration -FeatureScenario KnowYourData -ErrorAction Stop |
        Where-Object {
            [string]$_.Name -ceq $Name -or [string]$_.Identity -ceq $Name
        })
    if ($matches.Count -gt 1) { throw "Multiple collection policies matched '$Name'." }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Get-ExactDlpPolicy {
    param([Parameter(Mandatory)][string]$Name)

    $matches = @(Get-DlpCompliancePolicy -ErrorAction Stop | Where-Object {
        [string]$_.Name -ceq $Name -or [string]$_.Identity -ceq $Name
    })
    if ($matches.Count -gt 1) { throw "Multiple DLP policies matched '$Name'." }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Get-ExactDlpRule {
    param([Parameter(Mandatory)][string]$Name)

    $matches = @(Get-DlpComplianceRule -ErrorAction Stop | Where-Object {
        [string]$_.Name -ceq $Name -or [string]$_.Identity -ceq $Name
    })
    if ($matches.Count -gt 1) { throw "Multiple DLP rules matched '$Name'." }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function New-CollectionLocation {
    return [ordered]@{
        Workload = 'Applications'
        Location = $script:EnterpriseAiAppsCollectionLocationId
        LocationSource = 'Entra'
        LocationType = 'Group'
        Inclusions = @(@{ Type = 'Tenant'; Identity = 'All' })
    }
}

function New-DlpApplicationLocation {
    param(
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$DisplayName
    )

    return [ordered]@{
        Workload = 'Applications'
        Location = $ApplicationId
        LocationDisplayName = $DisplayName
        LocationSource = 'Entra'
        LocationType = 'Individual'
        Inclusions = @(@{ Type = 'Tenant'; Identity = 'All' })
    }
}

function Merge-DlpApplicationLocation {
    param(
        [object[]]$Locations,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$DisplayName
    )

    $result = [System.Collections.Generic.List[object]]::new()
    $found = $false
    foreach ($location in $Locations) {
        if ($null -eq $location) { continue }
        $locationId = [string](Get-ExactProperty -InputObject $location -Names @('Location'))
        if ($locationId.Equals($ApplicationId, [StringComparison]::OrdinalIgnoreCase)) {
            if ($found) { throw 'The existing Purview policy contains a duplicate blueprint Application location.' }
            $found = $true
        }
        $result.Add($location)
    }
    if (-not $found) {
        $result.Add((New-DlpApplicationLocation -ApplicationId $ApplicationId -DisplayName $DisplayName))
    }
    return @($result)
}

function Assert-TenantApplicationLocations {
    param(
        [AllowNull()]$Value,
        [AllowNull()][AllowEmptyCollection()][string[]]$ExpectedApplicationIds,
        [Parameter(Mandatory)][string]$ResourceName,
        [Parameter(Mandatory)][ValidateSet('Group', 'Individual')][string]$ExpectedLocationType
    )

    $locations = @(Convert-ToStructuredArray -Value $Value -Label "$ResourceName Locations")
    $applicationIds = [System.Collections.Generic.List[string]]::new()
    foreach ($location in $locations) {
        if ([string](Get-ExactProperty -InputObject $location -Names @('Workload')) -cne 'Applications' -or
            [string](Get-ExactProperty -InputObject $location -Names @('LocationSource')) -cne 'Entra' -or
            [string](Get-ExactProperty -InputObject $location -Names @('LocationType')) -cne $ExpectedLocationType) {
            throw "Purview resource '$ResourceName' contains an unreviewed Application location shape."
        }

        $locationId = [string](Get-ExactProperty -InputObject $location -Names @('Location'))
        $parsedLocationId = [Guid]::Empty
        if (-not [Guid]::TryParse($locationId, [ref]$parsedLocationId) -or $parsedLocationId -eq [Guid]::Empty) {
            throw "Purview resource '$ResourceName' returned an invalid Application location ID."
        }
        if (@($applicationIds | Where-Object {
            $_.Equals($locationId, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0) {
            throw "Purview resource '$ResourceName' contains a duplicate Application location."
        }
        $applicationIds.Add($parsedLocationId.ToString('D'))

        $inclusions = @(Convert-ToStructuredArray -Value (
            Get-ExactProperty -InputObject $location -Names @('Inclusions')) -Label 'location Inclusions')
        if ($inclusions.Count -ne 1 -or
            [string](Get-ExactProperty -InputObject $inclusions[0] -Names @('Type')) -cne 'Tenant' -or
            [string](Get-ExactProperty -InputObject $inclusions[0] -Names @('Identity')) -cne 'All') {
            throw "Purview resource '$ResourceName' does not have the exact tenant-wide Application inclusion."
        }
        Assert-NoUnknownMeaningfulProperties -Resource $inclusions[0] `
            -AllowedNames @('Type', 'Identity') -Label "$ResourceName location inclusion"
        Assert-NoNamedValues -Resource $location -Names @(
            'Exclusions', 'ExcludedLocations', 'Exceptions', 'Bypass', 'BypassRules'
        ) -Label "$ResourceName location"
        Assert-NoUnknownMeaningfulProperties -Resource $location -AllowedNames @(
            'Workload', 'Location', 'LocationDisplayName', 'LocationSource',
            'LocationType', 'Inclusions', 'Exclusions', 'ExcludedLocations',
            'Exceptions', 'Bypass', 'BypassRules'
        ) -Label "$ResourceName location"
    }

    if ($null -ne $ExpectedApplicationIds -and
        -not (Test-ExactSet -Actual @($applicationIds) -Expected $ExpectedApplicationIds)) {
        throw "Purview resource '$ResourceName' did not read back the exact authorized Application scope."
    }
    return @($applicationIds)
}

function Assert-ExactCollectionLocation {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$ResourceName
    )

    return @(Assert-TenantApplicationLocations -Value $Value `
        -ExpectedApplicationIds @($script:EnterpriseAiAppsCollectionLocationId) `
        -ResourceName $ResourceName -ExpectedLocationType 'Group')
}

function Assert-DlpApplicationLocations {
    param(
        [AllowNull()]$Value,
        [AllowNull()][AllowEmptyCollection()][string[]]$ExpectedApplicationIds,
        [Parameter(Mandatory)][string]$ResourceName
    )

    return @(Assert-TenantApplicationLocations -Value $Value `
        -ExpectedApplicationIds $ExpectedApplicationIds `
        -ResourceName $ResourceName -ExpectedLocationType 'Individual')
}

function Assert-NoExtraRuleBehavior {
    param([Parameter(Mandatory)]$Rule)

    # Current official New-DlpComplianceRule parameters are classified here.
    # ContentContainsSensitiveInformation and RestrictAccess are the sole reviewed
    # condition/action; every other meaningful rule behavior fails closed.
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
    Assert-NoNamedValues -Resource $Rule -Names $knownExtraConditions -Label 'DLP rule conditions'
    Assert-NoNamedValues -Resource $Rule -Names $knownExtraActions -Label 'DLP rule actions'

    foreach ($property in $Rule.PSObject.Properties) {
        if (($property.Name.StartsWith('ExceptIf', [StringComparison]::OrdinalIgnoreCase) -or
             $property.Name.Contains('Bypass', [StringComparison]::OrdinalIgnoreCase) -or
             $property.Name.Contains('Override', [StringComparison]::OrdinalIgnoreCase)) -and
            (Test-MeaningfulValue -Value $property.Value)) {
            throw "Purview DLP rule contains unreviewed condition or action '$($property.Name)'."
        }
    }

    $disabled = Get-ExactProperty -InputObject $Rule -Names @('Disabled') -Optional
    if (Test-MeaningfulValue -Value $disabled) {
        throw 'Purview DLP rule is disabled.'
    }

    $metadataProperties = @(
        'Name', 'DisplayName', 'Identity', 'Guid', 'ImmutableId', 'ParentPolicyName',
        'PolicyName', 'Policy', 'PolicyId', 'Comment', 'Description', 'Priority',
        'CreatedBy', 'LastModifiedBy', 'WhenCreated', 'WhenCreatedUTC', 'WhenChanged',
        'WhenChangedUTC', 'ExchangeVersion', 'ObjectState', 'OrganizationId',
        'DistinguishedName', 'IsValid', 'ObjectCategory', 'ObjectClass', 'Status',
        'Workload', 'Version', 'RunspaceId', 'PSComputerName', 'PSShowComputerName',
        'PSSourceJobInstanceId', 'SerializationData'
    )
    Assert-NoUnknownMeaningfulProperties -Resource $Rule -AllowedNames @(
        $metadataProperties
        'ContentContainsSensitiveInformation'
        'RestrictAccess'
        'Disabled'
        $knownExtraConditions
        $knownExtraActions
    ) -Label 'DLP rule'
}

function Assert-ExactReadback {
    param(
        [Parameter(Mandatory)]$Collection,
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)]$Rule,
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$ExpectedDlpMode,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedDlpApplicationIds
    )

    $collectionName = [string]$InputObject.collectionPolicyName
    $policyName = [string]$InputObject.dlpPolicyName
    $ruleName = [string]$InputObject.dlpRuleName
    $sensitiveInformationTypeId = [string]$InputObject.sensitiveInformationTypeId
    $sensitiveInformationType = [string]$InputObject.sensitiveInformationType

    if ((Get-ResourceName -Resource $Collection) -cne $collectionName -or
        [string](Get-ExactProperty -InputObject $Collection -Names @('Mode')) -cne 'Enable') {
        throw 'The collection policy name or mode did not read back exactly.'
    }
    $scenario = Convert-ToStructuredValue -Value (
        Get-ExactProperty -InputObject $Collection -Names @('ScenarioConfig')) -Label 'ScenarioConfig'
    $activities = @((Get-ExactProperty -InputObject $scenario -Names @('Activities')) |
        ForEach-Object { [string]$_ })
    $collectionPlanes = @((Get-ExactProperty -InputObject $scenario -Names @('EnforcementPlanes')) |
        ForEach-Object { [string]$_ })
    $sensitiveTypeIds = @((Get-ExactProperty -InputObject $scenario -Names @('SensitiveTypeIds')) |
        ForEach-Object { [string]$_ })
    $ingestionEnabled = Get-ExactProperty -InputObject $scenario -Names @('IsIngestionEnabled')
    if (-not (Test-ExactSet -Actual $activities -Expected @('UploadText', 'DownloadText')) -or
        -not (Test-ExactSet -Actual $collectionPlanes -Expected @('Application')) -or
        -not (Test-ExactSet -Actual $sensitiveTypeIds -Expected @('All')) -or
        $ingestionEnabled -ne $true) {
        throw 'The collection policy ScenarioConfig did not read back exactly.'
    }
    Assert-NoUnknownMeaningfulProperties -Resource $scenario -AllowedNames @(
        'Activities', 'EnforcementPlanes', 'SensitiveTypeIds', 'IsIngestionEnabled'
    ) -Label 'collection policy ScenarioConfig'
    $collectionLocationIds = @(Assert-ExactCollectionLocation -Value (
        Get-ExactProperty -InputObject $Collection -Names @('Locations')) `
        -ResourceName $collectionName)
    Assert-NoNamedValues -Resource $Collection -Names @(
        'Exclusions', 'ExcludedLocations', 'Exceptions', 'Bypass', 'BypassRules'
    ) -Label 'collection policy'
    $providerMetadataProperties = @(
        'Name', 'DisplayName', 'Identity', 'Guid', 'ImmutableId', 'Comment',
        'Description', 'Priority', 'CreatedBy', 'LastModifiedBy', 'WhenCreated',
        'WhenCreatedUTC', 'WhenChanged', 'WhenChangedUTC', 'ExchangeVersion',
        'ObjectState', 'OrganizationId', 'DistinguishedName', 'IsValid',
        'ObjectCategory', 'ObjectClass', 'Status', 'Workload', 'Version',
        'RunspaceId', 'PSComputerName', 'PSShowComputerName',
        'PSSourceJobInstanceId', 'SerializationData'
    )
    Assert-NoUnknownMeaningfulProperties -Resource $Collection -AllowedNames @(
        $providerMetadataProperties
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
    ) -Label 'collection policy'

    if ((Get-ResourceName -Resource $Policy) -cne $policyName -or
        [string](Get-ExactProperty -InputObject $Policy -Names @('Mode')) -cne $ExpectedDlpMode) {
        throw 'The DLP policy name or mode did not read back exactly.'
    }
    $policyPlanes = @((Get-ExactProperty -InputObject $Policy -Names @('EnforcementPlanes')) |
        ForEach-Object { [string]$_ })
    if (-not (Test-ExactSet -Actual $policyPlanes -Expected @('Application'))) {
        throw 'The DLP policy enforcement plane did not read back exactly.'
    }
    $policyApplicationIds = @(Assert-DlpApplicationLocations -Value (
        Get-ExactProperty -InputObject $Policy -Names @('Locations')) `
        -ExpectedApplicationIds $ExpectedDlpApplicationIds -ResourceName $policyName)
    Assert-NoNamedValues -Resource $Policy -Names @(
        'Exclusions', 'ExcludedLocations', 'Exceptions', 'Bypass', 'BypassRules'
    ) -Label 'DLP policy'
    $policyExtraBehavior = @(
        'EndpointDlpAdaptiveScopes', 'EndpointDlpAdaptiveScopesException',
        'EndpointDlpLocation', 'EndpointDlpLocationException',
        'ExceptIfOneDriveSharedBy', 'ExceptIfOneDriveSharedByMemberOf',
        'ExchangeAdaptiveScopes', 'ExchangeAdaptiveScopesException',
        'ExchangeLocation', 'ExchangeSenderMemberOf',
        'ExchangeSenderMemberOfException', 'IsFromSmartInsights',
        'OneDriveAdaptiveScopes', 'OneDriveAdaptiveScopesException',
        'OneDriveLocation', 'OneDriveLocationException', 'OneDriveSharedBy',
        'OneDriveSharedByMemberOf', 'OnPremisesScannerDlpLocation',
        'OnPremisesScannerDlpLocationException', 'PolicyRBACScopes',
        'PolicyTemplateInfo', 'PowerBIDlpLocation', 'PowerBIDlpLocationException',
        'SharePointAdaptiveScopes', 'SharePointAdaptiveScopesException',
        'SharePointLocation', 'SharePointLocationException', 'TeamsAdaptiveScopes',
        'TeamsAdaptiveScopesException', 'TeamsLocation', 'TeamsLocationException',
        'ThirdPartyAppDlpLocation', 'ThirdPartyAppDlpLocationException'
    )
    Assert-NoNamedValues -Resource $Policy -Names $policyExtraBehavior -Label 'DLP policy behavior'
    foreach ($property in $Policy.PSObject.Properties) {
        if (($property.Name.StartsWith('ExceptIf', [StringComparison]::OrdinalIgnoreCase) -or
             $property.Name.Contains('Exception', [StringComparison]::OrdinalIgnoreCase) -or
             $property.Name.Contains('Bypass', [StringComparison]::OrdinalIgnoreCase)) -and
            (Test-MeaningfulValue -Value $property.Value)) {
            throw "Purview DLP policy contains unreviewed exclusion or bypass '$($property.Name)'."
        }
    }
    Assert-NoUnknownMeaningfulProperties -Resource $Policy -AllowedNames @(
        $providerMetadataProperties
        'Mode'
        'Locations'
        'EnforcementPlanes'
        'Exclusions'
        'ExcludedLocations'
        'Exceptions'
        'Bypass'
        'BypassRules'
        $policyExtraBehavior
    ) -Label 'DLP policy'

    if ((Get-ResourceName -Resource $Rule) -cne $ruleName -or
        [string](Get-ExactProperty -InputObject $Rule -Names @(
            'ParentPolicyName', 'PolicyName', 'Policy')) -cne $policyName) {
        throw 'The DLP rule name or parent policy did not read back exactly.'
    }
    $conditions = @(Convert-ToStructuredArray -Value (
        Get-ExactProperty -InputObject $Rule -Names @('ContentContainsSensitiveInformation')) `
        -Label 'ContentContainsSensitiveInformation')
    if ($conditions.Count -ne 1) {
        throw 'The DLP rule classifier did not read back exactly.'
    }
    $classifierIdValue = [string](Get-ExactProperty -InputObject $conditions[0] -Names @('Id'))
    $classifierId = [Guid]::Empty
    if (-not [Guid]::TryParse($classifierIdValue, [ref]$classifierId) -or
        $classifierId -eq [Guid]::Empty) {
        throw 'The DLP rule classifier did not read back exactly.'
    }
    $classifierIds = @($classifierId.ToString('D'))
    $classifierNames = @([string](Get-ExactProperty -InputObject $conditions[0] -Names @('Name')))
    if (-not (Test-ExactSet -Actual $classifierIds -Expected @($sensitiveInformationTypeId)) -or
        -not (Test-ExactSet -Actual $classifierNames -Expected @($sensitiveInformationType))) {
        throw 'The DLP rule classifier did not read back exactly.'
    }
    Assert-NoUnknownMeaningfulProperties -Resource $conditions[0] `
        -AllowedNames @('Id', 'Name') -Label 'DLP rule classifier condition'
    $restrictAccess = @(Convert-ToStructuredArray -Value (
        Get-ExactProperty -InputObject $Rule -Names @('RestrictAccess')) -Label 'RestrictAccess')
    if ($restrictAccess.Count -ne 1 -or
        [string](Get-ExactProperty -InputObject $restrictAccess[0] -Names @('setting', 'Setting')) -cne 'UploadText' -or
        [string](Get-ExactProperty -InputObject $restrictAccess[0] -Names @('value', 'Value')) -cne 'Block') {
        throw 'The DLP rule action is not exactly UploadText=Block.'
    }
    Assert-NoUnknownMeaningfulProperties -Resource $restrictAccess[0] `
        -AllowedNames @('setting', 'value') -Label 'DLP rule RestrictAccess action'
    Assert-NoExtraRuleBehavior -Rule $Rule

    $collectionIdentity = Get-ResourceIdentity -Resource $Collection -Label 'collection policy'
    $policyIdentity = Get-ResourceIdentity -Resource $Policy -Label 'DLP policy'
    $ruleIdentity = Get-ResourceIdentity -Resource $Rule -Label 'DLP rule'
    foreach ($expected in @(
        @{ Value = [string]$InputObject.expectedCollectionPolicyId; Actual = $collectionIdentity; Label = 'collection policy' },
        @{ Value = [string]$InputObject.expectedDlpPolicyId; Actual = $policyIdentity; Label = 'DLP policy' },
        @{ Value = [string]$InputObject.expectedDlpRuleId; Actual = $ruleIdentity; Label = 'DLP rule' }
    )) {
        if (-not [string]::IsNullOrWhiteSpace($expected.Value) -and $expected.Value -cne $expected.Actual) {
            throw "The $($expected.Label) ID did not match the persisted profile ID."
        }
    }

    return [ordered]@{
        collectionPolicyId = $collectionIdentity
        dlpPolicyId = $policyIdentity
        dlpRuleId = $ruleIdentity
        collectionMode = 'Enable'
        collectionActivities = @($activities)
        collectionEnforcementPlanes = @($collectionPlanes)
        collectionSensitiveTypeIds = @($sensitiveTypeIds)
        collectionIngestionEnabled = $true
        collectionLocation = [ordered]@{
            workload = 'Applications'
            locationSource = 'Entra'
            locationType = 'Group'
            locationIds = @($collectionLocationIds)
        }
        dlpMode = $ExpectedDlpMode
        dlpEnforcementPlanes = @($policyPlanes)
        dlpLocation = [ordered]@{
            workload = 'Applications'
            locationSource = 'Entra'
            locationType = 'Individual'
            locationIds = @($policyApplicationIds)
        }
        classifierIds = @($classifierIds)
        classifierNames = @($classifierNames)
        ruleActions = @(@{ setting = 'UploadText'; value = 'Block' })
        hasExclusions = $false
        hasBypass = $false
        hasExtraConditions = $false
        hasExtraActions = $false
        dlpBlueprintApplicationIds = @($policyApplicationIds)
        verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
}

function Invoke-ExactPurviewProfile {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$ExpectedDlpMode,
        [switch]$VerifyOnly
    )

    $applicationId = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$InputObject.blueprintApplicationId, [ref]$applicationId) -or
        $applicationId -eq [Guid]::Empty) {
        throw 'The blueprint Application ID is invalid.'
    }
    $applicationIdText = $applicationId.ToString('D')
    $priorDlpApplicationIds = @(Convert-ToExactGuidSet `
        -Value $InputObject.expectedPriorDlpBlueprintApplicationIds `
        -Label 'prior authorized DLP Application scope')
    $expectedDlpApplicationIds = @(Convert-ToExactGuidSet `
        -Value $InputObject.expectedDlpBlueprintApplicationIds `
        -Label 'expected DLP Application scope')
    $computedDlpUnion = @($priorDlpApplicationIds + $applicationIdText | Sort-Object -Unique)
    if (-not (Test-ExactSet -Actual $expectedDlpApplicationIds -Expected $computedDlpUnion)) {
        throw 'The expected Purview DLP Application scope is not the exact prior-authority union.'
    }
    $resolvedSensitiveInformationType = Get-ExactSensitiveInformationType `
        -Id ([string]$InputObject.sensitiveInformationTypeId) `
        -ExpectedName ([string]$InputObject.sensitiveInformationType)

    $scenarioConfig = @{
        Activities = @('UploadText', 'DownloadText')
        EnforcementPlanes = @('Application')
        SensitiveTypeIds = @('All')
        IsIngestionEnabled = $true
    } | ConvertTo-Json -Compress
    $collection = Get-ExactCollectionPolicy -Name ([string]$InputObject.collectionPolicyName)
    $policy = Get-ExactDlpPolicy -Name ([string]$InputObject.dlpPolicyName)
    $rule = Get-ExactDlpRule -Name ([string]$InputObject.dlpRuleName)
    $existingCount = @(@($collection, $policy, $rule) |
        Where-Object { $null -ne $_ }).Count

    if ($existingCount -notin @(0, 3)) {
        throw 'The Purview managed profile is only partially present and cannot be adopted or mutated.'
    }

    if ($existingCount -eq 3) {
        if ([string]::IsNullOrWhiteSpace([string]$InputObject.expectedCollectionPolicyId) -or
            [string]::IsNullOrWhiteSpace([string]$InputObject.expectedDlpPolicyId) -or
            [string]::IsNullOrWhiteSpace([string]$InputObject.expectedDlpRuleId)) {
            throw 'Existing Purview resources lack persisted provider-ID authority and cannot be adopted.'
        }

        Assert-ExactCollectionLocation -Value $collection.Locations `
            -ResourceName ([string]$InputObject.collectionPolicyName) | Out-Null
        $policyScope = @(Assert-DlpApplicationLocations -Value $policy.Locations `
            -ExpectedApplicationIds $null `
            -ResourceName ([string]$InputObject.dlpPolicyName))
        $policyAtPrior = Test-ExactSet -Actual $policyScope -Expected $priorDlpApplicationIds
        $policyAtExpected = Test-ExactSet -Actual $policyScope -Expected $expectedDlpApplicationIds
        if ($VerifyOnly) {
            if (-not $policyAtExpected) {
                throw 'Purview read-only verification did not return the exact authorized DLP Application scope.'
            }
        }
        elseif (-not $policyAtPrior -and -not $policyAtExpected) {
            throw 'Purview existing DLP scope is neither the exact prior nor expected authorized DLP Application scope.'
        }

        Assert-ExactReadback -Collection $collection -Policy $policy -Rule $rule `
            -InputObject $InputObject -ExpectedDlpMode $ExpectedDlpMode `
            -ExpectedDlpApplicationIds $policyScope | Out-Null

        if (-not $VerifyOnly -and -not $policyAtExpected) {
            $displayName = [string]$InputObject.blueprintDisplayName
            $policyLocations = @(Convert-ToStructuredArray -Value $policy.Locations `
                -Label ([string]$InputObject.dlpPolicyName))
            $policyLocationsJson = Merge-DlpApplicationLocation -Locations $policyLocations `
                -ApplicationId $applicationIdText -DisplayName $displayName |
                ConvertTo-Json -Depth 10 -Compress
            Set-DlpCompliancePolicy -Identity $policy.Identity `
                -Locations $policyLocationsJson -Mode $ExpectedDlpMode `
                -EnforcementPlanes @('Application') -Confirm:$false | Out-Null
        }
    }
    else {
        if ($VerifyOnly) {
            throw 'The expected Purview managed profile was not found during read-only verification.'
        }
        if ($priorDlpApplicationIds.Count -ne 0 -or
            -not [string]::IsNullOrWhiteSpace([string]$InputObject.expectedCollectionPolicyId) -or
            -not [string]::IsNullOrWhiteSpace([string]$InputObject.expectedDlpPolicyId) -or
            -not [string]::IsNullOrWhiteSpace([string]$InputObject.expectedDlpRuleId)) {
            throw 'Persisted Purview authority refers to provider resources that are absent.'
        }

        $collectionLocationsJson = @((New-CollectionLocation)) |
            ConvertTo-Json -Depth 10 -Compress
        $dlpLocationsJson = @((New-DlpApplicationLocation -ApplicationId $applicationIdText `
            -DisplayName ([string]$InputObject.blueprintDisplayName))) |
            ConvertTo-Json -Depth 10 -Compress
        New-FeatureConfiguration -FeatureScenario KnowYourData `
            -Name ([string]$InputObject.collectionPolicyName) -Mode Enable `
            -ScenarioConfig $scenarioConfig -Locations $collectionLocationsJson -Confirm:$false | Out-Null
        New-DlpCompliancePolicy -Name ([string]$InputObject.dlpPolicyName) `
            -Mode $ExpectedDlpMode -Locations $dlpLocationsJson `
            -EnforcementPlanes @('Application') -Confirm:$false | Out-Null
        New-DlpComplianceRule -Name ([string]$InputObject.dlpRuleName) `
            -Policy ([string]$InputObject.dlpPolicyName) `
            -ContentContainsSensitiveInformation @{ Name = $resolvedSensitiveInformationType.Name } `
            -RestrictAccess @(@{ setting = 'UploadText'; value = 'Block' }) `
            -Confirm:$false | Out-Null
    }

    # Always perform fresh exact readback after any mutation. Provider lookup
    # failures remain terminating and can never be interpreted as absence.
    $collection = Get-ExactCollectionPolicy -Name ([string]$InputObject.collectionPolicyName)
    $policy = Get-ExactDlpPolicy -Name ([string]$InputObject.dlpPolicyName)
    $rule = Get-ExactDlpRule -Name ([string]$InputObject.dlpRuleName)
    if ($null -eq $collection -or $null -eq $policy -or $null -eq $rule) {
        throw 'Purview exact readback did not return the complete managed profile.'
    }

    return Assert-ExactReadback -Collection $collection -Policy $policy -Rule $rule `
        -InputObject $InputObject -ExpectedDlpMode $ExpectedDlpMode `
        -ExpectedDlpApplicationIds $expectedDlpApplicationIds
}

$passwordText = [Console]::In.ReadLine()
if ([string]::IsNullOrWhiteSpace($passwordText)) { throw 'Certificate password was not supplied.' }
$securePassword = ConvertTo-SecureString $passwordText -AsPlainText -Force
$passwordText = $null
$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $CertificatePath,
    $securePassword,
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)

try {
    $input = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json -Depth 20
    $applicationId = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$input.blueprintApplicationId, [ref]$applicationId) -or
        $applicationId -eq [Guid]::Empty) {
        throw 'The blueprint Application ID is invalid.'
    }

    Import-Module ExchangeOnlineManagement -MinimumVersion 3.10.1 -ErrorAction Stop
    Connect-IPPSSession -AppId $AutomationApplicationId -Certificate $certificate `
        -Organization $Organization -ShowBanner:$false

    foreach ($command in @(
        'Get-FeatureConfiguration', 'New-FeatureConfiguration',
        'Get-DlpCompliancePolicy', 'New-DlpCompliancePolicy', 'Set-DlpCompliancePolicy',
        'Get-DlpComplianceRule', 'New-DlpComplianceRule',
        'Get-DlpSensitiveInformationType')) {
        try { Get-Command $command -ErrorAction Stop | Out-Null }
        catch { throw "Required Security & Compliance cmdlet '$command' is unavailable." }
    }

    $dlpMode = if ([string]$input.mode -eq 'Enforce') {
        'Enable'
    }
    elseif ([string]$input.mode -eq 'AuditOnly') {
        'TestWithoutNotifications'
    }
    else {
        throw 'The requested Purview policy mode is unsupported.'
    }
    $result = Invoke-ExactPurviewProfile -InputObject $input -ExpectedDlpMode $dlpMode `
        -VerifyOnly:$VerifyOnly |
        ConvertTo-Json -Depth 20 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($result))
    [Console]::Out.WriteLine("A365GW_RESULT:$encoded")
}
finally {
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
    $certificate.Dispose()
    $securePassword.Dispose()
}
