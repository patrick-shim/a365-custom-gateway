$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Entra.psm1') -Force

Describe 'Tenant initial verified domain lookup' {
    InModuleScope Entra {
        BeforeEach {
            $script:requestedUrls = [Collections.Generic.List[string]]::new()
        }

        It 'does not ask Microsoft Graph to filter the unsupported domains collection' {
            # Microsoft documents a known issue with $filter on the domains collection and
            # the service answers a filtered request with HTTP 400 Request_UnsupportedQuery,
            # so the initial domain has to be selected from the returned collection instead.
            Mock Get-BoundedGraphCollection {
                $script:requestedUrls.Add([string]$InitialUrl)
                return @(
                    [pscustomobject]@{ id = 'contoso.com'; isInitial = $false; isVerified = $true },
                    [pscustomobject]@{ id = 'Contoso.onmicrosoft.com'; isInitial = $true; isVerified = $true })
            }

            Get-BootstrapInitialTenantDomain | Should -BeExactly 'contoso.onmicrosoft.com'

            $script:requestedUrls.Count | Should -Be 1
            $script:requestedUrls[0] | Should -Not -Match '\$filter'
            $script:requestedUrls[0] | Should -Not -Match 'isInitial'
            $script:requestedUrls[0] | Should -Match '^https://graph\.microsoft\.com/v1\.0/domains'
        }

        It 'refuses a tenant that reports no initial domain' {
            Mock Get-BoundedGraphCollection {
                return @([pscustomobject]@{ id = 'contoso.com'; isInitial = $false; isVerified = $true })
            }

            { Get-BootstrapInitialTenantDomain } | Should -Throw '*initial verified domain*'
        }

        It 'refuses a tenant that reports more than one initial domain' {
            Mock Get-BoundedGraphCollection {
                return @(
                    [pscustomobject]@{ id = 'first.onmicrosoft.com'; isInitial = $true; isVerified = $true },
                    [pscustomobject]@{ id = 'second.onmicrosoft.com'; isInitial = $true; isVerified = $true })
            }

            { Get-BootstrapInitialTenantDomain } | Should -Throw '*initial verified domain*'
        }

        It 'refuses an unverified initial domain' {
            Mock Get-BoundedGraphCollection {
                return @([pscustomobject]@{ id = 'contoso.onmicrosoft.com'; isInitial = $true; isVerified = $false })
            }

            { Get-BootstrapInitialTenantDomain } | Should -Throw '*initial verified domain*'
        }

        It 'refuses an initial domain whose name is not a plain domain' {
            Mock Get-BoundedGraphCollection {
                return @([pscustomobject]@{ id = 'not a domain'; isInitial = $true; isVerified = $true })
            }

            { Get-BootstrapInitialTenantDomain } | Should -Throw '*initial verified domain*'
        }
    }
}
