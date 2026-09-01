Describe 'POSIX gateway launcher routing boundary' -Skip:$IsWindows {
    BeforeAll {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    }

    It 'routes status and no-install to PowerShell without running the bootstrap itself' {
        $pwshStub = Join-Path $TestDrive 'pwsh'
        $marker = Join-Path $TestDrive 'pwsh-arguments.txt'
        @'
#!/bin/sh
printf '%s\n' "$@" > "$GATEWAY_TEST_MARKER"
'@ | Set-Content -LiteralPath $pwshStub -Encoding utf8NoBOM
        & chmod 700 $pwshStub
        $LASTEXITCODE | Should -Be 0

        $originalPath = $env:PATH
        $originalMarker = $env:GATEWAY_TEST_MARKER
        try {
            $env:PATH = "$TestDrive$([IO.Path]::PathSeparator)$originalPath"
            $env:GATEWAY_TEST_MARKER = $marker
            $launcher = Join-Path $repositoryRoot 'gateway'

            & bash $launcher status --no-install --json

            $LASTEXITCODE | Should -Be 0
            $arguments = @(Get-Content -LiteralPath $marker)
            $arguments | Should -Contain '-Mode'
            $arguments | Should -Contain 'Status'
            $arguments | Should -Contain '-InstallPrerequisites:$false'
            $arguments | Should -Contain '-OutputFormat'
            $arguments | Should -Contain 'Json'
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_MARKER = $originalMarker
        }
    }

    It 'routes the public database recovery command and explicit authorization to PowerShell' {
        $pwshStub = Join-Path $TestDrive 'pwsh'
        $marker = Join-Path $TestDrive 'recovery-pwsh-arguments.txt'
        @'
#!/bin/sh
printf '%s\n' "$@" > "$GATEWAY_TEST_MARKER"
'@ | Set-Content -LiteralPath $pwshStub -Encoding utf8NoBOM
        & chmod 700 $pwshStub
        $LASTEXITCODE | Should -Be 0

        $originalPath = $env:PATH
        $originalMarker = $env:GATEWAY_TEST_MARKER
        try {
            $env:PATH = "$TestDrive$([IO.Path]::PathSeparator)$originalPath"
            $env:GATEWAY_TEST_MARKER = $marker
            $launcher = Join-Path $repositoryRoot 'gateway'
            $configPath = 'bootstrap/config.json'

            & bash $launcher recover-database --config $configPath --yes

            $LASTEXITCODE | Should -Be 0
            $arguments = @(Get-Content -LiteralPath $marker)
            $arguments | Should -Contain '-Mode'
            $arguments | Should -Contain 'RecoverDatabase'
            $arguments | Should -Contain '-Config'
            $arguments | Should -Contain $configPath
            $arguments | Should -Contain '-Yes'
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_MARKER = $originalMarker
        }
    }

    It 'routes the one-shot manual database repair command and explicit authorization to PowerShell' {
        $pwshStub = Join-Path $TestDrive 'pwsh'
        $marker = Join-Path $TestDrive 'repair-pwsh-arguments.txt'
        @'
#!/bin/sh
printf '%s\n' "$@" > "$GATEWAY_TEST_MARKER"
'@ | Set-Content -LiteralPath $pwshStub -Encoding utf8NoBOM
        & chmod 700 $pwshStub

        $originalPath = $env:PATH
        $originalMarker = $env:GATEWAY_TEST_MARKER
        try {
            $env:PATH = "$TestDrive$([IO.Path]::PathSeparator)$originalPath"
            $env:GATEWAY_TEST_MARKER = $marker
            & bash (Join-Path $repositoryRoot 'gateway') repair-database --config bootstrap/config.json --yes

            $LASTEXITCODE | Should -Be 0
            $arguments = @(Get-Content -LiteralPath $marker)
            $arguments | Should -Contain '-Mode'
            $arguments | Should -Contain 'RepairDatabase'
            $arguments | Should -Contain '-Yes'
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_MARKER = $originalMarker
        }
    }

    It 'rejects an unknown command before invoking PowerShell' {
        $pwshStub = Join-Path $TestDrive 'pwsh'
        $marker = Join-Path $TestDrive 'pwsh-was-invoked.txt'
        @'
#!/bin/sh
touch "$GATEWAY_TEST_MARKER"
'@ | Set-Content -LiteralPath $pwshStub -Encoding utf8NoBOM
        & chmod 700 $pwshStub

        $originalPath = $env:PATH
        $originalMarker = $env:GATEWAY_TEST_MARKER
        try {
            $env:PATH = "$TestDrive$([IO.Path]::PathSeparator)$originalPath"
            $env:GATEWAY_TEST_MARKER = $marker
            $launcher = Join-Path $repositoryRoot 'gateway'

            & bash $launcher unknown-command 2>$null | Out-Null

            $LASTEXITCODE | Should -Be 2
            Test-Path -LiteralPath $marker | Should -BeFalse
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_MARKER = $originalMarker
        }
    }

    It 'reports each missing setup runtime before starting the UI host' {
        $launcher = Join-Path $repositoryRoot 'gateway'
        $bashPath = (Get-Command bash -ErrorAction Stop).Source
        $chmodPath = (Get-Command chmod -ErrorAction Stop).Source
        $originalPath = $env:PATH
        $originalRepositoryRoot = $env:GATEWAY_TEST_REPOSITORY_ROOT
        $originalMarker = $env:GATEWAY_TEST_DOTNET_HOST_MARKER
        try {
            foreach ($case in @(
                @{ Missing = 'dotnet'; Message = 'Setup requires the .NET 10 SDK.' },
                @{ Missing = 'pwsh'; Message = 'Setup requires PowerShell 7 (pwsh).' },
                @{ Missing = 'az'; Message = 'Setup requires Azure CLI (az).' }
            )) {
                $stubDirectory = Join-Path $TestDrive "setup-missing-$($case.Missing)"
                $null = New-Item -ItemType Directory -Path $stubDirectory -Force
                @'
#!/bin/sh
printf '%s\n' "$GATEWAY_TEST_REPOSITORY_ROOT"
'@ | Set-Content -LiteralPath (Join-Path $stubDirectory 'dirname') -Encoding utf8NoBOM

                if ($case.Missing -ne 'dotnet') {
                    @'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf '10.0.100\n'
  exit 0
fi
: > "$GATEWAY_TEST_DOTNET_HOST_MARKER"
'@ | Set-Content -LiteralPath (Join-Path $stubDirectory 'dotnet') -Encoding utf8NoBOM
                }
                if ($case.Missing -ne 'pwsh') {
                    "#!/bin/sh`nexit 0`n" | Set-Content -LiteralPath (Join-Path $stubDirectory 'pwsh') -Encoding utf8NoBOM
                }
                if ($case.Missing -ne 'az') {
                    "#!/bin/sh`nexit 0`n" | Set-Content -LiteralPath (Join-Path $stubDirectory 'az') -Encoding utf8NoBOM
                }

                Get-ChildItem -LiteralPath $stubDirectory -File | ForEach-Object {
                    & $chmodPath 700 $_.FullName
                    $LASTEXITCODE | Should -Be 0
                }

                $marker = Join-Path $stubDirectory 'dotnet-hosted-ui.txt'
                $env:PATH = $stubDirectory
                $env:GATEWAY_TEST_REPOSITORY_ROOT = $repositoryRoot
                $env:GATEWAY_TEST_DOTNET_HOST_MARKER = $marker

                $output = (& $bashPath $launcher setup 2>&1 | Out-String)

                $LASTEXITCODE | Should -Be 1
                $output | Should -Match ([regex]::Escape($case.Message))
                $output | Should -Match ([regex]::Escape('Install or repair the listed tools'))
                Test-Path -LiteralPath $marker | Should -BeFalse
            }
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_REPOSITORY_ROOT = $originalRepositoryRoot
            $env:GATEWAY_TEST_DOTNET_HOST_MARKER = $originalMarker
        }
    }

    It 'starts setup only after all three runtime probes succeed' {
        $launcher = Join-Path $repositoryRoot 'gateway'
        $bashPath = (Get-Command bash -ErrorAction Stop).Source
        $chmodPath = (Get-Command chmod -ErrorAction Stop).Source
        $stubDirectory = Join-Path $TestDrive 'setup-ready'
        $null = New-Item -ItemType Directory -Path $stubDirectory -Force
        @'
#!/bin/sh
printf '%s\n' "$GATEWAY_TEST_REPOSITORY_ROOT"
'@ | Set-Content -LiteralPath (Join-Path $stubDirectory 'dirname') -Encoding utf8NoBOM
        @'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf '10.0.100\n'
  exit 0
fi
printf '%s\n' "$@" > "$GATEWAY_TEST_DOTNET_ARGUMENTS"
'@ | Set-Content -LiteralPath (Join-Path $stubDirectory 'dotnet') -Encoding utf8NoBOM
        "#!/bin/sh`nexit 0`n" | Set-Content -LiteralPath (Join-Path $stubDirectory 'pwsh') -Encoding utf8NoBOM
        "#!/bin/sh`nexit 0`n" | Set-Content -LiteralPath (Join-Path $stubDirectory 'az') -Encoding utf8NoBOM
        Get-ChildItem -LiteralPath $stubDirectory -File | ForEach-Object {
            & $chmodPath 700 $_.FullName
            $LASTEXITCODE | Should -Be 0
        }

        $argumentRecord = Join-Path $stubDirectory 'dotnet-arguments.txt'
        $originalPath = $env:PATH
        $originalRepositoryRoot = $env:GATEWAY_TEST_REPOSITORY_ROOT
        $originalArguments = $env:GATEWAY_TEST_DOTNET_ARGUMENTS
        try {
            $env:PATH = $stubDirectory
            $env:GATEWAY_TEST_REPOSITORY_ROOT = $repositoryRoot
            $env:GATEWAY_TEST_DOTNET_ARGUMENTS = $argumentRecord

            & $bashPath $launcher setup --no-open

            $LASTEXITCODE | Should -Be 0
            $arguments = @(Get-Content -LiteralPath $argumentRecord)
            $arguments | Should -Contain 'run'
            $arguments | Should -Contain '--project'
            $arguments | Should -Contain (Join-Path $repositoryRoot 'tools/Gateway.Setup/Gateway.Setup.csproj')
            $arguments | Should -Contain '--repo-root'
            $arguments | Should -Contain $repositoryRoot
            $arguments | Should -Contain '--no-open'
        }
        finally {
            $env:PATH = $originalPath
            $env:GATEWAY_TEST_REPOSITORY_ROOT = $originalRepositoryRoot
            $env:GATEWAY_TEST_DOTNET_ARGUMENTS = $originalArguments
        }
    }
}

