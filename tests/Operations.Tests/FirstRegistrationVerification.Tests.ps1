Describe 'First-registration interactive verification lifecycle' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $script:VerificationPath = Join-Path $script:RepositoryRoot 'operations/verify-first-registration.ps1'
        $script:StatePath = Join-Path $script:RepositoryRoot 'operations/FirstRegistrationVerificationState.psm1'
        $script:LiveVerificationPath = Join-Path $script:RepositoryRoot 'tools/Gateway.LiveVerification/Program.cs'
        $script:VerificationSource = Get-Content -LiteralPath $script:VerificationPath -Raw
        $script:StateSource = Get-Content -LiteralPath $script:StatePath -Raw
        $script:LiveVerificationSource = Get-Content -LiteralPath $script:LiveVerificationPath -Raw
        $script:Tokens = $null
        $script:ParseErrors = $null
        $script:VerificationAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:VerificationPath,
            [ref]$script:Tokens,
            [ref]$script:ParseErrors)
        $script:VerificationCode = @($script:Tokens | Where-Object Kind -ne 'Comment' | ForEach-Object Text) -join ' '
        foreach ($functionName in @(
            'Get-ApplicationsByExactDisplayName',
            'Get-ApplicationsByExactClientId',
            'Get-VerificationGrants',
            'Invoke-ExactVerificationGraphGetOrNull',
            'Get-ExactVerificationGrantById',
            'Get-ExactVerificationServicePrincipalById',
            'Get-ExactVerificationApplicationById',
            'Wait-ExactVerificationObjectAbsent'
        )) {
            $functionAst = @($script:VerificationAst.FindAll({
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

            $checkpointIndex = $script:VerificationSource.IndexOf($Checkpoint, [StringComparison]::Ordinal)
            $saveIndex = $script:VerificationSource.IndexOf(
                'Save-FirstRegistrationVerificationState',
                $checkpointIndex,
                [StringComparison]::Ordinal)
            $mutationIndex = $script:VerificationSource.IndexOf(
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
        $script:VerificationSource | Should -Match 'Connect-BootstrapAzure'
        $script:VerificationSource | Should -Match '-NonInteractive'
        $script:VerificationSource | Should -Not -Match "'account', 'show', '--subscription'"
        $script:VerificationSource | Should -Match "subscriptionId = \`$ExpectedSubscriptionId"
        $script:VerificationSource | Should -Match "tenantId = \`$ExpectedTenantId"
        $script:VerificationSource | Should -Match "\[string\]\`$azureIdentity\.subscriptionId -cne \`$ExpectedSubscriptionId"
        $script:VerificationSource | Should -Match "\[string\]\`$azureIdentity\.tenantId -cne \`$ExpectedTenantId"
        $script:VerificationSource | Should -Match "\[string\]\`$azureIdentity\.userObjectId -cne \`$TenantUserObjectId"
    }

    It 'requires the exact v2 custom scope four user-only roles and assigned administrator' {
        $script:VerificationSource | Should -Match 'requestedAccessTokenVersion -ne 2'
        $script:VerificationSource | Should -Match "allowedMemberTypes\[0\] -cne 'User'"
        $script:VerificationSource | Should -Match "@\(\`$Application\.appRoles\)\.Count -ne 4"
        $script:VerificationSource | Should -Match 'Assert-BootstrapApplicationOwnership'
        $script:VerificationSource | Should -Match 'Assert-ExactBootstrapServicePrincipalBoundary'
        $script:VerificationSource | Should -Match ([regex]::Escape(
            '-ExpectedAppRoleAssigneePrincipalId $TenantUserObjectId'))
        $script:VerificationSource | Should -Match 'Assert-GatewayApiDelegatedPermissionBoundary'
        $script:VerificationSource | Should -Match '-RequireComplete'
        $script:VerificationSource | Should -Not -Match "allowedMemberTypes\s*=\s*@\('Application'"
    }

    It 'creates a credential-free loopback app with one exact owner and empty local SP authority' {
        $script:VerificationSource | Should -Match "publicClient = @\{ redirectUris = @\('http://localhost'\) \}"
        $script:VerificationSource | Should -Match 'isFallbackPublicClient = \$false'
        $script:VerificationSource | Should -Match 'passwordCredentials\)\.Count -ne 0'
        $script:VerificationSource | Should -Match 'keyCredentials\)\.Count -ne 0'
        $script:VerificationSource | Should -Match "type = 'Scope'"
        $script:VerificationSource | Should -Match 'Assert-ExactTemporaryApplicationOwner'
        $script:VerificationSource | Should -Match 'must have exactly the pinned administrator as owner'
        $script:VerificationSource | Should -Match 'ExpectedAppRoles @\(\)'
        $script:VerificationSource | Should -Match 'ExpectedOauth2PermissionScopes @\(\)'
    }

    It 'uses one principal-specific access_as_user grant and never broad tenant consent' {
        $script:VerificationSource | Should -Match "consentType = 'Principal'"
        $script:VerificationSource | Should -Match 'principalId = \$TenantUserObjectId'
        $script:VerificationSource | Should -Match "scope = 'access_as_user'"
        $script:VerificationSource | Should -Not -Match "consentType = 'AllPrincipals'"
        $script:VerificationSource | Should -Not -Match 'AzureCliCredential'
        $script:VerificationSource | Should -Not -Match "account', 'get-access-token"
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
        Get-VerificationGrants -ClientServicePrincipalId '22222222-2222-2222-2222-222222222222' | Out-Null

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
        Invoke-ExactVerificationGraphGetOrNull `
            -Url 'https://graph.microsoft.com/v1.0/applications/11111111-1111-1111-1111-111111111111' |
            Should -BeNullOrEmpty

        Mock Invoke-AzJson {
            throw 'Microsoft Graph request returned HTTP 500; provider body was suppressed.'
        }
        {
            Invoke-ExactVerificationGraphGetOrNull `
                -Url 'https://graph.microsoft.com/v1.0/applications/11111111-1111-1111-1111-111111111111'
        } | Should -Throw '*HTTP 500*'

        $script:ExactReadCount = 0
        Mock Start-Sleep { }
        Wait-ExactVerificationObjectAbsent -ReadExact {
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

        Get-ExactVerificationGrantById -GrantId 'safe_grant_id' | Out-Null
        Get-ExactVerificationServicePrincipalById `
            -ServicePrincipalId '11111111-1111-1111-1111-111111111111' | Out-Null
        Get-ExactVerificationApplicationById `
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
            -Mutation '& dotnet @verificationArguments'

        ([regex]::Matches($script:VerificationSource, [regex]::Escape(
            "Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/applications'"))).Count | Should -Be 1
        ([regex]::Matches($script:VerificationSource, [regex]::Escape('/owners/`$ref'))).Count | Should -Be 1
        ([regex]::Matches($script:VerificationSource, [regex]::Escape(
            "Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/servicePrincipals'"))).Count | Should -Be 1
        ([regex]::Matches($script:VerificationSource, [regex]::Escape(
            "Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants'"))).Count | Should -Be 1
        ([regex]::Matches($script:VerificationSource, [regex]::Escape("-Method 'PATCH'"))).Count | Should -Be 1
        ([regex]::Matches($script:VerificationSource, [regex]::Escape('& dotnet @verificationArguments'))).Count | Should -Be 1
        $script:VerificationSource | Should -Match 'This Started stage is GET-only'
        $script:VerificationSource | Should -Match 'will not be repeated'
    }

    It 'binds recovery to atomic safe-ID state exact executable hashes and an immutable tombstone' {
        $script:VerificationSource | Should -Match '\.bootstrap/verification/'
        $script:VerificationSource | Should -Match 'Enter-BootstrapLock'
        $script:VerificationSource | Should -Match 'wrapperSha256'
        $script:VerificationSource | Should -Match 'helperBundleSha256'
        $script:VerificationSource | Should -Match 'verificationBundleSha256'
        $script:VerificationSource | Should -Match 'promptShieldExpected'
        $script:VerificationSource | Should -Match 'purviewExpected'
        $script:StateSource | Should -Match "'promptShieldExpected'"
        $script:StateSource | Should -Match "'purviewExpected'"
        $script:StateSource | Should -Match "promptShieldExpected -cnotmatch '\^\(true\|false\)\$'"
        $script:StateSource | Should -Match "purviewExpected -cnotmatch '\^\(true\|false\)\$'"
        $script:VerificationSource | Should -Match 'Get-ChildItem -LiteralPath \$verificationOutput -Recurse -File'
        $script:VerificationSource | Should -Match 'GetRelativePath\(\$verificationOutput'
        $script:VerificationSource | Should -Match 'bootstrap/modules/Common\.psm1'
        $script:VerificationSource | Should -Match 'operations/FirstRegistrationVerificationState\.psm1'
        $script:VerificationSource | Should -Match "status -cne 'CredentialObserved'"
        $script:VerificationSource | Should -Match 'recoveryCredentialId -cne \$RecoveryCredentialId'
        $script:VerificationSource | Should -Match "status -ceq 'Completed'"
        $script:StateSource | Should -Match 'Completed = @\(\)'
        $script:StateSource | Should -Match '\$stream\.Flush\(\$true\)'
        $script:StateSource | Should -Match '\[IO\.File\]::Move\(\$temporary, \$fullPath, \$true\)'
    }

    It 'preserves every durable nonterminal resume before Azure validation and always releases its lock' {
        $preservationCheck = $script:VerificationSource.IndexOf(
            'Test-FirstRegistrationVerificationStateRequiresPreservation',
            [StringComparison]::Ordinal)
        $preserve = $script:VerificationSource.IndexOf(
            '$preserveTemporaryIdentity = $true',
            $preservationCheck,
            [StringComparison]::Ordinal)
        $connect = $script:VerificationSource.IndexOf(
            'Connect-BootstrapAzure',
            $preservationCheck,
            [StringComparison]::Ordinal)
        $preservationCheck | Should -BeGreaterOrEqual 0
        $preserve | Should -BeGreaterThan $preservationCheck
        $connect | Should -BeGreaterThan $preserve
        $script:VerificationSource | Should -Match 'RESUME REQUIRED'
        $script:VerificationSource | Should -Match '\$verificationLock\.Dispose\(\)'
        $script:VerificationSource | Should -Match 'finally \{\s*if \(\$null -ne \$verificationLock\)'
    }

    It 'persists an issued ID before rendering it and completes before enabling cleanup' {
        $observed = $script:VerificationSource.IndexOf("-Status 'CredentialObserved'", [StringComparison]::Ordinal)
        $save = $script:VerificationSource.IndexOf('Save-FirstRegistrationVerificationState', $observed, [StringComparison]::Ordinal)
        $render = $script:VerificationSource.IndexOf('Write-Host $childLine', $observed, [StringComparison]::Ordinal)
        $completed = $script:VerificationSource.IndexOf("-Status 'Completed'", $observed, [StringComparison]::Ordinal)
        $completedSave = $script:VerificationSource.IndexOf('Save-FirstRegistrationVerificationState', $completed, [StringComparison]::Ordinal)
        $cleanupEnabled = $script:VerificationSource.IndexOf(
            '$preserveTemporaryIdentity = $false',
            $completed,
            [StringComparison]::Ordinal)
        $save | Should -BeGreaterThan $observed
        $render | Should -BeGreaterThan $save
        $completedSave | Should -BeGreaterThan $completed
        $cleanupEnabled | Should -BeGreaterThan $completedSave
    }

    It 'uses InteractiveBrowserUser and RevokeOnly without accepting a token argument' {
        $script:VerificationSource | Should -Match "'--authentication-mode', 'InteractiveBrowserUser'"
        $script:VerificationSource | Should -Match "'--authentication-client-id', \`$temporaryApplicationClientId"
        $script:VerificationSource | Should -Match "'--api-scope-base-uri', \`$expectedScopeBaseUri"
        $script:VerificationSource | Should -Match "\`$operationMode = if \(\`$recoveryMode\) \{ 'RevokeOnly' \} else \{ 'Full' \}"
        $script:VerificationSource | Should -Match "'--recovery-credential-id', \`$RecoveryCredentialId"
        $script:VerificationSource | Should -Not -Match '(?i)--access-token|--bearer|authorization-header'
        $script:LiveVerificationSource | Should -Match 'if \(options\.OperationMode == VerificationOperationMode\.RevokeOnly\)'
    }

    It 'binds exact protection expectations and keeps the minimal-profile ingestion proof unconditional' {
        $script:VerificationSource | Should -Match '\[switch\]\$ExpectPromptShieldEnabled'
        $script:VerificationSource | Should -Match '\[switch\]\$ExpectPurviewEnabled'
        $script:VerificationSource | Should -Match ([regex]::Escape(
            'promptShieldExpected = ([bool]$ExpectPromptShieldEnabled).ToString().ToLowerInvariant()'))
        $script:VerificationSource | Should -Match ([regex]::Escape(
            'purviewExpected = ([bool]$ExpectPurviewEnabled).ToString().ToLowerInvariant()'))
        $script:VerificationSource | Should -Match ([regex]::Escape(
            "'--expect-prompt-shield-enabled', ([bool]`$ExpectPromptShieldEnabled).ToString().ToLowerInvariant()"))
        $script:VerificationSource | Should -Match ([regex]::Escape(
            "'--expect-purview-enabled', ([bool]`$ExpectPurviewEnabled).ToString().ToLowerInvariant()"))

        $script:LiveVerificationSource | Should -Match 'RequiredBoolean\(values, "expect-prompt-shield-enabled"\)'
        $script:LiveVerificationSource | Should -Match 'RequiredBoolean\(values, "expect-purview-enabled"\)'
        $script:LiveVerificationSource | Should -Match 'must be canonical lowercase true or false'

        $allowed = $script:LiveVerificationSource.IndexOf(
            'ValidateAllowedEvaluation(await EvaluateAsync(',
            [StringComparison]::Ordinal)
        $activity = $script:LiveVerificationSource.IndexOf(
            '"api/v1/agent-activities"',
            [StringComparison]::Ordinal)
        $interaction = $script:LiveVerificationSource.IndexOf(
            '"api/v1/ai-interactions"',
            [StringComparison]::Ordinal)
        $conditionalBlock = $script:LiveVerificationSource.IndexOf(
            'if (options.ExpectPromptShieldEnabled)',
            [StringComparison]::Ordinal)
        $allowed | Should -BeGreaterOrEqual 0
        $activity | Should -BeGreaterThan $allowed
        $interaction | Should -BeGreaterThan $activity
        $conditionalBlock | Should -BeGreaterThan $interaction
        $script:LiveVerificationSource | Should -Match 'Prompt Shields injection-block proof was not attempted'
        $script:LiveVerificationSource | Should -Match 'Live Gateway verification completed'
    }

    It 'redacts provider failures and never renders clear credentials tokens or dependency bodies' {
        $script:LiveVerificationSource | Should -Match 'provider details were suppressed'
        $script:LiveVerificationSource | Should -Not -Match 'exception\.Message|Exception\.Message'
        $script:LiveVerificationSource | Should -Not -Match 'Console\.WriteLine\(credentialKey'
        $script:LiveVerificationSource | Should -Not -Match 'Console\.WriteLine\(token\.Token'
        $script:VerificationCode | Should -Not -Match '(?i)servicebus|queue|peek|receive|deadletter|purge'
        $script:VerificationCode | Should -Not -Match '(?i)clientsecret|password\s*=|apikey|credentialKey'
        $script:VerificationCode | Should -Not -Match 'Write-(Host|Output).*(token|secret|key)'
    }

    It 'performs only reverse-order exact cleanup after revocation or a Completed tombstone' {
        $grant = $script:VerificationSource.IndexOf("@{ label = 'delegated grant'", [StringComparison]::Ordinal)
        $principal = $script:VerificationSource.IndexOf("@{ label = 'service principal'", [StringComparison]::Ordinal)
        $application = $script:VerificationSource.IndexOf("@{ label = 'active application'", [StringComparison]::Ordinal)
        $finally = $script:VerificationSource.IndexOf("finally {`n    try {", [StringComparison]::Ordinal)
        $grant | Should -BeGreaterThan $finally
        $principal | Should -BeGreaterThan $grant
        $application | Should -BeGreaterThan $principal
        $script:VerificationSource | Should -Match 'Get-ExactVerificationGrantById'
        $script:VerificationSource | Should -Match 'Get-ExactVerificationServicePrincipalById'
        $script:VerificationSource | Should -Match 'Get-ExactVerificationApplicationById'
        $script:VerificationSource | Should -Match 'could not be proven absent by exact ID after deletion'
        $script:VerificationSource | Should -Match 'different client or name authority remains'
    }

    It 'keeps direct native execution limited to the reviewed dotnet child' {
        $commands = @($script:VerificationAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand
        }, $true))
        $directNames = @($commands | ForEach-Object { $_.CommandElements[0].Extent.Text } | Sort-Object -Unique)
        $directNames | Should -Not -Contain 'az'
        $directNames | Should -Contain 'dotnet'
    }
}
