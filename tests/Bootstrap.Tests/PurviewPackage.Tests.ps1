BeforeAll {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Import-Module (Join-Path $root 'bootstrap/modules/Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'bootstrap/modules/PurviewPackage.psm1') -Force -DisableNameChecking
    function New-TestExecutorPackage {
        param([string]$Directory, [string]$Source, [string]$Variant = '')
        [IO.Directory]::CreateDirectory($Directory) | Out-Null
        $names = @('Gateway.Purview.Executor.dll', 'Gateway.Purview.dll', 'Gateway.Provisioning.Worker.dll',
            'PowerShell/pwsh.exe', 'Automation/Verify-PurviewTenantConnection.ps1', 'Automation/Invoke-PurviewSettingsOperation.ps1',
            'PowerShellModules/ExchangeOnlineManagement/3.10.1/ExchangeOnlineManagement.psd1')
        if ($Variant -eq 'Traversal') { $names += '../outside.dll' }
        if ($Variant -eq 'Collision') { $names += 'gateway.purview.executor.dll' }
        if ($Variant -eq 'FileDirectoryCollision') { $names += 'PowerShell' }
        if ($Variant.StartsWith('Invalid:')) { $names += $Variant.Substring(8) }
        $files = @($names | ForEach-Object { @{ path = $_; sha256 = [Convert]::ToHexStringLower(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('offline fixture'))) } })
        if ($Variant -eq 'WrongFileHash') { $files[0].sha256 = 'f' * 64 }
        $manifest = @{ schemaVersion = 1; sourceFingerprint = $Source; powerShellVersion = '7.6.5';
            exchangeOnlineManagementVersion = '3.10.1'; files = $files }
        $manifestBytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $manifest -Depth 6))
        $temporaryZip = Join-Path $Directory 'temporary.zip'
        $zip = [IO.Compression.ZipFile]::Open($temporaryZip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $names) {
                $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::NoCompression)
                $stream = $entry.Open()
                try { $stream.Write([Text.Encoding]::UTF8.GetBytes('offline fixture')) }
                finally { $stream.Dispose() }
            }
            $entry = $zip.CreateEntry('executor-runtime.json', [IO.Compression.CompressionLevel]::NoCompression)
            $stream = $entry.Open()
            try { $stream.Write($manifestBytes) }
            finally { $stream.Dispose() }
        }
        finally { $zip.Dispose() }
        if ($Variant -in @('WrongDeclaredLength', 'WrongManifestLength')) {
            $targetName = if ($Variant -eq 'WrongManifestLength') { 'executor-runtime.json' } else { $names[0] }
            $bytes = [IO.File]::ReadAllBytes($temporaryZip)
            for ($index = 0; $index -lt $bytes.Length - 46; $index++) {
                $signature = [BitConverter]::ToUInt32($bytes, $index)
                if ($signature -eq 0x04034b50) {
                    $nameLength = [BitConverter]::ToUInt16($bytes, $index + 26)
                    if ([Text.Encoding]::UTF8.GetString($bytes, $index + 30, $nameLength) -ceq $targetName) {
                        [BitConverter]::GetBytes([uint32]1).CopyTo($bytes, $index + 22)
                    }
                }
                elseif ($signature -eq 0x02014b50) {
                    $nameLength = [BitConverter]::ToUInt16($bytes, $index + 28)
                    if ([Text.Encoding]::UTF8.GetString($bytes, $index + 46, $nameLength) -ceq $targetName) {
                        [BitConverter]::GetBytes([uint32]1).CopyTo($bytes, $index + 24)
                    }
                }
            }
            [IO.File]::WriteAllBytes($temporaryZip, $bytes)
        }
        $hash = (Get-FileHash -LiteralPath $temporaryZip -Algorithm SHA256).Hash.ToLowerInvariant()
        $fileName = $hash + '.zip'
        Move-Item -LiteralPath $temporaryZip -Destination (Join-Path $Directory $fileName)
        $receipt = @{ schemaVersion = 1; sourceFingerprint = $Source; packageDigest = 'sha256:' + $hash;
            runtimeManifestDigest = 'sha256:' + [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($manifestBytes));
            packageFileName = $fileName; packageBytes = (Get-Item (Join-Path $Directory $fileName)).Length;
            powerShellVersion = '7.6.5'; exchangeOnlineManagementVersion = '3.10.1'; fileCount = $names.Count }
        $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Directory 'package-receipt.json')
        return $receipt
    }
}