Describe 'Cross-platform guided setup prerequisite contract' {
    BeforeAll {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    }

    It 'keeps the Windows launcher aligned with the POSIX runtime gate' {
        $launcher = Get-Content -LiteralPath (Join-Path $repositoryRoot 'gateway.cmd') -Raw
        $runSetup = $launcher.IndexOf(':run_setup', [StringComparison]::OrdinalIgnoreCase)
        $preflight = $launcher.IndexOf('call :check_setup_prerequisites', $runSetup, [StringComparison]::OrdinalIgnoreCase)
        $hostIndex = $launcher.IndexOf('dotnet run --project', $runSetup, [StringComparison]::OrdinalIgnoreCase)

        $runSetup | Should -BeGreaterOrEqual 0
        $preflight | Should -BeGreaterThan $runSetup
        $hostIndex | Should -BeGreaterThan $preflight
        $launcher | Should -Match 'where pwsh\.exe'
        $launcher | Should -Match 'PSVersionTable\.PSVersion\.Major -ge 7'
        $launcher | Should -Match 'where dotnet\.exe'
        $launcher | Should -Match 'dotnet --version'
        $launcher | Should -Match 'where az'
        $launcher | Should -Match 'call az version'
        $launcher | Should -Match 'Setup requires PowerShell 7'
        $launcher | Should -Match 'Setup requires the \.NET SDK feature band 10\.0\.4xx from global\.json'
        $launcher | Should -Match 'Setup requires Azure CLI'
        $launcher | Should -Match ([regex]::Escape('--repo-root "%~dp0."'))
        $launcher | Should -Not -Match ([regex]::Escape('--repo-root "%~dp0"'))
        $launcher | Should -Match 'if /I "%COMMAND%"=="recover-database" set "GATEWAY_MODE=RecoverDatabase"'
        $launcher | Should -Match 'if /I "%COMMAND%"=="repair-database" set "GATEWAY_MODE=RepairDatabase"'
        $launcher | Should -Not -Match 'continue-bootstrap|repair-api-attestation'
    }

    It 'gives Windows Setup an explicit guided prerequisite installation policy' {
        $launcher = Get-Content -LiteralPath (Join-Path $repositoryRoot 'gateway.cmd') -Raw
        $globalJson = Get-Content -LiteralPath (Join-Path $repositoryRoot 'global.json') -Raw | ConvertFrom-Json
        $requiredSdk = [version]$globalJson.sdk.version
        $requiredFeatureBand = '{0}.{1}.{2}' -f $requiredSdk.Major, $requiredSdk.Minor, ([math]::Floor($requiredSdk.Build / 100))

        $launcher | Should -Match 'set "GATEWAY_NO_INSTALL=0"'
        $launcher | Should -Match 'if /I "%~1"=="--no-install"'
        $launcher | Should -Match 'set "GATEWAY_NO_INSTALL=1"'
        $launcher | Should -Match ([regex]::Escape('Usage: gateway.cmd setup [--no-open] [--no-install]'))
        $launcher | Should -Match ([regex]::Escape('Microsoft.PowerShell'))
        $launcher | Should -Match ([regex]::Escape('Microsoft.DotNet.SDK.10'))
        $launcher | Should -Match ([regex]::Escape('Microsoft.AzureCLI'))
        $launcher | Should -Match ([regex]::Escape($requiredFeatureBand))
        $launcher | Should -Match 'call :refresh_setup_tool_paths'
        $launcher | Should -Match '--no-install forbids installing it'
    }
}

