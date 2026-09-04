$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Purview.psm1') -Force

Describe 'Purview exact typed readback' {
    InModuleScope Purview {
        BeforeEach {
            $script:blueprintId = '11111111-1111-4111-8111-111111111111'
            $script:sensitiveInformationTypeId = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'
            $script:enterpriseAiAppsCollectionLocationId = 'ee1680d0-702f-4090-b26c-c49091e86531'
            $script:collectionLocations = ConvertTo-Json -InputObject @(@{
                Workload = 'Applications'
                Location = $script:enterpriseAiAppsCollectionLocationId
                LocationSource = 'Entra'
                LocationType = 'Group'
                Inclusions = @(@{ Type = 'Tenant'; Identity = 'All' })
            }) -Depth 10 -Compress
            $script:dlpLocations = ConvertTo-Json -InputObject @(@{
                Workload = 'Applications'
                Location = $script:blueprintId
                LocationDisplayName = 'Reviewed blueprint'
                LocationSource = 'Entra'
                LocationType = 'Individual'
                Inclusions = @(@{ Type = 'Tenant'; Identity = 'All' })
            }) -Depth 10 -Compress
            $script:scenario = @{
                Activities = @('UploadText', 'DownloadText')
                EnforcementPlanes = @('Application')
                SensitiveTypeIds = @('All')
                IsIngestionEnabled = $true
            } | ConvertTo-Json -Depth 10 -Compress
            function New-ReviewedDlpPolicy {
                param([string]$Locations = $script:dlpLocations)
                return [pscustomobject]@{
                    Name = 'Policy'
                    Mode = 'Enable'
                    Type = 'Dlp'
                    Enabled = $true
                    ReadOnly = $false
                    Workload = 'Exchange, SharePoint, OneDriveForBusiness, Applications'
                    PolicyCategory = 'Unknown'
                    GlobalListType = 'None'
                    ForceValidate = $false
                    DistributionStatus = 'Pending'
                    DistributionSyncStatus = 'Pending'
                    PolicyConstraints = '{"AdministrativeUnit":[]}'
                    PolicyRBACScopes = $null
                    PolicyRulesMetaData = ''
                    ErrorMetadata = $null
                    DistributionResults = $null
                    UserAdministrativeUnitMembershipMap = $null
                    EnforcementPlanes = @('Application')
                    Locations = $Locations
                }
            }
        }

        It 'serializes distinct collection and DLP application location contracts as provider arrays' {
            $collectionJson = ConvertTo-BootstrapPurviewCollectionLocationsJson
            $dlpJson = ConvertTo-BootstrapPurviewDlpLocationsJson `
                -BlueprintApplicationId $script:blueprintId `
                -BlueprintDisplayName 'Reviewed blueprint'

            foreach ($json in @($collectionJson, $dlpJson)) {
                $json.TrimStart().StartsWith('[', [StringComparison]::Ordinal) | Should -BeTrue
                $locations = @($json | ConvertFrom-Json)
                $locations.Count | Should -Be 1
            }
            $collectionLocation = (@($collectionJson | ConvertFrom-Json))[0]
            $dlpLocation = (@($dlpJson | ConvertFrom-Json))[0]
            $collectionLocation.Location | Should -BeExactly $script:enterpriseAiAppsCollectionLocationId
            $collectionLocation.LocationType | Should -BeExactly 'Group'
            $collectionLocation.PSObject.Properties.Name | Should -Not -Contain 'LocationDisplayName'
            $dlpLocation.Location | Should -BeExactly $script:blueprintId
            $dlpLocation.LocationType | Should -BeExactly 'Individual'
        }

        It 'passes Group only to KYD creation and Individual only to DLP creation' {
            $script:observedCollectionLocations = $null
            $script:observedDlpLocations = $null
            function Get-FeatureConfiguration { param($FeatureScenario) }
            function Get-DlpCompliancePolicy { param($Identity, $ErrorAction) }
            function Get-DlpComplianceRule { param($Identity, $ErrorAction) }
            function New-FeatureConfiguration { param($FeatureScenario, $Name, $Mode, $ScenarioConfig, $Locations, $Confirm) }
            function New-DlpCompliancePolicy { param($Name, $Mode, $Locations, $EnforcementPlanes, $Confirm) }
            function New-DlpComplianceRule { param($Name, $Policy, $ContentContainsSensitiveInformation, $RestrictAccess, $Confirm) }
            Mock Connect-BootstrapPurview { '22222222-2222-4222-8222-222222222222' }
            Mock Disconnect-BootstrapPurview {}
            Mock Get-FeatureConfiguration { @() }
            Mock Get-DlpCompliancePolicy { @() }
            Mock Get-DlpComplianceRule { @() }
            Mock New-FeatureConfiguration { $script:observedCollectionLocations = $Locations }
            Mock New-DlpCompliancePolicy { $script:observedDlpLocations = $Locations }
            Mock New-DlpComplianceRule {}
            Mock Resolve-BootstrapPurviewSensitiveInformationType {
                [pscustomobject]@{
                    id = $script:sensitiveInformationTypeId
                    name = 'Credit Card Number'
                    publisher = 'Microsoft Corporation'
                }
            }
            Mock Get-BootstrapPurviewPolicyEvidence { [ordered]@{ configured = $true } }
            $config = [pscustomobject]@{
                tenantId = '22222222-2222-4222-8222-222222222222'
                purview = [pscustomobject]@{
                    enabled = $true
                    collectionPolicyName = 'Collection'
                    dlpPolicyName = 'Policy'
                    dlpRuleName = 'Rule'
                    sensitiveInformationTypeId = $script:sensitiveInformationTypeId
                    sensitiveInformationType = 'Credit Card Number'
                }
            }
            $blueprint = [pscustomobject]@{
                applicationId = $script:blueprintId
                displayName = 'Reviewed blueprint'
            }

            Ensure-BootstrapPurviewPolicies `
                -Config $config `
                -Blueprint $blueprint `
                -UserPrincipalName 'operator@example.test' | Out-Null

            (@($script:observedCollectionLocations | ConvertFrom-Json))[0].LocationType |
                Should -BeExactly 'Group'
            (@($script:observedDlpLocations | ConvertFrom-Json))[0].LocationType |
                Should -BeExactly 'Individual'
            Should -Invoke Resolve-BootstrapPurviewSensitiveInformationType -Times 2 -Exactly -ParameterFilter {
                $Id -ceq $script:sensitiveInformationTypeId -and $Name -ceq 'Credit Card Number'
            }
            Should -Invoke New-DlpComplianceRule -Times 1 -Exactly -ParameterFilter {
                $ContentContainsSensitiveInformation.Name -ceq 'Credit Card Number'
            }
        }

        It 'accepts only the exact reviewed collection, policy, and rule fields' {
            $collection = [pscustomobject]@{
                Name = 'Collection'
                Mode = 'Enable'
                Type = 'KnowYourData'
                Scenario = 'KnowYourData'
                Enabled = $true
                ReadOnly = $false
                Workload = 'Exchange, Applications'
                PolicyCategory = 'Unknown'
                GlobalListType = 'None'
                ForceValidate = $false
                DistributionStatus = 'Pending'
                DistributionSyncStatus = 'Unknown'
                PolicyConstraints = '{"AdministrativeUnit":[]}'
                PolicyRBACScopes = $null
                PolicyRulesMetaData = ''
                ErrorMetadata = $null
                DistributionResults = $null
                UserAdministrativeUnitMembershipMap = $null
                ScenarioConfig = $script:scenario
                Locations = $script:collectionLocations
            }
            $policy = New-ReviewedDlpPolicy
            $rule = [pscustomobject]@{
                Name = 'Rule'
                ParentPolicyName = 'Policy'
                Mode = 'Enforce'
                Workload = 'Exchange, SharePoint, OneDriveForBusiness, Applications'
                ReadOnly = $false
                IsAdvancedRule = $false
                EnforcePortalAccess = $true
                NotifyEmailExchangeIncludeAttachment = $true
                ReportSeverityLevel = 'Low'
                MaximumBlobRuleLength = 0
                ExternalScenarioDependancies = [pscustomobject]@{}
                AdvancedRule = (@{
                    Version = '1.0'
                    Condition = @{
                        Operator = 'And'
                        SubConditions = @(@{
                            ConditionName = 'ContentContainsSensitiveInformation'
                            Value = @(@{
                                Name = 'Credit Card Number'; classifiertype = 'Content'; mincount = '1'
                                confidencelevel = 'High'; minconfidence = '85'; maxconfidence = '100'
                                maxcount = '-1'; id = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'
                            })
                        })
                    }
                } | ConvertTo-Json -Depth 10)
                ContentContainsSensitiveInformation = @{
                    Name = 'Credit Card Number'
                    classifiertype = 'Content'
                    mincount = '1'
                    confidencelevel = 'High'
                    minconfidence = '85'
                    maxconfidence = '100'
                    maxcount = '-1'
                    id = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'
                }
                RestrictAccess = @(@{ setting = 'UploadText'; value = 'Block' })
            }

            { Assert-BootstrapPurviewCollectionObject -Collection $collection -Name 'Collection' } | Should -Not -Throw
            { Assert-BootstrapPurviewPolicyObject -Policy $policy -Name 'Policy' -BlueprintApplicationId $script:blueprintId } | Should -Not -Throw
            { Assert-BootstrapPurviewRuleObject -Rule $rule -Name 'Rule' -PolicyName 'Policy' -SensitiveInformationTypeId $script:sensitiveInformationTypeId -SensitiveInformationType 'Credit Card Number' } | Should -Not -Throw
        }

        It 'rejects collection and DLP location types when their contracts are conflated' {
            $blueprintGroupLocations = ConvertTo-Json -InputObject @(@{
                Workload = 'Applications'
                Location = $script:blueprintId
                LocationSource = 'Entra'
                LocationType = 'Group'
                Inclusions = @(@{ Type = 'Tenant'; Identity = 'All' })
            }) -Depth 10 -Compress
            $collection = [pscustomobject]@{
                Name = 'Collection'; Mode = 'Enable'; Type = 'KnowYourData'; Scenario = 'KnowYourData'
                Enabled = $true; ReadOnly = $false; Workload = 'Exchange, Applications'
                PolicyCategory = 'Unknown'; GlobalListType = 'None'; ForceValidate = $false
                DistributionStatus = 'Pending'; DistributionSyncStatus = 'Unknown'
                PolicyConstraints = '{"AdministrativeUnit":[]}'
                PolicyRBACScopes = $null; PolicyRulesMetaData = ''; ErrorMetadata = $null
                DistributionResults = $null; UserAdministrativeUnitMembershipMap = $null
                ScenarioConfig = $script:scenario; Locations = $blueprintGroupLocations
            }
            $policy = New-ReviewedDlpPolicy -Locations $script:collectionLocations

            { Assert-BootstrapPurviewCollectionObject -Collection $collection -Name 'Collection' } |
                Should -Throw '*application location does not exactly match*'
            { Assert-BootstrapPurviewPolicyObject -Policy $policy -Name 'Policy' -BlueprintApplicationId $script:blueprintId } |
                Should -Throw '*application location does not exactly match*'
        }

        It 'rejects an added collection enforcement plane' {
            $scenario = @{
                Activities = @('UploadText', 'DownloadText')
                EnforcementPlanes = @('Application', 'Browser')
                SensitiveTypeIds = @('All')
                IsIngestionEnabled = $true
            } | ConvertTo-Json -Compress
            $collection = [pscustomobject]@{
                Name = 'Collection'; Mode = 'Enable'; Type = 'KnowYourData'; Scenario = 'KnowYourData'
                Enabled = $true; ReadOnly = $false; Workload = 'Exchange, Applications'
                PolicyCategory = 'Unknown'; GlobalListType = 'None'; ForceValidate = $false
                DistributionStatus = 'Pending'; DistributionSyncStatus = 'Unknown'
                PolicyConstraints = '{"AdministrativeUnit":[]}'
                PolicyRBACScopes = $null; PolicyRulesMetaData = ''; ErrorMetadata = $null
                DistributionResults = $null; UserAdministrativeUnitMembershipMap = $null
                ScenarioConfig = $scenario; Locations = $script:collectionLocations
            }

            { Assert-BootstrapPurviewCollectionObject -Collection $collection -Name 'Collection' } |
                Should -Throw '*does not match the exact reviewed*'
        }

        It 'rejects a rule that does not block UploadText with the one configured classifier' {
            $rule = [pscustomobject]@{
                Name = 'Rule'
                ParentPolicyName = 'Policy'
                ContentContainsSensitiveInformation = @(@{ Name = 'Credit Card Number' }, @{ Name = 'Passport Number' })
                RestrictAccess = @(@{ setting = 'DownloadText'; value = 'Audit' })
            }

            { Assert-BootstrapPurviewRuleObject -Rule $rule -Name 'Rule' -PolicyName 'Policy' -SensitiveInformationTypeId $script:sensitiveInformationTypeId -SensitiveInformationType 'Credit Card Number' } |
                Should -Throw '*classifier does not exactly match*'
        }

        It 'rejects unknown meaningful collection and policy behavior' {
            $collection = [pscustomobject]@{
                Name = 'Collection'; Mode = 'Enable'; Type = 'KnowYourData'; Scenario = 'KnowYourData'
                Enabled = $true; ReadOnly = $false; Workload = 'Exchange, Applications'
                PolicyCategory = 'Unknown'; GlobalListType = 'None'; ForceValidate = $false
                DistributionStatus = 'Pending'; DistributionSyncStatus = 'Unknown'
                PolicyConstraints = '{"AdministrativeUnit":[]}'
                PolicyRBACScopes = $null; PolicyRulesMetaData = ''; ErrorMetadata = $null
                DistributionResults = $null; UserAdministrativeUnitMembershipMap = $null
                ScenarioConfig = $script:scenario; Locations = $script:collectionLocations
                UnreviewedCollectionSwitch = 'Enabled'
            }
            $policy = New-ReviewedDlpPolicy
            $policy | Add-Member -NotePropertyName UnreviewedPolicySwitch -NotePropertyValue @('extra')

            { Assert-BootstrapPurviewCollectionObject -Collection $collection -Name 'Collection' } |
                Should -Throw '*unrecognized meaningful property*'
            { Assert-BootstrapPurviewPolicyObject -Policy $policy -Name 'Policy' -BlueprintApplicationId $script:blueprintId } |
                Should -Throw '*unrecognized meaningful property*'
        }

        It 'rejects an unexpected DLP provider type, workload, or hidden administrative scope' {
            foreach ($mutation in @(
                @{ Name = 'Type'; Value = 'Unknown' },
                @{ Name = 'Workload'; Value = 'Applications' },
                @{ Name = 'PolicyConstraints'; Value = '{"AdministrativeUnit":["unreviewed"]}' }
            )) {
                $policy = New-ReviewedDlpPolicy
                $policy.($mutation.Name) = $mutation.Value
                { Assert-BootstrapPurviewPolicyObject -Policy $policy -Name 'Policy' -BlueprintApplicationId $script:blueprintId } |
                    Should -Throw
            }
        }

        It 'rejects hidden collection scope and failed distribution state' {
            $collection = [pscustomobject]@{
                Name = 'Collection'; Mode = 'Enable'; Type = 'KnowYourData'; Scenario = 'KnowYourData'
                Enabled = $true; ReadOnly = $false; Workload = 'Exchange, Applications'
                PolicyCategory = 'Unknown'; GlobalListType = 'None'; ForceValidate = $false
                DistributionStatus = 'Error'; DistributionSyncStatus = 'Unknown'
                PolicyConstraints = '{"AdministrativeUnit":["unreviewed"]}'
                PolicyRBACScopes = @('unreviewed'); PolicyRulesMetaData = ''; ErrorMetadata = $null
                DistributionResults = $null; UserAdministrativeUnitMembershipMap = $null
                ScenarioConfig = $script:scenario; Locations = $script:collectionLocations
            }

            { Assert-BootstrapPurviewCollectionObject -Collection $collection -Name 'Collection' } |
                Should -Throw
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

                { Assert-BootstrapPurviewRuleObject -Rule $rule -Name 'Rule' -PolicyName 'Policy' -SensitiveInformationTypeId $script:sensitiveInformationTypeId -SensitiveInformationType 'Credit Card Number' } |
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
                ContentContainsSensitiveInformation = @{
                    Name = 'Credit Card Number'; classifiertype = 'Content'; mincount = '1'
                    confidencelevel = 'High'; minconfidence = '85'; maxconfidence = '100'
                    maxcount = '-1'; id = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'
                    Confidence = 'Low'
                }
                RestrictAccess = @(@{ setting = 'UploadText'; value = 'Block' })
            }

            { Assert-BootstrapPurviewRuleObject -Rule $duplicate -Name 'Rule' -PolicyName 'Policy' -SensitiveInformationTypeId $script:sensitiveInformationTypeId -SensitiveInformationType 'Credit Card Number' } |
                Should -Throw '*classifier does not exactly match*'
            { Assert-BootstrapPurviewRuleObject -Rule $unknownClassifierField -Name 'Rule' -PolicyName 'Policy' -SensitiveInformationTypeId $script:sensitiveInformationTypeId -SensitiveInformationType 'Credit Card Number' } |
                Should -Throw '*unrecognized meaningful property*'
        }

        It 'rejects changed provider-expanded classifier thresholds' {
            $rule = [pscustomobject]@{
                Name = 'Rule'
                ParentPolicyName = 'Policy'
                Mode = 'Enforce'
                Workload = 'Exchange, SharePoint, OneDriveForBusiness, Applications'
                ReadOnly = $false
                ContentContainsSensitiveInformation = @{
                    Name = 'Credit Card Number'; classifiertype = 'Content'; mincount = '1'
                    confidencelevel = 'Low'; minconfidence = '65'; maxconfidence = '100'
                    maxcount = '-1'; id = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'
                }
                RestrictAccess = @(@{ setting = 'UploadText'; value = 'Block' })
            }

            { Assert-BootstrapPurviewRuleObject -Rule $rule -Name 'Rule' -PolicyName 'Policy' -SensitiveInformationTypeId $script:sensitiveInformationTypeId -SensitiveInformationType 'Credit Card Number' } |
                Should -Throw '*thresholds or provider identity*'
        }

        It 'rejects a classifier GUID that differs from the configured tenant SIT GUID' {
            $rule = [pscustomobject]@{
                Name = 'Rule'
                ParentPolicyName = 'Policy'
                ContentContainsSensitiveInformation = @{
                    Name = 'Credit Card Number'; classifiertype = 'Content'; mincount = '1'
                    confidencelevel = 'High'; minconfidence = '85'; maxconfidence = '100'
                    maxcount = '-1'; id = '99999999-9999-4999-8999-999999999999'
                }
                RestrictAccess = @(@{ setting = 'UploadText'; value = 'Block' })
            }

            { Assert-BootstrapPurviewRuleObject -Rule $rule -Name 'Rule' -PolicyName 'Policy' -SensitiveInformationTypeId $script:sensitiveInformationTypeId -SensitiveInformationType 'Credit Card Number' } |
                Should -Throw '*thresholds or provider identity*'
        }

        It 'projects the tenant inventory deterministically without leaking provider fields' {
            $types = @(ConvertTo-BootstrapPurviewSensitiveInformationTypeProjection -InputObject @(
                [pscustomobject]@{
                    Id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
                    Name = '中文類別'
                    Publisher = 'Contoso'
                    UnreviewedProviderBody = 'must-not-escape'
                },
                [pscustomobject]@{
                    Id = $script:sensitiveInformationTypeId.ToUpperInvariant()
                    Name = 'Credit Card Number'
                    Publisher = 'Microsoft Corporation'
                }
            ))

            $types.Count | Should -Be 2
            $types[0].id | Should -BeExactly $script:sensitiveInformationTypeId
            $types[0].name | Should -BeExactly 'Credit Card Number'
            $types[1].name | Should -BeExactly '中文類別'
            @($types[0].PSObject.Properties.Name) | Should -Be @('id', 'name', 'publisher')
            @($types[1].PSObject.Properties.Name) | Should -Be @('id', 'name', 'publisher')
        }

        It 'enumerates tenant SITs with the documented no-argument command and masks provider failures' {
            function Get-DlpSensitiveInformationType { param($Identity, $ErrorAction) }
            Mock Get-DlpSensitiveInformationType {
                [pscustomobject]@{
                    Id = $script:sensitiveInformationTypeId
                    Name = 'Credit Card Number'
                    Publisher = 'Microsoft Corporation'
                }
            }

            @(Get-BootstrapPurviewSensitiveInformationTypes).Count | Should -Be 1
            Should -Invoke Get-DlpSensitiveInformationType -Times 1 -Exactly

            Mock Get-DlpSensitiveInformationType { throw 'private-provider-marker' }
            try {
                Get-BootstrapPurviewSensitiveInformationTypes
                throw 'Expected provider failure.'
            }
            catch {
                $_.Exception.Message | Should -BeLike '*inventory could not be read*'
                $_.Exception.Message | Should -Not -BeLike '*private-provider-marker*'
            }
        }

        It 'fails closed for ambiguous, malformed, or oversized tenant inventory' {
            { ConvertTo-BootstrapPurviewSensitiveInformationTypeProjection -InputObject @(
                [pscustomobject]@{ Id = $script:sensitiveInformationTypeId; Name = 'Duplicate'; Publisher = 'One' },
                [pscustomobject]@{ Id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; Name = 'Duplicate'; Publisher = 'Two' }
            ) } | Should -Throw '*duplicate exact Name*'
            { ConvertTo-BootstrapPurviewSensitiveInformationTypeProjection -InputObject @(
                [pscustomobject]@{ Id = 'not-a-guid'; Name = 'Invalid'; Publisher = 'One' }
            ) } | Should -Throw '*invalid Id*'
            $tooMany = @(1..2049 | ForEach-Object {
                [pscustomobject]@{ Id = [guid]::NewGuid(); Name = "Type $_"; Publisher = 'Publisher' }
            })
            { ConvertTo-BootstrapPurviewSensitiveInformationTypeProjection -InputObject $tooMany } |
                Should -Throw '*2048-item limit*'
        }

        It 'preserves an exact 255-character Unicode Name and rejects 256 characters' {
            $acceptedName = '類' * 255
            $accepted = @(ConvertTo-BootstrapPurviewSensitiveInformationTypeProjection -InputObject @(
                [pscustomobject]@{
                    Id = $script:sensitiveInformationTypeId
                    Name = $acceptedName
                    Publisher = 'Publisher'
                }
            ))
            $accepted[0].name | Should -BeExactly $acceptedName
            $accepted[0].name.Length | Should -Be 255

            { ConvertTo-BootstrapPurviewSensitiveInformationTypeProjection -InputObject @(
                [pscustomobject]@{
                    Id = $script:sensitiveInformationTypeId
                    Name = ('類' * 256)
                    Publisher = 'Publisher'
                }
            ) } | Should -Throw '*invalid Name*'
        }

        It 're-resolves by canonical GUID and requires the exact Unicode Name' {
            function Get-DlpSensitiveInformationType { param($Identity, $ErrorAction) }
            Mock Get-DlpSensitiveInformationType {
                @(
                    [pscustomobject]@{ Id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; Name = 'Other'; Publisher = 'Contoso' },
                    [pscustomobject]@{ Id = $script:sensitiveInformationTypeId; Name = 'クレジット カード番号'; Publisher = 'Microsoft Corporation' }
                )
            }

            $resolved = Resolve-BootstrapPurviewSensitiveInformationType `
                -Id $script:sensitiveInformationTypeId.ToUpperInvariant() `
                -Name 'クレジット カード番号'
            $resolved.id | Should -BeExactly $script:sensitiveInformationTypeId
            $resolved.name | Should -BeExactly 'クレジット カード番号'
            Should -Invoke Get-DlpSensitiveInformationType -Times 1 -Exactly

            { Resolve-BootstrapPurviewSensitiveInformationType `
                -Id $script:sensitiveInformationTypeId `
                -Name 'クレジットカード番号' } |
                Should -Throw '*ID and exact Name no longer match*'
        }

        It 'reports the runtime adapter as enabled once the reviewed policy objects pass exact typed readback' {
            function Get-FeatureConfiguration { param($FeatureScenario) }
            function Get-DlpCompliancePolicy { param($Identity, $ErrorAction) }
            function Get-DlpComplianceRule { param($Identity, $ErrorAction) }
            Mock Get-FeatureConfiguration { [pscustomobject]@{ Name = 'Collection'; Identity = 'Collection' } }
            Mock Get-DlpCompliancePolicy { @([pscustomobject]@{ Name = 'Policy'; Identity = 'Policy' }) }
            Mock Get-DlpComplianceRule { @([pscustomobject]@{ Name = 'Rule'; Identity = 'Rule' }) }
            Mock Resolve-BootstrapPurviewSensitiveInformationType {
                [pscustomobject]@{
                    id = $script:sensitiveInformationTypeId
                    name = 'Credit Card Number'
                    publisher = 'Microsoft Corporation'
                }
            }
            Mock Assert-BootstrapPurviewCollectionObject { $true }
            Mock Assert-BootstrapPurviewPolicyObject { $true }
            Mock Assert-BootstrapPurviewRuleObject { $true }

            $evidence = Get-BootstrapPurviewPolicyEvidence `
                -Config ([pscustomobject]@{
                    tenantId = '22222222-2222-4222-8222-222222222222'
                    purview = [pscustomobject]@{
                        enabled = $true
                        collectionPolicyName = 'Collection'
                        dlpPolicyName = 'Policy'
                        dlpRuleName = 'Rule'
                        sensitiveInformationTypeId = $script:sensitiveInformationTypeId
                        sensitiveInformationType = 'Credit Card Number'
                    }
                }) `
                -Blueprint ([pscustomobject]@{
                    applicationId = $script:blueprintId
                    displayName = 'Reviewed blueprint'
                }) `
                -MaximumAttempts 1

            $evidence.configured | Should -BeTrue
            # The adapter must become reachable, otherwise a reviewed blueprint DLP
            # policy can never produce a runtime verdict and the feature is dead.
            $evidence.enabled | Should -BeTrue
            $evidence.exactTypedReadback | Should -BeTrue
            $evidence.blueprintApplicationId | Should -BeExactly $script:blueprintId
            $evidence.enforcementPlane | Should -BeExactly 'Application'
            # Authoring readback is not runtime proof; propagation stays unproven.
            $evidence.propagationStatus | Should -BeExactly 'PendingLiveVerification'
        }

        It 'keeps the runtime adapter disabled when the reviewed configuration does not request Purview' {
            $evidence = Ensure-BootstrapPurviewPolicies `
                -Config ([pscustomobject]@{ purview = [pscustomobject]@{ enabled = $false } }) `
                -Blueprint ([pscustomobject]@{ applicationId = $script:blueprintId }) `
                -UserPrincipalName 'operator@example.test'

            $evidence.configured | Should -BeFalse
            $evidence.enabled | Should -BeFalse
        }
    }
}
