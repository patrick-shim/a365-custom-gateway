$script:CapabilityRepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:CapabilityRepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:CapabilityRepositoryRoot 'bootstrap/modules/Entra.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $script:CapabilityRepositoryRoot 'bootstrap/modules/Verification.psm1') -Force

Describe 'Final runtime Graph role isolation' {
    InModuleScope Verification {
        It 'verifies exact distinct principal role sets with Purview enabled <Enabled>' -ForEach @(
            @{ Enabled = $true }
            @{ Enabled = $false }
        ) {
            $runtime = @{
                workerPrincipalId = '11111111-1111-4111-8111-111111111111'
                apiPrincipalId = '22222222-2222-4222-8222-222222222222'
                runtimeImagePullIdentityPrincipalId = '33333333-3333-4333-8333-333333333333'
            }
            Mock Assert-ExactGraphApplicationRoleAssignments { return $true }
            Assert-GatewayRuntimeGraphRoleAssignments -Config @{ purview = @{ enabled = $Enabled } } -Runtime $runtime
            Should -Invoke Assert-ExactGraphApplicationRoleAssignments -Times 1 -Exactly -ParameterFilter {
                $PrincipalId -ceq $runtime.workerPrincipalId -and $ExpectedRoleValues.Count -eq 8 -and
                ($ExpectedRoleValues -join '|') -ceq 'Application.Read.All|AppRoleAssignment.ReadWrite.All|AgentIdentityBlueprint.Create|AgentIdentityBlueprint.AddRemoveCreds.All|AgentIdentityBlueprintPrincipal.Create|AgentIdentityBlueprint.Read.All|AgentIdentity.Create.All|AgentIdentity.Read.All'
            }
            Should -Invoke Assert-ExactGraphApplicationRoleAssignments -Times 1 -Exactly -ParameterFilter {
                $PrincipalId -ceq $runtime.apiPrincipalId -and ($ExpectedRoleValues -join '|') -ceq 'AgentIdentityBlueprint.Read.All'
            }
            Should -Invoke Assert-ExactGraphApplicationRoleAssignments -Times 1 -Exactly -ParameterFilter {
                $PrincipalId -ceq $runtime.runtimeImagePullIdentityPrincipalId -and
                ($ExpectedRoleValues -join '|') -ceq $(if ($Enabled) { 'ProtectionScopes.Compute.User|Content.Process.User|ContentActivity.Write' } else { '' })
            }
            Should -Invoke Assert-ExactGraphApplicationRoleAssignments -Times 3 -Exactly
        }
    }
}

