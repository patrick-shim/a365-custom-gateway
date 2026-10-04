#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../src/Gateway.Purview/Automation/Read-PurviewPolicyCatalog.ps1"
. "$PSScriptRoot/../../src/Gateway.Purview/Automation/Add-PurviewIndividualTarget.ps1"
if ((ConvertTo-PurviewCanonicalJson @{nested=[ordered]@{first=1;second=2}}) -cne
    (ConvertTo-PurviewCanonicalJson @{nested=[ordered]@{second=2;first=1}})) { throw 'Dictionary order changed the reviewed policy revision.' }
$tenant = [guid]::NewGuid(); $child = [guid]::NewGuid(); $blueprint = [guid]::NewGuid(); $policyId = [guid]::NewGuid()
$script:mutations = 0
$script:locations = @([pscustomobject]@{ Workload='Applications'; Location=[guid]::NewGuid().ToString(); LocationSource='Entra'; LocationType='Individual'; Inclusions=@(@{Type='Tenant';Identity='All'}) })
function Get-DlpCompliancePolicy {
    param($Identity)
    [pscustomobject]@{ Guid=$script:policyId; Name='Existing'; Mode='Enable'; Locations=(ConvertTo-Json -InputObject $script:locations -Depth 15 -Compress); EnforcementPlanes=@('Application'); WhenChangedUTC='2026-10-03T00:00:00Z' }
}
function Get-DlpComplianceRule {
    param($Policy)
    [pscustomobject]@{ Guid='e6b89118-7d27-40c2-951e-870101104be1'; Disabled=$false; RestrictAccess=@(@{setting='UploadText';value='Block'}) }
}
function Set-DlpCompliancePolicy {
    param($Identity,$Locations,$Confirm)
    if ([guid]$Identity -ne $policyId) { throw 'Wrong policy.' }
    $delta = @($Locations | ConvertFrom-Json)
    if ($delta.Count -ne 1 -or $delta[0].Location -ne $child.ToString() -or $delta[0].Inclusions -or
        $delta[0].AddInclusions[0].Type -ne 'Tenant' -or $delta[0].AddInclusions[0].Identity -ne 'All') { throw 'Unsafe scope replacement.' }
    $script:mutations++
    $script:locations += [pscustomobject]@{ Workload='Applications'; Location=$child.ToString(); LocationSource='Entra'; LocationType='Individual'; Inclusions=@(@{Type='Tenant';Identity='All'}) }
}
function New-Request {
    $catalog = Read-PurviewPolicyCatalog -TenantId $tenant
    @{ tenantId=$tenant; agentIdentityId=$child; blueprintId=$blueprint; policyId=$policyId; reviewedRevision=$catalog.items[0].revision; expiresAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(5) }
}
$request = New-Request
$strictCatalog = & {
    Set-StrictMode -Version Latest
    Read-PurviewPolicyCatalog -TenantId $tenant
}
if ($strictCatalog.items[0].allAccountsApplicationIds.Count -ne 1) {
    throw 'Bootstrap strict mode must accept provider locations with omitted optional exclusions.'
}
Add-PurviewIndividualTarget -Request $request -Catalog $null
if ($script:mutations -ne 1 -or $script:locations.Count -ne 2) { throw 'Delta did not preserve sibling scope.' }
$catalog = Read-PurviewPolicyCatalog -TenantId $tenant
if ($catalog.items[0].allAccountsApplicationIds -notcontains $child.ToString()) { throw 'Missing exclusions must not imply an exclusion.' }
$request = New-Request
& {
    Set-StrictMode -Version Latest
    Add-PurviewIndividualTarget -Request $request -Catalog $null
}
if ($script:mutations -ne 1) { throw 'Idempotent readback wrote again.' }
$script:locations[1] | Add-Member Exclusions @(@{Type='User';Identity=[guid]::NewGuid().ToString()})
$request = New-Request
try { Add-PurviewIndividualTarget -Request $request -Catalog $null; throw 'Exclusion was broadened.' }
catch { if ($_.Exception.Message -ne 'ASSIGNMENT_EXISTING_SCOPE_CONFLICT') { throw } }
$request.reviewedRevision = '0' * 64
try { Add-PurviewIndividualTarget -Request $request -Catalog $null; throw 'Stale policy accepted.' }
catch { if ($_.Exception.Message -ne 'ASSIGNMENT_REVIEW_STALE') { throw } }
if ($script:mutations -ne 1) { throw 'Rejected assignments changed the provider.' }
'Assignment delta, unrelated scope preservation, exact readback, exclusions, idempotency, and stale-review checks passed (no network).'
