param([ValidateSet('GuidScripts','ExecutorChildIsolation','ExecutorStartupDiagnostics','ConsoleFreePowerShell','ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode', IgnoreCase = $false)][string]$Generation = 'GuidScripts')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $PSScriptRoot
$script:Baseline = Join-Path $script:Root '.test-work\fresh-full-0911g'
$script:Work = Join-Path $script:Root '.test-work\gw0911g-artifact-hotfix'
$script:Subscription = '6f6ae863-dcb7-456f-a7f0-d6f9887cfb76'
$script:Tenant = 'ff8b1e46-ff0f-4bc2-ab02-caf2b92da496'
$script:Scope = "/subscriptions/$script:Subscription/resourceGroups/rg-gw0911g-dev"
$script:Source = 'sha256:de369d5427906dc782dd5425354b1ca0e427012a279f3360cac6a2ed46a7565c'
$script:StateHash = '716269a7e668e85b67f8504b8fa1b8d3a6316676f3d8912cef8f7dc653c6a1ac'
$script:Operator = '2db7287c-9462-404f-810e-17e57377618d'
$script:Intent = 'dba09017-37b4-4c0d-bbc2-f98b07821011'
$script:AutomationScripts = [ordered]@{
    'src/Gateway.Purview/Automation/Connect-PurviewTenant.ps1' = 'e985e96da95566fe5890bdc7801a8d46440d0cbc2adff24acc46af54decf016c'
    'src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1' = '9327748027f9633f1a37e6eccb490ef0696d2a9282d90e46a0b070f606efeee8'
    'src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1' = 'cc11e012e9a7afa2ccc65a4f500254c524d4cf7bc1c58e0b805d3fc3cfb525d7'
}
$script:Delta = $script:AutomationScripts
$script:SeedRoot = $script:Baseline
$script:SeedSource = $script:Source
$script:PreviousWork = $script:Work
$script:ExecutorOnly = $Generation -cne 'GuidScripts'
$script:PreviousPlanFingerprint = 'sha256:f976bf0081f08c0ae4876198c716f797c28aeb0144ccb4d9c566958b13fec304'
$script:PreviousReceiptHash = '7f8a1d3c896e1299809af0499b86e67a3f025705afe6f98bbd853ac4dcb76862'
if ($Generation -ceq 'ExecutorStartupDiagnostics') {
    $script:Work = Join-Path $script:PreviousWork 'executor-startup-diagnostics'
    $script:PreviousWork = Join-Path $script:PreviousWork 'executor-child-isolation'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:ab6500da3340bdb96cd29587a96da03b092cdf2c9a82be8caeb8a80239488abe'
    $script:PreviousPlanFingerprint = 'sha256:bd6411dde197569fc5604281a03cceb421975fd3a58ba567f526dd1658ab608b'
    $script:PreviousReceiptHash = '0fe416926075661e10e69ea802eec79a93bee2fd77fab229f7bfaacf8644408e'
    $script:Intent = 'ec78a114-65fc-42ed-a94e-e37b565d3edf'
    $script:Delta = [ordered]@{
        'src/A365Gateway.slnx' = '675bd653b85526469b9576a49b1090008a2a718530b89b2fe5448e7622f675dc'
        'src/Gateway.Purview.Executor.StartupDiagnostics/Gateway.Purview.Executor.StartupDiagnostics.csproj' = 'ea617a6bea4d9dfd3cebef9a49ed71b98a91f320a6b3c130b9ec3997e510acbd'
        'src/Gateway.Purview.Executor.StartupDiagnostics/StartupHook.cs' = '563d5010dfe88620cb3b50067593dee09d8634638a8c86d43dbb25297692e10a'
        'src/Gateway.Purview.Executor/ExecutorRuntimeAttestation.cs' = 'c3636bd484480bd6148c8ff03c2c9eb2ca94c93021e4aeac4d7c6ea3a843a0a0'
        'src/Gateway.Purview.Executor/ExecutorStartupDiagnostics.cs' = '07425914af2a042c62cb80fb45a4982f877112105da17cd31458de4d6cd60801'
        'src/Gateway.Purview.Executor/Gateway.Purview.Executor.csproj' = '069da9e80bf63f7f770d8df083119339acc1b0c6f97cf7642e4ed3c04642c7d5'
    }
}
if ($Generation -ceq 'ExecutorChildIsolation') {
    $script:Work = Join-Path $script:PreviousWork 'executor-child-isolation'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:fdadada5df92fb16a5608130d818fa6d7954b979d78658221168a1f5fd428cee'
    $script:Intent = '9473f8c4-7dbb-4e48-958e-eff91fa9112f'
    $script:Delta = [ordered]@{
        'src/Gateway.Purview/PurviewPowerShellProcess.cs' = 'd7ddf9a78dcac0036c3cc7ccde7299a8a46a75590b295548a2c3589f6bae86c4'
        'src/Gateway.Purview.Executor/ExecutorRuntimeAttestation.cs' = '9f92b155dd4ec50d96a7bb4e36ccf7ffb2a76cd0a558c992d6498ceba9c92d02'
        'src/Gateway.Provisioning.Worker/PowerShellPurviewConnectionVerificationProvider.cs' = '10e5f917ab985881c43ae18025e4d59b83019f68f4601c9c3eed2721de29134f'
        'src/Gateway.Purview/PowerShellPurviewSettingsAutomation.cs' = '2dbbf97c98abc653d4606546073309a599ea442284da365543f834111b6ad70f'
        'src/Gateway.Purview/PowerShellPurviewPolicyProvisioningClient.cs' = '3e9d880e6c4bb44b6ab93d875ee791df0a3515741638c76cb27c5431cd267246'
    }
}
if ($Generation -ceq 'ConsoleFreePowerShell') {
    $script:Work = Join-Path $script:PreviousWork 'console-free-powershell'
    $script:PreviousWork = Join-Path $script:PreviousWork 'executor-startup-diagnostics'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:09dc1c81aae2696bcf3ccd952916be31cd63179afb6ec49d8f27bd62b9f3a720'
    $script:PreviousPlanFingerprint = 'sha256:caff23cd256dd8143888d5210fb3087025896ab5d6fbfc36eae4517b210bb1d1'
    $script:PreviousReceiptHash = '481673acf0d2bfaa67bb3f4317844de6049306d151fde370124ff53370da38f4'
    $script:Intent = 'bd283da1-8e25-4f1c-bdaf-58337efc696a'
    $script:Delta = [ordered]@{
        'bootstrap/modules/PurviewPackage.psm1' = 'c7a5579f0a292558a974f73b1995022c3e2f2f85b519825bc0545ac1a648f4e0'
        'operations/build-purview-executor-package.ps1' = '543958391ad8b1965de4e95a70c6e950c680d12f0012c1231322885b8172b47a'
        'src/A365Gateway.slnx' = '6cc74d75688b97dda343124d81a61a316af9dd47171f8f9344767ac0ae430530'
        'src/Gateway.Provisioning.Worker/PowerShellPurviewConnectionVerificationProvider.cs' = 'a1455927472b696d347a2243d5636f9966f5fe3bc434522ba7b9af8595a46741'
        'src/Gateway.Purview.Executor/ExecutorRuntimeAttestation.cs' = '5e306fa85fc710fddd543438a99a050c9112eca47c5ce97fe4fdf596cfdd99b4'
        'src/Gateway.Purview.Executor/ExecutorStartupDiagnostics.cs' = 'dba0191973b42e5d74b60bbee34e28c5e571831cabfabe5dc5b4f664b558df11'
        'src/Gateway.Purview.Executor/Gateway.Purview.Executor.csproj' = '8231eae4d4dae74ceaa15ca235f8127a8e06225e7e49c95b489e6c8399cf992f'
        'src/Gateway.Purview.Executor/Program.cs' = 'd9f82636b5ea9dc844d8890bce6f6c6c479526a2e9ce1790af2b6f2024a1894b'
        'src/Gateway.Purview.PowerShellHost/Gateway.Purview.PowerShellHost.csproj' = 'd78c9dad8af85e5250096c47f2950361d7f10aeb5975ba820c8f3d34149bcd07'
        'src/Gateway.Purview.PowerShellHost/Program.cs' = '52faad49c930e7c30d9fdef08fe6eae113d934ac90e0cd462a5d1721d8e584c4'
        'src/Gateway.Purview.PowerShellHost/RunspaceEngine.cs' = 'fb8210bdf5223a9c0ea494ca1125f553eefa177b398e8dc9bf2eb67f56cfeac4'
        'src/Gateway.Purview/PowerShellPurviewPolicyProvisioningClient.cs' = '1897f012f976380eadbc3bcdd75656ac199f3a424d3a940a857d2ff2cda9b295'
        'src/Gateway.Purview/PowerShellPurviewSettingsAutomation.cs' = '33e1e3cb1fc898e8491eea1a940e4e53ad77fde339e5ad43aaf17a6bf9830c49'
        'src/Gateway.Purview/PurviewChildInvocation.cs' = 'b9136fa8e0338d4090fa55bbf1cb88f7a3cab2ecb49fcaa4500ee65bb149786f'
        'src/Gateway.Purview/PurviewOptions.cs' = '0d060d6ef85d18a8c4f53726428ee4b06a2965426a8a2297225e9744a671bf3e'
        'src/Gateway.Purview/PurviewPowerShellProcess.cs' = '56fbc0ddbb048c72522bc0124652039b03e65ba69e80e9a0f44a5c247d51b98f'
        'src/Gateway.Purview/PurviewRuntimeManifest.cs' = 'bae2fa06f5ceba9d1ed0f7f0519ce08e25c28d9aa1a32f02f6f206d3bb94d99d'
    }
}
if ($Generation -ceq 'ConnectionDiagnostics') {
    $script:Work = Join-Path $script:PreviousWork 'connection-diagnostics'
    $script:PreviousWork = Join-Path $script:PreviousWork 'console-free-powershell'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:a9bb4e4bdea2a20c6088acd86a709eda2280e9119b238b6eaa1d67cf72f2d26e'
    $script:PreviousPlanFingerprint = 'sha256:25d772737d6b4794a60e052885e2fabd1289c6ebc2acb3b11328a3ea6c69ce4e'
    $script:PreviousReceiptHash = 'ca33292d7ba4475277297530839e03461b7aa4a63d2cb562d80d17dcd4d84314'
    $script:Intent = '63be08c5-40d3-43b3-b678-7ef5325b8351'
    $script:Delta = [ordered]@{
        'bootstrap/modules/PurviewPackage.psm1' = 'c7a5579f0a292558a974f73b1995022c3e2f2f85b519825bc0545ac1a648f4e0'
        'operations/build-purview-executor-package.ps1' = 'b1d9702a4e5af8781839142e230859d1a417ebbe96c902aac7be32c8a646ba26'
        'src/Gateway.Provisioning.Worker/PowerShellPurviewConnectionVerificationProvider.cs' = '4d808562b4395b4cd3d0bfc3d5392d38e58d28bf7764028f27c145bbdb85ad2e'
        'src/Gateway.Provisioning.Worker/PurviewConnectionVerificationDiagnostics.cs' = '35f86dc728de07c8eb316d38c57e1bda69d7ca22a2dfa0f9d427f01066782bb9'
        'src/Gateway.Purview.Executor/Program.cs' = 'ab99e491500f047ee5d64d7c7c0c3382f2d93dc6d02b24282fc286dba27b1ede'
    }
}
if ($Generation -ceq 'ProviderStageDiagnostics') {
    $script:Work = Join-Path $script:PreviousWork 'provider-stage-diagnostics'
    $script:PreviousWork = Join-Path $script:PreviousWork 'connection-diagnostics'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:6c0f130e741aa6f533d5250ec19b12061d98ebaa5d7b2b3e5c8b656aee4ab292'
    $script:PreviousPlanFingerprint = 'sha256:f858b78f3b08554b841a6808f8a26ae5b8ec6a3733e613e18b3b764d56670436'
    $script:PreviousReceiptHash = 'e0b8e1afa3ff649075508bd3040e48fd5723b9ca1ee2aab0a5a8f26cf977f740'
    $script:Intent = '0a8d9057-5627-4259-b6a3-ac337340166e'
    $script:AutomationScripts['src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1'] = '08193555ce06988f1cb2a0bc35b2853357cd37cf675947a09dcef200fba6b062'
    $script:Delta = [ordered]@{
        'bootstrap/modules/PurviewPackage.psm1' = 'c7a5579f0a292558a974f73b1995022c3e2f2f85b519825bc0545ac1a648f4e0'
        'src/Gateway.Provisioning.Worker/PowerShellPurviewConnectionVerificationProvider.cs' = '955b8043af95e5a0e5dc38b91453a7105d9ef9dd682d7a7cd4c410fdf3d320dd'
        'src/Gateway.Provisioning.Worker/PurviewConnectionVerificationDiagnostics.cs' = '217e34edde8a0a10a77c4783a728a30b8a0a24fda617df0d4a7744794e7c4a45'
        'src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1' = '08193555ce06988f1cb2a0bc35b2853357cd37cf675947a09dcef200fba6b062'
    }
}
if ($Generation -ceq 'ProviderErrorDiagnostics') {
    $script:Work = Join-Path $script:PreviousWork 'provider-error-diagnostics'
    $script:PreviousWork = Join-Path $script:PreviousWork 'provider-stage-diagnostics'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:b96de87ce89538617f50e1e2d72c9263d75580357c21fe6fba5aef813dd063d4'
    $script:PreviousPlanFingerprint = 'sha256:7482c8a30d91d7be400635d4473b04fbea682a8fe38e861be866346166434192'
    $script:PreviousReceiptHash = '2b3c07c1a3ba68d88d63e473102da0d55c34078be22a33417552937f3da301da'
    $script:Intent = 'b5394715-42bf-4685-9475-3a29e1e5f5a2'
    $script:AutomationScripts['src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1'] = '38959c6f0aae458ac4d943b33ae29ffa298ecb608829b84956bb83edccc0f94e'
    $script:Delta = [ordered]@{
        'bootstrap/modules/PurviewPackage.psm1' = 'c7a5579f0a292558a974f73b1995022c3e2f2f85b519825bc0545ac1a648f4e0'
        'src/Gateway.Provisioning.Worker/PowerShellPurviewConnectionVerificationProvider.cs' = '0c02bfee450aff5859d6d829e48503017c43980945a76a34782e2211c269fc77'
        'src/Gateway.Provisioning.Worker/PurviewConnectionVerificationDiagnostics.cs' = '4465347c36859dd0aecc8ea32d4b6c083c72b61ba7b6703b2c4a09c0168ac410'
        'src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1' = '38959c6f0aae458ac4d943b33ae29ffa298ecb608829b84956bb83edccc0f94e'
    }
}
if ($Generation -ceq 'PrivateEomWorkspace') {
    $script:Work = Join-Path $script:PreviousWork 'private-eom-workspace'
    $script:PreviousWork = Join-Path $script:PreviousWork 'provider-error-diagnostics'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:7e5e54dc3a4ed062e0dc41a71113628c25d547ad7f73234b85435c2346d37e31'
    $script:PreviousPlanFingerprint = 'sha256:623ce3973d03dace2e8b60f60772c6cbea8a165607af601f402deeb057fe1c3d'
    $script:PreviousReceiptHash = '5d35dd2ad29cc8e2e99965095d4ae370e1f8994fe10eff567a537b0e1e49da7b'
    $script:Intent = 'ce374174-946a-40fe-a497-e51b75649e4e'
    $script:AutomationScripts['src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1'] = '166de77d0657380dc52d2031646f39556123c4a32ed948b0efd23739ce326225'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1'] = '6e37dd2068c7f79599a4e61a990c4567bec86a3ce049f4909be7452034c32791'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1'] = '81ea572cce0531169b48cf92f480960f536873b24efcf225ad487f603f538626'
    $script:Delta = [ordered]@{
        'bootstrap/modules/PurviewPackage.psm1' = 'c7a5579f0a292558a974f73b1995022c3e2f2f85b519825bc0545ac1a648f4e0'
        'src/Gateway.Provisioning.Worker/PurviewConnectionVerificationDiagnostics.cs' = '69291ba436274ca9560d817e3df6faa89f687b8f60691a772ba320e23cefed7c'
        'src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1' = '166de77d0657380dc52d2031646f39556123c4a32ed948b0efd23739ce326225'
        'src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1' = '6e37dd2068c7f79599a4e61a990c4567bec86a3ce049f4909be7452034c32791'
        'src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1' = '81ea572cce0531169b48cf92f480960f536873b24efcf225ad487f603f538626'
    }
}
if ($Generation -ceq 'BoundedEomImports') {
    $script:Work = Join-Path $script:PreviousWork 'bounded-eom-imports'
    $script:PreviousWork = Join-Path $script:PreviousWork 'private-eom-workspace'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:90bfcb60b809e0ec51260d9627f313fb5c045d45f55bc3299a2613b1e95a1e0d'
    $script:PreviousPlanFingerprint = 'sha256:13ee08c591bf31ed31a756875ea2ba601a23493eb7601e5ae3e94f8f7b181273'
    $script:PreviousReceiptHash = 'd7c5c41d904c8671b4aaa3180fed06b76d07774f048ab85ac30b71ccb2fa7086'
    $script:Intent = 'c6646a4c-6ab7-4812-8127-fb34878a320d'
    $script:AutomationScripts['src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1'] = 'd3c9bc35dd4cc40a5fed179a2e02cfc65ffba864888d75a54c0ee019d2342697'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1'] = 'e83e79e58f34af20d25ffc55716a5f153ca69a77a12d22c23f6dd0409fdc94e7'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1'] = '81e4aa7dcbc07411b7efcbcac04c3e25b3d63104566e62b0f5bacb4099023b71'
    $script:Delta = [ordered]@{
        'bootstrap/modules/PurviewPackage.psm1' = 'c7a5579f0a292558a974f73b1995022c3e2f2f85b519825bc0545ac1a648f4e0'
        'src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1' = 'd3c9bc35dd4cc40a5fed179a2e02cfc65ffba864888d75a54c0ee019d2342697'
        'src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1' = 'e83e79e58f34af20d25ffc55716a5f153ca69a77a12d22c23f6dd0409fdc94e7'
        'src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1' = '81e4aa7dcbc07411b7efcbcac04c3e25b3d63104566e62b0f5bacb4099023b71'
        'src/Gateway.Purview.Executor/web.config' = '3f3c1bf2f23f0369fdd707ddb8a90b3b9d77bc2fe6db2a3d1ff2e1efaa435da5'
    }
}
if ($Generation -ceq 'LocationArrays') {
    $script:Work = Join-Path $script:PreviousWork 'location-arrays'
    $script:PreviousWork = Join-Path $script:PreviousWork 'bounded-eom-imports'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:f1ff4baf83439d38b870331deb40ead88c1749f2c22c18cbde85fa123308ac80'
    $script:PreviousPlanFingerprint = 'sha256:1bc9374f0b03ce5c86eee2b40242d54f618c54f494756257548b9d1e8d71270e'
    $script:PreviousReceiptHash = 'ce3ab4b50d65c05240803ccb0c7a7c0ee7f07896737aa04ecd38c8246d7ce9ac'
    $script:Intent = 'a6a751ad-e27b-432a-9ed2-5de72e9071b3'
    $script:AutomationScripts['src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1'] = 'd3c9bc35dd4cc40a5fed179a2e02cfc65ffba864888d75a54c0ee019d2342697'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1'] = '6a1747ec7ad4f9aced5b62a30efd4b5e64632ee2c763fcd869790ef121cc7c6b'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1'] = '85094730e014d00f5b0072ef906609a94884038083cabce89fef52b34f234b51'
    $script:Delta = [ordered]@{
        'src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1' = '6a1747ec7ad4f9aced5b62a30efd4b5e64632ee2c763fcd869790ef121cc7c6b'
        'src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1' = '85094730e014d00f5b0072ef906609a94884038083cabce89fef52b34f234b51'
    }
}
if ($Generation -ceq 'SettingsReadDiagnostics') {
    $script:Work = Join-Path $script:PreviousWork 'settings-read-diagnostics'
    $script:PreviousWork = Join-Path $script:PreviousWork 'location-arrays'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:10848e4010ef26605dbc67ec0391bbb44588d250d11bfb52033c9465965678d4'
    $script:PreviousPlanFingerprint = 'sha256:4a9732507851dc3a9ed3136b14e13767ebc2cd6477ea642b83e8a042d643d298'
    $script:PreviousReceiptHash = '3b11e34300676511924b4de04523feeaba769ace9fde1aa4977e4471bef39176'
    $script:Intent = '769a50cb-20e5-4e08-8b28-1e586ae2c824'
    $script:AutomationScripts['src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1'] = 'd3c9bc35dd4cc40a5fed179a2e02cfc65ffba864888d75a54c0ee019d2342697'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1'] = '35041ef785f7687ce3c9f3c5c24dd158e2e3e7945a4bd947de92893c696dc077'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1'] = '85094730e014d00f5b0072ef906609a94884038083cabce89fef52b34f234b51'
    $script:Delta = [ordered]@{
        'src/Gateway.Purview/IPurviewSettingsFailureObserver.cs' = '2df68cf6938d8f2b4cbc4287b9aea62a12aeeaea2e94c42c301a1c6020c8207b'
        'src/Gateway.Purview/PowerShellPurviewSettingsAutomation.cs' = '8062450216cc2531e55dfbe708798f7e2b895f6907dd6873783ef444dc1c2bc7'
        'src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1' = '35041ef785f7687ce3c9f3c5c24dd158e2e3e7945a4bd947de92893c696dc077'
        'src/Gateway.Purview.Executor/PurviewSettingsFailureDiagnostics.cs' = '95af89a5d94c723b5ae28b158352099740bb569548eabba60f2736f028a1e027'
        'src/Gateway.Purview.Executor/Program.cs' = '3e26ded3866ca3c5d62d6bd86e02a61942dbde1dc8d8cde1aaaf3e44b3a62b6f'
        'src/Gateway.Provisioning.Worker/PurviewConnectionVerificationDiagnostics.cs' = 'b5f1aec1787e85915688e2edc7229a419557eedcec3fcd170104e5d1bf9e978b'
    }
}
if ($Generation -ceq 'ProviderReadbackMetadata') {
    $script:Work = Join-Path $script:PreviousWork 'provider-readback-metadata'
    $script:PreviousWork = Join-Path $script:PreviousWork 'settings-read-diagnostics'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:ae7ba989c899e07dcf57a5ae512183ccce2fc2633b7dcfe20ef84bb65574e026'
    $script:PreviousPlanFingerprint = 'sha256:4a7464386b06b4252a17453252496fcc56709188bd0cb3bea15446a48f656ae7'
    $script:PreviousReceiptHash = '17593cc1ef3f47fbdb72c7b1a2d65164f71741fd5da3552c26883414084254c7'
    $script:Intent = '9d7c7619-1bd2-4a36-8a6a-96a9a1f10308'
    $script:AutomationScripts['src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1'] = 'd3c9bc35dd4cc40a5fed179a2e02cfc65ffba864888d75a54c0ee019d2342697'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1'] = '5f733ed7f454155e4c58deb42ddd7c4e4fee519a30fdce3b00b5fee8bfdad097'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1'] = '4a3f25228f6dffd387539f6c136f9c91d2ea9e7b6713cd0d21c834df330adecb'
    $script:Delta = [ordered]@{
        'src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1' = '5f733ed7f454155e4c58deb42ddd7c4e4fee519a30fdce3b00b5fee8bfdad097'
        'src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1' = '4a3f25228f6dffd387539f6c136f9c91d2ea9e7b6713cd0d21c834df330adecb'
    }
}
if ($Generation -ceq 'ProviderRuleRepresentation') {
    $script:Work = Join-Path $script:PreviousWork 'provider-rule-representation'
    $script:PreviousWork = Join-Path $script:PreviousWork 'provider-readback-metadata'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:80edb08fc7cdd02747602a8a4275f9c428d441a5c9b5b5aefa629884a9158641'
    $script:PreviousPlanFingerprint = 'sha256:a11b0a88142ddf91feb1e5b9a868a96c5627e783affdc5ef6001ed4757fba75f'
    $script:PreviousReceiptHash = '3f12e60326268e01163cc2f7bbb462570a975f891dcea3d5d27ec44367f2fa29'
    $script:Intent = '7cf68327-dc4b-477c-a578-7298f532b9c5'
    $script:AutomationScripts['src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1'] = 'd3c9bc35dd4cc40a5fed179a2e02cfc65ffba864888d75a54c0ee019d2342697'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1'] = '4a45c8a5e5b3727ee66de7b0754d001ec21fd68d0bed32d0cf6c1b61353e530c'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1'] = 'd57be7e377c7456a41e0075f448ab44650706b3a46b21e7092f7a1fd9181aac4'
    $script:Delta = [ordered]@{
        'src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1' = '4a45c8a5e5b3727ee66de7b0754d001ec21fd68d0bed32d0cf6c1b61353e530c'
        'src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1' = 'd57be7e377c7456a41e0075f448ab44650706b3a46b21e7092f7a1fd9181aac4'
    }
}
if ($Generation -ceq 'KydProviderMode') {
    $script:Work = Join-Path $script:PreviousWork 'kyd-provider-mode'
    $script:PreviousWork = Join-Path $script:PreviousWork 'provider-rule-representation'
    $script:SeedRoot = Join-Path $script:PreviousWork 'candidate'
    $script:SeedSource = 'sha256:7be096518a017273eb74f30138146873120b07d88823b934661273c11d8a47c4'
    $script:PreviousPlanFingerprint = 'sha256:ab6eaa3dd3dfda573768fbc0d220225cf77390506128e3dbd144e7317d5277b3'
    $script:PreviousReceiptHash = '631137734fa8509b7231e6ed80d4a67acaf4c54e1676575e08fbdaf2da3378e2'
    $script:Intent = '383ddd62-1d99-42b8-ae81-753e47168966'
    $script:AutomationScripts['src/Gateway.Provisioning.Worker/Automation/Verify-PurviewTenantConnection.ps1'] = 'd3c9bc35dd4cc40a5fed179a2e02cfc65ffba864888d75a54c0ee019d2342697'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1'] = '2e9d26ad8afadeb8815aedd308471d104cfafdf6b99a179eb94bb3ed32cc49eb'
    $script:AutomationScripts['src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1'] = 'd57be7e377c7456a41e0075f448ab44650706b3a46b21e7092f7a1fd9181aac4'
    $script:Delta = [ordered]@{
        'src/Gateway.Purview/Automation/Invoke-PurviewSettingsOperation.ps1' = '2e9d26ad8afadeb8815aedd308471d104cfafdf6b99a179eb94bb3ed32cc49eb'
    }
}
# Use the accepted source's contracts, never unrelated current-main changes.
foreach ($name in @('Common', 'Azure', 'Entra', 'Experience', 'PurviewPackage', 'PurviewExecutor')) {
    Import-Module (Join-Path $script:Baseline "bootstrap\modules\$name.psm1") -Global -Force -DisableNameChecking
}