Describe 'Executor package verification before publication' {
    BeforeEach {
        $source = 'sha256:' + ('a' * 64)
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }
    It 'verifies every file in a content-addressed package without execution' {
        $receipt = New-TestExecutorPackage $directory $source
        $verified = Read-PurviewExecutorPackage $directory $source
        $verified.receipt.packageDigest | Should -BeExactly $receipt.packageDigest
        $verified.receipt.fileCount | Should -Be 7
        $verified.receiptFingerprint | Should -Match '\Asha256:[0-9a-f]{64}\z'
    }
    It 'rejects an otherwise valid package built for another source' {
        $null = New-TestExecutorPackage $directory $source
        { Read-PurviewExecutorPackage $directory ('sha256:' + ('b' * 64)) } | Should -Throw '*receipt is invalid*'
    }
    It 'rejects changed ZIP bytes before inspecting contents' {
        $receipt = New-TestExecutorPackage $directory $source
        [IO.File]::AppendAllText((Join-Path $directory $receipt.packageFileName), 'changed')
        { Read-PurviewExecutorPackage $directory $source } | Should -Throw '*ZIP bytes*'
    }
    It 'rejects a content-addressed ZIP whose individual manifest hash is wrong' {
        $null = New-TestExecutorPackage $directory $source 'WrongFileHash'
        { Read-PurviewExecutorPackage $directory $source } | Should -Throw '*file hash*'
    }
    It 'rejects path traversal even when every outer digest is self-consistent' {
        $null = New-TestExecutorPackage $directory $source 'Traversal'
        { Read-PurviewExecutorPackage $directory $source } | Should -Throw '*relative path*'
    }
    It 'rejects names that collide on the target Windows filesystem' {
        $null = New-TestExecutorPackage $directory $source 'Collision'
        { Read-PurviewExecutorPackage $directory $source } | Should -Throw '*names or expanded sizes*'
    }
    It 'counts actual bytes when ZIP size metadata understates a stored entry' -ForEach @(
        @{ Variant = 'WrongDeclaredLength' }, @{ Variant = 'WrongManifestLength' }
    ) {
        $null = New-TestExecutorPackage $directory $source $Variant
        { Read-PurviewExecutorPackage $directory $source } | Should -Throw '*actual size*'
    }
    It 'rejects a file that is another runtime file directory' {
        $null = New-TestExecutorPackage $directory $source 'FileDirectoryCollision'
        { Read-PurviewExecutorPackage $directory $source } | Should -Throw '*directory paths collide*'
    }
    It 'rejects Windows device names, invalid characters and trailing aliases' -ForEach @(
        @{ Name = 'NUL.dll' }, @{ Name = 'aux/file.dll' }, @{ Name = 'COM1.log' },
        @{ Name = 'PowerShell/pwsh.exe.' }, @{ Name = 'PowerShell/pwsh.exe ' },
        @{ Name = 'bad|name.dll' }, @{ Name = 'bad?.dll' }, @{ Name = "bad`nname.dll" }
    ) {
        $null = New-TestExecutorPackage $directory $source ('Invalid:' + $Name)
        { Read-PurviewExecutorPackage $directory $source } | Should -Throw '*relative path*'
    }
    It 'rejects noncanonical digest, type, filename and extra receipt fields' -ForEach @(
        @{ Field = 'packageDigest'; Value = "sha256:$('a' * 64)`n" },
        @{ Field = 'runtimeManifestDigest'; Value = 'sha256:' + ('A' * 64) },
        @{ Field = 'packageFileName'; Value = '../outside.zip' },
        @{ Field = 'packageBytes'; Value = '100' },
        @{ Field = 'fileCount'; Value = 0 },
        @{ Field = 'extra'; Value = 'unexpected' }
    ) {
        $receipt = New-TestExecutorPackage $directory $source
        $receipt[$Field] = $Value
        $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'package-receipt.json')
        { Read-PurviewExecutorPackage $directory $source } | Should -Throw
    }
    It 'rejects a replaced manifest digest in an otherwise correct receipt' {
        $receipt = New-TestExecutorPackage $directory $source
        $receipt.runtimeManifestDigest = 'sha256:' + ('e' * 64)
        $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'package-receipt.json')
        { Read-PurviewExecutorPackage $directory $source } | Should -Throw '*manifest digest*'
    }
}

