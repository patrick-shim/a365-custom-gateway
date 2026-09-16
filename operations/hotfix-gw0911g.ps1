#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Plan','Apply','Verify')][string]$Mode,
    [ValidateSet('Build','Promote')][string]$Stage = 'Build',
    [ValidateSet('GuidScripts','ExecutorChildIsolation','ExecutorStartupDiagnostics','ConsoleFreePowerShell','ConnectionDiagnostics','ProviderStageDiagnostics','ProviderErrorDiagnostics','PrivateEomWorkspace','BoundedEomImports','LocationArrays','SettingsReadDiagnostics','ProviderReadbackMetadata','ProviderRuleRepresentation','KydProviderMode', IgnoreCase = $false)][string]$Generation = 'GuidScripts',
    [string]$ApprovalFingerprint = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Gw0911gArtifactHotfix.psm1') -ArgumentList $Generation -Force -DisableNameChecking
$root = Join-Path (Split-Path -Parent $PSScriptRoot) '.test-work\gw0911g-artifact-hotfix'
if ($Generation -ceq 'ExecutorChildIsolation') { $root = Join-Path $root 'executor-child-isolation' }
if ($Generation -ceq 'ExecutorStartupDiagnostics') { $root = Join-Path $root 'executor-startup-diagnostics' }
if ($Generation -ceq 'ConsoleFreePowerShell') { $root = Join-Path $root 'console-free-powershell' }
if ($Generation -ceq 'ConnectionDiagnostics') { $root = Join-Path $root 'connection-diagnostics' }
if ($Generation -ceq 'ProviderStageDiagnostics') { $root = Join-Path $root 'provider-stage-diagnostics' }
if ($Generation -ceq 'ProviderErrorDiagnostics') { $root = Join-Path $root 'provider-error-diagnostics' }
if ($Generation -ceq 'PrivateEomWorkspace') { $root = Join-Path $root 'private-eom-workspace' }
if ($Generation -ceq 'BoundedEomImports') { $root = Join-Path $root 'bounded-eom-imports' }
if ($Generation -ceq 'LocationArrays') { $root = Join-Path $root 'location-arrays' }
if ($Generation -ceq 'SettingsReadDiagnostics') { $root = Join-Path $root 'settings-read-diagnostics' }
if ($Generation -ceq 'ProviderReadbackMetadata') { $root = Join-Path $root 'provider-readback-metadata' }
if ($Generation -ceq 'ProviderRuleRepresentation') { $root = Join-Path $root 'provider-rule-representation' }
if ($Generation -ceq 'KydProviderMode') { $root = Join-Path $root 'kyd-provider-mode' }
[IO.Directory]::CreateDirectory($root) | Out-Null
$lock = [IO.File]::Open((Join-Path $root 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    switch ($Mode) {
        Prepare { Initialize-GwHotfixCandidate }
        Plan { New-GwHotfixPlan }
        Apply { Invoke-GwHotfixApply -Stage $Stage -ApprovalFingerprint $ApprovalFingerprint }
        Verify { Test-GwHotfixRelease }
    }
} finally { $lock.Dispose() }
