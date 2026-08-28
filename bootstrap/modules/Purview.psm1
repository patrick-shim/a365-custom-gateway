Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Connect-BootstrapPurview {
    param([Parameter(Mandatory)][string]$UserPrincipalName)
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Connect-IPPSSession -UserPrincipalName $UserPrincipalName -ShowBanner:$false
    foreach ($command in @('Get-FeatureConfiguration', 'New-FeatureConfiguration', 'Get-DlpCompliancePolicy', 'New-DlpCompliancePolicy', 'Get-DlpComplianceRule', 'New-DlpComplianceRule')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required Security & Compliance cmdlet '$command' is unavailable in this tenant/session." }
    }
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
    Connect-BootstrapPurview -UserPrincipalName $UserPrincipalName
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
        $serialized = $collection[0] | ConvertTo-Json -Depth 20 -Compress
        if ($serialized -notmatch [regex]::Escape($blueprintApplicationId) -or $serialized -notmatch 'Application') {
            throw "Existing collection policy '$collectionName' does not contain the expected blueprint/Application scope; refusing to overwrite it."
        }
    }

    $policyName = [string]$Config.purview.dlpPolicyName
    $policy = @(Get-DlpCompliancePolicy -Identity $policyName -ErrorAction SilentlyContinue)
    if ($policy.Count -gt 1) { throw "Multiple DLP policies match '$policyName'." }
    if ($policy.Count -eq 0) {
        New-DlpCompliancePolicy -Name $policyName -Mode Enable -Locations $locations -EnforcementPlanes @('Application') -Confirm:$false | Out-Null
    }
    else {
        $serialized = $policy[0] | ConvertTo-Json -Depth 20 -Compress
        if ($serialized -notmatch [regex]::Escape($blueprintApplicationId) -or $serialized -notmatch 'Application') {
            throw "Existing DLP policy '$policyName' does not contain the expected blueprint/Application scope; refusing to overwrite it."
        }
    }

    $ruleName = [string]$Config.purview.dlpRuleName
    $rule = @(Get-DlpComplianceRule -Identity $ruleName -ErrorAction SilentlyContinue)
    if ($rule.Count -gt 1) { throw "Multiple DLP rules match '$ruleName'." }
    if ($rule.Count -eq 0) {
        New-DlpComplianceRule -Name $ruleName -Policy $policyName `
            -ContentContainsSensitiveInformation @{ Name = [string]$Config.purview.sensitiveInformationType } `
            -RestrictAccess @(@{ setting = 'UploadText'; value = 'Block' }) -Confirm:$false | Out-Null
    }
    else {
        $serialized = $rule[0] | ConvertTo-Json -Depth 20 -Compress
        if ($serialized -notmatch [regex]::Escape([string]$Config.purview.sensitiveInformationType) -or $serialized -notmatch 'UploadText') {
            throw "Existing DLP rule '$ruleName' does not match the configured classifier/uploadText action; refusing to overwrite it."
        }
    }

    return [ordered]@{
        configured = $true
        enabled = [bool]$Config.purview.activateGatewayAdapterAfterPolicyReadback
        collectionPolicyName = $collectionName
        dlpPolicyName = $policyName
        dlpRuleName = $ruleName
        blueprintApplicationId = $blueprintApplicationId
        enforcementPlane = 'Application'
        propagationStatus = 'PendingCanaryVerification'
    }
}

Export-ModuleMember -Function *
