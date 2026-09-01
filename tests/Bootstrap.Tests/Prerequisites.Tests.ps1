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
