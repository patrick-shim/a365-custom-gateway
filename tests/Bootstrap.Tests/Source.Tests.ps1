Describe 'Public bootstrap helper source boundaries' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    }

    It 'keeps Purview SIT discovery interactive, bounded, and safe-output-only' {
        $path = Join-Path $script:RepositoryRoot 'bootstrap/get-purview-sensitive-information-types.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref]$tokens,
            [ref]$errors)

        $errors.Count | Should -Be 0
        $parameterNames = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
        $parameterNames | Should -Be @('TenantId', 'UserPrincipalName')
        $source = $ast.Extent.Text
        $source | Should -Match 'Connect-BootstrapPurview'
        $source | Should -Match 'Get-BootstrapPurviewSensitiveInformationTypes'
        $source | Should -Not -Match 'Connect-BootstrapPurview(?s:.){0,250}-(?:AccessToken|Device)'
        $source | Should -Match 'schemaVersion\s*=\s*1'
        $source | Should -Match 'tenantId\s*=\s*\$canonicalTenantId'
        $source | Should -Match 'types\s*=\s*@\('
        $source | Should -Match 'id\s*=\s*\[string\]\$_\.id'
        $source | Should -Match 'name\s*=\s*\[string\]\$_\.name'
        $source | Should -Match 'publisher\s*=\s*\[string\]\$_\.publisher'
        $source | Should -Not -Match '\$_.Exception|ErrorDetails|ScriptStackTrace|providerItems'
    }

    It 'enumerates the full tenant SIT catalog without an Identity lookup' {
        $path = Join-Path $script:RepositoryRoot 'bootstrap/modules/Purview.psm1'
        $source = Get-Content -LiteralPath $path -Raw

        $source | Should -Match 'Get-DlpSensitiveInformationType\s+-ErrorAction\s+Stop'
        $source | Should -Not -Match 'Get-DlpSensitiveInformationType\s+-Identity'
    }

    It 'keeps every executable production SIT default empty' {
        $mainBicep = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'infrastructure/bicep/main.bicep') -Raw
        $workerBicep = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'infrastructure/bicep/modules/container-app-worker.bicep') -Raw
        $purviewOptions = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'src/Gateway.Purview/PurviewOptions.cs') -Raw
        $workerSettings = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'src/Gateway.Provisioning.Worker/appsettings.json') -Raw |
                ConvertFrom-Json -Depth 20 -ErrorAction Stop

        foreach ($source in @($mainBicep, $workerBicep)) {
            $source | Should -Match "param purviewDefaultSensitiveInformationType string = ''"
            $source | Should -Match "param purviewDefaultSensitiveInformationTypeId string = ''"
        }
        $purviewOptions | Should -Match (
            'DefaultSensitiveInformationTypeId\s*\{\s*get;\s*set;\s*\}\s*=\s*string\.Empty')
        $purviewOptions | Should -Match (
            'DefaultSensitiveInformationType\s*\{\s*get;\s*set;\s*\}\s*=\s*string\.Empty')
        [string]$workerSettings.Purview.DefaultSensitiveInformationTypeId |
            Should -BeExactly ''
        [string]$workerSettings.Purview.DefaultSensitiveInformationType |
            Should -BeExactly ''
    }
}

