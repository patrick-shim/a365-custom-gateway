#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1')

$script:RetainedBuildFiles = @('Directory.Build.props', 'global.json', 'nuget.config', 'VERSION')
$script:AllowedRootFiles = $script:RetainedBuildFiles
$script:AllowedDirectories = @('src', 'tools\Gateway.DatabaseMigrator', 'tools\Gateway.LiveVerification',
    'bootstrap\modules', 'bootstrap\infra', 'infrastructure\bicep', 'infrastructure\sql', 'operations')
$script:Extensions = @('.cs', '.csproj', '.slnx', '.props', '.targets', '.razor', '.cshtml', '.css', '.js', '.mjs',
    '.ts', '.tsx', '.html', '.svg', '.sql', '.bicep', '.bicepparam', '.ps1', '.psm1', '.psd1')

function Get-GatewayUpgradePackagingInventory {
    param([Parameter(Mandatory)][string]$Root)
    $rootPath = [IO.Path]::GetFullPath($Root)
    if ((Get-Item -LiteralPath $rootPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'UpgradePackaging: source roots cannot be links.'
    }
    $result = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($relative in $script:AllowedRootFiles) {
        $path = Join-Path $rootPath $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Add-GatewayUpgradePackagingFile $result $rootPath (Get-Item -LiteralPath $path -Force)
        }
    }
    foreach ($directory in $script:AllowedDirectories) {
        $path = Join-Path $rootPath $directory
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($path)
        while ($pending.Count) {
            $current = $pending.Pop()
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'UpgradePackaging: source directory links are forbidden.'
            }
            foreach ($item in Get-ChildItem -LiteralPath $current -Force) {
                if ($item.Name -match '^(?:bin|obj|Python|__pycache__|venv|\.venv|node_modules|\.git|\.bootstrap|\.maintenance|\.test-work|\.vs|\.secrets?|config|state)$' -or
                    $item.Name -match '^(?:\.env|appsettings|config\.|secrets?\.|credentials?\.|local\.settings)') { continue }
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'UpgradePackaging: source links are forbidden.' }
                if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
                $relative = [IO.Path]::GetRelativePath($rootPath, $item.FullName).Replace('/', '\')
                if ($item.Extension -cin $script:Extensions -or $item.Name -ceq 'Dockerfile' -or
                    $relative -ceq 'src\Gateway.Purview.Executor\web.config') {
                    Add-GatewayUpgradePackagingFile $result $rootPath $item
                }
            }
        }
    }
    return $result
}

function Add-GatewayUpgradePackagingFile {
    param($Inventory, [string]$Root, $Item)
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'UpgradePackaging: source file links are forbidden.' }
    if ($Item.Length -gt 4194304) { throw 'UpgradePackaging: oversized source asset requires separate review.' }
    $relative = [IO.Path]::GetRelativePath($Root, $Item.FullName).Replace('/', '\')
    if ($relative -cnotmatch '^[A-Za-z0-9_.-]+(?:\\[A-Za-z0-9_.-]+)*$') {
        throw 'UpgradePackaging: unsupported source path.'
    }
    $bytes = [IO.File]::ReadAllBytes($Item.FullName)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text -match '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|(?i:AccountKey\s*=\s*[A-Za-z0-9+/]{20,}|SharedAccessSignature\s*=\s*[^;]+|<packageSourceCredentials[ >])') {
        throw 'UpgradePackaging: credential material was detected; source was not packaged.'
    }
    if ($Inventory.ContainsKey($relative)) { return }
    $Inventory.Add($relative, @{ path = $relative; fullPath = $Item.FullName; sha256 = Get-GatewayUpgradeFileHash $Item.FullName })
}

