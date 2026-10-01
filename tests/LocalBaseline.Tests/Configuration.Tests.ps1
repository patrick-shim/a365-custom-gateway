BeforeAll {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $schema = Join-Path $root 'bootstrap\config.schema.json'
    $example = [IO.File]::ReadAllText((Join-Path $root 'bootstrap\config.example.json'))
}

Describe 'Non-secret bootstrap configuration schema' {
    It 'accepts the authored full-evaluation example without a deployment' {
        Test-Json -Json $example -SchemaFile $schema -ErrorAction Stop | Should -BeTrue
    }

    It 'supports Core with shared Prompt Shields and Purview omitted' {
        $value = ConvertFrom-Json $example -AsHashtable
        $value.capabilityPreset = 'coreGateway'
        $value.purview.enabled = $false
        $value.purview.authorityRequirementsAcknowledged = $false
        Test-Json -Json (ConvertTo-Json $value -Depth 10) -SchemaFile $schema -ErrorAction Stop | Should -BeTrue
    }

    It 'does not admit beta Registry in production' {
        $value = ConvertFrom-Json $example -AsHashtable
        $value.environment = 'prod'
        { Test-Json -Json (ConvertTo-Json $value -Depth 10) -SchemaFile $schema -ErrorAction Stop } | Should -Throw
    }

    It 'rejects unacknowledged capability authority and cost choices' -ForEach @(
        @{ Section = 'agent365'; Property = 'registryBetaAcknowledged' },
        @{ Section = 'promptShield'; Property = 'costAndQuotaAcknowledged' },
        @{ Section = 'purview'; Property = 'authorityRequirementsAcknowledged' }
    ) {
        $value = ConvertFrom-Json $example -AsHashtable
        $value[$Section][$Property] = $false
        { Test-Json -Json (ConvertTo-Json $value -Depth 10) -SchemaFile $schema -ErrorAction Stop } | Should -Throw
    }

    It 'rejects a mismatched SQL SKU and tier' {
        $value = ConvertFrom-Json $example -AsHashtable
        $value.sql.skuName = 'S0'
        $value.sql.skuTier = 'Basic'
        { Test-Json -Json (ConvertTo-Json $value -Depth 10) -SchemaFile $schema -ErrorAction Stop } | Should -Throw
    }

    It 'rejects arbitrary credential properties instead of persisting them' {
        $value = ConvertFrom-Json $example -AsHashtable
        $value['credential'] = 'synthetic-forbidden-field'
        { Test-Json -Json (ConvertTo-Json $value -Depth 10) -SchemaFile $schema -ErrorAction Stop } | Should -Throw
    }
}
