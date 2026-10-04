#Requires -Version 7.0
[CmdletBinding()]
param([switch]$NoOpen)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($tool in @('node','npm','dotnet')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Graphical setup needs $tool. Install Node.js LTS and .NET 10, then run gateway gui again. Terminal setup remains available with gateway up." }
}
Push-Location (Join-Path $root 'web/setup')
try {
    Write-Host 'Preparing the graphical installer...'
    $dependencyStamp = Join-Path (Get-Location) 'node_modules/.gateway-setup-dependencies'
    $dependencyHash = ((Get-FileHash package.json,package-lock.json -Algorithm SHA256).Hash -join ':') + ':' + (& node --version)
    if (-not (Test-Path $dependencyStamp) -or (Get-Content $dependencyStamp -Raw).Trim() -cne $dependencyHash -or
        -not (Test-Path 'node_modules/vite/bin/vite.js')) {
        & npm ci --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'Setup dependencies could not be installed.' }
        Set-Content -LiteralPath $dependencyStamp -Value $dependencyHash -NoNewline
    }
    & npm run build
    if ($LASTEXITCODE -ne 0) { throw 'The graphical installer did not build.' }
} finally { Pop-Location }
$launch=@('run','--project',(Join-Path $root 'tools/Gateway.Setup'),'--','--repo-root',$root)
if ($NoOpen) { $launch+='--no-open' }
& dotnet @launch
exit $LASTEXITCODE