Describe 'Windows-safe standalone Bicep compiler boundary' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $script:CompilerPath = Join-Path $script:RepositoryRoot 'tools/Test-BootstrapSource.ps1'
        $script:CompilerSource = Get-Content -LiteralPath $script:CompilerPath -Raw

        $tokens = $null
        $errors = $null
        $compilerAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:CompilerPath,
            [ref]$tokens,
            [ref]$errors)
        $errors.Count | Should -Be 0

        $requiredFunctions = @(
            'Resolve-GatewayBicepCompilerCommand',
            'New-GatewayBicepCompilerStartInfo'
        )
        $functionDefinitions = @(
            $compilerAst.FindAll(
                {
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $requiredFunctions -contains $node.Name
                },
                $true)
        )
        $script:CompilerFunctionCount = $functionDefinitions.Count
        $script:CompilerModule = if ($functionDefinitions.Count -eq $requiredFunctions.Count) {
            New-Module -ScriptBlock ([scriptblock]::Create(
                ($functionDefinitions.Extent.Text -join "`n`n")))
        }
        else {
            $null
        }
    }

    It 'resolves a Windows az.cmd launcher through bundled Python and preserves ArgumentList values' {
        $script:CompilerFunctionCount | Should -Be 2

        $azureCliRoot = Join-Path $TestDrive 'Azure CLI root with spaces'
        $commandDirectory = New-Item -ItemType Directory -Path (
            Join-Path $azureCliRoot 'wbin') -Force
        $commandPath = Join-Path $commandDirectory.FullName 'az.cmd'
        $pythonPath = Join-Path $azureCliRoot 'python.exe'
        Set-Content -LiteralPath $commandPath -Value '@exit /b 0'
        Set-Content -LiteralPath $pythonPath -Value ''

        $command = & $script:CompilerModule {
            param($path)
            Resolve-GatewayBicepCompilerCommand `
                -AzureCliPath $path `
                -WindowsPlatform $true
        } $commandPath
        $arguments = @(
            'bicep',
            'build',
            '--file',
            'C:\source path & marker\main.bicep',
            '--stdout'
        )
        $startInfo = & $script:CompilerModule {
            param($resolvedCommand, $compilerArguments)
            New-GatewayBicepCompilerStartInfo `
                -Command $resolvedCommand `
                -Arguments $compilerArguments
        } $command $arguments

        $startInfo.FileName | Should -BeExactly ([IO.Path]::GetFullPath($pythonPath))
        @($startInfo.ArgumentList) | Should -Be @(
            '-IBm',
            'azure.cli',
            'bicep',
            'build',
            '--file',
            'C:\source path & marker\main.bicep',
            '--stdout'
        )
        $startInfo.UseShellExecute | Should -BeFalse
        $startInfo.FileName | Should -Not -Match '(?i)(?:^|[\\/])(?:cmd|powershell|pwsh)\.exe$'
        @($startInfo.ArgumentList) | Should -Not -Contain '/c'
    }

    It 'maps the extensionless Azure CLI shim to its sibling Windows launcher and bundled Python' {
        $script:CompilerFunctionCount | Should -Be 2

        # The Azure CLI MSI installs an extensionless bash shim beside az.cmd in
        # wbin. PowerShell can resolve that shim instead of the .cmd launcher, and
        # it is not a Windows executable process boundary.
        $azureCliRoot = Join-Path $TestDrive 'Azure CLI with shim'
        $commandDirectory = New-Item -ItemType Directory -Path (
            Join-Path $azureCliRoot 'wbin') -Force
        $shimPath = Join-Path $commandDirectory.FullName 'az'
        $launcherPath = Join-Path $commandDirectory.FullName 'az.cmd'
        $pythonPath = Join-Path $azureCliRoot 'python.exe'
        Set-Content -LiteralPath $shimPath -Value '#!/usr/bin/env bash'
        Set-Content -LiteralPath $launcherPath -Value '@exit /b 0'
        Set-Content -LiteralPath $pythonPath -Value ''

        $command = & $script:CompilerModule {
            param($path)
            Resolve-GatewayBicepCompilerCommand `
                -AzureCliPath $path `
                -WindowsPlatform $true
        } $shimPath
        $startInfo = & $script:CompilerModule {
            param($resolvedCommand)
            New-GatewayBicepCompilerStartInfo `
                -Command $resolvedCommand `
                -Arguments @('bicep', 'build', '--stdout')
        } $command

        $startInfo.FileName | Should -BeExactly ([IO.Path]::GetFullPath($pythonPath))
        @($startInfo.ArgumentList) | Should -Be @(
            '-IBm',
            'azure.cli',
            'bicep',
            'build',
            '--stdout'
        )
        $startInfo.FileName | Should -Not -Match '(?i)(?:^|[\\/])az$'
        $startInfo.UseShellExecute | Should -BeFalse
    }

    It 'fails closed when an extensionless Azure CLI shim has no supported sibling launcher' {
        $script:CompilerFunctionCount | Should -Be 2

        $commandDirectory = New-Item -ItemType Directory -Path (
            Join-Path $TestDrive 'Azure CLI shim only/wbin') -Force
        $shimPath = Join-Path $commandDirectory.FullName 'az'
        Set-Content -LiteralPath $shimPath -Value '#!/usr/bin/env bash'
        Set-Content -LiteralPath (Join-Path $commandDirectory.FullName 'azps.ps1') -Value ''

        {
            & $script:CompilerModule {
                param($path)
                Resolve-GatewayBicepCompilerCommand `
                    -AzureCliPath $path `
                    -WindowsPlatform $true
            } $shimPath
        } | Should -Throw '*supported Windows executable process boundary*'
    }

    It 'fails closed when a Windows az.cmd launcher has no bundled Python executable' {
        $script:CompilerFunctionCount | Should -Be 2

        $commandDirectory = New-Item -ItemType Directory -Path (
            Join-Path $TestDrive 'Azure CLI without Python/wbin') -Force
        $commandPath = Join-Path $commandDirectory.FullName 'az.cmd'
        Set-Content -LiteralPath $commandPath -Value '@exit /b 0'

        {
            & $script:CompilerModule {
                param($path)
                Resolve-GatewayBicepCompilerCommand `
                    -AzureCliPath $path `
                    -WindowsPlatform $true
            } $commandPath
        } | Should -Throw '*bundled Python*'
    }

    It 'never assigns the az command source directly to a no-shell process' {
        $script:CompilerSource |
            Should -Not -Match '(?m)\.FileName\s*=\s*\$azCommand\.Source'
    }

    It 'binds exactly one az command source when PATH exposes several candidates' {
        # An unbounded Get-Command result yields an array whose Source casts to a
        # space-joined string, which is not a real path on any platform.
        $script:CompilerSource | Should -Match (
            '(?ms)@\(Get-Command az -CommandType Application -ErrorAction Stop\)\s*\|\s*' +
            'Select-Object -First 1')
        $script:CompilerSource |
            Should -Not -Match '(?m)^\s*\$azCommand\s*=\s*Get-Command az[^\r\n]*$'
    }

    It 'compiles every Bicep template in the hosted Windows bootstrap lane' {
        $workflow = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot '.github/workflows/build-and-test.yml') -Raw

        $workflow | Should -Match (
            "(?ms)- name: Compile every Bicep template on Windows\s+" +
            "if: runner\.os == 'Windows'\s+" +
            'shell: pwsh\s+' +
            'run: \./tools/Test-BootstrapSource\.ps1 -CompileBicep')
    }
}
