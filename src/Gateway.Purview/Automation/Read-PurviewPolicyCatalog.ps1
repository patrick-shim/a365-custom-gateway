# Loaded only after the caller establishes and verifies an owned tenant session.
function Get-PurviewPropertyValue {
    param($Value, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        return $(if ($Value.Contains($Name)) { $Value[$Name] } else { $null })
    }

    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-PurviewCanonicalNode {
    param($Value)

    if ($Value -is [Collections.IDictionary]) {
        $keys = [string[]]@($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $result = [ordered]@{}
        foreach ($key in $keys) {
            $result[$key] = ConvertTo-PurviewCanonicalNode $Value[$key]
        }
        return ,$result
    }

    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        # Array order can be semantic inside a rule definition. Callers sort only
        # the provider collections whose contract treats them as sets.
        $items = @(foreach ($item in $Value) {
            ,(ConvertTo-PurviewCanonicalNode $item)
        })
        return ,$items
    }

    return $Value
}

function ConvertTo-PurviewCanonicalJson {
    param($Value)

    # This is the deployed public-revision canonicalizer. Preserve its array
    # behavior byte-for-byte so previously persisted revisions remain comparable.
    $plain = ConvertTo-Json -InputObject $Value -Depth 60 -Compress |
        ConvertFrom-Json -AsHashtable -Depth 60
    ConvertTo-Json -InputObject (ConvertTo-PurviewCanonicalNode $plain) -Depth 60 -Compress
}

function ConvertFrom-PurviewJsonValue {
    param($Value)

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    $trimmed = $Value.Trim()
    if (-not ($trimmed.StartsWith('{') -or $trimmed.StartsWith('['))) { return $Value }
    try {
        return ConvertFrom-Json -InputObject $trimmed -AsHashtable -Depth 60 -NoEnumerate -ErrorAction Stop
    }
    catch {
        # Some provider fields are ordinary strings that happen to start with a
        # bracket. Preserve those values rather than changing their semantics.
        return $Value
    }
}

function Get-PurviewCanonicalRuleDefinitions {
    param([object[]]$Rules)

    @($Rules | ForEach-Object {
        $rawGuid = [string](Get-PurviewPropertyValue $_ 'Guid')
        $normalizedGuid = $rawGuid
        $ruleId = [Guid]::Empty
        if ([Guid]::TryParse($rawGuid, [ref]$ruleId)) {
            $normalizedGuid = $ruleId.ToString('D')
        }
        [ordered]@{
            guid = $normalizedGuid
            name = [string](Get-PurviewPropertyValue $_ 'Name')
            disabled = Get-PurviewPropertyValue $_ 'Disabled'
            priority = Get-PurviewPropertyValue $_ 'Priority'
            advancedRule = ConvertFrom-PurviewJsonValue (Get-PurviewPropertyValue $_ 'AdvancedRule')
            contentContainsSensitiveInformation = ConvertFrom-PurviewJsonValue (Get-PurviewPropertyValue $_ 'ContentContainsSensitiveInformation')
            restrictAccess = ConvertFrom-PurviewJsonValue (Get-PurviewPropertyValue $_ 'RestrictAccess')
        }
    } | Sort-Object -Property @{ Expression = { $_.guid }; Ascending = $true })
}

function Get-PurviewCanonicalKnownSetValues {
    param($Values)

    $items = [Collections.Generic.List[object]]::new()
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        $canonicalJson = ConvertTo-PurviewCanonicalJson $value
        $items.Add([pscustomobject]@{
            Key = $canonicalJson
            Value = ConvertFrom-Json -InputObject $canonicalJson -AsHashtable -Depth 60 -NoEnumerate
        })
    }
    $items.Sort([Comparison[object]]{
        param($left, $right)
        [StringComparer]::Ordinal.Compare([string]$left.Key, [string]$right.Key)
    })
    foreach ($item in $items) {
        ,$item.Value
    }
}

