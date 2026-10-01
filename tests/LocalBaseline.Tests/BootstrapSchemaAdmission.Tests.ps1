BeforeDiscovery {
    $admissionCases = @(
        foreach ($environment in @('dev', 'staging', 'prod')) {
            foreach ($preset in @('fullEvaluation', 'coreGateway', 'custom')) {
                foreach ($registry in @($false, $true)) {
                    foreach ($prompt in @($false, $true)) {
                        foreach ($purview in @($false, $true)) {
                            $expected = (-not $registry -or $environment -ceq 'dev') -and
                                ($preset -cne 'fullEvaluation' -or
                                    ($environment -ceq 'dev' -and $registry -and $prompt -and $purview)) -and
                                ($preset -cne 'coreGateway' -or -not $purview)
                            @{
                                Label = "$environment/$preset/registry=$registry/prompt=$prompt/purview=$purview"
                                Environment = $environment
                                Preset = $preset
                                Registry = $registry
                                Prompt = $prompt
                                Purview = $purview
                                Expected = $expected
                            }
                        }
                    }
                }
            }
        }
    )
}

BeforeAll {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $commonPath = Join-Path $root 'bootstrap\modules\Common.psm1'
    $schemaPath = Join-Path $root 'bootstrap\config.schema.json'
    $example = [IO.File]::ReadAllText((Join-Path $root 'bootstrap\config.example.json'))
    $sourceHashes = @{}
    foreach ($path in @($commonPath, $schemaPath)) {
        $sourceHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }

    $tokens = $null
    $parseErrors = $null
    $commonAst = [Management.Automation.Language.Parser]::ParseFile(
        $commonPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw 'Bootstrap loader source must parse before admission tests.' }
    $priorCommands = @{}
    foreach ($definition in $commonAst.EndBlock.Statements |
            Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
        $existing = Get-Command -Name $definition.Name -CommandType Function -ErrorAction SilentlyContinue
        if ($null -ne $existing) { $priorCommands[$definition.Name] = $existing }
    }

    $fixtureModuleName = "M5SchemaAdmission_$([guid]::NewGuid().ToString('N'))"
    $fixtureRoot = Join-Path $TestDrive $fixtureModuleName
    $moduleDirectory = Join-Path $fixtureRoot 'modules'
    [IO.Directory]::CreateDirectory($moduleDirectory) | Out-Null
    $fixtureModulePath = Join-Path $moduleDirectory "$fixtureModuleName.psm1"
    $fixtureSchemaPath = Join-Path $fixtureRoot 'config.schema.json'
    Copy-Item -LiteralPath $commonPath -Destination $fixtureModulePath
    Copy-Item -LiteralPath $schemaPath -Destination $fixtureSchemaPath
    $fixtureModule = Import-Module $fixtureModulePath -DisableNameChecking -NoClobber -PassThru
    $fixtureLoader = $fixtureModule.ExportedCommands['Read-BootstrapConfig']
    $guardedCommands = @(
        'Invoke-BootstrapCommand', 'Invoke-AzJson', 'Invoke-AzTsv',
        'Get-BootstrapGraphAccessToken', 'Get-BootstrapGraphHttpClient',
        'Invoke-BootstrapGraphAzRest', 'Invoke-RestMethod', 'Invoke-WebRequest'
    )

    function New-AdmissionConfiguration {
        ConvertFrom-Json -InputObject $example -AsHashtable
    }

    function Test-AdmissionSchema {
        param([Parameter(Mandatory)][hashtable]$Value)
        Test-Json -Json ($Value | ConvertTo-Json -Depth 30) `
            -SchemaFile $fixtureSchemaPath -ErrorAction Stop
    }

    function Read-AdmissionConfiguration {
        param([Parameter(Mandatory)][hashtable]$Value)
        $json = $Value | ConvertTo-Json -Depth 30
        $path = Join-Path $fixtureRoot "$([guid]::NewGuid().ToString('N')).json"
        [IO.File]::WriteAllText($path, $json)
        try {
            & $fixtureLoader -Path $path -WarningAction SilentlyContinue
        }
        finally {
            try {
                [IO.File]::ReadAllText($path) | Should -BeExactly $json
            }
            finally {
                [IO.File]::Delete($path)
            }
        }
    }
}

AfterAll {
    if ($null -ne $fixtureModule) {
        Remove-Module -Name $fixtureModuleName -Force
    }
    foreach ($name in $priorCommands.Keys) {
        $current = Get-Command -Name $name -CommandType Function -ErrorAction Stop
        $current.ModuleName | Should -BeExactly $priorCommands[$name].ModuleName
        $current.Definition | Should -BeExactly $priorCommands[$name].Definition
    }
    foreach ($path in $sourceHashes.Keys) {
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash |
            Should -BeExactly $sourceHashes[$path]
    }
}

Describe 'Bootstrap preset schema and actual loader admission' {
    BeforeEach {
        foreach ($command in $guardedCommands) {
            Mock -CommandName $command -ModuleName $fixtureModuleName -MockWith {
                throw 'Authentication, provider and HTTP calls are forbidden in schema-admission tests.'
            }
        }
    }

    AfterEach {
        foreach ($command in $guardedCommands) {
            Should -Invoke -CommandName $command -ModuleName $fixtureModuleName -Times 0 -Exactly
        }
    }

    It 'agrees for <Label>' -ForEach $admissionCases {
        $value = New-AdmissionConfiguration
        $value.environment = $Environment
        $value.capabilityPreset = $Preset
        $value.agent365.allowDevelopmentRegistryPreview = $Registry
        $value.agent365.registryBetaAcknowledged = $Registry
        $value.promptShield.enabled = $Prompt
        $value.promptShield.costAndQuotaAcknowledged = $Prompt
        $value.purview.enabled = $Purview
        $value.purview.authorityRequirementsAcknowledged = $Purview

        if ($Expected) {
            Test-AdmissionSchema $value | Should -BeTrue
            $loaded = Read-AdmissionConfiguration $value
            $loaded.capabilityPreset | Should -BeExactly $Preset
            $loaded.environment | Should -BeExactly $Environment
            $loaded.agent365.allowDevelopmentRegistryPreview | Should -Be $Registry
            $loaded.promptShield.enabled | Should -Be $Prompt
            $loaded.purview.enabled | Should -Be $Purview
        }
        else {
            { Test-AdmissionSchema $value } | Should -Throw
            { Read-AdmissionConfiguration $value } | Should -Throw '*JSON Schema validation*'
        }
    }

    It 'rejects a nil reviewed manager identity in both schema and loader' {
        $value = New-AdmissionConfiguration
        $value.agent365.reviewedManagerApplicationIds = @('00000000-0000-0000-0000-000000000000')
        { Test-AdmissionSchema $value } | Should -Throw
        { Read-AdmissionConfiguration $value } | Should -Throw '*JSON Schema validation*'
    }

    It 'rejects forbidden legacy adapter activation in both schema and loader' {
        $value = New-AdmissionConfiguration
        $value.purview['activateGatewayAdapterAfterPolicyReadback'] = $true
        { Test-AdmissionSchema $value } | Should -Throw
        { Read-AdmissionConfiguration $value } | Should -Throw '*JSON Schema validation*'
    }

    It 'keeps an explicit false legacy adapter flag accepted without rewriting it' {
        $value = New-AdmissionConfiguration
        $value.purview['activateGatewayAdapterAfterPolicyReadback'] = $false
        Test-AdmissionSchema $value | Should -BeTrue
        $loaded = Read-AdmissionConfiguration $value
        $loaded.purview.legacyPolicyMigrationRequired | Should -BeTrue
        $loaded.purview.PSObject.Properties.Name | Should -Not -Contain 'activateGatewayAdapterAfterPolicyReadback'
    }

    It 'preserves legacy preset inference and missing acknowledgement migration for <Label>' -ForEach @(
        @{ Label = 'full evaluation'; Prompt = $true; Purview = $true; Registry = $true; ExpectedPreset = 'fullEvaluation' },
        @{ Label = 'core with Prompt Shields off'; Prompt = $false; Purview = $false; Registry = $true; ExpectedPreset = 'coreGateway' },
        @{ Label = 'custom with Prompt Shields off'; Prompt = $false; Purview = $true; Registry = $false; ExpectedPreset = 'custom' },
        @{ Label = 'custom with Purview off'; Prompt = $true; Purview = $false; Registry = $false; ExpectedPreset = 'custom' }
    ) {
        $value = New-AdmissionConfiguration
        $value.Remove('capabilityPreset')
        $value.agent365.Remove('registryBetaAcknowledged')
        $value.promptShield.Remove('costAndQuotaAcknowledged')
        $value.purview.Remove('authorityRequirementsAcknowledged')
        $value.agent365.allowDevelopmentRegistryPreview = $Registry
        $value.promptShield.enabled = $Prompt
        $value.purview.enabled = $Purview
        $value.purview['activateGatewayAdapterAfterPolicyReadback'] = $false

        { Test-AdmissionSchema $value } | Should -Throw
        $loaded = Read-AdmissionConfiguration $value
        $loaded.capabilityPreset | Should -BeExactly $ExpectedPreset
        $loaded.agent365.registryBetaAcknowledged | Should -Be $Registry
        $loaded.promptShield.enabled | Should -Be $Prompt
        $loaded.promptShield.costAndQuotaAcknowledged | Should -Be $Prompt
        $loaded.purview.enabled | Should -Be $Purview
        $loaded.purview.authorityRequirementsAcknowledged | Should -Be $Purview
        $loaded.purview.legacyPolicyMigrationRequired | Should -BeTrue
    }

    It 'does not infer a missing preset for a new configuration without legacy fields' {
        $value = New-AdmissionConfiguration
        $value.Remove('capabilityPreset')
        { Test-AdmissionSchema $value } | Should -Throw
        { Read-AdmissionConfiguration $value } | Should -Throw '*JSON Schema validation*'
    }

    It 'preserves accepted legacy SIT migration metadata' {
        $value = New-AdmissionConfiguration
        $value.purview['sensitiveInformationTypeId'] = 'ABCDEF12-ABCD-4ABC-8DEF-0123456789AB'
        $value.purview['sensitiveInformationType'] = 'Synthetic classifier'
        Test-AdmissionSchema $value | Should -BeTrue
        $loaded = Read-AdmissionConfiguration $value
        $loaded.purview.sensitiveInformationTypeId | Should -BeExactly 'abcdef12-abcd-4abc-8def-0123456789ab'
        $loaded.purview.sensitiveInformationType | Should -BeExactly 'Synthetic classifier'
        $loaded.purview.legacyPolicyMigrationRequired | Should -BeTrue
    }
}

Describe 'Manager GUID supplemental semantic guard' -Tag SchemaSemanticGuard {
    BeforeEach {
        foreach ($command in $guardedCommands) {
            Mock -CommandName $command -ModuleName $fixtureModuleName -MockWith {
                throw 'Authentication, provider and HTTP calls are forbidden in schema-admission tests.'
            }
        }
    }

    AfterEach {
        foreach ($command in $guardedCommands) {
            Should -Invoke -CommandName $command -ModuleName $fixtureModuleName -Times 0 -Exactly
        }
    }

    It 'declares the supplemental case-insensitive manager GUID guard' {
        $schema = [IO.File]::ReadAllText($fixtureSchemaPath) | ConvertFrom-Json -AsHashtable
        $identities = $schema.properties.agent365.properties.reviewedManagerApplicationIds
        $identities.uniqueItems | Should -BeTrue
        $identities['$comment'] | Should -Match 'uniqueItems'
        $identities['$comment'] | Should -Match 'Read-BootstrapConfig'
        $identities['$comment'] | Should -Match 'case-insensitive'
        $identities['$comment'] | Should -Match 'uppercase'
        $identities['$comment'] | Should -Match 'mixed-case'
    }

    It 'accepts <Label> manager GUIDs without rewriting input' -ForEach @(
        @{ Label = 'lowercase'; ManagerId = 'abcdef12-abcd-4abc-8def-0123456789ab' },
        @{ Label = 'uppercase'; ManagerId = 'ABCDEF12-ABCD-4ABC-8DEF-0123456789AB' },
        @{ Label = 'mixed-case'; ManagerId = 'aBcDeF12-AbCd-4aBc-8DeF-0123456789aB' }
    ) {
        $value = New-AdmissionConfiguration
        $value.agent365.reviewedManagerApplicationIds = @($ManagerId)
        Test-AdmissionSchema $value | Should -BeTrue
        $loaded = Read-AdmissionConfiguration $value
        @($loaded.agent365.reviewedManagerApplicationIds).Count | Should -Be 1
        $loaded.agent365.reviewedManagerApplicationIds[0] | Should -BeExactly 'abcdef12-abcd-4abc-8def-0123456789ab'
    }

    It 'accepts distinct mixed-casing manager GUIDs' {
        $value = New-AdmissionConfiguration
        $value.agent365.reviewedManagerApplicationIds = @(
            'ABCDEF12-ABCD-4ABC-8DEF-0123456789AB',
            'BbBbBbBb-1111-4CcC-8DdD-EeEeEeEeEeEe'
        )
        Test-AdmissionSchema $value | Should -BeTrue
        $loaded = Read-AdmissionConfiguration $value
        @($loaded.agent365.reviewedManagerApplicationIds).Count | Should -Be 2
        ($loaded.agent365.reviewedManagerApplicationIds -join ',') |
            Should -BeExactly 'abcdef12-abcd-4abc-8def-0123456789ab,bbbbbbbb-1111-4ccc-8ddd-eeeeeeeeeeee'
    }

    It 'rejects <Label>case-only duplicate manager GUIDs after schema admission' -ForEach @(
        @{ Label = ''; Reversed = $false },
        @{ Label = 'reversed '; Reversed = $true }
    ) {
        $value = New-AdmissionConfiguration
        $ids = @('abcdef12-abcd-4abc-8def-0123456789ab', 'ABCDEF12-ABCD-4ABC-8DEF-0123456789AB')
        if ($Reversed) { [Array]::Reverse($ids) }
        $value.agent365.reviewedManagerApplicationIds = $ids
        Test-AdmissionSchema $value | Should -BeTrue
        { Read-AdmissionConfiguration $value } | Should -Throw '*reviewedManagerApplicationIds must not contain duplicates*'
    }
}
