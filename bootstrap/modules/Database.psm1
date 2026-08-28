Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ManagedIdentityClientId {
    param([Parameter(Mandatory)][string]$PrincipalObjectId)
    $principal = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalObjectId?`$select=id,appId,displayName")
    Assert-GuidValue -Value ([string]$principal.appId) -Label "Managed identity $PrincipalObjectId client ID"
    return [ordered]@{ objectId = [string]$principal.id; clientId = [string]$principal.appId; displayName = [string]$principal.displayName }
}

function Initialize-GatewayDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$ApiPrincipalId,
        [Parameter(Mandatory)][string]$WorkerPrincipalId
    )
    $root = Get-RepositoryRoot
    $api = Get-ManagedIdentityClientId -PrincipalObjectId $ApiPrincipalId
    $worker = Get-ManagedIdentityClientId -PrincipalObjectId $WorkerPrincipalId
    $evidenceDirectory = Join-Path $root ".bootstrap/evidence/$($Config.resourceGroupName)/database"
    & (Join-Path $root 'tools/apply-migrations.ps1') `
        -SqlServerFqdn $SqlServerFqdn `
        -DatabaseName 'GatewayDb' `
        -ResourceGroup ([string]$Config.resourceGroupName) `
        -Phase Initialize `
        -Repeat 1 `
        -AllowLiveDatabase `
        -TemporarilyEnablePublicNetwork `
        -EvidenceDirectory $evidenceDirectory `
        -ApiPrincipalName "ca-gateway-api-$($Config.environment)" `
        -ApiPrincipalClientId ([guid]$api.clientId) `
        -WorkerPrincipalName "ca-gateway-worker-$($Config.environment)-v3" `
        -WorkerPrincipalClientId ([guid]$worker.clientId)
    if ($LASTEXITCODE -ne 0) { throw 'Gateway database initialization failed.' }
    return [ordered]@{
        server = $SqlServerFqdn
        database = 'GatewayDb'
        schema = 'CurrentEfModel'
        apiPrincipalClientId = [string]$api.clientId
        workerPrincipalClientId = [string]$worker.clientId
        publicNetworkRestoredToDisabled = $true
        evidenceDirectory = $evidenceDirectory
    }
}

Export-ModuleMember -Function *
