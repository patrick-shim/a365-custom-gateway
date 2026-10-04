#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../modules/Entra.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot/../modules/RuntimePurview.psm1" -Force -DisableNameChecking
$module = Get-Module RuntimePurview
& $module {
    $script:tenant = [guid]::NewGuid()
    function script:Invoke-AzTsv { return $script:tenant.ToString() }
    function script:Get-ServicePrincipalByAppId { throw 'Tenant check failed to stop provider discovery.' }
    try {
        Ensure-RuntimePurviewManagementIdentity -TenantId ([guid]::NewGuid()) -DeploymentOwnershipId ([guid]::NewGuid()) -DeploymentName test -OwnerObjectId ([guid]::NewGuid())
        throw 'Wrong tenant accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'signed-in tenant does not match|Windows catalog host') { throw }
    }
    # Simulate provider projections: role references and role objects use different
    # canonical paths in SCC. Only this exact built-in DLP role may be accepted.
    $script:identity = @{
        tenantId = $script:tenant.ToString()
        applicationId = [guid]::NewGuid().ToString(); servicePrincipalId = [guid]::NewGuid().ToString()
        deploymentOwnershipId = [guid]::NewGuid().ToString(); roleGroupName = 'test-role-group'; displayName = 'test'
    }
    $script:extraRole = $false
    $script:extraMember = $false
    $script:mutationCount = 0
    $script:disconnects = 0
    function script:Import-Module { }
    $script:connected = $false
    function script:Connect-IPPSSession { $script:connected = $true }
    function script:Get-ConnectionInformation { if ($script:connected) { [pscustomobject]@{ TenantID=$script:tenant; IsEopSession=$true; State='Connected'; TokenStatus='Active' } } }
    function script:Disconnect-ExchangeOnline { $script:disconnects++; $script:connected=$false }
    function script:Get-ServicePrincipal { return [pscustomobject]@{ AppId=$script:identity.applicationId; ObjectId=$script:identity.servicePrincipalId; Identity="org/Configuration/$($script:identity.servicePrincipalId)" } }
    function script:Get-ManagementRole { return [pscustomobject]@{ RoleType='DLPComplianceManagement'; IsRootRole=$true; Identity='org/Configuration/RBAC/Roles/DLP Compliance Management' } }
    function script:Get-RoleGroup {
        [pscustomobject]@{
            Name=$script:identity.roleGroupName; DisplayName=$script:identity.roleGroupName; Guid=[guid]::NewGuid()
            Description="Gateway existing-policy scope management; deployment $($script:identity.deploymentOwnershipId)"
            Roles=@('org/DLP Compliance Management'; if ($script:extraRole) { 'org/Organization Management' })
        }
    }
    function script:Get-RoleGroupMember {
        [pscustomobject]@{ Identity="org/Configuration/$($script:identity.servicePrincipalId)"; Guid=$script:identity.servicePrincipalId }
        if ($script:extraMember) { [pscustomobject]@{ Identity='org/Configuration/unrelated' } }
    }
    function script:New-ServicePrincipal { $script:mutationCount++; throw 'Unexpected mutation' }
    function script:New-RoleGroup { $script:mutationCount++; throw 'Unexpected mutation' }
    function script:Set-RoleGroup { $script:mutationCount++; throw 'Unexpected mutation' }
    function script:Add-RoleGroupMember { $script:mutationCount++; throw 'Unexpected mutation' }
    Set-RuntimePurviewManagementRoleGroup -Identity $script:identity -AdministratorUpn 'operator@example.com'
    $script:extraRole = $true
    try {
        Set-RuntimePurviewManagementRoleGroup -Identity $script:identity -AdministratorUpn 'operator@example.com'
        throw 'Unexpected role accepted'
    } catch { if ($_.Exception.Message -ne 'The dedicated Purview role group has unexpected ownership or roles.') { throw } }
    $script:extraRole = $false
    $script:extraMember = $true
    try {
        Set-RuntimePurviewManagementRoleGroup -Identity $script:identity -AdministratorUpn 'operator@example.com'
        throw 'Unexpected member accepted'
    } catch { if ($_.Exception.Message -ne 'The dedicated Purview role group has unexpected members.') { throw } }
    if ($script:mutationCount -ne 0 -or $script:disconnects -ne 3) { throw 'Reconciliation changed a provider object or leaked a connection.' }
}
'Runtime Purview tenant, exact role/member boundary and reconciliation checks passed (no network).'
