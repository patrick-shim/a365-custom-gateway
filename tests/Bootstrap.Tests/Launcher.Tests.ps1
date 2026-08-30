Describe 'POSIX gateway launcher routing boundary' -Skip:$IsWindows {
    BeforeAll {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    }

    It 'routes status and no-install to PowerShell without running the bootstrap itself' {
        $pwshStub = Join-Path $TestDrive 'pwsh'
        $marker = Join-Path $TestDrive 'pwsh-arguments.txt'
        @'
#!/bin/sh
printf '%s\n' "$@" > "$GATEWAY_TEST_MARKER"
'@ | Set-Content -LiteralPath $pwshStub -Encoding utf8NoBOM
        & chmod 700 $pwshStub
        $LASTEXITCODE | Should -Be 0

        $originalPath = $env:PATH
        $originalMarker = $env:GATEWAY_TEST_MARKER
        try {
            $env:PATH = "$TestDrive$([IO.Path]::PathSeparator)$originalPath"
            $env:GATEWAY_TEST_MARKER = $marker
            $launcher = Join-Path $repositoryRoot 'gateway'

            & bash $launcher status --no-install --json

            $LASTEXITCODE | Should -Be 0
            $arguments = @(Get-Content -LiteralPath $marker)
            $arguments | Should -Contain '-Mode'
            $arguments | Should -Contain 'Status'
            $arguments | Should -Contain '-InstallPrerequisites:$false'
            $arguments | Should -Contain '-OutputFormat'
            $arguments | Should -Contain 'Json'
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_MARKER = $originalMarker
        }
    }

    It 'routes the public database recovery command and explicit authorization to PowerShell' {
        $pwshStub = Join-Path $TestDrive 'pwsh'
        $marker = Join-Path $TestDrive 'recovery-pwsh-arguments.txt'
        @'
#!/bin/sh
printf '%s\n' "$@" > "$GATEWAY_TEST_MARKER"
'@ | Set-Content -LiteralPath $pwshStub -Encoding utf8NoBOM
        & chmod 700 $pwshStub
        $LASTEXITCODE | Should -Be 0

        $originalPath = $env:PATH
        $originalMarker = $env:GATEWAY_TEST_MARKER
        try {
            $env:PATH = "$TestDrive$([IO.Path]::PathSeparator)$originalPath"
            $env:GATEWAY_TEST_MARKER = $marker
            $launcher = Join-Path $repositoryRoot 'gateway'
            $configPath = 'bootstrap/config.json'

            & bash $launcher recover-database --config $configPath --yes

            $LASTEXITCODE | Should -Be 0
            $arguments = @(Get-Content -LiteralPath $marker)
            $arguments | Should -Contain '-Mode'
            $arguments | Should -Contain 'RecoverDatabase'
            $arguments | Should -Contain '-Config'
            $arguments | Should -Contain $configPath
            $arguments | Should -Contain '-Yes'
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_MARKER = $originalMarker
        }
    }

    It 'routes the one-shot manual database repair command and explicit authorization to PowerShell' {
        $pwshStub = Join-Path $TestDrive 'pwsh'
        $marker = Join-Path $TestDrive 'repair-pwsh-arguments.txt'
        @'
#!/bin/sh
printf '%s\n' "$@" > "$GATEWAY_TEST_MARKER"
'@ | Set-Content -LiteralPath $pwshStub -Encoding utf8NoBOM
        & chmod 700 $pwshStub

        $originalPath = $env:PATH
        $originalMarker = $env:GATEWAY_TEST_MARKER
        try {
            $env:PATH = "$TestDrive$([IO.Path]::PathSeparator)$originalPath"
            $env:GATEWAY_TEST_MARKER = $marker
            & bash (Join-Path $repositoryRoot 'gateway') repair-database --config bootstrap/config.json --yes

            $LASTEXITCODE | Should -Be 0
            $arguments = @(Get-Content -LiteralPath $marker)
            $arguments | Should -Contain '-Mode'
            $arguments | Should -Contain 'RepairDatabase'
            $arguments | Should -Contain '-Yes'
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_MARKER = $originalMarker
        }
    }

    It 'routes the narrow recovered-bootstrap continuation and exact fingerprint' {
        $pwshStub = Join-Path $TestDrive 'pwsh'
        $marker = Join-Path $TestDrive 'continuation-pwsh-arguments.txt'
        @'
#!/bin/sh
printf '%s\n' "$@" > "$GATEWAY_TEST_MARKER"
'@ | Set-Content -LiteralPath $pwshStub -Encoding utf8NoBOM
        & chmod 700 $pwshStub
        $fingerprint = 'sha256:' + ('a' * 64)
        $originalPath = $env:PATH
        $originalMarker = $env:GATEWAY_TEST_MARKER
        try {
            $env:PATH = "$TestDrive$([IO.Path]::PathSeparator)$originalPath"
            $env:GATEWAY_TEST_MARKER = $marker
            & bash (Join-Path $repositoryRoot 'gateway') continue-bootstrap --config bootstrap/config.json --yes --expected-continuation-fingerprint $fingerprint

            $LASTEXITCODE | Should -Be 0
            $arguments = @(Get-Content -LiteralPath $marker)
            $arguments | Should -Contain (Join-Path $repositoryRoot 'operations/continue-bootstrap-after-database-recovery.ps1')
            $arguments | Should -Contain '-ExpectedContinuationFingerprint'
            $arguments | Should -Contain $fingerprint
            $arguments | Should -Contain '-Yes'
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_MARKER = $originalMarker
        }
    }

    It 'rejects an unknown command before invoking PowerShell' {
        $pwshStub = Join-Path $TestDrive 'pwsh'
        $marker = Join-Path $TestDrive 'pwsh-was-invoked.txt'
        @'
#!/bin/sh
touch "$GATEWAY_TEST_MARKER"
'@ | Set-Content -LiteralPath $pwshStub -Encoding utf8NoBOM
        & chmod 700 $pwshStub

        $originalPath = $env:PATH
        $originalMarker = $env:GATEWAY_TEST_MARKER
        try {
            $env:PATH = "$TestDrive$([IO.Path]::PathSeparator)$originalPath"
            $env:GATEWAY_TEST_MARKER = $marker
            $launcher = Join-Path $repositoryRoot 'gateway'

            & bash $launcher unknown-command 2>$null | Out-Null

            $LASTEXITCODE | Should -Be 2
            Test-Path -LiteralPath $marker | Should -BeFalse
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_MARKER = $originalMarker
        }
    }

    It 'reports each missing setup runtime before starting the UI host' {
        $launcher = Join-Path $repositoryRoot 'gateway'
        $bashPath = (Get-Command bash -ErrorAction Stop).Source
        $chmodPath = (Get-Command chmod -ErrorAction Stop).Source
        $originalPath = $env:PATH
        $originalRepositoryRoot = $env:GATEWAY_TEST_REPOSITORY_ROOT
        $originalMarker = $env:GATEWAY_TEST_DOTNET_HOST_MARKER
        try {
            foreach ($case in @(
                @{ Missing = 'dotnet'; Message = 'Setup requires the .NET 10 SDK.' },
                @{ Missing = 'pwsh'; Message = 'Setup requires PowerShell 7 (pwsh).' },
                @{ Missing = 'az'; Message = 'Setup requires Azure CLI (az).' }
            )) {
                $stubDirectory = Join-Path $TestDrive "setup-missing-$($case.Missing)"
                $null = New-Item -ItemType Directory -Path $stubDirectory -Force
                @'
#!/bin/sh
printf '%s\n' "$GATEWAY_TEST_REPOSITORY_ROOT"
'@ | Set-Content -LiteralPath (Join-Path $stubDirectory 'dirname') -Encoding utf8NoBOM

                if ($case.Missing -ne 'dotnet') {
                    @'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf '10.0.100\n'
  exit 0
fi
: > "$GATEWAY_TEST_DOTNET_HOST_MARKER"
'@ | Set-Content -LiteralPath (Join-Path $stubDirectory 'dotnet') -Encoding utf8NoBOM
                }
                if ($case.Missing -ne 'pwsh') {
                    "#!/bin/sh`nexit 0`n" | Set-Content -LiteralPath (Join-Path $stubDirectory 'pwsh') -Encoding utf8NoBOM
                }
                if ($case.Missing -ne 'az') {
                    "#!/bin/sh`nexit 0`n" | Set-Content -LiteralPath (Join-Path $stubDirectory 'az') -Encoding utf8NoBOM
                }

                Get-ChildItem -LiteralPath $stubDirectory -File | ForEach-Object {
                    & $chmodPath 700 $_.FullName
                    $LASTEXITCODE | Should -Be 0
                }

                $marker = Join-Path $stubDirectory 'dotnet-hosted-ui.txt'
                $env:PATH = $stubDirectory
                $env:GATEWAY_TEST_REPOSITORY_ROOT = $repositoryRoot
                $env:GATEWAY_TEST_DOTNET_HOST_MARKER = $marker

                $output = (& $bashPath $launcher setup 2>&1 | Out-String)

                $LASTEXITCODE | Should -Be 1
                $output | Should -Match ([regex]::Escape($case.Message))
                $output | Should -Match ([regex]::Escape('Install or repair the listed tools'))
                Test-Path -LiteralPath $marker | Should -BeFalse
            }
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_REPOSITORY_ROOT = $originalRepositoryRoot
            $env:GATEWAY_TEST_DOTNET_HOST_MARKER = $originalMarker
        }
    }

    It 'starts setup only after all three runtime probes succeed' {
        $launcher = Join-Path $repositoryRoot 'gateway'
        $bashPath = (Get-Command bash -ErrorAction Stop).Source
        $chmodPath = (Get-Command chmod -ErrorAction Stop).Source
        $stubDirectory = Join-Path $TestDrive 'setup-ready'
        $null = New-Item -ItemType Directory -Path $stubDirectory -Force
        @'
#!/bin/sh
printf '%s\n' "$GATEWAY_TEST_REPOSITORY_ROOT"
'@ | Set-Content -LiteralPath (Join-Path $stubDirectory 'dirname') -Encoding utf8NoBOM
        @'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf '10.0.100\n'
  exit 0
fi
printf '%s\n' "$@" > "$GATEWAY_TEST_DOTNET_ARGUMENTS"
'@ | Set-Content -LiteralPath (Join-Path $stubDirectory 'dotnet') -Encoding utf8NoBOM
        "#!/bin/sh`nexit 0`n" | Set-Content -LiteralPath (Join-Path $stubDirectory 'pwsh') -Encoding utf8NoBOM
        "#!/bin/sh`nexit 0`n" | Set-Content -LiteralPath (Join-Path $stubDirectory 'az') -Encoding utf8NoBOM
        Get-ChildItem -LiteralPath $stubDirectory -File | ForEach-Object {
            & $chmodPath 700 $_.FullName
            $LASTEXITCODE | Should -Be 0
        }

        $argumentRecord = Join-Path $stubDirectory 'dotnet-arguments.txt'
        $originalPath = $env:PATH
        $originalRepositoryRoot = $env:GATEWAY_TEST_REPOSITORY_ROOT
        $originalArguments = $env:GATEWAY_TEST_DOTNET_ARGUMENTS
        try {
            $env:PATH = $stubDirectory
            $env:GATEWAY_TEST_REPOSITORY_ROOT = $repositoryRoot
            $env:GATEWAY_TEST_DOTNET_ARGUMENTS = $argumentRecord

            & $bashPath $launcher setup --no-open

            $LASTEXITCODE | Should -Be 0
            $arguments = @(Get-Content -LiteralPath $argumentRecord)
            $arguments | Should -Contain 'run'
            $arguments | Should -Contain '--project'
            $arguments | Should -Contain (Join-Path $repositoryRoot 'tools/Gateway.Setup/Gateway.Setup.csproj')
            $arguments | Should -Contain '--repo-root'
            $arguments | Should -Contain $repositoryRoot
            $arguments | Should -Contain '--no-open'
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_REPOSITORY_ROOT = $originalRepositoryRoot
            $env:GATEWAY_TEST_DOTNET_ARGUMENTS = $originalArguments
        }
    }
}

