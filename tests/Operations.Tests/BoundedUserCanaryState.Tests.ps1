Describe 'Bounded user canary durable state' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $script:StateModulePath = Join-Path $script:RepositoryRoot 'operations/BoundedUserCanaryState.psm1'
        Import-Module $script:StateModulePath -Force

        function New-TestCanaryBindings {
            return [ordered]@{
                subscriptionId = '11111111-1111-1111-1111-111111111111'
                tenantId = '22222222-2222-2222-2222-222222222222'
                projectName = 'a365gw10'
                environment = 'dev'
                resourceGroup = 'rg-a365-custom-gw-phase6i'
                apiBaseUrl = 'https://gateway.example.test/'
                gatewayApiApplicationClientId = '33333333-3333-3333-3333-333333333333'
                agentRegistrationId = '44444444-4444-4444-4444-444444444444'
                externalAgentId = 'agent-state-test'
                tenantUserObjectId = '55555555-5555-5555-5555-555555555555'
                promptShieldExpected = 'false'
                purviewExpected = 'false'
                wrapperSha256 = "sha256:$('a' * 64)"
                helperBundleSha256 = "sha256:$('c' * 64)"
                canaryBundleSha256 = "sha256:$('b' * 64)"
                preChildDisplayName = 'A365 Gateway Bounded Canary - a365gw10-dev-44444444444444444444444444444444 - PreChild'
                childArmedDisplayName = 'A365 Gateway Bounded Canary - a365gw10-dev-44444444444444444444444444444444 - ChildArmed'
                executionTag = 'a365gw:bounded-user-canary:44444444444444444444444444444444'
            }
        }

        function Move-TestCanaryToChildLaunch {
            param(
                [Parameter(Mandatory)][System.Collections.IDictionary]$State,
                [Parameter(Mandatory)][System.Collections.IDictionary]$Bindings
            )

            $State = Set-BoundedUserCanaryStateStatus -State $State -Bindings $Bindings -Status 'ApplicationCreateStarted'
            $State = Set-BoundedUserCanaryStateStatus `
                -State $State `
                -Bindings $Bindings `
                -Status 'ApplicationObserved' `
                -TemporaryApplicationObjectId '66666666-6666-6666-6666-666666666666' `
                -TemporaryApplicationClientId '77777777-7777-7777-7777-777777777777'
            $State = Set-BoundedUserCanaryStateStatus -State $State -Bindings $Bindings -Status 'OwnerAddStarted'
            $State = Set-BoundedUserCanaryStateStatus -State $State -Bindings $Bindings -Status 'OwnerObserved'
            $State = Set-BoundedUserCanaryStateStatus -State $State -Bindings $Bindings -Status 'ServicePrincipalCreateStarted'
            $State = Set-BoundedUserCanaryStateStatus `
                -State $State `
                -Bindings $Bindings `
                -Status 'ServicePrincipalObserved' `
                -TemporaryServicePrincipalId '88888888-8888-8888-8888-888888888888'
            $State = Set-BoundedUserCanaryStateStatus -State $State -Bindings $Bindings -Status 'GrantCreateStarted'
            $State = Set-BoundedUserCanaryStateStatus `
                -State $State `
                -Bindings $Bindings `
                -Status 'AuthorityReady' `
                -TemporaryGrantId 'safe_grant_id'
            $State = Set-BoundedUserCanaryStateStatus -State $State -Bindings $Bindings -Status 'ArmStarted'
            $State = Set-BoundedUserCanaryStateStatus -State $State -Bindings $Bindings -Status 'ChildArmed'
            return Set-BoundedUserCanaryStateStatus -State $State -Bindings $Bindings -Status 'ChildLaunchStarted'
        }
    }

    BeforeEach {
        $script:Bindings = New-TestCanaryBindings
        $script:State = New-BoundedUserCanaryState -Bindings $script:Bindings
    }

    It 'creates a fixed safe-identifier Prepared state that does not require preservation' {
        $script:State.status | Should -BeExactly 'Prepared'
        $script:State.schemaVersion | Should -Be 2
        $script:State.Keys.Count | Should -Be 28
        $script:State.promptShieldExpected | Should -BeExactly 'false'
        $script:State.purviewExpected | Should -BeExactly 'false'
        $script:State.wrapperSha256 | Should -BeExactly $script:Bindings.wrapperSha256
        $script:State.helperBundleSha256 | Should -BeExactly $script:Bindings.helperBundleSha256
        $script:State.canaryBundleSha256 | Should -BeExactly $script:Bindings.canaryBundleSha256
        Test-BoundedUserCanaryStateRequiresPreservation `
            -State $script:State `
            -Bindings $script:Bindings | Should -BeFalse
    }

    It 'requires canonical lowercase protection expectations in the durable binding' {
        $uppercase = New-TestCanaryBindings
        $uppercase.promptShieldExpected = 'False'
        { New-BoundedUserCanaryState -Bindings $uppercase } |
            Should -Throw '*bounded non-secret contract*'

        $missing = New-TestCanaryBindings
        $missing.Remove('purviewExpected')
        { New-BoundedUserCanaryState -Bindings $missing } |
            Should -Throw '*unexpected property set*'
    }

    It 'round-trips atomically without temporary files or credential material' {
        $path = Join-Path $TestDrive 'nested/canary.json'
        Save-BoundedUserCanaryState -State $script:State -Path $path -Bindings $script:Bindings
        $loaded = Read-BoundedUserCanaryState -Path $path -Bindings $script:Bindings

        $loaded.status | Should -BeExactly 'Prepared'
        $loaded.subscriptionId | Should -BeExactly $script:Bindings.subscriptionId
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '*.tmp').Count | Should -Be 0
        $json = Get-Content -LiteralPath $path -Raw
        $json.Length | Should -BeLessThan 32768
        $json | Should -Not -Match (
            '(?i)api[_-]?key|bearer|client[_-]?secret|access[_-]?token|' +
            '"(?:prompt|response|content)"\s*:')
    }

    It 'normalizes PowerShell 7.0 through 7.4 automatic JSON dates before validation' {
        $path = Join-Path $TestDrive 'legacy-date-materialization.json'
        Save-BoundedUserCanaryState -State $script:State -Path $path -Bindings $script:Bindings
        $legacyParsed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $legacyParsed.createdAtUtc | Should -BeOfType [DateTime]

        InModuleScope BoundedUserCanaryState -Parameters @{ Parsed = $legacyParsed } {
            param($Parsed)
            Convert-CanaryParsedJsonDatesToStrings -Value $Parsed
        }
        $legacyParsed.createdAtUtc | Should -BeOfType [string]
        $legacyParsed.createdAtUtc | Should -BeExactly $script:State.createdAtUtc
        { Assert-BoundedUserCanaryState -State $legacyParsed -Bindings $script:Bindings } |
            Should -Not -Throw
    }

    It 'supports only the ordered per-mutation Started and Observed path' {
        $script:State = Move-TestCanaryToChildLaunch -State $script:State -Bindings $script:Bindings
        $script:State.status | Should -BeExactly 'ChildLaunchStarted'
        Test-BoundedUserCanaryStateRequiresPreservation `
            -State $script:State `
            -Bindings $script:Bindings | Should -BeTrue

        $script:State = Set-BoundedUserCanaryStateStatus `
            -State $script:State `
            -Bindings $script:Bindings `
            -Status 'CredentialObserved' `
            -RecoveryCredentialId '99999999-9999-9999-9999-999999999999'
        $script:State = Set-BoundedUserCanaryStateStatus `
            -State $script:State `
            -Bindings $script:Bindings `
            -Status 'Completed'

        $script:State.status | Should -BeExactly 'Completed'
        $script:State.completedAtUtc | Should -Not -BeNullOrEmpty
        Test-BoundedUserCanaryStateRequiresPreservation `
            -State $script:State `
            -Bindings $script:Bindings | Should -BeFalse
    }

    It 'allows direct OwnerObserved only when application creation already assigned the exact owner' {
        $script:State = Set-BoundedUserCanaryStateStatus `
            -State $script:State `
            -Bindings $script:Bindings `
            -Status 'ApplicationCreateStarted'
        $script:State = Set-BoundedUserCanaryStateStatus `
            -State $script:State `
            -Bindings $script:Bindings `
            -Status 'ApplicationObserved' `
            -TemporaryApplicationObjectId '66666666-6666-6666-6666-666666666666' `
            -TemporaryApplicationClientId '77777777-7777-7777-7777-777777777777'
        $script:State = Set-BoundedUserCanaryStateStatus `
            -State $script:State `
            -Bindings $script:Bindings `
            -Status 'OwnerObserved'

        $script:State.status | Should -BeExactly 'OwnerObserved'
    }

    It 'rejects skipped or repeated mutation stages without changing the last valid state' {
        {
            Set-BoundedUserCanaryStateStatus `
                -State $script:State `
                -Bindings $script:Bindings `
                -Status 'ApplicationObserved' `
                -TemporaryApplicationObjectId '66666666-6666-6666-6666-666666666666' `
                -TemporaryApplicationClientId '77777777-7777-7777-7777-777777777777'
        } | Should -Throw '*Prepared -> ApplicationObserved*'
        $script:State.status | Should -BeExactly 'Prepared'

        $script:State = Set-BoundedUserCanaryStateStatus `
            -State $script:State `
            -Bindings $script:Bindings `
            -Status 'ApplicationCreateStarted'
        {
            Set-BoundedUserCanaryStateStatus `
                -State $script:State `
                -Bindings $script:Bindings `
                -Status 'ApplicationCreateStarted'
        } | Should -Throw '*ApplicationCreateStarted -> ApplicationCreateStarted*'
        $script:State.status | Should -BeExactly 'ApplicationCreateStarted'
        $script:State.temporaryApplicationObjectId | Should -BeExactly ''
    }

    It 'does not mutate ChildLaunchStarted when credential observation lacks an exact ID' {
        $script:State = Move-TestCanaryToChildLaunch -State $script:State -Bindings $script:Bindings
        {
            Set-BoundedUserCanaryStateStatus `
                -State $script:State `
                -Bindings $script:Bindings `
                -Status 'CredentialObserved'
        } | Should -Throw '*must bind the exact observed credential*'

        $script:State.status | Should -BeExactly 'ChildLaunchStarted'
        $script:State.recoveryCredentialId | Should -BeExactly ''
    }

    It 'keeps a Completed tombstone immutable' {
        $script:State = Move-TestCanaryToChildLaunch -State $script:State -Bindings $script:Bindings
        $script:State = Set-BoundedUserCanaryStateStatus `
            -State $script:State `
            -Bindings $script:Bindings `
            -Status 'CredentialObserved' `
            -RecoveryCredentialId '99999999-9999-9999-9999-999999999999'
        $script:State = Set-BoundedUserCanaryStateStatus `
            -State $script:State `
            -Bindings $script:Bindings `
            -Status 'Completed'
        $completedAt = $script:State.completedAtUtc

        {
            Set-BoundedUserCanaryStateStatus `
                -State $script:State `
                -Bindings $script:Bindings `
                -Status 'Completed'
        } | Should -Throw '*Completed -> Completed*'
        $script:State.status | Should -BeExactly 'Completed'
        $script:State.completedAtUtc | Should -BeExactly $completedAt
    }

    It 'rejects a tampered invocation binding without returning file contents' {
        $path = Join-Path $TestDrive 'tampered-binding.json'
        Save-BoundedUserCanaryState -State $script:State -Path $path -Bindings $script:Bindings
        $tampered = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $tampered.projectName = 'wrongproject'
        [IO.File]::WriteAllText($path, ($tampered | ConvertTo-Json -Depth 20))

        $message = ''
        try { Read-BoundedUserCanaryState -Path $path -Bindings $script:Bindings | Out-Null }
        catch { $message = $_.Exception.Message }
        $message | Should -Match 'does not match this exact invocation'
        $message | Should -Not -Match 'wrongproject|11111111|agent-state-test'
    }

    It 'rejects unknown properties malformed JSON and oversized state' {
        $path = Join-Path $TestDrive 'invalid.json'
        Save-BoundedUserCanaryState -State $script:State -Path $path -Bindings $script:Bindings
        $unknown = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $unknown.unexpected = 'value'
        [IO.File]::WriteAllText($path, ($unknown | ConvertTo-Json -Depth 20))
        { Read-BoundedUserCanaryState -Path $path -Bindings $script:Bindings } |
            Should -Throw '*unexpected property set*'

        [IO.File]::WriteAllText($path, '{not-json')
        { Read-BoundedUserCanaryState -Path $path -Bindings $script:Bindings } |
            Should -Throw '*not valid bounded JSON*'

        [IO.File]::WriteAllText($path, ('x' * 32769))
        { Read-BoundedUserCanaryState -Path $path -Bindings $script:Bindings } |
            Should -Throw '*exceeds the bounded safe-identifier size*'
    }
}