function New-GatewayUpgradeCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkingRoot, [Parameter(Mandatory)][string]$PackagingBaselineRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot)
    $workingRootPath = [IO.Path]::GetFullPath($WorkingRoot)
    $baselineRootPath = [IO.Path]::GetFullPath($PackagingBaselineRoot)
    $workspaceRootPath = [IO.Path]::GetFullPath($WorkspaceRoot)
    if ($workspaceRootPath -match '(?:^|[\\/])\.bootstrap(?:[\\/]|$)' -or
        $workspaceRootPath.Equals($baselineRootPath, [StringComparison]::OrdinalIgnoreCase) -or
        $workspaceRootPath.StartsWith($baselineRootPath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'UpgradePackaging: output cannot be written into retained baseline or bootstrap evidence.'
    }
    $working = Get-GatewayUpgradePackagingInventory $workingRootPath
    $baseline = Get-GatewayUpgradePackagingInventory $baselineRootPath
    $entries = [Collections.Generic.List[object]]::new()
    $deleted = [Collections.Generic.List[object]]::new()
    $names = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @($working.Keys) + @($baseline.Keys)) { $null = $names.Add($name) }
    foreach ($name in $names) {
        $current = if ($working.ContainsKey($name)) { $working[$name] } else { $null }
        $old = if ($baseline.ContainsKey($name)) { $baseline[$name] } else { $null }
        if ($null -eq $current -and $name -cnotin $script:RetainedBuildFiles) {
            $deleted.Add(@{ path = $name; baselineSha256 = $old.sha256; disposition = 'ExcludedWorkingTreeDeletion' })
            continue
        }
        $selected = if ($null -ne $current) { $current } else { $old }
        $origin = if ($null -eq $current) { 'RetainedCleanBuildPrerequisite' } else { 'WorkingTree' }
        $change = if ($null -eq $current) { 'RetainedBaselineOnlyInPackage' }
            elseif ($null -eq $old) { 'Added' }
            elseif ($current.sha256 -cne $old.sha256) { 'Modified' } else { 'Unchanged' }
        $entries.Add(@{
            path = $name; sha256 = $selected.sha256; origin = $origin; change = $change
            baselineSha256 = if ($null -ne $old) { $old.sha256 } else { $null }
        })
    }
    foreach ($name in $script:RetainedBuildFiles) {
        if ($name -cnotin @($entries.path)) { throw 'UpgradePackaging: a required build prerequisite is absent from both reviewed sources.' }
    }
    $allowedPaths = @($entries.path) + @('.dockerignore')
    $ignoreLines = [Collections.Generic.List[string]]::new()
    $ignoreLines.Add('**')
    $parents = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relative in $allowedPaths) {
        $parts = $relative.Split('\')
        for ($index = 1; $index -lt $parts.Count; $index++) {
            $null = $parents.Add(($parts[0..($index - 1)] -join '/') + '/')
        }
    }
    foreach ($parent in $parents) { $ignoreLines.Add('!' + $parent) }
    foreach ($relative in $allowedPaths) { $ignoreLines.Add('!' + $relative.Replace('\', '/')) }
    $ignoreText = ($ignoreLines -join "`n") + "`n"
    $ignoreHash = Get-GatewayUpgradeFingerprint @{ encoding = 'UTF8NoBOM'; content = $ignoreText }
    $provenance = @{
        schemaVersion = 1; operation = 'GatewayUpgradeCandidatePackaging'
        entries = @($entries); excludedDeletions = @($deleted)
        uploadAllowlistContentFingerprint = $ignoreHash
        exclusions = @('secrets', 'application/local/bootstrap configuration', 'state', 'bin', 'obj', 'Python', 'arbitrary assets')
        workingTreeRestored = $false; retainedBaselineModified = $false
    }
    $fingerprint = Get-GatewayUpgradeFingerprint $provenance
    $directory = Join-Path $workspaceRootPath ".maintenance\candidates\$($fingerprint.Substring(7))"
    if (Test-Path -LiteralPath $directory) { throw 'UpgradePackaging: this candidate directory already exists; verify it rather than overwrite it.' }
    $parentDirectory = Split-Path -Parent $directory
    for ($ancestor = [IO.DirectoryInfo]::new($parentDirectory); $null -ne $ancestor; $ancestor = $ancestor.Parent) {
        if ($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'UpgradePackaging: output ancestors cannot be links.'
        }
    }
    $sourceDirectory = Join-Path $directory 'source'
    [IO.Directory]::CreateDirectory($sourceDirectory) | Out-Null
    foreach ($entry in $entries) {
        $source = if ($entry.origin -ceq 'WorkingTree') { $working[$entry.path].fullPath } else { $baseline[$entry.path].fullPath }
        if ((Get-GatewayUpgradeFileHash $source) -cne $entry.sha256) { throw 'UpgradePackaging: source changed before snapshot copy.' }
        $destination = Join-Path $sourceDirectory $entry.path
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [IO.File]::Copy($source, $destination, $false)
        if ((Get-GatewayUpgradeFileHash $destination) -cne $entry.sha256) { throw 'UpgradePackaging: snapshot bytes did not match their provenance.' }
    }
    [IO.File]::WriteAllText((Join-Path $sourceDirectory '.dockerignore'), $ignoreText, [Text.UTF8Encoding]::new($false))
    $provenance['uploadAllowlistSha256'] = Get-GatewayUpgradeFileHash (Join-Path $sourceDirectory '.dockerignore')
    $receipt = @{ candidateFingerprint = $fingerprint; provenance = $provenance }
    [IO.File]::WriteAllText((Join-Path $directory 'provenance.json'), (ConvertTo-Json -InputObject $receipt -Depth 100), [Text.UTF8Encoding]::new($false))
    return @{ sourceRoot = $sourceDirectory; receiptPath = (Join-Path $directory 'provenance.json'); candidateFingerprint = $fingerprint }
}

function Test-GatewayUpgradeCandidate {
    param([Parameter(Mandatory)][string]$ReceiptPath, [Parameter(Mandatory)][string]$ExpectedCandidateFingerprint)
    $receipt = Read-GatewayUpgradeJson $ReceiptPath
    $sourceRoot = Join-Path (Split-Path -Parent $ReceiptPath) 'source'
    $provenance = $receipt.provenance
    $ignoreHash = $provenance.uploadAllowlistSha256
    $canonical = [ordered]@{}
    foreach ($key in $provenance.Keys) { if ($key -cne 'uploadAllowlistSha256') { $canonical[$key] = $provenance[$key] } }
    if ($receipt.candidateFingerprint -cne $ExpectedCandidateFingerprint -or
        (Get-GatewayUpgradeFingerprint $canonical) -cne $ExpectedCandidateFingerprint -or
        $provenance.workingTreeRestored -ne $false -or $provenance.retainedBaselineModified -ne $false) {
        throw 'UpgradePackaging: candidate provenance integrity failed.'
    }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $provenance.entries) {
        if (-not $expected.Add($entry.path)) { throw 'UpgradePackaging: duplicate source entry.' }
        if ((Get-GatewayUpgradeFileHash (Join-Path $sourceRoot $entry.path)) -cne $entry.sha256) {
            throw 'UpgradePackaging: candidate bytes changed.'
        }
    }
    $null = $expected.Add('.dockerignore')
    if ((Get-GatewayUpgradeFileHash (Join-Path $sourceRoot '.dockerignore')) -cne $ignoreHash) {
        throw 'UpgradePackaging: exact upload allowlist changed.'
    }
    $ignoreText = [Text.UTF8Encoding]::new($false, $true).GetString(
        [IO.File]::ReadAllBytes((Join-Path $sourceRoot '.dockerignore')))
    if ((Get-GatewayUpgradeFingerprint @{ encoding = 'UTF8NoBOM'; content = $ignoreText }) -cne
        $provenance.uploadAllowlistContentFingerprint) {
        throw 'UpgradePackaging: upload allowlist content is not bound to the approved candidate.'
    }
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName).Replace('/', '\')
        if (-not $expected.Contains($relative)) { throw 'UpgradePackaging: unmanifested file exists in the upload source.' }
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'UpgradePackaging: candidate links are forbidden.' }
    }
    return $sourceRoot
}

