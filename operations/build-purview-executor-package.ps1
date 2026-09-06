#Requires -Version 7.0
<#
.SYNOPSIS
Builds a content-addressed Windows Purview executor package without deploying it.
.DESCRIPTION
Requires installed Microsoft-signed PowerShell 7.6.5 and ExchangeOnlineManagement
3.10.1. Copies only their installation directories, never a user profile or cache.
The output directory must be new and inside the repository's ignored runtime area.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$PowerShellDirectory = $PSHOME
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess) {
    throw 'Purview executor packaging requires Windows x64.'
}
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Common.psm1') -Force -DisableNameChecking
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$allowedRoots = @('.bootstrap', '.agent-runtime') | ForEach-Object {
    [IO.Path]::GetFullPath((Join-Path $repositoryRoot $_)).TrimEnd('\') + '\'
}
if (-not @($allowedRoots | Where-Object { $outputRoot.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -or
    (Test-Path -LiteralPath $outputRoot)) {
    throw 'Executor package output must be a new directory under this repository .bootstrap or .agent-runtime.'
}
$powerShellRoot = [IO.Path]::GetFullPath($PowerShellDirectory)
$powerShellPath = Join-Path $powerShellRoot 'pwsh.exe'
$signature = Get-AuthenticodeSignature -LiteralPath $powerShellPath
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Microsoft Corporation(,|$)') {
    throw 'Packaged PowerShell must have a valid Microsoft Authenticode signature.'
}
$runtimeVersion = & $powerShellPath -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
if ($LASTEXITCODE -ne 0 -or [string]$runtimeVersion -cne '7.6.5') {
    throw 'This executor package requires PowerShell 7.6.5 exactly.'
}
$modules = @(Get-Module -ListAvailable -FullyQualifiedName @{ ModuleName = 'ExchangeOnlineManagement'; RequiredVersion = '3.10.1' })
if ($modules.Count -ne 1) { throw 'Exactly one installed ExchangeOnlineManagement 3.10.1 module is required.' }
$moduleRoot = [IO.Path]::GetFullPath($modules[0].ModuleBase)
$moduleManifest = Join-Path $moduleRoot 'ExchangeOnlineManagement.psd1'
$moduleSignature = Get-AuthenticodeSignature -LiteralPath $moduleManifest
if ($moduleSignature.Status -ne 'Valid' -or $moduleSignature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Microsoft Corporation(,|$)') {
    throw 'The pinned ExchangeOnlineManagement module must have a valid Microsoft signature.'
}
foreach ($sourceRoot in @($powerShellRoot, $moduleRoot)) {
    if (([IO.File]::GetAttributes($sourceRoot) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Executor dependency roots cannot be reparse points.'
    }
    foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($sourceRoot, '*', [IO.SearchOption]::AllDirectories)) {
        if (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Executor dependencies cannot contain reparse points.'
        }
    }
}
$sourceFingerprint = Get-BootstrapSourceFingerprint -Root $repositoryRoot
$publishDirectory = Join-Path $outputRoot 'publish'
[IO.Directory]::CreateDirectory($publishDirectory) | Out-Null
& dotnet publish (Join-Path $repositoryRoot 'src/Gateway.Purview.Executor/Gateway.Purview.Executor.csproj') `
    -c Release -r win-x64 --self-contained true -o $publishDirectory /p:UseAppHost=true
if ($LASTEXITCODE -ne 0) { throw 'Windows executor publish failed.' }
Copy-Item -LiteralPath $powerShellRoot -Destination (Join-Path $publishDirectory 'PowerShell') -Recurse
$moduleDestination = Join-Path $publishDirectory 'PowerShellModules/ExchangeOnlineManagement/3.10.1'
[IO.Directory]::CreateDirectory((Split-Path -Parent $moduleDestination)) | Out-Null
Copy-Item -LiteralPath $moduleRoot -Destination $moduleDestination -Recurse
$files = @([IO.Directory]::EnumerateFiles($publishDirectory, '*', [IO.SearchOption]::AllDirectories) | ForEach-Object {
    [ordered]@{
        path = [IO.Path]::GetRelativePath($publishDirectory, $_).Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
    }
} | Sort-Object { $_.path })
$manifest = [ordered]@{
    schemaVersion = 1
    sourceFingerprint = $sourceFingerprint
    powerShellVersion = '7.6.5'
    exchangeOnlineManagementVersion = '3.10.1'
    files = $files
}
$manifestPath = Join-Path $publishDirectory 'executor-runtime.json'
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
$temporaryPackage = Join-Path $outputRoot 'executor.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($publishDirectory, $temporaryPackage,
    [IO.Compression.CompressionLevel]::Optimal, $false)
if ((Get-Item -LiteralPath $temporaryPackage).Length -gt 1GB) { throw 'Executor ZIP exceeds the App Service one-gigabyte limit.' }
$packageHash = (Get-FileHash -LiteralPath $temporaryPackage -Algorithm SHA256).Hash.ToLowerInvariant()
$packagePath = Join-Path $outputRoot ($packageHash + '.zip')
Move-Item -LiteralPath $temporaryPackage -Destination $packagePath
$receipt = [ordered]@{
    schemaVersion = 1
    sourceFingerprint = $sourceFingerprint
    packageDigest = 'sha256:' + $packageHash
    runtimeManifestDigest = 'sha256:' + (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    packageFileName = [IO.Path]::GetFileName($packagePath)
    packageBytes = (Get-Item -LiteralPath $packagePath).Length
    powerShellVersion = '7.6.5'
    exchangeOnlineManagementVersion = '3.10.1'
    fileCount = $files.Count
}
$receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRoot 'package-receipt.json') -Encoding utf8NoBOM
$receipt
