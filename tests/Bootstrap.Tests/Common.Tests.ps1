$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force

BeforeAll {
    $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))

    function New-TestBootstrapConfig {
        $config = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'bootstrap/config.example.json') -Raw |
            ConvertFrom-Json -Depth 30
        $config.subscriptionId = '11111111-1111-4111-8111-111111111111'
        $config.tenantId = '22222222-2222-4222-8222-222222222222'
        return $config
    }

    function Copy-TestBootstrapConfig {
        param([Parameter(Mandatory)]$Config)
        return $Config | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    }

    function Write-TestBootstrapConfig {
        param(
            [Parameter(Mandatory)]$Config,
            [Parameter(Mandatory)][string]$Path
        )
        $Config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
    }
}

Describe 'Bootstrap JSON Schema configuration validation' {
    It 'loads a valid configuration and materializes backward-compatible defaults' {
        $config = New-TestBootstrapConfig
        foreach ($name in @(
            'policyProvisioningEnabled',
            'policyProvisioningOrganization',
            'policyProvisioningApplicationId',
            'policyProvisioningCertificateSecretUri'
        )) {
            $config.purview.PSObject.Properties.Remove($name)
        }
        $path = Join-Path $TestDrive 'valid.json'
        Write-TestBootstrapConfig -Config $config -Path $path

        $loaded = Read-BootstrapConfig -Path $path

        $loaded.purview.policyProvisioningEnabled | Should -BeFalse
        $loaded.purview.policyProvisioningOrganization | Should -Be ''
    }

    It 'rejects properties that are not declared by the schema' {
        $config = New-TestBootstrapConfig
        $config | Add-Member -MemberType NoteProperty -Name unexpectedCredential -Value 'not-a-real-value'
        $path = Join-Path $TestDrive 'extra-property.json'
        Write-TestBootstrapConfig -Config $config -Path $path

        { Read-BootstrapConfig -Path $path } | Should -Throw '*JSON Schema validation*'
    }

    It 'rejects an incompatible SQL SKU and tier pair' {
        $config = New-TestBootstrapConfig
        $config.sql.skuName = 'S0'
        $config.sql.skuTier = 'Premium'
        $path = Join-Path $TestDrive 'invalid-sql.json'
        Write-TestBootstrapConfig -Config $config -Path $path

        { Read-BootstrapConfig -Path $path } | Should -Throw '*JSON Schema validation*'
    }

    It 'rejects Registry preview outside development' {
        $config = New-TestBootstrapConfig
        $config.environment = 'staging'
        $config.agent365.allowDevelopmentRegistryPreview = $true
        $path = Join-Path $TestDrive 'invalid-preview.json'
        Write-TestBootstrapConfig -Config $config -Path $path

        { Read-BootstrapConfig -Path $path } | Should -Throw '*JSON Schema validation*'
    }

    It 'requires complete policy-provisioning fields when that feature is enabled' {
        $config = New-TestBootstrapConfig
        $config.purview.enabled = $true
        $config.purview.sensitiveInformationType = 'Credit Card Number'
        $config.purview.policyProvisioningEnabled = $true
        $path = Join-Path $TestDrive 'invalid-policy-provisioning.json'
        Write-TestBootstrapConfig -Config $config -Path $path

        { Read-BootstrapConfig -Path $path } | Should -Throw '*JSON Schema validation*'
    }

    It 'accepts a complete versionless Key Vault policy-provisioning contract' {
        $config = New-TestBootstrapConfig
        $config.purview.enabled = $true
        $config.purview.activateGatewayAdapterAfterPolicyReadback = $true
        $config.purview.sensitiveInformationType = 'Credit Card Number'
        $config.purview.policyProvisioningEnabled = $true
        $config.purview.policyProvisioningOrganization = 'contoso.onmicrosoft.com'
        $config.purview.policyProvisioningApplicationId = '33333333-3333-4333-8333-333333333333'
        $config.purview.policyProvisioningCertificateSecretUri = 'https://safe-vault.vault.azure.net/secrets/automation-certificate'
        $path = Join-Path $TestDrive 'valid-policy-provisioning.json'
        Write-TestBootstrapConfig -Config $config -Path $path

        $loaded = Read-BootstrapConfig -Path $path

        $loaded.purview.policyProvisioningEnabled | Should -BeTrue
        $loaded.purview.policyProvisioningApplicationId | Should -Be '33333333-3333-4333-8333-333333333333'
    }

    It 'rejects policy provisioning when the Gateway Purview adapter would remain disabled' {
        $config = New-TestBootstrapConfig
        $config.purview.enabled = $true
        $config.purview.activateGatewayAdapterAfterPolicyReadback = $false
        $config.purview.sensitiveInformationType = 'Credit Card Number'
        $config.purview.policyProvisioningEnabled = $true
        $config.purview.policyProvisioningOrganization = 'contoso.onmicrosoft.com'
        $config.purview.policyProvisioningApplicationId = '33333333-3333-4333-8333-333333333333'
        $config.purview.policyProvisioningCertificateSecretUri = 'https://safe-vault.vault.azure.net/secrets/automation-certificate'
        $path = Join-Path $TestDrive 'inert-policy-provisioning.json'
        Write-TestBootstrapConfig -Config $config -Path $path

        { Read-BootstrapConfig -Path $path } | Should -Throw '*JSON Schema validation*'
    }

    It 'does not echo malformed JSON content in its parse error' {
        $path = Join-Path $TestDrive 'malformed.json'
        '{ "value": "private-marker" ' | Set-Content -LiteralPath $path -Encoding utf8NoBOM

        try {
            Read-BootstrapConfig -Path $path
            throw 'Expected malformed JSON to be rejected.'
        }
        catch {
            $_.Exception.Message | Should -BeLike '*is not valid JSON*'
            $_.Exception.Message | Should -Not -BeLike '*private-marker*'
        }
    }

    It 'does not echo rejected schema values in its validation error' {
        $config = New-TestBootstrapConfig
        $config.projectName = 'credential-like-private-marker'
        $path = Join-Path $TestDrive 'schema-value-redaction.json'
        Write-TestBootstrapConfig -Config $config -Path $path

        try {
            Read-BootstrapConfig -Path $path
            throw 'Expected schema validation to fail.'
        }
        catch {
            $_.Exception.Message | Should -BeLike '*JSON Schema validation*rejected input values were suppressed*'
            $_.Exception.Message | Should -Not -BeLike '*credential-like-private-marker*'
        }
    }
}

