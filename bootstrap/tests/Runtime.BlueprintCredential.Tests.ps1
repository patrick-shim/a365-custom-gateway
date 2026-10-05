#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
foreach ($name in @('Common','Entra','Runtime','Agent365')) {
    Import-Module "$PSScriptRoot/../modules/$name.psm1" -Force -DisableNameChecking
}
& (Get-Module Agent365) {
    $owner = '00000000-0000-0000-0000-000000000001'
    function script:Get-Agent365BlueprintRelationshipIds { $owner }
    function script:Get-Agent365BoundedGraphCollection { @() }
    $config = @{
        runtime = @{credentialLabelPrefix='installation-specific'}
        agent365 = @{reviewedManagerApplicationIds=@($owner)}
    }
    $credential = @{displayName='installation-specific-blueprint'}
    $blueprint = @{
        id=$owner; appId=$owner; displayName='test'; signInAudience='AzureADMyOrg'
        managerApplications=@($owner); identifierUris=@(); tags=@(); appRoles=@()
        requiredResourceAccess=@(); keyCredentials=@(); passwordCredentials=@($credential)
        api=$null; web=$null; spa=$null; publicClient=$null; isFallbackPublicClient=$false
    }
    $arguments = @{
        Blueprint=$blueprint; Config=$config; ExpectedDisplayName='test'
        DeploymentOwnershipId=$owner; SourceFingerprint=('sha256:' + ('a' * 64))
        SponsorObjectId=$owner; GatewayWorkloadPrincipalId=$owner
    }
    Assert-Agent365SeedBlueprintSurface @arguments | Out-Null
    function ExpectCredentialRejection([scriptblock]$Action) {
        try { & $Action } catch {
            if ($_.Exception.Message -notmatch 'passwordCredentials authority surface') { throw }
            return
        }
        throw 'Unexpected blueprint credential was accepted.'
    }
    ExpectCredentialRejection { Assert-Agent365SeedBlueprintSurface @arguments -RequirePristineAuthoritySurface }
    $blueprint.passwordCredentials=@($credential,$credential)
    ExpectCredentialRejection { Assert-Agent365SeedBlueprintSurface @arguments }
    $blueprint.passwordCredentials=@(@{displayName='unrelated'})
    ExpectCredentialRejection { Assert-Agent365SeedBlueprintSurface @arguments }
    $config.runtime=@{}
    $blueprint.passwordCredentials=@(@{displayName='a365gw-bootstrap-runtime-blueprint'})
    Assert-Agent365SeedBlueprintSurface @arguments | Out-Null
}
'Blueprint credentials: configured/default labels accepted; unrelated, duplicate and pristine credentials rejected.'
