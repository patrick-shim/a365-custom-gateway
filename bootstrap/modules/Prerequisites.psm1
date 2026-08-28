Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-CommandAvailable { param([string]$Name) return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

function Install-WithWinget {
    param([string]$Id)
    if (-not (Test-CommandAvailable 'winget')) { throw "winget is required to install $Id automatically on Windows." }
    & winget install --id $Id --exact --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "winget failed to install $Id." }
}

function Assert-BootstrapPrerequisites {
    [CmdletBinding()]
    param([switch]$Install, [switch]$RequirePurview)

    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 or later is required. On Windows, run bootstrap.cmd.' }
    if (-not (Test-CommandAvailable 'git')) {
        if (-not $Install -or -not $IsWindows) { throw 'Git is missing. Install it from https://git-scm.com/downloads.' }
        Install-WithWinget 'Git.Git'
        $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + [IO.Path]::PathSeparator + [Environment]::GetEnvironmentVariable('PATH', 'User')
    }
    if (-not (Test-CommandAvailable 'az')) {
        if (-not $Install -or -not $IsWindows) { throw 'Azure CLI is missing. Install it from https://aka.ms/installazurecliwindows (Windows), https://aka.ms/InstallAzureCLIDeb (Debian/Ubuntu), or Homebrew.' }
        Install-WithWinget 'Microsoft.AzureCLI'
        $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + [IO.Path]::PathSeparator + [Environment]::GetEnvironmentVariable('PATH', 'User')
    }
    if (-not (Test-CommandAvailable 'dotnet')) {
        if (-not $Install -or -not $IsWindows) { throw '.NET SDK 10 is missing. Install it from https://dotnet.microsoft.com/download/dotnet/10.0.' }
        Install-WithWinget 'Microsoft.DotNet.SDK.10'
        $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + [IO.Path]::PathSeparator + [Environment]::GetEnvironmentVariable('PATH', 'User')
    }

    $dotnetVersion = (& dotnet --version).Trim()
    if ($LASTEXITCODE -ne 0 -or $dotnetVersion -notmatch '^10\.') { throw "The repository requires .NET SDK 10; found '$dotnetVersion'." }
    & az bicep install --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI could not install/verify Bicep.' }

    $a365Installed = (& dotnet tool list --global | Out-String) -match '(?im)^microsoft\.agents\.a365\.devtools\.cli\s'
    if (-not $a365Installed) {
        if (-not $Install) { throw 'Agent 365 CLI is missing. Run: dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli' }
        & dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli
        if ($LASTEXITCODE -ne 0) { throw 'Failed to install the Agent 365 CLI.' }
    }
    $dotnetToolsPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dotnet/tools'
    if ($env:PATH -notlike "*$dotnetToolsPath*") { $env:PATH += [IO.Path]::PathSeparator + $dotnetToolsPath }
    if (-not (Test-CommandAvailable 'a365')) { throw "Agent 365 CLI is installed but 'a365' is not available from PATH ($dotnetToolsPath)." }

    if ($RequirePurview) {
        if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
            if (-not $Install) { throw 'ExchangeOnlineManagement is required for Purview configuration.' }
            Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
        }
    }

    return [ordered]@{
        powerShell = $PSVersionTable.PSVersion.ToString()
        azureCli = (& az version --query '"azure-cli"' -o tsv).Trim()
        dotnet = $dotnetVersion
        git = (& git --version | Out-String).Trim()
        bicep = (& az bicep version | Out-String).Trim()
        agent365CliInstalled = $true
        exchangeOnlineManagementInstalled = [bool](Get-Module -ListAvailable -Name ExchangeOnlineManagement)
    }
}

Export-ModuleMember -Function *