Describe 'Canonical bootstrap fingerprints' {
    It 'is independent of JSON property order and the schema annotation' {
        $config = New-TestBootstrapConfig
        $reordered = [ordered]@{}
        foreach ($name in @($config.PSObject.Properties.Name | Sort-Object -Descending)) {
            $reordered[$name] = $config.$name
        }
        $reordered['$schema'] = 'a-different-editor-only-schema-location.json'

        (Get-BootstrapConfigurationFingerprint -Config $reordered) |
            Should -Be (Get-BootstrapConfigurationFingerprint -Config $config)
    }

    It 'normalizes GUID casing and optional default fields' {
        $config = New-TestBootstrapConfig
        $equivalent = Copy-TestBootstrapConfig -Config $config
        $equivalent.subscriptionId = $equivalent.subscriptionId.ToUpperInvariant()
        $equivalent.tenantId = $equivalent.tenantId.ToUpperInvariant()
        foreach ($name in @(
            'policyProvisioningEnabled',
            'policyProvisioningOrganization',
            'policyProvisioningApplicationId',
            'policyProvisioningCertificateSecretUri'
        )) {
            $equivalent.purview.PSObject.Properties.Remove($name)
        }

        (Get-BootstrapConfigurationFingerprint -Config $equivalent) |
            Should -Be (Get-BootstrapConfigurationFingerprint -Config $config)
    }

    It 'changes when a deployment-affecting setting changes' {
        $config = New-TestBootstrapConfig
        $changed = Copy-TestBootstrapConfig -Config $config
        $changed.promptShield.skuName = 'F0'

        (Get-BootstrapConfigurationFingerprint -Config $changed) |
            Should -Not -Be (Get-BootstrapConfigurationFingerprint -Config $config)
    }

    It 'canonicalizes nested arrays in plan descriptors' {
        $first = [ordered]@{ operations = @('foundation', 'runtime'); options = [ordered]@{ enabled = $true } }
        $second = [ordered]@{ options = [ordered]@{ enabled = $true }; operations = @('foundation', 'runtime') }

        (Get-BootstrapObjectFingerprint -InputObject $first) |
            Should -Be (Get-BootstrapObjectFingerprint -InputObject $second)
    }

    It 'returns a canonical fingerprint for bootstrap source' {
        Get-BootstrapSourceFingerprint | Should -Match '^sha256:[0-9a-f]{64}$'
    }

    It 'rejects a symbolic-link deployment input instead of hashing only its target path' {
        $target = Join-Path $TestDrive 'mutable-target.ps1'
        'Write-Output safe-test-content' | Set-Content -LiteralPath $target -Encoding utf8NoBOM
        $link = Join-Path $script:RepositoryRoot "bootstrap/source-fingerprint-link-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            try { New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null }
            catch {
                Set-ItResult -Skipped -Because 'This test host cannot create symbolic links.'
                return
            }

            { Get-BootstrapSourceFingerprint } | Should -Throw '*must not contain symbolic links or reparse points*'
        }
        finally {
            if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
        }
    }

    It 'excludes credential-class files from the accepted source manifest' {
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'src/.azure') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'bootstrap') -Force | Out-Null
        'namespace Safe;' | Set-Content -LiteralPath (Join-Path $TestDrive 'src/Safe.cs')
        'safe script' | Set-Content -LiteralPath (Join-Path $TestDrive 'bootstrap/safe.ps1')
        'private-credential-marker' | Set-Content -LiteralPath (Join-Path $TestDrive 'src/credentials.json')
        'private-npm-marker' | Set-Content -LiteralPath (Join-Path $TestDrive 'src/.npmrc')
        'private-token-marker' | Set-Content -LiteralPath (Join-Path $TestDrive 'src/.azure/token.json')
        'private-key-marker' | Set-Content -LiteralPath (Join-Path $TestDrive 'src/id_rsa')

        $paths = @(Get-BootstrapSourceManifest -Root $TestDrive | ForEach-Object { [string]$_.path })

        $paths | Should -Contain 'src/Safe.cs'
        $paths | Should -Contain 'bootstrap/safe.ps1'
        $paths | Should -Not -Contain 'src/credentials.json'
        $paths | Should -Not -Contain 'src/.npmrc'
        $paths | Should -Not -Contain 'src/.azure/token.json'
        $paths | Should -Not -Contain 'src/id_rsa'
    }
}

