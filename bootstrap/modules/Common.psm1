Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-BootstrapStep {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-BootstrapSuccess {
    param([string]$Message)
    Write-Host "[ok] $Message" -ForegroundColor Green
}

function Invoke-BootstrapCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [switch]$AllowFailure,
        [switch]$NoCapture
    )

    $resolvedFile = $FilePath
    $effectiveArguments = @($ArgumentList)
    if ($IsWindows -and $FilePath -eq 'az') {
        $azCommand = Get-Command az -ErrorAction Stop
        if ($azCommand.Source.EndsWith('.cmd', [StringComparison]::OrdinalIgnoreCase)) {
            $azPython = [IO.Path]::GetFullPath((Join-Path (Split-Path $azCommand.Source -Parent) '..\python.exe'))
            if (Test-Path -LiteralPath $azPython) {
                $resolvedFile = $azPython
                $effectiveArguments = @('-IBm', 'azure.cli') + $effectiveArguments
            }
        }
    }

    if ($NoCapture) {
        & $resolvedFile @effectiveArguments
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and -not $AllowFailure) {
            throw "Command '$FilePath' failed with exit code $exitCode."
        }
        return $exitCode
    }

    $output = & $resolvedFile @effectiveArguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $safeOutput = ($output | Out-String).Trim()
        throw "Command '$FilePath' failed with exit code $exitCode. $safeOutput"
    }
    return ($output | Out-String).Trim()
}

function Invoke-AzJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    $raw = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList ($Arguments + @('--output', 'json', '--only-show-errors'))
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json -Depth 100
}

function Invoke-AzTsv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    return (Invoke-BootstrapCommand -FilePath 'az' -ArgumentList ($Arguments + @('--output', 'tsv', '--only-show-errors'))).Trim()
}

function Assert-GuidValue {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Label)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Label must be a non-empty GUID."
    }
}

function Get-RepositoryRoot {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (-not (Test-Path (Join-Path $root 'src/A365Gateway.slnx'))) {
        throw 'Bootstrap must run from a complete A365 Custom Gateway repository checkout.'
    }
    return $root
}

function Read-BootstrapConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $config = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -Depth 30
    foreach ($entry in ([ordered]@{
        policyProvisioningEnabled = $false
        policyProvisioningOrganization = ''
        policyProvisioningApplicationId = ''
        policyProvisioningCertificateSecretUri = ''
    }).GetEnumerator()) {
        if ($config.purview.PSObject.Properties.Name -notcontains $entry.Key) {
            $config.purview | Add-Member -MemberType NoteProperty -Name $entry.Key -Value $entry.Value
        }
    }
    foreach ($name in @('subscriptionId', 'tenantId', 'environment', 'location', 'projectName', 'resourceGroupName', 'alertEmail')) {
        if ([string]::IsNullOrWhiteSpace([string]$config.$name)) { throw "Config property '$name' is required." }
    }
    Assert-GuidValue -Value ([string]$config.subscriptionId) -Label 'subscriptionId'
    Assert-GuidValue -Value ([string]$config.tenantId) -Label 'tenantId'
    if ([string]$config.environment -notin @('dev', 'staging', 'prod')) { throw 'environment must be dev, staging, or prod.' }
    if ([string]$config.projectName -notmatch '^[a-z][a-z0-9]{1,7}$') { throw 'projectName must be 2-8 lowercase alphanumeric characters starting with a letter so every generated Key Vault name remains valid.' }
    if ([string]$config.resourceGroupName -notmatch '^[A-Za-z0-9._()\-]{1,90}$') { throw 'resourceGroupName is invalid.' }
    if ([string]$config.location -notmatch '^[a-z0-9]+$') { throw 'location must be an Azure region name such as koreacentral.' }
    if ([string]$config.alertEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'alertEmail must be a valid email address.' }
    if ([string]$config.sql.skuName -notin @('Basic', 'S0', 'S1', 'S2', 'S3', 'P1', 'P2', 'GP_S_Gen5_1', 'GP_S_Gen5_2')) { throw 'sql.skuName is unsupported by the deployment template.' }
    if ([string]$config.sql.skuTier -notin @('Basic', 'Standard', 'Premium', 'GeneralPurpose')) { throw 'sql.skuTier is unsupported by the deployment template.' }
    if ([string]::IsNullOrWhiteSpace([string]$config.agent365.seedBlueprintName) -or ([string]$config.agent365.seedBlueprintName).Length -gt 100) { throw 'agent365.seedBlueprintName must contain 1-100 characters.' }
    if ($config.environment -ne 'dev' -and $config.agent365.allowDevelopmentRegistryPreview -eq $true) {
        throw 'Agent Registration beta preview can be enabled only for the dev environment.'
    }
    if ($config.purview.enabled -eq $true -and [string]::IsNullOrWhiteSpace([string]$config.purview.sensitiveInformationType)) {
        throw 'purview.sensitiveInformationType is required when Purview is enabled; the bootstrap never invents a tenant DLP classifier.'
    }
    if ($config.purview.enabled -eq $true) {
        foreach ($name in @('collectionPolicyName', 'dlpPolicyName', 'dlpRuleName')) {
            if ([string]::IsNullOrWhiteSpace([string]$config.purview.$name)) { throw "purview.$name is required when Purview is enabled." }
        }
    }
    if ($config.purview.activateGatewayAdapterAfterPolicyReadback -eq $true -and $config.purview.enabled -ne $true) {
        throw 'Purview adapter activation requires purview.enabled=true.'
    }
    if ($config.purview.policyProvisioningEnabled -eq $true) {
        if ($config.purview.enabled -ne $true) {
            throw 'Purview policy-profile automation requires purview.enabled=true.'
        }
        if ([string]$config.purview.policyProvisioningOrganization -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$') {
            throw 'purview.policyProvisioningOrganization must be the verified Microsoft 365 organization domain.'
        }
        Assert-GuidValue -Value ([string]$config.purview.policyProvisioningApplicationId) -Label 'purview.policyProvisioningApplicationId'
        $certificateSecretUri = $null
        if (-not [Uri]::TryCreate([string]$config.purview.policyProvisioningCertificateSecretUri, [UriKind]::Absolute, [ref]$certificateSecretUri) -or
            $certificateSecretUri.Scheme -ne 'https' -or
            -not $certificateSecretUri.IsDefaultPort -or
            $certificateSecretUri.Host -notlike '*.vault.azure.net' -or
            $certificateSecretUri.AbsolutePath -notmatch '^/secrets/[^/]+/?$' -or
            -not [string]::IsNullOrEmpty($certificateSecretUri.Query) -or
            -not [string]::IsNullOrEmpty($certificateSecretUri.Fragment)) {
            throw 'purview.policyProvisioningCertificateSecretUri must be a versionless HTTPS Azure Key Vault secret URI.'
        }
    }
    return $config
}

