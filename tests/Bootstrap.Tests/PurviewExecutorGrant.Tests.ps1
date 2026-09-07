BeforeAll {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    foreach ($module in @('Common', 'Experience', 'Entra', 'PurviewExecutor', 'Verification')) {
        Import-Module "$root/bootstrap/modules/$module.psm1" -Force -DisableNameChecking
    }
    function New-CompletedGrantOperation($Intent, $Evidence) {
        return @{
            status = 'Completed'
            intentFingerprint = Get-BootstrapObjectFingerprint -InputObject $Intent
            evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $Evidence
        }
    }
}

Describe 'Real worker grant guards and fresh executor composition' {
    BeforeEach {
        $source = 'sha256:' + ('a' * 64)
        $owner = '11111111-1111-4111-8111-111111111111'
        $worker = '22222222-2222-4222-8222-222222222222'
        $api = '33333333-3333-4333-8333-333333333333'
        $runtimeId = '44444444-4444-4444-8444-444444444444'
        $executor = '55555555-5555-4555-8555-555555555555'
        $appId = '66666666-6666-4666-8666-666666666666'
        $objectId = '77777777-7777-4777-8777-777777777777'
        $graphId = '88888888-8888-4888-8888-888888888888'
        $config = @{
            tenantId = '99999999-9999-4999-8999-999999999999'
            subscriptionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            resourceGroupName = 'rg-grant-dev'; projectName = 'grant'; environment = 'dev'
            purview = @{ enabled = $true; authorityRequirementsAcknowledged = $true }
        }
        $workerRoles = @(
            'Application.Read.All', 'AppRoleAssignment.ReadWrite.All',
            'AgentIdentityBlueprint.Create', 'AgentIdentityBlueprint.AddRemoveCreds.All',
            'AgentIdentityBlueprintPrincipal.Create', 'AgentIdentityBlueprint.Read.All',
            'AgentIdentity.Create.All', 'AgentIdentity.Read.All'
        )
        $runtimeRoles = @('ProtectionScopes.Compute.User', 'Content.Process.User', 'ContentActivity.Write')
        $roles = @($workerRoles + $runtimeRoles | ForEach-Object {
            [pscustomobject]@{ id = [guid]::NewGuid().ToString('D'); value = $_; isEnabled = $true; allowedMemberTypes = @('Application') }
        })
        $scopes = @('AgentRegistration.Read.All', 'AgentRegistration.ReadWrite.All') | ForEach-Object {
            [pscustomobject]@{ id = [guid]::NewGuid().ToString('D'); value = $_; isEnabled = $true }
        }
        $graph = @{ id = $graphId; appId = '00000003-0000-0000-c000-000000000000'; appRoles = $roles; oauth2PermissionScopes = @($scopes) }
        $role = Get-PurviewExecutorRole
        $tags = @(Get-BootstrapApplicationTags -DeploymentOwnershipId $owner) + @("A365GatewaySource:$source", 'A365GatewayPurviewExecutor')
        $name = "A365 Gateway Purview Executor - $owner"
        $ctx = @{
            deploymentOwnershipId = $owner; sourceFingerprint = $source
            configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $config
            planFingerprint = 'sha256:' + ('b' * 64)
            tenantId = $config.tenantId; subscriptionId = $config.subscriptionId; resourceGroupName = $config.resourceGroupName
            workerPrincipalId = $worker; workerApplicationId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        }
        $identity = @{ applicationObjectId = $objectId; applicationId = $appId; servicePrincipalId = $executor; roleAssignmentId = 'exact-assignment' }
        $operations = [ordered]@{
            application = New-CompletedGrantOperation @{ name = $name; tags = $tags; role = $role; tenantId = $config.tenantId } @{ objectId = $objectId; applicationId = $appId }
            audience = New-CompletedGrantOperation @{ objectId = $objectId; audience = "api://$appId" } @{ audience = "api://$appId" }
            principal = New-CompletedGrantOperation @{ applicationId = $appId; tags = $tags; assignmentRequired = $true } @{ objectId = $executor; applicationId = $appId }
            invokeRole = New-CompletedGrantOperation @{ principalId = $worker; resourceId = $executor; appRoleId = $role.id } @{ id = 'exact-assignment' }
        }
        $inert = @{
            workerPrincipalId = $worker; apiPrincipalId = $api; runtimeImagePullIdentityPrincipalId = $runtimeId
            deploymentOwnershipId = $owner; sourceFingerprint = $source
        }
        $state = @{
            deploymentOwnershipId = $owner; configurationFingerprint = $ctx.configurationFingerprint
            acceptedPlan = @{ sourceFingerprint = $source; configurationFingerprint = $ctx.configurationFingerprint; planFingerprint = $ctx.planFingerprint }
            freshPurviewExecutor = @{ schemaVersion = 1; status = 'Installed'; context = $ctx; operations = $operations; identity = $identity }
            steps = @{}
        }
        $workerAssignments = @($roles | Where-Object value -in $workerRoles | ForEach-Object {
            @{ id = "assignment-$($_.id)"; principalId = $worker; resourceId = $graphId; appRoleId = $_.id }
        })
        $executorAssignment = @{ id = 'exact-assignment'; principalId = $worker; resourceId = $executor; appRoleId = $role.id; principalType = 'ServicePrincipal' }
        $apiRole = $roles | Where-Object value -eq 'AgentIdentityBlueprint.Read.All'
        $evidence = @{
            workerApplicationRoles = @{}; apiApplicationRoles = @{ 'AgentIdentityBlueprint.Read.All' = $apiRole.id }
            apiHostApplicationRoles = @{ 'AgentIdentityBlueprint.Read.All' = $apiRole.id }; purviewRuntimeApplicationRoles = @{}
            delegatedRegistryScopes = @($scopes.value); federatedCredentialName = 'a365gw-grant-api-obo-dev'
            purviewRuntimeIdentityResourceId = 'runtime-resource'; purviewRuntimeManagedIdentityClientId = 'runtime-client'
            purviewRuntimeManagedIdentityPrincipalId = $runtimeId
        }
        foreach ($r in $roles | Where-Object value -in $workerRoles) { $evidence.workerApplicationRoles[$r.value] = $r.id }
        foreach ($r in $roles | Where-Object value -in $runtimeRoles) {
            $evidence.purviewRuntimeApplicationRoles[$r.value] = $r.id
            $evidence.apiApplicationRoles[$r.value] = $r.id
        }
        $state.steps['Workflow v3 Entra configuration'] = @{ evidence = $evidence }
        $script:f = @{
            source = $source; config = $config; state = $state; runtime = $inert; graph = $graph; workerRoles = $workerRoles
            grant = $executorAssignment; workerAssignments = $workerAssignments + @($executorAssignment)
            apiAssignments = @(@{ id = 'api-assignment'; principalId = $api; resourceId = $graphId; appRoleId = $apiRole.id })
            runtimeAssignments = @($roles | Where-Object value -in $runtimeRoles | ForEach-Object {
                @{ id = "runtime-$($_.id)"; principalId = $runtimeId; resourceId = $graphId; appRoleId = $_.id }
            })
            app = @{
                id = $objectId; appId = $appId; displayName = $name; signInAudience = 'AzureADMyOrg'; tags = $tags
                identifierUris = @("api://$appId"); appRoles = @($role); requiredResourceAccess = @()
                passwordCredentials = @(); keyCredentials = @(); isFallbackPublicClient = $false
                api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(); acceptMappedClaims = $false }
                web = @{ redirectUris = @() }; spa = @{ redirectUris = @() }; publicClient = @{ redirectUris = @() }
            }
            sp = @{
                id = $executor; appId = $appId; servicePrincipalType = 'Application'; accountEnabled = $true
                appRoleAssignmentRequired = $true; tags = $tags; servicePrincipalNames = @($appId, "api://$appId")
                appRoles = @($role); passwordCredentials = @(); keyCredentials = @(); oauth2PermissionScopes = @(); alternativeNames = @()
            }
            gatewayIdentity = @{ gatewayApiApplicationObjectId = 'gateway-object'; gatewayApiClientId = 'gateway-client'; gatewayApiServicePrincipalId = 'gateway-principal' }
            evidence = $evidence
        }
        $script:verificationContext = @{ Configuration = $config; State = $state; Runtime = $inert }
        # Only provider/source metadata reads are replaced. Every permission guard,
        # executor ownership/intent check and workflow wrapper below is real.
        Mock Get-GraphPermissionCatalog -ModuleName Entra { @{ servicePrincipal = $script:f.graph } }
        Mock Get-BootstrapSourceFingerprint -ModuleName PurviewExecutor { $script:f.source }
        Mock Get-ExactApplicationByDisplayName -ModuleName PurviewExecutor { $script:f.app }
        Mock Get-ServicePrincipalByAppId -ModuleName PurviewExecutor { $script:f.sp }
        Mock Invoke-AzJson -ModuleName PurviewExecutor {
            @{ id = $script:f.runtime.workerPrincipalId; appId = $script:f.state.freshPurviewExecutor.context.workerApplicationId; servicePrincipalType = 'ManagedIdentity' }
        }
        Mock Get-BoundedGraphCollection -ModuleName PurviewExecutor {
            if ($InitialUrl -match '/appRoleAssignedTo$') { return @($script:f.grant) }
            if ($InitialUrl -match '/(federatedIdentityCredentials|appRoleAssignments|transitiveMemberOf)$') { return @() }
            throw 'Unexpected executor metadata read.'
        }
        Mock Invoke-GraphJsonBody -ModuleName PurviewExecutor { throw 'Verification must not mutate.' }
        Mock Get-BoundedGraphCollection -ModuleName Entra {
            if ($InitialUrl -match "/$($script:f.runtime.workerPrincipalId)/appRoleAssignments") { return $script:f.workerAssignments }
            if ($InitialUrl -match "/$($script:f.runtime.apiPrincipalId)/appRoleAssignments") { return $script:f.apiAssignments }
            if ($InitialUrl -match "/$($script:f.runtime.runtimeImagePullIdentityPrincipalId)/appRoleAssignments") { return $script:f.runtimeAssignments }
            throw 'Unexpected Entra metadata read.'
        }
        Mock Get-GatewayPurviewRuntimeManagedIdentity -ModuleName Entra {
            @{ resourceId = 'runtime-resource'; clientId = 'runtime-client'; principalId = $script:f.runtime.runtimeImagePullIdentityPrincipalId }
        }
        Mock Get-BoundedGraphCollection -ModuleName Experience {
            if ($InitialUrl -match '/servicePrincipals\?\$filter=appId') { return @($script:f.graph) }
            if ($InitialUrl -match "/$($script:f.runtime.workerPrincipalId)/appRoleAssignments") { return $script:f.workerAssignments }
            if ($InitialUrl -match "/$($script:f.runtime.apiPrincipalId)/appRoleAssignments") { return $script:f.apiAssignments }
            if ($InitialUrl -match '/oauth2PermissionGrants\?') {
                return @(@{ resourceId = $script:f.graph.id; consentType = 'AllPrincipals'; scope = 'AgentRegistration.Read.All AgentRegistration.ReadWrite.All' })
            }
            if ($InitialUrl -match '/federatedIdentityCredentials\?') {
                return @(@{ name = $script:f.evidence.federatedCredentialName; issuer = "https://login.microsoftonline.com/$($script:f.config.tenantId)/v2.0"
                    subject = $script:f.runtime.apiPrincipalId; audiences = @('api://AzureADTokenExchange') })
            }
            throw 'Unexpected workflow metadata read.'
        }
        Mock Invoke-AzJson -ModuleName Experience {
            @{ appId = 'gateway-client'; requiredResourceAccess = @(@{ resourceAppId = $script:f.graph.appId
                resourceAccess = @($script:f.graph.oauth2PermissionScopes | ForEach-Object { @{ id = $_.id; type = 'Scope' } }) }) }
        }
    }

    It 'reproduces the original strict Graph-only rejection of the required ninth grant' {
        $script:f.graph.appRoles.Count | Should -Be 11
        @($script:f.graph.appRoles | Where-Object value -eq 'Application.Read.All').Count | Should -Be 1
        Entra\Get-UniqueGraphPermissionId -Graph $script:f.graph -Value 'Application.Read.All' -Type Role | Should -Not -BeNullOrEmpty
        { Entra\Assert-ExactGraphApplicationRoleAssignments -PrincipalId $script:f.runtime.workerPrincipalId -ExpectedRoleValues $script:f.workerRoles } |
            Should -Throw '*outside the exact reviewed*'
    }

    It 'accepts eight Graph roles plus one exact independently verified owned executor grant' {
        Entra\Assert-ExactGraphApplicationRoleAssignments -PrincipalId $script:f.runtime.workerPrincipalId `
            -ExpectedRoleValues $script:f.workerRoles -PurviewExecutorContext $script:verificationContext | Should -BeTrue
        Should -Invoke Invoke-GraphJsonBody -ModuleName PurviewExecutor -Times 0 -Exactly
    }

    It 'rejects a wrong <Field> on the worker grant even if resource-side readback remains correct' -ForEach @(
        @{ Field = 'resourceId' }, @{ Field = 'appRoleId' }, @{ Field = 'principalId' }, @{ Field = 'id' }
    ) {
        $script:f.workerAssignments[-1] = @{} + $script:f.grant
        $script:f.workerAssignments[-1][$Field] = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        { Entra\Assert-ExactGraphApplicationRoleAssignments -PrincipalId $script:f.runtime.workerPrincipalId `
            -ExpectedRoleValues $script:f.workerRoles -PurviewExecutorContext $script:verificationContext } | Should -Throw
        { Verification\Assert-GatewayRuntimeGraphRoleAssignments -Config $script:f.config -Runtime $script:f.runtime -State $script:f.state } | Should -Throw
        { Entra\Test-GatewayWorkflowIdentityEvidence -Config $script:f.config -Identity $script:f.gatewayIdentity `
            -Inert $script:f.runtime -Evidence $script:f.evidence -State $script:f.state } | Should -Throw
    }

    It 'rejects duplicate <Kind> assignments' -ForEach @(@{ Kind = 'Graph' }, @{ Kind = 'Executor' }) {
        $script:f.workerAssignments += if ($Kind -eq 'Graph') { $script:f.workerAssignments[0] } else { $script:f.grant }
        { Entra\Assert-ExactGraphApplicationRoleAssignments -PrincipalId $script:f.runtime.workerPrincipalId `
            -ExpectedRoleValues $script:f.workerRoles -PurviewExecutorContext $script:verificationContext } | Should -Throw
        { Verification\Assert-GatewayRuntimeGraphRoleAssignments -Config $script:f.config -Runtime $script:f.runtime -State $script:f.state } | Should -Throw
        { Entra\Test-GatewayWorkflowIdentityEvidence -Config $script:f.config -Identity $script:f.gatewayIdentity `
            -Inert $script:f.runtime -Evidence $script:f.evidence -State $script:f.state } | Should -Throw
    }

    It 'rejects mismatched accepted <Field> binding before trusting the grant' -ForEach @(
        @{ Field = 'deploymentOwnershipId' }, @{ Field = 'sourceFingerprint' }, @{ Field = 'configurationFingerprint' },
        @{ Field = 'planFingerprint' }, @{ Field = 'workerPrincipalId' }, @{ Field = 'tenantId' },
        @{ Field = 'subscriptionId' }, @{ Field = 'resourceGroupName' }
    ) {
        $script:f.state.freshPurviewExecutor.context[$Field] = 'not-the-accepted-value'
        { Entra\Assert-ExactGraphApplicationRoleAssignments -PrincipalId $script:f.runtime.workerPrincipalId `
            -ExpectedRoleValues $script:f.workerRoles -PurviewExecutorContext $script:verificationContext } | Should -Throw
    }

    It 'rejects an executor identity whose independently read ownership tags changed' {
        $script:f.sp.tags = @('unowned')
        { Entra\Assert-ExactGraphApplicationRoleAssignments -PrincipalId $script:f.runtime.workerPrincipalId `
            -ExpectedRoleValues $script:f.workerRoles -PurviewExecutorContext $script:verificationContext } | Should -Throw
    }

    It 'rejects missing or ambiguous executor authority rather than silently falling back to eight' {
        $script:f.grant = $null
        $script:f.workerAssignments = @($script:f.workerAssignments | Select-Object -First 8)
        { Entra\Assert-ExactGraphApplicationRoleAssignments -PrincipalId $script:f.runtime.workerPrincipalId `
            -ExpectedRoleValues $script:f.workerRoles -PurviewExecutorContext $script:verificationContext } | Should -Throw
    }

    It 'permits observed exact grant after Started without mutating the journal' {
        $script:f.state.freshPurviewExecutor.status = 'Installing'
        $script:f.state.freshPurviewExecutor.operations.invokeRole.status = 'Started'
        $before = Get-BootstrapObjectFingerprint -InputObject $script:f.state
        Entra\Assert-ExactGraphApplicationRoleAssignments -PrincipalId $script:f.runtime.workerPrincipalId `
            -ExpectedRoleValues $script:f.workerRoles -PurviewExecutorContext $script:verificationContext | Should -BeTrue
        (Get-BootstrapObjectFingerprint -InputObject $script:f.state) | Should -Be $before
    }

    It 'keeps pre-executor <Phase> exactly eight-only through final and workflow guards' -ForEach @(
        @{ Phase = 'NoRecord' }, @{ Phase = 'BeforeGrant' }, @{ Phase = 'Core' }
    ) {
        if ($Phase -eq 'BeforeGrant') {
            $script:f.state.freshPurviewExecutor.status = 'Installing'
            $script:f.state.freshPurviewExecutor.operations.Remove('invokeRole')
            $script:f.state.freshPurviewExecutor.Remove('identity')
        } else { $script:f.state.Remove('freshPurviewExecutor') }
        if ($Phase -eq 'Core') {
            $script:f.config.purview.enabled = $false
            $script:f.runtimeAssignments = @()
            $script:f.evidence.apiApplicationRoles = $script:f.evidence.apiHostApplicationRoles
        }
        $script:f.workerAssignments = @($script:f.workerAssignments | Select-Object -First 8)
        { Verification\Assert-GatewayRuntimeGraphRoleAssignments -Config $script:f.config -Runtime $script:f.runtime -State $script:f.state } | Should -Not -Throw
        Entra\Test-GatewayWorkflowIdentityEvidence -Config $script:f.config -Identity $script:f.gatewayIdentity `
            -Inert $script:f.runtime -Evidence $script:f.evidence -State $script:f.state | Should -BeTrue
        $script:f.workerAssignments += $script:f.grant
        { Verification\Assert-GatewayRuntimeGraphRoleAssignments -Config $script:f.config -Runtime $script:f.runtime -State $script:f.state } | Should -Throw
        { Entra\Test-GatewayWorkflowIdentityEvidence -Config $script:f.config -Identity $script:f.gatewayIdentity `
            -Inert $script:f.runtime -Evidence $script:f.evidence -State $script:f.state } | Should -Throw
    }

    It 'never uses executor context to relax Core or another principal' {
        $script:f.config.purview.enabled = $false
        { Verification\Assert-GatewayRuntimeGraphRoleAssignments -Config $script:f.config -Runtime $script:f.runtime -State $script:f.state } | Should -Throw
        { Entra\Assert-ExactGraphApplicationRoleAssignments -PrincipalId $script:f.runtime.apiPrincipalId `
            -ExpectedRoleValues @('AgentIdentityBlueprint.Read.All') -PurviewExecutorContext $script:verificationContext } | Should -Throw
    }

    It 'composes the real final Verify guard with exact executor readback' {
        { Verification\Assert-GatewayRuntimeGraphRoleAssignments -Config $script:f.config -Runtime $script:f.runtime -State $script:f.state } | Should -Not -Throw
    }

    It 'composes Entra wrapper and Experience Resume checks after executor installation' {
        Entra\Test-GatewayWorkflowIdentityEvidence -Config $script:f.config -Identity $script:f.gatewayIdentity `
            -Inert $script:f.runtime -Evidence $script:f.evidence -State $script:f.state | Should -BeTrue
    }

    It 'rejects wrong Graph principal, missing Graph role, or unapproved Graph role in Verify and Resume' -ForEach @(
        @{ Drift = 'principalId' }, @{ Drift = 'missing' }, @{ Drift = 'appRoleId' }
    ) {
        if ($Drift -eq 'missing') { $script:f.workerAssignments = @($script:f.workerAssignments | Select-Object -Skip 1) }
        else { $script:f.workerAssignments[0][$Drift] = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
        { Verification\Assert-GatewayRuntimeGraphRoleAssignments -Config $script:f.config -Runtime $script:f.runtime -State $script:f.state } | Should -Throw
        { Entra\Test-GatewayWorkflowIdentityEvidence -Config $script:f.config -Identity $script:f.gatewayIdentity `
            -Inert $script:f.runtime -Evidence $script:f.evidence -State $script:f.state } | Should -Throw
    }

    It 'passes only applicable state through actual <Path> call sites for <Phase>' -ForEach @(
        @{ Path = 'ResumeAndWorkflow'; Phase = 'Installed' }, @{ Path = 'FinalVerify'; Phase = 'Installed' },
        @{ Path = 'ResumeAndWorkflow'; Phase = 'Prefix' }, @{ Path = 'FinalVerify'; Phase = 'Prefix' },
        @{ Path = 'ResumeAndWorkflow'; Phase = 'Core' }, @{ Path = 'FinalVerify'; Phase = 'Core' }
    ) {
        if ($Phase -ne 'Installed') {
            $script:f.state.Remove('freshPurviewExecutor')
            $script:f.workerAssignments = @($script:f.workerAssignments | Select-Object -First 8)
        }
        if ($Phase -eq 'Core') {
            $script:f.config.purview.enabled = $false
            $script:f.runtimeAssignments = @()
            $script:f.evidence.apiApplicationRoles = $script:f.evidence.apiHostApplicationRoles
        }
        $file = if ($Path -eq 'FinalVerify') { "$root/bootstrap/modules/Verification.psm1" } else { "$root/bootstrap/bootstrap.ps1" }
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
        $commandName = if ($Path -eq 'FinalVerify') { 'Assert-GatewayRuntimeGraphRoleAssignments' } else { 'Test-GatewayWorkflowIdentityEvidence' }
        $commands = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq $commandName
        }, $true))
        $commands.Count | Should -Be $(if ($Path -eq 'FinalVerify') { 1 } else { 2 })
        $Config = $script:f.config; $Configuration = $Config; $State = $script:f.state
        $Runtime = $script:f.runtime; $Inert = $Runtime; $Identity = $script:f.gatewayIdentity
        foreach ($command in $commands) {
            # Include the real conditional State splat in the two engine closures.
            $code = if ($Path -eq 'FinalVerify') { $command.Extent.Text } else {
                $command.Parent.Parent.Statements.Extent.Text -join "`n"
            }
            { & ([scriptblock]::Create($code)) } | Should -Not -Throw
            if ($Path -eq 'ResumeAndWorkflow' -and $Phase -ne 'Installed') {
                # Prove older accepted modules receive no newly added parameter.
                $setup = @($command.Parent.Parent.Statements | Select-Object -First 2).Extent.Text -join "`n"
                $parameters = & ([scriptblock]::Create("$setup`nreturn ,`$workflowIdentityParameters"))
                $parameters.Count | Should -Be 0
            }
        }
    }
}
