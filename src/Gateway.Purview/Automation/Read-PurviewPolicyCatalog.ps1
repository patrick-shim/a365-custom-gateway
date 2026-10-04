# Loaded only after the caller establishes and verifies an owned tenant session.
function ConvertTo-PurviewCanonicalNode {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        $keys = [string[]]@($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $result = [ordered]@{}
        foreach ($key in $keys) { $result[$key] = ConvertTo-PurviewCanonicalNode $Value[$key] }
        return ,$result
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @(foreach ($item in $Value) { ,(ConvertTo-PurviewCanonicalNode $item) })
        return ,$items
    }
    return $Value
}
function ConvertTo-PurviewCanonicalJson {
    param($Value)
    # SCC returns unordered nested hashtables. Their enumeration order varies by
    # process; hashing raw ConvertTo-Json output would invent a policy change.
    $plain = ConvertTo-Json -InputObject $Value -Depth 60 -Compress | ConvertFrom-Json -AsHashtable -Depth 60
    ConvertTo-Json -InputObject (ConvertTo-PurviewCanonicalNode $plain) -Depth 60 -Compress
}
function Read-PurviewPolicyCatalog {
    param([Parameter(Mandatory)][Guid]$TenantId, [Guid]$PolicyId = [Guid]::Empty)
    if ($TenantId -eq [Guid]::Empty) { throw 'Tenant binding is required.' }
    $policies = @(if ($PolicyId -eq [Guid]::Empty) { Get-DlpCompliancePolicy -ErrorAction Stop } else { Get-DlpCompliancePolicy -Identity $PolicyId -ErrorAction Stop })
    if ($policies.Count -gt 2048) { throw 'Policy catalog exceeds the supported bound; no partial catalog returned.' }
    $items = @($policies | ForEach-Object {
        $policy = $_ | Select-Object Guid,Name,Mode,Locations,EnforcementPlanes,WhenChangedUTC
        $id = [Guid]$policy.Guid
        if ($id -eq [Guid]::Empty) { throw 'Policy identity missing.' }
        $locations = @(if (-not [string]::IsNullOrWhiteSpace([string]$policy.Locations)) {
            $policy.Locations | ConvertFrom-Json -Depth 30 -ErrorAction Stop
        })
        # SCC omits optional location properties, including Exclusions. Project
        # the scope view explicitly so StrictMode callers behave identically to
        # the catalog host. Keep the original nodes in the revision definition.
        $scopeLocations = @($locations | Select-Object Workload,LocationSource,LocationType,Location,Exclusions,Inclusions)
        $planes = @($policy.EnforcementPlanes | ForEach-Object { [string]$_ })
        $rules = @()
        if ($planes -contains 'Application') { $rules = @(Get-DlpComplianceRule -Policy $id -ErrorAction Stop) }
        $blocks = @($rules | Select-Object Disabled,RestrictAccess | Where-Object {
            $_.Disabled -eq $false -and @($_.RestrictAccess | Select-Object setting,value | Where-Object {
                $_.setting -eq 'UploadText' -and $_.value -eq 'Block'
            }).Count -gt 0
        }).Count -gt 0
        # Version the provider's policy/rule definitions; no text is executed or modified.
        $policyDefinition = $policy | Select-Object Guid,Name,Mode,Locations,EnforcementPlanes,WhenChangedUTC
        $policyDefinition.Locations = $locations
        $ruleDefinitions = @($rules | Sort-Object Guid | Select-Object Guid,Name,Disabled,Priority,AdvancedRule,ContentContainsSensitiveInformation,RestrictAccess,WhenChangedUTC)
        foreach ($ruleDefinition in $ruleDefinitions) {
            if (-not [string]::IsNullOrWhiteSpace([string]$ruleDefinition.AdvancedRule)) {
                $ruleDefinition.AdvancedRule = $ruleDefinition.AdvancedRule | ConvertFrom-Json -AsHashtable -Depth 40
            }
        }
        $definition = ConvertTo-PurviewCanonicalJson @{ policy = $policyDefinition; rules = $ruleDefinitions }
        $revision = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($definition))).ToLowerInvariant()
        [ordered]@{
            id = $id.ToString('D'); displayName = [string]$policy.Name; mode = [string]$policy.Mode
            enforcementPlanes = $planes
            individualApplicationIds = @($scopeLocations | Where-Object {
                $_.Workload -eq 'Applications' -and $_.LocationSource -eq 'Entra' -and $_.LocationType -eq 'Individual'
            } | ForEach-Object { ([Guid]$_.Location).ToString('D') } | Sort-Object -Unique)
            allAccountsApplicationIds = @($scopeLocations | Where-Object {
                $_.Workload -eq "Applications" -and $_.LocationSource -eq "Entra" -and $_.LocationType -eq "Individual" -and
                @($_.Exclusions | Where-Object { $null -ne $_ }).Count -eq 0 -and @($_.Inclusions | Select-Object Type,Identity | Where-Object { $_.Type -eq "Tenant" -and $_.Identity -eq "All" }).Count -eq 1
            } | ForEach-Object { ([Guid]$_.Location).ToString("D") } | Sort-Object -Unique)
            hasUploadTextBlock = [bool]$blocks; revision = $revision
        }
    })
    @{ tenantId=$TenantId.ToString('D'); retrievedAtUtc=[DateTimeOffset]::UtcNow.ToString('O'); items=$items }
}
