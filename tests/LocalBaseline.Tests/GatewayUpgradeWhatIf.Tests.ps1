BeforeAll {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'operations\GatewayUpgradeExecution.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'The actual maintenance deployment adapter must parse.' }
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Invoke-GatewayUpgradeArmDeployment'
    }, $false)
    if ($null -eq $definition) { throw 'The actual maintenance What-If consumer is missing.' }
    $hashAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'operations\GatewayUpgrade.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'The actual canonical fingerprint helpers must parse.' }
    $hashDefinitions = foreach ($name in @(
        'ConvertTo-GatewayUpgradeCanonical', 'ConvertTo-GatewayUpgradeCanonicalJson', 'Get-GatewayUpgradeFingerprint'
    )) {
        $helper = $hashAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $false)
        if ($null -eq $helper) { throw "The actual fingerprint helper is missing: $name" }
        $helper.Extent.Text
    }
    $fixture = New-Module -Name "UpgradeWhatIfFixture_$([guid]::NewGuid().ToString('N'))" `
        -ArgumentList $definition.Extent.Text, ($hashDefinitions -join "`n") -ScriptBlock {
        param($definition, $hashDefinitions)
        Set-StrictMode -Version Latest
        . ([scriptblock]::Create($definition))
        . ([scriptblock]::Create($hashDefinitions))
        $script:Changes = @()
        $script:Accepted = $false
        function Get-GatewayUpgradeFileHash {
            param($Path)
            return 'sha256:' + (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant()
        }
        function Invoke-BootstrapCommand {
            param($FilePath, $ArgumentList)
            if ($FilePath -cne 'az' -or ($ArgumentList[0..1] -join ' ') -cne 'bicep build') {
                throw 'Unscripted native or provider command is forbidden.'
            }
            return '{}'
        }
        function Invoke-GatewayUpgradeArm {
            param($Context, $Method, $Id, $Version, $Body, [switch]$AllowNotFound)
            if ($Method -cne 'POST' -or -not $Id.EndsWith('/whatIf', [StringComparison]::Ordinal) -or
                $Version -cne '2025-04-01' -or $Body.properties.mode -cne 'Incremental') {
                throw 'Unscripted provider access or any mutation is forbidden.'
            }
            return @{ status = 'Succeeded'; properties = @{ changes = $script:Changes } }
        }
        function Invoke-GatewayUpgradeOnce {
            param($Context, $Action, $InputBinding, [switch]$ReadOnly,
                [scriptblock]$Discover, [scriptblock]$Preflight, [scriptblock]$Mutate)
            & $Preflight
            $script:Accepted = $true
            return 'PreflightAcceptedWithoutMutation'
        }
        Export-ModuleMember -Function Invoke-GatewayUpgradeArmDeployment
    }
    $fixture | Import-Module -NoClobber -DisableNameChecking
    $invoke = $fixture.ExportedCommands['Invoke-GatewayUpgradeArmDeployment']
    $scope = '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-fixture'
    $jobId = "$scope/providers/Microsoft.App/jobs/fixture-publisher"
    $unrelatedId = "$scope/providers/microsoft.alertsManagement/smartDetectorAlertRules/Failure Anomalies - fixture"
    $template = 'infrastructure\bicep\maintenance-purview-publisher.bicep'
    [IO.Directory]::CreateDirectory((Join-Path $TestDrive 'infrastructure\bicep')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $TestDrive $template), 'targetScope = ''resourceGroup''')
    $executorTemplate = 'infrastructure\bicep\maintenance-source-only-executor.bicep'
    [IO.File]::WriteAllText((Join-Path $TestDrive $executorTemplate), 'targetScope = ''resourceGroup''')
}

AfterAll {
    if ($fixture) { Remove-Module -ModuleInfo $fixture -Force }
}