Describe 'Windows gateway launcher mutation boundary' -Skip:(-not $IsWindows) {
    BeforeAll {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))

        $fakeToolProject = Join-Path $TestDrive 'GatewayLauncherFakeTool'
        $fakeToolBin = Join-Path $TestDrive 'fake-tool-bin'
        $null = New-Item -ItemType Directory -Path $fakeToolProject, $fakeToolBin -Force
        @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AssemblyName>GatewayLauncherFakeTool</AssemblyName>
  </PropertyGroup>
</Project>
'@ | Set-Content -LiteralPath (Join-Path $fakeToolProject 'GatewayLauncherFakeTool.csproj') -Encoding utf8NoBOM
        @'
using System;
using System.IO;
using System.Linq;

internal static class Program
{
    private static int Main(string[] args)
    {
        var tool = Path.GetFileNameWithoutExtension(Environment.ProcessPath ?? string.Empty).ToLowerInvariant();
        return tool switch
        {
            "where" => RunWhere(args),
            "winget" => RunWinget(args),
            "dotnet" => RunDotNet(args),
            "pwsh" => 0,
            "az" => 0,
            _ => 91
        };
    }

    private static int RunWhere(string[] args)
    {
        if (args.Length == 0)
        {
            return 1;
        }

        var requested = Path.GetFileNameWithoutExtension(args[0]).ToLowerInvariant();
        if (requested == "winget")
        {
            return 0;
        }

        var missing = (Environment.GetEnvironmentVariable("GATEWAY_TEST_MISSING_TOOL") ?? string.Empty).ToLowerInvariant();
        if (requested == missing && !PackageWasInstalled(PackageFor(requested)))
        {
            return 1;
        }

        return File.Exists(Path.Combine(AppContext.BaseDirectory, requested + ".exe")) ? 0 : 1;
    }

