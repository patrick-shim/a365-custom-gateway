$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Entra.psm1') -Force

Describe 'Purview directory role query wire contract' {
    InModuleScope Entra {
        It 'sends supported OData query names without literal PowerShell escaping' {
            $script:capturedRoleUrl = ''
            Mock Invoke-AzJson {
                param($Arguments)
                $script:capturedRoleUrl = [string]$Arguments[4]
                return [pscustomobject]@{ value = @() }
            }
            $principalId = '44444444-4444-4444-8444-444444444444'
            $result = @(Get-BootstrapPurviewDirectoryRoleAssignments -PrincipalId $principalId)
            $result.Count | Should -Be 0
            $expected = 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?' +
                '$filter=principalId%20eq%20''' + $principalId + '''&' +
                '$select=id,principalId,roleDefinitionId,directoryScopeId'
            $script:capturedRoleUrl | Should -BeExactly $expected
            $script:capturedRoleUrl.Contains([char]96) | Should -BeFalse
            Should -Invoke Invoke-AzJson -Times 1 -Exactly
        }
    }
}
