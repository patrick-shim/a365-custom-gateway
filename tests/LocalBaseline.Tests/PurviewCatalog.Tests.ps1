BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $sourcePath = Join-Path $root 'src\Gateway.Purview\Automation\Invoke-PurviewSettingsOperation.ps1'
    $text = [IO.File]::ReadAllText($sourcePath)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Purview source has parse errors.' }
    $names = @('Get-Property', 'Assert-BoundedText', 'ConvertTo-CanonicalGuid',
        'ConvertFrom-ProviderGuid', 'Get-SelectedSensitiveInformationType',
        'Get-SelectedSensitiveInformationTypes', 'Get-DlpSitThresholds',
        'Get-DlpPolicyMode', 'Assert-Intent', 'Assert-DlpActions',
        'Assert-IntentLifetime', 'Get-OperationProviderCommands',
        'New-ApplicationLocation', 'ConvertTo-ProviderMode',
        'ConvertTo-KnowYourDataProviderMode', 'New-DlpSensitiveInformationCondition')
    $definitions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false) | Where-Object Name -In $names | ForEach-Object { $_.Extent.Text })
    $first = $text.IndexOf('    $script:SettingsStage = 6', [StringComparison]::Ordinal)
    $split = $text.IndexOf("    if (`$Operation -in @('ReadKnowYourData'", $first, [StringComparison]::Ordinal)
    $second = $text.IndexOf('    $actions = @(Assert-DlpActions', $split, [StringComparison]::Ordinal)
    $end = $text.IndexOf('    $script:SettingsStage = 8', $second, [StringComparison]::Ordinal)
    if ($first -lt 0 -or $split -le $first -or $second -le $split -or $end -le $second) {
        throw 'The exact production selection boundaries were not found.'
    }
    $flow = $text.Substring($first, $split - $first) + $text.Substring($second, $end - $second)
    $main = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
    if ($main.Count -ne 1) { throw 'Expected one native operation entry point.' }
    $nativeFlow = $text.Substring($first, $main[0].Body.Extent.EndOffset - 1 - $first)
    $moduleName = 'PurviewCatalogFixture_' + [guid]::NewGuid().ToString('N')
    $fixture = New-Module -Name $moduleName -ArgumentList $definitions, $flow, $nativeFlow -ScriptBlock {
        param($definitions, $flow, $nativeFlow)
        Set-StrictMode -Version Latest
        foreach ($definition in $definitions) { . ([scriptblock]::Create($definition)) }
        $script:selectionFlow = [scriptblock]::Create('$input = $Intent' + [Environment]::NewLine + $flow)
        $script:nativeFlow = [scriptblock]::Create('$input = $Intent; $Operation = $FixtureOperation' +
            [Environment]::NewLine + $nativeFlow)
        $script:InventoryLimit = 2048
        $script:EnterpriseAiAppsGroupId = '55555555-5555-4555-8555-555555555555'
        $script:SettingsSchemaCode = $null
        $script:reads = 0
        $script:catalog = @()
        function Get-DlpSensitiveInformationType {
            [CmdletBinding()]
            param()
            $script:reads++
            $script:catalog
        }
        function Invoke-Selection {
            param($Intent, [object[]]$Catalog)
            $script:reads = 0
            $script:catalog = $Catalog
            . $script:selectionFlow
            [pscustomobject]@{ Reads = $script:reads; Primary = $selectedType; Selections = @($selectedTypes) }
        }
        function Get-DlpReadback {
            param($InputObject, $SelectedType, $ExpectedActions, $SelectedTypes)
            if ($script:expireDuringRead) {
                $InputObject.inventoryExpiresAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('O')
            }
            @{ state = $script:state; ruleProviderId = $script:ruleProviderId }
        }
        function Get-KnowYourDataReadback {
            param($InputObject, $SelectedType)
            Get-DlpReadback -InputObject $InputObject
        }
        foreach ($name in @('Get-KnowYourDataUpdateTarget', 'Get-DlpPolicyUpdateTarget', 'Get-DlpRuleUpdateTarget')) {
            Set-Item -Path "Function:\$name" -Value {
                param($InputObject)
                if ($script:expireDuringUpdateRead) {
                    $InputObject.inventoryExpiresAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('O')
                }
                @{ Identity = 'synthetic-existing-object' }
            }
        }
        foreach ($name in @('New-FeatureConfiguration', 'Set-FeatureConfiguration',
                'New-DlpCompliancePolicy', 'Set-DlpCompliancePolicy', 'New-DlpComplianceRule', 'Set-DlpComplianceRule')) {
            Set-Item -Path "Function:\$name" -Value {
                [CmdletBinding(SupportsShouldProcess)]
                param($FeatureScenario, $Name, $Mode, $ScenarioConfig, $Locations,
                    $Identity, $EnforcementPlanes, $Policy, $ContentContainsSensitiveInformation, $RestrictAccess)
                $script:mutations++
            }
        }
        function Write-TypedResult { param($Value) $script:result = $Value }
        function Invoke-NativeFixture {
            param($Intent, [object[]]$Catalog, [string]$FixtureOperation,
                [string]$FixtureState, [bool]$ExpireDuringRead, [bool]$ExpireDuringUpdateRead, [string]$RuleProviderId)
            $script:catalog = $Catalog
            $script:reads = 0; $script:mutations = 0; $script:result = $null
            $script:SettingsSchemaCode = $null
            $script:state = $FixtureState; $script:ruleProviderId = $RuleProviderId
            $script:expireDuringRead = $ExpireDuringRead
            $script:expireDuringUpdateRead = $ExpireDuringUpdateRead
            $failure = $null
            try { . $script:nativeFlow }
            catch { $failure = $_.Exception.Message }
            [pscustomobject]@{
                Reads = $script:reads; Mutations = $script:mutations
                Failure = $failure; SchemaCode = $script:SettingsSchemaCode; Result = $script:result
            }
        }
        Export-ModuleMember -Function @()
    }
    Import-Module $fixture -NoClobber
}

