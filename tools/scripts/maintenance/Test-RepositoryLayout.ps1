#Requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
Push-Location $repository
try {
    # Honor git ignores so credentials, runtime snapshots and generated files are never scanned.
    $files = @(& git -c core.quotepath=false ls-files --cached --others --exclude-standard | Sort-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate repository sources.' }
    $failures = [Collections.Generic.List[string]]::new()
    $retiredRoots = @('src/Gateway.AdminUi/', 'src/Gateway.Purview.Executor/',
        'src/Gateway.Purview.Executor.StartupDiagnostics/', 'src/Gateway.Purview.PowerShellHost/',
        'src/Gateway.Purview.PackagePublisher/', 'tools/Gateway.DatabaseMigrator/',
        'infrastructure/sql/', 'tools/scripts/legacy-azure/')
    foreach ($file in $files) {
        foreach ($retiredRoot in $retiredRoots) {
            if ($file.StartsWith($retiredRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $failures.Add("Retired deployment source reintroduced: $file")
            }
        }
    }
    $scripts = @($files | Where-Object { $_ -match '\.ps(m)?1$' })
    foreach ($file in $scripts) {
        $parseTokens = $null; $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository $file), [ref]$parseTokens, [ref]$parseErrors)
        foreach ($error in $parseErrors) { $failures.Add("${file}:$($error.Extent.StartLineNumber): $($error.Message)") }
        if ($file -notmatch '^(bootstrap/|operations/|src/|tests/|tools/scripts/)') {
            $failures.Add("Unclassified PowerShell script: $file")
        }
    }
    [xml]$solution = Get-Content -Raw -LiteralPath (Join-Path $repository 'Gateway.slnx')
    $listed = @($solution.SelectNodes('//Project') | ForEach-Object { $_.Path.Replace('\','/') })
    $projects = @($files | Where-Object { $_ -match '\.csproj$' })
    foreach ($project in $projects) {
        if ($project -notin $listed) { $failures.Add("Project absent from Gateway.slnx: $project") }
        [xml]$xml = Get-Content -Raw -LiteralPath (Join-Path $repository $project)
        foreach ($package in $xml.SelectNodes('//PackageReference')) {
            if ($package.Include -in @('Microsoft.EntityFrameworkCore.SqlServer', 'Microsoft.Data.SqlClient',
                'Azure.Storage.Blobs', 'Azure.Messaging.ServiceBus', 'Azure.Security.KeyVault.Secrets')) {
                $failures.Add("Retired hosting dependency in ${project}: $($package.Include)")
            }
        }
        foreach ($reference in $xml.SelectNodes('//ProjectReference')) {
            $target = [IO.Path]::GetFullPath((Join-Path (Split-Path (Join-Path $repository $project)) $reference.Include))
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $failures.Add("Missing project reference in ${project}: $($reference.Include)") }
        }
    }
    foreach ($project in $listed) { if ($project -notin $projects) { $failures.Add("Solution points at absent project: $project") } }
    if ($failures.Count) { throw ($failures -join [Environment]::NewLine) }
    Write-Output "Repository layout passed: $($projects.Count) projects, $($scripts.Count) PowerShell sources parsed. Ignored runtime state excluded."
}
finally { Pop-Location }
