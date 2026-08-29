[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$CertificatePath,
    [Parameter(Mandatory)][string]$AutomationApplicationId,
    [Parameter(Mandatory)][string]$Organization
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Convert-ToLocationArray {
    param([AllowNull()]$Value, [Parameter(Mandatory)][string]$ResourceName)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        try { return @($Value | ConvertFrom-Json -Depth 20) }
        catch { throw "Purview resource '$ResourceName' returned an unreadable Locations value." }
    }
    return @($Value)
}

function New-ApplicationLocation {
    param([Parameter(Mandatory)][string]$ApplicationId, [Parameter(Mandatory)][string]$DisplayName)
    return [ordered]@{
        Workload = 'Applications'
        Location = $ApplicationId
        LocationDisplayName = $DisplayName
        LocationSource = 'Entra'
        LocationType = 'Individual'
        Inclusions = @(@{ Type = 'Tenant'; Identity = 'All' })
    }
}

function Merge-ApplicationLocation {
    param([object[]]$Locations, [string]$ApplicationId, [string]$DisplayName)
    $result = [System.Collections.Generic.List[object]]::new()
    $found = $false
    foreach ($location in $Locations) {
        if ($null -eq $location) { continue }
        $locationId = [string]$location.Location
        if ($locationId -eq $ApplicationId) { $found = $true }
        $result.Add($location)
    }
    if (-not $found) { $result.Add((New-ApplicationLocation -ApplicationId $ApplicationId -DisplayName $DisplayName)) }
    return @($result)
}

function Assert-ApplicationScope {
    param([Parameter(Mandatory)]$Resource, [string]$ApplicationId, [string]$ResourceName)
    $serialized = $Resource | ConvertTo-Json -Depth 30 -Compress
    if ($serialized -notmatch [regex]::Escape($ApplicationId) -or $serialized -notmatch 'Application') {
        throw "Purview resource '$ResourceName' did not read back the exact blueprint Application scope."
    }
}

