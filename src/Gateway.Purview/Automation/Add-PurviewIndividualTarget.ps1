# Only called inside the verified certificate session, for an authenticated bounded request.
function Add-PurviewIndividualTarget {
    param($Request, $Catalog)
    $policyId = [Guid]$Request.policyId
    $child = [Guid]$Request.agentIdentityId
    if ($child -eq [Guid]::Empty -or $child -eq [Guid]$Request.blueprintId -or
        [DateTimeOffset]$Request.expiresAtUtc -le [DateTimeOffset]::UtcNow) { throw 'ASSIGNMENT_REQUEST_INVALID' }
    $Catalog = Read-PurviewPolicyCatalog -TenantId ([guid]$Request.tenantId) -PolicyId $policyId
    $item = @($Catalog.items | Where-Object id -EQ $policyId.ToString())
    if ($item.Count -ne 1 -or $item[0].mode -ne 'Enable' -or -not $item[0].hasUploadTextBlock -or
        $item[0].enforcementPlanes -notcontains 'Application' -or $item[0].revision -cne $Request.reviewedRevision) {
        throw 'ASSIGNMENT_REVIEW_STALE'
    }
    # Read the exact policy again immediately before mutation, never trust the inventory alone.
    $before = Get-DlpCompliancePolicy -Identity $policyId -ErrorAction Stop
    $locations = @($before.Locations | ConvertFrom-Json -Depth 40)
    $existing = @($locations | Select-Object Workload,Location,LocationSource,LocationType,Exclusions,Inclusions |
        Where-Object { $_.Workload -eq 'Applications' -and $_.Location -eq $child.ToString() })
    if ($existing.Count -gt 0) {
        if ($existing.Count -ne 1 -or $existing[0].LocationSource -ne 'Entra' -or $existing[0].LocationType -ne 'Individual' -or
            @($existing[0].Exclusions | Where-Object { $null -ne $_ }).Count -ne 0 -or
            @($existing[0].Inclusions | Select-Object Type,Identity | Where-Object { $_.Type -eq 'Tenant' -and $_.Identity -eq 'All' }).Count -ne 1) {
            throw 'ASSIGNMENT_EXISTING_SCOPE_CONFLICT'
        }
        return # Already exactly scoped; no provider write.
    }
    $rulesBefore = ConvertTo-PurviewCanonicalJson @(Get-DlpComplianceRule -Policy $policyId -ErrorAction Stop | Sort-Object Guid |
        Select-Object Guid,Name,Disabled,Priority,AdvancedRule,ContentContainsSensitiveInformation,RestrictAccess,WhenChangedUTC)
    $otherBefore = ConvertTo-PurviewCanonicalJson $locations
    # Delta syntax is essential. Supplying Inclusions here is not a confirmed scope addition.
    $delta = ConvertTo-Json -InputObject @(@{
        Workload='Applications'; Location=$child.ToString(); LocationSource='Entra'; LocationType='Individual'
        AddInclusions=@(@{Type='Tenant';Identity='All'})
    }) -Depth 15 -Compress
    Set-DlpCompliancePolicy -Identity $policyId -Locations $delta -Confirm:$false -ErrorAction Stop | Out-Null
    $after = Get-DlpCompliancePolicy -Identity $policyId -ErrorAction Stop
    $afterLocations = @($after.Locations | ConvertFrom-Json -Depth 40)
    $otherAfter = ConvertTo-PurviewCanonicalJson @($afterLocations | Where-Object { -not ($_.Workload -eq 'Applications' -and $_.Location -eq $child.ToString()) })
    $rulesAfter = ConvertTo-PurviewCanonicalJson @(Get-DlpComplianceRule -Policy $policyId -ErrorAction Stop | Sort-Object Guid |
        Select-Object Guid,Name,Disabled,Priority,AdvancedRule,ContentContainsSensitiveInformation,RestrictAccess,WhenChangedUTC)
    if ($otherBefore -cne $otherAfter -or $rulesBefore -cne $rulesAfter -or $before.Mode -ne $after.Mode -or
        (@($before.EnforcementPlanes) -join ',') -cne (@($after.EnforcementPlanes) -join ',')) {
        throw 'ASSIGNMENT_CONCURRENT_POLICY_CHANGE'
    }
}
