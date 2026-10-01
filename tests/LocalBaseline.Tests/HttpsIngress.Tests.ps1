BeforeAll {
    $tokens = $null
    $errors = $null
    $source = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\..\bootstrap\modules\Verification.psm1'),
        [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Verification source must parse before ingress contract tests.' }
    $definition = $source.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-GatewayHttpsIngressEvidence'
    }, $false)
    if ($null -eq $definition) { throw 'The authored HTTPS ingress verifier is required.' }
    . ([scriptblock]::Create($definition.Extent.Text))
}

Describe 'Current HTTPS ingress evidence' {
    BeforeEach {
        Mock Invoke-WebRequest { throw 'Unscripted network access is forbidden.' }
    }

    It 'checks the request-derived HTTPS origin with untrusted forwarding headers supplied by the client' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Content = '{"servers":[{"url":"https://gateway.invalid/"}]}' }
        } -ParameterFilter {
            $Uri -ceq 'https://gateway.invalid/openapi/v1.json' -and
            $Headers['X-Forwarded-Proto'] -ceq 'http' -and
            $Headers['X-Forwarded-Host'] -ceq 'untrusted.invalid' -and
            $TimeoutSec -eq 30 -and $MaximumRedirection -eq 0
        }
        $result = Get-GatewayHttpsIngressEvidence -ApiFqdn gateway.invalid
        $result.status | Should -BeExactly 'Passed'
        $result.scheme | Should -BeExactly 'https'
        $result.host | Should -BeExactly 'gateway.invalid'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'rejects a missing, insecure, foreign or ambiguous reflected origin' -ForEach @(
        '{"servers":[{"url":"http://gateway.invalid/"}]}',
        '{"servers":[{"url":"https://untrusted.invalid/"}]}',
        '{"servers":[]}',
        '{"servers":[{"url":"https://gateway.invalid/"},{"url":"https://gateway.invalid/"}]}'
    ) {
        $body = $_
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $body } }
        { Get-GatewayHttpsIngressEvidence -ApiFqdn gateway.invalid } | Should -Throw
    }

    It 'rejects non-success and over-sized documents' -ForEach @(
        @{ Status = 503; Body = '{}' },
        @{ Status = 200; Body = ('x' * 2097153) }
    ) {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = $Status; Content = $Body } }
        { Get-GatewayHttpsIngressEvidence -ApiFqdn gateway.invalid } | Should -Throw
    }

    It 'rejects malformed authority before any request' -ForEach @('gateway.invalid/path', 'gateway.invalid:443', 'user@gateway.invalid') {
        { Get-GatewayHttpsIngressEvidence -ApiFqdn $_ } | Should -Throw
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
}
