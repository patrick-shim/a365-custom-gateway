#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../modules/Runtime.psm1" -Force -DisableNameChecking
& (Get-Module Runtime) {
    function script:Get-GatewayRuntimeComposeDirectory { $PSScriptRoot }
    $script:workerRunning = $true
    $script:consumers = 1
    function script:Invoke-BootstrapCommand {
        param($FilePath, $ArgumentList, [switch]$CaptureStdoutOnly)
        if ($ArgumentList -contains 'ps') {
            if ($script:workerRunning) { return 'worker-container' }
            return ''
        }
        return (@(@{name='gateway-provisioning-v3';consumers=$script:consumers}) | ConvertTo-Json -AsArray)
    }
    if (-not (Test-GatewayRuntimeWorkerHealth).workerRunning) { throw 'Healthy consumer rejected.' }
    foreach ($failure in @('Stopped', 'NoConsumer')) {
        $script:workerRunning = $failure -ne 'Stopped'
        $script:consumers = 0
        $rejected = $false
        try { Test-GatewayRuntimeWorkerHealth | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw "Worker health accepted $failure." }
    }
}
'Worker verification rejects stopped containers and missing queue consumers.'
