#Requires -Version 7.0

<#
.SYNOPSIS
    Submits a bounded Gateway data-plane canary without rendering the one-time key.

.DESCRIPTION
    Reads the Gateway key from the Windows clipboard, validates its public format,
    clears the clipboard immediately, and keeps the key only in process memory.
    Unless -NoWait is supplied for an already-Active registration, the script waits
    for an explicit newline before it sends one mismatched request, one matched
    activity, and one matched interaction. Output is limited to HTTP
    status codes and safe correlation identifiers; response bodies and credentials
    are never printed or persisted.

    Copy only the one-time Gateway API key field in the Admin UI immediately before
    starting this script. Use the returned process session to send a newline only
    after provisioning reports Active.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ApiBaseUrl,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$')]
    [string]$ExternalAgentId,

    [Parameter(Mandatory = $true)]
    [guid]$TenantUserObjectId,

    [switch]$NoWait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$baseUri = [uri]$ApiBaseUrl
if ($baseUri.Scheme -ne 'https' -or -not [string]::IsNullOrEmpty($baseUri.Query) -or
    -not [string]::IsNullOrEmpty($baseUri.Fragment)) {
    throw 'ApiBaseUrl must be a plain HTTPS origin or base path.'
}

$gatewayKey = $null
$client = $null
try {
    $gatewayKey = ([string](Get-Clipboard -Raw)).Trim()
    Set-Clipboard -Value ''

    if ($gatewayKey -notmatch '^a365gw_v1_[0-9a-f]{32}\.[A-Za-z0-9_-]{43}$') {
        $gatewayKey = $null
        throw 'The clipboard does not contain one valid Gateway v1 API key.'
    }

    Write-Host '[READY] Gateway key captured in process memory; clipboard cleared.' -ForegroundColor Green
    if (-not $NoWait) {
        Write-Host '[WAIT] Press Enter only after the operation reports Active.' -ForegroundColor Yellow
        $null = [Console]::ReadLine()
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.BaseAddress = $baseUri
    $client.Timeout = [timespan]::FromSeconds(30)
    $client.DefaultRequestHeaders.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $gatewayKey)

    function Send-CanaryRequest {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][hashtable]$Body,
            [Parameter(Mandatory = $true)][int]$ExpectedStatus,
            [Parameter(Mandatory = $true)][string]$Label
        )

        $request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Post,
            $Path)
        try {
            $request.Headers.TryAddWithoutValidation(
                'Idempotency-Key',
                [guid]::NewGuid().ToString('D')) | Out-Null
            $json = $Body | ConvertTo-Json -Depth 8 -Compress
            $request.Content = [System.Net.Http.StringContent]::new(
                $json,
                [System.Text.Encoding]::UTF8,
                'application/json')

            $response = $client.Send($request)
            try {
                $actualStatus = [int]$response.StatusCode
                if ($actualStatus -ne $ExpectedStatus) {
                    throw "$Label returned HTTP $actualStatus; expected $ExpectedStatus. The response body was deliberately not rendered."
                }

                $correlation = $null
                if ($response.Headers.TryGetValues('X-Correlation-ID', [ref]$correlation)) {
                    $safeCorrelation = @($correlation) | Select-Object -First 1
                    Write-Host "[PASS] $Label HTTP $actualStatus correlation $safeCorrelation" -ForegroundColor Green
                }
                else {
                    Write-Host "[PASS] $Label HTTP $actualStatus" -ForegroundColor Green
                }
            }
            finally {
                $response.Dispose()
            }
        }
        finally {
            $request.Dispose()
        }
    }

    $occurredAtUtc = [datetimeoffset]::UtcNow.ToString('O')
    $userObjectId = $TenantUserObjectId.ToString('D')
    $canarySuffix = [guid]::NewGuid().ToString('N')

    Send-CanaryRequest `
        -Path 'api/v1/agent-activities' `
        -ExpectedStatus 403 `
        -Label 'registration-bound identity rejection' `
        -Body @{
            externalAgentId = "agent-mismatch-$canarySuffix"
            activityId = "canary-mismatch-$canarySuffix"
            sessionId = "canary-session-$canarySuffix"
            activityType = 'Chat'
            occurredAtUtc = $occurredAtUtc
            actor = @{
                type = 'User'
                tenantUserObjectId = $userObjectId
            }
            tool = $null
            attributes = @{ canary = 'workflow-v3' }
        }

    Send-CanaryRequest `
        -Path 'api/v1/agent-activities' `
        -ExpectedStatus 202 `
        -Label 'matched activity ingestion' `
        -Body @{
            externalAgentId = $ExternalAgentId
            activityId = "canary-activity-$canarySuffix"
            sessionId = "canary-session-$canarySuffix"
            activityType = 'Chat'
            occurredAtUtc = $occurredAtUtc
            actor = @{
                type = 'User'
                tenantUserObjectId = $userObjectId
            }
            tool = $null
            attributes = @{ canary = 'workflow-v3' }
        }

    Send-CanaryRequest `
        -Path 'api/v1/ai-interactions' `
        -ExpectedStatus 202 `
        -Label 'matched interaction ingestion' `
        -Body @{
            externalAgentId = $ExternalAgentId
            interactionId = "canary-interaction-$canarySuffix"
            sessionId = "canary-session-$canarySuffix"
            occurredAtUtc = $occurredAtUtc
            userContext = @{ tenantUserObjectId = $userObjectId }
            prompt = @{
                contentType = 'text/plain'
                content = 'Workflow v3 bounded canary prompt.'
            }
            response = @{
                contentType = 'text/plain'
                content = 'Workflow v3 bounded canary response.'
            }
            model = $null
            metadata = @{ canary = 'workflow-v3' }
        }
}
finally {
    if ($null -ne $client) {
        $client.Dispose()
    }

    $gatewayKey = $null
    [System.GC]::Collect()
}
