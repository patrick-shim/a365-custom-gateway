#Requires -Version 7.0
<#
.SYNOPSIS
Provision or resume the dedicated runtime Purview management identity.
.DESCRIPTION
Run on the Windows catalog host under its service account. Requires an already
authenticated tenant administrator for the initial Entra consent and Purview
role-group setup. No policy definitions or scopes are changed by this procedure.
State contains only public identifiers and certificate metadata. A successful
result proves catalog access, not agent assignment or runtime enforcement.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$DeploymentOwnershipId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]{1,64}$')][string]$DeploymentName,
    [Parameter(Mandatory)][string]$AdministratorUpn,
    [string]$EvidenceDirectory = (Join-Path $PSScriptRoot '../.bootstrap/evidence/runtime'),
    [switch]$VerifyOnly,
    [switch]$StartCatalogHost
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($module in @('Common','Entra','RuntimePurview')) {
    Import-Module (Join-Path $PSScriptRoot "modules/$module.psm1") -Force -DisableNameChecking
}
$directory = [IO.Path]::GetFullPath($EvidenceDirectory)
[IO.Directory]::CreateDirectory($directory) | Out-Null
$path = Join-Path $directory 'purview-management-identity.json'
$lock = [IO.File]::Open("$path.lock", 'OpenOrCreate', 'ReadWrite', 'None')
function Save-Identity($value) {
    $temporary = "$path.tmp"
    [IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Depth 10))
    [IO.File]::Move($temporary, $path, $true)
}
try {
    if ($VerifyOnly) {
        $identity = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    } else {
        $account = Invoke-AzJson -Arguments @('account','show')
        if ($account.tenantId -ne $TenantId.ToString()) { throw 'Sign in to the deployment tenant before bootstrap.' }
        Set-BootstrapAzureSubscriptionContext -SubscriptionId $account.id -TenantId $TenantId.ToString()
        $owner = (Invoke-AzJson -Arguments @('rest','--method','GET','--url','https://graph.microsoft.com/v1.0/me?$select=id')).id
        $identity = Ensure-RuntimePurviewManagementIdentity -TenantId $TenantId `
            -DeploymentOwnershipId $DeploymentOwnershipId -DeploymentName $DeploymentName -OwnerObjectId $owner
        Save-Identity $identity
        Set-RuntimePurviewManagementRoleGroup -Identity $identity -AdministratorUpn $AdministratorUpn
        $identity.roleGroupVerified = $true
        Save-Identity $identity
    }
    if ($identity.tenantId -ne $TenantId.ToString() -or $identity.deploymentOwnershipId -ne $DeploymentOwnershipId.ToString()) {
        throw 'Saved Purview identity belongs to another tenant or deployment.'
    }
    $identity.accessVerified = $false
    Save-Identity $identity
    $verification = Test-RuntimePurviewManagementAccess -Identity $identity
    $identity.accessVerified = $true
    $identity.verifiedAtUtc = $verification.verifiedAtUtc
    $identity.policyCount = $verification.policyCount
    Save-Identity $identity
    [IO.File]::WriteAllText((Join-Path $directory 'purview-management-catalog.json'), ($verification.catalog | ConvertTo-Json -Depth 40))
    if ($StartCatalogHost) { Start-RuntimePurviewCatalogHost -Identity $identity | Out-Null }
    $identity | ConvertTo-Json -Depth 10
} finally { $lock.Dispose() }