function Get-PurviewCanonicalLocationDefinitions {
    param([object[]]$Locations)

    @($Locations | ForEach-Object {
        $rawLocation = [string](Get-PurviewPropertyValue $_ 'Location')
        $normalizedLocation = $rawLocation
        $locationId = [Guid]::Empty
        if ([Guid]::TryParse($rawLocation, [ref]$locationId)) {
            $normalizedLocation = $locationId.ToString('D')
        }
        [ordered]@{
            workload = [string](Get-PurviewPropertyValue $_ 'Workload')
            locationSource = [string](Get-PurviewPropertyValue $_ 'LocationSource')
            locationType = [string](Get-PurviewPropertyValue $_ 'LocationType')
            location = $normalizedLocation
            exclusions = @(Get-PurviewCanonicalKnownSetValues `
                (Get-PurviewPropertyValue $_ 'Exclusions'))
            inclusions = @(Get-PurviewCanonicalKnownSetValues `
                (Get-PurviewPropertyValue $_ 'Inclusions'))
        }
    })
}

function ConvertTo-PurviewCanonicalSetJson {
    param([object[]]$Values)

    $items = [Collections.Generic.List[string]]::new()
    foreach ($value in @($Values)) {
        $items.Add((ConvertTo-PurviewCanonicalJson $value))
    }
    $items.Sort([StringComparer]::Ordinal)
    ConvertTo-Json -InputObject ([string[]]$items.ToArray()) -Compress
}

function Get-PurviewSortedOrdinalUniqueStrings {
    param([object[]]$Values)

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in @($Values)) {
        [void]$seen.Add([string]$value)
    }
    $items = [string[]]@($seen)
    [Array]::Sort($items, [StringComparer]::Ordinal)
    $items
}

function Get-PurviewSha256 {
    param($Value)

    $canonical = ConvertTo-PurviewCanonicalJson $Value
    [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))
    ).ToLowerInvariant()
}

function Get-PurviewLegacyPolicyRevision {
    param(
        [Parameter(Mandatory)]$Policy,
        [object[]]$Locations,
        [object[]]$Rules
    )

    # Do not modernize this shape. It is the exact deployed public revision
    # contract, including provider timestamps and provider array ordering.
    $policyDefinition = $Policy |
        Select-Object Guid,Name,Mode,Locations,EnforcementPlanes,WhenChangedUTC
    $policyDefinition.Locations = @($Locations)
    $ruleDefinitions = @($Rules | Sort-Object Guid |
        Select-Object Guid,Name,Disabled,Priority,AdvancedRule,ContentContainsSensitiveInformation,RestrictAccess,WhenChangedUTC)
    foreach ($ruleDefinition in $ruleDefinitions) {
        if (-not [string]::IsNullOrWhiteSpace([string]$ruleDefinition.AdvancedRule)) {
            $ruleDefinition.AdvancedRule = $ruleDefinition.AdvancedRule |
                ConvertFrom-Json -AsHashtable -Depth 40
        }
    }
    Get-PurviewSha256 @{ policy = $policyDefinition; rules = $ruleDefinitions }
}

function Test-PurviewIndividualApplicationLocation {
    param($Location)

    (Get-PurviewPropertyValue $Location 'Workload') -eq 'Applications' -and
        (Get-PurviewPropertyValue $Location 'LocationSource') -eq 'Entra' -and
        (Get-PurviewPropertyValue $Location 'LocationType') -eq 'Individual'
}

function Test-PurviewAllAccountsApplicationLocation {
    param($Location)

    if (-not (Test-PurviewIndividualApplicationLocation $Location)) { return $false }
    $exclusions = @((Get-PurviewPropertyValue $Location 'Exclusions') | Where-Object { $null -ne $_ })
    $inclusions = @((Get-PurviewPropertyValue $Location 'Inclusions') | Where-Object { $null -ne $_ })
    $allTenant = @($inclusions | Where-Object {
        (Get-PurviewPropertyValue $_ 'Type') -eq 'Tenant' -and
            (Get-PurviewPropertyValue $_ 'Identity') -eq 'All'
    })
    $exclusions.Count -eq 0 -and $inclusions.Count -eq 1 -and $allTenant.Count -eq 1
}