function Assert-RuleTemplate {
    param([Parameter(Mandatory)]$Rule, [string]$SensitiveInformationType)
    $serialized = $Rule | ConvertTo-Json -Depth 30 -Compress
    if ($serialized -notmatch [regex]::Escape($SensitiveInformationType) -or
        $serialized -notmatch 'UploadText' -or
        $serialized -notmatch 'Block') {
        throw 'The existing DLP rule does not match the reviewed Gateway protection template.'
    }
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
    Import-Module ExchangeOnlineManagement -MinimumVersion 3.10.1 -ErrorAction Stop
    Connect-IPPSSession -AppId $AutomationApplicationId -Certificate $certificate -Organization $Organization -ShowBanner:$false

    foreach ($command in @(
        'Get-FeatureConfiguration', 'New-FeatureConfiguration', 'Set-FeatureConfiguration',
        'Get-DlpCompliancePolicy', 'New-DlpCompliancePolicy', 'Set-DlpCompliancePolicy',
        'Get-DlpComplianceRule', 'New-DlpComplianceRule')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required Security & Compliance cmdlet '$command' is unavailable."
        }
    }

    $applicationId = [string]$input.blueprintApplicationId
    $displayName = [string]$input.blueprintDisplayName
    $dlpMode = if ([string]$input.mode -eq 'Enforce') { 'Enable' } else { 'TestWithoutNotifications' }
    $scenarioConfig = @{
        Activities = @('UploadText', 'DownloadText')
        EnforcementPlanes = @('Application')
        SensitiveTypeIds = @('All')
        IsIngestionEnabled = $true
    } | ConvertTo-Json -Compress

    $collection = @(Get-FeatureConfiguration -FeatureScenario KnowYourData -Identity ([string]$input.collectionPolicyName) -ErrorAction SilentlyContinue)
    if ($collection.Count -gt 1) { throw 'Multiple collection policies matched the requested profile.' }
    if ($collection.Count -eq 0) {
        $locationsJson = @((New-ApplicationLocation -ApplicationId $applicationId -DisplayName $displayName)) | ConvertTo-Json -Depth 10 -Compress
        New-FeatureConfiguration -FeatureScenario KnowYourData -Name ([string]$input.collectionPolicyName) -Mode Enable -ScenarioConfig $scenarioConfig -Locations $locationsJson -Confirm:$false | Out-Null
    }
    else {
        $locations = Convert-ToLocationArray -Value $collection[0].Locations -ResourceName ([string]$input.collectionPolicyName)
        $locationsJson = Merge-ApplicationLocation -Locations $locations -ApplicationId $applicationId -DisplayName $displayName | ConvertTo-Json -Depth 10 -Compress
        Set-FeatureConfiguration -Identity $collection[0].Identity -Locations $locationsJson -ScenarioConfig $scenarioConfig -Mode Enable -Confirm:$false | Out-Null
    }

    $policy = @(Get-DlpCompliancePolicy -Identity ([string]$input.dlpPolicyName) -ErrorAction SilentlyContinue)
    if ($policy.Count -gt 1) { throw 'Multiple DLP policies matched the requested profile.' }
    if ($policy.Count -eq 0) {
        $locationsJson = @((New-ApplicationLocation -ApplicationId $applicationId -DisplayName $displayName)) | ConvertTo-Json -Depth 10 -Compress
        New-DlpCompliancePolicy -Name ([string]$input.dlpPolicyName) -Mode $dlpMode -Locations $locationsJson -EnforcementPlanes @('Application') -Confirm:$false | Out-Null
    }
    else {
        $locations = Convert-ToLocationArray -Value $policy[0].Locations -ResourceName ([string]$input.dlpPolicyName)
        $locationsJson = Merge-ApplicationLocation -Locations $locations -ApplicationId $applicationId -DisplayName $displayName | ConvertTo-Json -Depth 10 -Compress
        Set-DlpCompliancePolicy -Identity $policy[0].Identity -Locations $locationsJson -Mode $dlpMode -Confirm:$false | Out-Null
    }

    $rule = @(Get-DlpComplianceRule -Identity ([string]$input.dlpRuleName) -ErrorAction SilentlyContinue)
    if ($rule.Count -gt 1) { throw 'Multiple DLP rules matched the requested profile.' }
    if ($rule.Count -eq 0) {
        New-DlpComplianceRule -Name ([string]$input.dlpRuleName) -Policy ([string]$input.dlpPolicyName) `
            -ContentContainsSensitiveInformation @{ Name = [string]$input.sensitiveInformationType } `
            -RestrictAccess @(@{ setting = 'UploadText'; value = 'Block' }) -Confirm:$false | Out-Null
    }
    else {
        Assert-RuleTemplate -Rule $rule[0] -SensitiveInformationType ([string]$input.sensitiveInformationType)
    }

    $collection = Get-FeatureConfiguration -FeatureScenario KnowYourData -Identity ([string]$input.collectionPolicyName)
    $policy = Get-DlpCompliancePolicy -Identity ([string]$input.dlpPolicyName)
    $rule = Get-DlpComplianceRule -Identity ([string]$input.dlpRuleName)
    Assert-ApplicationScope -Resource $collection -ApplicationId $applicationId -ResourceName ([string]$input.collectionPolicyName)
    Assert-ApplicationScope -Resource $policy -ApplicationId $applicationId -ResourceName ([string]$input.dlpPolicyName)
    Assert-RuleTemplate -Rule $rule -SensitiveInformationType ([string]$input.sensitiveInformationType)
    if ([string]$policy.Mode -ne $dlpMode) {
        throw "The DLP policy mode did not read back as '$dlpMode'."
    }

    $collectionLocations = Convert-ToLocationArray -Value $collection.Locations -ResourceName ([string]$input.collectionPolicyName)
    $blueprintIds = @($collectionLocations | ForEach-Object { [string]$_.Location } | Where-Object { $_ } | Sort-Object -Unique)
    $result = [ordered]@{
        collectionPolicyId = [string]$collection.Identity
        dlpPolicyId = [string]$policy.Identity
        dlpRuleId = [string]$rule.Identity
        blueprintApplicationIds = $blueprintIds
        verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    } | ConvertTo-Json -Depth 10 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($result))
    [Console]::Out.WriteLine("A365GW_RESULT:$encoded")
}
finally {
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
    $certificate.Dispose()
    $securePassword.Dispose()
}
