BeforeAll {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    foreach ($module in @('Common', 'Entra', 'PurviewExecutor')) {
        Import-Module "$root/bootstrap/modules/$module.psm1" -Force -DisableNameChecking
    }
    $originalPath = $env:PATH
    $gitDirectory = Split-Path -Parent (Get-Command git -ErrorAction Stop).Source
    $nativeDirectory = Join-Path $TestDrive 'native'
    $null = New-Item -ItemType Directory -Path $nativeDirectory
    $env:A365GW_TEST_ARM_LOG = Join-Path $TestDrive 'native-arguments.jsonl'
    $env:A365GW_TEST_ARM_FIXTURE = Join-Path $TestDrive 'synthetic-metadata.json'
    # Replace only the native process boundary. No mock of the executor helper,
    # Invoke-AzJson, Invoke-BootstrapCommand, URL guard, or subscription guard.
    # PATH excludes the installed Azure CLI, so a broken fixture cannot call Azure.
    @'
$ErrorActionPreference = 'Stop'
[IO.File]::AppendAllText($env:A365GW_TEST_ARM_LOG, (ConvertTo-Json -InputObject @($args) -Compress) + "`n")
$f = Get-Content -LiteralPath $env:A365GW_TEST_ARM_FIXTURE -Raw | ConvertFrom-Json -AsHashtable
if ($args[0] -ceq 'account' -and $args[1] -ceq 'get-access-token') {
    $result = @{
        subscription = $f.subscription; tenant = $f.tenant; tokenType = 'Bearer'
        expires_on = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
        accessToken = 'synthetic-native-boundary-only'
    }
}
elseif ($args[0] -ceq 'resource' -and $args[1] -ceq 'show') {
    $id = $args[[array]::IndexOf($args, '--ids') + 1]
    $result = if ($f.resources.ContainsKey($id)) { $f.resources[$id] } else {
        @{ id = $id; properties = @{ fixture = $true } }
    }
}
elseif ($args[0] -ceq 'resource' -and $args[1] -ceq 'invoke-action') { $result = $f.settings }
elseif ($args[0] -cin @('network', 'storage') -and $args -ccontains 'list') { $result = $f.collection }
else { exit 93 }
if ($f.stderr) { [Console]::Error.WriteLine('synthetic-native-diagnostic-must-not-escape') }
[Console]::Out.Write((ConvertTo-Json -InputObject $result -Depth 50 -Compress))
exit $f.exitCode
'@ | Set-Content -LiteralPath (Join-Path $nativeDirectory 'fixture.ps1') -Encoding utf8NoBOM
    if ($IsWindows) {
        $nativeCommand = Join-Path $nativeDirectory 'az.cmd'
        "@echo off`r`n`"$PSHOME\pwsh.exe`" -NoLogo -NoProfile -NonInteractive -File `"%~dp0fixture.ps1`" %*`r`n" |
            Set-Content -LiteralPath $nativeCommand -Encoding ascii
        Test-Path (Join-Path $TestDrive 'python.exe') | Should -BeFalse
    }
    else {
        $nativeCommand = Join-Path $nativeDirectory 'az'
        "#!/bin/sh`nexec '$PSHOME/pwsh' -NoLogo -NoProfile -NonInteractive -File '$nativeDirectory/fixture.ps1' `"`$@`"`n" |
            Set-Content -LiteralPath $nativeCommand -Encoding utf8NoBOM
        & chmod 700 $nativeCommand
        $LASTEXITCODE | Should -Be 0
    }
    function Save-NativeFixture {
        ConvertTo-Json -InputObject $fixture -Depth 50 -Compress |
            Set-Content -LiteralPath $env:A365GW_TEST_ARM_FIXTURE -Encoding utf8NoBOM
    }
    function Get-NativeCalls {
        foreach ($line in Get-Content -LiteralPath $env:A365GW_TEST_ARM_LOG) {
            ,@(ConvertFrom-Json -InputObject $line)
        }
    }
    function Assert-ExactNativeScope($Call) {
        @($Call | Where-Object { $_ -ceq '--subscription' }).Count | Should -Be 1
        $Call[[array]::IndexOf($Call, '--subscription') + 1] | Should -BeExactly $subscription
        $Call | Should -Not -Contain 'rest'
    }
    # Execute the actual host settings assignment, without fabricating a second
    # dispatcher call that could diverge from Assert-PurviewExecutorHost.
    $ast = (Get-Command Assert-PurviewExecutorHost).ScriptBlock.Ast
    $assignment = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -ceq 'settings'
            }, $true))
    $assignment.Count | Should -Be 1
    $readHostSettings = [scriptblock]::Create("param([string]`$siteId)`n$($assignment[0].Extent.Text)`n`$settings")
    $source = Get-BootstrapSourceFingerprint -Root $root
}

