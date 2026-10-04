#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach($name in 'Common','Entra','Runtime') {Import-Module "$PSScriptRoot/../modules/$name.psm1" -Force -DisableNameChecking}
& (Get-Module Common) {
    $script:BootstrapAzureTenantId='11111111-1111-4111-8111-111111111111'
    function script:Invoke-BootstrapCommand {
        param($FilePath,$ArgumentList)
        $withSubscription=$ArgumentList -contains '--subscription'
        $withTenant=$ArgumentList -contains '--tenant'
        if($withSubscription -eq $withTenant) {throw 'Token requests must choose exactly one Azure CLI account selector.'}
        if($withSubscription -ne [bool]$script:BootstrapAzureSubscriptionId) {throw 'Wrong account selector.'}
        @{tenant=$script:BootstrapAzureTenantId;subscription=$script:BootstrapAzureSubscriptionId;tokenType='Bearer';expires_on=[DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds();accessToken='synthetic-token'} | ConvertTo-Json -Compress
    }
    foreach($subscription in @('22222222-2222-4222-8222-222222222222','')) {
        $script:BootstrapAzureSubscriptionId=$subscription
        $script:BootstrapGraphAccessToken=''
        $null=Get-BootstrapGraphAccessToken
    }
}
& (Get-Module Runtime) {
    $script:owner='33333333-3333-4333-8333-333333333333'
    $script:resourceOwner=$script:owner
    $script:exists='true'
    function script:Invoke-AzTsv {param($Arguments) if(($Arguments -join ' ') -notmatch '^group exists ') {throw 'Ownership checking must not change tenant context.'}; $script:exists}
    function script:Invoke-AzJson {
        param($Arguments)
        if($Arguments[0] -eq 'group') {return @{tags=@{bootstrapOwnershipId=$script:resourceOwner}}}
        if($Arguments[0] -eq 'resource') {return @(@{name='cstestdev';tags=@{bootstrapOwnershipId=$script:resourceOwner}})}
        throw 'Unexpected ownership lookup.'
    }
    $config=@{resourceGroupName='rg-test-dev';projectName='test';environment='dev'}
    Assert-RuntimeContentSafetyOwnership -Config $config -DeploymentOwnershipId $script:owner
    $script:resourceOwner='unrelated'
    $rejected=$false
    try {Assert-RuntimeContentSafetyOwnership -Config $config -DeploymentOwnershipId $script:owner} catch {$rejected=$true}
    if(-not $rejected) {throw 'Unowned resource group was admitted.'}
    $script:exists='false'
    Assert-RuntimeContentSafetyOwnership -Config $config -DeploymentOwnershipId $script:owner
}
$credential=@{displayName='reviewed';keyId=[guid]::NewGuid().ToString();endDateTime=[DateTimeOffset]::UtcNow.AddDays(1).ToString('O')}
Assert-RuntimePasswordCredentials -Credentials @() -ExpectedName 'reviewed'
Assert-RuntimePasswordCredentials -Credentials @($credential) -ExpectedName 'reviewed'
foreach($invalid in @(@($credential,$credential),@(@{displayName='unreviewed';keyId=$credential.keyId;endDateTime=$credential.endDateTime}),@(@{displayName='reviewed';keyId=$credential.keyId;endDateTime=[DateTimeOffset]::UtcNow.AddDays(-1).ToString('O')}))) {
    $rejected=$false
    try {Assert-RuntimePasswordCredentials -Credentials $invalid -ExpectedName 'reviewed'} catch {$rejected=$true}
    if(-not $rejected) {throw 'Unexpected, duplicate or expired credentials were accepted.'}
}
'Tenant-only/subscription token selectors, Content Safety ownership and exact credential boundaries passed.'
