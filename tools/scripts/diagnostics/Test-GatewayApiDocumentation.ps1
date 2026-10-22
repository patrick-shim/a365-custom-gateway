#Requires -Version 7.0
[CmdletBinding()]
param([uri]$BaseUri = 'http://127.0.0.1:5080')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$document = Invoke-RestMethod ([uri]::new($BaseUri, '/openapi/v1.json'))
$failures = [Collections.Generic.List[string]]::new()
$ids = [Collections.Generic.HashSet[string]]::new()
$count = 0

function Get-ApiOperation {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Method
    )

    $pathProperty = $document.paths.PSObject.Properties[$Path]
    if (-not $pathProperty) {
        $failures.Add("Missing path: $Path")
        return $null
    }
    $methodProperty = $pathProperty.Value.PSObject.Properties[$Method]
    if (-not $methodProperty) {
        $failures.Add("Missing method: $($Method.ToUpperInvariant()) $Path")
        return $null
    }
    return $methodProperty.Value
}

function Assert-RequiredHeader {
    param(
        [Parameter(Mandatory)]$Operation,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $header = @($Operation.parameters | Where-Object { $_.name -eq $Name -and $_.in -eq 'header' })
    if ($header.Count -ne 1 -or -not $header[0].required) {
        $failures.Add("Missing required $Name header: $Path")
    }
}

function Get-JsonSchemaReference {
    param($Content)

    if (-not $Content) { return $null }
    $json = $Content.PSObject.Properties['application/json']
    if (-not $json -or -not $json.Value.schema) { return $null }
    return $json.Value.schema.PSObject.Properties['$ref'].Value
}

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

foreach ($schema in @(
    'ConnectPurviewRequest',
    'RefreshPurviewCatalogRequest',
    'PurviewConnectionResponse',
    'PurviewConnectorOperationAcceptedResponse',
    'OperationStatusDto'
)) {
    if (-not $document.components.schemas.PSObject.Properties[$schema]) {
        $failures.Add("Missing Purview connector schema: $schema")
    }
}

$connectionPath = '/api/v1/protection/purview/connection'
$refreshPath = '/api/v1/protection/purview/connection/refresh'
$connectionGet = Get-ApiOperation -Path $connectionPath -Method 'get'
$connectionPost = Get-ApiOperation -Path $connectionPath -Method 'post'
$refreshPost = Get-ApiOperation -Path $refreshPath -Method 'post'

if ($connectionGet) {
    if (-not $connectionGet.security[0].PSObject.Properties['EntraBearer']) {
        $failures.Add("Wrong connection authentication: $connectionPath")
    }
    $response = $connectionGet.responses.PSObject.Properties['200']
    $reference = if ($response) { Get-JsonSchemaReference $response.Value.content } else { $null }
    if ($reference -ne '#/components/schemas/PurviewConnectionResponse') {
        $failures.Add("Wrong connection response schema: $connectionPath")
    }
    $etag = if ($response) { $response.Value.headers.PSObject.Properties['ETag'] } else { $null }
    if (-not $etag -or -not $etag.Value.required) {
        $failures.Add("Missing required ETag response header: $connectionPath")
    }
}

foreach ($entry in @(
    @{ Path = $connectionPath; Operation = $connectionPost; Request = '#/components/schemas/ConnectPurviewRequest' },
    @{ Path = $refreshPath; Operation = $refreshPost; Request = '#/components/schemas/RefreshPurviewCatalogRequest' }
)) {
    $operation = $entry.Operation
    if (-not $operation) { continue }
    if (-not $operation.security[0].PSObject.Properties['EntraBearer']) {
        $failures.Add("Wrong connector mutation authentication: $($entry.Path)")
    }
    Assert-RequiredHeader -Operation $operation -Path $entry.Path -Name 'Idempotency-Key'
    Assert-RequiredHeader -Operation $operation -Path $entry.Path -Name 'If-Match'
    $requestReference = Get-JsonSchemaReference $operation.requestBody.content
    if ($requestReference -ne $entry.Request) {
        $failures.Add("Wrong connector request schema: $($entry.Path)")
    }
    $accepted = $operation.responses.PSObject.Properties['202']
    $acceptedReference = if ($accepted) { Get-JsonSchemaReference $accepted.Value.content } else { $null }
    if ($acceptedReference -ne '#/components/schemas/PurviewConnectorOperationAcceptedResponse') {
        $failures.Add("Wrong connector accepted-response schema: $($entry.Path)")
    }
}

$operationGet = Get-ApiOperation -Path '/api/v1/operations/{operationId}' -Method 'get'
if ($operationGet) {
    $operationResponse = $operationGet.responses.PSObject.Properties['200']
    $operationReference = if ($operationResponse) { Get-JsonSchemaReference $operationResponse.Value.content } else { $null }
    if ($operationReference -ne '#/components/schemas/OperationStatusDto') {
        $failures.Add('The shared operation endpoint does not expose OperationStatusDto.')
    }
}

$reference = Invoke-WebRequest ([uri]::new($BaseUri, '/docs'))
if ($reference.Content -notmatch 'Scalar|scalar') { $failures.Add('Interactive API reference is not served.') }
$yaml = Invoke-WebRequest ([uri]::new($BaseUri, '/openapi/v1.yaml'))
if ($yaml.Content -notmatch 'openapi:') { $failures.Add('YAML schema is not served.') }
if ($count -lt 29) { $failures.Add("Unexpectedly incomplete API: $count operations") }
if ($failures.Count) { throw ($failures -join [Environment]::NewLine) }
"API documentation verified: $count operations, authentication, critical DTOs, ingress headers, interactive reference and YAML."