Describe 'Fresh Purview capability infrastructure contract' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $script:BootstrapSource = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'bootstrap/bootstrap.ps1') -Raw
        $script:EntraSource = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'bootstrap/modules/Entra.psm1') -Raw
        $script:AzureSource = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Raw
        $script:ExperienceSource = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'bootstrap/modules/Experience.psm1') -Raw
        $script:MainBicep = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'infrastructure/bicep/main.bicep') -Raw
        $script:ServiceBusBicep = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'infrastructure/bicep/modules/service-bus.bicep') -Raw
        $script:WorkerBicep = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'infrastructure/bicep/modules/container-app-worker.bicep') -Raw
        $script:ApiBicep = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'infrastructure/bicep/modules/container-app-api.bicep') -Raw
        $script:RoleBicep = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'infrastructure/bicep/modules/role-assignments.bicep') -Raw
    }

    It 'keeps selected Content Safety infrastructure while withholding runtime activation during inert bootstrap' {
        $script:MainBicep | Should -Match 'promptShieldEnabled:\s*promptShieldEnabled && databaseAttestationEnabled'
        $script:MainBicep | Should -Match "module contentSafety[^\r\n]+if \(promptShieldEnabled\)"
        $script:MainBicep | Should -Match 'promptShieldEndpoint:\s*promptShieldEnabled \? contentSafety!\.outputs\.endpoint'
        $script:MainBicep | Should -Match "resource promptShieldCognitiveServicesUser[^\r\n]+if \(promptShieldEnabled\)"
    }

    It 'pins the documented Security and Compliance app-only permission and role' {
        $script:EntraSource |
            Should -Match "PurviewExchangeOnlineProtectionAppId\s*=\s*'00000007-0000-0ff1-ce00-000000000000'"
        $script:EntraSource |
            Should -Match "PurviewExchangeManageAsAppRoleId\s*=\s*'455e5cd2-84e8-4751-8344-5672145dfa17'"
        $script:EntraSource |
            Should -Match "PurviewComplianceAdministratorRoleDefinitionId\s*=\s*'17315797-102d-40b4-93e0-432062caca18'"
        $script:EntraSource | Should -Match 'Ensure-BootstrapPurviewAutomationIdentity'
        $script:EntraSource | Should -Match '/roleManagement/directory/roleAssignments'
        $script:EntraSource | Should -Match '/appRoleAssignments'
    }

    It 'uses one certificate secret path without exposing private material in outputs' {
        $templatePath = Join-Path $script:RepositoryRoot (
            'bootstrap/infra/purview-automation-certificate.bicep')
        Test-Path -LiteralPath $templatePath -PathType Leaf | Should -BeTrue
        $template = Get-Content -LiteralPath $templatePath -Raw

        $template | Should -Match '@secure\(\)[\s\S]{0,80}param secretValue string'
        $template | Should -Match "secretName = 'purview-automation-certificate'"
        $template | Should -Match "contentType = 'application/x-pkcs12'"
        $template | Should -Not -Match 'output\s+\w+\s+\w+\s*=\s*secretValue'
        $script:AzureSource | Should -Match 'Deploy-GatewayPurviewAutomationCertificateSecret'
        $script:AzureSource | Should -Match 'Get-GatewayPurviewAutomationCertificateSecretArmMetadata'
        $script:EntraSource | Should -Match 'CertificateRequest'
        $script:EntraSource | Should -Match 'RSACryptoServiceProvider'
        $script:EntraSource | Should -Match 'PersistKeyInCsp\s*=\s*\$false'
        $script:EntraSource | Should -Match 'CryptographicOperations\]::ZeroMemory'
    }

    It 'provisions the exact dedicated protection administration queue only with Purview' {
        $script:MainBicep |
            Should -Match "param protectionAdminQueueName string = 'gateway-protection-admin-v1'"
        $script:MainBicep |
            Should -Match 'protectionAdminQueueEnabled:\s*purviewEnabled'
        $script:ServiceBusBicep |
            Should -Match "param protectionAdminQueueName string = 'gateway-protection-admin-v1'"
        $script:ServiceBusBicep |
            Should -Match 'resource protectionAdminQueue[\s\S]{0,180}= if \(protectionAdminQueueEnabled\)'
        $script:MainBicep |
            Should -Match 'output protectionAdminQueueName string = purviewEnabled \? serviceBus\.outputs\.protectionAdminQueueName : '''
    }

    It 'wires exact sender and receiver RBAC plus worker processing and KEDA settings' {
        $script:RoleBicep | Should -Match 'protectionAdminQueueEnabled'
        $script:RoleBicep |
            Should -Match 'apiProtectionAdminServiceBusDataSender[\s\S]{0,220}scope: protectionAdminQueue'
        $script:RoleBicep |
            Should -Match 'workerProtectionAdminServiceBusDataReceiver[\s\S]{0,220}scope: protectionAdminQueue'
        $script:WorkerBicep |
            Should -Match "name: 'ProtectionAdminWorker__ProcessingEnabled'"
        $script:WorkerBicep |
            Should -Match "queueName: protectionAdminQueueName"
        $script:WorkerBicep |
            Should -Match "name: 'protection-admin-queue-rule'"
    }

    It 'selects one exact shared workload identity for API Purview traffic and worker readiness' {
        $script:MainBicep |
            Should -Match "resource runtimeWorkloadIdentity 'Microsoft\.ManagedIdentity/userAssignedIdentities@2023-01-31' existing"
        $script:MainBicep |
            Should -Match 'purviewRuntimeIdentityConfigured = purviewEnabled && runtimeImagePullIdentityInputsArePopulated'
        $script:MainBicep |
            Should -Match 'purviewRuntimeIdentityResourceId:\s*purviewRuntimeIdentityConfigured \? runtimeImagePullIdentityId : '''
        $script:MainBicep |
            Should -Match 'purviewRuntimeIdentityClientId:\s*purviewRuntimeIdentityConfigured \? runtimeWorkloadIdentity!\.properties\.clientId : '''
        $script:MainBicep |
            Should -Match 'purviewRuntimeIdentityPrincipalId:\s*purviewRuntimeIdentityConfigured \? runtimeImagePullIdentityPrincipalId : '''
        foreach ($source in @($script:ApiBicep, $script:WorkerBicep)) {
            $source | Should -Match "name: 'PurviewRuntimeIdentity__ManagedIdentityClientId'"
            $source | Should -Match "name: 'PurviewRuntimeIdentity__ManagedIdentityPrincipalObjectId'"
            $source | Should -Match "'\$\{purviewRuntimeIdentityResourceId\}': \{\}"
        }
        $script:EntraSource |
            Should -Match 'Get-GatewayPurviewRuntimeManagedIdentity'
        $script:EntraSource |
            Should -Match 'Assert-ExactGraphApplicationRoleAssignments -PrincipalId \$purviewRuntimeIdentity\.principalId -ExpectedRoleValues \$purviewRuntimeRoles'
        $script:EntraSource |
            Should -Not -Match 'foreach \(\$role in \$purviewRuntimeRoles\) \{ \$apiRoles\.Add\(\$role\) \}'
        $script:EntraSource |
            Should -Match 'apiHostApplicationRoles = \$apiHostRoleIds'
        $script:EntraSource |
            Should -Match 'Experience\\Test-GatewayWorkflowIdentityEvidence'
        $script:EntraSource |
            Should -Not -Match 'ExpectedRoleValues \$workerRoles[\s\S]{0,160}ProtectionScopes\.Compute\.User'
    }

    It 'binds automation evidence and queue outputs into runtime deployment and verification' {
        $script:BootstrapSource |
            Should -Match 'Ensure-BootstrapPurviewAutomationIdentity'
        $script:EntraSource |
            Should -Match 'Test-BootstrapPurviewAutomationIdentityEvidence'
        $script:BootstrapSource |
            Should -Match 'Test-GatewayBootstrapCapabilityEvidence'
        $script:BootstrapSource |
            Should -Match 'Deploy-GatewayCore[\s\S]{0,900}-PurviewAutomation'
        $script:AzureSource |
            Should -Match 'protectionAdminQueueName'
        $script:AzureSource |
            Should -Match 'protectionAdminQueueId'
        $script:AzureSource |
            Should -Match 'ProtectionAdminWorker__ProcessingEnabled'
    }

    It 'does not create optional Purview resources for Core or Custom without Purview' {
        $script:MainBicep |
            Should -Match 'effectiveProtectionAdminProcessingEnabled = purviewEnabled'
        $script:MainBicep |
            Should -Match 'protectionAdminProcessingEnabled:\s*effectiveProtectionAdminProcessingEnabled'
        $script:MainBicep |
            Should -Match 'enableWorkerKeyVaultSecretsUser:\s*purviewEnabled'
        $script:BootstrapSource |
            Should -Match 'if \(\$configuration\.purview\.enabled -eq \$true\)'
    }

    It 'passes only the exact strict bootstrap capability facts to the API environment' {
        foreach ($name in @(
            'BootstrapCapabilities__Enabled',
            'BootstrapCapabilities__AttestedAtUtc',
            'BootstrapCapabilities__DeploymentOwnershipId',
            'BootstrapCapabilities__AcceptedSourceFingerprint',
            'BootstrapCapabilities__Agent365RegistrationBeta__Status',
            'BootstrapCapabilities__Agent365RegistrationBeta__Agent365RegistryApiApplicationId',
            'BootstrapCapabilities__PromptShields__Status',
            'BootstrapCapabilities__PromptShields__ContentSafetyAccountResourceId',
            'BootstrapCapabilities__PromptShields__ContentSafetyEndpoint',
            'BootstrapCapabilities__PromptShields__GatewayApiManagedIdentityPrincipalObjectId',
            'BootstrapCapabilities__Purview__Status',
            'BootstrapCapabilities__Purview__GatewayApiManagedIdentityPrincipalObjectId',
            'BootstrapCapabilities__Purview__PurviewRuntimeManagedIdentityPrincipalObjectId',
            'BootstrapCapabilities__Purview__PurviewAutomationApplicationId',
            'BootstrapCapabilities__Purview__PurviewAutomationServicePrincipalObjectId',
            'BootstrapCapabilities__Purview__KeyVaultResourceId',
            'BootstrapCapabilities__Purview__KeyVaultHost',
            'BootstrapCapabilities__Purview__CertificateName',
            'BootstrapCapabilities__Purview__CertificateSecretUri'
        )) {
            $script:ApiBicep | Should -Match ([regex]::Escape("name: '$name'"))
        }
        $script:MainBicep | Should -Match 'bootstrapCapabilities:\s*bootstrapCapabilities'
        $script:MainBicep | Should -Match 'output bootstrapCapabilities object = bootstrapCapabilities'
        $script:AzureSource |
            Should -Match "Get-GatewayCoreOutputValue -Outputs [`$]Outputs -Name 'bootstrapCapabilities'"
        $script:ExperienceSource | Should -Match 'deployment\.parameters\.bootstrapCapabilities\.value'
        $script:ExperienceSource | Should -Match 'deployment\.outputs\.bootstrapCapabilities\.value'
        $script:ApiBicep | Should -Not -Match 'BootstrapCapabilities__[A-Za-z0-9_]*(Policy|Readiness|Propagation|Verdict|TokenRoles)'
    }
}
