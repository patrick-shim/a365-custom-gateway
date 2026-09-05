$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Force

Describe 'Purview automation certificate secure ARM boundary' {
    InModuleScope Azure {
        BeforeEach {
            $script:certificateSource = "sha256:$('c' * 64)"
            $script:certificateOwnership = '11111111-1111-4111-8111-111111111111'
            $script:certificateApplicationId = '22222222-2222-4222-8222-222222222222'
            $script:certificateKeyId = '33333333-3333-4333-8333-333333333333'
            $script:certificateThumbprint = 'a' * 40
            $script:certificatePrivateMarker = 'synthetic-private-certificate-material'
            $script:secureDeploymentParameters = $null
            $script:certificateConfig = [pscustomobject]@{
                subscriptionId = '44444444-4444-4444-8444-444444444444'
                resourceGroupName = 'rg-safe-dev'
                projectName = 'safe'
                environment = 'dev'
            }
            Mock Get-GatewayPurviewAutomationCertificateContext {
                return [ordered]@{
                    subscriptionId = [string]$script:certificateConfig.subscriptionId
                    resourceGroupName = 'rg-safe-dev'
                    keyVaultName = 'kv-safe-dev'
                    secretName = 'purview-automation-certificate'
                    secretResourceId = '/subscriptions/44444444-4444-4444-8444-444444444444/resourceGroups/rg-safe-dev/providers/Microsoft.KeyVault/vaults/kv-safe-dev/secrets/purview-automation-certificate'
                    versionlessSecretUri = 'https://kv-safe-dev.vault.azure.net/secrets/purview-automation-certificate'
                    automationApplicationId = $script:certificateApplicationId
                    deploymentOwnershipId = $script:certificateOwnership
                    sourceFingerprint = $script:certificateSource
                }
            }
            Mock Get-BootstrapExecutionSourceRoot { return 'C:\source' }
            Mock Assert-BootstrapSourcePathIsRegular { return $true }
            Mock Get-BootstrapSourceFingerprint { return $script:certificateSource }
            Mock Invoke-ArmDeploymentWithSecureParameters {
                param($SubscriptionId, $ResourceGroup, $Name, $TemplateFile, $Parameters)
                $script:secureDeploymentParameters = $Parameters
                return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded' } }
            }
            Mock Get-GatewayPurviewAutomationCertificateSecretArmMetadata {
                return [ordered]@{
                    status = 'Present'
                    secretResourceId = '/subscriptions/44444444-4444-4444-8444-444444444444/resourceGroups/rg-safe-dev/providers/Microsoft.KeyVault/vaults/kv-safe-dev/secrets/purview-automation-certificate'
                    secretUri = 'https://kv-safe-dev.vault.azure.net/secrets/purview-automation-certificate'
                    keyCredentialId = $script:certificateKeyId
                    certificateThumbprint = $script:certificateThumbprint
                    automationApplicationId = $script:certificateApplicationId
                    deploymentOwnershipId = $script:certificateOwnership
                    sourceFingerprint = $script:certificateSource
                    contentType = 'application/x-pkcs12'
                }
            }
        }

        It 'passes private bytes only through the secure deployment parameter and returns metadata only' {
            $result = Deploy-GatewayPurviewAutomationCertificateSecret `
                -Config $script:certificateConfig `
                -KeyVaultUri 'https://kv-safe-dev.vault.azure.net/' `
                -AutomationApplicationId $script:certificateApplicationId `
                -KeyCredentialId $script:certificateKeyId `
                -CertificateThumbprint $script:certificateThumbprint `
                -CertificateSecretText $script:certificatePrivateMarker `
                -DeploymentOwnershipId $script:certificateOwnership `
                -SourceFingerprint $script:certificateSource

            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 1 -Exactly
            [string]$script:secureDeploymentParameters.secretValue |
                Should -BeNullOrEmpty
            ($result | ConvertTo-Json -Depth 20 -Compress) |
                Should -Not -Match ([regex]::Escape($script:certificatePrivateMarker))
            $result.secretUri | Should -BeExactly 'https://kv-safe-dev.vault.azure.net/secrets/purview-automation-certificate'
        }

        It 'uses exact metadata after an unknown ARM response without replaying the deployment' {
            Mock Invoke-ArmDeploymentWithSecureParameters {
                param($SubscriptionId, $ResourceGroup, $Name, $TemplateFile, $Parameters)
                $script:secureDeploymentParameters = $Parameters
                throw 'synthetic unknown response'
            }

            $result = Deploy-GatewayPurviewAutomationCertificateSecret `
                -Config $script:certificateConfig `
                -KeyVaultUri 'https://kv-safe-dev.vault.azure.net/' `
                -AutomationApplicationId $script:certificateApplicationId `
                -KeyCredentialId $script:certificateKeyId `
                -CertificateThumbprint $script:certificateThumbprint `
                -CertificateSecretText $script:certificatePrivateMarker `
                -DeploymentOwnershipId $script:certificateOwnership `
                -SourceFingerprint $script:certificateSource

            $result.status | Should -BeExactly 'Present'
            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 1 -Exactly
            Should -Invoke Get-GatewayPurviewAutomationCertificateSecretArmMetadata -Times 1 -Exactly
        }
    }
}
