BeforeAll {
    $launcherSource = Join-Path $PSScriptRoot '..\..\gateway.cmd'

    function Invoke-OfflineGatewayLauncher {
        param([Parameter(Mandatory)][string]$Body)

        $root = Join-Path $TestDrive ("launcher fixture $([guid]::NewGuid().ToString('N'))")
        [IO.Directory]::CreateDirectory((Join-Path $root 'bootstrap')) | Out-Null
        Copy-Item -LiteralPath $launcherSource -Destination (Join-Path $root 'gateway.cmd')
        $parameters = 'param([string]$Mode, [string]$OutputFormat, [switch]$NonInteractive, [bool]$InstallPrerequisites)'
        [IO.File]::WriteAllText((Join-Path $root 'bootstrap\bootstrap.ps1'), "$parameters`n$Body")

        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $start.Arguments = '/d /s /c ""' + (Join-Path $root 'gateway.cmd') + '" plan --json --non-interactive --no-install"'
        $start.WorkingDirectory = $root
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.CreateNoWindow = $true
        $start.Environment.Clear()
        $start.Environment['SystemRoot'] = $env:SystemRoot
        $start.Environment['PATH'] = $PSHOME + ';' + (Join-Path $env:SystemRoot 'System32')
        $start.Environment['PATHEXT'] = '.COM;.EXE;.BAT;.CMD'
        $start.Environment['TEMP'] = $root
        $start.Environment['TMP'] = $root
        $start.Environment['USERPROFILE'] = $root
        $start.Environment['AZURE_CONFIG_DIR'] = Join-Path $root 'no-azure-session'
        $start.Environment['AZD_CONFIG_DIR'] = Join-Path $root 'no-azd-session'

        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) {
                throw 'The owned offline launcher fixture did not finish within 30 seconds.'
            }
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Output = $stdout.GetAwaiter().GetResult()
                Error = $stderr.GetAwaiter().GetResult()
            }
        }
        finally {
            if (-not $process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            $process.Dispose()
        }
    }
}

if ($IsWindows) {
    Describe 'Windows terminal launcher status' {
        It 'returns failure when the bootstrap script exits unsuccessfully' -ForEach @(1, 7) {
            $result = Invoke-OfflineGatewayLauncher -Body "Write-Output 'fixture-failure'; exit $_"
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'fixture-failure'
        }

        It 'returns success for a normally completed bootstrap script' {
            $result = Invoke-OfflineGatewayLauncher -Body "Write-Output 'fixture-success'"
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'fixture-success'
            $result.Error | Should -BeNullOrEmpty
        }

        It 'does not misreport a handled native failure as the final script outcome' {
            $result = Invoke-OfflineGatewayLauncher -Body '$global:LASTEXITCODE = 23; Write-Output ''fixture-success'''
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'fixture-success'
        }

        It 'fails safely without exposing a startup exception body' {
            $result = Invoke-OfflineGatewayLauncher -Body "throw 'fixture-sensitive-exception'"
            $result.ExitCode | Should -Be 1
            $result.Error | Should -Match 'Gateway bootstrap could not start safely'
            ($result.Output + $result.Error) | Should -Not -Match 'fixture-sensitive-exception'
        }
    }
}
