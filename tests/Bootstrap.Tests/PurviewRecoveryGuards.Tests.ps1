& {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    foreach ($module in @('Common', 'Experience', 'Azure', 'Entra', 'PurviewRecovery')) {
        Import-Module (Join-Path $root "bootstrap/modules/$module.psm1") -Force -DisableNameChecking
    }
}

Describe 'Purview recovery immutable source restriction' {
    InModuleScope PurviewRecovery {
        BeforeEach {
            $script:changedPath = ''
            $script:missingPath = ''
            Mock Resolve-BootstrapAcceptedSourceRoot { 'original' }
            Mock Get-BootstrapSourceManifest {
                param($Root)
                foreach ($path in @('bootstrap/modules/Entra.psm1', 'bootstrap/modules/Common.psm1', 'bootstrap/bootstrap.ps1',
                    'bootstrap/modules/PurviewRecovery.psm1', 'bootstrap/recover-purview-prerequisites.ps1',
                    'src/Gateway.Api/Program.cs', 'bootstrap/infra/purview-automation-certificate.bicep',
                    'infrastructure/bicep/main.bicep')) {
                    if ($Root -ceq 'original' -and $path -in @('bootstrap/modules/PurviewRecovery.psm1', 'bootstrap/recover-purview-prerequisites.ps1')) { continue }
                    if ($Root -ceq 'candidate' -and $path -ceq $script:missingPath) { continue }
                    @{ path = $path; sha256 = if ($Root -ceq 'candidate' -and $path -ceq $script:changedPath) { 'b' * 64 } else { 'a' * 64 } }
                }
            }
        }

        It 'accepts the dedicated recovery tooling addition and query correction' {
            $script:changedPath = 'bootstrap/modules/Entra.psm1'
            Assert-BootstrapPurviewRecoverySourceBoundary -State @{} -CandidateRoot candidate | Should -BeTrue
        }

        It 'rejects runtime or template changes' -ForEach @('src/Gateway.Api/Program.cs', 'bootstrap/infra/purview-automation-certificate.bicep', 'infrastructure/bicep/main.bicep') {
            $script:changedPath = $_
            { Assert-BootstrapPurviewRecoverySourceBoundary -State @{} -CandidateRoot candidate } | Should -Throw '*tooling-only*'
        }

        It 'rejects removing an existing source file even within the tooling allowlist' {
            $script:missingPath = 'bootstrap/modules/Entra.psm1'
            { Assert-BootstrapPurviewRecoverySourceBoundary -State @{} -CandidateRoot candidate } | Should -Throw '*cannot remove*'
        }
    }
}

Describe 'Certificate-only recovery helper' {
    InModuleScope Entra {
        BeforeEach {
            $script:applicationObject = '11111111-1111-4111-8111-111111111111'
            $script:applicationId = '22222222-2222-4222-8222-222222222222'
            $script:keyId = '33333333-3333-4333-8333-333333333333'
            $script:application = [ordered]@{ id = $script:applicationObject; appId = $script:applicationId; keyCredentials = @() }
            $script:metadata = @{ status = 'Absent' }
            $script:patches = 0
            $script:secretDeployments = 0
            $script:certificateArguments = @{ Config = @{ projectName = 'safe'; environment = 'dev' }; AzureIdentity = @{ userObjectId = '44444444-4444-4444-8444-444444444444' }
                ApplicationObjectId = $script:applicationObject; ApplicationId = $script:applicationId; KeyCredentialId = $script:keyId
                KeyVaultUri = 'https://kv-safe-dev.vault.azure.net/'; DeploymentOwnershipId = '55555555-5555-4555-8555-555555555555'
                SourceFingerprint = 'sha256:' + ('a' * 64); ExecutionSourceFingerprint = 'sha256:' + ('b' * 64) }
            Mock Resolve-GatewayCredentialDeploymentTemplate { 'synthetic-template' }
            Mock Get-BootstrapPurviewAutomationApplication { $script:application }
            Mock Get-BootstrapPurviewExchangeRole { @{ roleId = '455e5cd2-84e8-4751-8344-5672145dfa17' } }
            Mock Assert-BootstrapPurviewAutomationApplication { $true }
            Mock Get-GatewayPurviewAutomationCertificateSecretArmMetadata { $script:metadata }
            Mock Deploy-GatewayPurviewAutomationCertificateSecret { $script:secretDeployments++ }
            Mock Invoke-GraphJsonBody {
                param($Method, $Url, $Body)
                if ($Method -cne 'PATCH' -or $Url -cne "https://graph.microsoft.com/v1.0/applications/$script:applicationObject" -or
                    [string]$Body.keyCredentials[0].keyId -cne $script:keyId) { throw 'Unexpected certificate mutation' }
                $script:patches++
            }
        }

        It 'does exactly one secret deployment and public-key PATCH using the planned key ID' {
            New-BootstrapPurviewAutomationCertificate @script:certificateArguments
            $script:secretDeployments | Should -Be 1
            $script:patches | Should -Be 1
        }

        It 'refuses partial or existing certificate stores' -ForEach @('EntraOnly', 'VaultOnly', 'Both') {
            if ($_ -cin @('EntraOnly', 'Both')) { $script:application.keyCredentials = @(@{ keyId = $script:keyId }) }
            if ($_ -cin @('VaultOnly', 'Both')) { $script:metadata.status = 'Present' }
            { New-BootstrapPurviewAutomationCertificate @script:certificateArguments } | Should -Throw '*both Entra and Key Vault*'
            $script:secretDeployments | Should -Be 0
            $script:patches | Should -Be 0
        }

        It 'rejects a replaced application before certificate creation' {
            $script:application.appId = '99999999-9999-4999-8999-999999999999'
            { New-BootstrapPurviewAutomationCertificate @script:certificateArguments } | Should -Throw '*pinned identity*'
            $script:secretDeployments | Should -Be 0
        }

        It 'checks immutable template before any identity or certificate call' {
            Mock Resolve-GatewayCredentialDeploymentTemplate { throw 'Synthetic source drift' }
            { New-BootstrapPurviewAutomationCertificate @script:certificateArguments } | Should -Throw '*source drift*'
            Should -Invoke Get-BootstrapPurviewAutomationApplication -Times 0
            $script:secretDeployments | Should -Be 0
        }

        It 'does not repeat a lost secret deployment or patch when exact key readback is absent' {
            Mock Deploy-GatewayPurviewAutomationCertificateSecret { $script:secretDeployments++; throw 'Synthetic unknown secret outcome' }
            { New-BootstrapPurviewAutomationCertificate @script:certificateArguments } | Should -Throw
            $script:secretDeployments | Should -Be 1
            $script:patches | Should -Be 0
        }
    }
}
