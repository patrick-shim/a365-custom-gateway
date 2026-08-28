Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Agent365BlueprintByName {
    param([Parameter(Mandatory)][string]$DisplayName)
    $response = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', 'https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint?$select=id,appId,displayName,managerApplications&$top=999')
    $matches = @($response.value | Where-Object { [string]$_.displayName -eq $DisplayName })
    if ($matches.Count -gt 1) { throw "More than one typed Agent ID blueprint is named '$DisplayName'." }
    return if ($matches.Count -eq 1) { $matches[0] } else { $null }
}

function Ensure-Agent365SeedBlueprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [switch]$NonInteractive)
    $baseName = [string]$Config.agent365.seedBlueprintName
    if ([string]::IsNullOrWhiteSpace($baseName)) { throw 'agent365.seedBlueprintName is required.' }
    $displayName = "$baseName Blueprint"
    $blueprint = Get-Agent365BlueprintByName -DisplayName $displayName
    if (-not $blueprint) {
        if ($NonInteractive) {
            throw "Typed Agent ID blueprint '$displayName' does not exist. Create it during an interactive Apply, then Resume non-interactively."
        }
        $root = Get-RepositoryRoot
        $workRoot = [IO.Path]::GetFullPath((Join-Path $root '.bootstrap/work'))
        $work = [IO.Path]::GetFullPath((Join-Path $workRoot ([guid]::NewGuid().ToString('N'))))
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        try {
            Push-Location $work
            try {
                Invoke-BootstrapCommand -FilePath 'a365' -ArgumentList @('setup', 'requirements') -NoCapture | Out-Null
                Invoke-BootstrapCommand -FilePath 'a365' -ArgumentList @('setup', 'blueprint', '--agent-name', $baseName, '--tenant-id', [string]$Config.tenantId, '--no-endpoint') -NoCapture | Out-Null
            }
            finally { Pop-Location }
        }
        finally {
            $resolvedWork = [IO.Path]::GetFullPath($work)
            if (-not $resolvedWork.StartsWith($workRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Refusing to remove an Agent 365 CLI work directory outside .bootstrap/work.'
            }
            if (Test-Path -LiteralPath $resolvedWork) { Remove-Item -LiteralPath $resolvedWork -Recurse -Force }
        }
        for ($attempt = 1; $attempt -le 18 -and -not $blueprint; $attempt++) {
            Start-Sleep -Seconds 5
            $blueprint = Get-Agent365BlueprintByName -DisplayName $displayName
        }
    }
    if (-not $blueprint) { throw "Agent 365 CLI completed but typed blueprint '$displayName' was not observable through Microsoft Graph." }
    Assert-GuidValue -Value ([string]$blueprint.id) -Label 'Blueprint object ID'
    Assert-GuidValue -Value ([string]$blueprint.appId) -Label 'Blueprint application ID'
    $managers = @($blueprint.managerApplications | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($managers.Count -eq 0) { throw 'The seed blueprint has no managerApplications; provisioning must remain closed.' }
    foreach ($manager in $managers) { Assert-GuidValue -Value $manager -Label 'managerApplications entry' }
    return [ordered]@{
        objectId = [string]$blueprint.id
        applicationId = [string]$blueprint.appId
        displayName = [string]$blueprint.displayName
        managerApplicationIds = $managers
    }
}

Export-ModuleMember -Function *
