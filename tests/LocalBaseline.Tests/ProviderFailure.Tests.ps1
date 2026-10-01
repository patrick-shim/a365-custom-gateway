BeforeAll {
    $fixtureModuleName = "M5FailureFixture_$([guid]::NewGuid().ToString('N'))"
    $fixtureModulePath = Join-Path $TestDrive "$fixtureModuleName.psm1"
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\bootstrap\modules\Common.psm1') -Destination $fixtureModulePath
    $fixtureModule = Import-Module $fixtureModulePath -Force -DisableNameChecking -NoClobber -PassThru
    $tokens = $null
    $parseErrors = $null
    $bootstrap = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\..\bootstrap\bootstrap.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw 'Bootstrap source must parse before testing its safe failure projection.' }
    $projection = $bootstrap.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-GatewaySafeFailureEvent'
    }, $false)
    if ($null -eq $projection) { throw 'The authored safe failure projection is required.' }
    $projectionSource = $projection.Extent.Text

    function Project-FixtureFailure {
        param([Parameter(Mandatory)][Exception]$Failure)
        & $fixtureModule {
            param($definition, $exception)
            . ([scriptblock]::Create($definition))
            Get-GatewaySafeFailureEvent -FailureCode plan_what_if -FailureStage 'Plan review' -CommandMode Plan -Exception $exception
        } $projectionSource $Failure
    }

    $mfaFailure = "ERROR: NotSpecified - Resource 'fixture-resource' was disallowed by Azure: You are receiving this error because you tried to create, update or delete Azure resources without authenticating through MFA. User accounts must be authenticated through MFA to manage your resources. To resolve this error, go to https://aka.ms/MFAforAzure."
}

AfterAll {
    Remove-Module -Name $fixtureModuleName -Force
}

Describe 'Bounded provider failure diagnostics' {
    BeforeEach {
        Mock Invoke-BootstrapCommand -ModuleName $fixtureModuleName { throw 'Provider execution is forbidden in this fixture.' }
        & "$fixtureModuleName\Set-BootstrapDiagnosticsDirectory" -Path ''
    }

    AfterEach {
        Should -Invoke Invoke-BootstrapCommand -ModuleName $fixtureModuleName -Times 0 -Exactly
        & "$fixtureModuleName\Set-BootstrapDiagnosticsDirectory" -Path ''
    }

    It 'recognizes the Azure MFA denial without retaining resource names or provider prose' {
        $signature = & "$fixtureModuleName\Get-BootstrapProviderFailureSignature" -Output $mfaFailure
        $signature.codes.Count | Should -Be 1
        $signature.codes[0] | Should -BeExactly 'AzureMfaRequired'
        ($signature | ConvertTo-Json -Depth 4) | Should -Not -Match 'fixture-resource|User accounts|https:'
    }

    It 'does not classify an unrelated error or a bare help link as an MFA denial' -ForEach @(
        'ERROR: NotSpecified - Something else failed.',
        'Visit https://aka.ms/MFAforAzure for general account guidance.',
        'A fixture mentions without authenticating through MFA but has no recognized help link.'
    ) {
        $signature = & "$fixtureModuleName\Get-BootstrapProviderFailureSignature" -Output $_
        $signature.codes | Should -Not -Contain 'AzureMfaRequired'
    }

    It 'preserves bounded structured codes and correlations with an MFA denial' {
        $output = $mfaFailure + "`n" + '{"code":"ResourceDisallowedByPolicy","correlationId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","access_token":"fixture-sensitive-token"}'
        $signature = & "$fixtureModuleName\Get-BootstrapProviderFailureSignature" -Output $output
        $signature.codes | Should -Contain 'AzureMfaRequired'
        $signature.codes | Should -Contain 'ResourceDisallowedByPolicy'
        $signature.correlationIds | Should -Contain 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
        ($signature | ConvertTo-Json -Depth 4) | Should -Not -Match 'fixture-sensitive-token|access_token'
    }

    It 'persists only the bounded signature and projects actionable MFA guidance' {
        & "$fixtureModuleName\Set-BootstrapDiagnosticsDirectory" -Path (Join-Path $TestDrive 'diagnostics')
        $failure = & "$fixtureModuleName\New-BootstrapProviderFailureException" -CommandName az -ExitCode 1 -Output $mfaFailure
        $event = Project-FixtureFailure -Failure $failure
        $event.data.failureCode | Should -BeExactly 'plan_what_if'
        $event.data.category | Should -BeExactly 'planFailure'
        $event.data.resumable | Should -BeFalse
        $event.message | Should -Match 'multifactor authentication'
        $event.message | Should -Match 'configured tenant'
        $event.message | Should -Match 'Resume'
        $record = [IO.File]::ReadAllText($failure.Data['GatewayProviderDiagnosticPath'])
        $record | Should -Match 'AzureMfaRequired'
        $record | Should -Not -Match 'fixture-resource|You are receiving|User accounts'
    }

    It 'retains the normal curated What-If failure for unrelated provider errors' {
        $failure = & "$fixtureModuleName\New-BootstrapProviderFailureException" -CommandName az -ExitCode 1 -Output '{"code":"AuthorizationFailed"}'
        $event = Project-FixtureFailure -Failure $failure
        $event.message | Should -Match 'What-If could not produce a reviewable result'
        $event.message | Should -Not -Match 'multifactor authentication'
        $event.data.providerErrorCodes | Should -Contain 'AuthorizationFailed'
    }
}
