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

function Update-BootstrapProcessPath {
    if (-not $IsWindows) { return }
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') +
        [IO.Path]::PathSeparator + [Environment]::GetEnvironmentVariable('PATH', 'User')
}

function Assert-GatewayPlanPrerequisites {
    [CmdletBinding()]
    param([switch]$Install)

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
    $dotnetVersion = (Invoke-BootstrapCommand -FilePath 'dotnet' -ArgumentList @('--version')).Trim()
    if ($dotnetVersion -notmatch '^10\.') { throw "The repository requires .NET SDK 10; the installed SDK does not match." }

    $bicepVersion = ''
    try { $bicepVersion = (Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('bicep', 'version')).Trim() }
    catch {
        if (-not $Install) { throw 'Azure Bicep CLI is missing. Run az bicep install, then retry.' }
        Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('bicep', 'install', '--only-show-errors') -NoCapture | Out-Null
        $bicepVersion = (Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('bicep', 'version')).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($bicepVersion)) { throw 'Azure Bicep CLI could not be verified after local prerequisite setup.' }
    return [ordered]@{ powerShell = $PSVersionTable.PSVersion.ToString(); git = $true; azureCli = $true; dotnet = $dotnetVersion; bicep = $bicepVersion }
}

function Assert-BootstrapPrerequisites {
    [CmdletBinding()]
    param([switch]$Install, [switch]$RequirePurview)

    Assert-GatewayPlanPrerequisites -Install:$Install | Out-Null
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 or later is required. On Windows, run .\\gateway.cmd from the repository root.' }
    if (-not (Test-CommandAvailable 'git')) {
        if (-not $Install -or -not $IsWindows) { throw 'Git is missing. Install it from https://git-scm.com/downloads.' }
        Install-WithWinget 'Git.Git'
        Update-BootstrapProcessPath
    }
    if (-not (Test-CommandAvailable 'az')) {
        if (-not $Install -or -not $IsWindows) { throw 'Azure CLI is missing. Install it from https://aka.ms/installazurecliwindows (Windows), https://aka.ms/InstallAzureCLIDeb (Debian/Ubuntu), or Homebrew.' }
        Install-WithWinget 'Microsoft.AzureCLI'
        Update-BootstrapProcessPath
    }
    if (-not (Test-CommandAvailable 'dotnet')) {
        if (-not $Install -or -not $IsWindows) { throw '.NET SDK 10 is missing. Install it from https://dotnet.microsoft.com/download/dotnet/10.0.' }
        Install-WithWinget 'Microsoft.DotNet.SDK.10'
        Update-BootstrapProcessPath
    }

    $dotnetVersion = (& dotnet --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $dotnetVersion -notmatch '^10\.') { throw "The repository requires .NET SDK 10; found '$dotnetVersion'." }
    $bicepVersion = (Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('bicep', 'version')).Trim()
    if ([string]::IsNullOrWhiteSpace($bicepVersion)) { throw 'Azure CLI could not verify Bicep.' }

    if ($RequirePurview) {
        if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
            if (-not $Install) { throw 'ExchangeOnlineManagement is required for Purview configuration.' }
            Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber -Repository PSGallery | Out-Null
        }
    }

    return [ordered]@{
        powerShell = $PSVersionTable.PSVersion.ToString()
        azureCli = (& az version --query '"azure-cli"' -o tsv).Trim()
        dotnet = $dotnetVersion
        git = (& git --version | Out-String).Trim()
        bicep = $bicepVersion
        agent365BlueprintProvider = 'MicrosoftGraphV1DirectNoCredential'
        exchangeOnlineManagementInstalled = [bool](Get-Module -ListAvailable -Name ExchangeOnlineManagement)
    }
}

Export-ModuleMember -Function *
