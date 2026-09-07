& {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    foreach ($module in @('Common', 'Experience', 'Azure', 'Entra', 'PurviewRecovery')) {
        Import-Module (Join-Path $root "bootstrap/modules/$module.psm1") -Force -DisableNameChecking
    }
}

Describe 'Purview prerequisite recovery preserves the accepted deployment' {
    InModuleScope PurviewRecovery {
        BeforeEach {
            $script:original = 'sha256:' + ('a' * 64)
            $script:corrected = 'sha256:' + ('b' * 64)
            $script:current = $script:corrected
            $script:owner = '11111111-1111-4111-8111-111111111111'
            $script:identity = [ordered]@{ tenantId = '22222222-2222-4222-8222-222222222222'
                subscriptionId = '33333333-3333-4333-8333-333333333333'; userObjectId = '44444444-4444-4444-8444-444444444444' }
            $script:config = [ordered]@{ tenantId = $script:identity.tenantId; subscriptionId = $script:identity.subscriptionId
                resourceGroupName = 'rg-safe'; projectName = 'safe'; environment = 'dev'; purview = @{ enabled = $true } }
            $script:state = [ordered]@{ deploymentOwnershipId = $script:owner
                deploymentKey = "$($script:config.subscriptionId)/rg-safe/dev"
                configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $script:config
                acceptedPlan = [ordered]@{ sourceFingerprint = $script:original; planFingerprint = 'sha256:' + ('c' * 64)
                    configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $script:config }
                steps = [ordered]@{} }
            foreach ($name in @(Get-GatewayBootstrapStepNames)[0..12]) {
                $script:state.steps[$name] = [ordered]@{ status = 'Completed'; evidence = [ordered]@{ verified = $true }
                    sourceFingerprint = $script:original; completedAtUtc = '2026-09-06T00:00:00.0000000+00:00' }
            }
            $script:state.steps['Azure authentication'].evidence = $script:identity
            $script:state.steps['Purview capability prerequisites'] = [ordered]@{ status = 'Failed'; sourceFingerprint = $script:original }
            $script:provider = [ordered]@{ binding = [ordered]@{ applicationObjectId = '55555555-5555-4555-8555-555555555555'
                    applicationId = '66666666-6666-4666-8666-666666666666'; servicePrincipalId = '77777777-7777-4777-8777-777777777777'
                    exchangeServicePrincipalId = '88888888-8888-4888-8888-888888888888'
                    exchangeRoleId = '455e5cd2-84e8-4751-8344-5672145dfa17'; complianceRoleDefinitionId = '17315797-102d-40b4-93e0-432062caca18'
                    keyVaultUri = 'https://kv-safe-dev.vault.azure.net/'; certificateSecretResourceId = '/safe/certificate'
                    certificateSecretUri = 'https://kv-safe-dev.vault.azure.net/secrets/purview-automation-certificate' }
                operations = [ordered]@{ ExchangeGrant = @{ status = 'Absent'; assignmentId = '' }
                    ComplianceGrant = @{ status = 'Absent'; assignmentId = '' }
                    Certificate = @{ status = 'Absent'; keyCredentialId = ''; evidenceFingerprint = '' } }
                automationEvidence = $null }
            Mock Assert-BootstrapAcceptedPlan { $true }
            Mock Assert-BootstrapPurviewRecoverySourceBoundary { $true }
            Mock Get-BootstrapSourceFingerprint { $script:current }
            Mock Get-RepositoryRoot { 'TestDrive:/' }
            Mock Resolve-GatewayCredentialDeploymentTemplate { 'TestDrive:/template.bicep' }
            Mock Get-FileHash { [pscustomobject]@{ Hash = 'e' * 64 } }
            Mock Get-BootstrapPurviewRecoveryProviderState { $script:provider }
            Mock New-BootstrapAcceptedSourceSnapshot {
                param($State, $PlanFingerprint, $SourceFingerprint)
                ".bootstrap/accepted-source/$($State.deploymentOwnershipId)/$($PlanFingerprint.Substring(7))"
            }
            Mock Save-BootstrapState { }
            Mock Invoke-GraphJsonBody { throw 'Unexpected mutation' }
            Mock New-BootstrapPurviewAutomationCertificate { throw 'Unexpected certificate mutation' }
            $script:recovery = New-BootstrapPurviewRecoveryPlan -State $script:state -Config $script:config -AzureIdentity $script:identity
        }

        It 'plans only the exact existing identity and preserves every original step' {
            $before = Get-BootstrapObjectFingerprint -InputObject $script:state
            $plan = New-BootstrapPurviewRecoveryPlan -State $script:state -Config $script:config -AzureIdentity $script:identity
            $plan.plan.completedPrefix.Count | Should -Be 13
            $plan.plan.binding.applicationObjectId | Should -BeExactly $script:provider.binding.applicationObjectId
            (Get-BootstrapObjectFingerprint -InputObject $script:state) | Should -BeExactly $before
            Should -Invoke Invoke-GraphJsonBody -Times 0
            Should -Invoke Save-BootstrapState -Times 0
        }

        It 'refuses the wrong completed-stage boundary before provider access' -ForEach @('Gateway database', 'Admin UI identity') {
            $script:state.steps[$_].status = 'Failed'
            { New-BootstrapPurviewRecoveryPlan -State $script:state -Config $script:config -AzureIdentity $script:identity } | Should -Throw '*prefix*'
            Should -Invoke Get-BootstrapPurviewRecoveryProviderState -Times 1
        }

        It 'refuses later work or another recovery generation' -ForEach @('Later', 'OtherRecovery') {
            if ($_ -ceq 'Later') { $script:state.steps['Gateway runtime deployment'] = @{ status = 'Running' } }
            else { $script:state.databaseRecoveryPlan = @{ status = 'Completed' } }
            { New-BootstrapPurviewRecoveryPlan -State $script:state -Config $script:config -AzureIdentity $script:identity } | Should -Throw
            Should -Invoke Save-BootstrapState -Times 0
        }

        It 'refuses already present certificates without creating a replacement' {
            $script:provider.operations.Certificate.status = 'Present'
            { New-BootstrapPurviewRecoveryPlan -State $script:state -Config $script:config -AzureIdentity $script:identity } | Should -Throw '*both certificate stores*'
            Should -Invoke New-BootstrapPurviewAutomationCertificate -Times 0
        }

        It 'plans and completes read-only reconciliation for exact complete prerequisites without replay' {
            $script:provider.operations.ExchangeGrant = @{ status = 'Present'; assignmentId = 'exact-exchange' }
            $script:provider.operations.ComplianceGrant = @{ status = 'Present'; assignmentId = 'exact-compliance' }
            $script:provider.operations.Certificate = @{ status = 'Present'; keyCredentialId = '99999999-9999-4999-8999-999999999999'; evidenceFingerprint = 'sha256:' + ('e' * 64) }
            $script:provider.automationEvidence = @{ status = 'Installed'; keyCredentialId = $script:provider.operations.Certificate.keyCredentialId }
            $reconciliation = New-BootstrapPurviewCompletePrerequisiteReconciliationPlan -State $script:state -Config $script:config -AzureIdentity $script:identity
            $script:state.purviewPrerequisiteReconciliation = $reconciliation
            (Invoke-BootstrapPurviewCompletePrerequisiteReconciliation -State $script:state -StatePath 'TestDrive:/state.json' `
                -Config $script:config -AzureIdentity $script:identity -Reconciliation $reconciliation `
                -ExpectedPlanFingerprint $reconciliation.planFingerprint -Yes).status | Should -BeExactly 'Completed'
            Should -Invoke Invoke-GraphJsonBody -Times 0
            Should -Invoke New-BootstrapPurviewAutomationCertificate -Times 0
            Assert-BootstrapPurviewCompletePrerequisiteReconciliationPlan -State $script:state `
                -Reconciliation $script:state.purviewPrerequisiteReconciliation -Completed | Should -Not -BeNullOrEmpty
            $restarted = [ordered]@{}
            foreach ($entry in $script:state.GetEnumerator()) { $restarted[$entry.Key] = $entry.Value }
            $restarted.purviewPrerequisiteReconciliation = $script:state.purviewPrerequisiteReconciliation |
                ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
            $restarted.purviewPrerequisiteReconciliation.status | Should -BeExactly 'Completed'
            $restarted.purviewPrerequisiteReconciliation.completionFingerprint |
                Should -BeExactly $reconciliation.completionFingerprint
            $restarted.purviewPrerequisiteReconciliation.providerEvidenceFingerprint |
                Should -BeExactly $reconciliation.providerEvidenceFingerprint
        }

        It 'rejects tampered complete-prerequisite reconciliation receipts' {
            $script:provider.operations.ExchangeGrant = @{ status = 'Present'; assignmentId = 'exact-exchange' }
            $script:provider.operations.ComplianceGrant = @{ status = 'Present'; assignmentId = 'exact-compliance' }
            $script:provider.operations.Certificate = @{ status = 'Present'; keyCredentialId = '99999999-9999-4999-8999-999999999999'; evidenceFingerprint = 'sha256:' + ('e' * 64) }
            $script:provider.automationEvidence = @{ status = 'Installed'; keyCredentialId = $script:provider.operations.Certificate.keyCredentialId }
            $reconciliation = New-BootstrapPurviewCompletePrerequisiteReconciliationPlan -State $script:state -Config $script:config -AzureIdentity $script:identity
            $reconciliation.plan.binding.applicationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            { Assert-BootstrapPurviewCompletePrerequisiteReconciliationPlan -State $script:state -Reconciliation $reconciliation } | Should -Throw
            Should -Invoke Save-BootstrapState -Times 0
        }

        It 'rejects partial complete-prerequisite provider state' {
            $script:provider.operations.ExchangeGrant = @{ status = 'Present'; assignmentId = 'exact-exchange' }
            $script:provider.operations.ComplianceGrant = @{ status = 'Absent'; assignmentId = '' }
            $script:provider.operations.Certificate = @{ status = 'Present'; keyCredentialId = '99999999-9999-4999-8999-999999999999'; evidenceFingerprint = 'sha256:' + ('e' * 64) }
            $script:provider.automationEvidence = @{ status = 'Installed'; keyCredentialId = $script:provider.operations.Certificate.keyCredentialId }
            { New-BootstrapPurviewCompletePrerequisiteReconciliationPlan -State $script:state -Config $script:config -AzureIdentity $script:identity } |
                Should -Throw '*every existing certificate and grant*'
            Should -Invoke Invoke-GraphJsonBody -Times 0
            Should -Invoke New-BootstrapPurviewAutomationCertificate -Times 0
        }

        It 'validates a complete immutable plan' {
            Assert-BootstrapPurviewRecoveryPlan -State $script:state -Recovery $script:recovery | Should -Not -BeNullOrEmpty
        }

        It 'composes the three mutations, completion receipt and subsequent stage reconciliation' {
            $originalSteps = Get-BootstrapObjectFingerprint -InputObject $script:state.steps
            Mock Invoke-GraphJsonBody {
                param($Method, $Url, $Body)
                if ($Url -like '*/appRoleAssignments') { $script:provider.operations.ExchangeGrant = @{ status = 'Present'; assignmentId = 'exact-exchange' } }
                elseif ($Url -like '*/directory/roleAssignments') { $script:provider.operations.ComplianceGrant = @{ status = 'Present'; assignmentId = 'exact-compliance' } }
                else { throw 'Unexpected Graph mutation target' }
            }
            Mock New-BootstrapPurviewAutomationCertificate {
                param($KeyCredentialId)
                $script:provider.automationEvidence = @{ status = 'Installed'; keyCredentialId = $KeyCredentialId }
                $script:provider.operations.Certificate = @{ status = 'Present'; keyCredentialId = $KeyCredentialId
                    evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $script:provider.automationEvidence }
            }
            Mock Get-GatewayPurviewCapabilityEvidence { @{ status = 'Installed' } }
            Mock Get-GatewayBootstrapCapabilityEvidence { [ordered]@{ readbackAtUtc = '2026-09-06T00:00:00.0000000+00:00'; purview = @{ status = 'Installed' } } }
            $result = Invoke-BootstrapPurviewRecovery -State $script:state -StatePath 'TestDrive:/state.json' -Config $script:config `
                -AzureIdentity $script:identity -Recovery $script:recovery -ExpectedPlanFingerprint $script:recovery.planFingerprint -Yes
            $result.status | Should -BeExactly 'Completed'
            (Get-BootstrapObjectFingerprint -InputObject $script:state.steps) | Should -BeExactly $originalSteps
            Should -Invoke Invoke-GraphJsonBody -Times 2 -Exactly
            Should -Invoke New-BootstrapPurviewAutomationCertificate -Times 1 -Exactly
            $receipt = $script:state.purviewPrerequisiteRecoveryPlan
            Assert-BootstrapPurviewRecoveryPlan -State $script:state -Recovery $receipt -Completed | Should -Not -BeNullOrEmpty
            foreach ($name in @(Get-GatewayBootstrapStepNames)[0..1]) {
                foreach ($status in @('Running', 'Failed')) {
                    $script:state.steps[$name].status = $status
                    Assert-BootstrapPurviewRecoveryPlan -State $script:state -Recovery $receipt -Completed | Should -Not -BeNullOrEmpty
                }
                $script:state.steps[$name].status = 'Completed'
            }
            foreach ($name in @(Get-GatewayBootstrapStepNames)[0..1]) { $script:state.steps[$name].completedAtUtc = '2026-09-06T01:00:00.0000000+00:00' }
            $script:state.steps['Purview capability prerequisites'] = [ordered]@{ status = 'Completed'; sourceFingerprint = $script:original
                evidence = [ordered]@{ readbackAtUtc = '2026-09-06T02:00:00.0000000+00:00'; purview = @{ status = 'Installed' } } }
            $script:state.steps['Gateway runtime deployment'] = @{ status = 'Completed' }
            Assert-BootstrapPurviewRecoveryPlan -State $script:state -Recovery $receipt -Completed | Should -Not -BeNullOrEmpty
            $script:state.steps['Purview capability prerequisites'].status = 'Failed'
            Assert-BootstrapPurviewRecoveryPlan -State $script:state -Recovery $receipt -Completed | Should -Not -BeNullOrEmpty
            $script:state.steps['Purview capability prerequisites'].evidence.purview.status = 'NotInstalled'
            { Assert-BootstrapPurviewRecoveryPlan -State $script:state -Recovery $receipt -Completed } | Should -Throw '*capability evidence*'
        }

        It 'refuses altered target, source, original authorization, plan, prefix, failure or snapshot' -ForEach @(
            'Owner', 'Source', 'Configuration', 'AcceptedPlan', 'Binding', 'Prefix', 'FailedStep', 'Snapshot', 'Template') {
            switch ($_) {
                'Owner' { $script:state.deploymentOwnershipId = '99999999-9999-4999-8999-999999999999' }
                'Source' { $script:current = 'sha256:' + ('d' * 64) }
                'Configuration' { $script:state.configurationFingerprint = 'sha256:' + ('d' * 64) }
                'AcceptedPlan' { $script:state.acceptedPlan.planFingerprint = 'sha256:' + ('d' * 64) }
                'Binding' { $script:recovery.plan.binding.applicationId = '99999999-9999-4999-8999-999999999999' }
                'Prefix' { $script:state.steps['Gateway database'].evidence.verified = $false }
                'FailedStep' { $script:state.steps['Purview capability prerequisites'].status = 'Running' }
                'Snapshot' { $script:recovery.executionSource = '.bootstrap/accepted-source/elsewhere' }
                'Template' { Mock Get-FileHash { [pscustomobject]@{ Hash = 'f' * 64 } } }
            }
            { Invoke-BootstrapPurviewRecovery -State $script:state -StatePath 'TestDrive:/state.json' -Config $script:config `
                -AzureIdentity $script:identity -Recovery $script:recovery -ExpectedPlanFingerprint $script:recovery.planFingerprint -Yes } | Should -Throw
            Should -Invoke Invoke-GraphJsonBody -Times 0
            Should -Invoke New-BootstrapPurviewAutomationCertificate -Times 0
            Should -Invoke Save-BootstrapState -Times 0
        }

        It 'requires explicit exact plan confirmation' -ForEach @('MissingYes', 'WrongPlan') {
            $yes = $_ -ceq 'WrongPlan'
            $fingerprint = if ($yes) { 'sha256:' + ('d' * 64) } else { $script:recovery.planFingerprint }
            { Invoke-BootstrapPurviewRecovery -State $script:state -StatePath 'TestDrive:/state.json' -Config $script:config `
                -AzureIdentity $script:identity -Recovery $script:recovery -ExpectedPlanFingerprint $fingerprint -Yes:$yes } | Should -Throw
            Should -Invoke Save-BootstrapState -Times 0
        }

        It 'blocks certificate template drift before accepting or mutating the recovery' {
            Mock Resolve-GatewayCredentialDeploymentTemplate { throw 'Immutable template changed' }
            { Invoke-BootstrapPurviewRecovery -State $script:state -StatePath 'TestDrive:/state.json' -Config $script:config `
                -AzureIdentity $script:identity -Recovery $script:recovery -ExpectedPlanFingerprint $script:recovery.planFingerprint -Yes } | Should -Throw '*template*'
            Should -Invoke Save-BootstrapState -Times 0
            Should -Invoke Invoke-GraphJsonBody -Times 0
        }
    }
}

Describe 'Purview recovery at-most-once operations' {
    InModuleScope PurviewRecovery {
        BeforeEach {
            $script:state = [ordered]@{ purviewPrerequisiteRecoveryPlan = [ordered]@{ operations = [ordered]@{}
                plan = @{ initialOperations = @{ ExchangeGrant = @{ status = 'Absent' }; ComplianceGrant = @{ status = 'Absent' }; Certificate = @{ status = 'Absent' } } } } }
            $script:present = $false
            $script:mutations = 0
            $script:durableStarted = $false
            Mock Save-BootstrapState { $script:durableStarted = $true }
            $script:read = { [ordered]@{ status = if ($script:present) { 'Present' } else { 'Absent' }; assignmentId = 'exact-assignment' } }
            $script:mutate = {
                if (-not $script:durableStarted) { throw 'Mutation preceded durable intent' }
                $script:mutations++
                $script:present = $true
            }
        }

        It 'persists intent before the single mutation and replays completed readback only' -ForEach @('ExchangeGrant', 'ComplianceGrant', 'Certificate') {
            Invoke-BootstrapPurviewRecoveryOperation -State $script:state -StatePath 'TestDrive:/state.json' -Name $_ -Read $script:read -Mutate $script:mutate
            Invoke-BootstrapPurviewRecoveryOperation -State $script:state -StatePath 'TestDrive:/state.json' -Name $_ -Read $script:read -Mutate $script:mutate
            $script:mutations | Should -Be 1
            $script:state.purviewPrerequisiteRecoveryPlan.operations[$_].status | Should -BeExactly 'Completed'
        }

        It 'never repeats an ambiguous absent mutation, including after serialization and restart' {
            $mutate = { $script:mutations++; throw 'Synthetic unknown response' }
            { Invoke-BootstrapPurviewRecoveryOperation -State $script:state -StatePath 'TestDrive:/state.json' -Name ExchangeGrant -Read $script:read -Mutate $mutate } | Should -Throw '*attempted once*'
            $script:state = $script:state | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
            { Invoke-BootstrapPurviewRecoveryOperation -State $script:state -StatePath 'TestDrive:/state.json' -Name ExchangeGrant -Read $script:read -Mutate $mutate } | Should -Throw '*cannot be repeated*'
            $script:mutations | Should -Be 1
        }

        It 'accepts exact delayed readback after an unknown response without another mutation' {
            $mutate = { $script:mutations++; throw 'Synthetic unknown response' }
            { Invoke-BootstrapPurviewRecoveryOperation -State $script:state -StatePath 'TestDrive:/state.json' -Name ExchangeGrant -Read $script:read -Mutate $mutate } | Should -Throw
            $script:present = $true
            Invoke-BootstrapPurviewRecoveryOperation -State $script:state -StatePath 'TestDrive:/state.json' -Name ExchangeGrant -Read $script:read -Mutate $mutate
            $script:mutations | Should -Be 1
        }

        It 'does not mutate if durable intent cannot be saved' {
            Mock Save-BootstrapState { throw 'Synthetic disk failure' }
            { Invoke-BootstrapPurviewRecoveryOperation -State $script:state -StatePath 'TestDrive:/state.json' -Name ExchangeGrant -Read $script:read -Mutate $script:mutate } | Should -Throw
            $script:mutations | Should -Be 0
        }

        It 'never replaces a grant that was present in the plan after an interrupted acceptance' {
            $script:state.purviewPrerequisiteRecoveryPlan.plan.initialOperations.ExchangeGrant = @{ status = 'Present'; assignmentId = 'original-assignment' }
            { Invoke-BootstrapPurviewRecoveryOperation -State $script:state -StatePath 'TestDrive:/state.json' -Name ExchangeGrant -Read $script:read -Mutate $script:mutate } | Should -Throw '*readback-only*'
            $script:mutations | Should -Be 0
        }

        It 'refuses disappearance of completed evidence' {
            Invoke-BootstrapPurviewRecoveryOperation -State $script:state -StatePath 'TestDrive:/state.json' -Name ExchangeGrant -Read $script:read -Mutate $script:mutate
            $script:present = $false
            { Invoke-BootstrapPurviewRecoveryOperation -State $script:state -StatePath 'TestDrive:/state.json' -Name ExchangeGrant -Read $script:read -Mutate $script:mutate } | Should -Throw '*no longer matches*'
            $script:mutations | Should -Be 1
        }
    }
}
