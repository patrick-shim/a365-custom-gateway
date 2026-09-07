BeforeAll {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Import-Module "$root/bootstrap/modules/Common.psm1" -Force -DisableNameChecking
    Import-Module "$root/bootstrap/modules/Entra.psm1" -Force -DisableNameChecking
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        "$root/bootstrap/bootstrap.ps1", [ref]$tokens, [ref]$errors)
    $errors.Count | Should -Be 0
    $plan = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Invoke-GatewayPlanWorkflow'
    }, $true)
    # Execute the actual context -> namespace -> What-If caller composition,
    # without running unrelated local packaging, state writes or Bicep compilation.
    $source = $plan.Extent.Text
    $start = $source.IndexOf('Clear-BootstrapAzureSubscriptionContext', [StringComparison]::Ordinal)
    $end = $source.IndexOf("`$script:GatewayFailureCode = 'plan_blueprint'", [StringComparison]::Ordinal)
    $script:planNamespaceSegment = [scriptblock]::Create($source.Substring($start, $end - $start))
    function Invoke-GatewayFoundationWhatIf {
        param($Config, $RepositoryRoot, $DeploymentOwnershipId, $SourceFingerprint,
            $ExecutionSourceFingerprint, $State)
        $script:whatIfReached = $true
        throw 'Synthetic What-If boundary reached.'
    }
}