    private static int RunWinget(string[] args)
    {
        var marker = Environment.GetEnvironmentVariable("GATEWAY_TEST_INSTALL_MARKER");
        if (string.IsNullOrWhiteSpace(marker))
        {
            return 92;
        }

        File.AppendAllText(marker, string.Join(" ", args) + Environment.NewLine);
        return 0;
    }

    private static int RunDotNet(string[] args)
    {
        if (args.Length > 0 && args[0] == "--version")
        {
            var version = Environment.GetEnvironmentVariable("GATEWAY_TEST_DOTNET_VERSION") ?? "10.0.400";
            if (PackageWasInstalled("Microsoft.DotNet.SDK.10"))
            {
                version = "10.0.400";
            }

            Console.WriteLine(version);
            return 0;
        }

        var marker = Environment.GetEnvironmentVariable("GATEWAY_TEST_DOTNET_ARGUMENTS");
        if (!string.IsNullOrWhiteSpace(marker))
        {
            File.WriteAllLines(marker, args);
        }

        return 0;
    }

    private static bool PackageWasInstalled(string packageId)
    {
        if (string.IsNullOrWhiteSpace(packageId))
        {
            return false;
        }

        var marker = Environment.GetEnvironmentVariable("GATEWAY_TEST_INSTALL_MARKER");
        return !string.IsNullOrWhiteSpace(marker)
            && File.Exists(marker)
            && File.ReadAllText(marker).Contains(packageId, StringComparison.OrdinalIgnoreCase);
    }

