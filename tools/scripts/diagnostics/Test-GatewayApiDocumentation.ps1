#Requires -Version 7.0
[CmdletBinding()]
param([uri]$BaseUri = 'http://127.0.0.1:5080')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$document = Invoke-RestMethod ([uri]::new($BaseUri, '/openapi/v1.json'))
$failures = [Collections.Generic.List[string]]::new()
$ids = [Collections.Generic.HashSet[string]]::new()
$count = 0
foreach ($path in $document.paths.PSObject.Properties) {
    foreach ($method in $path.Value.PSObject.Properties | Where-Object Name -In @('get','post','patch','put','delete')) {
        $operation = $method.Value
        $count++
        if (-not $operation.PSObject.Properties['summary'] -or [string]::IsNullOrWhiteSpace($operation.summary)) { $failures.Add("Missing summary: $($method.Name) $($path.Name)") }
        if (-not $operation.PSObject.Properties['operationId'] -or -not $ids.Add($operation.operationId)) { $failures.Add("Missing/duplicate operation ID: $($path.Name)") }
        if ($path.Name.StartsWith('/api/')) {
            if (-not $operation.PSObject.Properties['security'] -or $operation.security.Count -eq 0) { $failures.Add("Missing authentication contract: $($path.Name)") }
        }
        if ($path.Name -in @('/api/v1/prompts:evaluate','/api/v1/ai-interactions','/api/v1/agent-activities','/api/v1/agent-activities:batch') -and $method.Name -eq 'post') {
            $header = @($operation.parameters | Where-Object { $_.name -eq 'Idempotency-Key' -and $_.in -eq 'header' })
            if ($header.Count -ne 1 -or -not $header[0].required) { $failures.Add("Missing required idempotency header: $($path.Name)") }
            if (-not $operation.security[0].PSObject.Properties['AgentKey']) { $failures.Add("Wrong agent authentication: $($path.Name)") }
        }
    }
}
foreach ($scheme in @('AgentKey','EntraBearer')) {
    if (-not $document.components.securitySchemes.PSObject.Properties[$scheme]) { $failures.Add("Missing security scheme: $scheme") }
}
foreach ($schema in @('PurviewPolicyCatalogResponse','AgentPolicyAssignmentsResponse','PolicyAssignmentReviewResponse','PolicyAssignmentConfirmationResponse','PromptEvaluationResultDto','SubmitInteractionRequest')) {
    if (-not $document.components.schemas.PSObject.Properties[$schema]) { $failures.Add("Missing response/request schema: $schema") }
}
$reference = Invoke-WebRequest ([uri]::new($BaseUri, '/docs'))
if ($reference.Content -notmatch 'Scalar|scalar') { $failures.Add('Interactive API reference is not served.') }
$yaml = Invoke-WebRequest ([uri]::new($BaseUri, '/openapi/v1.yaml'))
if ($yaml.Content -notmatch 'openapi:') { $failures.Add('YAML schema is not served.') }
if ($count -lt 29) { $failures.Add("Unexpectedly incomplete API: $count operations") }
if ($failures.Count) { throw ($failures -join [Environment]::NewLine) }
"API documentation verified: $count operations, authentication, critical DTOs, ingress headers, interactive reference and YAML."
