Describe 'Azure CLI subscription and output boundary' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $script:OriginalSubscriptionPin = [Environment]::GetEnvironmentVariable('A365GW_BOOTSTRAP_SUBSCRIPTION_ID')
        . (Join-Path $script:RepositoryRoot 'tools/_common.ps1')
    }

    AfterAll {
        [Environment]::SetEnvironmentVariable(
            'A365GW_BOOTSTRAP_SUBSCRIPTION_ID',
            $script:OriginalSubscriptionPin)
    }

    BeforeEach {
        [Environment]::SetEnvironmentVariable(
            'A365GW_BOOTSTRAP_SUBSCRIPTION_ID',
            '11111111-1111-4111-8111-111111111111')
    }

    It 'appends the canonical bootstrap subscription to an unpinned Azure CLI command' {
        $actual = @(Add-A365GatewayAzureSubscriptionPin -Arguments @('group', 'show', '--name', 'rg-safe') -Required)

        $actual | Should -Be @(
            'group', 'show', '--name', 'rg-safe',
            '--subscription', '11111111-1111-4111-8111-111111111111')
    }

    It 'keeps one matching explicit subscription without duplication' {
        $actual = @(Add-A365GatewayAzureSubscriptionPin -Arguments @(
            'account', 'show', '--subscription', '11111111-1111-4111-8111-111111111111') -Required)

        @($actual | Where-Object { $_ -ceq '--subscription' }).Count | Should -Be 1
    }

    It 'rejects a conflicting explicit subscription' {
        { Add-A365GatewayAzureSubscriptionPin -Arguments @(
                'group', 'show', '--subscription', '22222222-2222-4222-8222-222222222222') -Required } |
            Should -Throw '*do not match the exact bootstrap subscription pin*'
    }

    It 'rejects a malformed or noncanonical environment pin' {
        [Environment]::SetEnvironmentVariable(
            'A365GW_BOOTSTRAP_SUBSCRIPTION_ID',
            '11111111-1111-4111-8111-11111111111A')

        { Get-A365GatewayBootstrapSubscriptionId -Required } |
            Should -Throw '*canonical, non-empty lowercase GUID*'
    }

    It 'does not include provider output in Azure CLI failures' {
        function az {
            'private-provider-body-marker'
            $global:LASTEXITCODE = 29
        }

        try {
            Invoke-AzCommand -Arguments @('group', 'show', '--name', 'rg-safe') -ErrorMessage 'Resource lookup failed.'
            throw 'Expected the Azure CLI wrapper to fail.'
        }
        catch {
            $_.Exception.Message | Should -Match 'Resource lookup failed'
            $_.Exception.Message | Should -Match 'exit code: 29'
            $_.Exception.Message | Should -Not -Match 'private-provider-body-marker'
        }
    }

    It 'routes the Entra helper through the accepted Common Graph boundary without native az rest' {
        $source = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'tools/configure-workflow-v3-entra.ps1') -Raw

        $source | Should -Match '\$commonModulePath = \[IO\.Path\]::GetFullPath[\s\S]+bootstrap/modules/Common\.psm1'
        $source | Should -Match '\$loadedCommonModules = @\(Get-Module -Name Common\)[\s\S]+\$loadedCommonModules\.Count -gt 1'
        $source | Should -Match 'function Get-CommonModuleFileDigest[\s\S]+SHA256'
        $source | Should -Match '\$loadedCommonPath\.Equals\(\$commonModulePath, \$pathComparison\)[\s\S]+Get-CommonModuleFileDigest -Path \$loadedCommonPath[\s\S]+Get-CommonModuleFileDigest -Path \$commonModulePath'
        $source | Should -Match 'A dynamic Common module cannot provide the accepted Graph trust boundary'
        $source | Should -Match 'Import-Module \$commonModulePath -ErrorAction Stop'
        $source | Should -Match 'Common\\Set-BootstrapAzureSubscriptionContext[\s\S]+-SubscriptionId \(\$ExpectedSubscriptionId\.ToString\(''D''\)\)[\s\S]+-TenantId \(\$ExpectedTenantId\.ToString\(''D''\)\)'
        $source | Should -Match 'function Invoke-GraphAzRest[\s\S]+Common\\Invoke-BootstrapGraphAzRest -Arguments \$Arguments'
        $source | Should -Match 'function Invoke-AzMutation[\s\S]+Assert-ExpectedAzureContext[\s\S]+Invoke-GraphAzRest'
        $source | Should -Not -Match 'function Invoke-AzJson'
        $source | Should -Not -Match '&\s+az\b'
        $source | Should -Not -Match 'Common\\Invoke-AzJson\s+-Arguments\s+@\(\s*''rest'''
        $source | Should -Not -Match 'get-access-token'
        $source | Should -Not -Match 'Authorization='
    }

    It 'passes the exact subscription and tenant to Common and performs all Graph reads through its helper' {
        $subscriptionId = '11111111-1111-4111-8111-111111111111'
        $tenantId = '22222222-2222-4222-8222-222222222222'
        $gatewayClientId = '33333333-3333-4333-8333-333333333333'
        $gatewayPrincipalId = '44444444-4444-4444-8444-444444444444'
        $workerPrincipalId = '55555555-5555-4555-8555-555555555555'
        $gatewayApplicationObjectId = '66666666-6666-4666-8666-666666666666'
        $gatewayServicePrincipalObjectId = '77777777-7777-4777-8777-777777777777'
        $graphServicePrincipalObjectId = '88888888-8888-4888-8888-888888888888'
        $readScopeId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $readWriteScopeId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        $readRoleId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        $readWriteRoleId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'

        $global:WorkflowV3ContextSubscription = $null
        $global:WorkflowV3ContextTenant = $null
        $global:WorkflowV3AccountCalls = [Collections.Generic.List[object]]::new()
        $global:WorkflowV3GraphCalls = [Collections.Generic.List[object]]::new()
        $global:WorkflowV3Fake = [ordered]@{
            subscriptionId = $subscriptionId
            tenantId = $tenantId
            gatewayClientId = $gatewayClientId
            gatewayPrincipalId = $gatewayPrincipalId
            workerPrincipalId = $workerPrincipalId
            gatewayApplicationObjectId = $gatewayApplicationObjectId
            gatewayServicePrincipalObjectId = $gatewayServicePrincipalObjectId
            graphServicePrincipalObjectId = $graphServicePrincipalObjectId
            readScopeId = $readScopeId
            readWriteScopeId = $readWriteScopeId
            readRoleId = $readRoleId
            readWriteRoleId = $readWriteRoleId
        }

        $previousCommonPaths = @(
            Get-Module -Name Common |
                ForEach-Object { $_.Path } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        Get-Module -Name Common | Remove-Module -Force
        $acceptedRoot = Join-Path $TestDrive 'accepted-source'
        $acceptedTools = Join-Path $acceptedRoot 'tools'
        $acceptedModules = Join-Path $acceptedRoot 'bootstrap/modules'
        New-Item -ItemType Directory -Path $acceptedTools, $acceptedModules -Force | Out-Null
        $scriptPath = Join-Path $acceptedTools 'configure-workflow-v3-entra.ps1'
        Copy-Item -LiteralPath (
            Join-Path $script:RepositoryRoot 'tools/configure-workflow-v3-entra.ps1') -Destination $scriptPath
        $fakeCommonPath = Join-Path $acceptedModules 'Common.psm1'
        @'
Set-StrictMode -Version Latest

            function Set-BootstrapAzureSubscriptionContext {
                param([string]$SubscriptionId, [string]$TenantId)
                $global:WorkflowV3ContextSubscription = $SubscriptionId
                $global:WorkflowV3ContextTenant = $TenantId
            }
            function Invoke-AzJson {
                param([string[]]$Arguments)
                $global:WorkflowV3AccountCalls.Add(@($Arguments))
                return [pscustomobject]@{
                    subscription = $global:WorkflowV3Fake.subscriptionId
                    tenant = $global:WorkflowV3Fake.tenantId
                }
            }
            function Invoke-BootstrapGraphAzRest {
                param([string[]]$Arguments)
                $global:WorkflowV3GraphCalls.Add(@($Arguments))
                $urlIndex = [Array]::IndexOf([object[]]$Arguments, '--url')
                if ($urlIndex -lt 0) {
                    throw 'The test Graph boundary requires an explicit URL.'
                }
                $url = [string]$Arguments[$urlIndex + 1]

                if ($url.Contains('/applications?') -and $url.Contains($global:WorkflowV3Fake.gatewayClientId)) {
                    return [pscustomobject]@{ value = @([pscustomobject]@{
                        id = $global:WorkflowV3Fake.gatewayApplicationObjectId
                        appId = $global:WorkflowV3Fake.gatewayClientId
                        requiredResourceAccess = @([pscustomobject]@{
                            resourceAppId = '00000003-0000-0000-c000-000000000000'
                            resourceAccess = @(
                                [pscustomobject]@{ id = $global:WorkflowV3Fake.readScopeId; type = 'Scope' },
                                [pscustomobject]@{ id = $global:WorkflowV3Fake.readWriteScopeId; type = 'Scope' }
                            )
                        })
                    }) }
                }
                if ($url.Contains('/servicePrincipals?') -and $url.Contains($global:WorkflowV3Fake.gatewayClientId)) {
                    return [pscustomobject]@{ value = @([pscustomobject]@{
                        id = $global:WorkflowV3Fake.gatewayServicePrincipalObjectId
                        appId = $global:WorkflowV3Fake.gatewayClientId
                    }) }
                }
                if ($url.Contains('/servicePrincipals?') -and $url.Contains('00000003-0000-0000-c000-000000000000')) {
                    return [pscustomobject]@{ value = @([pscustomobject]@{
                        id = $global:WorkflowV3Fake.graphServicePrincipalObjectId
                        appId = '00000003-0000-0000-c000-000000000000'
                        oauth2PermissionScopes = @(
                            [pscustomobject]@{ id = $global:WorkflowV3Fake.readScopeId; value = 'AgentRegistration.Read.All'; isEnabled = $true },
                            [pscustomobject]@{ id = $global:WorkflowV3Fake.readWriteScopeId; value = 'AgentRegistration.ReadWrite.All'; isEnabled = $true }
                        )
                        appRoles = @(
                            [pscustomobject]@{ id = $global:WorkflowV3Fake.readRoleId; value = 'AgentRegistration.Read.All'; isEnabled = $true; allowedMemberTypes = @('Application') },
                            [pscustomobject]@{ id = $global:WorkflowV3Fake.readWriteRoleId; value = 'AgentRegistration.ReadWrite.All'; isEnabled = $true; allowedMemberTypes = @('Application') }
                        )
                    }) }
                }
                if ($url.Contains("/servicePrincipals/$($global:WorkflowV3Fake.workerPrincipalId)/appRoleAssignments")) {
                    return [pscustomobject]@{ value = @() }
                }
                if ($url.Contains("/applications/$($global:WorkflowV3Fake.gatewayApplicationObjectId)/federatedIdentityCredentials")) {
                    return [pscustomobject]@{ value = @([pscustomobject]@{
                        id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
                        name = 'a365gw-api-obo-dev'
                        issuer = "https://login.microsoftonline.com/$($global:WorkflowV3Fake.tenantId)/v2.0"
                        subject = $global:WorkflowV3Fake.gatewayPrincipalId
                        audiences = @('api://AzureADTokenExchange')
                    }) }
                }
                if ($url.Contains('/oauth2PermissionGrants?')) {
                    return [pscustomobject]@{ value = @([pscustomobject]@{
                        id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
                        clientId = $global:WorkflowV3Fake.gatewayServicePrincipalObjectId
                        resourceId = $global:WorkflowV3Fake.graphServicePrincipalObjectId
                        consentType = 'AllPrincipals'
                        scope = 'AgentRegistration.Read.All AgentRegistration.ReadWrite.All'
                    }) }
                }
                throw "Unexpected Graph URL in test boundary: $url"
            }

            Export-ModuleMember -Function @(
                'Set-BootstrapAzureSubscriptionContext',
                'Invoke-AzJson',
                'Invoke-BootstrapGraphAzRest')
'@ | Set-Content -LiteralPath $fakeCommonPath -Encoding utf8NoBOM
        $workingTreeModules = Join-Path $TestDrive 'working-tree/bootstrap/modules'
        New-Item -ItemType Directory -Path $workingTreeModules -Force | Out-Null
        $workingTreeCommonPath = Join-Path $workingTreeModules 'Common.psm1'
        Copy-Item -LiteralPath $fakeCommonPath -Destination $workingTreeCommonPath
        Import-Module $workingTreeCommonPath -Force

        try {
            {
                & $scriptPath `
                    -ExpectedSubscriptionId $subscriptionId `
                    -ExpectedTenantId $tenantId `
                    -GatewayApiApplicationClientId $gatewayClientId `
                    -GatewayApiManagedIdentityPrincipalId $gatewayPrincipalId `
                    -WorkerManagedIdentityPrincipalId $workerPrincipalId | Out-Null
            } | Should -Not -Throw

            (Get-Module -Name Common).Path | Should -BeExactly $workingTreeCommonPath
            $global:WorkflowV3ContextSubscription | Should -BeExactly $subscriptionId
            $global:WorkflowV3ContextTenant | Should -BeExactly $tenantId
            $global:WorkflowV3AccountCalls.Count | Should -Be 1
            @($global:WorkflowV3AccountCalls[0]) | Should -Be @(
                'account', 'show', '--query', '{subscription:id,tenant:tenantId}')
            $global:WorkflowV3GraphCalls.Count | Should -Be 6
            foreach ($arguments in $global:WorkflowV3GraphCalls) {
                @($arguments)[0] | Should -BeExactly 'rest'
            }
        }
        finally {
            Get-Module -Name Common | Remove-Module -Force
            foreach ($path in $previousCommonPaths) {
                Import-Module $path -ErrorAction Stop
            }
            Remove-Variable -Name WorkflowV3ContextSubscription -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name WorkflowV3ContextTenant -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name WorkflowV3AccountCalls -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name WorkflowV3GraphCalls -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable -Name WorkflowV3Fake -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a non-equivalent preloaded Common module before any account or Graph call' {
        $previousCommonPaths = @(
            Get-Module -Name Common |
                ForEach-Object { $_.Path } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        Get-Module -Name Common | Remove-Module -Force
        $untrustedModuleRoot = Join-Path $TestDrive 'untrusted-module'
        New-Item -ItemType Directory -Path $untrustedModuleRoot -Force | Out-Null
        $untrustedModulePath = Join-Path $untrustedModuleRoot 'Common.psm1'
        @'
function Set-BootstrapAzureSubscriptionContext { throw 'must-not-run' }
function Invoke-AzJson { throw 'must-not-run' }
function Invoke-BootstrapGraphAzRest { throw 'must-not-run' }
Export-ModuleMember -Function *
'@ | Set-Content -LiteralPath $untrustedModulePath -Encoding utf8NoBOM
        Import-Module $untrustedModulePath -Force

        try {
            $scriptPath = Join-Path $script:RepositoryRoot 'tools/configure-workflow-v3-entra.ps1'
            {
                & $scriptPath `
                    -ExpectedSubscriptionId '11111111-1111-4111-8111-111111111111' `
                    -ExpectedTenantId '22222222-2222-4222-8222-222222222222' `
                    -GatewayApiApplicationClientId '33333333-3333-4333-8333-333333333333' `
                    -GatewayApiManagedIdentityPrincipalId '44444444-4444-4444-8444-444444444444' `
                    -WorkerManagedIdentityPrincipalId '55555555-5555-4555-8555-555555555555'
            } | Should -Throw '*does not match the accepted-source Graph trust boundary*'
        }
        finally {
            Get-Module -Name Common | Remove-Module -Force
            foreach ($path in $previousCommonPaths) {
                Import-Module $path -ErrorAction Stop
            }
        }
    }
}
