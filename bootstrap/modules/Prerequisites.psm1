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
    $dotnetVersion = (Invoke-BootstrapCommand `
        -FilePath 'dotnet' `
        -ArgumentList @('--version') `
        -CaptureStdoutOnly).Trim()
    if ($dotnetVersion -notmatch '^10\.') { throw "The repository requires .NET SDK 10; the installed SDK does not match." }

    $bicepVersion = ''
    try {
        $bicepVersion = (Invoke-BootstrapCommand `
            -FilePath 'az' `
            -ArgumentList @('bicep', 'version') `
            -CaptureStdoutOnly).Trim()
    }
    catch {
        if (-not $Install) { throw 'Azure Bicep CLI is missing. Run az bicep install, then retry.' }
        Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('bicep', 'install', '--only-show-errors') -NoCapture | Out-Null
        $bicepVersion = (Invoke-BootstrapCommand `
            -FilePath 'az' `
            -ArgumentList @('bicep', 'version') `
            -CaptureStdoutOnly).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($bicepVersion)) { throw 'Azure Bicep CLI could not be verified after local prerequisite setup.' }
    return [ordered]@{ powerShell = $PSVersionTable.PSVersion.ToString(); git = $true; azureCli = $true; dotnet = $dotnetVersion; bicep = $bicepVersion }
}

function Assert-BootstrapPrerequisites {
    [CmdletBinding()]
    param([switch]$Install, [switch]$RequirePurview)

    if ($RequirePurview -and -not $IsWindows) {
        throw 'Microsoft does not support Security & Compliance PowerShell in PowerShell 7 on macOS or Linux. Run Purview-enabled setup from Windows, or keep Purview policy authoring off on this computer.'
    }

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

    $dotnetVersion = (Invoke-BootstrapCommand `
        -FilePath 'dotnet' `
        -ArgumentList @('--version') `
        -CaptureStdoutOnly).Trim()
    if ($dotnetVersion -notmatch '^10\.') { throw 'The repository requires .NET SDK 10; the installed SDK does not match.' }
    $bicepVersion = (Invoke-BootstrapCommand `
        -FilePath 'az' `
        -ArgumentList @('bicep', 'version') `
        -CaptureStdoutOnly).Trim()
    if ([string]::IsNullOrWhiteSpace($bicepVersion)) { throw 'Azure CLI could not verify Bicep.' }

    $azureCliVersion = ''
    try {
        $azureCliVersionMetadata = Invoke-BootstrapCommand `
            -FilePath 'az' `
            -ArgumentList @('version', '--output', 'json', '--only-show-errors') `
            -CaptureStdoutOnly |
                ConvertFrom-Json -Depth 20 -ErrorAction Stop
        $azureCliVersion = [string]$azureCliVersionMetadata.PSObject.Properties['azure-cli'].Value
    }
    catch {
        throw 'Azure CLI version metadata could not be verified.'
    }
    if ([string]::IsNullOrWhiteSpace($azureCliVersion)) {
        throw 'Azure CLI version metadata could not be verified.'
    }
    $gitVersion = (Invoke-BootstrapCommand `
        -FilePath 'git' `
        -ArgumentList @('--version') `
        -CaptureStdoutOnly).Trim()

    if ($RequirePurview) {
        if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
            if (-not $Install) { throw 'ExchangeOnlineManagement is required for Purview configuration.' }
            Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber -Repository PSGallery | Out-Null
        }
    }

    return [ordered]@{
        powerShell = $PSVersionTable.PSVersion.ToString()
        azureCli = $azureCliVersion
        dotnet = $dotnetVersion
        git = $gitVersion
        bicep = $bicepVersion
        agent365BlueprintProvider = 'MicrosoftGraphV1DirectNoCredential'
        exchangeOnlineManagementInstalled = [bool](Get-Module -ListAvailable -Name ExchangeOnlineManagement)
    }
}

Export-ModuleMember -Function *
