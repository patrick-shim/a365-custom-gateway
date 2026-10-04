Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-CommandAvailable { param([string]$Name) return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

function Install-WithWinget {
    param([string]$Id)
    if (-not (Test-CommandAvailable 'winget')) { throw "winget is required to install $Id automatically on Windows." }
    Invoke-BootstrapCommand -FilePath 'winget' -ArgumentList @(
        'install', '--id', $Id, '--exact', '--accept-package-agreements',
        '--accept-source-agreements', '--disable-interactivity'
    ) -NoCapture | Out-Null
}

function Merge-BootstrapProcessPath {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$MachinePath = '',
        [AllowEmptyString()][string]$UserPath = '',
        [AllowEmptyString()][string]$ProcessPath = '',
        [char]$PathSeparator = [IO.Path]::PathSeparator
    )

    $comparer = if ($PathSeparator -eq ';') {
        [StringComparer]::OrdinalIgnoreCase
    }
    else {
        [StringComparer]::Ordinal
    }
    $seen = [Collections.Generic.HashSet[string]]::new($comparer)
    $merged = [Collections.Generic.List[string]]::new()
    foreach ($pathValue in @($MachinePath, $UserPath, $ProcessPath)) {
        foreach ($entry in ([string]$pathValue).Split(
                $PathSeparator,
                [StringSplitOptions]::RemoveEmptyEntries)) {
            if (-not [string]::IsNullOrWhiteSpace($entry) -and $seen.Add($entry)) {
                $merged.Add($entry)
            }
        }
    }
    return [string]::Join([string]$PathSeparator, $merged.ToArray())
}

function Update-BootstrapProcessPath {
    if (-not $IsWindows) { return }
    $currentProcessPath = [string]$env:PATH
    $env:PATH = Merge-BootstrapProcessPath `
        -MachinePath ([string][Environment]::GetEnvironmentVariable('PATH', 'Machine')) `
        -UserPath ([string][Environment]::GetEnvironmentVariable('PATH', 'User')) `
        -ProcessPath $currentProcessPath
}

function Get-BootstrapBicepRepairTargetPlatform {
    [CmdletBinding()]
    param(
        [bool]$WindowsPlatform = $IsWindows,
        [System.Runtime.InteropServices.Architecture]$OSArchitecture =
            [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    )

    if (-not $WindowsPlatform) { return '' }
    switch ($OSArchitecture) {
        ([System.Runtime.InteropServices.Architecture]::X64) { return 'win-x64' }
        ([System.Runtime.InteropServices.Architecture]::Arm64) { return 'win-arm64' }
        default {
            throw "Automatic Windows Bicep repair does not support operating-system architecture '$OSArchitecture'."
        }
    }
}

function Assert-GatewayPlanPrerequisites {
    [CmdletBinding()]
    param([switch]$Install, [bool]$RequireBicep = $false)

    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 or later is required. On Windows, run gateway.cmd.' }
    foreach ($tool in @(
        [ordered]@{ command = 'git'; winget = 'Git.Git'; guidance = 'Install Git from https://git-scm.com/downloads.' },
        [ordered]@{ command = 'az'; winget = 'Microsoft.AzureCLI'; guidance = 'Install Azure CLI from https://aka.ms/installazurecli.' },
        [ordered]@{ command = 'dotnet'; winget = 'Microsoft.DotNet.SDK.10'; guidance = 'Install .NET SDK 10 from https://dotnet.microsoft.com/download/dotnet/10.0.' }
    )) {
        if (-not (Test-CommandAvailable $tool.command)) {
            if (-not $Install -or -not $IsWindows) { throw "$($tool.command) is missing. $($tool.guidance)" }
            Install-WithWinget -Id $tool.winget
            Update-BootstrapProcessPath
        }
    }
    $dotnetVersion = (Invoke-BootstrapCommand `
        -FilePath 'dotnet' `
        -ArgumentList @('--version') `
        -CaptureStdoutOnly).Trim()
    if ($dotnetVersion -notmatch '^10\.') { throw "The repository requires .NET SDK 10; the installed SDK does not match." }

    $bicepVersion = ''
    if ($RequireBicep) {
        try {
            $bicepVersion = (Invoke-BootstrapCommand `
                -FilePath 'az' `
                -ArgumentList @('bicep', 'version') `
                -CaptureStdoutOnly).Trim()
        }
        catch {
            if (-not $Install) { throw 'Azure Bicep CLI is missing. Run az bicep install, then retry.' }
            $targetPlatform = Get-BootstrapBicepRepairTargetPlatform
            if ([string]::IsNullOrWhiteSpace($targetPlatform)) {
                Invoke-BootstrapCommand `
                    -FilePath 'az' `
                    -ArgumentList @('bicep', 'install', '--only-show-errors') `
                    -NoCapture | Out-Null
            }
            else {
                Invoke-BootstrapCommand `
                    -FilePath 'az' `
                    -ArgumentList @('bicep', 'uninstall') `
                    -NoCapture | Out-Null
                Invoke-BootstrapCommand `
                    -FilePath 'az' `
                    -ArgumentList @(
                        'bicep', 'install', '--target-platform', $targetPlatform,
                        '--only-show-errors') `
                    -NoCapture | Out-Null
            }
            $bicepVersion = (Invoke-BootstrapCommand `
                -FilePath 'az' `
                -ArgumentList @('bicep', 'version') `
                -CaptureStdoutOnly).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($bicepVersion)) { throw 'Azure Bicep CLI could not be verified after local prerequisite setup.' }
    }
    return [ordered]@{ powerShell = $PSVersionTable.PSVersion.ToString(); git = $true; azureCli = $true; dotnet = $dotnetVersion; bicep = $bicepVersion }
}

Export-ModuleMember -Function *
