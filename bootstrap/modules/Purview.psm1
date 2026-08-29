Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Connect-BootstrapPurview {
    param(
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [Parameter(Mandatory)][string]$TenantId
    )
    Assert-GuidValue -Value $TenantId -Label 'Purview tenant ID'
    $canonicalTenantId = ([guid]$TenantId).ToString('D')
    if ($TenantId -cne $canonicalTenantId -or
        [string]::IsNullOrWhiteSpace($UserPrincipalName) -or
        $UserPrincipalName -match '[\x00-\x1f\x7f]') {
        throw 'Purview connection identity must use the canonical reviewed tenant and signed-in user.'
    }
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    $existingConnections = @(Get-ConnectionInformation -ErrorAction Stop)
    $existingEopConnections = @($existingConnections | Where-Object { $_.IsEopSession -eq $true })
    if ($existingEopConnections.Count -ne 0) {
        throw 'An existing Security & Compliance session is active. Disconnect it before bootstrap so tenant authority cannot be ambiguous.'
    }
    $existingIds = @($existingConnections | ForEach-Object { [string]$_.ConnectionId })
    $authorizationEndpoint = "https://login.microsoftonline.com/$canonicalTenantId"
    $newConnectionIds = @()
    try {
        Connect-IPPSSession `
            -UserPrincipalName $UserPrincipalName `
            -AzureADAuthorizationEndpointUri $authorizationEndpoint `
            -ShowBanner:$false | Out-Null
        $connections = @(Get-ConnectionInformation -ErrorAction Stop)
        $newConnections = @($connections | Where-Object { [string]$_.ConnectionId -notin $existingIds })
        $newConnectionIds = @($newConnections | ForEach-Object { [string]$_.ConnectionId })
        $activeEopConnections = @($connections | Where-Object {
            $_.IsEopSession -eq $true -and [string]$_.State -ceq 'Connected'
        })
        if ($newConnections.Count -ne 1 -or
            $activeEopConnections.Count -ne 1 -or
            [string]$newConnections[0].ConnectionId -cne [string]$activeEopConnections[0].ConnectionId -or
            [string]$activeEopConnections[0].TokenStatus -cne 'Active' -or
            -not ([string]$activeEopConnections[0].TenantID).Equals($canonicalTenantId, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$activeEopConnections[0].UserPrincipalName).Equals($UserPrincipalName, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'connection-mismatch'
        }
        $actualEndpoint = [Uri][string]$activeEopConnections[0].AzureAdAuthorizationEndpointUri
        if ($actualEndpoint.Scheme -cne 'https' -or
            -not $actualEndpoint.Host.Equals('login.microsoftonline.com', [StringComparison]::OrdinalIgnoreCase) -or
            $actualEndpoint.AbsolutePath.Trim('/') -cne $canonicalTenantId -or
            -not [string]::IsNullOrEmpty($actualEndpoint.Query) -or
            -not [string]::IsNullOrEmpty($actualEndpoint.Fragment)) {
            throw 'connection-endpoint-mismatch'
        }
        foreach ($command in @('Get-FeatureConfiguration', 'New-FeatureConfiguration', 'Get-DlpCompliancePolicy', 'New-DlpCompliancePolicy', 'Get-DlpComplianceRule', 'New-DlpComplianceRule')) {
            if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw 'required-command-unavailable' }
        }
        return [string]$activeEopConnections[0].ConnectionId
    }
    catch {
        if ($newConnectionIds.Count -eq 0) {
            try {
                $newConnectionIds = @(Get-ConnectionInformation -ErrorAction SilentlyContinue |
                    Where-Object { [string]$_.ConnectionId -notin $existingIds } |
                    ForEach-Object { [string]$_.ConnectionId })
            }
            catch { }
        }
        foreach ($connectionId in $newConnectionIds) {
            try { Disconnect-ExchangeOnline -ConnectionId $connectionId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
        throw 'Security & Compliance tenant/session authority could not be proven exactly. No Purview policy cmdlet was authorized; direct-member bootstrap does not support guest/delegated organizations.'
    }
}

function Disconnect-BootstrapPurview {
    param([Parameter(Mandatory)][string]$ConnectionId)
    Assert-GuidValue -Value $ConnectionId -Label 'Owned Security & Compliance connection ID'
    Disconnect-ExchangeOnline -ConnectionId $ConnectionId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

function Get-BootstrapPurviewProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string[]]$Names,
        [switch]$Optional
    )
    foreach ($name in $Names) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            $keys = @($InputObject.Keys | Where-Object { ([string]$_).Equals($name, [StringComparison]::OrdinalIgnoreCase) })
            if ($keys.Count -eq 1) { return $InputObject[$keys[0]] }
            continue
        }
        $property = @($InputObject.PSObject.Properties | Where-Object { $_.Name.Equals($name, [StringComparison]::OrdinalIgnoreCase) })
        if ($property.Count -eq 1) { return $property[0].Value }
    }
    if ($Optional) { return $null }
    throw "Purview readback omitted required typed property '$($Names -join '/')'."
}

function ConvertFrom-BootstrapPurviewStructuredValue {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Label)
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { throw "Purview $Label readback was empty." }
        try { return $Value | ConvertFrom-Json -Depth 50 -ErrorAction Stop }
        catch { throw "Purview $Label readback was not valid structured JSON." }
    }
    return $Value
}

function Test-BootstrapPurviewExactSet {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Actual, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected)
    $actualSorted = @($Actual | Sort-Object -Unique)
    $expectedSorted = @($Expected | Sort-Object -Unique)
    return $Actual.Count -eq $Expected.Count -and ($actualSorted -join '|') -ceq ($expectedSorted -join '|')
}

function Test-BootstrapPurviewMeaningfulValue {
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

function Get-BootstrapPurviewPropertyEntries {
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

function Assert-BootstrapPurviewNoNamedValues {
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Label
    )
    foreach ($name in $Names) {
        $value = Get-BootstrapPurviewProperty -InputObject $Resource -Names @($name) -Optional
        if (Test-BootstrapPurviewMeaningfulValue -Value $value) {
            throw "Purview $Label contains unreviewed '$name' configuration."
        }
    }
}

function Assert-BootstrapPurviewNoUnknownMeaningfulProperties {
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][string[]]$AllowedNames,
        [Parameter(Mandatory)][string]$Label
    )
    foreach ($entry in @(Get-BootstrapPurviewPropertyEntries -Resource $Resource)) {
        $recognized = @($AllowedNames | Where-Object {
            $_.Equals([string]$entry.Name, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if (-not $recognized -and (Test-BootstrapPurviewMeaningfulValue -Value $entry.Value)) {
            throw "Purview $Label returned unrecognized meaningful property '$($entry.Name)'."
        }
    }
}

function Get-BootstrapPurviewProviderMetadataPropertyNames {
    return @(
        'Name', 'DisplayName', 'Identity', 'Guid', 'ImmutableId', 'Comment',
        'Description', 'Priority', 'CreatedBy', 'LastModifiedBy', 'WhenCreated',
        'WhenCreatedUTC', 'WhenChanged', 'WhenChangedUTC', 'ExchangeVersion',
        'ObjectState', 'OrganizationId', 'DistinguishedName', 'IsValid',
        'ObjectCategory', 'ObjectClass', 'Status', 'Workload', 'Version',
        'RunspaceId', 'PSComputerName', 'PSShowComputerName',
        'PSSourceJobInstanceId', 'SerializationData'
    )
}

function Assert-BootstrapPurviewApplicationLocations {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$BlueprintApplicationId)
    $locations = @(ConvertFrom-BootstrapPurviewStructuredValue -Value $Value -Label 'Locations')
    if ($locations.Count -ne 1) { throw 'Purview policy must contain exactly one application location.' }
    $location = $locations[0]
    if ([string](Get-BootstrapPurviewProperty -InputObject $location -Names @('Workload')) -cne 'Applications' -or
        -not ([string](Get-BootstrapPurviewProperty -InputObject $location -Names @('Location'))).Equals($BlueprintApplicationId, [StringComparison]::OrdinalIgnoreCase) -or
        [string](Get-BootstrapPurviewProperty -InputObject $location -Names @('LocationSource')) -cne 'Entra' -or
        [string](Get-BootstrapPurviewProperty -InputObject $location -Names @('LocationType')) -cne 'Individual') {
        throw 'Purview policy application location does not exactly match the selected blueprint/Entra scope.'
    }
    $inclusions = @(ConvertFrom-BootstrapPurviewStructuredValue -Value (Get-BootstrapPurviewProperty -InputObject $location -Names @('Inclusions')) -Label 'location inclusions')
    if ($inclusions.Count -ne 1 -or
        [string](Get-BootstrapPurviewProperty -InputObject $inclusions[0] -Names @('Type')) -cne 'Tenant' -or
        [string](Get-BootstrapPurviewProperty -InputObject $inclusions[0] -Names @('Identity')) -cne 'All') {
        throw 'Purview policy location inclusions are not exactly tenant-wide for the selected application.'
    }
    $exclusions = Get-BootstrapPurviewProperty -InputObject $location -Names @('Exclusions') -Optional
    if ($null -ne $exclusions -and @(ConvertFrom-BootstrapPurviewStructuredValue -Value $exclusions -Label 'location exclusions').Count -gt 0) {
        throw 'Purview policy location contains unreviewed exclusions.'
    }
    Assert-BootstrapPurviewNoNamedValues -Resource $location -Names @(
        'ExcludedLocations', 'Exceptions', 'Bypass', 'BypassRules'
    ) -Label 'application location'
    Assert-BootstrapPurviewNoUnknownMeaningfulProperties -Resource $location -AllowedNames @(
        'Workload', 'Location', 'LocationDisplayName', 'LocationSource',
        'LocationType', 'Inclusions', 'Exclusions', 'ExcludedLocations',
        'Exceptions', 'Bypass', 'BypassRules'
    ) -Label 'application location'
    return $true
}

function Assert-BootstrapPurviewCollectionObject {
    param([Parameter(Mandatory)]$Collection, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$BlueprintApplicationId)
    $actualName = [string](Get-BootstrapPurviewProperty -InputObject $Collection -Names @('Name', 'Identity'))
    $mode = [string](Get-BootstrapPurviewProperty -InputObject $Collection -Names @('Mode'))
    if ($actualName -cne $Name -or $mode -cne 'Enable') { throw 'Purview collection policy name or mode does not exactly match the reviewed configuration.' }
    $scenario = ConvertFrom-BootstrapPurviewStructuredValue -Value (Get-BootstrapPurviewProperty -InputObject $Collection -Names @('ScenarioConfig')) -Label 'ScenarioConfig'
    $activities = @((Get-BootstrapPurviewProperty -InputObject $scenario -Names @('Activities')) | ForEach-Object { [string]$_ })
    $planes = @((Get-BootstrapPurviewProperty -InputObject $scenario -Names @('EnforcementPlanes')) | ForEach-Object { [string]$_ })
    $types = @((Get-BootstrapPurviewProperty -InputObject $scenario -Names @('SensitiveTypeIds')) | ForEach-Object { [string]$_ })
    $ingestion = Get-BootstrapPurviewProperty -InputObject $scenario -Names @('IsIngestionEnabled')
    if (-not (Test-BootstrapPurviewExactSet -Actual $activities -Expected @('UploadText', 'DownloadText')) -or
        -not (Test-BootstrapPurviewExactSet -Actual $planes -Expected @('Application')) -or
        -not (Test-BootstrapPurviewExactSet -Actual $types -Expected @('All')) -or $ingestion -ne $true) {
        throw 'Purview collection ScenarioConfig does not match the exact reviewed activity, plane, classifier, and ingestion settings.'
    }
    Assert-BootstrapPurviewNoUnknownMeaningfulProperties -Resource $scenario -AllowedNames @(
        'Activities', 'EnforcementPlanes', 'SensitiveTypeIds', 'IsIngestionEnabled'
    ) -Label 'collection ScenarioConfig'
    Assert-BootstrapPurviewApplicationLocations -Value (Get-BootstrapPurviewProperty -InputObject $Collection -Names @('Locations')) -BlueprintApplicationId $BlueprintApplicationId | Out-Null
    Assert-BootstrapPurviewNoNamedValues -Resource $Collection -Names @(
        'Exclusions', 'ExcludedLocations', 'Exceptions', 'Bypass', 'BypassRules'
    ) -Label 'collection policy'
    Assert-BootstrapPurviewNoUnknownMeaningfulProperties -Resource $Collection -AllowedNames @(
        (Get-BootstrapPurviewProviderMetadataPropertyNames)
        'Mode', 'FeatureScenario', 'Scenario', 'ScenarioConfig', 'Locations',
        'Exclusions', 'ExcludedLocations', 'Exceptions', 'Bypass', 'BypassRules'
    ) -Label 'collection policy'
    return $true
}

function Assert-BootstrapPurviewPolicyObject {
    param([Parameter(Mandatory)]$Policy, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$BlueprintApplicationId)
    if ([string](Get-BootstrapPurviewProperty -InputObject $Policy -Names @('Name', 'Identity')) -cne $Name -or
        [string](Get-BootstrapPurviewProperty -InputObject $Policy -Names @('Mode')) -cne 'Enable') {
        throw 'Purview DLP policy name or mode does not exactly match the reviewed configuration.'
    }
    $planes = @((Get-BootstrapPurviewProperty -InputObject $Policy -Names @('EnforcementPlanes')) | ForEach-Object { [string]$_ })
    if (-not (Test-BootstrapPurviewExactSet -Actual $planes -Expected @('Application'))) { throw 'Purview DLP policy enforcement plane is not exactly Application.' }
    Assert-BootstrapPurviewApplicationLocations -Value (Get-BootstrapPurviewProperty -InputObject $Policy -Names @('Locations')) -BlueprintApplicationId $BlueprintApplicationId | Out-Null
    $extraBehavior = @(
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
    Assert-BootstrapPurviewNoNamedValues -Resource $Policy -Names @(
        'Exclusions', 'ExcludedLocations', 'Exceptions', 'Bypass', 'BypassRules'
        $extraBehavior
    ) -Label 'DLP policy behavior'
    foreach ($property in @(Get-BootstrapPurviewPropertyEntries -Resource $Policy)) {
        if (($property.Name.StartsWith('ExceptIf', [StringComparison]::OrdinalIgnoreCase) -or
             $property.Name.Contains('Exception', [StringComparison]::OrdinalIgnoreCase) -or
             $property.Name.Contains('Bypass', [StringComparison]::OrdinalIgnoreCase)) -and
            (Test-BootstrapPurviewMeaningfulValue -Value $property.Value)) {
            throw "Purview DLP policy contains unreviewed exclusion or bypass '$($property.Name)'."
        }
    }
    Assert-BootstrapPurviewNoUnknownMeaningfulProperties -Resource $Policy -AllowedNames @(
        (Get-BootstrapPurviewProviderMetadataPropertyNames)
        'Mode', 'Locations', 'EnforcementPlanes', 'Exclusions',
        'ExcludedLocations', 'Exceptions', 'Bypass', 'BypassRules'
        $extraBehavior
    ) -Label 'DLP policy'
    return $true
}

function Get-BootstrapPurviewNamedLeafValues {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$PropertyName)
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        $trimmed = $Value.Trim()
        if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
            try { $Value = $trimmed | ConvertFrom-Json -Depth 50 -ErrorAction Stop }
            catch { throw 'Purview rule readback contained malformed structured condition data.' }
        }
        else { return }
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) {
            if ([string]$entry.Key -ieq $PropertyName -and $entry.Value -is [string]) { [string]$entry.Value }
            Get-BootstrapPurviewNamedLeafValues -Value $entry.Value -PropertyName $PropertyName
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { Get-BootstrapPurviewNamedLeafValues -Value $item -PropertyName $PropertyName }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -ieq $PropertyName -and $property.Value -is [string]) { [string]$property.Value }
        Get-BootstrapPurviewNamedLeafValues -Value $property.Value -PropertyName $PropertyName
    }
}

function Assert-BootstrapPurviewRuleObject {
    param([Parameter(Mandatory)]$Rule, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$PolicyName, [Parameter(Mandatory)][string]$SensitiveInformationType)
    if ([string](Get-BootstrapPurviewProperty -InputObject $Rule -Names @('Name', 'Identity')) -cne $Name -or
        [string](Get-BootstrapPurviewProperty -InputObject $Rule -Names @('ParentPolicyName', 'PolicyName', 'Policy')) -cne $PolicyName) {
        throw 'Purview DLP rule name or parent policy does not exactly match the reviewed configuration.'
    }
    $condition = @(ConvertFrom-BootstrapPurviewStructuredValue -Value (
        Get-BootstrapPurviewProperty -InputObject $Rule -Names @('ContentContainsSensitiveInformation')) -Label 'ContentContainsSensitiveInformation')
    if ($condition.Count -ne 1) {
        throw 'Purview DLP rule classifier does not exactly match the configured sensitive-information type.'
    }
    Assert-BootstrapPurviewNoUnknownMeaningfulProperties -Resource $condition[0] -AllowedNames @('Name') -Label 'DLP rule classifier'
    $classifierNames = @(Get-BootstrapPurviewNamedLeafValues -Value $condition -PropertyName 'Name')
    if (-not (Test-BootstrapPurviewExactSet -Actual $classifierNames -Expected @($SensitiveInformationType))) {
        throw 'Purview DLP rule classifier does not exactly match the configured sensitive-information type.'
    }
    $restrictAccess = @(ConvertFrom-BootstrapPurviewStructuredValue -Value (Get-BootstrapPurviewProperty -InputObject $Rule -Names @('RestrictAccess')) -Label 'RestrictAccess')
    if ($restrictAccess.Count -ne 1 -or
        [string](Get-BootstrapPurviewProperty -InputObject $restrictAccess[0] -Names @('setting', 'Setting')) -cne 'UploadText' -or
        [string](Get-BootstrapPurviewProperty -InputObject $restrictAccess[0] -Names @('value', 'Value')) -cne 'Block') {
        throw 'Purview DLP rule action is not exactly UploadText=Block.'
    }
    Assert-BootstrapPurviewNoUnknownMeaningfulProperties -Resource $restrictAccess[0] -AllowedNames @('setting', 'value') -Label 'DLP rule RestrictAccess action'

    $extraConditions = @(
        'AccessScope', 'ActivationDate', 'AdvancedRule',
        'AnyOfRecipientAddressContainsWords', 'AnyOfRecipientAddressMatchesPatterns',
        'AttachmentIsNotLabeled', 'ContentCharacterSetContainsWords',
        'ContentExtensionMatchesWords', 'ContentFileTypeMatches',
        'ContentIsNotLabeled', 'ContentIsShared', 'ContentPropertyContainsWords',
        'DocumentContainsWords', 'DocumentCreatedBy', 'DocumentCreatedByMemberOf',
        'DocumentIsPasswordProtected', 'DocumentIsUnsupported',
        'DocumentMatchesPatterns', 'DocumentNameMatchesPatterns',
        'DocumentNameMatchesWords', 'DocumentSizeOver', 'EvaluateRulePerComponent',
        'ExpiryDate', 'From', 'FromAddressContainsWords',
        'FromAddressMatchesPatterns', 'FromMemberOf', 'FromScope', 'HasActivity',
        'HasSenderOverride', 'HeaderContainsWords', 'HeaderMatchesPatterns',
        'MessageIsNotLabeled', 'MessageSizeOver', 'MessageTypeMatches',
        'NonBifurcatingAccessScope', 'ProcessingLimitExceeded',
        'RecipientADAttributeContainsWords', 'RecipientADAttributeMatchesPatterns',
        'RecipientDomainIs', 'SenderADAttributeContainsWords',
        'SenderADAttributeMatchesPatterns', 'SenderAddressLocation',
        'SenderDomainIs', 'SenderIPRanges', 'SentTo', 'SentToMemberOf',
        'SharedByIRMUserRisk', 'SubjectContainsWords', 'SubjectMatchesPatterns',
        'SubjectOrBodyContainsWords', 'SubjectOrBodyMatchesPatterns',
        'UnscannableDocumentExtensionIs', 'WithImportance'
    )
    $extraActions = @(
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
        'SetHeader', 'SharepointMoveToQuarantineLocation',
        'StopPolicyProcessing', 'TriggerPowerAutomateFlow'
    )
    Assert-BootstrapPurviewNoNamedValues -Resource $Rule -Names @($extraConditions + $extraActions) -Label 'DLP rule behavior'
    foreach ($property in @(Get-BootstrapPurviewPropertyEntries -Resource $Rule)) {
        if (($property.Name.StartsWith('ExceptIf', [StringComparison]::OrdinalIgnoreCase) -or
             $property.Name.Contains('Bypass', [StringComparison]::OrdinalIgnoreCase) -or
             $property.Name.Contains('Override', [StringComparison]::OrdinalIgnoreCase)) -and
            (Test-BootstrapPurviewMeaningfulValue -Value $property.Value)) {
            throw "Purview DLP rule contains unreviewed condition or action '$($property.Name)'."
        }
    }
    $disabled = Get-BootstrapPurviewProperty -InputObject $Rule -Names @('Disabled') -Optional
    if (Test-BootstrapPurviewMeaningfulValue -Value $disabled) { throw 'Purview DLP rule is disabled.' }
    Assert-BootstrapPurviewNoUnknownMeaningfulProperties -Resource $Rule -AllowedNames @(
        (Get-BootstrapPurviewProviderMetadataPropertyNames)
        'ParentPolicyName', 'PolicyName', 'Policy', 'PolicyId',
        'ContentContainsSensitiveInformation', 'RestrictAccess', 'Disabled'
        $extraConditions
        $extraActions
    ) -Label 'DLP rule'
    return $true
}

function Get-BootstrapPurviewPolicyEvidence {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Blueprint, [ValidateRange(1, 30)][int]$MaximumAttempts = 18)
    $lastFailure = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $collection = @(Get-FeatureConfiguration -FeatureScenario KnowYourData | Where-Object { $_.Name -eq [string]$Config.purview.collectionPolicyName -or $_.Identity -eq [string]$Config.purview.collectionPolicyName })
            $policy = @(Get-DlpCompliancePolicy -Identity ([string]$Config.purview.dlpPolicyName) -ErrorAction Stop)
            $rule = @(Get-DlpComplianceRule -Identity ([string]$Config.purview.dlpRuleName) -ErrorAction Stop)
            if ($collection.Count -ne 1 -or $policy.Count -ne 1 -or $rule.Count -ne 1) { throw 'Purview object count mismatch.' }
            $blueprintId = [string]$Blueprint.applicationId
            Assert-BootstrapPurviewCollectionObject -Collection $collection[0] -Name ([string]$Config.purview.collectionPolicyName) -BlueprintApplicationId $blueprintId | Out-Null
            Assert-BootstrapPurviewPolicyObject -Policy $policy[0] -Name ([string]$Config.purview.dlpPolicyName) -BlueprintApplicationId $blueprintId | Out-Null
            Assert-BootstrapPurviewRuleObject -Rule $rule[0] -Name ([string]$Config.purview.dlpRuleName) -PolicyName ([string]$Config.purview.dlpPolicyName) -SensitiveInformationType ([string]$Config.purview.sensitiveInformationType) | Out-Null
            return [ordered]@{
                configured = $true
                enabled = [bool]$Config.purview.activateGatewayAdapterAfterPolicyReadback
                collectionPolicyName = [string]$Config.purview.collectionPolicyName
                dlpPolicyName = [string]$Config.purview.dlpPolicyName
                dlpRuleName = [string]$Config.purview.dlpRuleName
                blueprintApplicationId = $blueprintId
                enforcementPlane = 'Application'
                exactTypedReadback = $true
                propagationStatus = 'PendingCanaryVerification'
            }
        }
        catch {
            $lastFailure = $_
            if ($attempt -lt $MaximumAttempts) { Start-Sleep -Seconds 10 }
        }
    }
    throw 'Purview objects were not observed with the exact reviewed typed configuration during the bounded readback window. Adapter activation remains disabled and the step is resumable.'
}

function Ensure-BootstrapPurviewPolicies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Blueprint,
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [switch]$NonInteractive
    )
    if ($Config.purview.enabled -ne $true) { return [ordered]@{ configured = $false; enabled = $false } }
    if ($NonInteractive) {
        throw 'Purview policy authoring requires an interactive Security & Compliance PowerShell session. Complete this step interactively, then Resume or Verify non-interactively.'
    }
    $connectionId = ''
    try {
        $connectionId = Connect-BootstrapPurview -UserPrincipalName $UserPrincipalName -TenantId ([string]$Config.tenantId)
        $blueprintApplicationId = [string]$Blueprint.applicationId
        Assert-GuidValue -Value $blueprintApplicationId -Label 'Purview blueprint application ID'
        $locations = @(@{
        Workload = 'Applications'; Location = $blueprintApplicationId; LocationDisplayName = [string]$Blueprint.displayName
        LocationSource = 'Entra'; LocationType = 'Individual'; Inclusions = @(@{ Type = 'Tenant'; Identity = 'All' })
        }) | ConvertTo-Json -Depth 10 -Compress
        $scenarioConfig = @{ Activities = @('UploadText', 'DownloadText'); EnforcementPlanes = @('Application'); SensitiveTypeIds = @('All'); IsIngestionEnabled = $true } | ConvertTo-Json -Compress

    $collectionName = [string]$Config.purview.collectionPolicyName
    $collection = @(Get-FeatureConfiguration -FeatureScenario KnowYourData | Where-Object { $_.Name -eq $collectionName -or $_.Identity -eq $collectionName })
    if ($collection.Count -gt 1) { throw "Multiple Purview collection policies match '$collectionName'." }
    if ($collection.Count -eq 0) {
        New-FeatureConfiguration -FeatureScenario KnowYourData -Name $collectionName -Mode Enable -ScenarioConfig $scenarioConfig -Locations $locations -Confirm:$false | Out-Null
    }
    else {
        Assert-BootstrapPurviewCollectionObject -Collection $collection[0] -Name $collectionName -BlueprintApplicationId $blueprintApplicationId | Out-Null
    }

    $policyName = [string]$Config.purview.dlpPolicyName
    # Enumerate with terminating error semantics, then filter locally. A failed
    # discovery must never be translated into "absent" and followed by a create.
    $policy = @(Get-DlpCompliancePolicy -ErrorAction Stop | Where-Object {
        [string]$_.Name -ceq $policyName -or [string]$_.Identity -ceq $policyName
    })
    if ($policy.Count -gt 1) { throw "Multiple DLP policies match '$policyName'." }
    if ($policy.Count -eq 0) {
        New-DlpCompliancePolicy -Name $policyName -Mode Enable -Locations $locations -EnforcementPlanes @('Application') -Confirm:$false | Out-Null
    }
    else {
        Assert-BootstrapPurviewPolicyObject -Policy $policy[0] -Name $policyName -BlueprintApplicationId $blueprintApplicationId | Out-Null
    }

    $ruleName = [string]$Config.purview.dlpRuleName
    $rule = @(Get-DlpComplianceRule -ErrorAction Stop | Where-Object {
        [string]$_.Name -ceq $ruleName -or [string]$_.Identity -ceq $ruleName
    })
    if ($rule.Count -gt 1) { throw "Multiple DLP rules match '$ruleName'." }
    if ($rule.Count -eq 0) {
        New-DlpComplianceRule -Name $ruleName -Policy $policyName `
            -ContentContainsSensitiveInformation @{ Name = [string]$Config.purview.sensitiveInformationType } `
            -RestrictAccess @(@{ setting = 'UploadText'; value = 'Block' }) -Confirm:$false | Out-Null
    }
    else {
        Assert-BootstrapPurviewRuleObject -Rule $rule[0] -Name $ruleName -PolicyName $policyName -SensitiveInformationType ([string]$Config.purview.sensitiveInformationType) | Out-Null
    }
        return Get-BootstrapPurviewPolicyEvidence -Config $Config -Blueprint $Blueprint
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($connectionId)) {
            Disconnect-BootstrapPurview -ConnectionId $connectionId
        }
    }
}

Export-ModuleMember -Function *
