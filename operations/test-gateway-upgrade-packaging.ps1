#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradePackaging.psm1') -Force -DisableNameChecking -PassThru

$root = Join-Path ([IO.Path]::GetTempPath()) ('gateway-packaging-test-' + [guid]::NewGuid().ToString('N'))
$executor = Join-Path $root 'src\Gateway.Purview.Executor'
$other = Join-Path $root 'src\Unrelated'
try {
    [IO.Directory]::CreateDirectory($executor) | Out-Null
    [IO.Directory]::CreateDirectory($other) | Out-Null
    [IO.File]::WriteAllText((Join-Path $executor 'web.config'), '<configuration />')
    [IO.File]::WriteAllText((Join-Path $executor 'appsettings.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $executor 'other.config'), '<configuration />')
    [IO.File]::WriteAllText((Join-Path $other 'web.config'), '<configuration />')
    [IO.File]::WriteAllText((Join-Path $other 'Example.cs'), 'internal sealed class Example {}')

    $inventory = & $module { param($path) Get-GatewayUpgradePackagingInventory -Root $path } $root
    if (-not $inventory.ContainsKey('src\Gateway.Purview.Executor\web.config')) {
        throw 'The reviewed executor IIS configuration was omitted.'
    }
    foreach ($path in @('src\Gateway.Purview.Executor\appsettings.json',
        'src\Gateway.Purview.Executor\other.config', 'src\Unrelated\web.config')) {
        if ($inventory.ContainsKey($path)) { throw "An unreviewed configuration was admitted: $path" }
    }
    if (-not $inventory.ContainsKey('src\Unrelated\Example.cs') -or $inventory.Count -ne 2) {
        throw 'The source inventory changed outside the exact IIS configuration allowlist.'
    }
    $sourceHash = & $module { param($path) Get-GatewayUpgradeFileHash $path } (Join-Path $executor 'web.config')
    if ($inventory['src\Gateway.Purview.Executor\web.config'].sha256 -cne $sourceHash) {
        throw 'The reviewed IIS configuration hash was not preserved.'
    }

    Write-Output 'PASS: exact executor web.config retained; unrelated configs excluded; source hashing preserved.'
}
finally {
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
