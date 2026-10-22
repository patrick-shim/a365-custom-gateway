param([Parameter(Mandatory)][guid]$TenantId,
      [Parameter(Mandatory)][guid]$ApplicationId,
      [Parameter(Mandatory)][string]$Organization,
      [Parameter(Mandatory)][string]$CertificateThumbprint,
      [Parameter(Mandatory)][ValidateSet('VerifyConnection','RefreshCatalog','ApplyAssignment')][string]$Operation,
      [string]$AssignmentRequestPath)
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
Import-Module ExchangeOnlineManagement -RequiredVersion 3.10.1
try {
    if (@(Get-ConnectionInformation).Count -ne 0) { throw 'Existing connection is not allowed.' }
    Connect-IPPSSession -AppId $ApplicationId -Organization $Organization -CertificateThumbprint $CertificateThumbprint `
        -ShowBanner:$false -CommandName Get-DlpCompliancePolicy,Get-DlpComplianceRule,Set-DlpCompliancePolicy | Out-Null
    $connections = @(Get-ConnectionInformation)
    if ($connections.Count -ne 1 -or $connections[0].TenantID -ne $TenantId -or
        -not $connections[0].IsEopSession -or $connections[0].State -ne 'Connected' -or $connections[0].TokenStatus -ne 'Active') {
        throw 'The exact connected tenant was not confirmed.'
    }
    . "$PSScriptRoot/Automation/Read-PurviewPolicyCatalog.ps1"
    $catalog = $null
    $assignment = $null
    if ($Operation -in @('VerifyConnection','RefreshCatalog')) {
        if ($AssignmentRequestPath) { throw 'Assignment request is not valid for a catalog read.' }
        $catalog = Read-PurviewPolicyCatalog -TenantId $TenantId
    }
    elseif ($Operation -eq 'ApplyAssignment') {
        if ([string]::IsNullOrWhiteSpace($AssignmentRequestPath)) { throw 'Assignment request is required.' }
        $request = Get-Content -LiteralPath $AssignmentRequestPath -Raw | ConvertFrom-Json
        if ([guid]$request.tenantId -ne $TenantId) { throw 'Wrong assignment tenant.' }
        $assignment = @{ assigned=$false; revision=$null; failureCode=$null }
        try {
            . "$PSScriptRoot/Automation/Add-PurviewIndividualTarget.ps1"
            # The assignment function re-reads the exact selected policy before
            # mutation. It intentionally does not enumerate the full inventory.
            Add-PurviewIndividualTarget -Request $request -Catalog $null
            $updated = Read-PurviewPolicyCatalog -TenantId $TenantId -PolicyId ([guid]$request.policyId)
            $policy = @($updated.items | Where-Object id -EQ $request.policyId)
            if ($policy.Count -ne 1 -or $policy[0].allAccountsApplicationIds -notcontains $request.agentIdentityId) {
                throw 'ASSIGNMENT_READBACK_PENDING'
            }
            $assignment.assigned = $true; $assignment.revision = $policy[0].revision
        } catch {
            $code = $_.Exception.Message
            $assignment.failureCode = if ($code -cmatch '^ASSIGNMENT_[A-Z_]+$') { $code } else { 'ASSIGNMENT_OUTCOME_UNCONFIRMED' }
        }
    }
    [Console]::Out.Write((@{catalog=$catalog; assignment=$assignment} | ConvertTo-Json -Depth 40 -Compress))
} catch {
    [Console]::Error.Write('PURVIEW_CATALOG_READ_FAILED')
    exit 1
} finally { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
