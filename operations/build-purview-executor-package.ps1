#Requires -Version 7.0
<#
.SYNOPSIS
Builds a content-addressed Windows Purview executor package without deploying it.
.DESCRIPTION
Requires installed Microsoft-signed PowerShell 7.6.5 and ExchangeOnlineManagement
3.10.1. Copies only their installation directories, never a user profile or cache.
Selects the first exact-version installation in PSModulePath order and pins its
absolute manifest path. An invalid or ambiguous candidate fails without fallback.
The output directory must be new and inside the repository's ignored runtime area.
#>
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Build')][string]$OutputDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Validate')][switch]$ValidateOnly,
    [string]$PowerShellDirectory = $PSHOME,
    [string]$ExpectedSourceFingerprint = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PurviewDependencyTree {
    param([Parameter(Mandatory)][string]$Root)
    # Check ancestors too: a version directory beneath a junction is not an
    # independent installation root. Never recurse through a reparse point.
    $directory = [IO.DirectoryInfo]::new($Root)
    for ($ancestor = $directory; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
        if (([IO.File]::GetAttributes($ancestor.FullName) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Executor dependency roots and ancestors cannot be reparse points.'
        }
    }
    if (-not $directory.Exists) { throw 'Executor dependency root must be an installed directory.' }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($directory.FullName)
    while ($pending.Count -gt 0) {
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop())) {
            $attributes = [IO.File]::GetAttributes($path)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Executor dependencies cannot contain reparse points.'
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($path) }
        }
    }
}

function Resolve-PurviewExecutorModuleRoot {
    param([AllowEmptyString()][string]$ModulePath = $env:PSModulePath)
    # PSModulePath differs with Windows PowerShell ancestry. Multiple installed
    # copies are normal, not an ambiguity across ordered search roots.
    # https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_psmodulepath
    # https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_modules
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $ModulePath.Split([IO.Path]::PathSeparator)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if (-not [IO.Path]::IsPathFullyQualified($entry)) {
            throw 'Executor module search paths must be absolute installation paths.'
        }
        $searchRoot = [IO.Path]::GetFullPath($entry)
        if (-not $seen.Add($searchRoot)) { continue }
        $moduleDirectory = Join-Path $searchRoot 'ExchangeOnlineManagement'
        $versionDirectory = Join-Path $moduleDirectory '3.10.1'
        $versionExists = Test-Path -LiteralPath $versionDirectory
        $unversionedExists = @('.psd1', '.psm1', '.dll') | Where-Object {
            Test-Path -LiteralPath (Join-Path $moduleDirectory ('ExchangeOnlineManagement' + $_))
        }
        if ($versionExists -and $unversionedExists) {
            throw 'The first ExchangeOnlineManagement installation is ambiguous: both versioned and unversioned candidates exist. Repair that installation before packaging.'
        }
        if (-not $versionExists -and -not $unversionedExists) { continue }
        $candidateRoot = if ($versionExists) { $versionDirectory } else { $moduleDirectory }
        # Inspect the path before module discovery: Get-Module can omit a broken
        # manifest, which would silently promote a lower-priority installation.
        Assert-PurviewDependencyTree -Root $candidateRoot
        $manifestPath = Join-Path $candidateRoot 'ExchangeOnlineManagement.psd1'
        if (-not [IO.File]::Exists($manifestPath)) {
            throw 'The first ExchangeOnlineManagement installation is missing its pinned manifest. Repair that installation before packaging.'
        }
        $moduleSignature = Get-AuthenticodeSignature -LiteralPath $manifestPath
        if ($moduleSignature.Status -ne 'Valid' -or
            $moduleSignature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Microsoft Corporation(,|$)') {
            throw 'The pinned ExchangeOnlineManagement module must have a valid Microsoft signature. Repair the first installation in PSModulePath; no fallback is permitted.'
        }
        # Get-Module reads metadata without importing EOM, and supports its signed
        # edition-conditional RootModule (unlike Import-PowerShellDataFile).
        # Never re-resolve by bare name: only this verified manifest can qualify.
        try {
            $modules = @(Get-Module -ListAvailable -FullyQualifiedName @{
                ModuleName = $manifestPath; RequiredVersion = '3.10.1'
            } -ErrorAction Stop)
        } catch {
            throw 'The pinned ExchangeOnlineManagement manifest must be valid and declare version 3.10.1 exactly.'
        }
        if ($modules.Count -ne 1 -or $modules[0].Version -ne [version]'3.10.1' -or
            [IO.Path]::GetFullPath($modules[0].ModuleBase) -ine [IO.Path]::GetFullPath($candidateRoot)) {
            throw 'The pinned ExchangeOnlineManagement manifest must be valid and declare version 3.10.1 exactly.'
        }
        return [IO.Path]::GetFullPath($candidateRoot)
    }
    throw 'Installed ExchangeOnlineManagement 3.10.1 is required in PSModulePath. Install the exact Microsoft-signed version before packaging.'
}