function Get-BootstrapStatePath {
    param([Parameter(Mandatory)]$Config)
    $root = Get-RepositoryRoot
    return Join-Path $root ".bootstrap/state/$($Config.subscriptionId)-$($Config.resourceGroupName)-$($Config.environment).json"
}

function New-BootstrapState {
    param([Parameter(Mandatory)]$Config)
    return [ordered]@{
        schemaVersion = 1
        deploymentKey = "$($Config.subscriptionId)/$($Config.resourceGroupName)/$($Config.environment)"
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        configuration = [ordered]@{
            subscriptionId = [string]$Config.subscriptionId
            tenantId = [string]$Config.tenantId
            environment = [string]$Config.environment
            location = [string]$Config.location
            projectName = [string]$Config.projectName
            resourceGroupName = [string]$Config.resourceGroupName
        }
        steps = [ordered]@{}
        outputs = [ordered]@{}
    }
}

function Read-BootstrapState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Config)
    if (-not (Test-Path -LiteralPath $Path)) { return New-BootstrapState -Config $Config }
    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100 -AsHashtable
    $expected = "$($Config.subscriptionId)/$($Config.resourceGroupName)/$($Config.environment)"
    if ([string]$state.deploymentKey -ne $expected) { throw "State belongs to '$($state.deploymentKey)', not '$expected'." }
    return $state
}

function Save-BootstrapState {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State, [Parameter(Mandatory)][string]$Path)
    $State.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = "$Path.tmp"
    $State | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Invoke-BootstrapStateStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter()][scriptblock]$Validate,
        [switch]$AlwaysRun
    )
    Write-BootstrapStep $Name
    $existing = $State.steps[$Name]
    if (-not $AlwaysRun -and $existing -and $existing.status -eq 'Completed') {
        if (-not $Validate -or (& $Validate)) {
            Write-BootstrapSuccess "$Name already complete$(if ($Validate) { ' and revalidated' } else { '' })"
            return $existing.evidence
        }
        Write-Warning "$Name state was stale; running it again."
    }

    $State.steps[$Name] = [ordered]@{ status = 'Running'; startedAtUtc = [DateTimeOffset]::UtcNow.ToString('O') }
    Save-BootstrapState -State $State -Path $StatePath
    try {
        $evidence = & $Action
        $State.steps[$Name] = [ordered]@{
            status = 'Completed'
            startedAtUtc = $State.steps[$Name].startedAtUtc
            completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            evidence = $evidence
        }
        Save-BootstrapState -State $State -Path $StatePath
        Write-BootstrapSuccess $Name
        return $evidence
    }
    catch {
        $State.steps[$Name] = [ordered]@{
            status = 'Failed'
            startedAtUtc = $State.steps[$Name].startedAtUtc
            failedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            message = "Bootstrap step '$Name' failed. Review the local terminal output, correct the cause, and run Resume."
        }
        Save-BootstrapState -State $State -Path $StatePath
        throw
    }
}

function Enter-BootstrapLock {
    param([Parameter(Mandatory)][string]$StatePath)
    $lockPath = "$StatePath.lock"
    New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force | Out-Null
    try {
        $stream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        $bytes = [Text.Encoding]::UTF8.GetBytes("$PID $([DateTimeOffset]::UtcNow.ToString('O'))")
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        return $stream
    }
    catch {
        throw "Another bootstrap process holds '$lockPath'. Wait for it to finish or terminate that process cleanly."
    }
}

Export-ModuleMember -Function *