    private static string PackageFor(string tool) => tool switch
    {
        "pwsh" => "Microsoft.PowerShell",
        "dotnet" => "Microsoft.DotNet.SDK.10",
        "az" => "Microsoft.AzureCLI",
        _ => string.Empty
    };
}
'@ | Set-Content -LiteralPath (Join-Path $fakeToolProject 'Program.cs') -Encoding utf8NoBOM

        & dotnet build (Join-Path $fakeToolProject 'GatewayLauncherFakeTool.csproj') --configuration Release --output $fakeToolBin --nologo
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not build the isolated Windows launcher fake executables.'
        }

        $fakeToolHost = Join-Path $fakeToolBin 'GatewayLauncherFakeTool.exe'
        foreach ($toolName in @('where.exe', 'winget.exe', 'pwsh.exe', 'dotnet.exe', 'az.exe')) {
            Copy-Item -LiteralPath $fakeToolHost -Destination (Join-Path $fakeToolBin $toolName) -Force
        }
    }

    It 'never invokes winget when --no-install is present and PowerShell is unavailable' {
        $whereStub = Join-Path $TestDrive 'where.cmd'
        $wingetStub = Join-Path $TestDrive 'winget.cmd'
        $marker = Join-Path $TestDrive 'winget-was-invoked.txt'
        '@exit /b 1' | Set-Content -LiteralPath $whereStub -Encoding ascii
        '@echo invoked>"%GATEWAY_TEST_MARKER%"' | Set-Content -LiteralPath $wingetStub -Encoding ascii

        $originalPath = $env:Path
        $originalProgramFiles = $env:ProgramFiles
        $originalMarker = $env:GATEWAY_TEST_MARKER
        try {
            $env:Path = $TestDrive
            $env:ProgramFiles = Join-Path $TestDrive 'missing-program-files'
            $env:GATEWAY_TEST_MARKER = $marker
            $launcher = Join-Path $repositoryRoot 'gateway.cmd'

            & $env:ComSpec /d /c "`"$launcher`" status --no-install" 2>$null | Out-Null

            $LASTEXITCODE | Should -Be 1
            Test-Path -LiteralPath $marker | Should -BeFalse
        }
        finally {
            $env:Path = $originalPath
            $env:ProgramFiles = $originalProgramFiles
            $env:GATEWAY_TEST_MARKER = $originalMarker
        }
    }

    It 'installs missing <Tool> through the exact reviewed package and rechecks before starting Setup' -ForEach @(
        @{ Tool = 'pwsh'; PackageId = 'Microsoft.PowerShell' }
        @{ Tool = 'dotnet'; PackageId = 'Microsoft.DotNet.SDK.10' }
        @{ Tool = 'az'; PackageId = 'Microsoft.AzureCLI' }
    ) {
        $installMarker = Join-Path $TestDrive "install-$Tool.txt"
        $dotnetMarker = Join-Path $TestDrive "dotnet-$Tool.txt"
        $launcher = Join-Path $repositoryRoot 'gateway.cmd'
        $originalValues = @{
            Path = $env:Path
            ProgramFiles = $env:ProgramFiles
            ProgramW6432 = $env:ProgramW6432
            LocalAppData = $env:LocalAppData
            MissingTool = $env:GATEWAY_TEST_MISSING_TOOL
            InstallMarker = $env:GATEWAY_TEST_INSTALL_MARKER
            DotnetMarker = $env:GATEWAY_TEST_DOTNET_ARGUMENTS
            DotnetVersion = $env:GATEWAY_TEST_DOTNET_VERSION
        }
        $originalProgramFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        try {
            $env:Path = $fakeToolBin
            $env:ProgramFiles = Join-Path $TestDrive 'program-files'
            $env:ProgramW6432 = Join-Path $TestDrive 'program-w6432'
            $env:LocalAppData = Join-Path $TestDrive 'local-app-data'
            [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', (Join-Path $TestDrive 'program-files-x86'))
            $env:GATEWAY_TEST_MISSING_TOOL = $Tool
            $env:GATEWAY_TEST_INSTALL_MARKER = $installMarker
            $env:GATEWAY_TEST_DOTNET_ARGUMENTS = $dotnetMarker
            $env:GATEWAY_TEST_DOTNET_VERSION = '10.0.400'

            & $env:ComSpec /d /c "`"$launcher`" setup --no-open" 2>&1 | Out-Null

            $LASTEXITCODE | Should -Be 0
            $installArguments = Get-Content -LiteralPath $installMarker -Raw
            $installArguments | Should -Match ([regex]::Escape("install --id $PackageId --exact --source winget --accept-package-agreements --accept-source-agreements"))
            $dotnetArguments = @(Get-Content -LiteralPath $dotnetMarker)
            $dotnetArguments | Should -Contain 'run'
            $dotnetArguments | Should -Contain '--no-open'
        }
        finally {
            $env:Path = $originalValues.Path
            $env:ProgramFiles = $originalValues.ProgramFiles
            $env:ProgramW6432 = $originalValues.ProgramW6432
            $env:LocalAppData = $originalValues.LocalAppData
            [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $originalProgramFilesX86)
            $env:GATEWAY_TEST_MISSING_TOOL = $originalValues.MissingTool
            $env:GATEWAY_TEST_INSTALL_MARKER = $originalValues.InstallMarker
            $env:GATEWAY_TEST_DOTNET_ARGUMENTS = $originalValues.DotnetMarker
            $env:GATEWAY_TEST_DOTNET_VERSION = $originalValues.DotnetVersion
        }
    }

    It 'never invokes winget for missing or incompatible <Tool> when Setup receives --no-install' -ForEach @(
        @{ Tool = 'pwsh'; MissingTool = 'pwsh'; DotnetVersion = '10.0.400'; Guidance = 'PowerShell 7' }
        @{ Tool = 'dotnet'; MissingTool = 'dotnet'; DotnetVersion = '10.0.400'; Guidance = '.NET SDK feature band 10.0.4xx' }
        @{ Tool = 'dotnet-feature-band'; MissingTool = ''; DotnetVersion = '10.0.100'; Guidance = '.NET SDK feature band 10.0.4xx' }
        @{ Tool = 'az'; MissingTool = 'az'; DotnetVersion = '10.0.400'; Guidance = 'Azure CLI' }
    ) {
        $installMarker = Join-Path $TestDrive "forbidden-install-$Tool.txt"
        $dotnetMarker = Join-Path $TestDrive "forbidden-dotnet-$Tool.txt"
        $launcher = Join-Path $repositoryRoot 'gateway.cmd'
        $originalValues = @{
            Path = $env:Path
            ProgramFiles = $env:ProgramFiles
            ProgramW6432 = $env:ProgramW6432
            LocalAppData = $env:LocalAppData
            MissingTool = $env:GATEWAY_TEST_MISSING_TOOL
            InstallMarker = $env:GATEWAY_TEST_INSTALL_MARKER
            DotnetMarker = $env:GATEWAY_TEST_DOTNET_ARGUMENTS
            DotnetVersion = $env:GATEWAY_TEST_DOTNET_VERSION
        }
        $originalProgramFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        try {
            $env:Path = $fakeToolBin
            $env:ProgramFiles = Join-Path $TestDrive 'program-files'
            $env:ProgramW6432 = Join-Path $TestDrive 'program-w6432'
            $env:LocalAppData = Join-Path $TestDrive 'local-app-data'
            [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', (Join-Path $TestDrive 'program-files-x86'))
            $env:GATEWAY_TEST_MISSING_TOOL = $MissingTool
            $env:GATEWAY_TEST_INSTALL_MARKER = $installMarker
            $env:GATEWAY_TEST_DOTNET_ARGUMENTS = $dotnetMarker
            $env:GATEWAY_TEST_DOTNET_VERSION = $DotnetVersion

            $output = (& $env:ComSpec /d /c "`"$launcher`" setup --no-open --no-install" 2>&1 | Out-String)

            $LASTEXITCODE | Should -Be 1
            $output | Should -Match ([regex]::Escape($Guidance))
            $output | Should -Match ([regex]::Escape('--no-install forbids installing it'))
            Test-Path -LiteralPath $installMarker | Should -BeFalse
            Test-Path -LiteralPath $dotnetMarker | Should -BeFalse
        }
        finally {
            $env:Path = $originalValues.Path
            $env:ProgramFiles = $originalValues.ProgramFiles
            $env:ProgramW6432 = $originalValues.ProgramW6432
            $env:LocalAppData = $originalValues.LocalAppData
            [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $originalProgramFilesX86)
            $env:GATEWAY_TEST_MISSING_TOOL = $originalValues.MissingTool
            $env:GATEWAY_TEST_INSTALL_MARKER = $originalValues.InstallMarker
            $env:GATEWAY_TEST_DOTNET_ARGUMENTS = $originalValues.DotnetMarker
            $env:GATEWAY_TEST_DOTNET_VERSION = $originalValues.DotnetVersion
        }
    }

    It 'installs the required SDK when dotnet reports an older 10.0 feature band' {
        $installMarker = Join-Path $TestDrive 'feature-band-install.txt'
        $dotnetMarker = Join-Path $TestDrive 'feature-band-dotnet.txt'
        $launcher = Join-Path $repositoryRoot 'gateway.cmd'
        $originalValues = @{
            Path = $env:Path
            ProgramFiles = $env:ProgramFiles
            ProgramW6432 = $env:ProgramW6432
            LocalAppData = $env:LocalAppData
            MissingTool = $env:GATEWAY_TEST_MISSING_TOOL
            InstallMarker = $env:GATEWAY_TEST_INSTALL_MARKER
            DotnetMarker = $env:GATEWAY_TEST_DOTNET_ARGUMENTS
            DotnetVersion = $env:GATEWAY_TEST_DOTNET_VERSION
        }
        $originalProgramFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        try {
            $env:Path = $fakeToolBin
            $env:ProgramFiles = Join-Path $TestDrive 'program-files'
            $env:ProgramW6432 = Join-Path $TestDrive 'program-w6432'
            $env:LocalAppData = Join-Path $TestDrive 'local-app-data'
            [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', (Join-Path $TestDrive 'program-files-x86'))
            $env:GATEWAY_TEST_MISSING_TOOL = ''
            $env:GATEWAY_TEST_INSTALL_MARKER = $installMarker
            $env:GATEWAY_TEST_DOTNET_ARGUMENTS = $dotnetMarker
            $env:GATEWAY_TEST_DOTNET_VERSION = '10.0.100'

            & $env:ComSpec /d /c "`"$launcher`" setup --no-open" 2>&1 | Out-Null

            $LASTEXITCODE | Should -Be 0
            (Get-Content -LiteralPath $installMarker -Raw) | Should -Match ([regex]::Escape('install --id Microsoft.DotNet.SDK.10 --exact'))
            Test-Path -LiteralPath $dotnetMarker | Should -BeTrue
        }
        finally {
            $env:Path = $originalValues.Path
            $env:ProgramFiles = $originalValues.ProgramFiles
            $env:ProgramW6432 = $originalValues.ProgramW6432
            $env:LocalAppData = $originalValues.LocalAppData
            [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $originalProgramFilesX86)
            $env:GATEWAY_TEST_MISSING_TOOL = $originalValues.MissingTool
            $env:GATEWAY_TEST_INSTALL_MARKER = $originalValues.InstallMarker
            $env:GATEWAY_TEST_DOTNET_ARGUMENTS = $originalValues.DotnetMarker
            $env:GATEWAY_TEST_DOTNET_VERSION = $originalValues.DotnetVersion
        }
    }
}
