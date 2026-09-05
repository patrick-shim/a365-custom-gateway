$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Experience.psm1') -Force

Describe 'Strict bootstrap capability evidence' {
    BeforeEach {
        $script:ownershipId = '11111111-1111-4111-8111-111111111111'
        $script:sourceFingerprint = "sha256:$('a' * 64)"
        $script:readbackAt = '2026-09-05T13:30:00.0000000+00:00'
        $script:apiPrincipalId = '22222222-2222-4222-8222-222222222222'
        $script:workerPrincipalId = '33333333-3333-4333-8333-333333333333'
        $script:runtimePrincipalId = '88888888-8888-4888-8888-888888888888'
        $script:apiApplicationId = '44444444-4444-4444-8444-444444444444'
        $script:contentSafetyId = '/subscriptions/55555555-5555-4555-8555-555555555555/resourceGroups/rg-safe-dev/providers/Microsoft.CognitiveServices/accounts/cs-safe'
        $script:contentSafetyEndpoint = 'https://cs-safe.cognitiveservices.azure.com/'
        $script:keyVaultId = '/subscriptions/55555555-5555-4555-8555-555555555555/resourceGroups/rg-safe-dev/providers/Microsoft.KeyVault/vaults/kv-safe-dev'
        $script:config = [pscustomobject]@{
            environment = 'dev'
            agent365 = [pscustomobject]@{ allowDevelopmentRegistryPreview = $true }
            promptShield = [pscustomobject]@{ enabled = $true }
            purview = [pscustomobject]@{ enabled = $true }
        }
        $script:identity = [pscustomobject]@{
            gatewayApiClientId = $script:apiApplicationId
        }
        $script:runtime = [pscustomobject]@{
            deploymentOwnershipId = $script:ownershipId
            sourceFingerprint = $script:sourceFingerprint
            apiPrincipalId = $script:apiPrincipalId
            workerPrincipalId = $script:workerPrincipalId
            runtimeImagePullIdentityPrincipalId = $script:runtimePrincipalId
            promptShieldAccountId = $script:contentSafetyId
            promptShieldEndpoint = $script:contentSafetyEndpoint
            sharedKeyVaultId = $script:keyVaultId
        }
        $script:purview = [ordered]@{
            enabled = $true
            status = 'Installed'
            automationApplicationId = '66666666-6666-4666-8666-666666666666'
            automationServicePrincipalId = '77777777-7777-4777-8777-777777777777'
            certificateSecretResourceId = "$script:keyVaultId/secrets/purview-automation-certificate"
            certificateSecretUri = 'https://kv-safe-dev.vault.azure.net/secrets/purview-automation-certificate'
            deploymentOwnershipId = $script:ownershipId
            sourceFingerprint = $script:sourceFingerprint
        }
    }

    It 'emits the complete Installed snapshot from exact readback facts only' {
        $evidence = Get-GatewayBootstrapCapabilityEvidence `
            -Config $script:config `
            -Identity $script:identity `
            -RuntimeReadback $script:runtime `
            -PurviewCapability $script:purview `
            -ReadbackAtUtc $script:readbackAt

        $evidence.enabled | Should -BeTrue
        $evidence.readbackAtUtc | Should -BeExactly $script:readbackAt
        $evidence.deploymentOwnershipId | Should -BeExactly $script:ownershipId
        $evidence.sourceFingerprint | Should -BeExactly $script:sourceFingerprint
        $evidence.agent365RegistrationBeta.status | Should -BeExactly 'Installed'
        $evidence.agent365RegistrationBeta.registryApiApplicationId |
            Should -BeExactly $script:apiApplicationId
        $evidence.promptShields.status | Should -BeExactly 'Installed'
        $evidence.promptShields.contentSafetyAccountResourceId |
            Should -BeExactly $script:contentSafetyId
        $evidence.promptShields.contentSafetyEndpoint |
            Should -BeExactly $script:contentSafetyEndpoint
        $evidence.promptShields.gatewayApiManagedIdentityPrincipalObjectId |
            Should -BeExactly $script:apiPrincipalId
        $evidence.purview.status | Should -BeExactly 'Installed'
        $evidence.purview.gatewayApiManagedIdentityPrincipalObjectId |
            Should -BeExactly $script:apiPrincipalId
        $evidence.purview.purviewRuntimeManagedIdentityPrincipalObjectId |
            Should -BeExactly $script:runtimePrincipalId
        $evidence.purview.purviewRuntimeManagedIdentityPrincipalObjectId |
            Should -Not -BeExactly $script:workerPrincipalId
        $evidence.purview.automationApplicationId |
            Should -BeExactly $script:purview.automationApplicationId
        $evidence.purview.automationServicePrincipalObjectId |
            Should -BeExactly $script:purview.automationServicePrincipalId
        $evidence.purview.keyVaultResourceId | Should -BeExactly $script:keyVaultId
        $evidence.purview.keyVaultHost | Should -BeExactly 'kv-safe-dev.vault.azure.net'
        $evidence.purview.certificateName |
            Should -BeExactly 'purview-automation-certificate'
        $evidence.purview.certificateSecretUri |
            Should -BeExactly $script:purview.certificateSecretUri
        ($evidence | ConvertTo-Json -Depth 20 -Compress) |
            Should -Not -Match '(?i)policy|readiness|propagation|verdict|tokenRoles'
    }

    It 'clears every omitted optional identifier while retaining development beta admission' {
        $script:config.promptShield.enabled = $false
        $script:config.purview.enabled = $false
        $script:runtime.promptShieldAccountId = ''
        $script:runtime.promptShieldEndpoint = ''

        $evidence = Get-GatewayBootstrapCapabilityEvidence `
            -Config $script:config `
            -Identity $script:identity `
            -RuntimeReadback $script:runtime `
            -PurviewCapability $null `
            -ReadbackAtUtc $script:readbackAt

        $evidence.agent365RegistrationBeta.status | Should -BeExactly 'Installed'
        $evidence.promptShields.status | Should -BeExactly 'NotInstalled'
        $evidence.promptShields.contentSafetyAccountResourceId | Should -BeExactly ''
        $evidence.promptShields.contentSafetyEndpoint | Should -BeExactly ''
        $evidence.promptShields.gatewayApiManagedIdentityPrincipalObjectId |
            Should -BeExactly ''
        $evidence.purview.status | Should -BeExactly 'NotInstalled'
        foreach ($value in @(
            $evidence.purview.gatewayApiManagedIdentityPrincipalObjectId
            $evidence.purview.purviewRuntimeManagedIdentityPrincipalObjectId
            $evidence.purview.automationApplicationId
            $evidence.purview.automationServicePrincipalObjectId
            $evidence.purview.keyVaultResourceId
            $evidence.purview.keyVaultHost
            $evidence.purview.certificateName
            $evidence.purview.certificateSecretUri
        )) {
            $value | Should -BeExactly ''
        }
    }

    It 'keeps staging and production Agent 365 beta closed with a clear application ID' {
        foreach ($environment in @('staging', 'prod')) {
            $script:config.environment = $environment
            $script:config.agent365.allowDevelopmentRegistryPreview = $false
            $script:config.promptShield.enabled = $false
            $script:config.purview.enabled = $false
            $script:runtime.promptShieldAccountId = ''
            $script:runtime.promptShieldEndpoint = ''

            $evidence = Get-GatewayBootstrapCapabilityEvidence `
                -Config $script:config `
                -Identity $script:identity `
                -RuntimeReadback $script:runtime `
                -PurviewCapability $null `
                -ReadbackAtUtc $script:readbackAt

            $evidence.agent365RegistrationBeta.status | Should -BeExactly 'NotInstalled'
            $evidence.agent365RegistrationBeta.registryApiApplicationId |
                Should -BeExactly ''
        }
    }
}
