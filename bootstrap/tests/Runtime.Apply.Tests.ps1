#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach($name in @('Common','Experience','Runtime','Lifecycle')) {Import-Module "$PSScriptRoot/../modules/$name.psm1" -Force -DisableNameChecking}
& (Get-Module Lifecycle) {
    function script:Save-BootstrapState {param($State,$Path) if(($State | ConvertTo-Json -Depth 30) -match 'SECRET_SENTINEL'){throw 'Secret persisted'}}
    function script:Write-GatewayExperienceEvent {param($Type,$Message,$Data,$OutputFormat)}
}
& (Get-Module Runtime) {
    function script:Get-BootstrapSourceFingerprint {'source'}
    function script:Get-BootstrapConfigurationFingerprint {param($Config) 'config'}
    function script:Assert-GatewayRuntimePrerequisites {param($Install,$RequireBicep)}
    function script:Assert-RuntimePurviewPrerequisites {param($Enabled)}
    function script:Connect-BootstrapAzure {param($Config,$NonInteractive) @{tenantId='tenant';userObjectId='owner';userPrincipalName='admin@example.com'}}
    function script:Ensure-GatewayApiApplication {param($Config,$AzureIdentity,$DeploymentOwnershipId) if($AzureIdentity.userObjectId -ne 'owner'){throw 'Authentication result lost'}; @{gatewayApiClientId='api';gatewayApiApplicationObjectId='api-object'}}
    function script:Ensure-RuntimeConsoleApplication {param($Config,$Identity,$DeploymentOwnershipId,$ConsoleHostPort) if($Identity.gatewayApiClientId -ne 'api'){throw 'API result lost'}; @{consoleClientId='console';consoleUrl='http://127.0.0.1:5081/';apiScope='scope'}}
    function script:Ensure-RuntimeGatewayApiOboSecret {param($Config,$Identity) @{gatewayApiApplicationObjectId='api-object';gatewayApiClientId='api';gatewayApiOboClientSecret='SECRET_SENTINEL'}}
    function script:Ensure-RuntimeWorkloadApplication {param($Config,$AzureIdentity,$DeploymentOwnershipId) @{workloadClientId='workload';workloadServicePrincipalId='principal';workloadClientSecret='SECRET_SENTINEL'}}
    function script:Ensure-RuntimeAgent365SeedBlueprint {param($Config,$DeploymentOwnershipId,$SourceFingerprint,$SponsorObjectId,$WorkloadServicePrincipalId,$ExistingEvidence) if($null -ne $ExistingEvidence){throw 'Fresh seed adopted evidence'}; @{applicationId='blueprint'}}
    function script:Ensure-RuntimeBlueprintClientSecret {param($Config,$Blueprint) @{blueprintObjectId='blueprint';blueprintApplicationId='blueprint';blueprintClientSecret='SECRET_SENTINEL'}}
    function script:Deploy-GatewayRuntimeContentSafety {param($Config,$DeploymentOwnershipId,$SourceFingerprint) @{enabled=$false}}
    function script:Build-GatewayRuntimeImages {param($Config) @{api='api';worker='worker';console='console'}}
    function script:Write-GatewayRuntimeEnv {param($Config,$Identity,$ConsoleIdentity,$WorkloadIdentity,$Images,$PromptShield,$GatewayApiOboClientSecret,$BlueprintClientSecret,$BlueprintApplicationId,$PurviewIdentity) if($GatewayApiOboClientSecret -ne 'SECRET_SENTINEL' -or $BlueprintClientSecret -ne 'SECRET_SENTINEL'){throw 'Credential transfer failed'}; 'env-file'}
    function script:Deploy-GatewayRuntime {param($Config,$EnvFile) @{apiHealthUrl='health';apiReadyUrl='ready';consoleConfigUrl='config';consoleProxyHealthUrl='proxy';consoleUrl='http://127.0.0.1:5081/'}}
    function script:Test-GatewayRuntimeHealth {param($HealthUrl,$ReadyUrl,$ConsoleConfigUrl,$ConsoleProxyHealthUrl) @{healthy=$true}}
    function script:Write-GatewayExperienceEvent {param($Type,$Message,$Data,$OutputFormat)}
    $state=@{deploymentOwnershipId='owner';steps=@{};acceptedPlan=@{planFingerprint='plan';configurationFingerprint='config';sourceFingerprint='source'}}
    $config=@{subscriptionId='subscription';tenantId='tenant';runtime=@{consoleHostPort=5081};promptShield=@{enabled=$false};purview=@{enabled=$false}}
    $result=Invoke-GatewayRuntimeApplyWorkflow -Configuration $config -State $state -StatePath 'unused' -Format Json -InstallLocalPrerequisites $false -NonInteractive $true -AcceptedPlanFingerprint plan
    if($state.steps.Count -ne 13 -or @($state.steps.Values | Where-Object status -NE Completed).Count -gt 0 -or -not $result.health.healthy){throw 'Shared apply workflow did not complete all steps.'}
}
'All thirteen shared Apply steps passed with isolated providers; credentials stayed out of persisted evidence.'
