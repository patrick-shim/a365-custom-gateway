#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../modules/Common.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot/../modules/Entra.psm1" -Force -DisableNameChecking
& (Get-Module Entra) {
    $identity = @{ gatewayApiApplicationObjectId='app-object'; gatewayApiClientId='client'; gatewayApiServicePrincipalId='principal' }
    $script:application = @{
        appId='client'; api=@{}; passwordCredentials=@(); keyCredentials=@(); requiredResourceAccess=@()
        web=@{redirectUris=@();logoutUrl='';homePageUrl=''}; spa=@{redirectUris=@()}; publicClient=@{redirectUris=@()}
    }
    $script:grants=@()
    $script:writes=0
    $script:grantCreates=0
    $script:discardGrant=$false
    function script:Get-GraphPermissionCatalog {
        @{servicePrincipal=@{id='graph-principal';oauth2PermissionScopes=@(
            [pscustomobject]@{id='read-scope';value='AgentRegistration.Read.All';isEnabled=$true},
            [pscustomobject]@{id='write-scope';value='AgentRegistration.ReadWrite.All';isEnabled=$true}
        )}}
    }
    function script:Invoke-AzJson { param($Arguments) $script:application }
    function script:Get-BoundedGraphCollection { param($InitialUrl) $script:grants }
    function script:Invoke-GraphJsonBody {
        param($Method,$Url,$Body)
        $script:writes++
        if ($Url -like '*/applications/*') { $script:application.requiredResourceAccess=$Body.requiredResourceAccess }
        elseif ($Method -eq 'POST') {
            $script:grantCreates++
            if (-not $script:discardGrant) {
                $script:grants=@(@{id='grant';clientId=$Body.clientId;resourceId=$Body.resourceId;consentType=$Body.consentType;scope=$Body.scope})
            }
        } else { $script:grants[0].scope=$Body.scope }
    }
    function ExpectFailure([scriptblock]$Action,[string]$Message) {
        $failed=$false
        try { & $Action } catch { $failed=$true }
        if (-not $failed) { throw $Message }
    }
    ExpectFailure { Ensure-GatewayApiDelegatedRegistryConsent -Identity $identity -ReconcileOnly } 'Read-only reconciliation accepted missing consent.'
    if ($script:writes) { throw 'Read-only reconciliation mutated tenant.' }
    Ensure-GatewayApiDelegatedRegistryConsent -Identity $identity
    Assert-GatewayApiDelegatedPermissionBoundary -Identity $identity -RequireComplete | Out-Null
    Ensure-GatewayApiDelegatedRegistryConsent -Identity $identity
    if ($script:grantCreates -ne 1) { throw 'Repeated setup created duplicate consent.' }
    $script:grants[0].scope='AgentRegistration.Read.All'
    Ensure-GatewayApiDelegatedRegistryConsent -Identity $identity
    Assert-GatewayApiDelegatedPermissionBoundary -Identity $identity -RequireComplete | Out-Null
    $before=$script:writes
    $script:grants[0].scope += ' Mail.Read'
    ExpectFailure { Ensure-GatewayApiDelegatedRegistryConsent -Identity $identity } 'Unrelated delegated scope was overwritten.'
    if ($script:writes -ne $before) { throw 'Mutation occurred before consent boundary rejection.' }
    $script:grants=@()
    $script:discardGrant=$true
    ExpectFailure { Ensure-GatewayApiDelegatedRegistryConsent -Identity $identity } 'Missing grant readback was accepted.'
}
'Runtime Registry consent: fresh creation, exact readback, repeat, partial repair, unrelated-scope rejection and read-only checks passed.'
