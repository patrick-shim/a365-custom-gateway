[System.Environment]::SetEnvironmentVariable('ProgramFiles(x86)', 'C:\Program Files (x86)', 'Process')

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'C:\Program Files\dotnet\dotnet.exe'
$psi.Arguments = 'restore src/A365Gateway.slnx --packages C:\Users\patrickshim\.nuget\packages --configfile nuget.config --verbosity minimal'
$psi.UseShellExecute = $false
$psi.WorkingDirectory = 'C:\Users\patrickshim\Documents\Projects\A365\a365-custom-gateway'

# Copy current env and add ProgramFiles(x86)
foreach ($key in [System.Environment]::GetEnvironmentVariables().Keys) {
    try { $psi.EnvironmentVariables[$key] = [System.Environment]::GetEnvironmentVariable($key) } catch {}
}
$psi.EnvironmentVariables['ProgramFiles(x86)'] = 'C:\Program Files (x86)'
$psi.EnvironmentVariables['DOTNET_ENVIRONMENT'] = 'Local'

Write-Host "Restoring packages..."
$proc = [System.Diagnostics.Process]::Start($psi)
$proc.WaitForExit(120000)
Write-Host "Restore exit code: $($proc.ExitCode)"

if ($proc.ExitCode -eq 0) {
    Write-Host "Restore OK. Building + running..."
    $psi2 = $psi.Clone()
    $psi2.Arguments = 'run --project src/Gateway.Api/Gateway.Api.csproj --urls http://localhost:5118 --no-launch-profile --no-restore'
    $psi2.EnvironmentVariables['ASPNETCORE_ENVIRONMENT'] = 'Local'
    $proc2 = [System.Diagnostics.Process]::Start($psi2)
    Write-Host "Started PID: $($proc2.Id)"
    Start-Sleep -Seconds 30
    if (-not $proc2.HasExited) {
        Write-Host "APP IS RUNNING on http://localhost:5118"
    } else {
        Write-Host "Exited: $($proc2.ExitCode)"
    }
}
