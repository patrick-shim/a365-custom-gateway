Describe 'Runtime Purview policy profile exact readback' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $script:AutomationPath = Join-Path $script:RepositoryRoot `
            'src/Gateway.Purview/Automation/Ensure-PurviewPolicyProfile.ps1'
        $tokens = $null
        $parseErrors = $null
        $automationAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:AutomationPath,
            [ref]$tokens,
            [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw 'Runtime Purview automation did not parse for focused behavior tests.'
        }
        $script:EnterpriseAiAppsCollectionLocationId =
            'ee1680d0-702f-4090-b26c-c49091e86531'
        foreach ($definition in @($automationAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true))) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }

        function Get-FeatureConfiguration { }
        function Get-DlpCompliancePolicy { }
        function Get-DlpComplianceRule { }
        function New-FeatureConfiguration { }
        function New-DlpCompliancePolicy { }
        function New-DlpComplianceRule { }
        function Set-DlpCompliancePolicy { }
        $script:NewExactObjects = {
            param(
                [Parameter(Mandatory)]
                [Alias('DlpApplicationId')]
                [string[]]$DlpApplicationIds
            )

            $collectionLocations = @([pscustomobject]@{
                Workload = 'Applications'
                Location = 'ee1680d0-702f-4090-b26c-c49091e86531'
                LocationSource = 'Entra'
                LocationType = 'Group'
                Inclusions = @([pscustomobject]@{ Type = 'Tenant'; Identity = 'All' })
            })
            $dlpLocations = @($DlpApplicationIds | ForEach-Object {
                [pscustomobject]@{
                    Workload = 'Applications'
                    Location = $_
                    LocationDisplayName = 'Reviewed blueprint'
                    LocationSource = 'Entra'
                    LocationType = 'Individual'
                    Inclusions = @([pscustomobject]@{ Type = 'Tenant'; Identity = 'All' })
                }
            })
            $scenario = [pscustomobject]@{
                Activities = @('UploadText', 'DownloadText')
                EnforcementPlanes = @('Application')
                SensitiveTypeIds = @('All')
                IsIngestionEnabled = $true
            }
            return [pscustomobject]@{
                Collection = [pscustomobject]@{
                    Name = 'collection'
                    Identity = 'collection-id'
                    Mode = 'Enable'
                    ScenarioConfig = $scenario
                    Locations = $collectionLocations
                }
                Policy = [pscustomobject]@{
                    Name = 'policy'
                    Identity = 'policy-id'
                    Mode = 'Enable'
                    EnforcementPlanes = @('Application')
                    Locations = $dlpLocations
                }
                Rule = [pscustomobject]@{
                    Name = 'rule'
                    Identity = 'rule-id'
                    ParentPolicyName = 'policy'
                    ContentContainsSensitiveInformation = @(
                        [pscustomobject]@{ Name = 'Credit Card Number' })
                    RestrictAccess = @(
                        [pscustomobject]@{ setting = 'UploadText'; value = 'Block' })
                }
            }
        }
    }

    BeforeEach {
        $script:BlueprintId = '11111111-1111-4111-8111-111111111111'
        $script:OtherBlueprintId = '22222222-2222-4222-8222-222222222222'
        $script:InputObject = [pscustomobject]@{
            collectionPolicyName = 'collection'
            dlpPolicyName = 'policy'
            dlpRuleName = 'rule'
            blueprintApplicationId = $script:BlueprintId
            blueprintDisplayName = 'Reviewed blueprint'
            sensitiveInformationType = 'Credit Card Number'
            expectedCollectionPolicyId = 'collection-id'
            expectedDlpPolicyId = 'policy-id'
            expectedDlpRuleId = 'rule-id'
            expectedPriorDlpBlueprintApplicationIds = @()
            expectedDlpBlueprintApplicationIds = @($script:BlueprintId)
        }
    }

    It 'propagates a collection lookup failure instead of translating it to absence' {
        Mock Get-FeatureConfiguration { throw 'provider lookup unavailable' }
        Mock New-FeatureConfiguration { throw 'create must not run' }

        { Get-ExactCollectionPolicy -Name 'collection' } |
            Should -Throw '*provider lookup unavailable*'

        Should -Invoke Get-FeatureConfiguration -Times 1 -Exactly
        Should -Invoke New-FeatureConfiguration -Times 0 -Exactly
    }

    It 'rejects a wrong provider ID and wrong blueprint scope' {
        $objects = & $script:NewExactObjects -DlpApplicationId $script:OtherBlueprintId
        $objects.Collection.Identity = 'wrong-collection-id'

        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedDlpApplicationIds @($script:BlueprintId) } |
            Should -Throw
    }

    It 'rejects an extra exclusion or bypass on an application location' {
        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $objects.Collection.Locations[0] | Add-Member -NotePropertyName Exclusions `
            -NotePropertyValue @(@{ Type = 'Tenant'; Identity = 'Except' })

        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedDlpApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unreviewed*Exclusions*'
    }

    It 'rejects extra rule conditions and actions' {
        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $objects.Rule | Add-Member -NotePropertyName ExceptIfContentContainsWords `
            -NotePropertyValue @('bypass marker')
        $objects.Rule | Add-Member -NotePropertyName NotifyUser `
            -NotePropertyValue @('SiteAdmin')

        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedDlpApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unreviewed*'
    }

    It 'rejects an unknown meaningful rule behavior property' {
        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $objects.Rule | Add-Member -NotePropertyName FutureAutonomousAllow `
            -NotePropertyValue 'Enabled'

        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedDlpApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FutureAutonomousAllow*'
    }

    It 'rejects unknown meaningful collection and policy behavior properties' {
        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $objects.Collection | Add-Member -NotePropertyName FutureCollectionBypass `
            -NotePropertyValue 'Enabled'

        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedDlpApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FutureCollectionBypass*'

        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $objects.Policy | Add-Member -NotePropertyName FuturePolicyExclusion `
            -NotePropertyValue 'Enabled'

        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedDlpApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FuturePolicyExclusion*'
    }

    It 'rejects unknown meaningful nested scenario, inclusion, condition, and action behavior' {
        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $objects.Collection.ScenarioConfig | Add-Member -NotePropertyName FutureScenarioBypass `
            -NotePropertyValue 'Enabled'
        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedDlpApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FutureScenarioBypass*'

        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $objects.Collection.Locations[0].Inclusions[0] |
            Add-Member -NotePropertyName FutureInclusionException -NotePropertyValue 'Enabled'
        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedDlpApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FutureInclusionException*'

        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $objects.Rule.ContentContainsSensitiveInformation[0] |
            Add-Member -NotePropertyName FutureClassifierException -NotePropertyValue 'Enabled'
        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedDlpApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FutureClassifierException*'

        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $objects.Rule.RestrictAccess[0] |
            Add-Member -NotePropertyName FutureActionFallback -NotePropertyValue 'Allow'
        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedDlpApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FutureActionFallback*'
    }

    It 'accepts the exact typed collection, policy, classifier, and UploadText action' {
        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId

        $result = Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedDlpApplicationIds @($script:BlueprintId)

        $result.collectionPolicyId | Should -Be 'collection-id'
        $result.collectionLocation.locationIds | Should -Contain `
            'ee1680d0-702f-4090-b26c-c49091e86531'
        $result.collectionLocation.locationType | Should -BeExactly 'Group'
        $result.dlpBlueprintApplicationIds | Should -Contain $script:BlueprintId
        $result.dlpLocation.locationType | Should -BeExactly 'Individual'
        $result.hasExtraConditions | Should -BeFalse
        $result.hasExtraActions | Should -BeFalse
    }

    It 'rejects an untrusted extra DLP application before mutation' {
        $script:InputObject.blueprintApplicationId = $script:OtherBlueprintId
        $script:InputObject.expectedPriorDlpBlueprintApplicationIds = @($script:BlueprintId)
        $script:InputObject.expectedDlpBlueprintApplicationIds = @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        $untrustedId = '33333333-3333-4333-8333-333333333333'
        $objects = & $script:NewExactObjects -DlpApplicationIds @(
            $script:BlueprintId,
            $untrustedId)
        Mock Get-FeatureConfiguration { $objects.Collection }
        Mock Get-DlpCompliancePolicy { $objects.Policy }
        Mock Get-DlpComplianceRule { $objects.Rule }
        Mock Set-DlpCompliancePolicy { throw 'mutation must not run' }

        { Invoke-ExactPurviewProfile -InputObject $script:InputObject `
            -ExpectedDlpMode 'Enable' } |
            Should -Throw '*exact prior nor expected authorized DLP Application scope*'

        Should -Invoke Set-DlpCompliancePolicy -Times 0 -Exactly
    }

    It 'rejects a blueprint-scoped collection before DLP mutation' {
        $script:InputObject.blueprintApplicationId = $script:OtherBlueprintId
        $script:InputObject.expectedPriorDlpBlueprintApplicationIds = @($script:BlueprintId)
        $script:InputObject.expectedDlpBlueprintApplicationIds = @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $objects.Collection.Locations = @($objects.Policy.Locations)
        Mock Get-FeatureConfiguration { $objects.Collection }
        Mock Get-DlpCompliancePolicy { $objects.Policy }
        Mock Get-DlpComplianceRule { $objects.Rule }
        Mock Set-DlpCompliancePolicy { throw 'mutation must not run' }

        { Invoke-ExactPurviewProfile -InputObject $script:InputObject `
            -ExpectedDlpMode 'Enable' } |
            Should -Throw '*unreviewed Application location shape*'

        Should -Invoke Set-DlpCompliancePolicy -Times 0 -Exactly
    }

    It 'rejects behavior drift before DLP mutation' {
        $script:InputObject.blueprintApplicationId = $script:OtherBlueprintId
        $script:InputObject.expectedPriorDlpBlueprintApplicationIds = @($script:BlueprintId)
        $script:InputObject.expectedDlpBlueprintApplicationIds = @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $objects.Rule | Add-Member -NotePropertyName NotifyUser `
            -NotePropertyValue @('SiteAdmin')
        Mock Get-FeatureConfiguration { $objects.Collection }
        Mock Get-DlpCompliancePolicy { $objects.Policy }
        Mock Get-DlpComplianceRule { $objects.Rule }
        Mock Set-DlpCompliancePolicy { throw 'mutation must not run' }

        { Invoke-ExactPurviewProfile -InputObject $script:InputObject `
            -ExpectedDlpMode 'Enable' } |
            Should -Throw '*unreviewed*'

        Should -Invoke Set-DlpCompliancePolicy -Times 0 -Exactly
    }

    It 'rejects persisted provider-ID drift before DLP mutation' {
        $script:InputObject.blueprintApplicationId = $script:OtherBlueprintId
        $script:InputObject.expectedPriorDlpBlueprintApplicationIds = @($script:BlueprintId)
        $script:InputObject.expectedDlpBlueprintApplicationIds = @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $objects.Policy.Identity = 'untrusted-policy-id'
        Mock Get-FeatureConfiguration { $objects.Collection }
        Mock Get-DlpCompliancePolicy { $objects.Policy }
        Mock Get-DlpComplianceRule { $objects.Rule }
        Mock Set-DlpCompliancePolicy { throw 'mutation must not run' }

        { Invoke-ExactPurviewProfile -InputObject $script:InputObject `
            -ExpectedDlpMode 'Enable' } |
            Should -Throw '*ID did not match the persisted profile ID*'

        Should -Invoke Set-DlpCompliancePolicy -Times 0 -Exactly
    }

    It 'preserves the tenant-wide collection and extends only the exact persisted DLP scope' {
        $script:InputObject.blueprintApplicationId = $script:OtherBlueprintId
        $script:InputObject.expectedPriorDlpBlueprintApplicationIds = @($script:BlueprintId)
        $script:InputObject.expectedDlpBlueprintApplicationIds = @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $originalCollectionJson = $objects.Collection.Locations | ConvertTo-Json -Depth 20 -Compress
        Mock Get-FeatureConfiguration { $objects.Collection }
        Mock Get-DlpCompliancePolicy { $objects.Policy }
        Mock Get-DlpComplianceRule { $objects.Rule }
        Mock Set-DlpCompliancePolicy {
            param($Identity, $Locations)
            $objects.Policy.Locations = $Locations | ConvertFrom-Json -Depth 20
        }

        $result = Invoke-ExactPurviewProfile -InputObject $script:InputObject `
            -ExpectedDlpMode 'Enable'

        $result.dlpBlueprintApplicationIds | Should -HaveCount 2
        $result.dlpBlueprintApplicationIds | Should -Contain $script:BlueprintId
        $result.dlpBlueprintApplicationIds | Should -Contain $script:OtherBlueprintId
        ($objects.Collection.Locations | ConvertTo-Json -Depth 20 -Compress) |
            Should -BeExactly $originalCollectionJson
        Should -Invoke Set-DlpCompliancePolicy -Times 1 -Exactly
    }

    It 'resumes an independently verified DLP extension without repeating the Set' {
        $script:InputObject.blueprintApplicationId = $script:OtherBlueprintId
        $script:InputObject.expectedPriorDlpBlueprintApplicationIds = @($script:BlueprintId)
        $script:InputObject.expectedDlpBlueprintApplicationIds = @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        $objects = & $script:NewExactObjects -DlpApplicationIds @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        Mock Get-FeatureConfiguration { $objects.Collection }
        Mock Get-DlpCompliancePolicy { $objects.Policy }
        Mock Get-DlpComplianceRule { $objects.Rule }
        Mock Set-DlpCompliancePolicy { throw 'completed mutation must not repeat' }

        $result = Invoke-ExactPurviewProfile -InputObject $script:InputObject `
            -ExpectedDlpMode 'Enable'

        $result.dlpBlueprintApplicationIds | Should -HaveCount 2
        Should -Invoke Set-DlpCompliancePolicy -Times 0 -Exactly
    }

    It 'creates distinct fixed collection and blueprint DLP locations' {
        $objects = & $script:NewExactObjects -DlpApplicationId $script:BlueprintId
        $script:createdCollectionLocations = $null
        $script:createdCollectionScenario = $null
        $script:createdDlpLocations = $null
        $script:createdDlpEnforcementPlanes = $null
        Mock Get-FeatureConfiguration {
            if ($null -eq $script:createdCollectionLocations) { return @() }
            return $objects.Collection
        }
        Mock Get-DlpCompliancePolicy {
            if ($null -eq $script:createdDlpLocations) { return @() }
            return $objects.Policy
        }
        Mock Get-DlpComplianceRule {
            if ($null -eq $script:createdDlpLocations) { return @() }
            return $objects.Rule
        }
        Mock New-FeatureConfiguration {
            param($FeatureScenario, $Name, $Mode, $ScenarioConfig, $Locations)
            $script:createdCollectionLocations = $Locations | ConvertFrom-Json -Depth 20
            $script:createdCollectionScenario = $ScenarioConfig | ConvertFrom-Json -Depth 20
            $objects.Collection.Locations = $script:createdCollectionLocations
        }
        Mock New-DlpCompliancePolicy {
            param($Name, $Mode, $Locations, $EnforcementPlanes)
            $script:createdDlpLocations = $Locations | ConvertFrom-Json -Depth 20
            $script:createdDlpEnforcementPlanes = @($EnforcementPlanes)
            $objects.Policy.Locations = $script:createdDlpLocations
        }
        Mock New-DlpComplianceRule { }

        $script:InputObject.expectedCollectionPolicyId = $null
        $script:InputObject.expectedDlpPolicyId = $null
        $script:InputObject.expectedDlpRuleId = $null
        $result = Invoke-ExactPurviewProfile -InputObject $script:InputObject `
            -ExpectedDlpMode 'Enable'

        $script:createdCollectionLocations | Should -HaveCount 1
        $script:createdCollectionLocations.Location | Should -BeExactly `
            'ee1680d0-702f-4090-b26c-c49091e86531'
        $script:createdCollectionLocations.LocationType | Should -BeExactly 'Group'
        $script:createdCollectionScenario.EnforcementPlanes | Should -HaveCount 1
        $script:createdCollectionScenario.EnforcementPlanes | Should -Contain 'Application'
        $script:createdDlpLocations | Should -HaveCount 1
        $script:createdDlpLocations.Location | Should -BeExactly $script:BlueprintId
        $script:createdDlpLocations.LocationType | Should -BeExactly 'Individual'
        $script:createdDlpEnforcementPlanes | Should -HaveCount 1
        $script:createdDlpEnforcementPlanes | Should -Contain 'Application'
        $result.collectionLocation.locationIds | Should -Not -Contain $script:BlueprintId
        $result.dlpBlueprintApplicationIds | Should -Contain $script:BlueprintId
    }
}