AfterAll {
    $env:PATH = $originalPath
    $env:A365GW_TEST_ARM_LOG = $null
    $env:A365GW_TEST_ARM_FIXTURE = $null
    Clear-BootstrapAzureSubscriptionContext
}

Describe 'Executor ARM dispatch through real Common and native boundary' {
    BeforeEach {
        $subscription = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $tenant = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        $scope = "/subscriptions/$subscription/resourceGroups/rg-arm-test"
        $identityId = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/runtime"
        $fixture = @{
            subscription = $subscription; tenant = $tenant; resources = @{}
            collection = @{ value = @() }; settings = @{ DOTNET_EnableDiagnostics = '0' }
            stderr = $false; exitCode = 0
        }
        Save-NativeFixture
        [IO.File]::WriteAllText($env:A365GW_TEST_ARM_LOG, '')
        $env:PATH = $nativeDirectory
        $env:PATH += [IO.Path]::PathSeparator + $gitDirectory
        if ($IsWindows) { $env:PATH += ";$env:SystemRoot\System32" }
        (Get-Command az -ErrorAction Stop).Source | Should -BeExactly $nativeCommand
        Set-BootstrapAzureSubscriptionContext -SubscriptionId $subscription -TenantId $tenant
        $http = [pscustomobject]@{ calls = [Collections.Generic.List[string]]::new() }
        $http | Add-Member -MemberType ScriptMethod -Name SendAsync -Value {
            param($Request, $CompletionOption)
            $this.calls.Add("$($Request.Method.Method) $($Request.RequestUri.AbsoluteUri)")
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
            $response.Content = [Net.Http.StringContent]::new('{"id":"synthetic-graph-read"}')
            $completion = [Threading.Tasks.TaskCompletionSource[Net.Http.HttpResponseMessage]]::new()
            $completion.SetResult($response)
            return $completion.Task
        }
        $script:executorTestHttp = $http
        Mock -ModuleName Common Get-BootstrapGraphHttpClient { $script:executorTestHttp }
    }

    AfterEach {
        $env:PATH = $originalPath
        Clear-BootstrapAzureSubscriptionContext
    }

    It 'reads the exact UAMI using the supported scoped ARM lane, never Graph' {
        $result = Get-PurviewExecutorArmResource -Id $identityId -ApiVersion '2023-01-31'
        $result.id | Should -BeExactly $identityId
        $calls = @(Get-NativeCalls)
        $calls.Count | Should -Be 1
        Assert-ExactNativeScope $calls[0]
        ($calls[0][0..1] -join ' ') | Should -BeExactly 'resource show'
        $calls[0][[array]::IndexOf($calls[0], '--ids') + 1] | Should -BeExactly $identityId
        $calls[0][[array]::IndexOf($calls[0], '--api-version') + 1] | Should -BeExactly '2023-01-31'
        $http.calls.Count | Should -Be 0
    }

    It 'reads concrete nested ARM resource <Suffix> without changing its exact ID' -ForEach @(
        @{ Suffix = 'Microsoft.Web/sites/executor/config/authsettingsV2'; Version = '2024-11-01' }
        @{ Suffix = 'Microsoft.Web/sites/executor/basicPublishingCredentialsPolicies/scm'; Version = '2024-11-01' }
        @{ Suffix = 'Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net/A/executor.scm'; Version = '2020-06-01' }
        @{ Suffix = 'Microsoft.Network/virtualNetworks/owned/subnets/integration'; Version = '2023-11-01' }
        @{ Suffix = 'Microsoft.App/jobs/publisher'; Version = '2025-01-01' }
    ) {
        $id = "$scope/providers/$Suffix"
        (Get-PurviewExecutorArmResource -Id $id -ApiVersion $Version).id | Should -BeExactly $id
        Assert-ExactNativeScope (@(Get-NativeCalls)[0])
        $http.calls.Count | Should -Be 0
    }

    It 'enumerates complete <Kind> and independently reads the exact child ARM shape' -ForEach @(
        @{ Kind = 'endpoint DNS groups'; Suffix = 'Microsoft.Network/privateEndpoints/owned/privateDnsZoneGroups'; Command = 'network private-endpoint dns-zone-group list'; NameFlag = '--endpoint-name'; ParentName = 'owned'; Version = '2023-11-01' }
        @{ Kind = 'DNS VNet links'; Suffix = 'Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net/virtualNetworkLinks'; Command = 'network private-dns link vnet list'; NameFlag = '--zone-name'; ParentName = 'privatelink.blob.core.windows.net'; Version = '2020-06-01' }
        @{ Kind = 'ARM containers'; Suffix = 'Microsoft.Storage/storageAccounts/owned/blobServices/default/containers'; Command = 'storage container-rm list'; NameFlag = '--storage-account'; ParentName = 'owned'; Version = '2023-05-01' }
    ) {
        $id = "$scope/providers/$Suffix"
        $fixture.collection.value = @(@{ id = "$id/exact-child"; name = 'exact-child' })
        Save-NativeFixture
        $result = Get-PurviewExecutorArmResource -Id $id -ApiVersion $Version
        Assert-PurviewExecutorCompleteArmCollection -Collection $result
        $result.value.Count | Should -Be 1
        $result.value[0].id | Should -BeExactly "$id/exact-child"
        $result.value[0].properties.fixture | Should -BeTrue
        $calls = @(Get-NativeCalls)
        $calls.Count | Should -Be 2
        foreach ($call in $calls) { Assert-ExactNativeScope $call }
        ($calls[0] -join ' ') | Should -BeLike "$Command *"
        $calls[0][[array]::IndexOf($calls[0], $NameFlag) + 1] | Should -BeExactly $ParentName
        $calls[0][[array]::IndexOf($calls[0], '--resource-group') + 1] | Should -BeExactly 'rg-arm-test'
        $calls[0][[array]::IndexOf($calls[0], '--query') + 1] | Should -BeExactly '{value:@}'
        $calls[0] | Should -Not -Contain '--max-items'
        $calls[0] | Should -Not -Contain '--top'
        ($calls[1][0..1] -join ' ') | Should -BeExactly 'resource show'
        $http.calls.Count | Should -Be 0
    }

    It 'preserves an observed empty ARM container collection as an array, not unknown/null' {
        $id = "$scope/providers/Microsoft.Storage/storageAccounts/owned/blobServices/default/containers"
        $result = Get-PurviewExecutorArmResource -Id $id -ApiVersion '2023-05-01'
        Assert-PurviewExecutorCompleteArmCollection -Collection $result
        $result.value.Count | Should -Be 0
        @(Get-NativeCalls).Count | Should -Be 1
    }

    It 'rejects unknown, truncated, duplicate or escaped collection <Fault> before child reads' -ForEach @(
        @{ Fault = 'null' }, @{ Fault = 'scalar' }, @{ Fault = 'next page' },
        @{ Fault = 'duplicate' }, @{ Fault = 'different scope' }, @{ Fault = 'different parent' }
    ) {
        $id = "$scope/providers/Microsoft.Network/privateEndpoints/owned/privateDnsZoneGroups"
        switch ($Fault) {
            'null' { $fixture.collection = $null }
            'scalar' { $fixture.collection.value = @{ id = "$id/one" } }
            'next page' { $fixture.collection.nextLink = 'synthetic-unvisited-page' }
            'duplicate' { $fixture.collection.value = @(@{ id = "$id/one" }, @{ id = "$id/ONE" }) }
            'different scope' { $fixture.collection.value = @(@{ id = "$id/one".Replace($subscription, $tenant) }) }
            'different parent' { $fixture.collection.value = @(@{ id = "$id/one/nested/other" }) }
        }
        Save-NativeFixture
        { Get-PurviewExecutorArmResource -Id $id -ApiVersion '2023-11-01' } | Should -Throw
        @(Get-NativeCalls).Count | Should -Be 1
        $http.calls.Count | Should -Be 0
    }

    It 'routes the actual host appsettings assignment through exact resource list action, never Graph' {
        $siteId = "$scope/providers/Microsoft.Web/sites/executor"
        (& $readHostSettings -siteId $siteId).DOTNET_EnableDiagnostics | Should -BeExactly '0'
        $calls = @(Get-NativeCalls)
        $calls.Count | Should -Be 1
        Assert-ExactNativeScope $calls[0]
        ($calls[0][0..1] -join ' ') | Should -BeExactly 'resource invoke-action'
        $calls[0][[array]::IndexOf($calls[0], '--ids') + 1] | Should -BeExactly "$siteId/config/appsettings"
        $calls[0][[array]::IndexOf($calls[0], '--action') + 1] | Should -BeExactly 'list'
        $calls[0][[array]::IndexOf($calls[0], '--query') + 1] | Should -BeExactly 'properties'
        $calls[0] | Should -Not -Contain '--request-body'
        $http.calls.Count | Should -Be 0
    }

    It 'reproduces the real fresh-context composition through source/config/ownership checks and UAMI read' {
        $owner = '11111111-1111-4111-8111-111111111111'
        $principal = '22222222-2222-4222-8222-222222222222'
        $client = '33333333-3333-4333-8333-333333333333'
        $config = @{ subscriptionId = $subscription; tenantId = $tenant; resourceGroupName = 'rg-arm-test'; projectName = 'armtest'; environment = 'dev' }
        $configuration = Get-BootstrapConfigurationFingerprint -Config $config
        $state = @{
            deploymentOwnershipId = $owner; configurationFingerprint = $configuration
            acceptedPlan = @{ sourceFingerprint = $source; configurationFingerprint = $configuration; planFingerprint = 'sha256:' + ('a' * 64) }
        }
        $foundation = @{
            deploymentOwnershipId = $owner; sourceFingerprint = $source
            runtimeImagePullIdentityId = $identityId; runtimeImagePullIdentityPrincipalId = $principal
        }
        $vaultId = "$scope/providers/Microsoft.KeyVault/vaults/kv-armtest-dev"
        $runtime = @{
            deploymentOwnershipId = $owner; sourceFingerprint = $source
            apiPrincipalId = '44444444-4444-4444-8444-444444444444'
            workerPrincipalId = '55555555-5555-4555-8555-555555555555'; sharedKeyVaultId = $vaultId
        }
        $automation = @{
            deploymentOwnershipId = $owner; sourceFingerprint = $source
            status = 'Installed'; policyConfiguration = 'NotPerformed'; policyReadiness = 'NotClaimed'
            certificateSecretUri = 'https://kv-armtest-dev.vault.azure.net/secrets/purview-automation-certificate'
            certificateSecretResourceId = "$vaultId/secrets/purview-automation-certificate"
            automationApplicationId = '66666666-6666-4666-8666-666666666666'
            automationServicePrincipalId = '77777777-7777-4777-8777-777777777777'
            organization = 'fixture.onmicrosoft.com'
        }
        $database = @{
            deploymentOwnershipId = $owner; acceptedSourceFingerprint = $source
            apiPrincipalObjectId = $runtime.apiPrincipalId; workerPrincipalObjectId = $runtime.workerPrincipalId
            workerPrincipalClientId = '88888888-8888-4888-8888-888888888888'
        }
        $fixture.resources[$identityId] = @{
            id = $identityId; properties = @{ principalId = $principal; clientId = $client }
            tags = @{ bootstrapOwnershipId = $owner; bootstrapSourceFingerprint = $source }
        }
        Save-NativeFixture
        $before = Get-BootstrapObjectFingerprint -InputObject $state
        $context = Get-PurviewExecutorFreshContext -Config $config -State $state -Foundation $foundation -Runtime $runtime -Automation $automation -Database $database
        $context.runtimeClientId | Should -BeExactly $client
        (Get-BootstrapObjectFingerprint -InputObject $state) | Should -BeExactly $before
        $state.ContainsKey('freshPurviewExecutor') | Should -BeFalse
        @(Get-NativeCalls).Count | Should -Be 1
        Assert-ExactNativeScope (@(Get-NativeCalls)[0])
        $http.calls.Count | Should -Be 0
    }

    It 'requires initialized exact subscription and tenant context for ARM reads' {
        Clear-BootstrapAzureSubscriptionContext
        { Get-PurviewExecutorArmResource -Id $identityId -ApiVersion '2023-01-31' } | Should -Throw '*context*'
        @(Get-NativeCalls).Count | Should -Be 0
    }

    It 'rejects a foreign subscription embedded in an ARM resource ID' {
        { Get-PurviewExecutorArmResource -Id $identityId.Replace($subscription, $tenant) -ApiVersion '2023-01-31' } |
            Should -Throw '*subscription*'
        @(Get-NativeCalls).Count | Should -Be 0
    }

    It 'rejects an unreviewed or malformed ARM path <Suffix> before any native dispatch' -ForEach @(
        @{ Suffix = 'Microsoft.Network/privateEndpoints/owned/unknownCollection' }
        @{ Suffix = 'Microsoft.Web/sites/executor?api-version=other' }
        @{ Suffix = 'Microsoft.Web/sites/executor/../other' }
        @{ Suffix = 'Microsoft.Web/sites/executor#fragment' }
        @{ Suffix = 'Microsoft.Web/sites/executor%2Fother' }
    ) {
        { Get-PurviewExecutorArmResource -Id "$scope/providers/$Suffix" -ApiVersion '2023-01-31' } | Should -Throw
        @(Get-NativeCalls).Count | Should -Be 0
    }

    It 'rejects malformed API versions before native dispatch' {
        { Get-PurviewExecutorArmResource -Id $identityId -ApiVersion '2023-01-31&other=value' } | Should -Throw
        @(Get-NativeCalls).Count | Should -Be 0
    }

    It 'rejects absent scope, foreign subscription or a non-site in the actual settings assignment' -ForEach @(
        @{ Fault = 'no context' }, @{ Fault = 'foreign subscription' }, @{ Fault = 'non-site' }
    ) {
        $siteId = "$scope/providers/Microsoft.Web/sites/executor"
        switch ($Fault) {
            'no context' { Clear-BootstrapAzureSubscriptionContext }
            'foreign subscription' { $siteId = $siteId.Replace($subscription, $tenant) }
            'non-site' { $siteId += '/config/connectionstrings' }
        }
        { & $readHostSettings -siteId $siteId } | Should -Throw
        @(Get-NativeCalls).Count | Should -Be 0
        $http.calls.Count | Should -Be 0
    }

    It 'does not silently accept missing or mismatched exact resource readback' -ForEach @(
        @{ Missing = $true }, @{ Missing = $false }
    ) {
        $fixture.resources[$identityId] = if ($Missing) { $null } else { @{ id = "$identityId-other" } }
        Save-NativeFixture
        { Get-PurviewExecutorArmResource -Id $identityId -ApiVersion '2023-01-31' } | Should -Throw
        @(Get-NativeCalls).Count | Should -Be 1
    }

    It 'uses stdout-only ARM parsing without promoting native diagnostics into JSON' {
        $fixture.stderr = $true
        Save-NativeFixture
        (Get-PurviewExecutorArmResource -Id $identityId -ApiVersion '2023-01-31').id | Should -BeExactly $identityId
    }

    It 'fails closed on native failure without emitting diagnostic content' {
        $fixture.exitCode = 7; $fixture.stderr = $true
        Save-NativeFixture
        try {
            Get-PurviewExecutorArmResource -Id $identityId -ApiVersion '2023-01-31'
            throw 'Expected failure'
        }
        catch {
            $_.Exception.Message | Should -Not -Match 'synthetic-native-diagnostic'
            $_.Exception.Message | Should -Match '7'
        }
        @(Get-NativeCalls).Count | Should -Be 1
    }

    It 'still rejects duplicate or conflicting subscription selectors at the real native dispatcher' -ForEach @(
        @{ Duplicate = $true }, @{ Duplicate = $false }
    ) {
        $arguments = @('resource', 'show', '--ids', $identityId, '--subscription', $tenant)
        if ($Duplicate) { $arguments += @('--subscription', $subscription) }
        { Invoke-AzJson -CaptureStdoutOnly -Arguments $arguments } | Should -Throw '*subscription*'
        @(Get-NativeCalls).Count | Should -Be 0
    }

    It 'keeps Graph on in-process HTTP with exact-account acquisition, not native rest' {
        $result = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', 'https://graph.microsoft.com/v1.0/servicePrincipals?$select=id')
        $result.id | Should -BeExactly 'synthetic-graph-read'
        $calls = @(Get-NativeCalls)
        $calls.Count | Should -Be 1
        Assert-ExactNativeScope $calls[0]
        ($calls[0][0..1] -join ' ') | Should -BeExactly 'account get-access-token'
        $calls[0][[array]::IndexOf($calls[0], '--resource') + 1] | Should -BeExactly 'https://graph.microsoft.com/'
        $http.calls.Count | Should -Be 1
    }

    It 'rejects mismatched Graph account <Field> at the real acquisition guard, before HTTP' -ForEach @(
        @{ Field = 'subscription' }, @{ Field = 'tenant' }
    ) {
        $fixture[$Field] = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        Save-NativeFixture
        { Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', 'https://graph.microsoft.com/v1.0/servicePrincipals') } |
            Should -Throw '*metadata did not match*'
        @(Get-NativeCalls).Count | Should -Be 1
        $http.calls.Count | Should -Be 0
    }

    It 'keeps the actual Graph URL guard closed to <Url>' -ForEach @(
        @{ Url = 'https://management.azure.com/subscriptions/fixture?api-version=2023-01-31' }
        @{ Url = 'https://graph.microsoft.com/beta/servicePrincipals' }
        @{ Url = 'https://graph.microsoft.com.example.invalid/v1.0/servicePrincipals' }
        @{ Url = 'http://graph.microsoft.com/v1.0/servicePrincipals' }
    ) {
        { Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', $Url) } | Should -Throw '*v1.0 boundary*'
        @(Get-NativeCalls).Count | Should -Be 0
        $http.calls.Count | Should -Be 0
    }

    It 'does not permit CaptureStdoutOnly as a workaround for Graph-only rest' {
        { Invoke-AzJson -CaptureStdoutOnly -Arguments @('rest', '--method', 'GET', '--url', "https://management.azure.com$identityId") } |
            Should -Throw '*not available for Microsoft Graph*'
        @(Get-NativeCalls).Count | Should -Be 0
    }

    It 'does not permit native rest to bypass the Graph boundary' {
        { Invoke-BootstrapCommand -FilePath az -ArgumentList @('rest', '--method', 'GET', '--url', "https://management.azure.com$identityId") } |
            Should -Throw '*rest*'
        @(Get-NativeCalls).Count | Should -Be 0
    }

    It 'contains no remaining executor management URL sent through rest' {
        $text = Get-Content -LiteralPath "$root/bootstrap/modules/PurviewExecutor.psm1" -Raw
        ($text -match 'https://management\.azure\.com') | Should -BeFalse
        $text | Should -Match "'rest', '--method', 'GET', '--url'"
        $text | Should -Match 'https://graph\.microsoft\.com/v1\.0/servicePrincipals/'
    }
}