Describe 'Publisher build context isolation' {
    BeforeEach {
        $script:repository = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:inputs = [ordered]@{
            'global.json' = '{"sdk":{"version":"10.0.100"}}'
            'nuget.config' = '<configuration><packageSources><clear /><add key="nuget.org" value="https://api.nuget.org/v3/index.json" /></packageSources></configuration>'
            'src/Gateway.Purview.PackagePublisher/Dockerfile' = 'FROM scratch'
            'src/Gateway.Purview.PackagePublisher/Gateway.Purview.PackagePublisher.csproj' = '<Project Sdk="Microsoft.NET.Sdk" />'
            'src/Gateway.Purview.PackagePublisher/Program.cs' = '// Offline fixture'
            'src/Gateway.Api/appsettings.json' = '{"marker":"unrelated"}'
        }
        foreach ($inputPath in $script:inputs.Keys) {
            $full = Join-Path $script:repository $inputPath
            [IO.Directory]::CreateDirectory((Split-Path -Parent $full)) | Out-Null
            [IO.File]::WriteAllText($full, $script:inputs[$inputPath])
        }
        $script:manifest = @($script:inputs.Keys | ForEach-Object {
            @{ path = $_; sha256 = (Get-FileHash (Join-Path $script:repository $_)).Hash.ToLowerInvariant() }
        })
        $script:source = Get-BootstrapObjectFingerprint -InputObject $script:manifest
        $script:packageDirectory = Join-Path $script:repository '.bootstrap/package'
        $null = New-TestExecutorPackage $script:packageDirectory $script:source
        $script:package = Read-PurviewExecutorPackage $script:packageDirectory $script:source
        Mock Get-BootstrapSourceManifest -ModuleName PurviewPackage { $script:manifest }
        $script:output = Join-Path $script:repository '.bootstrap/context'
    }
    It 'copies only publisher sources, public build settings and the exact ZIP' {
        $result = New-PurviewPublisherBuildContext $script:repository $script:source $script:packageDirectory $script:package.receiptFingerprint $script:output
        $result | Should -BeExactly $script:output
        Test-Path (Join-Path $result 'src/Gateway.Api') | Should -BeFalse
        $files = @(Get-ChildItem -LiteralPath $result -Recurse -File)
        $files.Count | Should -Be 6
        'sha256:' + (Get-FileHash (Join-Path $result 'payload/executor.zip')).Hash.ToLowerInvariant() | Should -BeExactly $script:package.receipt.packageDigest
    }
    It 'rejects source drift before creating an output directory' {
        { New-PurviewPublisherBuildContext $script:repository ('sha256:' + ('d' * 64)) $script:packageDirectory $script:package.receiptFingerprint $script:output } | Should -Throw '*source changed*'
        Test-Path $script:output | Should -BeFalse
    }
    It 'rejects receipt drift before creating an output directory' {
        { New-PurviewPublisherBuildContext $script:repository $script:source $script:packageDirectory ('sha256:' + ('d' * 64)) $script:output } | Should -Throw '*receipt changed*'
        Test-Path $script:output | Should -BeFalse
    }
    It 'rejects an output outside the private artifact tree' {
        { New-PurviewPublisherBuildContext $script:repository $script:source $script:packageDirectory $script:package.receiptFingerprint (Join-Path $TestDrive 'outside') } | Should -Throw '*new directory*'
    }
    It 'rejects changed source bytes after manifest capture' {
        [IO.File]::AppendAllText((Join-Path $script:repository 'src/Gateway.Purview.PackagePublisher/Program.cs'), '// changed')
        { New-PurviewPublisherBuildContext $script:repository $script:source $script:packageDirectory $script:package.receiptFingerprint $script:output } | Should -Throw '*input changed*'
    }
}