function Read-PurviewPolicyCatalog {
    param([Parameter(Mandatory)][Guid]$TenantId, [Guid]$PolicyId = [Guid]::Empty)

    if ($TenantId -eq [Guid]::Empty) { throw 'Tenant binding is required.' }
    $policies = @(if ($PolicyId -eq [Guid]::Empty) {
        Get-DlpCompliancePolicy -ErrorAction Stop
    }
    else {
        Get-DlpCompliancePolicy -Identity $PolicyId -ErrorAction Stop
    })
    if ($policies.Count -gt 2048) {
        throw 'Policy catalog exceeds the supported bound; no partial catalog returned.'
    }

    $items = @($policies | ForEach-Object {
        $policy = $_
        $id = [Guid](Get-PurviewPropertyValue $policy 'Guid')
        if ($id -eq [Guid]::Empty) { throw 'Policy identity missing.' }

        $rawLocations = Get-PurviewPropertyValue $policy 'Locations'
        $locations = @(if (-not [string]::IsNullOrWhiteSpace([string]$rawLocations)) {
            if ($rawLocations -is [string]) {
                ConvertFrom-Json -InputObject $rawLocations -Depth 30 -ErrorAction Stop
            }
            else {
                $rawLocations
            }
        })
        $planes = @((Get-PurviewPropertyValue $policy 'EnforcementPlanes') |
            ForEach-Object { [string]$_ })
        $rules = @()
        if ($planes -contains 'Application') {
            $rules = @(Get-DlpComplianceRule -Policy $id -ErrorAction Stop)
        }

        $blocks = @($rules | Where-Object {
            $restrictAccess = ConvertFrom-PurviewJsonValue (Get-PurviewPropertyValue $_ 'RestrictAccess')
            (Get-PurviewPropertyValue $_ 'Disabled') -eq $false -and
                @($restrictAccess | Where-Object {
                    (Get-PurviewPropertyValue $_ 'setting') -eq 'UploadText' -and
                        (Get-PurviewPropertyValue $_ 'value') -eq 'Block'
                }).Count -gt 0
        }).Count -gt 0

        $ruleDefinitions = @(Get-PurviewCanonicalRuleDefinitions $rules)
        $definitionPlanes = @(Get-PurviewSortedOrdinalUniqueStrings $planes)
        $policyCore = [ordered]@{
            guid = $id.ToString('D')
            name = [string](Get-PurviewPropertyValue $policy 'Name')
            mode = [string](Get-PurviewPropertyValue $policy 'Mode')
            enforcementPlanes = $definitionPlanes
        }

        # `revision` is the deployed whole-scope review contract. It intentionally
        # retains provider timestamps and legacy array ordering.
        $revision = Get-PurviewLegacyPolicyRevision -Policy $policy -Locations $locations -Rules $rules

        # `definitionRevision` is the durable enforcement identity. Target scope
        # and display names are management evidence, not enforcement semantics.
        # Each assigned identity's exact all-accounts target is verified separately.
        $definitionRevision = Get-PurviewSha256 ([ordered]@{
            policy = [ordered]@{
                guid = $policyCore.guid
                mode = $policyCore.mode
                enforcementPlanes = $policyCore.enforcementPlanes
            }
            rules = $ruleDefinitions
        })

        $individualIds = @($locations | Where-Object {
            Test-PurviewIndividualApplicationLocation $_
        } | ForEach-Object {
            ([Guid](Get-PurviewPropertyValue $_ 'Location')).ToString('D')
        } | Sort-Object)
        $allAccountsIds = @($locations | Where-Object {
            Test-PurviewAllAccountsApplicationLocation $_
        } | ForEach-Object {
            ([Guid](Get-PurviewPropertyValue $_ 'Location')).ToString('D')
        } | Sort-Object)

        [ordered]@{
            id = $id.ToString('D')
            displayName = $policyCore.name
            mode = $policyCore.mode
            enforcementPlanes = $planes
            individualApplicationIds = $individualIds
            allAccountsApplicationIds = $allAccountsIds
            hasUploadTextBlock = [bool]$blocks
            revision = $revision
            definitionRevision = $definitionRevision
        }
    })

    @{
        tenantId = $TenantId.ToString('D')
        retrievedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        items = $items
    }
}
