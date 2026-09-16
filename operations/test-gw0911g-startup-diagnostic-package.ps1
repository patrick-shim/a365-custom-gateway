#Requires -Version 7.0
# Local validation only: load the final published assemblies, force the original
# empty result at its test seam, and execute the one real attested diagnostic child.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'Gw0911gArtifactHotfix.psm1') -ArgumentList ExecutorStartupDiagnostics -Force -DisableNameChecking
$candidate = & (Get-Module Gw0911gArtifactHotfix) { Get-GwHotfixCandidate }
$root = Join-Path $candidate.directory '.bootstrap\hotfix-package\publish'
$flags = [Reflection.BindingFlags]'Public,NonPublic,Static'
foreach ($name in @('Gateway.Contracts.dll','Gateway.Domain.dll','Gateway.Purview.dll','Gateway.Purview.Executor.dll')) {
    $null = [Reflection.Assembly]::LoadFrom((Join-Path $root $name))
}
$executor = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -ceq 'Gateway.Purview.Executor' }
$purview = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -ceq 'Gateway.Purview' }
foreach ($assembly in @($executor,$purview)) {
    if (-not $assembly.Location.Equals((Join-Path $root ($assembly.GetName().Name + '.dll')), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Final package validation loaded an assembly from outside the published package.'
    }
}
$attestation = $executor.GetType('Gateway.Purview.Executor.ExecutorRuntimeAttestation', $true)
$diagnostics = $executor.GetType('Gateway.Purview.Executor.ExecutorStartupDiagnostics', $true)
$captureType = $purview.GetType('Gateway.Purview.PowerShellPurviewPolicyProvisioningClient+BoundedTextCapture', $true)
$none = [Threading.CancellationToken]::None
$verify = $attestation.GetMethod('VerifyFilesAsync', $flags)
$hash = $verify.Invoke($null, [object[]]@([string]$root, [string]$candidate.package.receipt.runtimeManifestDigest, [string]$candidate.sourceFingerprint, $none)).GetAwaiter().GetResult()
if ($hash -cne $candidate.diagnosticHookSha256) { throw 'The complete final manifest did not attest the exact hook.' }

$original = [Diagnostics.ProcessStartInfo]::new((Join-Path $root 'PowerShell\pwsh.exe'))
$original.UseShellExecute = $false; $original.CreateNoWindow = $true
$original.RedirectStandardOutput = $true; $original.RedirectStandardError = $true; $original.WorkingDirectory = $root
$command = '$ErrorActionPreference=''Stop''; $m=@(Get-Module -ListAvailable ExchangeOnlineManagement); if($m.Count -ne 1){exit 2}; Import-Module -FullyQualifiedName @{ModuleName=''ExchangeOnlineManagement'';RequiredVersion=''3.10.1''} -ErrorAction Stop; $c=Get-Command Connect-IPPSSession -Module ExchangeOnlineManagement -ErrorAction Stop; if($null -eq $c){exit 3}; [Console]::Write(($PSVersionTable.PSVersion.ToString()+''|''+$m[0].Version.ToString()))'
foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-Command',$command)) { $original.ArgumentList.Add($arg) }
$purview.GetType('Gateway.Purview.PurviewPowerShellProcess', $true).GetMethod('ApplyVerifiedPackageIsolation', $flags).Invoke($null, [object[]]@($original,[string]$root))
$original.Environment['DOTNET_EnableDiagnostics'] = '0'
$original.Environment['DOTNET_STARTUP_HOOKS'] = 'UNAPPROVED-AMBIENT-CANARY;SECOND-CANARY'
$prepared = $diagnostics.GetMethod('CreateStartInfoAsync', $flags).Invoke($null, [object[]]@([string]$root,[string]$hash,$original,$none)).GetAwaiter().GetResult()
if ($prepared.Environment['DOTNET_STARTUP_HOOKS'] -cne (Join-Path $root 'Gateway.Purview.Executor.StartupDiagnostics.dll') -or
    $original.Environment['DOTNET_STARTUP_HOOKS'] -cne 'UNAPPROVED-AMBIENT-CANARY;SECOND-CANARY' -or
    $prepared.Environment['DOTNET_EnableDiagnostics'] -cne '0') { throw 'Diagnostic hook inheritance was not replaced exactly.' }

# Compile a typed expression delegate to the final assembly's internal async
# method. No replacement production DLL, hook, command callback or provider call.
$counter = [Runtime.CompilerServices.StrongBox[int]]::new(0)
$ct = [Linq.Expressions.Expression]::Parameter([Threading.CancellationToken], 'ct')
$run = $diagnostics.GetMethod('RunAsync', $flags)
$call = [Linq.Expressions.Expression]::Call($run, [Linq.Expressions.Expression[]]@(
    [Linq.Expressions.Expression]::Constant($root),
    [Linq.Expressions.Expression]::Constant($hash),
    [Linq.Expressions.Expression]::Constant($original),
    $ct,
    [Linq.Expressions.Expression]::Constant($null, [Nullable[TimeSpan]])
))
$increment = [Linq.Expressions.Expression]::PostIncrementAssign(
    [Linq.Expressions.Expression]::Field([Linq.Expressions.Expression]::Constant($counter), 'Value'))
$body = [Linq.Expressions.Expression]::Block([Linq.Expressions.Expression[]]@($increment,$call))
$callback = [Linq.Expressions.Expression]::Lambda($body, [Linq.Expressions.ParameterExpression[]]@($ct)).Compile()
$empty = [Activator]::CreateInstance($captureType, [object[]]@('',[long]0,$false))
$valid = [Activator]::CreateInstance($captureType, [object[]]@('7.6.5|3.10.1',[long]12,$false))
$validate = $attestation.GetMethod('ValidateProbeResultAsync', $flags)
$validate.Invoke($null, @([int]0,$valid,$empty,$callback,$none)).GetAwaiter().GetResult()
if ($counter.Value -ne 0) { throw 'Normal success unexpectedly invoked diagnostics.' }
$failure = $null
try { $validate.Invoke($null, @([int]0,$empty,$empty,$callback,$none)).GetAwaiter().GetResult() }
catch {
    $errorObject = $_.Exception
    while ($errorObject) {
        if ($errorObject -is [InvalidOperationException] -and $errorObject.Message.StartsWith('Purview executor PowerShell probe failed:', [StringComparison]::Ordinal)) {
            $failure = $errorObject; break
        }
        $errorObject = $errorObject.InnerException
    }
}
if ($null -eq $failure -or $counter.Value -ne 1 -or $null -ne $failure.InnerException -or
    -not $failure.Message.Contains('exit=0; stdoutCharacters=0; stderrCharacters=0;') -or
    -not $failure.Message.Contains('versionMatch=False.') -or
    -not $failure.Message.Contains('GWDIAG|ENTRY|None|0') -or
    -not $failure.Message.Contains('GWDIAG|COMMAND_COMPLETE|None|0') -or
    $failure.Message.Contains('7.6.5|3.10.1') -or $failure.Message.Contains('CANARY') -or $failure.Message.Contains($root)) {
    throw 'Final diagnostic repeat did not preserve the original failure and safe markers.'
}
$markers = $failure.Message.Split('Startup diagnostic: ')[-1].Split(';')
foreach ($marker in $markers) {
    if ($marker -cnotmatch '^GWDIAG\|(ENTRY|CONOUT_OK|CONOUT_FAILED|RAW_UI|BREAK_HANDLER|HOST_START|HOST_OTHER|COMMAND_ENTRY|COMMAND_COMPLETE)\|(None|Win32Exception|HostException)\|-?(0|[1-9][0-9]*)$') {
        throw 'Unexpected diagnostic output was suppressed.'
    }
}
$proof = @{ packageDigest = $candidate.package.receipt.packageDigest; sourceFingerprint = $candidate.sourceFingerprint
    runtimeManifestDigest = $candidate.package.receipt.runtimeManifestDigest; hookSha256 = $hash
    executorAssemblySha256 = (Get-FileHash $executor.Location -Algorithm SHA256).Hash.ToLowerInvariant()
    validationScriptSha256 = (Get-FileHash $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    diagnosticRepeats = $counter.Value; originalFailurePreserved = $true; ambientHookReplaced = $true
    normalSuccessDiagnosticRepeats = 0; safeMarkers = $markers; scope = 'Final published bytes; forced local result only; no cloud readiness or provider permission.' }
& (Get-Module Gw0911gArtifactHotfix) { param($p) Save-GwHotfixJson 'local-diagnostic-failure-verified.json' $p } $proof
$proof | ConvertTo-Json -Depth 4
