$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module ExchangeOnlineManagement -ErrorAction Stop
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Purview.psm1') -Force

Describe 'Purview Security and Compliance tenant boundary' {
    InModuleScope Purview {
        BeforeEach {
            $script:tenantId = '11111111-1111-4111-8111-111111111111'
            $script:userPrincipalName = 'operator@example.test'
            $script:connectionRead = 0
            $script:connection = [pscustomobject]@{
                ConnectionId = '22222222-2222-4222-8222-222222222222'
                State = 'Connected'
                UserPrincipalName = $script:userPrincipalName
                AzureAdAuthorizationEndpointUri = "https://login.microsoftonline.com/$script:tenantId"
                TenantID = $script:tenantId
                TokenStatus = 'Active'
                IsEopSession = $true
            }
            Mock Import-Module {}
            Mock Connect-IPPSSession {}
            Mock Disconnect-ExchangeOnline {}
            Mock Get-ConnectionInformation {
                $script:connectionRead++
                if ($script:connectionRead -eq 1) { return @() }
                return @($script:connection)
            }
            Mock Get-Command {
                param($Name)
                return [pscustomobject]@{ Name = $Name }
            }
        }

        It 'creates exactly one direct-member EOP session at the reviewed tenant endpoint' {
            $connectionId = Connect-BootstrapPurview `
                -UserPrincipalName $script:userPrincipalName `
                -TenantId $script:tenantId
            $connectionId | Should -BeExactly '22222222-2222-4222-8222-222222222222'
            Disconnect-BootstrapPurview -ConnectionId $connectionId

            Should -Invoke Connect-IPPSSession -Times 1 -Exactly -ParameterFilter {
                $UserPrincipalName -eq $script:userPrincipalName -and
                $AzureADAuthorizationEndpointUri -eq "https://login.microsoftonline.com/$script:tenantId"
            }
            Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly -ParameterFilter {
                $ConnectionId -eq '22222222-2222-4222-8222-222222222222'
            }
        }

        It 'disconnects the newly created session when tenant readback differs' {
            $script:connection.TenantID = '33333333-3333-4333-8333-333333333333'

            { Connect-BootstrapPurview `
                -UserPrincipalName $script:userPrincipalName `
                -TenantId $script:tenantId } |
                Should -Throw '*tenant/session authority could not be proven*'

            Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly -ParameterFilter {
                $ConnectionId -eq '22222222-2222-4222-8222-222222222222'
            }
        }

        It 'refuses a pre-existing EOP session before starting another connection' {
            $script:connectionRead = 1

            { Connect-BootstrapPurview `
                -UserPrincipalName $script:userPrincipalName `
                -TenantId $script:tenantId } |
                Should -Throw '*existing Security & Compliance session*'

            Should -Invoke Connect-IPPSSession -Times 0 -Exactly
        }

        It 'passes the canonical configured tenant into the policy-authoring connection exactly once' {
            Mock Connect-BootstrapPurview { throw 'stop-after-tenant-bound-connect' }
            $config = [pscustomobject]@{
                tenantId = $script:tenantId
                purview = [pscustomobject]@{ enabled = $true }
            }

            { Ensure-BootstrapPurviewPolicies `
                -Config $config `
                -Blueprint ([pscustomobject]@{ applicationId = '33333333-3333-4333-8333-333333333333' }) `
                -UserPrincipalName $script:userPrincipalName } |
                Should -Throw '*stop-after-tenant-bound-connect*'

            Should -Invoke Connect-BootstrapPurview -Times 1 -Exactly -ParameterFilter {
                $TenantId -eq $script:tenantId -and $UserPrincipalName -eq $script:userPrincipalName
            }
        }
    }
}
