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
        function Set-FeatureConfiguration { }
        function Set-DlpCompliancePolicy { }
        $script:NewExactObjects = {
            param(
                [Parameter(Mandatory)]
                [Alias('ApplicationId')]
                [string[]]$ApplicationIds
            )

            $locations = @($ApplicationIds | ForEach-Object {
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
                    Locations = $locations
                }
                Policy = [pscustomobject]@{
                    Name = 'policy'
                    Identity = 'policy-id'
                    Mode = 'Enable'
                    EnforcementPlanes = @('Application')
                    Locations = $locations
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
            expectedPriorBlueprintApplicationIds = @()
            expectedBlueprintApplicationIds = @($script:BlueprintId)
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
        $objects = & $script:NewExactObjects -ApplicationId $script:OtherBlueprintId
        $objects.Collection.Identity = 'wrong-collection-id'

        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedApplicationIds @($script:BlueprintId) } |
            Should -Throw
    }

    It 'rejects an extra exclusion or bypass on an application location' {
        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        $objects.Collection.Locations[0] | Add-Member -NotePropertyName Exclusions `
            -NotePropertyValue @(@{ Type = 'Tenant'; Identity = 'Except' })

        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unreviewed*Exclusions*'
    }

    It 'rejects extra rule conditions and actions' {
        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        $objects.Rule | Add-Member -NotePropertyName ExceptIfContentContainsWords `
            -NotePropertyValue @('bypass marker')
        $objects.Rule | Add-Member -NotePropertyName NotifyUser `
            -NotePropertyValue @('SiteAdmin')

        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unreviewed*'
    }

    It 'rejects an unknown meaningful rule behavior property' {
        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        $objects.Rule | Add-Member -NotePropertyName FutureAutonomousAllow `
            -NotePropertyValue 'Enabled'

        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FutureAutonomousAllow*'
    }

    It 'rejects unknown meaningful collection and policy behavior properties' {
        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        $objects.Collection | Add-Member -NotePropertyName FutureCollectionBypass `
            -NotePropertyValue 'Enabled'

        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FutureCollectionBypass*'

        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        $objects.Policy | Add-Member -NotePropertyName FuturePolicyExclusion `
            -NotePropertyValue 'Enabled'

        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FuturePolicyExclusion*'
    }

    It 'rejects unknown meaningful nested scenario, inclusion, condition, and action behavior' {
        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        $objects.Collection.ScenarioConfig | Add-Member -NotePropertyName FutureScenarioBypass `
            -NotePropertyValue 'Enabled'
        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FutureScenarioBypass*'

        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        $objects.Collection.Locations[0].Inclusions[0] |
            Add-Member -NotePropertyName FutureInclusionException -NotePropertyValue 'Enabled'
        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FutureInclusionException*'

        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        $objects.Rule.ContentContainsSensitiveInformation[0] |
            Add-Member -NotePropertyName FutureClassifierException -NotePropertyValue 'Enabled'
        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FutureClassifierException*'

        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        $objects.Rule.RestrictAccess[0] |
            Add-Member -NotePropertyName FutureActionFallback -NotePropertyValue 'Allow'
        { Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedApplicationIds @($script:BlueprintId) } |
            Should -Throw '*unrecognized meaningful property*FutureActionFallback*'
    }

    It 'accepts the exact typed collection, policy, classifier, and UploadText action' {
        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId

        $result = Assert-ExactReadback -Collection $objects.Collection -Policy $objects.Policy `
            -Rule $objects.Rule -InputObject $script:InputObject -ExpectedDlpMode 'Enable' `
            -ExpectedApplicationIds @($script:BlueprintId)

        $result.collectionPolicyId | Should -Be 'collection-id'
        $result.blueprintApplicationIds | Should -Contain $script:BlueprintId
        $result.hasExtraConditions | Should -BeFalse
        $result.hasExtraActions | Should -BeFalse
    }

    It 'rejects an untrusted extra provider application before either Set mutation' {
        $script:InputObject.blueprintApplicationId = $script:OtherBlueprintId
        $script:InputObject.expectedPriorBlueprintApplicationIds = @($script:BlueprintId)
        $script:InputObject.expectedBlueprintApplicationIds = @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        $untrustedId = '33333333-3333-4333-8333-333333333333'
        $objects = & $script:NewExactObjects -ApplicationIds @(
            $script:BlueprintId,
            $untrustedId)
        Mock Get-FeatureConfiguration { $objects.Collection }
        Mock Get-DlpCompliancePolicy { $objects.Policy }
        Mock Get-DlpComplianceRule { $objects.Rule }
        Mock Set-FeatureConfiguration { throw 'mutation must not run' }
        Mock Set-DlpCompliancePolicy { throw 'mutation must not run' }

        { Invoke-ExactPurviewProfile -InputObject $script:InputObject `
            -ExpectedDlpMode 'Enable' } |
            Should -Throw '*exact prior nor expected authorized Application scope*'

        Should -Invoke Set-FeatureConfiguration -Times 0 -Exactly
        Should -Invoke Set-DlpCompliancePolicy -Times 0 -Exactly
    }

    It 'rejects behavior drift before either Set mutation' {
        $script:InputObject.blueprintApplicationId = $script:OtherBlueprintId
        $script:InputObject.expectedPriorBlueprintApplicationIds = @($script:BlueprintId)
        $script:InputObject.expectedBlueprintApplicationIds = @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        $objects.Rule | Add-Member -NotePropertyName NotifyUser `
            -NotePropertyValue @('SiteAdmin')
        Mock Get-FeatureConfiguration { $objects.Collection }
        Mock Get-DlpCompliancePolicy { $objects.Policy }
        Mock Get-DlpComplianceRule { $objects.Rule }
        Mock Set-FeatureConfiguration { throw 'mutation must not run' }
        Mock Set-DlpCompliancePolicy { throw 'mutation must not run' }

        { Invoke-ExactPurviewProfile -InputObject $script:InputObject `
            -ExpectedDlpMode 'Enable' } |
            Should -Throw '*unreviewed*'

        Should -Invoke Set-FeatureConfiguration -Times 0 -Exactly
        Should -Invoke Set-DlpCompliancePolicy -Times 0 -Exactly
    }

    It 'rejects persisted provider-ID drift before either Set mutation' {
        $script:InputObject.blueprintApplicationId = $script:OtherBlueprintId
        $script:InputObject.expectedPriorBlueprintApplicationIds = @($script:BlueprintId)
        $script:InputObject.expectedBlueprintApplicationIds = @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        $objects.Policy.Identity = 'untrusted-policy-id'
        Mock Get-FeatureConfiguration { $objects.Collection }
        Mock Get-DlpCompliancePolicy { $objects.Policy }
        Mock Get-DlpComplianceRule { $objects.Rule }
        Mock Set-FeatureConfiguration { throw 'mutation must not run' }
        Mock Set-DlpCompliancePolicy { throw 'mutation must not run' }

        { Invoke-ExactPurviewProfile -InputObject $script:InputObject `
            -ExpectedDlpMode 'Enable' } |
            Should -Throw '*ID did not match the persisted profile ID*'

        Should -Invoke Set-FeatureConfiguration -Times 0 -Exactly
        Should -Invoke Set-DlpCompliancePolicy -Times 0 -Exactly
    }

    It 'extends only the exact persisted scope and verifies the post-mutation union' {
        $script:InputObject.blueprintApplicationId = $script:OtherBlueprintId
        $script:InputObject.expectedPriorBlueprintApplicationIds = @($script:BlueprintId)
        $script:InputObject.expectedBlueprintApplicationIds = @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        $objects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        Mock Get-FeatureConfiguration { $objects.Collection }
        Mock Get-DlpCompliancePolicy { $objects.Policy }
        Mock Get-DlpComplianceRule { $objects.Rule }
        Mock Set-FeatureConfiguration {
            param($Identity, $Locations)
            $objects.Collection.Locations = $Locations | ConvertFrom-Json -Depth 20
        }
        Mock Set-DlpCompliancePolicy {
            param($Identity, $Locations)
            $objects.Policy.Locations = $Locations | ConvertFrom-Json -Depth 20
        }

        $result = Invoke-ExactPurviewProfile -InputObject $script:InputObject `
            -ExpectedDlpMode 'Enable'

        $result.blueprintApplicationIds | Should -HaveCount 2
        $result.blueprintApplicationIds | Should -Contain $script:BlueprintId
        $result.blueprintApplicationIds | Should -Contain $script:OtherBlueprintId
        Should -Invoke Set-FeatureConfiguration -Times 1 -Exactly
        Should -Invoke Set-DlpCompliancePolicy -Times 1 -Exactly
    }

    It 'resumes an independently verified partial scope extension without repeating the completed Set' {
        $script:InputObject.blueprintApplicationId = $script:OtherBlueprintId
        $script:InputObject.expectedPriorBlueprintApplicationIds = @($script:BlueprintId)
        $script:InputObject.expectedBlueprintApplicationIds = @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        $collectionObjects = & $script:NewExactObjects -ApplicationIds @(
            $script:BlueprintId,
            $script:OtherBlueprintId)
        $policyObjects = & $script:NewExactObjects -ApplicationId $script:BlueprintId
        $objects = [pscustomobject]@{
            Collection = $collectionObjects.Collection
            Policy = $policyObjects.Policy
            Rule = $policyObjects.Rule
        }
        Mock Get-FeatureConfiguration { $objects.Collection }
        Mock Get-DlpCompliancePolicy { $objects.Policy }
        Mock Get-DlpComplianceRule { $objects.Rule }
        Mock Set-FeatureConfiguration { throw 'completed mutation must not repeat' }
        Mock Set-DlpCompliancePolicy {
            param($Identity, $Locations)
            $objects.Policy.Locations = $Locations | ConvertFrom-Json -Depth 20
        }

        $result = Invoke-ExactPurviewProfile -InputObject $script:InputObject `
            -ExpectedDlpMode 'Enable'

        $result.blueprintApplicationIds | Should -HaveCount 2
        Should -Invoke Set-FeatureConfiguration -Times 0 -Exactly
        Should -Invoke Set-DlpCompliancePolicy -Times 1 -Exactly
    }
}