Describe 'Cross-platform guided setup prerequisite contract' {
    BeforeAll {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    }

    It 'keeps the Windows launcher aligned with the POSIX runtime gate' {
        $launcher = Get-Content -LiteralPath (Join-Path $repositoryRoot 'gateway.cmd') -Raw
        $runSetup = $launcher.IndexOf(':run_setup', [StringComparison]::OrdinalIgnoreCase)
        $preflight = $launcher.IndexOf('call :check_setup_prerequisites', $runSetup, [StringComparison]::OrdinalIgnoreCase)
        $hostIndex = $launcher.IndexOf('dotnet run --project', $runSetup, [StringComparison]::OrdinalIgnoreCase)

        $runSetup | Should -BeGreaterOrEqual 0
        $preflight | Should -BeGreaterThan $runSetup
        $hostIndex | Should -BeGreaterThan $preflight
        $launcher | Should -Match 'where pwsh\.exe'
        $launcher | Should -Match 'PSVersionTable\.PSVersion\.Major -ge 7'
        $launcher | Should -Match 'where dotnet\.exe'
        $launcher | Should -Match 'dotnet --version'
        $launcher | Should -Match 'where az'
        $launcher | Should -Match 'call az version'
        $launcher | Should -Match 'Setup requires PowerShell 7'
        $launcher | Should -Match 'Setup requires the \.NET 10 SDK'
        $launcher | Should -Match 'Setup requires Azure CLI'
        $launcher | Should -Match 'if /I "%COMMAND%"=="recover-database" set "GATEWAY_MODE=RecoverDatabase"'
        $launcher | Should -Match 'if /I "%COMMAND%"=="repair-database" set "GATEWAY_MODE=RepairDatabase"'
        $launcher | Should -Match 'if /I "%COMMAND%"=="continue-bootstrap" set "GATEWAY_MODE=ContinueBootstrap"'
        $launcher | Should -Match 'operations\\continue-bootstrap-after-database-recovery\.ps1'
    }
}

