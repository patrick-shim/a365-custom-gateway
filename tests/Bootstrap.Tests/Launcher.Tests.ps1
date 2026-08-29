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
