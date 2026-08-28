#Requires -Version 7.0

<#
.SYNOPSIS
    Blocks use of the retired shared-worker Agent 365 observability setup.

.DESCRIPTION
    Workflow v2 exports telemetry as each provisioned Agent Identity. The
    provisioning worker assigns Agent365.Observability.OtelWrite to the child
    Agent Identity and proves its two-stage token flow. Granting that role to the
    worker would recreate the incorrect shared-exporter model, so this retained
    compatibility entry point intentionally performs no Azure mutation.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment = 'dev',

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = 'rg-agent-gateway',

    [Parameter(Mandatory = $false)]
    [string]$WorkerAppName
)

$null = $Environment
$null = $ResourceGroup
$null = $WorkerAppName

Write-Error 'This command is retired. Workflow v2 assigns Agent365.Observability.OtelWrite to each child Agent Identity; do not grant it to the worker managed identity.'
exit 1