Describe 'Windows gateway launcher mutation boundary' -Skip:(-not $IsWindows) {
    BeforeAll {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    }

    It 'never invokes winget when --no-install is present and PowerShell is unavailable' {
        $whereStub = Join-Path $TestDrive 'where.cmd'
        $wingetStub = Join-Path $TestDrive 'winget.cmd'
        $marker = Join-Path $TestDrive 'winget-was-invoked.txt'
        '@exit /b 1' | Set-Content -LiteralPath $whereStub -Encoding ascii
        '@echo invoked>"%GATEWAY_TEST_MARKER%"' | Set-Content -LiteralPath $wingetStub -Encoding ascii

        $originalPath = $env:Path
        $originalProgramFiles = $env:ProgramFiles
        $originalMarker = $env:GATEWAY_TEST_MARKER
        try {
            $env:Path = $TestDrive
            $env:ProgramFiles = Join-Path $TestDrive 'missing-program-files'
            $env:GATEWAY_TEST_MARKER = $marker
            $launcher = Join-Path $repositoryRoot 'gateway.cmd'

            & $env:ComSpec /d /c "`"$launcher`" status --no-install" 2>$null | Out-Null

            $LASTEXITCODE | Should -Be 1
            Test-Path -LiteralPath $marker | Should -BeFalse
        }
        finally {
            $env:Path = $originalPath
            $env:ProgramFiles = $originalProgramFiles
            $env:GATEWAY_TEST_MARKER = $originalMarker
        }
    }
}
