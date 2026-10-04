#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$GatewayKeyPath,
    [Parameter(Mandatory)][string]$ExternalAgentId,
    [Parameter(Mandatory)][guid]$TenantUserObjectId,
    [Parameter(Mandatory)][string]$EvidencePath,
    [uri]$GatewayUrl = 'http://127.0.0.1:5080/'
)
$ErrorActionPreference = 'Stop'
if ($GatewayUrl.Scheme -ne 'https' -and -not ($GatewayUrl.Scheme -eq 'http' -and $GatewayUrl.IsLoopback)) { throw 'Use HTTPS outside loopback development.' }
if (Test-Path -LiteralPath $EvidencePath) { throw 'Choose a new evidence path; earlier evidence is not overwritten.' }
$key = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $GatewayKeyPath)).Trim()
$results = [ordered]@{ checkedAtUtc=[DateTimeOffset]::UtcNow.ToString('O'); externalAgentId=$ExternalAgentId; tests=@(); modelCalled=$false }
try {
    foreach ($sample in @(
        @{name='normal';text='Suggest three ways to organize a project meeting.'},
        @{name='synthetic-sensitive';text='Test credit card number: 4532 6677 8521 3500. This is synthetic data for DLP validation.'}
    )) {
        $body = @{ externalAgentId=$ExternalAgentId; interactionId="dlp-verification-$([guid]::NewGuid())";
            occurredAtUtc=[DateTimeOffset]::UtcNow.ToString('O'); userContext=@{tenantUserObjectId=$TenantUserObjectId.ToString()};
            prompt=@{contentType='text/plain';content=$sample.text} }
        $idempotency = [guid]::NewGuid().ToString()
        $response = Invoke-WebRequest -Uri ([uri]::new($GatewayUrl,'api/v1/prompts:evaluate')) -Method Post -MaximumRedirection 0 -TimeoutSec 120 `
            -Headers @{Authorization="Bearer $key";'Idempotency-Key'=$idempotency} -ContentType 'application/json' `
            -Body ($body | ConvertTo-Json -Depth 8 -Compress) -SkipHttpErrorCheck
        $responseText = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
        $decision = $responseText | ConvertFrom-Json
        $results.tests += @{ sample=$sample.name; httpStatus=[int]$response.StatusCode; interactionId=$body.interactionId; decision=$decision }
        $results | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
        "$($sample.name): HTTP $([int]$response.StatusCode), decision=$($decision.decision), code=$($decision.errorCode), Purview=$($decision.purviewProcessing)"
    }
    $results.normalAllowed = $results.tests[0].httpStatus -eq 200 -and $results.tests[0].decision.allowed -eq $true -and
        $results.tests[0].decision.purviewProcessing -eq 'Allowed' -and $null -ne $results.tests[0].decision.evaluationReceiptId
    $results.sensitiveBlocked = $results.tests[1].httpStatus -eq 403 -and $results.tests[1].decision.purviewProcessing -eq 'Blocked' -and
        $results.tests[1].decision.errorCode -eq 'PROMPT_BLOCKED_BY_DLP' -and $null -eq $results.tests[1].decision.evaluationReceiptId
    $results | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
} finally { $key=$null }
if (-not $results.normalAllowed -or -not $results.sensitiveBlocked) {
    throw 'Gateway DLP verification failed. Review the saved evidence; an unavailable or unrelated rejection is not a DLP block.'
}
