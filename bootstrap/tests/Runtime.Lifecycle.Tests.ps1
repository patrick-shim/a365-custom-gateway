#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot/../modules/Lifecycle.psm1" -Force -DisableNameChecking
& (Get-Module Lifecycle) {
    function script:Save-BootstrapState {param($State,$Path) $script:saved=($State | ConvertTo-Json -Depth 20 -Compress)}
    function script:Write-GatewayExperienceEvent {param($Type,$Message,$Data,$OutputFormat) $script:events.Add($Type)}
    $script:events=[Collections.Generic.List[string]]::new()
    $state=@{steps=@{'Example'=@{status='Running';evidence=@{ownedId='previous-id'}}}}
    $context=@{state=$state;path='unused';format='Json';index=0;total=1}
    try {
        Invoke-GatewaySetupStep -Name Example -Context $context -Action {throw 'sensitive-provider-body'} -Evidence {param($r) $r}
        throw 'Failure was swallowed'
    } catch {if ($_.Exception.Message -ne 'sensitive-provider-body' -or $_.Exception.Data['BootstrapStep'] -ne 'Example') {throw}}
    if($state.steps.Example.status -ne 'Failed' -or $state.steps.Example.evidence.ownedId -ne 'previous-id' -or $script:saved -match 'sensitive-provider-body') {throw 'Failure did not preserve safe checkpoint evidence.'}
    $result=Invoke-GatewaySetupStep -Name Example -Context $context -Action {@{ownedId='same-id';secret='must-not-persist'}} -Evidence {param($r) @{ownedId=$r.ownedId}}
    if($state.steps.Example.status -ne 'Completed' -or $script:saved -match 'must-not-persist' -or $result.secret -ne 'must-not-persist') {throw 'Credential result leaked into state or was discarded.'}
    if(($script:events -join ',') -ne 'PhaseStarted,PhaseStarted,PhaseCompleted') {throw 'Step events did not reflect failure and retry.'}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('gateway-lease-'+[guid]::NewGuid().ToString('N'))
try {
    & (Get-Module Lifecycle) {param($Root) $script:testRoot=$Root; function script:Get-RepositoryRoot {$script:testRoot}} $root
    $first=Enter-GatewaySetupLock
    try {
        $rejected=$false
        try {$other=Enter-GatewaySetupLock; $other.Dispose()} catch {$rejected=$true}
        if(-not $rejected) {throw 'Concurrent installer was admitted.'}
    } finally {$first.Dispose()}
    $again=Enter-GatewaySetupLock
    $again.Dispose()
} finally {
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if(-not [IO.Path]::GetFullPath($root).StartsWith($parent+[IO.Path]::DirectorySeparatorChar) -or (Split-Path $root -Leaf) -notmatch '^gateway-lease-[a-f0-9]{32}$') {throw 'Unsafe test cleanup.'}
    if(Test-Path $root) {Remove-Item -LiteralPath $root -Recurse -Force}
}
'Step failure recovery, secret exclusion, progress and cross-interface lease checks passed.'
