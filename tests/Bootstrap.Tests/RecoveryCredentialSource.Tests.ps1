$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach ($module in @('Common', 'Azure', 'Entra')) {
    Import-Module (Join-Path $root "bootstrap/modules/$module.psm1") -Force -DisableNameChecking
}

Describe 'Recovery credential deployment source binding' {
    InModuleScope Azure {
        BeforeEach {
            $script:original = 'sha256:' + ('a' * 64)
            $script:corrected = 'sha256:' + ('b' * 64)
            $script:owner = '11111111-1111-4111-8111-111111111111'
            $script:keyId = '22222222-2222-4222-8222-222222222222'
            $script:config = @{ projectName = 'safe'; environment = 'dev' }
            $script:template = ''
            $script:tag = ''
            $script:context = @{
                projectName = 'safe'; environment = 'dev'; keyVaultName = 'kv-safe-dev'
                subscriptionId = '33333333-3333-4333-8333-333333333333'; resourceGroupName = 'rg-safe'
                deploymentOwnershipId = $script:owner; sourceFingerprint = $script:original
                automationApplicationId = '44444444-4444-4444-8444-444444444444'
            }
            Mock Get-BootstrapExecutionSourceRoot { $TestDrive }
            Mock Assert-BootstrapSourcePathIsRegular { $true }
            Mock Get-BootstrapSourceFingerprint { $script:corrected }
            Mock Get-GatewayAdminUiCredentialVaultContext { $script:context }
            Mock Get-GatewayPurviewAutomationCertificateContext { $script:context }
            Mock Invoke-ArmDeploymentWithSecureParameters {
                $script:template = $TemplateFile
                $script:tag = $Parameters.bootstrapSourceFingerprint
                throw 'Synthetic lost ARM result; exact metadata must recover it.'
            }
            Mock Wait-GatewayAdminUiCredentialSecretArmMetadata { @{ status = 'Present' } }
            Mock Get-GatewayPurviewAutomationCertificateSecretArmMetadata {
                @{ status = 'Present'; keyCredentialId = $script:keyId; certificateThumbprint = 'a' * 40 }
            }
        }

        It 'uses corrected <Component> template bytes while retaining original deployment tags' -ForEach @(
            @{ Component = 'AdminUi' }, @{ Component = 'Purview' }
        ) {
            $arguments = @{
                Config = $script:config; KeyVaultUri = 'https://kv-safe-dev.vault.azure.net/'
                DeploymentOwnershipId = $script:owner; SourceFingerprint = $script:original
            }
            if ($Component -ceq 'AdminUi') {
                $command = 'Deploy-GatewayAdminUiCredentialSecret'
                $arguments.CredentialKeyId = $script:keyId
                $arguments.SecretText = 'synthetic-test-marker'
                $relative = 'bootstrap/infra/admin-ui-credential.bicep'
            }
            else {
                $command = 'Deploy-GatewayPurviewAutomationCertificateSecret'
                $arguments.AutomationApplicationId = $script:context.automationApplicationId
                $arguments.KeyCredentialId = $script:keyId
                $arguments.CertificateThumbprint = 'a' * 40
                $arguments.CertificateSecretText = 'synthetic-test-marker'
                $relative = 'bootstrap/infra/purview-automation-certificate.bicep'
            }
            if ((Get-Command $command).Parameters.ContainsKey('ExecutionSourceFingerprint')) {
                $arguments.ExecutionSourceFingerprint = $script:corrected
            }
            $result = & $command @arguments
            $result.status | Should -BeExactly 'Present'
            $script:template | Should -BeExactly (Join-Path $TestDrive $relative)
            $script:tag | Should -BeExactly $script:original
            Should -Invoke Invoke-ArmDeploymentWithSecureParameters -Times 1 -Exactly
        }
    }
}

Describe 'Credential source validation before identity mutation' {
    InModuleScope Entra {
        BeforeEach {
            $script:original = 'sha256:' + ('a' * 64)
            $script:owner = '11111111-1111-4111-8111-111111111111'
            Mock Get-BootstrapExecutionSourceRoot -ModuleName Azure { $TestDrive }
            Mock Get-BootstrapSourceFingerprint -ModuleName Azure { 'sha256:' + ('c' * 64) }
            Mock Assert-BootstrapSourcePathIsRegular -ModuleName Azure { $true }
            Mock Get-BootstrapExecutionSourceRoot { $TestDrive }
            Mock Get-BootstrapSourceFingerprint { 'sha256:' + ('c' * 64) }
            Mock Assert-BootstrapSourcePathIsRegular { $true }
            Mock Get-AdminUiCredentialReconciliationState { @{ status = 'DoubleAbsent' } }
            Mock Get-BootstrapPurviewExchangeRole { @{ id = '22222222-2222-4222-8222-222222222222' } }
            Mock Get-ExactApplicationByDisplayName { $null }
            Mock Invoke-GraphJsonBody { throw 'Synthetic mutation boundary reached.' }
        }

        It 'rejects an invalid <Component> execution snapshot before any Graph mutation' -ForEach @(
            @{ Component = 'AdminUi' }, @{ Component = 'Purview' }
        ) {
            $arguments = @{
                Config = @{ projectName = 'safe'; environment = 'dev' }
                KeyVaultUri = 'https://kv-safe-dev.vault.azure.net/'
                DeploymentOwnershipId = $script:owner; SourceFingerprint = $script:original
            }
            if ($Component -ceq 'AdminUi') {
                $command = 'New-AdminUiCredentialInKeyVault'
                $arguments.AdminIdentity = @{
                    deploymentOwnershipId = $script:owner
                    adminUiApplicationObjectId = '33333333-3333-4333-8333-333333333333'
                }
            }
            else {
                $command = 'Ensure-BootstrapPurviewAutomationIdentity'
                $arguments.AzureIdentity = @{ userObjectId = '44444444-4444-4444-8444-444444444444' }
            }
            if ((Get-Command $command).Parameters.ContainsKey('ExecutionSourceFingerprint')) {
                $arguments.ExecutionSourceFingerprint = 'sha256:' + ('b' * 64)
            }
            { & $command @arguments } | Should -Throw
            Should -Invoke Invoke-GraphJsonBody -Times 0 -Exactly
        }
    }
}
