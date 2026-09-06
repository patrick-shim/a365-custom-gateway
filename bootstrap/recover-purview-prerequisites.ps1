#Requires -Version 7.0
<#
.SYNOPSIS
Plans or executes bounded recovery of failed Purview bootstrap prerequisites.
.DESCRIPTION
Requires preserved local configuration/state and exact target authority. Plan is
provider-read-only. Execute requires the reviewed fingerprint and Yes. Unknown
mutations are readback-only forever. This command never repeats the failed stage.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Execute')][string]$Mode,
    [string]$Config = (Join-Path $PSScriptRoot 'config.json'),
    [string]$ExpectedPlanFingerprint = '',
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$lock = $null
try {
    foreach ($module in @('Common', 'Experience', 'Azure', 'Entra', 'PurviewRecovery')) {
        Import-Module (Join-Path $PSScriptRoot "modules/$module.psm1") -Force -DisableNameChecking
    }
    $configuration = Read-BootstrapConfig -Path $Config
    $statePath = Get-BootstrapStatePath -Config $configuration
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'Original bootstrap state is required.' }
    $lock = Enter-BootstrapLock -StatePath $statePath
    $state = Read-BootstrapState -Path $statePath -Config $configuration
    $azureIdentity = Connect-BootstrapAzure -Config $configuration -NonInteractive
    $planPath = Join-Path (Get-RepositoryRoot) ".bootstrap/purview-prerequisite-recovery/$($state.deploymentOwnershipId)/plan.json"
    if ($state.Contains('purviewPrerequisiteRecoveryPlan')) {
        $recovery = $state.purviewPrerequisiteRecoveryPlan
    }
    elseif (Test-Path -LiteralPath $planPath -PathType Leaf) {
        $parameters = @{ AsHashtable = $true; Depth = 100 }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $parameters.DateKind = 'String' }
        $recovery = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json @parameters
        Convert-BootstrapParsedJsonDatesToStrings -Value $recovery
    }
    elseif ($Mode -ceq 'Plan') {
        $recovery = New-BootstrapPurviewRecoveryPlan -State $state -Config $configuration -AzureIdentity $azureIdentity
        [IO.Directory]::CreateDirectory((Split-Path -Parent $planPath)) | Out-Null
        $stream = [IO.File]::Open($planPath, 'CreateNew', 'Write', 'None')
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $recovery -Depth 100))
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
    }
    else { throw 'Run Plan before Execute.' }

    $completed = $recovery.Contains('status') -and [string]$recovery.status -ceq 'Completed'
    $snapshot = Assert-BootstrapPurviewRecoveryPlan -State $state -Recovery $recovery -Completed:$completed
    $null = Get-BootstrapPurviewRecoveryProviderState -Config $configuration -State $state -AzureIdentity $azureIdentity -Binding $recovery.plan.binding
    if ($Mode -ceq 'Plan') {
        [ordered]@{ status = if ($completed) { 'Completed' } else { 'ReviewedReadOnly' }
            planFingerprint = [string]$recovery.planFingerprint
            correctedSourceFingerprint = [string]$recovery.plan.correctedSourceFingerprint
            operations = @('ExchangeGrant', 'ComplianceGrant', 'Certificate')
            planPath = $planPath } | ConvertTo-Json -Depth 5
    }
    elseif ($completed) {
        if (-not $Yes -or $ExpectedPlanFingerprint -cne [string]$recovery.planFingerprint) { throw 'Exact confirmation is required.' }
        $provider = Get-BootstrapPurviewRecoveryProviderState -Config $configuration -State $state -AzureIdentity $azureIdentity -Binding $recovery.plan.binding
        if ((Get-BootstrapObjectFingerprint -InputObject $provider.automationEvidence) -cne [string]$recovery.automationEvidenceFingerprint) {
            throw 'Completed recovery provider evidence changed.'
        }
        [ordered]@{ status = 'Completed'; planFingerprint = [string]$recovery.planFingerprint; readbackOnly = $true } | ConvertTo-Json
    }
    else {
        Set-BootstrapExecutionSourceRoot -Path $snapshot
        Invoke-BootstrapPurviewRecovery -State $state -StatePath $statePath -Config $configuration -AzureIdentity $azureIdentity `
            -Recovery $recovery -ExpectedPlanFingerprint $ExpectedPlanFingerprint -Yes:$Yes | ConvertTo-Json -Depth 5
    }
}
catch {
    # Provider exceptions and CLI bodies are deliberately not rendered or persisted.
    [Console]::Error.WriteLine('Purview prerequisite recovery stopped. Preserve the original state and recovery plan; inspect the bounded validation gate before any further action.')
    exit 1
}
finally { if ($null -ne $lock) { $lock.Dispose() } }
