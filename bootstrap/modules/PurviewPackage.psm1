Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Azure.psm1') -DisableNameChecking

function Assert-PurviewPackageRegularPath {
    param([Parameter(Mandatory)][string]$Path)
    $item = [IO.Path]::GetFullPath($Path)
    while ($item) {
        if ((Test-Path -LiteralPath $item) -and
            ([IO.File]::GetAttributes($item) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Package paths cannot contain reparse points.'
        }
        $item = [IO.Path]::GetDirectoryName($item)
    }
}

function Assert-PurviewPackageFileName {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name.Contains('\') -or $Name.Length -gt 512 -or
        @($Name.Split('/') | Where-Object { $_ -in @('', '.', '..') -or
            $_ -match '[\x00-\x1f\x7f<>:"|?*]' -or $_.EndsWith('.') -or $_.EndsWith(' ') -or
            $_ -match '\A(CON|PRN|AUX|NUL|COM[0-9\u00b9\u00b2\u00b3]+|LPT[0-9\u00b9\u00b2\u00b3]+)(\.|\z)' }).Count -ne 0) {
        throw 'The executor package contains an invalid relative path.'
    }
}

function Read-PurviewPackageEntry {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][long]$MaximumBytes, [switch]$IncludeBytes)
    if ($Entry.Length -lt 0 -or $Entry.Length -gt $MaximumBytes) { throw 'Executor ZIP entry size is invalid.' }
    $stream = $Entry.Open()
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $memory = if ($IncludeBytes) { [IO.MemoryStream]::new() } else { $null }
    try {
        $buffer = [byte[]]::new(65536)
        [long]$actual = 0
        while ($true) {
            $count = $stream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $MaximumBytes - $actual + 1))
            if ($count -eq 0) { break }
            $actual += $count
            if ($actual -gt $MaximumBytes -or $actual -gt $Entry.Length) { throw 'Executor ZIP actual size exceeds its bound or declared size.' }
            $hash.AppendData($buffer, 0, $count)
            if ($memory) { $memory.Write($buffer, 0, $count) }
        }
        if ($actual -ne $Entry.Length) { throw 'Executor ZIP actual size differs from its declared size.' }
        return @{ length = $actual; sha256 = [Convert]::ToHexStringLower($hash.GetHashAndReset());
            bytes = if ($memory) { $memory.ToArray() } else { $null } }
    }
    finally { $stream.Dispose(); $hash.Dispose(); if ($memory) { $memory.Dispose() } }
}

function Read-PurviewExecutorPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageDirectory,
        [Parameter(Mandatory)][string]$ExpectedSourceFingerprint
    )
    Assert-BootstrapFingerprintValue -Value $ExpectedSourceFingerprint -Label 'Executor package source'
    $receiptPath = Join-Path $PackageDirectory 'package-receipt.json'
    Assert-PurviewPackageRegularPath -Path $receiptPath
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf) -or
        (Get-Item -LiteralPath $receiptPath).Length -gt 4096) { throw 'A bounded executor package receipt is required.' }
    $receipt = [IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json -AsHashtable
    $expectedKeys = @('schemaVersion', 'sourceFingerprint', 'packageDigest', 'runtimeManifestDigest',
        'packageFileName', 'packageBytes', 'powerShellVersion', 'exchangeOnlineManagementVersion', 'fileCount')
    if ($receipt -isnot [Collections.IDictionary] -or $receipt.Count -ne $expectedKeys.Count -or
        @($expectedKeys | Where-Object { -not $receipt.ContainsKey($_) }).Count -ne 0 -or
        $receipt.schemaVersion -cne 1 -or $receipt.sourceFingerprint -cne $ExpectedSourceFingerprint -or
        $receipt.powerShellVersion -cne '7.6.5' -or $receipt.exchangeOnlineManagementVersion -cne '3.10.1' -or
        $receipt.packageBytes -isnot [long] -and $receipt.packageBytes -isnot [int] -or
        $receipt.packageBytes -le 0 -or $receipt.packageBytes -gt 1GB -or
        $receipt.fileCount -isnot [long] -and $receipt.fileCount -isnot [int] -or
        $receipt.fileCount -le 0 -or $receipt.fileCount -gt 20000) { throw 'The executor package receipt is invalid.' }
    foreach ($field in @('packageDigest', 'runtimeManifestDigest')) {
        if ([string]$receipt[$field] -cnotmatch '\Asha256:[0-9a-f]{64}\z') { throw 'The package digest is invalid.' }
    }
    if ([string]$receipt.packageFileName -cne ($receipt.packageDigest.Substring(7) + '.zip')) {
        throw 'The package filename must be its content digest.'
    }
    $packagePath = [IO.Path]::GetFullPath((Join-Path $PackageDirectory $receipt.packageFileName))
    Assert-PurviewPackageRegularPath -Path $packagePath
    $stream = [IO.File]::Open($packagePath, 'Open', 'Read', 'Read')
    try {
        if ($stream.Length -ne $receipt.packageBytes -or
            ('sha256:' + [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($stream))) -cne $receipt.packageDigest) {
            throw 'Executor ZIP bytes do not match the reviewed receipt.'
        }
        $stream.Position = 0
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            if ($zip.Entries.Count -ne $receipt.fileCount + 1) { throw 'Executor ZIP inventory differs from its receipt.' }
            $entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
            [long]$expandedBytes = 0
            foreach ($entry in $zip.Entries) {
                Assert-PurviewPackageFileName -Name $entry.FullName
                $expandedBytes += $entry.Length
                if (-not $entries.TryAdd($entry.FullName, $entry) -or $entry.Length -gt 256MB -or $expandedBytes -gt 2GB) {
                    throw 'Executor ZIP names or expanded sizes are invalid.'
                }
            }
            foreach ($name in $entries.Keys) {
                $segments = $name.Split('/')
                for ($index = 1; $index -lt $segments.Count; $index++) {
                    if ($entries.ContainsKey(($segments[0..($index - 1)] -join '/'))) {
                        throw 'Executor ZIP file and directory paths collide.'
                    }
                }
            }
            $manifestEntry = $null
            if (-not $entries.TryGetValue('executor-runtime.json', [ref]$manifestEntry) -or
                $manifestEntry.FullName -cne 'executor-runtime.json' -or $manifestEntry.Length -gt 4MB) {
                throw 'A bounded runtime manifest is required.'
            }
            $manifestRead = Read-PurviewPackageEntry -Entry $manifestEntry -MaximumBytes 4MB -IncludeBytes
            $manifestBytes = $manifestRead.bytes
            [long]$actualExpandedBytes = $manifestRead.length
            if ('sha256:' + $manifestRead.sha256 -cne $receipt.runtimeManifestDigest) {
                throw 'Executor runtime manifest digest differs from its receipt.'
            }
            $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json -AsHashtable
            if ($manifest.schemaVersion -cne 1 -or $manifest.sourceFingerprint -cne $ExpectedSourceFingerprint -or
                $manifest.powerShellVersion -cne '7.6.5' -or $manifest.exchangeOnlineManagementVersion -cne '3.10.1' -or
                @($manifest.files).Count -ne $receipt.fileCount) { throw 'Executor runtime manifest binding is invalid.' }
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($file in $manifest.files) {
                Assert-PurviewPackageFileName -Name ([string]$file.path)
                $entry = $null
                if (-not $names.Add([string]$file.path) -or [string]$file.path -ieq 'executor-runtime.json' -or
                    [string]$file.sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
                    -not $entries.TryGetValue([string]$file.path, [ref]$entry) -or $entry.FullName -cne [string]$file.path) {
                    throw 'Executor file inventory is not exact.'
                }
                $fileRead = Read-PurviewPackageEntry -Entry $entry -MaximumBytes ([Math]::Min(256MB, 2GB - $actualExpandedBytes))
                $actualExpandedBytes += $fileRead.length
                if ($fileRead.sha256 -cne [string]$file.sha256) { throw 'Executor runtime file hash differs from its manifest.' }
            }
            foreach ($required in @('Gateway.Purview.Executor.dll', 'Gateway.Purview.dll', 'Gateway.Provisioning.Worker.dll',
                'PowerShell/pwsh.exe', 'Automation/Verify-PurviewTenantConnection.ps1', 'Automation/Invoke-PurviewSettingsOperation.ps1',
                'PowerShellModules/ExchangeOnlineManagement/3.10.1/ExchangeOnlineManagement.psd1')) {
                if (-not $names.Contains($required)) { throw 'Executor package is missing a required runtime file.' }
            }
        }
        finally { $zip.Dispose() }
    }
    finally { $stream.Dispose() }
    return [ordered]@{ receipt = $receipt; receiptFingerprint = Get-BootstrapObjectFingerprint -InputObject $receipt; packagePath = $packagePath }
}