Describe 'Bootstrap state compatibility and atomic persistence' {
    It 'creates schema-v2 state with configuration, bootstrap, and source metadata' {
        $config = New-TestBootstrapConfig

        $state = New-BootstrapState -Config $config

        $state.schemaVersion | Should -Be 2
        $state.bootstrapVersion | Should -Match '^\d+\.\d+\.\d+$'
        $state.deploymentOwnershipId | Should -Match '^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
        $state.configurationFingerprint | Should -Be (Get-BootstrapConfigurationFingerprint -Config $config)
        $state.source.created.bootstrapSourceFingerprint | Should -Match '^sha256:[0-9a-f]{64}$'
        $state.source.created.repositoryCommit | Should -Match '^(unknown|[0-9a-f]{40,64})$'
    }

    It 'writes state atomically and leaves no temporary file' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $directory = Join-Path $TestDrive 'atomic'
        $path = Join-Path $directory 'state.json'

        Save-BootstrapState -State $state -Path $path

        { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop } |
            Should -Not -Throw
        @(Get-ChildItem -LiteralPath $directory -Filter '*.tmp').Count | Should -Be 0
    }

    It 'round-trips state only for the exact normalized configuration' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'roundtrip.json'
        Save-BootstrapState -State $state -Path $path

        $loaded = Read-BootstrapState -Path $path -Config $config

        $loaded.configurationFingerprint | Should -Be $state.configurationFingerprint
    }

    It 'refuses stale evidence after any configuration change' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $state.steps['Azure foundation'] = [ordered]@{ status = 'Completed'; evidence = [ordered]@{ resourceGroup = 'safe-id' } }
        $path = Join-Path $TestDrive 'stale.json'
        Save-BootstrapState -State $state -Path $path
        $changed = Copy-TestBootstrapConfig -Config $config
        $changed.projectName = 'newname'

        { Read-BootstrapState -Path $path -Config $changed } |
            Should -Throw '*configuration changed*Refusing to reuse*'
    }

    It 'refuses Entra adoption evidence that predates the ownership marker' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $state.Remove('deploymentOwnershipId')
        $state.steps['Gateway API identity'] = [ordered]@{ status = 'Completed'; evidence = [ordered]@{ gatewayApiClientId = 'safe-id' } }
        $path = Join-Path $TestDrive 'missing-ownership.json'
        $state | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8NoBOM

        { Read-BootstrapState -Path $path -Config $config } |
            Should -Throw '*no deployment ownership identifier*Refusing Entra application adoption*'
    }

    It 'reinitializes an empty state when configuration changes' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'empty-changed.json'
        Save-BootstrapState -State $state -Path $path
        $changed = Copy-TestBootstrapConfig -Config $config
        $changed.projectName = 'newname'

        $loaded = Read-BootstrapState -Path $path -Config $changed

        $loaded.configurationFingerprint | Should -Be (Get-BootstrapConfigurationFingerprint -Config $changed)
        $loaded.steps.Count | Should -Be 0
    }

    It 'refuses legacy state that contains unverifiable evidence' {
        $config = New-TestBootstrapConfig
        $legacy = [ordered]@{
            schemaVersion = 1
            deploymentKey = "$($config.subscriptionId)/$($config.resourceGroupName)/$($config.environment)"
            createdAtUtc = '2026-08-29T00:00:00.0000000+00:00'
            steps = [ordered]@{ Prerequisites = [ordered]@{ status = 'Completed' } }
            outputs = [ordered]@{}
        }
        $path = Join-Path $TestDrive 'legacy-evidence.json'
        $legacy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8NoBOM

        { Read-BootstrapState -Path $path -Config $config } |
            Should -Throw '*Legacy bootstrap state contains reusable evidence*'
    }

    It 'migrates empty legacy state without claiming evidence' {
        $config = New-TestBootstrapConfig
        $legacy = [ordered]@{
            schemaVersion = 1
            deploymentKey = "$($config.subscriptionId)/$($config.resourceGroupName)/$($config.environment)"
            createdAtUtc = '2026-08-29T00:00:00.0000000+00:00'
            steps = [ordered]@{}
            outputs = [ordered]@{}
        }
        $path = Join-Path $TestDrive 'legacy-empty.json'
        $legacy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8NoBOM

        $loaded = Read-BootstrapState -Path $path -Config $config

        $loaded.schemaVersion | Should -Be 2
        $loaded.migration.fromSchemaVersion | Should -Be 1
        $loaded.migration.reusedEvidence | Should -BeFalse
    }

    It 'refuses state created by a newer schema' {
        $config = New-TestBootstrapConfig
        $future = New-BootstrapState -Config $config
        $future.schemaVersion = 999
        $path = Join-Path $TestDrive 'future.json'
        $future | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8NoBOM

        { Read-BootstrapState -Path $path -Config $config } | Should -Throw '*newer than this bootstrap supports*'
    }

    It 'stores only a generic failure message in state' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'failure.json'

        try {
            Invoke-BootstrapStateStep -Name 'Expected failure' -State $state -StatePath $path -Action {
                throw 'private-provider-body-marker'
            }
        }
        catch { }

        $raw = Get-Content -LiteralPath $path -Raw
        $raw | Should -Not -Match 'private-provider-body-marker'
        ($raw | ConvertFrom-Json -Depth 100).steps.'Expected failure'.status | Should -Be 'Failed'
    }

    It 'preserves safe partial evidence across a failed replayable step and exposes it to Resume' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'partial-evidence.json'

        try {
            Invoke-BootstrapStateStep -Name 'Partial checkpoint' -State $state -StatePath $path -Action {
                $state.steps['Partial checkpoint'].evidence = [ordered]@{ completedComponents = @('api') }
                Save-BootstrapState -State $state -Path $path
                throw 'simulated-crash-after-checkpoint'
            }
        }
        catch { }

        $state.steps['Partial checkpoint'].status | Should -Be 'Failed'
        @($state.steps['Partial checkpoint'].evidence.completedComponents) | Should -Be @('api')
        $result = Invoke-BootstrapStateStep -Name 'Partial checkpoint' -State $state -StatePath $path -Action {
            @($state.steps['Partial checkpoint'].evidence.completedComponents) | Should -Be @('api')
            return [ordered]@{ completedComponents = @('api', 'worker', 'adminUi') }
        }

        @($result.completedComponents) | Should -Be @('api', 'worker', 'adminUi')
    }

    It 'fails closed instead of persisting noisy action output as evidence' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'noisy-action.json'

        { Invoke-BootstrapStateStep -Name 'Noisy action' -State $state -StatePath $path -Action {
            'private-provider-output-that-is-not-evidence'
            return [ordered]@{ resourceId = 'safe-resource-id' }
        } } | Should -Throw '*did not return exactly one non-null evidence object*'

        $raw = Get-Content -LiteralPath $path -Raw
        $raw | Should -Not -Match 'private-provider-output-that-is-not-evidence'
        ($raw | ConvertFrom-Json -Depth 100).steps.'Noisy action'.status | Should -Be 'Failed'
    }

    It 'emits structured safe lifecycle events without action output' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'events.json'
        $events = [Collections.Generic.List[object]]::new()
        $writer = { param($Event) $events.Add($Event) }.GetNewClosure()
        Set-BootstrapEventWriter -Writer $writer
        try {
            Invoke-BootstrapStateStep -Name 'Event test' -State $state -StatePath $path -Action {
                return [ordered]@{ providerDetail = 'must-not-be-an-event-field' }
            } | Out-Null
        }
        finally {
            Set-BootstrapEventWriter -Writer $null
        }

        $events.Count | Should -Be 2
        $events[0].status | Should -Be 'started'
        $events[1].status | Should -Be 'completed'
        ($events | ConvertTo-Json -Depth 10) | Should -Not -Match 'must-not-be-an-event-field'
    }

    It 'refuses to reuse a completed step without independent validation' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $state.steps['External mutation'] = [ordered]@{
            status = 'Completed'
            completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            evidence = [ordered]@{ resourceId = 'safe-resource-id' }
        }
        $path = Join-Path $TestDrive 'missing-validator.json'
        Save-BootstrapState -State $state -Path $path

        { Invoke-BootstrapStateStep -Name 'External mutation' -State $state -StatePath $path -Action {
            throw 'Action must not run without validation.'
        } } | Should -Throw '*cannot be reused without an independent read-only validator*'

        $state.steps['External mutation'].status | Should -Be 'Failed'
        $state.steps['External mutation'].evidence.resourceId | Should -Be 'safe-resource-id'
    }

    It 'reuses completed evidence only after its validator succeeds' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $evidence = [ordered]@{ resourceId = 'safe-resource-id' }
        $state.steps['Validated mutation'] = [ordered]@{
            status = 'Completed'
            completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            evidence = $evidence
        }
        $path = Join-Path $TestDrive 'validated-reuse.json'
        Save-BootstrapState -State $state -Path $path

        $result = Invoke-BootstrapStateStep -Name 'Validated mutation' -State $state -StatePath $path -Validate {
            return $true
        } -Action {
            throw 'Action must not run after successful validation.'
        }

        $result.resourceId | Should -Be 'safe-resource-id'
    }

    It 'rejects non-Boolean or noisy validator output' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $state.steps['Noisy validation'] = [ordered]@{
            status = 'Completed'
            evidence = [ordered]@{ resourceId = 'safe-resource-id' }
        }
        $path = Join-Path $TestDrive 'noisy-validator.json'
        Save-BootstrapState -State $state -Path $path

        { Invoke-BootstrapStateStep -Name 'Noisy validation' -State $state -StatePath $path -Validate {
            'provider-output-that-must-not-authorize-reuse'
            return $false
        } -Action {
            throw 'Action must not run after invalid validation output.'
        } } | Should -Throw '*could not be independently revalidated*'

        $state.steps['Noisy validation'].status | Should -Be 'Failed'
        $state.steps['Noisy validation'].evidence.resourceId | Should -Be 'safe-resource-id'
    }

    It 'reconciles a previously started non-replayable step without invoking its action' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $state.steps['One-shot mutation'] = [ordered]@{
            status = 'Failed'
            startedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('O')
            failedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        }
        $path = Join-Path $TestDrive 'reconciled-one-shot.json'
        Save-BootstrapState -State $state -Path $path
        $script:oneShotActionRuns = 0

        $result = Invoke-BootstrapStateStep -Name 'One-shot mutation' -State $state -StatePath $path `
            -NoAutomaticReplayAfterStart -Reconcile {
                return [ordered]@{
                    recovered = $true
                    evidence = [ordered]@{ resourceId = 'exact-provider-id' }
                }
            } -Action {
                $script:oneShotActionRuns++
                return [ordered]@{ resourceId = 'unexpected-replay' }
            }

        $script:oneShotActionRuns | Should -Be 0
        $result.resourceId | Should -Be 'exact-provider-id'
        $state.steps['One-shot mutation'].status | Should -Be 'Completed'
        $state.steps['One-shot mutation'].reconciledAtUtc | Should -Not -BeNullOrEmpty
    }

    It 'preserves an unresolved non-replayable outcome and never invokes its action' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $state.steps['Ambiguous mutation'] = [ordered]@{
            status = 'Running'
            startedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('O')
        }
        $path = Join-Path $TestDrive 'ambiguous-one-shot.json'
        Save-BootstrapState -State $state -Path $path
        $script:ambiguousActionRuns = 0

        { Invoke-BootstrapStateStep -Name 'Ambiguous mutation' -State $state -StatePath $path `
            -NoAutomaticReplayAfterStart -Reconcile {
                return [ordered]@{ recovered = $false }
            } -Action {
                $script:ambiguousActionRuns++
                return [ordered]@{ resourceId = 'unexpected-replay' }
            }
        } | Should -Throw '*could not be reconciled exactly*No mutation was repeated*'

        $script:ambiguousActionRuns | Should -Be 0
        $state.steps['Ambiguous mutation'].status | Should -Be 'Running'
    }

    It 'does not replay a completed non-replayable step when exact validation becomes stale' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $state.steps['Drifted one-shot mutation'] = [ordered]@{
            status = 'Completed'
            startedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('O')
            completedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('O')
            evidence = [ordered]@{ resourceId = 'prior-provider-id' }
        }
        $path = Join-Path $TestDrive 'drifted-one-shot.json'
        Save-BootstrapState -State $state -Path $path
        $script:driftedActionRuns = 0

        { Invoke-BootstrapStateStep -Name 'Drifted one-shot mutation' -State $state -StatePath $path `
            -NoAutomaticReplayAfterStart -Validate { return $false } -Action {
                $script:driftedActionRuns++
                return [ordered]@{ resourceId = 'unexpected-replay' }
            }
        } | Should -Throw '*no longer matches exact provider readback*No mutation was repeated*'

        $script:driftedActionRuns | Should -Be 0
        $state.steps['Drifted one-shot mutation'].status | Should -Be 'Failed'
        $state.steps['Drifted one-shot mutation'].evidence.resourceId | Should -Be 'prior-provider-id'
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100).steps.'Drifted one-shot mutation'.status |
            Should -Be 'Failed'
    }

    It 'reruns an idempotent action when validation returns exactly false' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $state.steps['Stale validation'] = [ordered]@{
            status = 'Completed'
            startedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('O')
            evidence = [ordered]@{ resourceId = 'stale-id' }
        }
        $path = Join-Path $TestDrive 'stale-validator.json'
        Save-BootstrapState -State $state -Path $path

        $result = Invoke-BootstrapStateStep -Name 'Stale validation' -State $state -StatePath $path -Validate {
            return $false
        } -Action {
            return [ordered]@{ resourceId = 'fresh-id' }
        }

        $result.resourceId | Should -Be 'fresh-id'
        $state.steps['Stale validation'].status | Should -Be 'Completed'
        $state.steps['Stale validation'].evidence.resourceId | Should -Be 'fresh-id'
    }

    It 'does not write Common warning records when structured output reruns stale evidence' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $state.steps['Structured stale validation'] = [ordered]@{
            status = 'Completed'
            startedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('O')
            evidence = [ordered]@{ resourceId = 'stale-id' }
        }
        $path = Join-Path $TestDrive 'structured-stale-validator.json'
        Save-BootstrapState -State $state -Path $path
        $warnings = @()

        Set-BootstrapStructuredOutput -Enabled $true
        try {
            Invoke-BootstrapStateStep -Name 'Structured stale validation' -State $state -StatePath $path -Validate {
                return $false
            } -Action {
                return [ordered]@{ resourceId = 'fresh-id' }
            } -WarningVariable warnings | Out-Null
        }
        finally {
            Set-BootstrapStructuredOutput -Enabled $false
        }

        @($warnings).Count | Should -Be 0
    }
}

Describe 'External command redaction' {
    It 'does not include captured provider output in a thrown failure' {
        $pwsh = (Get-Process -Id $PID).Path
        try {
            Invoke-BootstrapCommand -FilePath $pwsh -ArgumentList @(
                '-NoLogo',
                '-NoProfile',
                '-Command',
                '[Console]::Error.Write("private-provider-marker"); exit 7'
            )
            throw 'Expected the command to fail.'
        }
        catch {
            $_.Exception.Message | Should -BeLike '*failed with exit code 7*'
            $_.Exception.Message | Should -Not -BeLike '*private-provider-marker*'
        }
    }

    It 'suppresses NoCapture provider streams in structured-output mode' {
        $pwsh = (Get-Process -Id $PID).Path
        Set-BootstrapStructuredOutput -Enabled $true
        try {
            $result = & {
                Invoke-BootstrapCommand -FilePath $pwsh -NoCapture -ArgumentList @(
                    '-NoLogo',
                    '-NoProfile',
                    '-Command',
                    'Write-Output "private-stdout-marker"; [Console]::Error.Write("private-stderr-marker"); exit 0'
                )
            } *>&1
        }
        finally {
            Set-BootstrapStructuredOutput -Enabled $false
        }

        ($result | Out-String) | Should -Not -Match 'private-(stdout|stderr)-marker'
        @($result)[-1] | Should -Be 0
    }

    It 'keeps structured NoCapture failures fixed and provider-output free' {
        $pwsh = (Get-Process -Id $PID).Path
        Set-BootstrapStructuredOutput -Enabled $true
        try {
            try {
                Invoke-BootstrapCommand -FilePath $pwsh -NoCapture -ArgumentList @(
                    '-NoLogo',
                    '-NoProfile',
                    '-Command',
                    '[Console]::Error.Write("private-structured-provider-marker"); exit 9'
                )
                throw 'Expected the command to fail.'
            }
            catch {
                $_.Exception.Message | Should -BeLike '*failed with exit code 9*'
                $_.Exception.Message | Should -Not -BeLike '*private-structured-provider-marker*'
            }
        }
        finally {
            Set-BootstrapStructuredOutput -Enabled $false
        }
    }
}

Describe 'Bootstrap Azure CLI subscription boundary' {
    BeforeEach {
        Clear-BootstrapAzureSubscriptionContext
        Set-BootstrapAzureSubscriptionContext `
            -SubscriptionId '11111111-1111-4111-8111-111111111111' `
            -TenantId '22222222-2222-4222-8222-222222222222'
    }

    AfterEach {
        Clear-BootstrapAzureSubscriptionContext
    }

    It 'pins reviewed Azure resource families to the exact subscription' {
        @(Get-BootstrapAzureCliArguments -Arguments @('group', 'show', '--name', 'rg-safe')) |
            Should -Be @(
                'group', 'show', '--name', 'rg-safe',
                '--subscription', '11111111-1111-4111-8111-111111111111')

        @(Get-BootstrapAzureCliArguments -Arguments @(
                'account', 'get-access-token', '--resource', 'https://graph.microsoft.com/')) |
            Should -Be @(
                'account', 'get-access-token', '--resource', 'https://graph.microsoft.com/',
                '--subscription', '11111111-1111-4111-8111-111111111111')
    }

    It 'keeps one matching explicit resource subscription and rejects conflicts or duplicates' {
        @(Get-BootstrapAzureCliArguments -Arguments @(
                'group', 'show', '--subscription=11111111-1111-4111-8111-111111111111')) |
            Should -Be @(
                'group', 'show', '--subscription=11111111-1111-4111-8111-111111111111')

        { Get-BootstrapAzureCliArguments -Arguments @(
                'group', 'show', '--subscription', '22222222-2222-4222-8222-222222222222') } |
            Should -Throw '*exact bootstrap subscription context*'
        { Get-BootstrapAzureCliArguments -Arguments @(
                'group', 'show', '--subscription', '11111111-1111-4111-8111-111111111111',
                '--subscription=11111111-1111-4111-8111-111111111111') } |
            Should -Throw '*more than one explicit subscription*'
    }

    It 'keeps account show as an unpinned active-context probe' {
        @(Get-BootstrapAzureCliArguments -Arguments @('account', 'show', '--output', 'json')) |
            Should -Be @('account', 'show', '--output', 'json')

        { Get-BootstrapAzureCliArguments -Arguments @(
                'account', 'show', '--subscription', '11111111-1111-4111-8111-111111111111') } |
            Should -Throw '*active-context probe*'
    }

    It 'leaves reviewed local Bicep commands unpinned' {
        @(Get-BootstrapAzureCliArguments -Arguments @('bicep', 'version')) |
            Should -Be @('bicep', 'version')
        @(Get-BootstrapAzureCliArguments -Arguments @('version')) |
            Should -Be @('version')
    }

    It 'rejects native Graph, context-changing, and unknown commands after authentication' {
        foreach ($arguments in @(
            @('ad', 'signed-in-user', 'show'),
            @('rest', '--method', 'GET', '--url', 'https://graph.microsoft.com/v1.0/me'),
            @('account', 'set', '--subscription', '11111111-1111-4111-8111-111111111111'),
            @('login', '--tenant', '22222222-2222-4222-8222-222222222222'),
            @('extension', 'list')
        )) {
            { Get-BootstrapAzureCliArguments -Arguments $arguments } | Should -Throw
        }
    }
}

Describe 'Exact-account Microsoft Graph token boundary' {
    InModuleScope Common {
        BeforeEach {
            Clear-BootstrapAzureSubscriptionContext
            Set-BootstrapAzureSubscriptionContext `
                -SubscriptionId '11111111-1111-4111-8111-111111111111' `
                -TenantId '22222222-2222-4222-8222-222222222222'
            $script:tokenMetadata = [ordered]@{
                accessToken = 'test-only-token-value'
                expires_on = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
                subscription = '11111111-1111-4111-8111-111111111111'
                tenant = '22222222-2222-4222-8222-222222222222'
                tokenType = 'Bearer'
            }
            Mock Invoke-BootstrapCommand {
                return $script:tokenMetadata | ConvertTo-Json -Compress
            }
        }

        AfterEach {
            Clear-BootstrapAzureSubscriptionContext
        }

        It 'acquires and caches a token from the exact subscription and verifies returned tenant metadata' {
            Get-BootstrapGraphAccessToken | Should -BeExactly 'test-only-token-value'
            Get-BootstrapGraphAccessToken | Should -BeExactly 'test-only-token-value'

            Should -Invoke Invoke-BootstrapCommand -Times 1 -Exactly -ParameterFilter {
                $FilePath -ceq 'az' -and
                ($ArgumentList -join '|') -ceq (
                    'account|get-access-token|--subscription|11111111-1111-4111-8111-111111111111|' +
                    '--resource|https://graph.microsoft.com/|--output|json|--only-show-errors')
            }
        }

        It 'rejects mismatched or malformed token metadata without reflecting token material' {
            foreach ($mutation in @('tenant', 'subscription', 'tokenType', 'expires_on')) {
                Set-BootstrapAzureSubscriptionContext `
                    -SubscriptionId '11111111-1111-4111-8111-111111111111' `
                    -TenantId '22222222-2222-4222-8222-222222222222'
                $script:tokenMetadata = [ordered]@{
                    accessToken = 'private-token-marker'
                    expires_on = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
                    subscription = '11111111-1111-4111-8111-111111111111'
                    tenant = '22222222-2222-4222-8222-222222222222'
                    tokenType = 'Bearer'
                }
                switch ($mutation) {
                    'tenant' { $script:tokenMetadata.tenant = '33333333-3333-4333-8333-333333333333' }
                    'subscription' { $script:tokenMetadata.subscription = '33333333-3333-4333-8333-333333333333' }
                    'tokenType' { $script:tokenMetadata.tokenType = 'Unexpected' }
                    'expires_on' { $script:tokenMetadata.expires_on = 1 }
                }
                try {
                    Get-BootstrapGraphAccessToken
                    throw 'Expected token metadata rejection.'
                }
                catch {
                    $_.Exception.Message | Should -Not -Match 'private-token-marker'
                    $_.Exception.Message | Should -Match 'metadata'
                }
            }
        }
    }
}

Describe 'Bounded in-process Microsoft Graph request contract' {
    It 'accepts only reviewed v1.0 URLs, methods, headers, and JSON bodies' {
        $get = ConvertFrom-BootstrapGraphAzRestArguments -Arguments @(
            'rest', '--method', 'GET', '--url',
            'https://graph.microsoft.com/v1.0/me?$select=id',
            '--output', 'json', '--only-show-errors')
        $get.method | Should -BeExactly 'GET'
        $get.uri.AbsoluteUri | Should -BeExactly 'https://graph.microsoft.com/v1.0/me?$select=id'

        foreach ($method in @('POST', 'PATCH')) {
            $write = ConvertFrom-BootstrapGraphAzRestArguments -Arguments @(
                'rest', '--method', $method, '--url',
                'https://graph.microsoft.com/v1.0/applications',
                '--headers', 'Content-Type=application/json', 'OData-Version=4.0',
                '--body', '{"displayName":"safe"}', '--output', 'none')
            $write.method | Should -BeExactly $method
            $write.body | Should -BeExactly '{"displayName":"safe"}'
        }

        (ConvertFrom-BootstrapGraphAzRestArguments -Arguments @(
                'rest', '--method', 'DELETE', '--url',
                'https://graph.microsoft.com/v1.0/applications/11111111-1111-4111-8111-111111111111')).method |
            Should -BeExactly 'DELETE'
    }

    It 'rejects off-origin, beta, redirect-shaped, credentialed, and malformed requests' {
        foreach ($url in @(
            'http://graph.microsoft.com/v1.0/me',
            'https://example.invalid/v1.0/me',
            'https://graph.microsoft.com/beta/applications',
            'https://user@graph.microsoft.com/v1.0/me',
            'https://graph.microsoft.com/v1.0/me#fragment'
        )) {
            { ConvertFrom-BootstrapGraphAzRestArguments -Arguments @(
                    'rest', '--method', 'GET', '--url', $url) } |
                Should -Throw '*exact public-cloud HTTPS v1.0*'
        }

        { ConvertFrom-BootstrapGraphAzRestArguments -Arguments @(
                'rest', '--method', 'GET', '--url', 'https://graph.microsoft.com/v1.0/me',
                '--headers', 'Authorization=private-marker') } |
            Should -Throw '*outside the reviewed*'
        { ConvertFrom-BootstrapGraphAzRestArguments -Arguments @(
                'rest', '--method', 'POST', '--url', 'https://graph.microsoft.com/v1.0/applications',
                '--body', 'not-json') } |
            Should -Throw '*not valid JSON*'
    }
}

Describe 'Bounded in-process Microsoft Graph HTTP execution' {
    InModuleScope Common {
        BeforeEach {
            $script:graphResponse = $null
            $script:fakeGraphClient = [pscustomobject]@{}
            $script:fakeGraphClient | Add-Member -MemberType ScriptMethod -Name SendAsync -Value {
                param($Request, $CompletionOption)
                $script:capturedGraphMethod = [string]$Request.Method.Method
                $script:capturedGraphUri = [string]$Request.RequestUri.AbsoluteUri
                $completion = [Threading.Tasks.TaskCompletionSource[Net.Http.HttpResponseMessage]]::new()
                $completion.SetResult($script:graphResponse)
                return $completion.Task
            }
            Mock Get-BootstrapGraphAccessToken { return 'private-token-marker' }
            Mock Get-BootstrapGraphHttpClient { return $script:fakeGraphClient }
        }

        AfterEach {
            if ($null -ne $script:graphResponse) {
                $script:graphResponse.Dispose()
                $script:graphResponse = $null
            }
        }

        It 'parses a bounded successful JSON response with a concrete content length' {
            $script:graphResponse = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
            $script:graphResponse.Content = [Net.Http.StringContent]::new('{"id":"safe-id"}')

            $result = Invoke-BootstrapGraphAzRest -Arguments @(
                'rest', '--method', 'GET', '--url',
                'https://graph.microsoft.com/v1.0/me?$select=id')

            $result.id | Should -BeExactly 'safe-id'
            $script:capturedGraphMethod | Should -BeExactly 'GET'
            $script:capturedGraphUri | Should -BeExactly 'https://graph.microsoft.com/v1.0/me?$select=id'
        }

        It 'suppresses provider bodies and bearer material on an HTTP failure' {
            $script:graphResponse = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::BadRequest)
            $script:graphResponse.Content = [Net.Http.StringContent]::new('private-provider-body-marker')

            try {
                Invoke-BootstrapGraphAzRest -Arguments @(
                    'rest', '--method', 'GET', '--url', 'https://graph.microsoft.com/v1.0/me')
                throw 'Expected the Graph request to fail.'
            }
            catch {
                $_.Exception.Message | Should -Match 'HTTP 400'
                $_.Exception.Message | Should -Not -Match 'private-provider-body-marker|private-token-marker'
            }
        }

        It 'enforces the byte cap when the provider omits Content-Length' {
            $script:graphResponse = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
            $script:graphResponse.Content = [Net.Http.ByteArrayContent]::new([byte[]]::new(16777217))
            $script:graphResponse.Content.Headers.ContentLength = $null

            { Invoke-BootstrapGraphAzRest -Arguments @(
                    'rest', '--method', 'GET', '--url', 'https://graph.microsoft.com/v1.0/me') } |
                Should -Throw '*exceeded the reviewed sixteen-megabyte boundary*'
        }
    }
}

Describe 'Accepted deployment plan binding' {
    It 'rejects a new source generation after durable state evidence exists' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $state.steps['Azure foundation'] = [ordered]@{
            status = 'Completed'
            evidence = [ordered]@{ resourceGroupName = 'rg-safe' }
        }
        $state.source.lastWritten.bootstrapSourceFingerprint = 'sha256:' + ('0' * 64)

        { Assert-BootstrapStateAllowsSourcePlan -State $state } |
            Should -Throw '*will not mix source generations*'
    }

    It 'requires one canonical reviewed SQL client IPv4 at plan acceptance' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'invalid-client-ip.json'
        $plan = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{ operation = 'accepted' })

        { Set-BootstrapAcceptedPlan -State $state -StatePath $path -PlanFingerprint $plan -BootstrapClientIpv4 '2001:db8::1' } |
            Should -Throw '*canonical IPv4*'
    }

    It 'binds acceptance to the plan, configuration, source, and bootstrap version' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'accepted-plan.json'
        $planFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
            configurationFingerprint = $state.configurationFingerprint
            operations = @('foundation', 'runtime')
        })

        Set-BootstrapAcceptedPlan -State $state -StatePath $path -PlanFingerprint $planFingerprint -BootstrapClientIpv4 '192.0.2.10' | Out-Null

        Assert-BootstrapAcceptedPlan -State $state -PlanFingerprint $planFingerprint | Should -BeTrue
        $state.acceptedPlan.configurationFingerprint | Should -Be $state.configurationFingerprint
        $state.acceptedPlan.sourceFingerprint | Should -Be (Get-BootstrapSourceFingerprint)
        $state.acceptedPlan.bootstrapClientIpv4 | Should -Be '192.0.2.10'
        Test-Path -LiteralPath (Resolve-BootstrapAcceptedSourceRoot -State $state) -PathType Container | Should -BeTrue
    }

    It 'validates an accepted plan after the persisted state is reloaded' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'accepted-plan-roundtrip.json'
        $planFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
            configurationFingerprint = $state.configurationFingerprint
            operations = @('foundation', 'runtime')
        })
        Set-BootstrapAcceptedPlan -State $state -StatePath $path -PlanFingerprint $planFingerprint -BootstrapClientIpv4 '192.0.2.10' | Out-Null

        $reloaded = Read-BootstrapState -Path $path -Config $config

        $reloaded.acceptedPlan.acceptedAtUtc | Should -BeOfType [string]
        Assert-BootstrapAcceptedPlan -State $reloaded -PlanFingerprint $planFingerprint | Should -BeTrue
    }

    It 'rejects a plan fingerprint that was not accepted' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'wrong-plan.json'
        $accepted = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{ operation = 'accepted' })
        $different = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{ operation = 'different' })
        Set-BootstrapAcceptedPlan -State $state -StatePath $path -PlanFingerprint $accepted -BootstrapClientIpv4 '192.0.2.10' | Out-Null

        { Assert-BootstrapAcceptedPlan -State $state -PlanFingerprint $different } |
            Should -Throw '*accepted deployment plan is stale*'
    }

    It 'atomically clears prior acceptance before a fresh plan' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'cleared-plan.json'
        $plan = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{ operation = 'accepted' })
        Set-BootstrapAcceptedPlan -State $state -StatePath $path -PlanFingerprint $plan -BootstrapClientIpv4 '192.0.2.10' | Out-Null

        Clear-BootstrapAcceptedPlan -State $state -StatePath $path

        $state.Contains('acceptedPlan') | Should -BeFalse
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100).PSObject.Properties.Name |
            Should -Not -Contain 'acceptedPlan'
        { Assert-BootstrapAcceptedPlan -State $state -PlanFingerprint $plan } |
            Should -Throw '*No accepted deployment plan exists*'
    }

    It 'rejects acceptance when source changed before it was recorded' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'wrong-source.json'
        $plan = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{ operation = 'one' })
        $differentSource = 'sha256:' + ('0' * 64)

        { Set-BootstrapAcceptedPlan -State $state -StatePath $path -PlanFingerprint $plan -SourceFingerprint $differentSource -BootstrapClientIpv4 '192.0.2.10' } |
            Should -Throw '*source changed before plan acceptance*'
    }

    It 'does not allow callers to bypass current source binding with an override' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'source-override.json'
        $plan = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{ operation = 'one' })
        Set-BootstrapAcceptedPlan -State $state -StatePath $path -PlanFingerprint $plan -BootstrapClientIpv4 '192.0.2.10' | Out-Null
        $differentSource = 'sha256:' + ('0' * 64)

        { Assert-BootstrapAcceptedPlan -State $state -PlanFingerprint $plan -SourceFingerprint $differentSource } |
            Should -Throw '*accepted deployment plan is stale*'
    }

    It 'rejects accepted plans after the bounded freshness window' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'expired-plan.json'
        $plan = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{ operation = 'one' })
        Set-BootstrapAcceptedPlan -State $state -StatePath $path -PlanFingerprint $plan -BootstrapClientIpv4 '192.0.2.10' | Out-Null
        $state.acceptedPlan.acceptedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-61).ToString('O')

        { Assert-BootstrapAcceptedPlan -State $state -PlanFingerprint $plan } |
            Should -Throw '*outside its 60-minute validity window*'
    }

    It 'blocks every later state write when accepted source bytes no longer match' {
        $config = New-TestBootstrapConfig
        $state = New-BootstrapState -Config $config
        $path = Join-Path $TestDrive 'changed-after-acceptance.json'
        $plan = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{ operation = 'accepted' })
        Set-BootstrapAcceptedPlan -State $state -StatePath $path -PlanFingerprint $plan -BootstrapClientIpv4 '192.0.2.10' | Out-Null
        $state.acceptedPlan.sourceFingerprint = 'sha256:' + ('0' * 64)

        { Save-BootstrapState -State $state -Path $path } |
            Should -Throw '*execution snapshot is absent, modified*'
    }
}
