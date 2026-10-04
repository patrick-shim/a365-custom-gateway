#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../modules/Common.psm1" -Force -DisableNameChecking
$parent = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../.bootstrap/evidence/runtime'))
$fixture = Join-Path $parent ('source-manifest-test-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($name in @('src/main.cs','web/console/src/App.tsx','deploy/runtime/docker-compose.yml',
        'tools/scripts/legacy-azure/apply-migrations.ps1','tools/apply-migrations.ps1','tools/Gateway.Setup/Program.cs',
        'web/console/dist/generated.js','web/console/node_modules/dependency/index.js',
        'web/console/tsconfig.tsbuildinfo','deploy/runtime/.env.runtime')) {
        $path = Join-Path $fixture $name
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $path)
        Set-Content -LiteralPath $path -Value 'synthetic fixture' -Encoding utf8
    }
    $before = @(Get-BootstrapSourceManifest -Root $fixture)
    $paths = @($before | ForEach-Object { $_.path.Replace('\','/') })
    foreach ($name in @('src/main.cs','web/console/src/App.tsx','deploy/runtime/docker-compose.yml',
        'tools/Gateway.Setup/Program.cs')) {
        if ($name -notin $paths) { throw "Source manifest omitted $name" }
    }
    if ($paths.Count -ne 4) { throw 'Generated or runtime files entered the source manifest.' }
    Set-Content -LiteralPath (Join-Path $fixture 'web/console/src/App.tsx') -Value 'changed frontend' -Encoding utf8
    $after = @(Get-BootstrapSourceManifest -Root $fixture)
    if (($before | ConvertTo-Json -Compress) -ceq ($after | ConvertTo-Json -Compress)) { throw 'Frontend change did not invalidate the source manifest.' }
    'Source manifest covers frontend/Compose, excludes retired tooling paths, and excludes generated/runtime files.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith($parent + [IO.Path]::DirectorySeparatorChar) -or
        (Split-Path $resolved -Leaf) -notmatch '^source-manifest-test-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