Describe 'Maintenance What-If distinguishes untouched resources from approved writes' {
    BeforeEach {
        $context = @{
            sourceRoot = $TestDrive; planFingerprint = 'sha256:' + ('1' * 64)
            plan = @{ scope = @{ resourceGroupId = $scope } }
        }
        & $fixture { $script:Changes = @(); $script:Accepted = $false }
    }

    It 'accepts the approved create while Azure reports unrelated in-scope Ignore entries: <_>' -ForEach @(
        'original case', 'alternate ARM case', 'empty optional payloads', 'null optional payloads', 'identical resource projections'
    ) {
        $ignored = @{ resourceId = $unrelatedId; changeType = 'Ignore' }
        if ($_ -ceq 'alternate ARM case') { $ignored.resourceId = $unrelatedId.ToUpperInvariant() }
        if ($_ -ceq 'empty optional payloads') {
            $ignored.after = $null
            $ignored.delta = @()
            $ignored.before = @{ name = 'existing fixture' }
        }
        if ($_ -ceq 'null optional payloads') {
            $ignored.after = $null
            $ignored.delta = $null
        }
        if ($_ -ceq 'identical resource projections') {
            $ignored.before = @{ id = $unrelatedId; properties = @{ enabled = $true; recipients = @('synthetic') } }
            $ignored.after = @{ properties = @{ recipients = @('synthetic'); enabled = $true }; id = $unrelatedId }
            $ignored.delta = @()
        }
        & $fixture { param($changes) $script:Changes = $changes } @(
            @{ resourceId = $jobId; changeType = 'Create' }, $ignored)
        & $invoke $context 'publisher-job' $template @{} @($jobId) -Readback { throw 'Readback is not part of this preflight.' } |
            Should -BeExactly 'PreflightAcceptedWithoutMutation'
        & $fixture { $script:Accepted } | Should -BeTrue
    }

    It 'rejects an unrelated resource that is not genuinely untouched: <_>' -ForEach @(
        'Create', 'Modify', 'Delete', 'Deploy', 'Unsupported', 'Ignore with delta', 'Ignore with after',
        'Ignore with changed projections', 'Ignore with scalar projections'
    ) {
        $change = @{ resourceId = $unrelatedId; changeType = $_ }
        if ($_ -ceq 'Ignore with delta') {
            $change.changeType = 'Ignore'
            $change.delta = @(@{ path = 'properties.enabled'; propertyChangeType = 'Modify' })
        }
        if ($_ -ceq 'Ignore with after') {
            $change.changeType = 'Ignore'
            $change.after = @{ properties = @{ enabled = $false } }
        }
        if ($_ -ceq 'Ignore with changed projections') {
            $change.changeType = 'Ignore'
            $change.before = @{ properties = @{ enabled = $true } }
            $change.after = @{ properties = @{ enabled = $false } }
        }
        if ($_ -ceq 'Ignore with scalar projections') {
            $change.changeType = 'Ignore'
            $change.before = 'not a resource projection'
            $change.after = 'not a resource projection'
        }
        & $fixture { param($changes) $script:Changes = $changes } @($change)
        { & $invoke $context 'publisher-job' $template @{} @($jobId) -Readback {} } |
            Should -Throw '*What-If*'
        & $fixture { $script:Accepted } | Should -BeFalse
    }

    It 'rejects ignored resources outside the exact group or with no resource identity: <_>' -ForEach @(
        'other subscription', 'other group', 'group prefix collision', 'group itself', 'empty', 'null'
    ) {
        $id = switch ($_) {
            'other subscription' { $unrelatedId.Replace('22222222-2222-4222-8222-222222222222', '33333333-3333-4333-8333-333333333333') }
            'other group' { $unrelatedId.Replace('/rg-fixture/', '/rg-elsewhere/') }
            'group prefix collision' { $unrelatedId.Replace('/rg-fixture/', '/rg-fixture-sibling/') }
            'group itself' { $scope }
            'empty' { '' }
            'null' { $null }
        }
        & $fixture { param($changes) $script:Changes = $changes } @(@{ resourceId = $id; changeType = 'Ignore' })
        { & $invoke $context 'publisher-job' $template @{} @($jobId) -Readback {} } |
            Should -Throw
        & $fixture { $script:Accepted } | Should -BeFalse
    }

    It 'rejects malformed change types before the Ignore exception: <Label>' -ForEach @(
        @{ Label = 'true'; Value = $true },
        @{ Label = 'false'; Value = $false },
        @{ Label = 'number'; Value = 1 },
        @{ Label = 'array containing Ignore and Delete'; Value = @('Ignore', 'Delete') },
        @{ Label = 'single-element array'; Value = @('Ignore') },
        @{ Label = 'null'; Value = $null }
    ) {
        & $fixture { param($changes) $script:Changes = $changes } @(
            @{ resourceId = $unrelatedId; changeType = $Value })
        { & $invoke $context 'publisher-job' $template @{} @($jobId) -Readback {} } |
            Should -Throw '*malformed resource change*'
        & $fixture { $script:Accepted } | Should -BeFalse
    }

    It 'rejects a missing change type with an explicit contract error' {
        & $fixture { param($changes) $script:Changes = $changes } @(@{ resourceId = $unrelatedId })
        { & $invoke $context 'publisher-job' $template @{} @($jobId) -Readback {} } |
            Should -Throw '*malformed resource change*'
        & $fixture { $script:Accepted } | Should -BeFalse
    }

    It 'preserves denial of unapproved Modify and Delete on an allowed resource: <_>' -ForEach @('Modify', 'Delete') {
        & $fixture { param($changes) $script:Changes = $changes } @(@{ resourceId = $jobId; changeType = $_ })
        { & $invoke $context 'publisher-job' $template @{} @($jobId) -Readback {} } |
            Should -Throw '*What-If*'
    }

    It 'accepts the exact separately permitted modification and no unrelated writes' {
        & $fixture { param($changes) $script:Changes = $changes } @(
            @{ resourceId = $jobId.ToUpperInvariant(); changeType = 'Modify' },
            @{ resourceId = $unrelatedId; changeType = 'Ignore' })
        & $invoke $context 'publisher-job' $template @{} @($jobId) -AllowedModifyResourceIds @($jobId) -Readback {} |
            Should -BeExactly 'PreflightAcceptedWithoutMutation'
    }

    It 'still refuses to recreate installed executor app settings' {
        $settingsId = "$scope/providers/Microsoft.Web/sites/fixture/config/appsettings"
        & $fixture { param($changes) $script:Changes = $changes } @(@{ resourceId = $settingsId; changeType = 'Create' })
        { & $invoke $context 'executor-source-cutover' $executorTemplate @{} @($settingsId) `
            -AllowedModifyResourceIds @($settingsId) -Readback {} } |
            Should -Throw '*cannot recreate*'
    }
}
