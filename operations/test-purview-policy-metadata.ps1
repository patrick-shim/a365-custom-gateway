#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Gateway.Purview\Automation\Invoke-PurviewSettingsOperation.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'The provider script has syntax errors.' }

# Load only the pure validators, never the script's provider connection or mutation flow.
foreach ($name in @('Get-ProviderReadbackMember', 'Assert-ProviderDlpMetadata')) {
    $definitions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $false))
    if ($definitions.Count -ne 1) { throw "Expected one definition of $name." }
    Invoke-Expression $definitions[0].Extent.Text
}

$timestamp = '2026-09-13T00:00:00Z'
$validJson = '{"WhenRulesChangedUtc":"2026-09-13T00:00:00Z"}'
$cases = @(
    @{ Name = 'absent optional metadata'; Fields = @{}; Accept = $true }
    @{ Name = 'null optional metadata'; Fields = @{ PolicyRulesMetaData = $null }; Accept = $true }
    @{ Name = 'empty provider string'; Fields = @{ PolicyRulesMetaData = '' }; Accept = $true }
    @{ Name = 'valid JSON metadata'; Fields = @{ PolicyRulesMetaData = $validJson }; Accept = $true }
    @{ Name = 'valid typed metadata'; Fields = @{ PolicyRulesMetaData = [pscustomobject]@{ WhenRulesChangedUtc = [datetime]$timestamp } }; Accept = $true }
    @{ Name = 'valid dictionary metadata'; Fields = @{ PolicyRulesMetaData = @{ WhenRulesChangedUtc = [DateTimeOffset]$timestamp } }; Accept = $true }
    @{ Name = 'JSON null'; Fields = @{ PolicyRulesMetaData = 'null' }; Accept = $false }
    @{ Name = 'whitespace is not an observed empty value'; Fields = @{ PolicyRulesMetaData = ' ' }; Accept = $false }
    @{ Name = 'empty JSON object'; Fields = @{ PolicyRulesMetaData = '{}' }; Accept = $false }
    @{ Name = 'empty JSON array'; Fields = @{ PolicyRulesMetaData = '[]' }; Accept = $false }
    @{ Name = 'singleton JSON array'; Fields = @{ PolicyRulesMetaData = "[$validJson]" }; Accept = $false }
    @{ Name = 'multiple JSON objects'; Fields = @{ PolicyRulesMetaData = "[$validJson,$validJson]" }; Accept = $false }
    @{ Name = 'JSON string'; Fields = @{ PolicyRulesMetaData = '"unexpected"' }; Accept = $false }
    @{ Name = 'JSON boolean'; Fields = @{ PolicyRulesMetaData = 'true' }; Accept = $false }
    @{ Name = 'JSON number'; Fields = @{ PolicyRulesMetaData = '1' }; Accept = $false }
    @{ Name = 'typed empty array'; Fields = @{ PolicyRulesMetaData = @() }; Accept = $false }
    @{ Name = 'typed scalar'; Fields = @{ PolicyRulesMetaData = 1 }; Accept = $false }
    @{ Name = 'malformed JSON'; Fields = @{ PolicyRulesMetaData = '{broken' }; Accept = $false }
    @{ Name = 'unknown metadata field'; Fields = @{ PolicyRulesMetaData = '{"WhenRulesChangedUtc":"2026-09-13T00:00:00Z","Bypass":true}' }; Accept = $false }
    @{ Name = 'ambiguous metadata fields'; Fields = @{ PolicyRulesMetaData = '{"WhenRulesChangedUtc":"2026-09-13T00:00:00Z","whenruleschangedutc":"2026-09-13T00:00:00Z"}' }; Accept = $false }
    @{ Name = 'incorrect field casing'; Fields = @{ PolicyRulesMetaData = '{"whenRulesChangedUtc":"2026-09-13T00:00:00Z"}' }; Accept = $false }
    @{ Name = 'invalid timestamp'; Fields = @{ PolicyRulesMetaData = '{"WhenRulesChangedUtc":"not-a-date"}' }; Accept = $false }
    @{ Name = 'null timestamp'; Fields = @{ PolicyRulesMetaData = '{"WhenRulesChangedUtc":null}' }; Accept = $false }
    @{ Name = 'numeric timestamp'; Fields = @{ PolicyRulesMetaData = '{"WhenRulesChangedUtc":42}' }; Accept = $false }
    @{ Name = 'oversized metadata'; Fields = @{ PolicyRulesMetaData = ('x' * 16385) }; Accept = $false }
    @{ Name = 'empty metadata does not bypass policy classification'; Fields = @{ PolicyRulesMetaData = ''; Type = 'Other' }; Accept = $false }
    @{ Name = 'empty metadata does not bypass enabled state'; Fields = @{ PolicyRulesMetaData = ''; Enabled = $false }; Accept = $false }
    @{ Name = 'empty metadata does not bypass constraints'; Fields = @{ PolicyRulesMetaData = ''; PolicyConstraints = @{ UnexpectedScope = 'All' } }; Accept = $false }
    @{ Name = 'empty metadata does not bypass identity aliases'; Fields = @{ PolicyRulesMetaData = ''; Identity = 'expected'; Id = 'different' }; Accept = $false }
    @{ Name = 'empty metadata does not bypass missing bindings'; Fields = @{ PolicyRulesMetaData = ''; LocationInclusions = $null }; Accept = $false }
)

foreach ($case in $cases) {
    $policy = @{ Type = 'Dlp'; PolicyCategory = 'Unknown'; Enabled = $true }
    foreach ($name in $case.Fields.Keys) { $policy[$name] = $case.Fields[$name] }
    $failure = $null
    try {
        Assert-ProviderDlpMetadata -Policy $policy `
            -ExpectedIds @('11111111-1111-4111-8111-111111111111') `
            -ExpectedType Individual -ExpectedProviderMode Enable
    }
    catch { $failure = $_ }

    if ($case.Accept -and $null -ne $failure) {
        throw "Unexpected rejection for '$($case.Name)': $($failure.Exception.Message)"
    }
    if (-not $case.Accept -and $null -eq $failure) {
        throw "Unexpected acceptance for '$($case.Name)'."
    }
    if ($null -ne $failure -and
        $failure.Exception -is [Management.Automation.PropertyNotFoundException]) {
        throw "StrictMode property dereference escaped the validator for '$($case.Name)'."
    }
}

Write-Output "PASS: $($cases.Count) policy metadata cases under StrictMode Latest; no provider calls."
