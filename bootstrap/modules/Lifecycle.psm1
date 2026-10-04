Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Enter-GatewaySetupLock {
    $directory = Join-Path (Get-RepositoryRoot) '.bootstrap'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    try {
        # The operating system releases this lease even after a crash. The file
        # may remain; its existence is never treated as an active installer.
        return [IO.File]::Open((Join-Path $directory 'installer.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw 'Another installer is using this checkout. Wait for it to finish before starting terminal or graphical setup.'
    }
}

function Invoke-GatewaySetupStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Context,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][scriptblock]$Evidence
    )
    $state = $Context.state
    $priorEvidence = if ($state.steps.Contains($Name)) { $state.steps[$Name].evidence } else { @{} }
    $Context.index++
    $state.steps[$Name] = [ordered]@{
        status = 'Running'; startedAtUtc = [DateTimeOffset]::UtcNow.ToString('O'); evidence = $priorEvidence
    }
    Save-BootstrapState -State $state -Path $Context.path
    Write-GatewayExperienceEvent -Type PhaseStarted -Message $Name -Data @{
        step=$Name; index=$Context.index; total=$Context.total
    } -OutputFormat $Context.format
    try {
        $result = & $Action
        $safeEvidence = & $Evidence $result
        $state.steps[$Name] = [ordered]@{
            status='Completed'; completedAtUtc=[DateTimeOffset]::UtcNow.ToString('O'); evidence=$safeEvidence
        }
        Save-BootstrapState -State $state -Path $Context.path
        Write-GatewayExperienceEvent -Type PhaseCompleted -Message "$Name completed." -Data @{
            step=$Name; index=$Context.index; total=$Context.total
        } -OutputFormat $Context.format
        return $result
    } catch {
        $failure = $_
        $state.steps[$Name].status = 'Failed'
        $state.steps[$Name]['failedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
        $state.steps[$Name]['failureType'] = $failure.Exception.GetType().Name
        # Never store arbitrary exception/provider text or action return values.
        try { Save-BootstrapState -State $state -Path $Context.path } catch { }
        $failure.Exception.Data['BootstrapStep'] = $Name
        throw $failure
    }
}

Export-ModuleMember -Function Enter-GatewaySetupLock,Invoke-GatewaySetupStep
