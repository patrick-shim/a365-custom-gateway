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
    $locations = @($before.Locations | ConvertFrom-Json -Depth 30)
    $rawRulesBefore = @(Get-DlpComplianceRule -Policy $policyId -ErrorAction Stop)
    $providerRevisionBefore = Get-PurviewLegacyPolicyRevision `
        -Policy $before -Locations $locations -Rules $rawRulesBefore
    if ($providerRevisionBefore -cne $Request.reviewedRevision) {
        throw 'ASSIGNMENT_REVIEW_STALE'
    }

    $existing = @($locations | Select-Object Workload,Location,LocationSource,LocationType,Exclusions,Inclusions |
        Where-Object { $_.Workload -eq 'Applications' -and $_.Location -eq $child.ToString() })
    if ($existing.Count -gt 0) {
        if ($existing.Count -ne 1 -or -not (Test-PurviewAllAccountsApplicationLocation $existing[0])) {
            throw 'ASSIGNMENT_EXISTING_SCOPE_CONFLICT'
        }
        return # Already exactly scoped; no provider write.
    }
    $ruleDefinitionsBefore = @(Get-PurviewCanonicalRuleDefinitions $rawRulesBefore)
    $rulesBefore = ConvertTo-PurviewCanonicalJson $ruleDefinitionsBefore
    $otherBefore = ConvertTo-PurviewCanonicalSetJson (Get-PurviewCanonicalLocationDefinitions $locations)
    $policyBefore = ConvertTo-PurviewCanonicalJson @{
        mode = [string](Get-PurviewPropertyValue $before 'Mode')
        enforcementPlanes = @(Get-PurviewSortedOrdinalUniqueStrings `
            (Get-PurviewPropertyValue $before 'EnforcementPlanes'))
    }
    # Delta syntax is essential. Supplying Inclusions here is not a confirmed scope addition.
    $delta = ConvertTo-Json -InputObject @(@{
        Workload='Applications'; Location=$child.ToString(); LocationSource='Entra'; LocationType='Individual'
        AddInclusions=@(@{Type='Tenant';Identity='All'})
    }) -Depth 15 -Compress
    Set-DlpCompliancePolicy -Identity $policyId -Locations $delta -Confirm:$false -ErrorAction Stop | Out-Null
    $after = Get-DlpCompliancePolicy -Identity $policyId -ErrorAction Stop
    $afterLocations = @($after.Locations | ConvertFrom-Json -Depth 40)
    $otherAfter = ConvertTo-PurviewCanonicalSetJson (Get-PurviewCanonicalLocationDefinitions @(
        $afterLocations | Where-Object { -not ($_.Workload -eq 'Applications' -and $_.Location -eq $child.ToString()) }
    ))
    $rulesAfter = ConvertTo-PurviewCanonicalJson @(Get-PurviewCanonicalRuleDefinitions @(
        Get-DlpComplianceRule -Policy $policyId -ErrorAction Stop
    ))
    $policyAfter = ConvertTo-PurviewCanonicalJson @{
        mode = [string](Get-PurviewPropertyValue $after 'Mode')
        enforcementPlanes = @(Get-PurviewSortedOrdinalUniqueStrings `
            (Get-PurviewPropertyValue $after 'EnforcementPlanes'))
    }
    $added = @($afterLocations | Where-Object {
        $_.Workload -eq 'Applications' -and $_.Location -eq $child.ToString()
    })
    if ($added.Count -ne 1 -or -not (Test-PurviewAllAccountsApplicationLocation $added[0])) {
        throw 'ASSIGNMENT_READBACK_PENDING'
    }
    if ($otherBefore -cne $otherAfter -or $rulesBefore -cne $rulesAfter -or $policyBefore -cne $policyAfter) {
        throw 'ASSIGNMENT_CONCURRENT_POLICY_CHANGE'
    }
}
