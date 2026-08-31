Describe 'Provisioning prerequisite read-only source contract' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $script:PreflightPath = Join-Path $script:RepositoryRoot 'operations/test-provisioning-prerequisites.ps1'
        $script:PreflightSource = Get-Content -LiteralPath $script:PreflightPath -Raw
        $tokens = $null
        $errors = $null
        $script:PreflightAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:PreflightPath,
            [ref]$tokens,
            [ref]$errors)
        $script:ParseErrors = @($errors)

        foreach ($functionName in @(
            'Get-ExactPlainContainerEnvironmentValue',
            'Get-ContainerEnvironmentEntriesWithPrefix',
            'Test-DeployedDelegatedRegistryConfiguration',
            'Test-DeployedProvisioningAccessConfiguration'
        )) {
            $functionDefinition = @($script:PreflightAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq $functionName
            }, $true))
            $functionDefinition.Count | Should -Be 1
            Invoke-Expression $functionDefinition[0].Extent.Text
        }

        function Add-Failure {
            param([string]$Message)
            $script:PreflightFailures.Add($Message)
        }

        function Write-Pass {
            param([string]$Message)
        }

        function New-PreflightContainerApp {
            param([Parameter(Mandatory = $true)][bool]$ContinuousDevelopment)

            $continuousValue = $ContinuousDevelopment.ToString().ToLowerInvariant()
            return [pscustomobject]@{
                properties = [pscustomobject]@{
                    template = [pscustomobject]@{
                        containers = @([pscustomobject]@{
                            env = @(
                                [pscustomobject]@{ name = 'Agent365__DelegatedRegistry__Enabled'; value = $continuousValue }
                                [pscustomobject]@{ name = 'Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess'; value = $continuousValue }
                                [pscustomobject]@{ name = 'Agent365__DelegatedRegistry__Scopes__0'; value = 'https://graph.microsoft.com/AgentRegistration.ReadWrite.All' }
                                [pscustomobject]@{ name = 'Agent365__DelegatedRegistry__Scopes__1'; value = 'https://graph.microsoft.com/AgentRegistration.Read.All' }
                                [pscustomobject]@{ name = 'EntraId__ClientCredentials__0__SourceType'; value = 'SignedAssertionFromManagedIdentity' }
                                [pscustomobject]@{ name = 'EntraId__ClientCredentials__0__TokenExchangeUrl'; value = 'api://AzureADTokenExchange' }
                                [pscustomobject]@{ name = 'Provisioning__AllowContinuousDevelopmentAccess'; value = $continuousValue }
                            )
                        })
                    }
                }
            }
        }

        function Invoke-PreflightAccessConfigurationCheck {
            param(
                [Parameter(Mandatory = $true)][object]$ContainerApp,
                [Parameter(Mandatory = $true)][bool]$ContinuousDevelopment
            )

            Test-DeployedDelegatedRegistryConfiguration `
                -ContainerApp $ContainerApp `
                -ExpectedContinuousDevelopmentAccess $ContinuousDevelopment
            Test-DeployedProvisioningAccessConfiguration `
                -ContainerApp $ContainerApp `
                -ExpectedContinuousDevelopmentAccess $ContinuousDevelopment
        }
    }

    BeforeEach {
        $script:PreflightFailures = [Collections.Generic.List[string]]::new()
        $script:TokenExchangeAudience = 'api://AzureADTokenExchange'
    }

    It 'parses and exposes only the current operator inputs' {
        $script:ParseErrors.Count | Should -Be 0
        $parameterNames = @($script:PreflightAst.ParamBlock.Parameters | ForEach-Object {
            $_.Name.VariablePath.UserPath
        })
        $expectedParameterNames = @(
            'Environment',
            'ExpectedSubscriptionId',
            'ExpectedTenantId',
            'ResourceGroup',
            'ProjectName',
            'ContainerAppsEnvironmentName',
            'WorkerContainerAppName',
            'ExpectedServiceBusQueueName',
            'WorkerProcessingEnabled',
            'ExpectedGatewayApiApplicationClientId',
            'ExpectedManagerApplicationIds',
            'DelegatedRegistryEnabled',
            'ExpectedGatewayApiFederatedCredentialName',
            'RequireExecutionReady',
            'ExpectContinuousDevelopmentAccess',
            'ManagerApplicationsPreflightConfirmed',
            'RequireDeployedConfigurationMatch'
        )
        $parameterNames.Count | Should -Be $expectedParameterNames.Count
        Compare-Object -ReferenceObject $expectedParameterNames -DifferenceObject $parameterNames |
            Should -BeNullOrEmpty
    }

    It 'accepts the default closed admission and Registry configuration' {
        $containerApp = New-PreflightContainerApp -ContinuousDevelopment $false

        Invoke-PreflightAccessConfigurationCheck `
            -ContainerApp $containerApp `
            -ContinuousDevelopment $false

        $script:PreflightFailures.Count | Should -Be 0
    }

    It 'accepts the explicit continuous development configuration' {
        $containerApp = New-PreflightContainerApp -ContinuousDevelopment $true

        Invoke-PreflightAccessConfigurationCheck `
            -ContainerApp $containerApp `
            -ContinuousDevelopment $true

        $script:PreflightFailures.Count | Should -Be 0
    }

    It 'rejects mismatched continuous-development admission and Registry settings' {
        $containerApp = New-PreflightContainerApp -ContinuousDevelopment $false

        Invoke-PreflightAccessConfigurationCheck `
            -ContainerApp $containerApp `
            -ContinuousDevelopment $true

        $script:PreflightFailures.Count | Should -BeGreaterThan 0
    }

    It 'requires the queue API and worker instead of accepting partial deployment' {
        $script:PreflightSource | Should -Match "Service Bus queue '.+' does not exist"
        $script:PreflightSource | Should -Match '(?s)\$apiApp\s*=\s*Test-AppEnvironment.+?-Required\s+\$true'
        $script:PreflightSource | Should -Match '(?s)\$workerApp\s*=\s*Test-AppEnvironment.+?-Required\s+\$true'
    }
}