function New-GatewayUpgradePublisherContext {
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$PackageDirectory,
        [Parameter(Mandatory)][string]$ExpectedSourceFingerprint,
        [Parameter(Mandatory)][string]$ExpectedPackageReceiptFingerprint,
        [Parameter(Mandatory)][string]$WorkspaceRoot)
    $toolingRoot = Split-Path -Parent $PSScriptRoot
    foreach ($module in @('Common', 'Azure', 'PurviewPackage')) {
        Import-Module (Join-Path $toolingRoot "bootstrap\modules\$module.psm1") -Global -DisableNameChecking
    }
    if ((Get-BootstrapSourceFingerprint -Root $SourceRoot) -cne $ExpectedSourceFingerprint) {
        throw 'UpgradePackaging: publisher source does not match its exact package implementation.'
    }
    $package = Read-PurviewExecutorPackage -PackageDirectory $PackageDirectory -ExpectedSourceFingerprint $ExpectedSourceFingerprint
    if ($package.receiptFingerprint -cne $ExpectedPackageReceiptFingerprint) {
        throw 'UpgradePackaging: executor package receipt differs from the approved asset.'
    }
    $expectedProvenance = Get-GatewayUpgradePublisherExpectedProvenance $SourceRoot $ExpectedSourceFingerprint `
        $ExpectedPackageReceiptFingerprint $package.receipt.packageDigest
    $expectedFingerprint = Get-GatewayUpgradeFingerprint $expectedProvenance
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
    if ($workspace -match '(?:^|[\\/])\.bootstrap(?:[\\/]|$)' -or
        $workspace.StartsWith([IO.Path]::GetFullPath($SourceRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'UpgradePackaging: publisher output must remain outside immutable source snapshots.'
    }
    $directory = Join-Path $workspace ".maintenance\publisher-contexts\$($ExpectedPackageReceiptFingerprint.Substring(7))"
    if (Test-Path -LiteralPath (Join-Path $directory 'provenance.json')) {
        $receiptPath = Join-Path $directory 'provenance.json'
        $verifiedRoot = Test-GatewayUpgradePublisherContext $receiptPath $expectedFingerprint
        return @{ sourceRoot = $verifiedRoot; receiptPath = $receiptPath; fingerprint = $expectedFingerprint }
    }
    if (Test-Path -LiteralPath $directory) {
        $directory += '-' + [guid]::NewGuid().ToString('N')
    }
    $source = Join-Path $directory 'source'
    [IO.Directory]::CreateDirectory($source) | Out-Null
    $inputs = @(Get-GatewayUpgradePackagingInventory $SourceRoot).Values | Where-Object {
        $_.path -cmatch '^src\\Gateway\.Purview\.PackagePublisher\\[^\\]+\.(cs|csproj)$' -or
        $_.path -ceq 'src\Gateway.Purview.PackagePublisher\Dockerfile' -or $_.path -cin $script:AllowedRootFiles
    }
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($entry in $inputs) {
        $destination = Join-Path $source $entry.path
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [IO.File]::Copy($entry.fullPath, $destination, $false)
        if ((Get-GatewayUpgradeFileHash $destination) -cne $entry.sha256) { throw 'UpgradePackaging: publisher source bytes changed while copying.' }
        $entries.Add(@{ path = $entry.path; sha256 = $entry.sha256; origin = 'ApprovedSource' })
    }
    foreach ($required in @('global.json', 'nuget.config', 'src\Gateway.Purview.PackagePublisher\Dockerfile',
            'src\Gateway.Purview.PackagePublisher\Gateway.Purview.PackagePublisher.csproj')) {
        if ($required -cnotin @($entries.path)) { throw 'UpgradePackaging: publisher source closure is incomplete.' }
    }
    $payload = Join-Path $source 'payload\executor.zip'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $payload)) | Out-Null
    [IO.File]::Copy($package.packagePath, $payload, $false)
    if ((Get-GatewayUpgradeFileHash $payload) -cne $package.receipt.packageDigest) { throw 'UpgradePackaging: publisher payload digest changed.' }
    $entries.Add(@{ path = 'payload\executor.zip'; sha256 = $package.receipt.packageDigest; origin = 'VerifiedExecutorPackage' })
    $ignore = "**`n!payload/`n!src/`n!src/Gateway.Purview.PackagePublisher/`n!.dockerignore`n" +
        ((@($entries | ForEach-Object { '!' + $_.path.Replace('\', '/') })) -join "`n") + "`n"
    [IO.File]::WriteAllText((Join-Path $source '.dockerignore'), $ignore, [Text.UTF8Encoding]::new($false))
    $entries.Add(@{ path = '.dockerignore'; sha256 = Get-GatewayUpgradeFileHash (Join-Path $source '.dockerignore'); origin = 'ExactUploadAllowlist' })
    $body = @{
        schemaVersion = 1; sourceFingerprint = $ExpectedSourceFingerprint; packageReceiptFingerprint = $ExpectedPackageReceiptFingerprint
        packageDigest = $package.receipt.packageDigest; entries = @($entries)
    }
    if ((Get-GatewayUpgradeFingerprint $body) -cne $expectedFingerprint) {
        throw 'UpgradePackaging: copied publisher context differs from its independently derived byte manifest.'
    }
    $receipt = @{ fingerprint = Get-GatewayUpgradeFingerprint $body; provenance = $body }
    $receiptPath = Join-Path $directory 'provenance.json'
    [IO.File]::WriteAllText($receiptPath, (ConvertTo-Json -InputObject $receipt -Depth 100), [Text.UTF8Encoding]::new($false))
    return @{ sourceRoot = $source; receiptPath = $receiptPath; fingerprint = $receipt.fingerprint }
}

function Get-GatewayUpgradePublisherExpectedProvenance {
    param([string]$SourceRoot, [string]$SourceFingerprint, [string]$PackageReceiptFingerprint, [string]$PackageDigest)
    $inputs = @(Get-GatewayUpgradePackagingInventory $SourceRoot).Values | Where-Object {
        $_.path -cmatch '^src\\Gateway\.Purview\.PackagePublisher\\[^\\]+\.(cs|csproj)$' -or
        $_.path -ceq 'src\Gateway.Purview.PackagePublisher\Dockerfile' -or $_.path -cin $script:AllowedRootFiles
    }
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($entry in $inputs) { $entries.Add(@{ path = $entry.path; sha256 = $entry.sha256; origin = 'ApprovedSource' }) }
    $entries.Add(@{ path = 'payload\executor.zip'; sha256 = $PackageDigest; origin = 'VerifiedExecutorPackage' })
    $ignore = "**`n!payload/`n!src/`n!src/Gateway.Purview.PackagePublisher/`n!.dockerignore`n" +
        ((@($entries | ForEach-Object { '!' + $_.path.Replace('\', '/') })) -join "`n") + "`n"
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $hash = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($ignore)) } finally { $algorithm.Dispose() }
    $entries.Add(@{ path = '.dockerignore'; sha256 = 'sha256:' + [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant(); origin = 'ExactUploadAllowlist' })
    return @{
        schemaVersion = 1; sourceFingerprint = $SourceFingerprint; packageReceiptFingerprint = $PackageReceiptFingerprint
        packageDigest = $PackageDigest; entries = @($entries)
    }
}

function Test-GatewayUpgradePublisherContext {
    param([Parameter(Mandatory)][string]$ReceiptPath, [Parameter(Mandatory)][string]$ExpectedFingerprint)
    $receipt = Read-GatewayUpgradeJson $ReceiptPath
    if ($receipt.fingerprint -cne $ExpectedFingerprint -or
        (Get-GatewayUpgradeFingerprint $receipt.provenance) -cne $ExpectedFingerprint) {
        throw 'UpgradePackaging: publisher provenance is not exact.'
    }
    $root = Join-Path (Split-Path -Parent $ReceiptPath) 'source'
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $receipt.provenance.entries) {
        if ($entry.path -cnotmatch '^[A-Za-z0-9_.-]+(?:\\[A-Za-z0-9_.-]+)*$' -or
            $entry.path.Split('\') -contains '..' -or -not $paths.Add($entry.path)) {
            throw 'UpgradePackaging: publisher entry path is malformed.'
        }
        $path = Join-Path $root $entry.path
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
            (Get-GatewayUpgradeFileHash $path) -cne $entry.sha256) {
            throw 'UpgradePackaging: publisher input bytes or regular-file boundary changed.'
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        if (-not $paths.Contains([IO.Path]::GetRelativePath($root, $file.FullName).Replace('/', '\'))) {
            throw 'UpgradePackaging: an unapproved file entered the publisher context.'
        }
    }
    return $root
}

function Prepare-GatewayUpgradeCandidate {
    param([Parameter(Mandatory)][string]$ReceiptPath, [Parameter(Mandatory)][string]$ExpectedCandidateFingerprint,
        [Parameter(Mandatory)][string]$WorkspaceRoot)
    $source = Test-GatewayUpgradeCandidate $ReceiptPath $ExpectedCandidateFingerprint
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
    if ($workspace -match '(?:^|[\\/])\.bootstrap(?:[\\/]|$)' -or
        $workspace.StartsWith($source.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'UpgradePackaging: local validation output cannot modify immutable source.'
    }
    $buildRoot = Join-Path $workspace ".maintenance\local-validation\$($ExpectedCandidateFingerprint.Substring(7))\$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($buildRoot) | Out-Null
    $receipt = Read-GatewayUpgradeJson $ReceiptPath
    foreach ($relative in @($receipt.provenance.entries.path) + @('.dockerignore')) {
        $destination = Join-Path $buildRoot $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [IO.File]::Copy((Join-Path $source $relative), $destination, $false)
    }
    $toolingRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $toolingRoot 'bootstrap\modules\Common.psm1') -Global -DisableNameChecking
    $artifactSourceFingerprint = Get-BootstrapSourceFingerprint -Root $source
    if ((Get-BootstrapSourceFingerprint -Root $buildRoot) -cne $artifactSourceFingerprint) {
        throw 'UpgradePackaging: local validation source differs from its immutable candidate.'
    }
    $project = Join-Path $buildRoot 'tools\Gateway.DatabaseMigrator\Gateway.DatabaseMigrator.csproj'
    Invoke-BootstrapCommand -FilePath 'dotnet' -ArgumentList @('build', $project, '--configuration', 'Release', '--verbosity', 'quiet', '--nologo') | Out-Null
    $tool = Join-Path $buildRoot 'tools\Gateway.DatabaseMigrator\bin\Release\net10.0\Gateway.DatabaseMigrator.dll'
    $output = Invoke-BootstrapCommand -FilePath 'dotnet' -ArgumentList @(
        $tool, '--server', 'sql-schema-plan.database.windows.net', '--database', 'GatewayDb',
        '--phase', 'upgrade-schema-plan', '--repository-root', $buildRoot)
    $lines = @($output.Split("`n") | Where-Object { $_.StartsWith('A365GW_UPGRADE_SCHEMA:') })
    if ($lines.Count -ne 1 -or $lines[0].Trim() -cnotmatch '^A365GW_UPGRADE_SCHEMA:(sha256:[0-9a-f]{64})$') {
        throw 'UpgradePackaging: local schema planner did not emit one exact model fingerprint.'
    }
    $model = $Matches[1]
    if ((Get-BootstrapSourceFingerprint -Root $buildRoot) -cne $artifactSourceFingerprint) {
        throw 'UpgradePackaging: local build changed source bytes.'
    }
    $bundleRoot = Split-Path -Parent $tool
    $bundleManifest = @(Get-GatewayUpgradeToolBundleManifest $bundleRoot)
    return @{
        sourceRoot = $source; candidateReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
        candidateFingerprint = $ExpectedCandidateFingerprint; toolPath = $tool; toolSha256 = Get-GatewayUpgradeFileHash $tool
        buildRoot = $buildRoot; modelFingerprint = $model; artifactSourceFingerprint = $artifactSourceFingerprint
        toolBundleRoot = $bundleRoot; toolBundleManifest = $bundleManifest
        toolBundleFingerprint = Get-GatewayUpgradeFingerprint $bundleManifest
    }
}

function Get-GatewayUpgradeToolBundleManifest {
    param([string]$Root)
    $rootPath = [IO.Path]::GetFullPath($Root)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($rootPath)
    $files = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    while ($pending.Count) {
        $directory = $pending.Pop()
        if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'UpgradePackaging: executable bundle directories cannot be links.'
        }
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'UpgradePackaging: executable bundle links are forbidden.' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            if ($files.Count -ge 2000) { throw 'UpgradePackaging: executable bundle exceeds its file bound.' }
            $relative = [IO.Path]::GetRelativePath($rootPath, $item.FullName).Replace('/', '\')
            $files.Add($relative, @{ path = $relative; sha256 = Get-GatewayUpgradeFileHash $item.FullName })
        }
    }
    if (-not $files.ContainsKey('Gateway.DatabaseMigrator.dll') -or
        -not $files.ContainsKey('Gateway.DatabaseMigrator.deps.json') -or
        -not $files.ContainsKey('Gateway.DatabaseMigrator.runtimeconfig.json') -or
        -not $files.ContainsKey('Gateway.Infrastructure.dll')) {
        throw 'UpgradePackaging: local executable dependency closure is incomplete.'
    }
    return @($files.Values)
}

function Test-GatewayUpgradeLocalValidation {
    param([Parameter(Mandatory)]$Validation)
    if ([IO.Path]::GetFullPath($Validation.toolPath) -cne
        [IO.Path]::GetFullPath((Join-Path $Validation.toolBundleRoot 'Gateway.DatabaseMigrator.dll')) -or
        (Get-GatewayUpgradeFileHash $Validation.toolPath) -cne $Validation.toolSha256 -or
        (Get-GatewayUpgradeFingerprint $Validation.toolBundleManifest) -cne $Validation.toolBundleFingerprint) {
        throw 'UpgradePackaging: local executable binding is malformed.'
    }
    $current = @(Get-GatewayUpgradeToolBundleManifest $Validation.toolBundleRoot)
    if ((Get-GatewayUpgradeFingerprint $current) -cne $Validation.toolBundleFingerprint) {
        throw 'UpgradePackaging: local executable dependency or runtime configuration changed.'
    }
    return $true
}

Export-ModuleMember -Function New-GatewayUpgradeCandidate, Test-GatewayUpgradeCandidate,
    New-GatewayUpgradePublisherContext, Test-GatewayUpgradePublisherContext, Prepare-GatewayUpgradeCandidate,
    Test-GatewayUpgradeLocalValidation
