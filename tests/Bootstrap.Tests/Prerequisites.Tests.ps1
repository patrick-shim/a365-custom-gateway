$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Prerequisites.psm1') -Force

Describe 'Bootstrap prerequisite native-command boundary' {
    InModuleScope Prerequisites {
        BeforeEach {
            Mock Assert-GatewayPlanPrerequisites { }
            Mock Test-CommandAvailable { $true }
            Mock Invoke-BootstrapCommand {
                if ($FilePath -ceq 'dotnet') { return '10.0.400' }
                if ($FilePath -ceq 'git') { return 'git version 2.55.0.windows.5' }
                if ([string]::Join('|', $ArgumentList) -ceq 'bicep|version') {
                    return 'Bicep CLI version 0.38.33'
                }
                if ([string]::Join('|', $ArgumentList) -ceq 'version|--output|json|--only-show-errors') {
                    return '{"azure-cli":"2.76.0"}'
                }
                throw 'Unexpected prerequisite command.'
            }
        }

        It 'uses the shared wrapper for every reported native-tool version' {
            $result = Assert-BootstrapPrerequisites

            $result.azureCli | Should -BeExactly '2.76.0'
            $result.dotnet | Should -BeExactly '10.0.400'
            $result.git | Should -BeExactly 'git version 2.55.0.windows.5'
            $result.bicep | Should -BeExactly 'Bicep CLI version 0.38.33'
            Should -Invoke Invoke-BootstrapCommand -Times 4 -Exactly
            Should -Invoke Invoke-BootstrapCommand -Times 1 -Exactly -ParameterFilter {
                $FilePath -ceq 'az' -and
                [bool]$CaptureStdoutOnly -and
                [string]::Join('|', $ArgumentList) -ceq 'version|--output|json|--only-show-errors'
            }
        }

        It 'places the Purview Windows-only gate before every tool or module probe' {
            $modulePath = (Get-Module -Name Prerequisites -ErrorAction Stop).Path
            $source = Get-Content -LiteralPath $modulePath -Raw
            $functionStart = $source.IndexOf(
                'function Assert-BootstrapPrerequisites',
                [StringComparison]::Ordinal)
            $guard = $source.IndexOf(
                'if ($RequirePurview -and -not $IsWindows)',
                $functionStart,
                [StringComparison]::Ordinal)
            $planProbe = $source.IndexOf(
                'Assert-GatewayPlanPrerequisites -Install:$Install',
                $functionStart,
                [StringComparison]::Ordinal)

            $functionStart | Should -BeGreaterOrEqual 0
            $guard | Should -BeGreaterThan $functionStart
            $planProbe | Should -BeGreaterThan $guard

            if (-not $IsWindows) {
                { Assert-BootstrapPrerequisites -RequirePurview } |
                    Should -Throw '*does not support Security & Compliance PowerShell*'
                Should -Invoke Assert-GatewayPlanPrerequisites -Times 0 -Exactly
                Should -Invoke Invoke-BootstrapCommand -Times 0 -Exactly
            }
        }
    }
}