if (-not $IsWindows -or -not [Environment]::Is64BitProcess) {
    throw 'Purview executor packaging requires Windows x64.'
}
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Common.psm1') -Force -DisableNameChecking
$outputRoot = ''
if (-not $ValidateOnly) {
    $outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
    $allowedRoots = @('.bootstrap', '.agent-runtime') | ForEach-Object {
        [IO.Path]::GetFullPath((Join-Path $repositoryRoot $_)).TrimEnd('\') + '\'
    }
    if (-not @($allowedRoots | Where-Object { $outputRoot.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -or
        (Test-Path -LiteralPath $outputRoot)) {
        throw 'Executor package output must be a new directory under this repository .bootstrap or .agent-runtime.'
    }
}
$powerShellRoot = [IO.Path]::GetFullPath($PowerShellDirectory)
Assert-PurviewDependencyTree -Root $powerShellRoot
$powerShellPath = Join-Path $powerShellRoot 'pwsh.exe'
$signature = Get-AuthenticodeSignature -LiteralPath $powerShellPath
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Microsoft Corporation(,|$)') {
    throw 'Packaged PowerShell must have a valid Microsoft Authenticode signature.'
}
$runtimeVersion = & $powerShellPath -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
if ($LASTEXITCODE -ne 0 -or [string]$runtimeVersion -cne '7.6.5') {
    throw 'This executor package requires PowerShell 7.6.5 exactly.'
}
$moduleRoot = Resolve-PurviewExecutorModuleRoot
if ($ValidateOnly) { return }
$sourceFingerprint = Get-BootstrapSourceFingerprint -Root $repositoryRoot
if (-not [string]::IsNullOrEmpty($ExpectedSourceFingerprint) -and $sourceFingerprint -cne $ExpectedSourceFingerprint) {
    throw 'Executor package source differs from the accepted bootstrap generation.'
}
$publishDirectory = Join-Path $outputRoot 'publish'
[IO.Directory]::CreateDirectory($publishDirectory) | Out-Null
& dotnet publish (Join-Path $repositoryRoot 'src/Gateway.Purview.Executor/Gateway.Purview.Executor.csproj') `
    -c Release -r win-x64 --self-contained true -o $publishDirectory /p:UseAppHost=true
if ($LASTEXITCODE -ne 0) { throw 'Windows executor publish failed.' }
Copy-Item -LiteralPath $powerShellRoot -Destination (Join-Path $publishDirectory 'PowerShell') -Recurse
$moduleDestination = Join-Path $publishDirectory 'PowerShellModules/ExchangeOnlineManagement/3.10.1'
[IO.Directory]::CreateDirectory((Split-Path -Parent $moduleDestination)) | Out-Null
Copy-Item -LiteralPath $moduleRoot -Destination $moduleDestination -Recurse
if ((Get-BootstrapSourceFingerprint -Root $repositoryRoot) -cne $sourceFingerprint) {
    throw 'Executor source changed while publishing; no package receipt will be issued.'
}
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
