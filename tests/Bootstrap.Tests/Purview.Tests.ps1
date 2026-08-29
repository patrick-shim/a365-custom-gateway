$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Purview.psm1') -Force

Describe 'Purview exact typed readback' {
    InModuleScope Purview {
        BeforeEach {
            $script:blueprintId = '11111111-1111-4111-8111-111111111111'
            $script:locations = @(@{
                Workload = 'Applications'
                Location = $script:blueprintId
                LocationDisplayName = 'Reviewed blueprint'
                LocationSource = 'Entra'
                LocationType = 'Individual'
                Inclusions = @(@{ Type = 'Tenant'; Identity = 'All' })
            }) | ConvertTo-Json -Depth 10 -Compress
            $script:scenario = @{
                Activities = @('UploadText', 'DownloadText')
                EnforcementPlanes = @('Application')
                SensitiveTypeIds = @('All')
                IsIngestionEnabled = $true
            } | ConvertTo-Json -Depth 10 -Compress
        }

        It 'accepts only the exact reviewed collection, policy, and rule fields' {
            $collection = [pscustomobject]@{ Name = 'Collection'; Mode = 'Enable'; ScenarioConfig = $script:scenario; Locations = $script:locations }
            $policy = [pscustomobject]@{ Name = 'Policy'; Mode = 'Enable'; EnforcementPlanes = @('Application'); Locations = $script:locations }
            $rule = [pscustomobject]@{
                Name = 'Rule'
                ParentPolicyName = 'Policy'
                ContentContainsSensitiveInformation = @{ Name = 'Credit Card Number' }
                RestrictAccess = @(@{ setting = 'UploadText'; value = 'Block' })
            }

            { Assert-BootstrapPurviewCollectionObject -Collection $collection -Name 'Collection' -BlueprintApplicationId $script:blueprintId } | Should -Not -Throw
            { Assert-BootstrapPurviewPolicyObject -Policy $policy -Name 'Policy' -BlueprintApplicationId $script:blueprintId } | Should -Not -Throw
            { Assert-BootstrapPurviewRuleObject -Rule $rule -Name 'Rule' -PolicyName 'Policy' -SensitiveInformationType 'Credit Card Number' } | Should -Not -Throw
        }

        It 'rejects an added collection enforcement plane' {
            $scenario = @{
                Activities = @('UploadText', 'DownloadText')
                EnforcementPlanes = @('Application', 'Browser')
                SensitiveTypeIds = @('All')
                IsIngestionEnabled = $true
            } | ConvertTo-Json -Compress
            $collection = [pscustomobject]@{ Name = 'Collection'; Mode = 'Enable'; ScenarioConfig = $scenario; Locations = $script:locations }

            { Assert-BootstrapPurviewCollectionObject -Collection $collection -Name 'Collection' -BlueprintApplicationId $script:blueprintId } |
                Should -Throw '*does not match the exact reviewed*'
        }

        It 'rejects a rule that does not block UploadText with the one configured classifier' {
            $rule = [pscustomobject]@{
                Name = 'Rule'
                ParentPolicyName = 'Policy'
                ContentContainsSensitiveInformation = @(@{ Name = 'Credit Card Number' }, @{ Name = 'Passport Number' })
                RestrictAccess = @(@{ setting = 'DownloadText'; value = 'Audit' })
            }

            { Assert-BootstrapPurviewRuleObject -Rule $rule -Name 'Rule' -PolicyName 'Policy' -SensitiveInformationType 'Credit Card Number' } |
                Should -Throw '*classifier does not exactly match*'
        }

        It 'rejects unknown meaningful collection and policy behavior' {
            $collection = [pscustomobject]@{
                Name = 'Collection'; Mode = 'Enable'; ScenarioConfig = $script:scenario; Locations = $script:locations
                UnreviewedCollectionSwitch = 'Enabled'
            }
            $policy = [pscustomobject]@{
                Name = 'Policy'; Mode = 'Enable'; EnforcementPlanes = @('Application'); Locations = $script:locations
                UnreviewedPolicySwitch = @('extra')
            }

            { Assert-BootstrapPurviewCollectionObject -Collection $collection -Name 'Collection' -BlueprintApplicationId $script:blueprintId } |
                Should -Throw '*unrecognized meaningful property*'
            { Assert-BootstrapPurviewPolicyObject -Policy $policy -Name 'Policy' -BlueprintApplicationId $script:blueprintId } |
                Should -Throw '*unrecognized meaningful property*'
        }

        It 'rejects rule exceptions, override-capable actions, and disabled rules' {
            $baseline = [ordered]@{
                Name = 'Rule'
                ParentPolicyName = 'Policy'
                ContentContainsSensitiveInformation = @{ Name = 'Credit Card Number' }
                RestrictAccess = @(@{ setting = 'UploadText'; value = 'Block' })
            }
            foreach ($unreviewed in @(
                @{ ExceptIfDocumentNameMatchesWords = @('bypass.txt') },
                @{ NotifyUser = @('SiteAdmin') },
                @{ Disabled = $true }
            )) {
                $rule = [ordered]@{}
                foreach ($entry in $baseline.GetEnumerator()) { $rule[$entry.Key] = $entry.Value }
                foreach ($entry in $unreviewed.GetEnumerator()) { $rule[$entry.Key] = $entry.Value }

                { Assert-BootstrapPurviewRuleObject -Rule $rule -Name 'Rule' -PolicyName 'Policy' -SensitiveInformationType 'Credit Card Number' } |
                    Should -Throw
            }
        }

        It 'rejects duplicate classifiers and unknown classifier fields' {
            $duplicate = [pscustomobject]@{
                Name = 'Rule'
                ParentPolicyName = 'Policy'
                ContentContainsSensitiveInformation = @(
                    @{ Name = 'Credit Card Number' },
                    @{ Name = 'Credit Card Number' }
                )
                RestrictAccess = @(@{ setting = 'UploadText'; value = 'Block' })
            }
            $unknownClassifierField = [pscustomobject]@{
                Name = 'Rule'
                ParentPolicyName = 'Policy'
                ContentContainsSensitiveInformation = @{ Name = 'Credit Card Number'; Confidence = 'Low' }
                RestrictAccess = @(@{ setting = 'UploadText'; value = 'Block' })
            }

            { Assert-BootstrapPurviewRuleObject -Rule $duplicate -Name 'Rule' -PolicyName 'Policy' -SensitiveInformationType 'Credit Card Number' } |
                Should -Throw '*classifier does not exactly match*'
            { Assert-BootstrapPurviewRuleObject -Rule $unknownClassifierField -Name 'Rule' -PolicyName 'Policy' -SensitiveInformationType 'Credit Card Number' } |
                Should -Throw '*unrecognized meaningful property*'
        }
    }
}