function New-PurviewPublisherBuildContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$PackageDirectory,
        [Parameter(Mandatory)][string]$ExpectedReceiptFingerprint,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    $allowed = [IO.Path]::GetFullPath((Join-Path $root '.bootstrap')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $output.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $output)) {
        throw 'Publisher context must be a new directory under the repository .bootstrap path.'
    }
    Assert-PurviewPackageRegularPath -Path $output
    $manifest = @(Get-BootstrapSourceManifest -Root $root)
    if ((Get-BootstrapObjectFingerprint -InputObject $manifest) -cne $SourceFingerprint) { throw 'Publisher source changed after review.' }
    $package = Read-PurviewExecutorPackage -PackageDirectory $PackageDirectory -ExpectedSourceFingerprint $SourceFingerprint
    if ($package.receiptFingerprint -cne $ExpectedReceiptFingerprint) { throw 'Publisher package receipt changed after review.' }
    $inputs = @($manifest | Where-Object { [string]$_.path -cmatch '\Asrc/Gateway\.Purview\.PackagePublisher/[^/]+\.(cs|csproj)\z' -or
        [string]$_.path -ceq 'src/Gateway.Purview.PackagePublisher/Dockerfile' -or
        [string]$_.path -in @('global.json', 'nuget.config', 'Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props') })
    foreach ($required in @('global.json', 'nuget.config', 'src/Gateway.Purview.PackagePublisher/Dockerfile',
        'src/Gateway.Purview.PackagePublisher/Gateway.Purview.PackagePublisher.csproj')) {
        if ($required -cnotin @($inputs.path)) { throw 'Publisher build context is missing a required source file.' }
    }
    Assert-GatewayCredentialFreeNuGetConfig -Path (Join-Path $root 'nuget.config') | Out-Null
    [IO.Directory]::CreateDirectory($output) | Out-Null
    foreach ($input in $inputs) {
        Assert-BootstrapSourcePathIsRegular -Root $root -RelativePath $input.path | Out-Null
        $destination = Join-Path $output $input.path
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $input.path) -Destination $destination
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $input.sha256) {
            throw 'Publisher build input changed while copying.'
        }
    }
    $payload = Join-Path $output 'payload/executor.zip'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $payload)) | Out-Null
    Copy-Item -LiteralPath $package.packagePath -Destination $payload
    if ('sha256:' + (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant() -cne $package.receipt.packageDigest) {
        throw 'Publisher payload changed while copying.'
    }
    return $output
}

Export-ModuleMember -Function Read-PurviewExecutorPackage, New-PurviewPublisherBuildContext