Describe 'Windows Bicep prerequisite repair' {
    InModuleScope Prerequisites {
        It 'maps the Windows operating-system architecture to <TargetPlatform>' -ForEach @(
            @{
                OSArchitecture = [System.Runtime.InteropServices.Architecture]::X64
                TargetPlatform = 'win-x64'
            },
            @{
                OSArchitecture = [System.Runtime.InteropServices.Architecture]::Arm64
                TargetPlatform = 'win-arm64'
            }
        ) {
            Get-BootstrapBicepRepairTargetPlatform `
                -WindowsPlatform $true `
                -OSArchitecture $OSArchitecture |
                Should -BeExactly $TargetPlatform
        }

        It 'repairs an incompatible Bicep binary in the exact <TargetPlatform> order' -ForEach @(
            @{ TargetPlatform = 'win-x64' },
            @{ TargetPlatform = 'win-arm64' }
        ) {
            $script:bicepVersionAttempts = 0
            $script:targetPlatform = $TargetPlatform
            $script:nativeCalls = [Collections.Generic.List[string]]::new()

            Mock Test-CommandAvailable { $true }
            Mock Get-BootstrapBicepRepairTargetPlatform { $script:targetPlatform }
            Mock Invoke-BootstrapCommand {
                $arguments = [string]::Join('|', @($ArgumentList))
                $script:nativeCalls.Add("$FilePath|$arguments")
                if ($FilePath -ceq 'dotnet' -and $arguments -ceq '--version') {
                    return '10.0.400'
                }
                if ($FilePath -ceq 'az' -and $arguments -ceq 'bicep|version') {
                    $script:bicepVersionAttempts++
                    if ($script:bicepVersionAttempts -eq 1) {
                        throw 'Synthetic incompatible Bicep binary.'
                    }
                    return 'Bicep CLI version 0.38.33'
                }
                if ($FilePath -ceq 'az' -and $arguments -ceq 'bicep|uninstall') {
                    return 0
                }
                if ($FilePath -ceq 'az' -and $arguments -ceq (
                        "bicep|install|--target-platform|$($script:targetPlatform)|--only-show-errors")) {
                    return 0
                }
                throw "Unexpected prerequisite command: $FilePath|$arguments"
            }

            $result = Assert-GatewayPlanPrerequisites -Install

            $result.bicep | Should -BeExactly 'Bicep CLI version 0.38.33'
            @($script:nativeCalls) | Should -Be @(
                'dotnet|--version',
                'az|bicep|version',
                'az|bicep|uninstall',
                "az|bicep|install|--target-platform|$TargetPlatform|--only-show-errors",
                'az|bicep|version'
            )
            Should -Invoke Invoke-BootstrapCommand -Times 1 -Exactly -ParameterFilter {
                $FilePath -ceq 'az' -and
                [bool]$NoCapture -and
                [string]::Join('|', $ArgumentList) -ceq 'bicep|uninstall'
            }
            Should -Invoke Invoke-BootstrapCommand -Times 1 -Exactly -ParameterFilter {
                $FilePath -ceq 'az' -and
                [bool]$NoCapture -and
                [string]::Join('|', $ArgumentList) -ceq (
                    "bicep|install|--target-platform|$TargetPlatform|--only-show-errors")
            }
        }

        It 'does not mutate Bicep when local prerequisite installation is disabled' {
            Mock Test-CommandAvailable { $true }
            Mock Invoke-BootstrapCommand {
                $arguments = [string]::Join('|', @($ArgumentList))
                if ($FilePath -ceq 'dotnet' -and $arguments -ceq '--version') {
                    return '10.0.400'
                }
                if ($FilePath -ceq 'az' -and $arguments -ceq 'bicep|version') {
                    throw 'Synthetic incompatible Bicep binary.'
                }
                throw "Unexpected prerequisite command: $FilePath|$arguments"
            }

            { Assert-GatewayPlanPrerequisites } |
                Should -Throw '*Bicep CLI is missing*'
            Should -Invoke Invoke-BootstrapCommand -Times 0 -Exactly -ParameterFilter {
                $FilePath -ceq 'az' -and
                $ArgumentList.Count -ge 2 -and
                [string]$ArgumentList[0] -ceq 'bicep' -and
                [string]$ArgumentList[1] -in @('uninstall', 'install')
            }
        }
    }
}

Describe 'Bootstrap PATH refresh' {
    InModuleScope Prerequisites {
        It 'preserves process-only entries while preferring refreshed machine and user PATH entries' {
            Merge-BootstrapProcessPath `
                -MachinePath 'C:\Windows;C:\Tools' `
                -UserPath 'C:\Users\Public\bin' `
                -ProcessPath 'C:\Portable;C:\WINDOWS;C:\CI' `
                -PathSeparator ';' |
                Should -BeExactly 'C:\Windows;C:\Tools;C:\Users\Public\bin;C:\Portable;C:\CI'
        }
    }
}

Describe 'Bootstrap local Bicep command allowlist' {
    BeforeEach {
        Clear-BootstrapAzureSubscriptionContext
        Set-BootstrapAzureSubscriptionContext `
            -SubscriptionId '11111111-1111-4111-8111-111111111111' `
            -TenantId '22222222-2222-4222-8222-222222222222'
    }

    AfterEach {
        Clear-BootstrapAzureSubscriptionContext
    }

    It 'allows only the exact local Bicep uninstall command' {
        @(Get-BootstrapAzureCliArguments -Arguments @('bicep', 'uninstall')) |
            Should -Be @('bicep', 'uninstall')
        { Get-BootstrapAzureCliArguments -Arguments @(
                'bicep', 'uninstall', '--only-show-errors') } |
            Should -Throw '*reviewed local Azure CLI Bicep commands*'
    }
}
