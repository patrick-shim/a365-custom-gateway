[System.Environment]::SetEnvironmentVariable('ProgramFiles(x86)', 'C:\Program Files (x86)', 'Process')
Write-Host "ProgramFiles(x86) = $([System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)'))"

Set-Location 'C:\Users\patrickshim\Documents\Projects\A365\a365-custom-gateway'

Write-Host "`n=== RESTORING ==="
$restoreResult = & 'C:\Program Files\dotnet\dotnet.exe' restore src/A365Gateway.slnx --configfile nuget.config --verbosity minimal 2>&1
$restoreResult | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Host "RESTORE FAILED: $LASTEXITCODE"
    exit 1
}

Write-Host "`n=== BUILDING ==="
$buildResult = & 'C:\Program Files\dotnet\dotnet.exe' build src/Gateway.Api/Gateway.Api.csproj --configuration Debug --no-restore 2>&1
$buildResult | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Host "BUILD FAILED: $LASTEXITCODE"
    exit 1
}

Write-Host "`n=== SUCCESS ==="
