Describe 'Bounded interactive-user canary lifecycle' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $script:CanaryPath = Join-Path $script:RepositoryRoot 'operations/invoke-bounded-user-canary.ps1'
        $script:StatePath = Join-Path $script:RepositoryRoot 'operations/BoundedUserCanaryState.psm1'
        $script:LiveCanaryPath = Join-Path $script:RepositoryRoot 'tools/Gateway.LiveCanary/Program.cs'
        $script:CanarySource = Get-Content -LiteralPath $script:CanaryPath -Raw
        $script:StateSource = Get-Content -LiteralPath $script:StatePath -Raw
        $script:LiveCanarySource = Get-Content -LiteralPath $script:LiveCanaryPath -Raw
        $script:Tokens = $null
        $script:ParseErrors = $null
        $script:CanaryAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:CanaryPath,
            [ref]$script:Tokens,
            [ref]$script:ParseErrors)
        $script:CanaryCode = @($script:Tokens | Where-Object Kind -ne 'Comment' | ForEach-Object Text) -join ' '
        foreach ($functionName in @(
            'Get-ApplicationsByExactDisplayName',
            'Get-ApplicationsByExactClientId',
            'Get-CanaryGrants',
            'Invoke-ExactCanaryGraphGetOrNull',
            'Get-ExactCanaryGrantById',
            'Get-ExactCanaryServicePrincipalById',
            'Get-ExactCanaryApplicationById',
            'Wait-ExactCanaryObjectAbsent'
        )) {
            $functionAst = @($script:CanaryAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $functionName
            }, $true))
            $functionAst.Count | Should -Be 1
            . ([scriptblock]::Create($functionAst[0].Extent.Text))
        }
        function Get-BoundedGraphCollection {
            param([Parameter(Mandatory)][string]$InitialUrl)
            return @()
        }
        function Invoke-AzJson {
            param([Parameter(Mandatory)][string[]]$Arguments)
            return $null
        }
        function Assert-CanonicalNonEmptyGuid {
            param([string]$Value, [string]$Label)
        }
        function Assert-BoundedOpaqueIdentifier {
            param([string]$Value, [string]$Label)
        }

        function Assert-CheckpointBeforeMutation {
            param(
                [Parameter(Mandatory)][string]$Checkpoint,
                [Parameter(Mandatory)][string]$Mutation
            )

            $checkpointIndex = $script:CanarySource.IndexOf($Checkpoint, [StringComparison]::Ordinal)
            $saveIndex = $script:CanarySource.IndexOf(
                'Save-BoundedUserCanaryState',
                $checkpointIndex,
                [StringComparison]::Ordinal)
            $mutationIndex = $script:CanarySource.IndexOf(
                $Mutation,
                $checkpointIndex,
                [StringComparison]::Ordinal)
            $checkpointIndex | Should -BeGreaterOrEqual 0
            $saveIndex | Should -BeGreaterThan $checkpointIndex
            $mutationIndex | Should -BeGreaterThan $saveIndex
        }
    }

    It 'parses and pins the exact subscription tenant and user independently of CLI default state' {
        $script:ParseErrors.Count | Should -Be 0
        $script:CanarySource | Should -Match 'Connect-BootstrapAzure'
        $script:CanarySource | Should -Match '-NonInteractive'
        $script:CanarySource | Should -Not -Match "'account', 'show', '--subscription'"
        $script:CanarySource | Should -Match "subscriptionId = \`$ExpectedSubscriptionId"
        $script:CanarySource | Should -Match "tenantId = \`$ExpectedTenantId"
        $script:CanarySource | Should -Match "\[string\]\`$azureIdentity\.subscriptionId -cne \`$ExpectedSubscriptionId"
        $script:CanarySource | Should -Match "\[string\]\`$azureIdentity\.tenantId -cne \`$ExpectedTenantId"
        $script:CanarySource | Should -Match "\[string\]\`$azureIdentity\.userObjectId -cne \`$TenantUserObjectId"
    }

    It 'requires the exact v2 custom scope four user-only roles and assigned administrator' {
        $script:CanarySource | Should -Match 'requestedAccessTokenVersion -ne 2'
        $script:CanarySource | Should -Match "allowedMemberTypes\[0\] -cne 'User'"
        $script:CanarySource | Should -Match "@\(\`$Application\.appRoles\)\.Count -ne 4"
        $script:CanarySource | Should -Match 'Assert-BootstrapApplicationOwnership'
        $script:CanarySource | Should -Match 'Assert-ExactBootstrapServicePrincipalBoundary'
        $script:CanarySource | Should -Match ([regex]::Escape(
            '-ExpectedAppRoleAssigneePrincipalId $TenantUserObjectId'))
        $script:CanarySource | Should -Match 'Assert-GatewayApiDelegatedPermissionBoundary'
        $script:CanarySource | Should -Match '-RequireComplete'
        $script:CanarySource | Should -Not -Match "allowedMemberTypes\s*=\s*@\('Application'"
    }

    It 'creates a credential-free loopback app with one exact owner and empty local SP authority' {
        $script:CanarySource | Should -Match "publicClient = @\{ redirectUris = @\('http://localhost'\) \}"
        $script:CanarySource | Should -Match 'isFallbackPublicClient = \$false'
        $script:CanarySource | Should -Match 'passwordCredentials\)\.Count -ne 0'
        $script:CanarySource | Should -Match 'keyCredentials\)\.Count -ne 0'
        $script:CanarySource | Should -Match "type = 'Scope'"
        $script:CanarySource | Should -Match 'Assert-ExactTemporaryApplicationOwner'
        $script:CanarySource | Should -Match 'must have exactly the pinned administrator as owner'
        $script:CanarySource | Should -Match 'ExpectedAppRoles @\(\)'
        $script:CanarySource | Should -Match 'ExpectedOauth2PermissionScopes @\(\)'
    }

    It 'uses one principal-specific access_as_user grant and never broad tenant consent' {
        $script:CanarySource | Should -Match "consentType = 'Principal'"
        $script:CanarySource | Should -Match 'principalId = \$TenantUserObjectId'
        $script:CanarySource | Should -Match "scope = 'access_as_user'"
        $script:CanarySource | Should -Not -Match "consentType = 'AllPrincipals'"
        $script:CanarySource | Should -Not -Match 'AzureCliCredential'
        $script:CanarySource | Should -Not -Match "account', 'get-access-token"
    }

    It 'constructs exact Graph filter and select query keys without literal backticks' {
        $script:CapturedInitialUrls = [Collections.Generic.List[string]]::new()
        Mock Get-BoundedGraphCollection {
            param([string]$InitialUrl)
            $script:CapturedInitialUrls.Add($InitialUrl)
            return @()
        }

        Get-ApplicationsByExactDisplayName -DisplayName 'Exact Test Name' | Out-Null
        Get-ApplicationsByExactClientId -ClientId '11111111-1111-1111-1111-111111111111' | Out-Null
        Get-CanaryGrants -ClientServicePrincipalId '22222222-2222-2222-2222-222222222222' | Out-Null

        $script:CapturedInitialUrls.Count | Should -Be 3
        foreach ($url in $script:CapturedInitialUrls) {
            $url | Should -Match ([regex]::Escape('?$filter='))
            $url | Should -Match ([regex]::Escape('&$select='))
            $url | Should -Not -Match ([regex]::Escape('`$'))
        }
        $script:CapturedInitialUrls[0] | Should -Match ([regex]::Escape(
            '&$select=id,appId,displayName,signInAudience,identifierUris,tags,api,appRoles,'))
        $script:CapturedInitialUrls[2] | Should -Match ([regex]::Escape(
            '&$select=id,clientId,resourceId,consentType,principalId,scope'))
    }

    It 'treats only an exact-ID Graph 404 as absence and requires stable readback' {
        Mock Invoke-AzJson {
            throw 'Microsoft Graph request returned HTTP 404; provider body was suppressed.'
        }
        Invoke-ExactCanaryGraphGetOrNull `
            -Url 'https://graph.microsoft.com/v1.0/applications/11111111-1111-1111-1111-111111111111' |
            Should -BeNullOrEmpty

        Mock Invoke-AzJson {
            throw 'Microsoft Graph request returned HTTP 500; provider body was suppressed.'
        }
        {
            Invoke-ExactCanaryGraphGetOrNull `
                -Url 'https://graph.microsoft.com/v1.0/applications/11111111-1111-1111-1111-111111111111'
        } | Should -Throw '*HTTP 500*'

        $script:ExactReadCount = 0
        Mock Start-Sleep { }
        Wait-ExactCanaryObjectAbsent -ReadExact {
            $script:ExactReadCount++
            if ($script:ExactReadCount -eq 2) { return [pscustomobject]@{ id = 'still-present' } }
            return $null
        } -FailureMessage 'absence failed'
        $script:ExactReadCount | Should -Be 4
    }

    It 'constructs exact object-ID GET selectors for every cleanup authority' {
        $script:ExactGetUrls = [Collections.Generic.List[string]]::new()
        Mock Invoke-AzJson {
            param([string[]]$Arguments)
            $script:ExactGetUrls.Add([string]$Arguments[4])
            return [pscustomobject]@{ id = 'observed' }
        }

        Get-ExactCanaryGrantById -GrantId 'safe_grant_id' | Out-Null
        Get-ExactCanaryServicePrincipalById `
            -ServicePrincipalId '11111111-1111-1111-1111-111111111111' | Out-Null
        Get-ExactCanaryApplicationById `
            -ApplicationObjectId '22222222-2222-2222-2222-222222222222' | Out-Null

        $script:ExactGetUrls.Count | Should -Be 3
        $script:ExactGetUrls[0] | Should -Match '/oauth2PermissionGrants/safe_grant_id\?\$select='
        $script:ExactGetUrls[1] | Should -Match '/servicePrincipals/11111111-1111-1111-1111-111111111111\?\$select='
        $script:ExactGetUrls[2] | Should -Match '/applications/22222222-2222-2222-2222-222222222222\?\$select='
        $script:ExactGetUrls | Should -Not -Match ([regex]::Escape('`$'))
    }

    It 'persists each external mutation Started stage before its sole call site' {
        Assert-CheckpointBeforeMutation `
            -Checkpoint "-Status 'ApplicationCreateStarted'" `
            -Mutation "Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/applications'"
        Assert-CheckpointBeforeMutation `
            -Checkpoint "-Status 'OwnerAddStarted'" `
            -Mutation '/owners/`$ref'
        Assert-CheckpointBeforeMutation `
            -Checkpoint "-Status 'ServicePrincipalCreateStarted'" `
            -Mutation "Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/servicePrincipals'"
        Assert-CheckpointBeforeMutation `
            -Checkpoint "-Status 'GrantCreateStarted'" `
            -Mutation "Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants'"
        Assert-CheckpointBeforeMutation `
            -Checkpoint "-Status 'ArmStarted'" `
            -Mutation "-Method 'PATCH'"
        Assert-CheckpointBeforeMutation `
            -Checkpoint "-Status 'ChildLaunchStarted'" `
            -Mutation '& dotnet @canaryArguments'

        ([regex]::Matches($script:CanarySource, [regex]::Escape(
            "Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/applications'"))).Count | Should -Be 1
        ([regex]::Matches($script:CanarySource, [regex]::Escape('/owners/`$ref'))).Count | Should -Be 1
        ([regex]::Matches($script:CanarySource, [regex]::Escape(
            "Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/servicePrincipals'"))).Count | Should -Be 1
        ([regex]::Matches($script:CanarySource, [regex]::Escape(
            "Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants'"))).Count | Should -Be 1
        ([regex]::Matches($script:CanarySource, [regex]::Escape("-Method 'PATCH'"))).Count | Should -Be 1
        ([regex]::Matches($script:CanarySource, [regex]::Escape('& dotnet @canaryArguments'))).Count | Should -Be 1
        $script:CanarySource | Should -Match 'This Started stage is GET-only'
        $script:CanarySource | Should -Match 'will not be repeated'
    }

    It 'binds recovery to atomic safe-ID state exact executable hashes and an immutable tombstone' {
        $script:CanarySource | Should -Match '\.bootstrap/canary/'
        $script:CanarySource | Should -Match 'Enter-BootstrapLock'
        $script:CanarySource | Should -Match 'wrapperSha256'
        $script:CanarySource | Should -Match 'helperBundleSha256'
        $script:CanarySource | Should -Match 'canaryBundleSha256'
        $script:CanarySource | Should -Match 'promptShieldExpected'
        $script:CanarySource | Should -Match 'purviewExpected'
        $script:StateSource | Should -Match "'promptShieldExpected'"
        $script:StateSource | Should -Match "'purviewExpected'"
        $script:StateSource | Should -Match "promptShieldExpected -cnotmatch '\^\(true\|false\)\$'"
        $script:StateSource | Should -Match "purviewExpected -cnotmatch '\^\(true\|false\)\$'"
        $script:CanarySource | Should -Match 'Get-ChildItem -LiteralPath \$canaryOutput -Recurse -File'
        $script:CanarySource | Should -Match 'GetRelativePath\(\$canaryOutput'
        $script:CanarySource | Should -Match 'bootstrap/modules/Common\.psm1'
        $script:CanarySource | Should -Match 'operations/BoundedUserCanaryState\.psm1'
        $script:CanarySource | Should -Match "status -cne 'CredentialObserved'"
        $script:CanarySource | Should -Match 'recoveryCredentialId -cne \$RecoveryCredentialId'
        $script:CanarySource | Should -Match "status -ceq 'Completed'"
        $script:StateSource | Should -Match 'Completed = @\(\)'
        $script:StateSource | Should -Match '\$stream\.Flush\(\$true\)'
        $script:StateSource | Should -Match '\[IO\.File\]::Move\(\$temporary, \$fullPath, \$true\)'
    }

    It 'preserves every durable nonterminal resume before Azure validation and always releases its lock' {
        $preservationCheck = $script:CanarySource.IndexOf(
            'Test-BoundedUserCanaryStateRequiresPreservation',
            [StringComparison]::Ordinal)
        $preserve = $script:CanarySource.IndexOf(
            '$preserveTemporaryIdentity = $true',
            $preservationCheck,
            [StringComparison]::Ordinal)
        $connect = $script:CanarySource.IndexOf(
            'Connect-BootstrapAzure',
            $preservationCheck,
            [StringComparison]::Ordinal)
        $preservationCheck | Should -BeGreaterOrEqual 0
        $preserve | Should -BeGreaterThan $preservationCheck
        $connect | Should -BeGreaterThan $preserve
        $script:CanarySource | Should -Match 'RESUME REQUIRED'
        $script:CanarySource | Should -Match '\$canaryLock\.Dispose\(\)'
        $script:CanarySource | Should -Match 'finally \{\s*if \(\$null -ne \$canaryLock\)'
    }

    It 'persists an issued ID before rendering it and completes before enabling cleanup' {
        $observed = $script:CanarySource.IndexOf("-Status 'CredentialObserved'", [StringComparison]::Ordinal)
        $save = $script:CanarySource.IndexOf('Save-BoundedUserCanaryState', $observed, [StringComparison]::Ordinal)
        $render = $script:CanarySource.IndexOf('Write-Host $childLine', $observed, [StringComparison]::Ordinal)
        $completed = $script:CanarySource.IndexOf("-Status 'Completed'", $observed, [StringComparison]::Ordinal)
        $completedSave = $script:CanarySource.IndexOf('Save-BoundedUserCanaryState', $completed, [StringComparison]::Ordinal)
        $cleanupEnabled = $script:CanarySource.IndexOf(
            '$preserveTemporaryIdentity = $false',
            $completed,
            [StringComparison]::Ordinal)
        $save | Should -BeGreaterThan $observed
        $render | Should -BeGreaterThan $save
        $completedSave | Should -BeGreaterThan $completed
        $cleanupEnabled | Should -BeGreaterThan $completedSave
    }

    It 'uses InteractiveBrowserUser and RevokeOnly without accepting a token argument' {
        $script:CanarySource | Should -Match "'--authentication-mode', 'InteractiveBrowserUser'"
        $script:CanarySource | Should -Match "'--authentication-client-id', \`$temporaryApplicationClientId"
        $script:CanarySource | Should -Match "'--api-scope-base-uri', \`$expectedScopeBaseUri"
        $script:CanarySource | Should -Match "\`$operationMode = if \(\`$recoveryMode\) \{ 'RevokeOnly' \} else \{ 'Full' \}"
        $script:CanarySource | Should -Match "'--recovery-credential-id', \`$RecoveryCredentialId"
        $script:CanarySource | Should -Not -Match '(?i)--access-token|--bearer|authorization-header'
        $script:LiveCanarySource | Should -Match 'if \(options\.OperationMode == CanaryOperationMode\.RevokeOnly\)'
    }

    It 'binds exact protection expectations and keeps the minimal-profile ingestion proof unconditional' {
        $script:CanarySource | Should -Match '\[switch\]\$ExpectPromptShieldEnabled'
        $script:CanarySource | Should -Match '\[switch\]\$ExpectPurviewEnabled'
        $script:CanarySource | Should -Match ([regex]::Escape(
            'promptShieldExpected = ([bool]$ExpectPromptShieldEnabled).ToString().ToLowerInvariant()'))
        $script:CanarySource | Should -Match ([regex]::Escape(
            'purviewExpected = ([bool]$ExpectPurviewEnabled).ToString().ToLowerInvariant()'))
        $script:CanarySource | Should -Match ([regex]::Escape(
            "'--expect-prompt-shield-enabled', ([bool]`$ExpectPromptShieldEnabled).ToString().ToLowerInvariant()"))
        $script:CanarySource | Should -Match ([regex]::Escape(
            "'--expect-purview-enabled', ([bool]`$ExpectPurviewEnabled).ToString().ToLowerInvariant()"))

        $script:LiveCanarySource | Should -Match 'RequiredBoolean\(values, "expect-prompt-shield-enabled"\)'
        $script:LiveCanarySource | Should -Match 'RequiredBoolean\(values, "expect-purview-enabled"\)'
        $script:LiveCanarySource | Should -Match 'must be canonical lowercase true or false'

        $allowed = $script:LiveCanarySource.IndexOf(
            'ValidateAllowedEvaluation(await EvaluateAsync(',
            [StringComparison]::Ordinal)
        $activity = $script:LiveCanarySource.IndexOf(
            '"api/v1/agent-activities"',
            [StringComparison]::Ordinal)
        $interaction = $script:LiveCanarySource.IndexOf(
            '"api/v1/ai-interactions"',
            [StringComparison]::Ordinal)
        $conditionalBlock = $script:LiveCanarySource.IndexOf(
            'if (options.ExpectPromptShieldEnabled)',
            [StringComparison]::Ordinal)
        $allowed | Should -BeGreaterOrEqual 0
        $activity | Should -BeGreaterThan $allowed
        $interaction | Should -BeGreaterThan $activity
        $conditionalBlock | Should -BeGreaterThan $interaction
        $script:LiveCanarySource | Should -Match 'Prompt Shields injection-block proof was not attempted'
        $script:LiveCanarySource | Should -Match 'Live Gateway ingestion canary completed'
    }

    It 'redacts provider failures and never renders clear credentials tokens or dependency bodies' {
        $script:LiveCanarySource | Should -Match 'provider details were suppressed'
        $script:LiveCanarySource | Should -Not -Match 'exception\.Message|Exception\.Message'
        $script:LiveCanarySource | Should -Not -Match 'Console\.WriteLine\(credentialKey'
        $script:LiveCanarySource | Should -Not -Match 'Console\.WriteLine\(token\.Token'
        $script:CanaryCode | Should -Not -Match '(?i)servicebus|queue|peek|receive|deadletter|purge'
        $script:CanaryCode | Should -Not -Match '(?i)clientsecret|password\s*=|apikey|credentialKey'
        $script:CanaryCode | Should -Not -Match 'Write-(Host|Output).*(token|secret|key)'
    }

    It 'performs only reverse-order exact cleanup after revocation or a Completed tombstone' {
        $grant = $script:CanarySource.IndexOf("@{ label = 'delegated grant'", [StringComparison]::Ordinal)
        $principal = $script:CanarySource.IndexOf("@{ label = 'service principal'", [StringComparison]::Ordinal)
        $application = $script:CanarySource.IndexOf("@{ label = 'active application'", [StringComparison]::Ordinal)
        $finally = $script:CanarySource.IndexOf("finally {`n    try {", [StringComparison]::Ordinal)
        $grant | Should -BeGreaterThan $finally
        $principal | Should -BeGreaterThan $grant
        $application | Should -BeGreaterThan $principal
        $script:CanarySource | Should -Match 'Get-ExactCanaryGrantById'
        $script:CanarySource | Should -Match 'Get-ExactCanaryServicePrincipalById'
        $script:CanarySource | Should -Match 'Get-ExactCanaryApplicationById'
        $script:CanarySource | Should -Match 'could not be proven absent by exact ID after deletion'
        $script:CanarySource | Should -Match 'different client or name authority remains'
    }

    It 'keeps direct native execution limited to the reviewed dotnet child' {
        $commands = @($script:CanaryAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand
        }, $true))
        $directNames = @($commands | ForEach-Object { $_.CommandElements[0].Extent.Text } | Sort-Object -Unique)
        $directNames | Should -Not -Contain 'az'
        $directNames | Should -Contain 'dotnet'
    }
}