function Copy-GwHotfixObject($Value) {
    return ,(ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100) -AsHashtable -Depth 100 -NoEnumerate -DateKind String)
}
function Get-GwHotfixHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-PurviewPackageRegularPath([string]$Path) {
    $expected = Join-Path $script:Baseline 'bootstrap\modules\PurviewPackage.psm1'
    $module = @(Get-Module PurviewPackage -All | Where-Object { $_.Path -ieq $expected })
    if ($module.Count -ne 1) { throw 'Gw0911gHotfix: exact baseline package path guard is unavailable.' }
    & $module[0] { param($p) Assert-PurviewPackageRegularPath -Path $p } $Path
}
function Assert-GwHotfixEqual($Actual, $Expected, [string]$Label) {
    if ((Get-BootstrapObjectFingerprint $Actual) -cne (Get-BootstrapObjectFingerprint $Expected)) {
        throw "Gw0911gHotfix: $Label drifted; no adoption or replay is authorized."
    }
}
function Read-GwHotfixJson([string]$Name) {
    $path = Join-Path $script:Work $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    Assert-PurviewPackageRegularPath $path
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
}
function Save-GwHotfixJson([string]$Name, $Value) {
    $path = Join-Path $script:Work $Name
    Assert-PurviewPackageRegularPath $path
    [IO.Directory]::CreateDirectory($script:Work) | Out-Null
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 100))
    # Immutable checkpoints: absence after a crash is never permission to repeat a dispatch.
    $stream = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Get-GwHotfixState {
    $path = Join-Path $script:Baseline ".bootstrap\state\$script:Subscription-rg-gw0911g-dev-dev.json"
    if ((Get-GwHotfixHash $path) -cne $script:StateHash) { throw 'Gw0911gHotfix: accepted state changed.' }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    if ($state.deploymentOwnershipId -cne '9b34fc6e-3ba5-4d2e-b40d-d706ba23833f' -or
        $state.acceptedPlan.sourceFingerprint -cne $script:Source -or
        $state.freshPurviewExecutor.status -cne 'Installed' -or $state.steps.Count -ne 19 -or
        @($state.steps.Values | Where-Object status -CNE 'Completed').Count) {
        throw 'Gw0911gHotfix: only the exact accepted completed Full deployment is supported.'
    }
    if ((Get-BootstrapSourceFingerprint -Root $script:Baseline) -cne $script:Source) {
        throw 'Gw0911gHotfix: original source drift.'
    }
    return $state
}
function Assert-GwHotfixOperator {
    $account = Invoke-AzJson -Arguments @('account', 'show', '--query', '{id:id,tenantId:tenantId,user:user}')
    if ($account.id -cne $script:Subscription -or $account.tenantId -cne $script:Tenant -or
        $account.user.type -cne 'user') {
        throw 'Gw0911gHotfix: sign in as the reviewed operator in the exact tenant/subscription.'
    }
    Set-BootstrapAzureSubscriptionContext -SubscriptionId $script:Subscription -TenantId $script:Tenant
    $operator = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', 'https://graph.microsoft.com/v1.0/me?$select=id')
    if ($operator.id -cne $script:Operator) {
        throw 'Gw0911gHotfix: sign in as the reviewed operator in the exact tenant/subscription.'
    }
}
function Get-GwHotfixCandidate {
    $state = Get-GwHotfixState
    $candidate = Join-Path $script:Work 'candidate'
    $expected = @(Get-GwHotfixExpectedManifest)
    Assert-GwHotfixEqual @(Get-BootstrapSourceManifest -Root $candidate) $expected 'candidate inventory (only fixed reviewed delta allowed)'
    $source = Get-BootstrapObjectFingerprint $expected
    $package = Read-PurviewExecutorPackage -PackageDirectory (Join-Path $candidate '.bootstrap\hotfix-package') -ExpectedSourceFingerprint $source
    if ($Generation -cin @('ConsoleFreePowerShell','ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) {
        $readerPath = Join-Path $candidate 'bootstrap\modules\PurviewPackage.psm1'
        $readerHash = if ($Generation -cin @('LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) {
            'c7a5579f0a292558a974f73b1995022c3e2f2f85b519825bc0545ac1a648f4e0'
        } else { $script:Delta['bootstrap/modules/PurviewPackage.psm1'] }
        if ((Get-GwHotfixHash $readerPath) -cne $readerHash) {
            throw 'Gw0911gHotfix: reviewed console-free package reader changed.'
        }
        $reader = @(Import-Module $readerPath -PassThru -DisableNameChecking | Where-Object { $_.Path -ieq $readerPath })
        if ($reader.Count -ne 1) { throw 'Gw0911gHotfix: exact reviewed console-free reader was not loaded.' }
        $package = & $reader[0] {
            param($directory,$fingerprint)
            Read-PurviewExecutorPackage -PackageDirectory $directory -ExpectedSourceFingerprint $fingerprint
        } (Join-Path $candidate '.bootstrap\hotfix-package') $source
    }
    $proof = @()
    foreach ($path in $script:AutomationScripts.Keys) {
        $name = Split-Path -Leaf $path
        $final = if ($name -ceq 'Connect-PurviewTenant.ps1') {
            if ($script:ExecutorOnly) { Join-Path $candidate $path }
            else { Join-Path $candidate ".bootstrap\admin-publish\wwwroot\downloads\$name" }
        } else { Join-Path $candidate ".bootstrap\hotfix-package\publish\Automation\$name" }
        if ((Get-GwHotfixHash $final) -cne $script:AutomationScripts[$path]) { throw 'Gw0911gHotfix: final published script bytes differ.' }
        $proof += @{ path = $path; oldSha256 = Get-GwHotfixHash (Join-Path $script:SeedRoot $path)
            newSha256 = Get-GwHotfixHash $final }
    }
    # The ZIP validator hashes every entry. Also bind its script entries to the reviewed source.
    $zip = [IO.Compression.ZipFile]::OpenRead($package.packagePath)
    try {
        $zipScripts = @('Automation/Verify-PurviewTenantConnection.ps1', 'Automation/Invoke-PurviewSettingsOperation.ps1')
        if ($Generation -cin @('PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) { $zipScripts += 'Automation/Ensure-PurviewPolicyProfile.ps1' }
        foreach ($path in $zipScripts) {
            $entry = $zip.GetEntry($path)
            $stream = $entry.Open()
            try { $hash = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($stream)) }
            finally { $stream.Dispose() }
            if ($hash -cne @($proof | Where-Object { (Split-Path -Leaf $_.path) -ceq (Split-Path -Leaf $path) })[0].newSha256) {
                throw 'Gw0911gHotfix: actual ZIP script differs from reviewed bytes.'
            }
        }
    } finally { $zip.Dispose() }
    $sourceProof = @($script:Delta.Keys | ForEach-Object {
        @{ path = $_; oldSha256 = if (Test-Path -LiteralPath (Join-Path $script:SeedRoot $_)) { Get-GwHotfixHash (Join-Path $script:SeedRoot $_) } else { $null }
            newSha256 = Get-GwHotfixHash (Join-Path $candidate $_) }
    })
    $result = @{ directory = $candidate; sourceFingerprint = $source; package = $package; scriptProof = $proof; sourceProof = $sourceProof }
    if ($Generation -cin @('ExecutorStartupDiagnostics','ConsoleFreePowerShell','ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) {
        $zip = [IO.Compression.ZipFile]::OpenRead($package.packagePath)
        try {
            $hooks = @($zip.Entries | Where-Object { (Split-Path -Leaf $_.FullName) -ieq 'Gateway.Purview.Executor.StartupDiagnostics.dll' })
            if ($hooks.Count -ne 1 -or $hooks[0].FullName -cne 'Gateway.Purview.Executor.StartupDiagnostics.dll') {
                throw 'Gw0911gHotfix: exactly one root attested diagnostic hook DLL is required.'
            }
            $stream = $hooks[0].Open()
            try { $hash = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($stream)) }
            finally { $stream.Dispose() }
            if ((Get-GwHotfixHash (Join-Path $candidate '.bootstrap\hotfix-package\publish\Gateway.Purview.Executor.StartupDiagnostics.dll')) -cne $hash) {
                throw 'Gw0911gHotfix: published diagnostic hook differs from final ZIP bytes.'
            }
            $result.diagnosticHookSha256 = $hash
        } finally { $zip.Dispose() }
    }
    if ($Generation -cin @('ConsoleFreePowerShell','ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) { $result.consoleFreeAssets = Assert-GwHotfixConsoleFreeAssets $result }
    if ($Generation -cin @('BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) {
        [xml]$web = Get-Content (Join-Path $candidate '.bootstrap\hotfix-package\publish\web.config') -Raw
        $hostSettings = $web.configuration.location.'system.webServer'.aspNetCore
        if ($hostSettings.requestTimeout -cne '00:03:50' -or $hostSettings.hostingModel -cne 'OutOfProcess' -or
            $hostSettings.stdoutLogEnabled -cne 'false' -or $hostSettings.processPath -cne '.\Gateway.Purview.Executor.exe') {
            throw 'Gw0911gHotfix: final IIS hosting budget or privacy boundary differs.'
        }
        $zip = [IO.Compression.ZipFile]::OpenRead($package.packagePath)
        try {
            $stream = $zip.GetEntry('web.config').Open()
            try { $hash = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($stream)) }
            finally { $stream.Dispose() }
            if ($hash -cne (Get-GwHotfixHash (Join-Path $candidate '.bootstrap\hotfix-package\publish\web.config'))) {
                throw 'Gw0911gHotfix: final ZIP IIS configuration differs from the verified host configuration.'
            }
        } finally { $zip.Dispose() }
    }
    return $result
}
function Assert-GwHotfixPublisherContext($Candidate) {
    $context = Join-Path $Candidate.directory '.bootstrap\publisher-context'
    $inputs = @(Get-BootstrapSourceManifest -Root $Candidate.directory | Where-Object {
        $_.path -cmatch '\Asrc/Gateway\.Purview\.PackagePublisher/[^/]+\.(cs|csproj)\z' -or
        $_.path -ceq 'src/Gateway.Purview.PackagePublisher/Dockerfile' -or
        $_.path -cin @('global.json','nuget.config','Directory.Build.props','Directory.Build.targets','Directory.Packages.props')
    })
    $expected = @($inputs.path) + @('payload/executor.zip')
    $files = @(Get-ChildItem -LiteralPath $context -Recurse -File)
    Assert-GwHotfixEqual @($files | ForEach-Object { [IO.Path]::GetRelativePath($context,$_.FullName).Replace('\','/') } | Sort-Object) `
        @($expected | Sort-Object) 'publisher build-context file inventory'
    foreach ($input in $inputs) {
        Assert-PurviewPackageRegularPath (Join-Path $context $input.path)
        if ((Get-GwHotfixHash (Join-Path $context $input.path)) -cne $input.sha256) { throw 'Gw0911gHotfix: publisher source drift.' }
    }
    if ('sha256:' + (Get-GwHotfixHash (Join-Path $context 'payload\executor.zip')) -cne $Candidate.package.receipt.packageDigest) {
        throw 'Gw0911gHotfix: publisher payload drift.'
    }
}

function Get-GwHotfixAdminContext($Candidate) {
        $context = Join-Path $Candidate.directory '.bootstrap\admin-context'
        $create = -not (Test-Path -LiteralPath $context)
        $hashes = @{}
        foreach ($file in @(Get-BootstrapSourceManifest -Root $Candidate.directory)) { $hashes[$file.path] = $file.sha256 }
        $paths = @(Get-GatewayAcrBuildSourceFiles -RepositoryRoot $Candidate.directory |
            Where-Object { $_ -notmatch '(?i)(^|/)(bin|obj)(/|$)' })
        foreach ($path in $paths) {
            if (-not $hashes.ContainsKey($path)) { throw 'Gw0911gHotfix: Admin build input outside source manifest.' }
            $destination = Join-Path $context $path
            Assert-PurviewPackageRegularPath $destination
            if ($create) {
                Assert-BootstrapSourcePathIsRegular -Root $Candidate.directory -RelativePath $path | Out-Null
                [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
                Copy-Item -LiteralPath (Join-Path $Candidate.directory $path) -Destination $destination
            }
            if ((Get-GwHotfixHash $destination) -cne $hashes[$path]) { throw 'Gw0911gHotfix: Admin context input drift.' }
        }
        $actual = @(Get-ChildItem -LiteralPath $context -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($context,$_.FullName).Replace('\','/') } | Sort-Object)
        Assert-GwHotfixEqual $actual @($paths | Sort-Object) 'Admin context inventory'
        Assert-GatewayCredentialFreeNuGetConfig -Path (Join-Path $context 'nuget.config') | Out-Null
        return $context
}
function Initialize-GwHotfixCandidate {
    $null = Get-GwHotfixState
    $candidate = Join-Path $script:Work 'candidate'
    if (Test-Path -LiteralPath $candidate) {
        $existing = Get-GwHotfixCandidate
        if ($Generation -cin @('ConsoleFreePowerShell','ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) {
            $context = Join-Path $candidate '.bootstrap\publisher-context'
            if (-not (Test-Path -LiteralPath $context)) {
                $null = New-PurviewPublisherBuildContext -RepositoryRoot $candidate -SourceFingerprint $existing.sourceFingerprint `
                    -PackageDirectory (Split-Path -Parent $existing.package.packagePath) -ExpectedReceiptFingerprint $existing.package.receiptFingerprint `
                    -OutputDirectory $context
            }
            Assert-GwHotfixPublisherContext $existing
            if (-not (Read-GwHotfixJson 'local-artifacts.json')) { Save-GwHotfixJson 'local-artifacts.json' $existing }
        }
        if ($script:ExecutorOnly -and -not (Read-GwHotfixJson 'local-startup-verified.json')) {
            Test-GwHotfixFinalExecutorStartup $existing | Out-Null
        }
        if ($Generation -ceq 'ExecutorStartupDiagnostics') { Invoke-GwHotfixDiagnosticPackageValidation }
        if ($Generation -cin @('ConsoleFreePowerShell','ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) { Invoke-GwHotfixDetachedValidation $existing }
        return $existing
    }
    $manifest = @(Get-GwHotfixExpectedManifest)
    foreach ($path in $script:Delta.Keys) {
        if ((Get-GwHotfixHash (Join-Path $script:Root $path)) -cne $script:Delta[$path]) {
            throw 'Gw0911gHotfix: approved main script bytes changed.'
        }
    }
    foreach ($entry in $manifest) {
        $source = Join-Path $script:SeedRoot $entry.path
        if ($script:Delta.Contains($entry.path)) { $source = Join-Path $script:Root $entry.path }
        Assert-PurviewPackageRegularPath $source
        $destination = Join-Path $candidate $entry.path
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
    }
    $pwsh = Join-Path $script:Root '.maintenance\dependencies\powershell-7.6.5\runtime\pwsh.exe'
    # EOM is reused from an existing validated maintenance package, never downloaded.
    $moduleRoot = Join-Path $script:Root '.maintenance\executor-validation\253925d5844c1f104305317ff6cc12657ef5b937be27019dbd5bba553085b2dc\5c3447ca-d510-45ea-9bc0-125ec5a8265e\.agent-runtime\purview-package\publish\PowerShellModules'
    $before = $env:PSModulePath
    try {
        $env:PSModulePath = $moduleRoot
        $preserve = @{}
        if ($Generation -cin @('ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) {
            $previous = Get-GwHotfixPreviousPlan
            $preserve = @{
                PreservedChildSourceRoot = $script:SeedRoot
                PreservedChildSourceFingerprint = $script:SeedSource
                PreservedChildPackageDigest = $previous.packageReceipt.packageDigest
            }
        }
        & $pwsh -NoProfile -NonInteractive -File (Join-Path $candidate 'operations\build-purview-executor-package.ps1') `
            -OutputDirectory (Join-Path $candidate '.bootstrap\hotfix-package') `
            -PowerShellDirectory (Split-Path -Parent $pwsh) `
            -ExpectedSourceFingerprint (Get-BootstrapSourceFingerprint -Root $candidate) @preserve
        if ($LASTEXITCODE -ne 0) { throw 'Gw0911gHotfix: local executor build failed; retain diagnostics, do not reuse partial output.' }
    } finally { $env:PSModulePath = $before }
    if ($Generation -ceq 'GuidScripts') {
        & dotnet publish (Join-Path $candidate 'src\Gateway.AdminUi\Gateway.AdminUi.csproj') -c Release `
            -o (Join-Path $candidate '.bootstrap\admin-publish') /p:UseAppHost=false --nologo -v quiet
        if ($LASTEXITCODE -ne 0) { throw 'Gw0911gHotfix: local Admin publish failed.' }
    }
    $result = Get-GwHotfixCandidate
    $null = New-PurviewPublisherBuildContext -RepositoryRoot $candidate -SourceFingerprint $result.sourceFingerprint `
        -PackageDirectory (Split-Path -Parent $result.package.packagePath) -ExpectedReceiptFingerprint $result.package.receiptFingerprint `
        -OutputDirectory (Join-Path $candidate '.bootstrap\publisher-context')
    Save-GwHotfixJson 'local-artifacts.json' $result
    if ($script:ExecutorOnly) { Test-GwHotfixFinalExecutorStartup $result | Out-Null }
    if ($Generation -ceq 'ExecutorStartupDiagnostics') { Invoke-GwHotfixDiagnosticPackageValidation }
    if ($Generation -cin @('ConsoleFreePowerShell','ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) { Invoke-GwHotfixDetachedValidation $result }
    return $result
}

# Fixed endpoints; no supplied URLs, arbitrary ARM resources, JSON programs or callbacks.
function Get-GwHotfixResourceId([ValidateSet('admin', 'api', 'worker', 'site', 'publisher')][string]$Name) {
    $suffix = switch ($Name) {
        admin { 'Microsoft.App/containerApps/ca-gateway-admin-dev' }
        api { 'Microsoft.App/containerApps/ca-gateway-api-dev' }
        worker { 'Microsoft.App/containerApps/ca-gateway-worker-dev-v3' }
        site { 'Microsoft.Web/sites/app-gw0911g-dev-purview-roeal6' }
        publisher { 'Microsoft.App/jobs/job-gw0911g-purview-package-dev' }
    }
    return "$script:Scope/providers/$suffix"
}
function Invoke-GwHotfixArm([ValidateSet('admin', 'api', 'worker', 'site', 'publisher', 'settings', 'executions', 'start')][string]$Name,
    [ValidateSet('GET', 'POST', 'PATCH', 'PUT')][string]$Method = 'GET', $Body = $null,
    [AllowNull()][Collections.IDictionary]$CorrectionPlan = $null) {
    $version = '2025-01-01'
    $id = switch ($Name) {
        settings { $version = '2024-11-01'; "$(Get-GwHotfixResourceId site)/config/appsettings$(if ($Method -ceq 'POST') {'/list'})" }
        executions { "$(Get-GwHotfixResourceId publisher)/executions" }
        start { "$(Get-GwHotfixResourceId publisher)/start" }
        site { $version = '2024-11-01'; Get-GwHotfixResourceId site }
        default { Get-GwHotfixResourceId $Name }
    }
    $allowed = @{ admin = @('GET','PATCH'); api = @('GET'); worker = @('GET','PATCH')
        site = @('GET','PATCH'); publisher = @('GET'); settings = @('POST','PUT'); executions = @('GET'); start = @('POST') }
    if ($Method -cnotin $allowed[$Name]) { throw 'Gw0911gHotfix: unsupported fixed ARM operation.' }
    if ($Name -ceq 'settings' -and $Method -ceq 'POST') {
        return @{ properties = Get-PurviewExecutorArmSettings -SiteId (Get-GwHotfixResourceId site) }
    }
    if ($Name -ceq 'executions') {
        return @{ value = @(Invoke-AzJsonArray -OperationLabel 'Hotfix publisher executions' -Arguments @(
            'containerapp','job','execution','list','--subscription',$script:Subscription,
            '--resource-group','rg-gw0911g-dev','--name','job-gw0911g-purview-package-dev')) }
    }
    if ($Method -ceq 'GET') { return Copy-GwHotfixObject (Get-PurviewExecutorArmResource -Id $id -ApiVersion $version) }
    # Common intentionally forbids native `az rest` after authentication.
    # Keep writes at a fixed in-process ARM boundary; never follow provider URLs.
    if ($CorrectionPlan) {
        if ($Name -cne 'start' -or $Method -cne 'POST') { throw 'Gw0911gHotfix: correction is only for this publisher start.' }
        $correction = Assert-GwHotfixCorrectedPlan $CorrectionPlan
        $approval = Read-GwHotfixJson 'promote-corrected-approval.json'
        if (-not $approval -or $approval.fingerprint -cne (Get-BootstrapObjectFingerprint $CorrectionPlan)) {
            throw 'Gw0911gHotfix: corrected dispatch is not approved.'
        }
        Assert-GwHotfixEqual $Body (ConvertTo-GwHotfixStartBody $CorrectionPlan.target.executionTemplate) 'corrected HTTP body'
        if (Test-Path -LiteralPath (Join-Path $script:Work 'publisher-http-dispatch.json')) {
            throw 'Gw0911gHotfix: HTTP dispatch was already attempted; read-only reconciliation only.'
        }
    }
    $token = Get-GwHotfixArmToken
    try {
        if ($CorrectionPlan) {
            # Token acquisition/validation is complete. Prove the original live
            # history immediately before consuming the single HTTP dispatch.
            Assert-GwHotfixEqual @(Get-GwHotfixExecutions) $CorrectionPlan.original.executions 'pre-HTTP publisher history'
            Save-GwHotfixJson 'publisher-http-dispatch.json' @{
                planFingerprint = Get-BootstrapObjectFingerprint $CorrectionPlan
                correctionFingerprint = Get-BootstrapObjectFingerprint $correction
                retainedIntentSha256 = $correction.publisherIntentSha256
                executionIntentId = $script:Intent
                bodyFingerprint = Get-BootstrapObjectFingerprint $Body
                jobId = Get-GwHotfixResourceId publisher
            }
        }
        $response = Invoke-WebRequest -Uri "https://management.azure.com$id`?api-version=$version" -Method $Method `
            -Headers @{ Authorization = "Bearer $($token.accessToken)" } -ContentType 'application/json' `
            -Body (ConvertTo-Json -InputObject $Body -Depth 100 -Compress) -MaximumRedirection 0 -TimeoutSec 120 -SkipHttpErrorCheck
        if ([int]$response.StatusCode -notin @(200,201,202)) { throw 'Gw0911gHotfix: ARM write did not succeed; reconcile exact resources without replay.' }
        # A response is not completion. Only independent exact GETs can attest it.
        return @{}
    } catch { throw 'Gw0911gHotfix: ARM outcome unverified; preserve intent and reconcile, never replay.' }
    finally { $token = $null }
}
function Get-GwHotfixProjection($Resource, [string]$Name) {
    $ready = if ($Name -ceq 'site') { $Resource.properties.state -ceq 'Running' -and $Resource.properties.enabled -eq $true }
        else { $Resource.properties.provisioningState -ceq 'Succeeded' }
    if (-not ([string]$Resource.id).Equals((Get-GwHotfixResourceId $Name), [StringComparison]::OrdinalIgnoreCase) -or
        $Resource.tags.bootstrapOwnershipId -cne '9b34fc6e-3ba5-4d2e-b40d-d706ba23833f' -or
        $Resource.tags.bootstrapSourceFingerprint -cne $script:Source -or
        -not $ready) { throw "Gw0911gHotfix: foreign/unready $Name resource." }
    if ($Name -cin @('admin','api','worker') -and (
        [string]::IsNullOrEmpty([string]$Resource.properties.latestRevisionName) -or
        $Resource.properties.latestReadyRevisionName -cne $Resource.properties.latestRevisionName)) {
        throw 'Gw0911gHotfix: latest app revision is not independently ready.'
    }
    $projection = @{ id = $Resource.id.ToLowerInvariant(); identity = $Resource.identity; tags = $Resource.tags }
    if ($Name -ceq 'site') {
        $projection.properties = @{}
        foreach ($key in @('serverFarmId', 'enabled', 'httpsOnly', 'publicNetworkAccess', 'virtualNetworkSubnetId', 'outboundVnetRouting')) {
            $projection.properties[$key] = $Resource.properties[$key]
        }
    } else {
        $projection.properties = @{ configuration = $Resource.properties.configuration; template = $Resource.properties.template }
        $projection.properties.environmentId = $Resource.properties.environmentId
        if ($Resource.properties.Contains('managedEnvironmentId')) { $projection.properties.managedEnvironmentId = $Resource.properties.managedEnvironmentId }
    }
    return $projection
}
function Get-GwHotfixExecutions {
    $value = Invoke-GwHotfixArm executions
    Assert-PurviewExecutorCompleteArmCollection $value
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $value.value) {
        if ($item.name -cnotmatch '^[a-z0-9-]{1,80}$' -or -not $seen.Add($item.name) -or
            -not ([string]$item.id).Equals("$(Get-GwHotfixResourceId publisher)/executions/$($item.name)", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Gw0911gHotfix: foreign/duplicate publisher execution.'
        }
    }
    return @($value.value)
}
function Get-GwHotfixCompanionHash {
    $client = [Net.Http.HttpClient]::new([Net.Http.HttpClientHandler]@{ AllowAutoRedirect = $false })
    try {
        $response = $client.GetAsync('https://ca-gateway-admin-dev.bluepond-de6fa6aa.koreacentral.azurecontainerapps.io/downloads/Connect-PurviewTenant.ps1').GetAwaiter().GetResult()
        try {
            if ([int]$response.StatusCode -ne 200) { throw 'Gw0911gHotfix: served companion unavailable (redirects are not followed).' }
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if ($bytes.Length -gt 1MB) { throw 'Gw0911gHotfix: oversized companion.' }
            return [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($bytes))
        } finally { $response.Dispose() }
    } finally { $client.Dispose() }
}
function Get-GwHotfixObservation {
    Assert-GwHotfixOperator
    $state = Get-GwHotfixState
    if ($Generation -cin @('LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) { Assert-GwHotfixB2Capacity }
    $result = @{}
    foreach ($name in @('admin','api','worker','site','publisher')) {
        $result[$name] = Get-GwHotfixProjection (Invoke-GwHotfixArm $name) $name
    }
    $result.settings = (Invoke-GwHotfixArm settings POST).properties
    $result.executions = @(Get-GwHotfixExecutions)
    $result.companionSha256 = Get-GwHotfixCompanionHash
    return $result
}
function Get-GwHotfixExactApiTimestampRepresentation($Resource) {
    $copy = Copy-GwHotfixObject $Resource
    $entries = @($copy.properties.template.containers[0].env |
        Where-Object name -CEQ 'BootstrapCapabilities__AttestedAtUtc')
    if ($entries.Count -ne 1 -or
        [string]$entries[0].value -cne '2026-09-11T19:54:25.2167343+09:00') {
        throw 'Gw0911gHotfix: frozen API timestamp representation differs from the exact reviewed baseline.'
    }
    # The prior JSON reader changed only this timestamp's timezone representation.
    # Match the unchanged live UTC bytes without rewriting the immutable old plan.
    $entries[0].value = '2026-09-11T10:54:25.2167343+00:00'
    return $copy
}
function Get-GwHotfixProfileAmendedSettings($Settings) {
    $path = Join-Path $script:Root '.test-work\live-acceptance-20260912\profile-setting-readback.json'
    if ((Get-GwHotfixHash $path) -cne '45386e8f218f2cbfc2f177c095ef0119aeef2f5f829cc7ced8aae9f929c95ccd') {
        throw 'Gw0911gHotfix: exact live profile-setting amendment receipt changed.'
    }
    $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    if ($receipt.onlyExpectedSettingChanged -ne $true -or $receipt.allOtherSettingsPreserved -ne $true -or
        $receipt.setting -cne 'WEBSITE_LOAD_USER_PROFILE' -or $receipt.value -cne '1' -or
        (Get-BootstrapObjectFingerprint $Settings) -cne $receipt.oldSettingsHash -or
        $Settings.Contains('WEBSITE_LOAD_USER_PROFILE')) {
        throw 'Gw0911gHotfix: profile-setting amendment is not bound to the exact previous settings.'
    }
    $copy = Copy-GwHotfixObject $Settings
    $copy.WEBSITE_LOAD_USER_PROFILE = '1'
    if ((Get-BootstrapObjectFingerprint $copy) -cne $receipt.newSettingsHash) {
        throw 'Gw0911gHotfix: amended settings fingerprint differs.'
    }
    return $copy
}
function Get-GwHotfixReviewedContainerAmendments {
    if ($Generation -cne 'LocationArrays') { throw 'Gw0911gHotfix: container amendments are generation-bound.' }
    $work = Join-Path $script:Root '.test-work\gw0911g-admin-inventory'
    $receiptPath = Join-Path $work 'verified.json'
    if ((Get-GwHotfixHash $receiptPath) -cne 'c968a7e1a4ef6793b70288f186cebe505f243a5fcdca68b85955515e7ec2e563') {
        throw 'Gw0911gHotfix: latest Admin receipt changed.'
    }
    $receipt = Get-Content $receiptPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    $fingerprint = 'sha256:9fe62f158e1cf2e26d2e71b969f3353da81f3a7202c0360a5333f93da4990e3e'
    $plan = Get-Content (Join-Path $work "plan-$($fingerprint.Substring(7)).json") -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    if ((Get-BootstrapObjectFingerprint $plan) -cne $fingerprint -or
        $receipt.plan -cne $fingerprint -or $receipt.status -cne 'ExactAdminImageVerified' -or
        $receipt.image -cne $plan.targetAdmin.properties.template.containers[0].image -or
        $plan.original.worker.properties.template.containers[0].image -cne
            'acrgw0911gdevdbilxu.azurecr.io/gateway-worker@sha256:5321acf7d20361483a156085cf9927c6fac88d6f9b9a79d09cd27f868ca7ff39') {
        throw 'Gw0911gHotfix: exact reviewed container amendment changed.'
    }
    return @{ admin = $plan.targetAdmin; worker = $plan.original.worker }
}
function Assert-GwHotfixB2Capacity {
    if ($Generation -cnotin @('LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) { throw 'Gw0911gHotfix: capacity amendment is generation-bound.' }
    $receiptPath = Join-Path $script:Root '.test-work\live-acceptance-20260912\executor-capacity-b2\verified.json'
    if ((Get-GwHotfixHash $receiptPath) -cne '9f3d3b59f5ce4607727956570cd22c346a9044782a809427bb26c80a3c624b77') {
        throw 'Gw0911gHotfix: B2 capacity receipt changed.'
    }
    $id = "$script:Scope/providers/Microsoft.Web/serverfarms/asp-gw0911g-dev-purview"
    $plan = Get-PurviewExecutorArmResource -Id $id -ApiVersion '2024-04-01'
    if (-not ([string]$plan.id).Equals($id,[StringComparison]::OrdinalIgnoreCase) -or
        $plan.sku.name -cne 'B2' -or $plan.sku.tier -cne 'Basic' -or $plan.sku.capacity -ne 1 -or
        $plan.properties.numberOfSites -ne 1 -or $plan.properties.reserved -ne $false -or
        $plan.properties.status -cne 'Ready' -or
        $plan.tags.bootstrapOwnershipId -cne '9b34fc6e-3ba5-4d2e-b40d-d706ba23833f') {
        throw 'Gw0911gHotfix: exact owned B2 capacity changed.'
    }
}
function Assert-GwHotfixOriginal($Observation, $State) {
    if ($script:ExecutorOnly) {
        $previous = Get-GwHotfixPreviousPlan
        $amendments = if ($Generation -ceq 'LocationArrays') { Get-GwHotfixReviewedContainerAmendments } else { @{} }
        foreach ($name in @('admin','api','worker','site','publisher','settings','companionSha256')) {
            $expectedResource = $previous.target.resources[$name]
            if ($amendments.ContainsKey($name)) { $expectedResource = $amendments[$name] }
            if ($Generation -ceq 'ConnectionDiagnostics' -and $name -ceq 'api') {
                $expectedResource = Get-GwHotfixExactApiTimestampRepresentation $expectedResource
            }
            if ($Generation -ceq 'ProviderStageDiagnostics' -and $name -ceq 'settings') {
                $expectedResource = Get-GwHotfixProfileAmendedSettings $expectedResource
            }
            Assert-GwHotfixEqual $Observation[$name] $expectedResource "previous verified $name baseline"
        }
        $publication = Get-GwHotfixPublisherResult $previous $Observation.executions
        Assert-GwHotfixEqual $publication $previous.verified.publication 'exact completed prior publisher executions'
        $null = Assert-PurviewPublisherJob -Config $State.configuration -Foundation $State.steps['Azure foundation'].evidence `
            -Record $State.freshPurviewExecutor -Network $State.freshPurviewExecutor.network
        return
    }
    $record = $State.freshPurviewExecutor
    $runtime = $State.steps['Gateway runtime deployment'].evidence
    $admin = $State.steps['Admin UI deployment'].evidence
    $adminIdentities = @($Observation.admin.identity.userAssignedIdentities.Values)
    if ($Observation.admin.identity.type -cne 'UserAssigned' -or $adminIdentities.Count -ne 1 -or
        $adminIdentities[0].principalId -cne $admin.adminUiPrincipalId -or
        $Observation.admin.properties.configuration.activeRevisionsMode -cne 'Single' -or
        $Observation.worker.properties.configuration.activeRevisionsMode -cne 'Single') {
        throw 'Gw0911gHotfix: Admin principal or single-revision runtime drift.'
    }
    foreach ($pair in @(@('admin',$admin.adminUiImage), @('api',$runtime.apiImage), @('worker',$runtime.workerImage))) {
        $containers = @($Observation[$pair[0]].properties.template.containers)
        if ($containers.Count -ne 1 -or $containers[0].image -cne $pair[1]) { throw 'Gw0911gHotfix: original image drift.' }
    }
    if ($Observation.worker.identity.principalId -cne $runtime.workerPrincipalId -or
        $Observation.api.identity.principalId -cne $runtime.apiPrincipalId -or
        $Observation.site.identity.principalId -cne $record.host.executorPrincipalId.value -or
        $Observation.publisher.identity.principalId -cne $record.publisher.jobPrincipalId.value) {
        throw 'Gw0911gHotfix: original principal drift.'
    }
    $binding = Get-PurviewExecutorWorkerEnvironment @{ enabled = $true; endpoint = $record.host.executorEndpoint.value; binding = $record.host.executorBinding.value }
    $actual = @($Observation.worker.properties.template.containers[0].env | Where-Object { $_.name.StartsWith('PurviewExecutor__', [StringComparison]::Ordinal) })
    Assert-GatewayExactContainerEnvironment -Entries $actual -ExpectedValues $binding | Out-Null
    # Actual existing-host/job adapters verify identities, roles, certificates' identifiers,
    # package URL, runtime manifest, nonsecret settings, network and allowed template shape.
    $foundation = $State.steps['Azure foundation'].evidence
    Assert-PurviewExecutorHost -Config $State.configuration -Foundation $foundation -Record $record -Enabled
    $null = Assert-PurviewPublisherJob -Config $State.configuration -Foundation $foundation -Record $record -Network $record.network
    if ($Observation.executions.Count -ne 1 -or $Observation.executions[0].name -cne $record.publication.name -or
        $Observation.executions[0].properties.status -cne 'Succeeded') { throw 'Gw0911gHotfix: publisher history or ongoing execution is not the exact completed baseline.' }
    if ($Observation.companionSha256 -cne (Get-GwHotfixHash (Join-Path $script:Baseline 'src\Gateway.Purview\Automation\Connect-PurviewTenant.ps1'))) {
        throw 'Gw0911gHotfix: served original companion drift.'
    }
    $null = Read-PurviewExecutorPackage -PackageDirectory $record.packageDirectory -ExpectedSourceFingerprint $script:Source
}

function New-GwHotfixTargets($Observation, $Candidate, [string]$AdminImage, [string]$PublisherImage) {
    if ($script:ExecutorOnly -and $AdminImage -cne $Observation.admin.properties.template.containers[0].image) {
        throw 'Gw0911gHotfix: executor-only generation cannot change Admin image.'
    }
    foreach ($pair in @(@($AdminImage,'gateway-admin'), @($PublisherImage,'gateway-purview-package-publisher'))) {
        if ($pair[0] -cnotmatch "^acrgw0911gdevdbilxu\.azurecr\.io/$($pair[1])@sha256:[0-9a-f]{64}$") {
            throw 'Gw0911gHotfix: only exact immutable images in the existing registry/repositories are allowed.'
        }
    }
    $result = Copy-GwHotfixObject $Observation
    $result.admin.properties.template.containers[0].image = $AdminImage
    $result.site.tags.purviewExecutionSourceFingerprint = $Candidate.sourceFingerprint
    $result.settings.WEBSITE_RUN_FROM_PACKAGE = 'https://stgw0911gdevdbilxu.blob.core.windows.net/purview-executor-packages/' + $Candidate.package.receipt.packageFileName
    $result.settings.Executor__RuntimeManifestDigest = $Candidate.package.receipt.runtimeManifestDigest
    $result.settings.Executor__Binding__ExecutionSourceFingerprint = $Candidate.sourceFingerprint
    $result.settings.Executor__Binding__PackageDigest = $Candidate.package.receipt.packageDigest
    $changes = @{ PurviewExecutor__Binding__ExecutionSourceFingerprint = $Candidate.sourceFingerprint
        PurviewExecutor__Binding__PackageDigest = $Candidate.package.receipt.packageDigest }
    foreach ($name in $changes.Keys) {
        $entries = @($result.worker.properties.template.containers[0].env | Where-Object name -CEQ $name)
        if ($entries.Count -ne 1 -or ($entries[0].Contains('secretRef') -and $entries[0].secretRef)) { throw 'Gw0911gHotfix: worker binding is missing/duplicated/secret-backed.' }
        $entries[0].value = $changes[$name]
    }
    $template = Copy-GwHotfixObject $Observation.publisher.properties.template
    $template.containers[0].image = $PublisherImage
    $changes = @{ PUBLISHER_EXECUTION_INTENT_ID = $script:Intent
        PUBLISHER_EXECUTION_SOURCE_FINGERPRINT = $Candidate.sourceFingerprint
        PUBLISHER_PACKAGE_DIGEST = $Candidate.package.receipt.packageDigest
        PUBLISHER_PACKAGE_BYTES = [string]$Candidate.package.receipt.packageBytes }
    foreach ($name in $changes.Keys) {
        $entries = @($template.containers[0].env | Where-Object name -CEQ $name)
        if ($entries.Count -ne 1) { throw 'Gw0911gHotfix: publisher binding is not exact.' }
        $entries[0].value = $changes[$name]
    }
    $null = ConvertTo-PurviewPublisherExecutionTemplate $template -JobTemplate
    $result.companionSha256 = $script:AutomationScripts['src/Gateway.Purview/Automation/Connect-PurviewTenant.ps1']
    return @{ resources = $result; executionTemplate = $template }
}

function New-GwHotfixPlan {
    $candidate = Get-GwHotfixCandidate
    Assert-GwHotfixPublisherContext $candidate
    if ($Generation -ceq 'GuidScripts') { $null = Get-GwHotfixAdminContext $candidate }
    $observation = Get-GwHotfixObservation
    Assert-GwHotfixOriginal $observation (Get-GwHotfixState)
    $build = Read-GwHotfixJson 'build-result.json'
    $plan = @{ schemaVersion = 1; intentId = $script:Intent; subscriptionId = $script:Subscription; tenantId = $script:Tenant
        operatorObjectId = $script:Operator; acceptedStateSha256 = $script:StateHash
        implementationSha256 = Get-GwHotfixHash $PSCommandPath
        originalSourceFingerprint = $script:Source
        buildOperations = @(
            @{ registry = 'acrgw0911gdevdbilxu'; repository = 'gateway-admin'; tag = Get-GwHotfixBuildTag admin; dockerfile = 'src/Gateway.AdminUi/Dockerfile' },
            @{ registry = 'acrgw0911gdevdbilxu'; repository = 'gateway-purview-package-publisher'; tag = Get-GwHotfixBuildTag publisher; dockerfile = 'src/Gateway.Purview.PackagePublisher/Dockerfile'; payloadDigest = $candidate.package.receipt.packageDigest }
        )
        meteredCostScope = 'Two builds in the existing ACR; one existing 0.5-vCPU/1Gi publisher execution, maximum 660 seconds; no new recurring resources. Actual task duration is metered.'
        sourceFingerprint = $candidate.sourceFingerprint; packageReceipt = $candidate.package.receipt
        scriptProof = $candidate.scriptProof; original = $observation
        stage = if ($null -eq $build) { 'Build' } else { 'Promote' } }
    if ($script:ExecutorOnly) {
        $plan.generation = $Generation
        $plan.baselinePlanFingerprint = $script:PreviousPlanFingerprint
        $plan.baselineExecutionSourceFingerprint = $script:SeedSource
        $plan.sourceProof = $candidate.sourceProof
        $plan.buildOperations = @($plan.buildOperations | Where-Object repository -CEQ 'gateway-purview-package-publisher')
        $plan.meteredCostScope = 'One build in the existing ACR; one existing 0.5-vCPU/1Gi publisher execution, maximum 660 seconds; no new recurring resources.'
        $startup = Read-GwHotfixJson 'local-startup-verified.json'
        if (-not $startup -or $startup.packageDigest -cne $candidate.package.receipt.packageDigest -or
            $startup.sourceFingerprint -cne $candidate.sourceFingerprint -or $startup.localAuthPipelineStatus -ne 401 -or
            $startup.ambientModuleCount -lt 2) { throw 'Gw0911gHotfix: final package startup with ambient duplicates has not been proven.' }
        $plan.localStartup = $startup
        if ($Generation -ceq 'ExecutorStartupDiagnostics') {
            $failure = Read-GwHotfixJson 'local-diagnostic-failure-verified.json'
            $validator = Join-Path $script:Root 'operations\test-gw0911g-startup-diagnostic-package.ps1'
            if (-not $failure -or $failure.packageDigest -cne $candidate.package.receipt.packageDigest -or
                $failure.sourceFingerprint -cne $candidate.sourceFingerprint -or
                $failure.hookSha256 -cne $candidate.diagnosticHookSha256 -or
                $failure.validationScriptSha256 -cne (Get-GwHotfixHash $validator) -or
                $failure.diagnosticRepeats -ne 1 -or $failure.originalFailurePreserved -ne $true -or
                $failure.ambientHookReplaced -ne $true) { throw 'Gw0911gHotfix: final-byte fail-closed diagnostic proof is missing or changed.' }
            $plan.localDiagnosticFailure = $failure
            $plan.diagnosticHookSha256 = $candidate.diagnosticHookSha256
            $plan.purpose = 'Fail-closed startup diagnostics only; one later worker-MI probe and safe Event Viewer markers, no tenant connections or readiness inferred from diagnostics.'
        }
        if ($Generation -cin @('ConsoleFreePowerShell','ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) {
            $detached = Read-GwHotfixJson 'local-detached-verified.json'
            $validator = Join-Path $script:Root 'operations\test-gw0911g-consolefree-detached.py'
            if (-not $detached -or $detached.packageDigest -cne $candidate.package.receipt.packageDigest -or
                $detached.sourceFingerprint -cne $candidate.sourceFingerprint -or
                $detached.manifestDigest -cne $candidate.package.receipt.runtimeManifestDigest -or
                $detached.validatorSha256 -cne (Get-GwHotfixHash $validator) -or
                $detached.creationFlags -ne 520 -or $detached.consoleFreeSucceeded -ne $true -or
                $detached.consoleUnavailable -ne $true) { throw 'Gw0911gHotfix: exact final detached-child proof is missing or changed.' }
            $plan.consoleFreeAssets = $candidate.consoleFreeAssets
            $plan.localDetached = $detached
            $plan.purpose = 'Console-free disposable PowerShell SDK child remediation; actual matching worker-MI health must pass before any new parent-authorized tenant connection.'
            if ($Generation -ceq 'ConnectionDiagnostics') {
                $plan.purpose = 'Five-minute fixed-category verification failure observation on existing WorkerOnly private health; no provider output, secrets, readiness bypass, or policy writes.'
            }
            if ($Generation -ceq 'ProviderStageDiagnostics') {
                $plan.purpose = 'Fixed bounded provider-stage failure marker only; all verification checks, exact console-free child, and verified WEBSITE_LOAD_USER_PROFILE=1 amendment preserved.'
                $plan.profileSettingAmendmentReceiptSha256 = '45386e8f218f2cbfc2f177c095ef0119aeef2f5f829cc7ced8aae9f929c95ccd'
            }
            if ($Generation -ceq 'ProviderErrorDiagnostics') {
                $plan.purpose = 'Bounded allowlisted category/type/HRESULT/code from the original fatal provider failure; no raw provider text, token, identity or certificate changes; exact existing console-free child preserved.'
            }
            if ($Generation -ceq 'PrivateEomWorkspace') {
                $plan.purpose = 'Supported EOM module/log paths confined to the existing private operation directory; fixed denial-site diagnostic codes; no role, identity, certificate, signed runtime, child, or authority-check changes.'
            }
            if ($Generation -ceq 'BoundedEomImports') {
                $plan.purpose = 'Import only required remote cmdlets (3/10/8), retain strict command checks and 230s bounded IIS request budget; unchanged signed engine/EOM/child, identities, permissions and SKU.'
            }
            if ($Generation -ceq 'LocationArrays') {
                $plan.purpose = 'Preserve required top-level Locations JSON arrays for singleton KYD/DLP create/update paths; unchanged scope, thresholds, approvals, signed runtime, child, identities, permissions, latest Admin/worker images and B2 capacity.'
                $plan.containerAmendmentReceiptSha256 = 'c968a7e1a4ef6793b70288f186cebe505f243a5fcdca68b85955515e7ec2e563'
                $plan.capacityReceiptSha256 = '9f3d3b59f5ce4607727956570cd22c346a9044782a809427bb26c80a3c624b77'
            }
            if ($Generation -ceq 'SettingsReadDiagnostics') {
                $plan.purpose = 'Five-minute fixed Settings failure stage/type/schema/category/HRESULT diagnostics on existing WorkerOnly private health; no raw provider content, mutation changes, relaxed checks or credential extraction.'
                $plan.capacityReceiptSha256 = '9f3d3b59f5ce4607727956570cd22c346a9044782a809427bb26c80a3c624b77'
            }
            if ($Generation -ceq 'ProviderReadbackMetadata') {
                $plan.purpose = 'Strict compatibility with observed provider tenant-inclusion and operational metadata; exact constraints, internal bindings, modes and scope validated; no blanket property acceptance or new policy mutation authority.'
                $plan.capacityReceiptSha256 = '9f3d3b59f5ce4607727956570cd22c346a9044782a809427bb26c80a3c624b77'
            }
            if ($Generation -ceq 'ProviderRuleRepresentation') {
                $plan.purpose = 'Validate matching canonical single-content-predicate and flat SIT projections, explicit thresholds, timestamp-only metadata and inert defaults; reject added rules/conditions/actions; suppress only nonterminating rule mutation warnings before independent exact readback.'
                $plan.capacityReceiptSha256 = '9f3d3b59f5ce4607727956570cd22c346a9044782a809427bb26c80a3c624b77'
            }
            if ($Generation -ceq 'KydProviderMode') {
                $plan.purpose = 'Use native Enable for legacy AuditOnly/Enforce collection choices; preserve independent DLP simulation modes, exact fixed Group/SIT scope, provider-ID update authority and all readback checks.'
                $plan.capacityReceiptSha256 = '9f3d3b59f5ce4607727956570cd22c346a9044782a809427bb26c80a3c624b77'
            }
        }
    }
    if ($build) {
        $plan.build = $build
        $adminImage = if ($script:ExecutorOnly) { $observation.admin.properties.template.containers[0].image } else { $build.admin }
        $plan.target = New-GwHotfixTargets $observation $candidate $adminImage $build.publisher
        $correction = $null
        if (Test-Path -LiteralPath (Join-Path $script:Work 'promote-predispatch-blocked.json')) {
            if (Test-Path -LiteralPath (Join-Path $script:Work 'publisher-http-dispatch.json')) {
                throw 'Gw0911gHotfix: cannot replan after corrected HTTP dispatch; reconcile the retained approved Plan.'
            }
            $plan.preDispatchCorrection = Get-GwHotfixTokenCorrection
            $saved = Read-GwHotfixJson 'arm-token-predispatch-correction.json'
            if ($saved) { Assert-GwHotfixEqual $saved $plan.preDispatchCorrection 'retained token correction' }
            else { Save-GwHotfixJson 'arm-token-predispatch-correction.json' $plan.preDispatchCorrection }
            $correction = Assert-GwHotfixCorrectedPlan $plan
        }
        Assert-GwHotfixBuiltImages $build $candidate $correction
    }
    $name = "plan-$((Get-BootstrapObjectFingerprint $plan).Substring(7)).json"
    $existing = Read-GwHotfixJson $name
    if ($existing) { Assert-GwHotfixEqual $existing $plan 'retained plan' } else { Save-GwHotfixJson $name $plan }
    return @{ plan = $name; approvalFingerprint = Get-BootstrapObjectFingerprint $plan; stage = $plan.stage }
}

function Get-GwHotfixBuildTag([ValidateSet('admin','publisher')][string]$Name) {
    $suffix = if ($Name -ceq 'admin') { 'adminui' } else { 'publisher' }
    return "maintenance-$($script:Intent.Replace('-','').Substring(0,24))-$suffix"
}

function Assert-GwHotfixBuiltImages($Build, $Candidate, [AllowNull()]$Correction = $null) {
        if ($Build.buildPlanFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            $Build.sourceFingerprint -cne $Candidate.sourceFingerprint -or
            $Build.packageReceiptFingerprint -cne $Candidate.package.receiptFingerprint) { throw 'Gw0911gHotfix: built artifact authority drift.' }
        $buildPlan = Read-GwHotfixJson "plan-$($Build.buildPlanFingerprint.Substring(7)).json"
        $expectedImplementation = Get-GwHotfixHash $PSCommandPath
        if ($Correction) {
            Assert-GwHotfixEqual $Correction (Get-GwHotfixTokenCorrection) 'fixed build reuse correction'
            if ($Build.buildPlanFingerprint -cne $Correction.oldBuildPlanFingerprint) { throw 'Gw0911gHotfix: correction cannot adopt other builds.' }
            $expectedImplementation = $Correction.oldImplementationSha256
        }
        if (-not $buildPlan -or (Get-BootstrapObjectFingerprint $buildPlan) -cne $Build.buildPlanFingerprint -or
            $buildPlan.stage -cne 'Build' -or $buildPlan.implementationSha256 -cne $expectedImplementation) {
            throw 'Gw0911gHotfix: build plan authority is missing or changed.'
        }
        foreach ($name in @(Get-GwHotfixBuildNames)) {
            $repository = if ($name -ceq 'admin') { 'gateway-admin' } else { 'gateway-purview-package-publisher' }
            $tag = Get-GwHotfixBuildTag $name
            $reader = @{ Registry = 'acrgw0911gdevdbilxu'; Repository = $repository; Tag = $tag; TagContract = 'MaintenanceV1' }
            $intent = Read-GwHotfixJson "$name-build-intent.json"
            Assert-GwHotfixEqual $intent @{ planFingerprint = $Build.buildPlanFingerprint; repository = $repository; tag = $tag
                sourceFingerprint = $Candidate.sourceFingerprint; packageDigest = $Candidate.package.receipt.packageDigest } 'build ownership'
            $runs = @(Get-GatewayAcrExactImageRuns @reader)
            if ($runs.Count -ne 1 -or $runs[0].runId -cne $Build["${name}RunId"]) { throw 'Gw0911gHotfix: exact build history drift.' }
            $run = Get-GatewayAcrExactRunById @reader -RunId $Build["${name}RunId"]
            $null = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository $repository -Tag $tag -TagContract MaintenanceV1
            $digest = @($run.outputImages)[0].digest
            if ($Build[$name] -cne "acrgw0911gdevdbilxu.azurecr.io/$repository@$digest") { throw 'Gw0911gHotfix: image/run binding drift.' }
            $found = Get-GatewayAcrExactTagDigest @reader
            if ($found.digest -cne $digest) { throw 'Gw0911gHotfix: immutable tag binding drift.' }
        }
}

function Copy-GwHotfixExecutionForComparison($Execution) {
    $copy = Copy-GwHotfixObject $Execution
    foreach ($name in @('startTime','endTime')) {
        if ($copy.properties.Contains($name) -and $null -ne $copy.properties[$name]) {
            $value = [string]$copy.properties[$name]
            if ($value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
                throw 'Gw0911gHotfix: provider execution timestamp is not an ISO instant.'
            }
            $copy.properties[$name] = [DateTimeOffset]::Parse($value,
                [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime().ToString('O')
        }
    }
    return $copy
}
function Get-GwHotfixPublisherResult($Plan, $Executions) {
    $oldNames = @($Plan.original.executions.name)
    foreach ($old in $Plan.original.executions) {
        $found = @($Executions | Where-Object name -CEQ $old.name)
        if ($found.Count -ne 1) { throw 'Gw0911gHotfix: original publisher history disappeared.' }
        if ($Generation -cin @('ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) {
            Assert-GwHotfixEqual (Copy-GwHotfixExecutionForComparison $found[0]) `
                (Copy-GwHotfixExecutionForComparison $old) 'original publisher execution'
        } else {
            Assert-GwHotfixEqual $found[0] $old 'original publisher execution'
        }
    }
    $new = @($Executions | Where-Object { $_.name -cnotin $oldNames })
    if ($new.Count -eq 0) { return $null }
    if ($new.Count -ne 1) { throw 'Gw0911gHotfix: unknown or duplicate publisher execution; never replay.' }
    $execution = Invoke-AzJson -Arguments @('containerapp','job','execution','show','--subscription',$script:Subscription,
        '--resource-group','rg-gw0911g-dev','--name','job-gw0911g-purview-package-dev','--job-execution-name',$new[0].name)
    if (-not ([string]$execution.id).Equals("$(Get-GwHotfixResourceId publisher)/executions/$($new[0].name)", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Gw0911gHotfix: foreign publisher execution readback.'
    }
    Assert-GwHotfixEqual (ConvertTo-PurviewPublisherExecutionTemplate $execution.properties.template) `
        (ConvertTo-PurviewPublisherExecutionTemplate $Plan.target.executionTemplate -JobTemplate) 'publisher final execution template'
    if ($execution.properties.status -cne 'Succeeded') { throw 'Gw0911gHotfix: publisher pending/failed/unknown; reconcile only, never restart.' }
    return @{ executionId = $execution.id; templateFingerprint = Get-BootstrapObjectFingerprint $Plan.target.executionTemplate
        packageDigest = $Plan.packageReceipt.packageDigest }
}

function ConvertTo-GwHotfixStartBody($Template) {
    $null = ConvertTo-PurviewPublisherExecutionTemplate $Template -JobTemplate
    $body = Copy-GwHotfixObject $Template
    $body.Remove('volumes')
    foreach ($container in $body.containers) {
        $container.Remove('probes')
        $container.Remove('volumeMounts')
    }
    $null = ConvertTo-PurviewPublisherExecutionTemplate $body
    return $body
}

function Invoke-GwHotfixBuild($Plan) {
    $candidate = Get-GwHotfixCandidate
    Assert-GwHotfixPublisherContext $candidate
    $result = @{ buildPlanFingerprint = Get-BootstrapObjectFingerprint $Plan
        sourceFingerprint = $candidate.sourceFingerprint; packageReceiptFingerprint = $candidate.package.receiptFingerprint }
    foreach ($name in @(Get-GwHotfixBuildNames)) {
        $repository = if ($name -ceq 'admin') { 'gateway-admin' } else { 'gateway-purview-package-publisher' }
        $tag = Get-GwHotfixBuildTag $name
        $reader = @{ Registry = 'acrgw0911gdevdbilxu'; Repository = $repository; Tag = $tag; TagContract = 'MaintenanceV1' }
        $dispatchName = "$name-build-intent.json"
        $intent = @{ planFingerprint = Get-BootstrapObjectFingerprint $Plan; repository = $repository; tag = $tag
            sourceFingerprint = $candidate.sourceFingerprint; packageDigest = $candidate.package.receipt.packageDigest }
        $retained = Read-GwHotfixJson $dispatchName
        $runs = @(Get-GatewayAcrExactImageRuns @reader)
        if ($retained) { Assert-GwHotfixEqual $retained $intent 'build intent' }
        elseif ($runs.Count) { throw 'Gw0911gHotfix: unowned exact-tag ACR run.' }
        else {
            $context = if ($name -ceq 'admin') {
                Get-GwHotfixAdminContext $candidate
            } else { Join-Path $candidate.directory '.bootstrap\publisher-context' }
            $file = if ($name -ceq 'admin') { 'src/Gateway.AdminUi/Dockerfile' } else { 'src/Gateway.Purview.PackagePublisher/Dockerfile' }
            Save-GwHotfixJson $dispatchName $intent
            $run = Invoke-AzJson -CaptureStdoutOnly -Arguments @('acr','build','--subscription',$script:Subscription,
                '--registry','acrgw0911gdevdbilxu','--image',"${repository}:$tag",'--file',$file,$context,'--no-logs',
                '--query','{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}}')
            $null = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository $repository -Tag $tag -TagContract MaintenanceV1
            $runs = @(Get-GatewayAcrExactImageRuns @reader)
        }
        if ($runs.Count -ne 1) { throw 'Gw0911gHotfix: unknown ACR outcome; no repeat build.' }
        $run = Get-GatewayAcrExactRunById @reader -RunId $runs[0].runId
        $null = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository $repository -Tag $tag -TagContract MaintenanceV1
        $digest = @($run.outputImages)[0].digest
        $found = Get-GatewayAcrExactTagDigest @reader
        if ($found.digest -cne $digest) { throw 'Gw0911gHotfix: build/tag digest mismatch.' }
        $result[$name] = "acrgw0911gdevdbilxu.azurecr.io/$repository@$digest"
        $result["${name}RunId"] = $run.runId
    }
    $saved = Read-GwHotfixJson 'build-result.json'
    if ($saved) { Assert-GwHotfixEqual $saved $result 'build result' } else { Save-GwHotfixJson 'build-result.json' $result }
    return 'Build complete. Run Plan again; Promote requires a new artifact-bound approval.'
}
function Invoke-GwHotfixApply([ValidateSet('Build','Promote')][string]$Stage, [string]$ApprovalFingerprint) {
    Assert-GwHotfixOperator
    $candidate = Get-GwHotfixCandidate
    if ($ApprovalFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Gw0911gHotfix: canonical approval fingerprint required.' }
    $plan = Read-GwHotfixJson "plan-$($ApprovalFingerprint.Substring(7)).json"
    if (-not $plan -or $plan.implementationSha256 -cne (Get-GwHotfixHash $PSCommandPath) -or
        (Get-BootstrapObjectFingerprint $plan) -cne $ApprovalFingerprint -or $plan.stage -cne $Stage) {
        throw 'Gw0911gHotfix: exact independently reviewed Plan approval is required.'
    }
    $planGeneration = if ($plan.Contains('generation')) { [string]$plan.generation } else { 'GuidScripts' }
    if ($planGeneration -cne $Generation) {
        throw 'Gw0911gHotfix: Plan is from another fixed generation.'
    }
    Assert-GwHotfixEqual $candidate.package.receipt $plan.packageReceipt 'approved package'
    if ($Stage -ceq 'Build') {
        $current = Get-GwHotfixObservation
        Assert-GwHotfixOriginal $current (Get-GwHotfixState)
        Assert-GwHotfixEqual $current $plan.original 'pre-build resources'
        return Invoke-GwHotfixBuild $plan
    }
    $correction = if ($plan.Contains('preDispatchCorrection')) { Assert-GwHotfixCorrectedPlan $plan } else { $null }
    Assert-GwHotfixBuiltImages $plan.build $candidate $correction
    $adminImage = if ($script:ExecutorOnly) { $plan.original.admin.properties.template.containers[0].image } else { $plan.build.admin }
    Assert-GwHotfixEqual (New-GwHotfixTargets $plan.original $candidate $adminImage $plan.build.publisher) $plan.target 'derived target'
    $approval = @{ fingerprint = $ApprovalFingerprint }
    $approvalName = if ($correction) { 'promote-corrected-approval.json' } else { 'promote-approval.json' }
    $approved = Read-GwHotfixJson $approvalName
    if ($approved) { Assert-GwHotfixEqual $approved $approval 'promotion approval' } else { Save-GwHotfixJson $approvalName $approval }
    $current = Get-GwHotfixObservation
    foreach ($name in @('api','publisher')) { Assert-GwHotfixEqual $current[$name] $plan.original[$name] "$name preservation" }
    $publishIntent = @{ planFingerprint = if ($correction) { $correction.oldPlanFingerprint } else { $ApprovalFingerprint }; template = $plan.target.executionTemplate
        originalExecutions = $plan.original.executions; jobId = Get-GwHotfixResourceId publisher }
    $retained = Read-GwHotfixJson 'publisher-intent.json'
    if ($correction -and -not $retained) { throw 'Gw0911gHotfix: correction requires the unchanged original publisher intent.' }
    if (-not $retained) {
        Assert-GwHotfixOriginal $current (Get-GwHotfixState)
        Assert-GwHotfixEqual $current $plan.original 'pre-publisher resources'
        $startBody = ConvertTo-GwHotfixStartBody $plan.target.executionTemplate
        Save-GwHotfixJson 'publisher-intent.json' $publishIntent
        $null = Invoke-GwHotfixArm start POST $startBody
    } else {
        Assert-GwHotfixEqual $retained $publishIntent 'publisher intent'
        if ($correction) {
            $dispatch = Read-GwHotfixJson 'publisher-http-dispatch.json'
            if (-not $dispatch) {
                Assert-GwHotfixEqual $current $plan.original 'known-not-submitted original resources'
                $null = Invoke-GwHotfixArm start POST (ConvertTo-GwHotfixStartBody $plan.target.executionTemplate) -CorrectionPlan $plan
            } else {
                Assert-GwHotfixEqual $dispatch @{
                    planFingerprint = $ApprovalFingerprint; correctionFingerprint = Get-BootstrapObjectFingerprint $correction
                    retainedIntentSha256 = $correction.publisherIntentSha256; executionIntentId = $script:Intent
                    bodyFingerprint = Get-BootstrapObjectFingerprint (ConvertTo-GwHotfixStartBody $plan.target.executionTemplate)
                    jobId = Get-GwHotfixResourceId publisher
                } 'corrected HTTP dispatch ownership'
            }
        }
    }
    $publication = Get-GwHotfixPublisherResult $plan @(Get-GwHotfixExecutions)
    if (-not $publication) { throw 'Gw0911gHotfix: publisher response unknown; retain intent and reconcile only. No replay.' }
    $saved = Read-GwHotfixJson 'publisher-result.json'
    if ($saved) { Assert-GwHotfixEqual $saved $publication 'publication' } else { Save-GwHotfixJson 'publisher-result.json' $publication }
    foreach ($name in @(Get-GwHotfixMutationNames)) {
        $current = Get-GwHotfixObservation
        $null = Get-GwHotfixPublisherResult $plan $current.executions
        # Every resource is either at its exact approved old value or an owned checkpoint target.
        foreach ($check in @('settings','site','worker','admin')) {
            $checkpoint = Read-GwHotfixJson "$check-intent.json"
            $expected = if ($checkpoint) { $plan.target.resources[$check] } else { $plan.original[$check] }
            Assert-GwHotfixEqual $current[$check] $expected "$check pre-promotion"
        }
        foreach ($check in @('api','publisher')) { Assert-GwHotfixEqual $current[$check] $plan.original[$check] "$check preservation" }
        $intent = @{ planFingerprint = $ApprovalFingerprint; target = $plan.target.resources[$name] }
        $saved = Read-GwHotfixJson "$name-intent.json"
        if ($saved) { Assert-GwHotfixEqual $saved $intent "$name intent"; continue }
        Save-GwHotfixJson "$name-intent.json" $intent
        $body = switch ($name) {
            settings { @{ properties = $plan.target.resources.settings } }
            site { @{ tags = $plan.target.resources.site.tags } }
            default { @{ properties = @{ template = $plan.target.resources[$name].properties.template } } }
        }
        $method = if ($name -ceq 'settings') { 'PUT' } else { 'PATCH' }
        $null = Invoke-GwHotfixArm $name $method $body
    }
    return Test-GwHotfixRelease
}
function Test-GwHotfixRelease {
    $candidate = Get-GwHotfixCandidate
    $approval = Read-GwHotfixJson 'promote-corrected-approval.json'
    if (-not $approval) { $approval = Read-GwHotfixJson 'promote-approval.json' }
    if (-not $approval -or $approval.fingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Gw0911gHotfix: no exact promotion approval.' }
    $plan = Read-GwHotfixJson "plan-$($approval.fingerprint.Substring(7)).json"
    if (-not $plan) { throw 'Gw0911gHotfix: no promoted artifact plan.' }
    if ((Get-BootstrapObjectFingerprint $plan) -cne $approval.fingerprint -or
        $plan.implementationSha256 -cne (Get-GwHotfixHash $PSCommandPath)) { throw 'Gw0911gHotfix: verification authority drift.' }
    $correction = if ($plan.Contains('preDispatchCorrection')) { Assert-GwHotfixCorrectedPlan $plan } else { $null }
    Assert-GwHotfixBuiltImages $plan.build $candidate $correction
    Assert-GwHotfixEqual $candidate.package.receipt $plan.packageReceipt 'verified package'
    $adminImage = if ($script:ExecutorOnly) { $plan.original.admin.properties.template.containers[0].image } else { $plan.build.admin }
    Assert-GwHotfixEqual (New-GwHotfixTargets $plan.original $candidate $adminImage $plan.build.publisher) $plan.target 'verified target'
    foreach ($name in @(Get-GwHotfixMutationNames)) {
        $intent = Read-GwHotfixJson "$name-intent.json"
        if (-not $intent) { throw 'Gw0911gHotfix: target has no owned dispatch intent.' }
        Assert-GwHotfixEqual $intent @{ planFingerprint = Get-BootstrapObjectFingerprint $plan; target = $plan.target.resources[$name] } 'owned target'
    }
    if (-not (Read-GwHotfixJson 'publisher-intent.json')) { throw 'Gw0911gHotfix: publisher intent missing.' }
    if ($correction) {
        Assert-GwHotfixEqual (Read-GwHotfixJson 'publisher-http-dispatch.json') @{
            planFingerprint = Get-BootstrapObjectFingerprint $plan; correctionFingerprint = Get-BootstrapObjectFingerprint $correction
            retainedIntentSha256 = $correction.publisherIntentSha256; executionIntentId = $script:Intent
            bodyFingerprint = Get-BootstrapObjectFingerprint (ConvertTo-GwHotfixStartBody $plan.target.executionTemplate)
            jobId = Get-GwHotfixResourceId publisher
        } 'verified corrected HTTP dispatch'
    }
    $current = Get-GwHotfixObservation
    foreach ($name in @('settings','site','worker','admin','api','publisher','companionSha256')) {
        Assert-GwHotfixEqual $current[$name] $plan.target.resources[$name] "$name final readback"
    }
    $publication = Get-GwHotfixPublisherResult $plan $current.executions
    if (-not $publication) { throw 'Gw0911gHotfix: publication not proven.' }
    $result = @{ artifactStatus = 'Verified'; runtimeReadiness = 'NotClaimed'; tenantReadiness = 'NotClaimed'
        planFingerprint = Get-BootstrapObjectFingerprint $plan; publication = $publication
        finalScriptBytes = $candidate.scriptProof; acceptedStateSha256 = Get-GwHotfixHash (Join-Path $script:Baseline ".bootstrap\state\$script:Subscription-rg-gw0911g-dev-dev.json") }
    $saved = Read-GwHotfixJson 'verified.json'
    if ($saved) { Assert-GwHotfixEqual $saved $result 'final receipt' } else { Save-GwHotfixJson 'verified.json' $result }
    return $result
}
function Get-GwHotfixArmToken {
    # Azure CLI accepts one account selector, not --subscription plus --tenant.
    $token = Invoke-AzJson -Arguments @('account','get-access-token','--subscription',$script:Subscription,
        '--resource','https://management.azure.com/',
        '--query','{accessToken:accessToken,subscription:subscription,tenant:tenant,tokenType:tokenType,expires_on:expires_on}')
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($token.subscription -cne $script:Subscription -or $token.tenant -cne $script:Tenant -or
            $token.tokenType -cne 'Bearer' -or $token.accessToken -isnot [string] -or
            $token.accessToken.Length -gt 32768 -or
            ($token.expires_on -isnot [long] -and $token.expires_on -isnot [int]) -or $token.expires_on -le $now + 120) { throw 'invalid' }
        $parts = $token.accessToken.Split('.')
        if ($parts.Count -ne 3 -or $parts[1] -cnotmatch '^[A-Za-z0-9_-]+$') { throw 'invalid' }
        $payload = $parts[1].Replace('-','+').Replace('_','/')
        $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable
        # ARM verifies the signature. Local checks bind the trusted CLI token to
        # the operator, requested audience and freshness before any HTTP write.
        if ($claims.aud -cne 'https://management.azure.com/' -or $claims.tid -cne $script:Tenant -or
            $claims.oid -cne $script:Operator -or
            ($claims.exp -isnot [long] -and $claims.exp -isnot [int]) -or
            ($claims.nbf -isnot [long] -and $claims.nbf -isnot [int]) -or
            $claims.exp -le $now + 120 -or $claims.nbf -gt $now + 30 -or
            [Math]::Abs([long]$claims.exp - [long]$token.expires_on) -gt 60) { throw 'invalid' }
        return $token
    } catch {
        $token = $null
        throw 'Gw0911gHotfix: ARM token tenant/subscription/operator/audience/expiry validation failed; no HTTP dispatch.'
    } finally { $claims = $null; $parts = $null; $payload = $null }
}

function Get-GwHotfixTokenCorrection {
    $pins = [ordered]@{
        'pre-token-correction.psm1' = 'e6966da77ecf513d70342b3d833253ba04e7a0aa6b1e738bfaf9249cbf1cbc3b'
        'publisher-intent.json' = '84245fc1b6fe53c03e43b0da5f0ddb1677c963457636dfcb8177b807f476440e'
        'promote-approval.json' = '091ffb7ddcc713c36d57c621c54ee2bca44c66c9f29c68676e570bf4a5f2bf9d'
        'promote-predispatch-blocked.json' = '0dfa4bec3497283fd1cf68418b09472620934a1d15990a65c196be50e7858bb8'
        'promote-approved.log' = '42a4494551f014e8bb3824d1a2c48362e62a298cfee8f54276892f8edf7bd29c'
    }
    foreach ($entry in $pins.GetEnumerator()) {
        if ((Get-GwHotfixHash (Join-Path $script:Work $entry.Key)) -cne $entry.Value) { throw 'Gw0911gHotfix: known-not-submitted evidence bytes changed.' }
    }
    $old = Read-GwHotfixJson 'plan-2af2533deb28dbdc873d56da09015fdf4b6e9cf44583f4ca1260dc9927aa54f7.json'
    if ((Get-BootstrapObjectFingerprint $old) -cne 'sha256:2af2533deb28dbdc873d56da09015fdf4b6e9cf44583f4ca1260dc9927aa54f7' -or
        $old.implementationSha256 -cne $pins['pre-token-correction.psm1']) { throw 'Gw0911gHotfix: original promotion authority changed.' }
    $proof = Read-GwHotfixJson 'promote-predispatch-blocked.json'
    if ($proof.status -cne 'BlockedBeforePublisherHttpDispatch' -or $proof.httpDispatchReached -ne $false -or
        $proof.newPublisherExecutions -ne 0 -or $proof.nativeError -cne 'Please specify only one of subscription and tenant, not both') {
        throw 'Gw0911gHotfix: unknown outcomes never authorize this correction.'
    }
    Assert-GwHotfixEqual (Read-GwHotfixJson 'publisher-intent.json') @{
        planFingerprint = Get-BootstrapObjectFingerprint $old; template = $old.target.executionTemplate
        originalExecutions = $old.original.executions; jobId = Get-GwHotfixResourceId publisher
    } 'original publication intent'
    return @{
        schemaVersion = 1; kind = 'Gw0911gArmSelectorKnownNotSubmitted'
        oldPlanFingerprint = Get-BootstrapObjectFingerprint $old
        oldImplementationSha256 = $old.implementationSha256
        newImplementationSha256 = Get-GwHotfixHash $PSCommandPath
        oldBuildPlanFingerprint = $old.build.buildPlanFingerprint
        publisherIntentSha256 = $pins['publisher-intent.json']
        publisherIntentFingerprint = $proof.publisherIntentFingerprint
        proofSha256 = $pins['promote-predispatch-blocked.json']; failureLogSha256 = $pins['promote-approved.log']
        oldApprovalSha256 = $pins['promote-approval.json']; executionIntentId = $script:Intent
        httpDispatchesAllowed = 1; packageDigest = $old.packageReceipt.packageDigest
        adminImage = $old.build.admin; publisherImage = $old.build.publisher
    }
}

function Assert-GwHotfixCorrectedPlan($Plan) {
    $expected = Get-GwHotfixTokenCorrection
    Assert-GwHotfixEqual $Plan.preDispatchCorrection $expected 'fixed correction authority'
    Assert-GwHotfixEqual (Read-GwHotfixJson 'arm-token-predispatch-correction.json') $expected 'fixed correction receipt'
    $original = Copy-GwHotfixObject $Plan
    $original.Remove('preDispatchCorrection')
    $original.implementationSha256 = $expected.oldImplementationSha256
    if ((Get-BootstrapObjectFingerprint $original) -cne $expected.oldPlanFingerprint -or
        $Plan.implementationSha256 -cne $expected.newImplementationSha256) {
        throw 'Gw0911gHotfix: corrected Plan changed something other than the token adapter correction.'
    }
    return $expected
}

function Get-GwHotfixBuildNames {
    if ($script:ExecutorOnly) { return 'publisher' }
    return @('admin','publisher')
}

function Get-GwHotfixMutationNames {
    if ($script:ExecutorOnly) { return @('settings','site','worker') }
    return @('settings','site','worker','admin')
}

function Get-GwHotfixPreviousPlan {
    $path = Join-Path $script:PreviousWork "plan-$($script:PreviousPlanFingerprint.Substring(7)).json"
    $previous = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    if ((Get-BootstrapObjectFingerprint $previous) -cne $script:PreviousPlanFingerprint) {
        throw 'Gw0911gHotfix: previous verified generation Plan changed.'
    }
    $receiptPath = Join-Path $script:PreviousWork 'verified.json'
    if ((Get-GwHotfixHash $receiptPath) -cne $script:PreviousReceiptHash) {
        throw 'Gw0911gHotfix: previous artifact verification receipt changed.'
    }
    $previous.verified = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    if ($previous.verified.artifactStatus -cne 'Verified' -or $previous.sourceFingerprint -cne $script:SeedSource) {
        throw 'Gw0911gHotfix: previous artifact generation is not the admitted baseline.'
    }
    return $previous
}

function Get-GwHotfixExpectedManifest {
    $manifest = @(Get-BootstrapSourceManifest -Root $script:SeedRoot)
    if ((Get-BootstrapObjectFingerprint $manifest) -cne $script:SeedSource) { throw 'Gw0911gHotfix: frozen seed source drift.' }
    if ($script:ExecutorOnly) { $null = Get-GwHotfixPreviousPlan }
    $hashes = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($file in $manifest) { $hashes.Add($file.path, $file.sha256) }
    foreach ($path in $script:Delta.Keys) { $hashes[$path] = $script:Delta[$path] }
    [string[]]$paths = @($hashes.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    foreach ($path in $paths) { [ordered]@{ path = $path; sha256 = $hashes[$path] } }
}

function Test-GwHotfixFinalExecutorStartup($Candidate) {
    if (-not $script:ExecutorOnly) { throw 'Gw0911gHotfix: this local startup check is executor-generation only.' }
    $previous = Get-GwHotfixPreviousPlan
    $root = Join-Path $Candidate.directory '.bootstrap\hotfix-package\publish'
    $modulePath = (Join-Path $root 'PowerShellModules') + [IO.Path]::PathSeparator + (Join-Path $root 'PowerShell\Modules')
    $probe = [Diagnostics.ProcessStartInfo]::new((Join-Path $root 'PowerShell\pwsh.exe'))
    $probe.UseShellExecute = $false; $probe.CreateNoWindow = $true; $probe.RedirectStandardOutput = $true; $probe.RedirectStandardError = $true
    $probe.WorkingDirectory = $root; $probe.Environment['PSModulePath'] = $modulePath
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-Command','[Console]::Write(@(Get-Module -ListAvailable ExchangeOnlineManagement).Count)')) {
        $probe.ArgumentList.Add($arg)
    }
    $control = [Diagnostics.Process]::Start($probe)
    try {
        $stdout = $control.StandardOutput.ReadToEndAsync(); $stderr = $control.StandardError.ReadToEndAsync()
        if (-not $control.WaitForExit(60000)) { throw 'Gw0911gHotfix: ambient module control timed out.' }
        [int]$count = 0
        if ($control.ExitCode -ne 0 -or $stderr.GetAwaiter().GetResult().Length -ne 0 -or
            -not [int]::TryParse($stdout.GetAwaiter().GetResult(), [ref]$count) -or $count -lt 2) {
            throw 'Gw0911gHotfix: ambient duplicate control was not established.'
        }
    } finally { if (-not $control.HasExited) { $control.Kill($true); $control.WaitForExit() }; $control.Dispose() }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $root 'Gateway.Purview.Executor.exe'))
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true; $start.WorkingDirectory = $root
    foreach ($entry in $previous.target.resources.settings.GetEnumerator()) { $start.Environment[$entry.Key] = [string]$entry.Value }
    $start.Environment['Executor__Binding__ExecutionSourceFingerprint'] = $Candidate.sourceFingerprint
    $start.Environment['Executor__Binding__PackageDigest'] = $Candidate.package.receipt.packageDigest
    $start.Environment['Executor__RuntimeManifestDigest'] = $Candidate.package.receipt.runtimeManifestDigest
    $start.Environment['WEBSITE_RUN_FROM_PACKAGE'] = 'https://stgw0911gdevdbilxu.blob.core.windows.net/purview-executor-packages/' + $Candidate.package.receipt.packageFileName
    $start.Environment['ASPNETCORE_URLS'] = "http://127.0.0.1:$port"; $start.Environment['PSModulePath'] = $modulePath
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $deadline = [DateTime]::UtcNow.AddSeconds(210); $healthy = $false
        while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
            try {
                $response = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health/ready" -MaximumRedirection 0 -TimeoutSec 2 -SkipHttpErrorCheck
                if ([int]$response.StatusCode -eq 401) {
                    $connections = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop)
                    if ($connections.Count -eq 1 -and $connections[0].OwningProcess -eq $process.Id) { $healthy = $true; break }
                }
            } catch {}
            Start-Sleep -Seconds 1
        }
        if (-not $healthy) {
            $code = if ($process.HasExited) { $process.ExitCode } else { 'Timeout' }
            throw "Gw0911gHotfix: final packaged startup did not reach its own auth pipeline ($code); no raw diagnostics emitted."
        }
        $evidence = @{ sourceFingerprint = $Candidate.sourceFingerprint; packageDigest = $Candidate.package.receipt.packageDigest
            runtimeManifestDigest = $Candidate.package.receipt.runtimeManifestDigest; ambientModuleCount = $count
            localAuthPipelineStatus = 401; executableSha256 = Get-GwHotfixHash $start.FileName
            scope = 'Actual final published executor with full startup attestation; localhost anonymous 401 only, no provider operation or cloud readiness claim.' }
        Save-GwHotfixJson 'local-startup-verified.json' $evidence
        return $evidence
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

function Invoke-GwHotfixDiagnosticPackageValidation {
    if ($Generation -cne 'ExecutorStartupDiagnostics') { throw 'Gw0911gHotfix: diagnostic validation is fixed-generation only.' }
    if (Read-GwHotfixJson 'local-diagnostic-failure-verified.json') { return }
    $pwsh = Join-Path $script:Root '.maintenance\dependencies\powershell-7.6.5\runtime\pwsh.exe'
    & $pwsh -NoProfile -NonInteractive -File (Join-Path $script:Root 'operations\test-gw0911g-startup-diagnostic-package.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Gw0911gHotfix: final diagnostic package validation failed.' }
}

function Assert-GwHotfixConsoleFreeAssets($Candidate) {
    $previous = Get-GwHotfixPreviousPlan
    $oldPath = Join-Path $script:SeedRoot '.bootstrap\hotfix-package\publish\executor-runtime.json'
    $newRoot = Join-Path $Candidate.directory '.bootstrap\hotfix-package\publish'
    $newPath = Join-Path $newRoot 'executor-runtime.json'
    if ('sha256:' + (Get-GwHotfixHash $oldPath) -cne $previous.packageReceipt.runtimeManifestDigest -or
        'sha256:' + (Get-GwHotfixHash $newPath) -cne $Candidate.package.receipt.runtimeManifestDigest) {
        throw 'Gw0911gHotfix: old/new runtime manifest bytes changed.'
    }
    $old = Get-Content -LiteralPath $oldPath -Raw | ConvertFrom-Json -AsHashtable
    $new = Get-Content -LiteralPath $newPath -Raw | ConvertFrom-Json -AsHashtable
    $oldEngine = @($old.files | Where-Object { $_.path -cmatch '^PowerShell(?:Modules)?/' })
    $newEngine = @($new.files | Where-Object { $_.path -cmatch '^PowerShell(?:Modules)?/' })
    Assert-GwHotfixEqual $newEngine $oldEngine 'approved PowerShell/SMA/EOM bytes'
    if ('System.Management.Automation.dll' -iin @($new.files.path)) { throw 'Gw0911gHotfix: root SMA runtime copy is forbidden.' }
    $refs = @($new.files | Where-Object { $_.path.StartsWith('ref/', [StringComparison]::Ordinal) })
    $expectedRefs = @($old.files | Where-Object { $_.path.StartsWith('PowerShell/ref/', [StringComparison]::Ordinal) } |
        ForEach-Object { @{ path = $_.path.Substring('PowerShell/'.Length); sha256 = $_.sha256 } })
    Assert-GwHotfixEqual $refs $expectedRefs 'exact approved reference copies'
    $bytes = ($refs | ForEach-Object { (Get-Item -LiteralPath (Join-Path $newRoot $_.path)).Length } | Measure-Object -Sum).Sum
    if ($refs.Count -ne 167 -or $bytes -ne 6046008) { throw 'Gw0911gHotfix: reference inventory differs from reviewed runtime delta.' }
    $children = @('Gateway.Purview.PowerShellHost.exe','Gateway.Purview.PowerShellHost.dll',
        'Gateway.Purview.PowerShellHost.deps.json','Gateway.Purview.PowerShellHost.runtimeconfig.json','Gateway.Purview.PowerShellHost.pdb')
    $added = @($new.files.path | Where-Object { $_ -cnotin @($old.files.path) } | Sort-Object)
    $removed = @($old.files.path | Where-Object { $_ -cnotin @($new.files.path) })
    if ($Generation -cin @('ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) {
        Assert-GwHotfixEqual $added @() 'diagnostics retain the existing runtime inventory'
        foreach ($child in $children) {
            Assert-GwHotfixEqual @($new.files | Where-Object path -CEQ $child) `
                @($old.files | Where-Object path -CEQ $child) 'console-free child bytes preserved'
        }
    } else {
        Assert-GwHotfixEqual $added @(@($children + $refs.path) | Sort-Object) 'only reviewed runtime additions'
    }
    if ($removed.Count -ne 0) { throw 'Gw0911gHotfix: previous runtime files were removed.' }
    return @{ addedFiles = $added.Count; removedFiles = 0; childEntryFiles = $children; referenceFiles = $refs.Count
        referenceBytes = [long]$bytes; changedApprovedEngineOrModuleFiles = 0; rootSmaRuntimeCopy = $false }
}

function Invoke-GwHotfixDetachedValidation($Candidate) {
    if ($Generation -cnotin @('ConsoleFreePowerShell','ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode')) { throw 'Gw0911gHotfix: detached proof is ConsoleFree generation only.' }
    if (Read-GwHotfixJson 'local-detached-verified.json') { return }
    $validator = Join-Path $script:Root 'operations\test-gw0911g-consolefree-detached.py'
    $root = Join-Path $Candidate.directory '.bootstrap\hotfix-package\publish'
    $raw = & python $validator $root $Candidate.package.receipt.runtimeManifestDigest
    if ($LASTEXITCODE -ne 0) { throw 'Gw0911gHotfix: genuine detached final-child proof failed.' }
    $proof = $raw | ConvertFrom-Json -AsHashtable
    $proof.packageDigest = $Candidate.package.receipt.packageDigest
    $proof.sourceFingerprint = $Candidate.sourceFingerprint
    $proof.manifestDigest = $Candidate.package.receipt.runtimeManifestDigest
    $proof.validatorSha256 = Get-GwHotfixHash $validator
    Save-GwHotfixJson 'local-detached-verified.json' $proof
}

Export-ModuleMember -Function Initialize-GwHotfixCandidate, New-GwHotfixPlan, Invoke-GwHotfixApply, Test-GwHotfixRelease