Describe 'Plan namespace preflight real Graph composition' {
    BeforeEach {
        $script:owner = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
        $script:config = @{
            projectName = 'namespace-fixture'; environment = 'dev'
            subscriptionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            tenantId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
            purview = @{ enabled = $false }
        }
        $script:apiName = 'A365 Gateway API - namespace-fixture-dev'
        $script:adminName = 'A365 Gateway Admin UI - namespace-fixture-dev'
        $script:purviewName = 'A365 Gateway Purview Automation - namespace-fixture-dev'
        $script:audience = 'api://a365-gateway-namespace-fixture-dev'
        $script:api = @{
            id = '11111111-1111-4111-8111-111111111111'
            displayName = $script:apiName
            tags = @(Get-BootstrapApplicationTags -DeploymentOwnershipId $script:owner)
        }
        $script:http = [pscustomobject]@{
            Applications = @{}; UriMatches = @(); Calls = [Collections.Generic.List[string]]::new()
            UnexpectedIo = [Collections.Generic.List[string]]::new()
            Status = 200; Malformed = $false; NextLink = ''; WrongTenant = $false
        }
        $script:http | Add-Member -MemberType ScriptMethod -Name SendAsync -Value {
            param($Request, $CompletionOption)
            $url = [Uri]::UnescapeDataString($Request.RequestUri.AbsoluteUri)
            if ($Request.Method.Method -cne 'GET' -or $Request.RequestUri.AbsolutePath -cne '/v1.0/applications') {
                $this.UnexpectedIo.Add('Unexpected HTTP mutation or collection.')
                throw 'Only application collection GET is permitted in namespace preflight.'
            }
            $this.Calls.Add($url)
            $values = @()
            if ($url.Contains('identifierUris/any(', [StringComparison]::Ordinal)) {
                $values = @($this.UriMatches)
            }
            elseif ($url -match "displayName eq '([^']+)'") {
                if ($this.Applications.ContainsKey($Matches[1])) { $values = @($this.Applications[$Matches[1]]) }
            }
            else { throw 'Unexpected namespace query.' }
            $payload = @{ value = $values }
            if ($this.Malformed) { $payload = @{ unexpected = @() } }
            if ($this.NextLink) { $payload['@odata.nextLink'] = $this.NextLink }
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$this.Status)
            $response.Content = [Net.Http.StringContent]::new(
                (ConvertTo-Json -InputObject $payload -Depth 12 -Compress))
            $task = [Threading.Tasks.TaskCompletionSource[Net.Http.HttpResponseMessage]]::new()
            $task.SetResult($response)
            return $task.Task
        }
        # Substitute only native process and HTTP I/O. Exact-account validation,
        # request parsing/dispatch, pagination and all Entra helpers remain real.
        Mock -ModuleName Common Invoke-BootstrapCommand {
            param($FilePath, $ArgumentList)
            if ($FilePath -cne 'az' -or ($ArgumentList[0..1] -join ' ') -cne 'account get-access-token') {
                $script:http.UnexpectedIo.Add('Unexpected native mutation or command.')
                throw 'Unexpected native process in namespace preflight.'
            }
            @{
                subscription = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
                tenant = if ($script:http.WrongTenant) { 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' } else { 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' }
                tokenType = 'Bearer'; expires_on = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
                accessToken = 'synthetic-test-only'
            } | ConvertTo-Json -Compress
        }
        Mock -ModuleName Common Get-BootstrapGraphHttpClient { $script:http }
        Set-BootstrapAzureSubscriptionContext -SubscriptionId $script:config.subscriptionId -TenantId $script:config.tenantId
    }

    AfterEach {
        Clear-BootstrapAzureSubscriptionContext
        $script:http.UnexpectedIo | Should -BeNullOrEmpty
    }

    It 'stops the actual Plan segment before What-If on a preexisting unowned API name' {
        $script:api.tags = @(Get-BootstrapApplicationTags -DeploymentOwnershipId 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee')
        $script:http.Applications[$script:apiName] = @($script:api)
        $Configuration = $script:config
        $State = @{ deploymentOwnershipId = $script:owner }
        $deploymentSourceFingerprint = 'sha256:' + ('a' * 64)
        $sourceFingerprintBefore = $deploymentSourceFingerprint
        $script:whatIfReached = $false
        { & $script:planNamespaceSegment } | Should -Throw 'Entra application namespace could not be verified.*'
        $script:whatIfReached | Should -BeFalse
        $script:GatewayFailureCode | Should -BeExactly 'plan_entra_namespace'
        $script:http.Calls.Count | Should -Be 1
    }

    It 'checks core exact names and API URI with GET only and skips optional namespace' {
        $script:http.Applications[$script:purviewName] = @(@{
            id = $script:api.id; displayName = $script:purviewName; tags = @('unowned')
        })
        Assert-GatewayApplicationNamespacePlanBoundary -Config $script:config -DeploymentOwnershipId $script:owner |
            Should -BeTrue
        $script:http.Calls.Count | Should -Be 3
        ($script:http.Calls -join '|') | Should -Match ([regex]::Escape("displayName eq '$script:apiName'"))
        ($script:http.Calls -join '|') | Should -Match ([regex]::Escape("displayName eq '$script:adminName'"))
        ($script:http.Calls -join '|') | Should -Match ([regex]::Escape("identifierUris/any(uri:uri eq '$script:audience')"))
        ($script:http.Calls -join '|') | Should -Not -Match 'Purview|owners|servicePrincipals|grants'
    }

    It 'allows the actual Plan segment to reach What-If only after successful namespace reads' {
        $Configuration = $script:config
        $State = @{ deploymentOwnershipId = $script:owner }
        $deploymentSourceFingerprint = 'sha256:' + ('a' * 64)
        $sourceFingerprintBefore = $deploymentSourceFingerprint
        $script:whatIfReached = $false
        { & $script:planNamespaceSegment } | Should -Throw 'Synthetic What-If boundary reached.'
        $script:whatIfReached | Should -BeTrue
        $script:GatewayFailureCode | Should -BeExactly 'plan_what_if'
        $script:http.Calls.Count | Should -Be 3
    }

    It 'fails closed without exact Azure context rather than attempting a network read' {
        Clear-BootstrapAzureSubscriptionContext
        { Assert-GatewayApplicationNamespacePlanBoundary -Config $script:config -DeploymentOwnershipId $script:owner } |
            Should -Throw 'Entra application namespace could not be verified.*'
        $script:http.Calls.Count | Should -Be 0
        Should -Invoke -ModuleName Common Invoke-BootstrapCommand -Times 0 -Exactly
    }

    It 'permits exact owned names and the same API ID without claiming full application readiness' {
        $script:config.purview.enabled = $true
        $script:http.Applications[$script:apiName] = @($script:api)
        foreach ($name in @($script:adminName, $script:purviewName)) {
            $script:http.Applications[$name] = @(@{
                id = [guid]::NewGuid().ToString('D'); displayName = $name; tags = @($script:api.tags)
            })
        }
        $script:http.UriMatches = @(@{ id = $script:api.id; identifierUris = @($script:audience) })
        # Deliberately no owners, roles, authentication shape or grants in fixtures.
        Assert-GatewayApplicationNamespacePlanBoundary -Config $script:config -DeploymentOwnershipId $script:owner |
            Should -BeTrue
        $script:http.Calls.Count | Should -Be 4
        Assert-GatewayApplicationNamespacePlanBoundary -Config $script:config -DeploymentOwnershipId $script:owner |
            Should -BeTrue
        $script:http.Calls.Count | Should -Be 8
    }

    It 'rejects unowned <kind> namespace' -TestCases @(
        @{ kind = 'API' }, @{ kind = 'Admin UI' }, @{ kind = 'Purview Automation' }
    ) {
        param($kind)
        $script:config.purview.enabled = $true
        $name = "A365 Gateway $kind - namespace-fixture-dev"
        $script:http.Applications[$name] = @(@{
            id = $script:api.id; displayName = $name; tags = @('A365GatewayBootstrap')
        })
        { Assert-GatewayApplicationNamespacePlanBoundary -Config $script:config -DeploymentOwnershipId $script:owner } |
            Should -Throw 'Entra application namespace could not be verified.*'
    }

    It 'rejects a URI-only collision even when no requested display name exists' {
        $script:http.UriMatches = @(@{ id = $script:api.id; identifierUris = @($script:audience) })
        { Assert-GatewayApplicationNamespacePlanBoundary -Config $script:config -DeploymentOwnershipId $script:owner } |
            Should -Throw 'Entra application namespace could not be verified.*'
    }

    It 'rejects a different or duplicate URI owner even with an owned API name' -TestCases @(
        @{ duplicate = $false }, @{ duplicate = $true }
    ) {
        param($duplicate)
        $script:http.Applications[$script:apiName] = @($script:api)
        $script:http.UriMatches = @(@{ id = '22222222-2222-4222-8222-222222222222'; identifierUris = @($script:audience) })
        if ($duplicate) { $script:http.UriMatches = @(
            @{ id = $script:api.id; identifierUris = @($script:audience) },
            @{ id = $script:api.id; identifierUris = @($script:audience) }
        ) }
        { Assert-GatewayApplicationNamespacePlanBoundary -Config $script:config -DeploymentOwnershipId $script:owner } |
            Should -Throw 'Entra application namespace could not be verified.*'
    }

    It 'fails closed on unknown, duplicate or unauthorized discovery: <fault>' -TestCases @(
        @{ fault = 'duplicateName' }, @{ fault = 'wrongName' }, @{ fault = 'missingId' },
        @{ fault = 'missingTags' }, @{ fault = 'nullTags' }, @{ fault = 'scalarTags' },
        @{ fault = 'duplicateTags' }, @{ fault = 'extraTag' }, @{ fault = 'malformed' },
        @{ fault = 'forbidden' }, @{ fault = 'wrongTenant' }, @{ fault = 'continuation' },
        @{ fault = 'wrongUri' }
    ) {
        param($fault)
        $script:http.Applications[$script:apiName] = @($script:api)
        switch ($fault) {
            duplicateName { $script:http.Applications[$script:apiName] = @($script:api, $script:api) }
            wrongName { $script:api.displayName = 'unrelated' }
            missingId { $script:api.Remove('id') }
            missingTags { $script:api.Remove('tags') }
            nullTags { $script:api.tags = $null }
            scalarTags { $script:api.tags = $script:api.tags -join '|' }
            duplicateTags { $script:api.tags = @($script:api.tags[0], $script:api.tags[0]) }
            extraTag { $script:api.tags += 'unreviewed' }
            malformed { $script:http.Malformed = $true }
            forbidden { $script:http.Status = 403 }
            wrongTenant { $script:http.WrongTenant = $true }
            continuation { $script:http.NextLink = 'https://example.invalid/v1.0/applications' }
            wrongUri { $script:http.UriMatches = @(@{ id = $script:api.id; identifierUris = @('api://unrelated') }) }
        }
        { Assert-GatewayApplicationNamespacePlanBoundary -Config $script:config -DeploymentOwnershipId $script:owner } |
            Should -Throw 'Entra application namespace could not be verified.*'
    }
}