AfterAll {
    if ($fixture) { Remove-Module -ModuleInfo $fixture -Force }
}

Describe 'Purview operation-scoped catalog reads' {
    BeforeEach {
    $catalog = @(1..3 | ForEach-Object {
        [pscustomobject]@{
            Id = "11111111-1111-4111-8111-$($_.ToString('000000000000'))"
            Name = "Synthetic type $_"
            Publisher = 'Synthetic fixture'
        }
    })
    $intent = [pscustomobject]@{
        operationId = '22222222-2222-4222-8222-222222222222'
        tenantId = '33333333-3333-4333-8333-333333333333'
        inventoryGenerationId = '44444444-4444-4444-8444-444444444444'
        inventoryExpiresAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('O')
        sensitiveInformationTypeId = $catalog[0].Id
        sensitiveInformationTypeName = $catalog[0].Name
        sensitiveInformationTypePublisher = $catalog[0].Publisher
        policyName = 'Synthetic policy'
        ruleName = 'Synthetic rule'
        blueprintApplicationId = '66666666-6666-4666-8666-666666666666'
        ingestionEnabled = $false
        expectedRuleProviderId = $null
        mode = 'Enforce'
        policyMode = 'Enforce'
        activities = @('UploadText')
        actions = @([pscustomobject]@{ activity = 'UploadText'; action = 'Block' })
        sensitiveInformationTypes = @($catalog | ForEach-Object {
            [pscustomobject]@{
                id = $_.Id; exactName = $_.Name; publisher = $_.Publisher
                minCount = 1; maxCount = -1; minConfidence = 75; maxConfidence = 100
                }
        })
    }
}

    It 'uses one provider catalog read for the actual primary and multi-SIT selection flow' -Tag 'CatalogReadCount' {
        $result = & $fixture { param($i, $c) Invoke-Selection -Intent $i -Catalog $c } $intent $catalog
        $result.Reads | Should -Be 1
        $result.Selections.Count | Should -Be 3
        $result.Primary.id | Should -BeExactly $catalog[0].Id
        @($result.Selections | Where-Object { $_.minCount -ne 1 -or $_.maxCount -ne -1 -or
            $_.minConfidence -ne 75 -or $_.maxConfidence -ne 100 }).Count | Should -Be 0
    }

    It 'rejects duplicate IDs and names instead of using a partial catalog' {
        $badCatalog = @($catalog) + @($catalog[0])
        { & $fixture { param($i, $c) Invoke-Selection -Intent $i -Catalog $c } $intent $badCatalog } | Should -Throw
    }

    It 'rejects a missing or renamed selected type without silently changing the selection' {
        $catalog[1].Name = 'Different synthetic name'
        { & $fixture { param($i, $c) Invoke-Selection -Intent $i -Catalog $c } $intent $catalog } | Should -Throw
    }

    It 'does not reuse a catalog across separate invocations' {
        $null = & $fixture { param($i, $c) Invoke-Selection -Intent $i -Catalog $c } $intent $catalog
        $changed = @($catalog | Select-Object -First 1)
        { & $fixture { param($i, $c) Invoke-Selection -Intent $i -Catalog $c } $intent $changed } | Should -Throw
    }

    It 'rejects expired input before reading the provider catalog' {
        $intent.inventoryExpiresAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('O')
        $result = & $fixture { param($i, $c) Invoke-NativeFixture -Intent $i -Catalog $c -FixtureOperation ReadDlpProfile -FixtureState Absent } $intent $catalog
        $result.Reads | Should -Be 0
        $result.Mutations | Should -Be 0
        $result.SchemaCode | Should -BeExactly 'InventoryExpired'
        $result.Failure | Should -BeExactly 'The selected Purview inventory generation is expired or invalid.'
    }

    It 'does not replace missing legacy thresholds with defaults' {
        $intent.sensitiveInformationTypes[1].minConfidence = $null
        { & $fixture { param($i, $c) Invoke-Selection -Intent $i -Catalog $c } $intent $catalog } | Should -Throw '*THRESHOLDS_REVIEW_REQUIRED*'
    }

    It 'imports only the commands required by <Operation>' -TestCases @(
        @{ Operation = 'ReadKnowYourData'; Expected = @('Get-DlpSensitiveInformationType', 'Get-FeatureConfiguration') }
        @{ Operation = 'CreateKnowYourData'; Expected = @('Get-DlpSensitiveInformationType', 'Get-FeatureConfiguration', 'New-FeatureConfiguration', 'Set-FeatureConfiguration') }
        @{ Operation = 'ReadDlpProfile'; Expected = @('Get-DlpSensitiveInformationType', 'Get-DlpCompliancePolicy', 'Get-DlpComplianceRule') }
        @{ Operation = 'CreateDlpPolicy'; Expected = @('Get-DlpSensitiveInformationType', 'Get-DlpCompliancePolicy', 'Get-DlpComplianceRule', 'New-DlpCompliancePolicy', 'Set-DlpCompliancePolicy') }
        @{ Operation = 'CreateDlpRule'; Expected = @('Get-DlpSensitiveInformationType', 'Get-DlpCompliancePolicy', 'Get-DlpComplianceRule', 'New-DlpComplianceRule', 'Set-DlpComplianceRule') }
    ) {
        param($Operation, $Expected)
        $commands = @(& $fixture { param($o) Get-OperationProviderCommands -Operation $o } $Operation)
        ($commands -join '|') | Should -BeExactly ($Expected -join '|')
    }

    It 'preserves <Operation> <State> behavior while stopping expiry during its last read' -TestCases @(
        @{ Operation = 'CreateKnowYourData'; State = 'Absent'; Rule = ''; Update = $false }
        @{ Operation = 'CreateKnowYourData'; State = 'Mismatch'; Rule = ''; Update = $true }
        @{ Operation = 'CreateDlpPolicy'; State = 'Absent'; Rule = ''; Update = $false }
        @{ Operation = 'CreateDlpPolicy'; State = 'Mismatch'; Rule = ''; Update = $true }
        @{ Operation = 'CreateDlpRule'; State = 'PolicyOnlyExact'; Rule = ''; Update = $false }
        @{ Operation = 'CreateDlpRule'; State = 'PolicyOnlyExact'; Rule = 'existing-rule'; Update = $true }
    ) {
        param($Operation, $State, $Rule, $Update)
        $normal = & $fixture {
            param($i, $c, $o, $s, $r)
            Invoke-NativeFixture -Intent $i -Catalog $c -FixtureOperation $o -FixtureState $s -RuleProviderId $r
        } $intent $catalog $Operation $State $Rule
        $normal.Failure | Should -BeNullOrEmpty
        $normal.Reads | Should -Be 1
        $normal.Mutations | Should -Be 1
        $normal.Result.state | Should -BeExactly 'MutationAccepted'

        $expired = & $fixture {
            param($i, $c, $o, $s, $r, $u)
            Invoke-NativeFixture -Intent $i -Catalog $c -FixtureOperation $o -FixtureState $s -RuleProviderId $r `
                -ExpireDuringRead (-not $u) -ExpireDuringUpdateRead $u
        } $intent $catalog $Operation $State $Rule $Update
        $expired.Mutations | Should -Be 0
        $expired.SchemaCode | Should -BeExactly 'InventoryExpired'
        $expired.Failure | Should -BeExactly 'The selected Purview inventory generation is expired or invalid.'
    }
}
