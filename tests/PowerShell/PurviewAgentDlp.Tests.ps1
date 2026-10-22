#Requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot '../../tools/scripts/setup/New-PurviewAgentDlpPolicy.ps1'
$tenant = '00000000-0000-0000-0000-000000000001'
$agent = '00000000-0000-0000-0000-000000000002'
$blueprint = '00000000-0000-0000-0000-000000000003'
$sit = '00000000-0000-0000-0000-000000000004'
$objectId = '00000000-0000-0000-0000-000000000005'
$policyId = '00000000-0000-0000-0000-000000000006'
$ruleId = '00000000-0000-0000-0000-000000000007'
$connectionId = '00000000-0000-0000-0000-000000000008'
$otherId = '00000000-0000-0000-0000-000000000009'
$settings = @{
    TenantId = $tenant; UserPrincipalName = 'operator@example.invalid'
    AgentApplicationId = $agent; BlueprintApplicationId = $blueprint
    PolicyName = 'Synthetic agent policy'; RuleName = 'Synthetic agent rule'
    SensitiveInformationType = @($sit)
}

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Reset-State([string]$Scenario = '') {
    $global:PurviewDlpTestState = @{
        Scenario = $Scenario; Context = $null; Connection = $null
        Policy = $null; Rule = $null; Events = [Collections.Generic.List[string]]::new()
        ExpectedAgentId = $agent; ExpectedBlueprintId = $blueprint
        ExpectedConnectionId = $connectionId
        Agent = @{
            id = $objectId; appId = $agent; displayName = 'Synthetic individual agent'
            agentIdentityBlueprintId = $blueprint; '@odata.type' = '#microsoft.graph.agentIdentity'
        }
    }
}

# All provider and module entry points are replaced; these tests have no tenant I/O.
function Import-Module { [CmdletBinding()] param($Name, $MinimumVersion) }
function Get-MgContext { [CmdletBinding()] param() $global:PurviewDlpTestState.Context }
function Connect-MgGraph {
    [CmdletBinding()] param($TenantId, $Scopes, $ContextScope, [switch]$NoWelcome)
    Assert-True ($Scopes -eq 'Application.Read.All' -and $ContextScope -eq 'Process') 'Only process-scoped read permission is requested.'
    $global:PurviewDlpTestState.Context = [pscustomobject]@{
        TenantId = $(if ($global:PurviewDlpTestState.Scenario -eq 'WrongGraphTenant') { $otherId } else { $tenant })
        Account = 'operator@example.invalid'; AuthType = 'Delegated'
    }
}
function Disconnect-MgGraph {
    [CmdletBinding()] param()
    $global:PurviewDlpTestState.Context = $null
}
function Get-ConnectionInformation {
    [CmdletBinding()] param()
    if ($null -ne $global:PurviewDlpTestState.Connection) { $global:PurviewDlpTestState.Connection }
}
function Connect-IPPSSession {
    [CmdletBinding()] param($UserPrincipalName, $AzureADAuthorizationEndpointUri, $ShowBanner)
    Assert-True ($AzureADAuthorizationEndpointUri -eq "https://login.microsoftonline.com/$tenant") 'Login must bind the selected tenant.'
    $global:PurviewDlpTestState.Connection = [pscustomobject]@{
        ConnectionId = $connectionId; IsEopSession = $true; State = 'Connected'; TokenStatus = 'Active'
        TenantID = $(if ($global:PurviewDlpTestState.Scenario -eq 'WrongPurviewTenant') { $otherId } else { $tenant })
        UserPrincipalName = $UserPrincipalName
    }
}
function Disconnect-ExchangeOnline {
    [CmdletBinding()] param($ConnectionId, $Confirm)
    Assert-True ($ConnectionId -eq $global:PurviewDlpTestState.ExpectedConnectionId) 'Disconnect only the session created by this invocation.'
    $global:PurviewDlpTestState.Connection = $null
}
function Invoke-MgGraphRequest {
    [CmdletBinding()] param($Method, $Uri, $OutputType)
    Assert-True ($Method -eq 'GET' -and $OutputType -eq 'PSObject') 'Graph must be read-only.'
    if ($Uri -match '/microsoft.graph.agentIdentity') {
        Assert-True ($Uri.Contains("/servicePrincipals/$objectId/")) 'Typed lookup must use the resolved object ID.'
        return $global:PurviewDlpTestState.Agent
    }
    $expectedAppId = $global:PurviewDlpTestState.ExpectedAgentId
    Assert-True ($Uri.Contains("servicePrincipals(appId='$expectedAppId')")) 'Lookup must use the exact individual app ID.'
    return @{ id = $objectId; appId = $expectedAppId }
}
function Get-DlpSensitiveInformationType {
    [CmdletBinding()] param()
    if ($global:PurviewDlpTestState.Scenario -eq 'SitReadFailure') { throw 'synthetic-provider-secret' }
    [pscustomobject]@{ Id = $sit; Name = 'Synthetic SIT' }
    if ($global:PurviewDlpTestState.Scenario -in @('AmbiguousSit', 'AmbiguousReadbackName')) {
        [pscustomobject]@{ Id = $otherId; Name = 'Synthetic SIT' }
    }
}
function Get-DlpCompliancePolicy {
    [CmdletBinding()] param($Identity)
    if ($global:PurviewDlpTestState.Scenario -eq 'InventoryFailure') { throw 'synthetic-provider-secret' }
    if ($global:PurviewDlpTestState.Scenario -eq 'ExistingPolicy') {
        return [pscustomobject]@{ Name = 'SYNTHETIC AGENT POLICY'; Guid = $otherId }
    }
    if ($Identity -and $global:PurviewDlpTestState.Scenario -eq 'PolicyReadFailure') { throw 'synthetic-provider-secret' }
    $global:PurviewDlpTestState.Policy
}
function Get-DlpComplianceRule {
    [CmdletBinding()] param($Policy)
    if ($global:PurviewDlpTestState.Scenario -eq 'ExistingRule') {
        return [pscustomobject]@{ Name = 'Synthetic agent rule'; Guid = $otherId }
    }
    $global:PurviewDlpTestState.Rule
}
function New-DlpCompliancePolicy {
    [CmdletBinding()] param($Name, $Comment, $Locations, $EnforcementPlanes, $Mode)
    $global:PurviewDlpTestState.Events.Add('NewPolicy')
    Assert-True ($Mode -eq 'Disable') 'Policy must stay disabled until both objects are read back.'
    Assert-True ($Locations.StartsWith('[')) 'One target must still be a JSON array.'
    $parsed = @($Locations | ConvertFrom-Json)
    Assert-True ($parsed.Count -eq 1 -and $parsed[0].Location -eq $global:PurviewDlpTestState.ExpectedAgentId -and
        $parsed[0].Location -ne $global:PurviewDlpTestState.ExpectedBlueprintId -and
        $parsed[0].Inclusions[0].Identity -eq 'All') 'Only the individual agent is targeted.'
    $global:PurviewDlpTestState.Policy = [pscustomobject]@{
        Guid = $policyId; Name = $Name; Comment = $Comment; Locations = $Locations
        EnforcementPlanes = $EnforcementPlanes; Mode = $Mode; DistributionStatus = 'Pending'
    }
    if ($global:PurviewDlpTestState.Scenario -eq 'WideScope') {
        $parsed[0].Location = $blueprint
        $global:PurviewDlpTestState.Policy.Locations = ConvertTo-Json -InputObject $parsed -Depth 8
    }
    if ($global:PurviewDlpTestState.Scenario -eq 'PolicyTimeout') { throw 'synthetic-provider-secret' }
    $global:PurviewDlpTestState.Policy
}
function New-DlpComplianceRule {
    [CmdletBinding()] param($Name, $Policy, $Comment, $Disabled, $ContentContainsSensitiveInformation, $RestrictAccess)
    $global:PurviewDlpTestState.Events.Add('NewRule')
    Assert-True ($Policy -eq $policyId) 'Rule must bind the GUID returned by policy creation.'
    $conditions = $ContentContainsSensitiveInformation
    if ($global:PurviewDlpTestState.Scenario -eq 'NormalizedSit') {
        $conditions = @(@{ operator = 'And'; groups = @(@{ operator = 'Or'; sensitivetypes = $conditions }) })
    }
    if ($global:PurviewDlpTestState.Scenario -eq 'BadThreshold') { $conditions[0].minCount = 999 }
    if ($global:PurviewDlpTestState.Scenario -eq 'WrongReadbackSitId') {
        $conditions[0].Id = $otherId
        $conditions[0].Name = 'Synthetic SIT'
    }
    if ($global:PurviewDlpTestState.Scenario -eq 'AmbiguousReadbackName') { $conditions[0].Name = 'Synthetic SIT' }
    $global:PurviewDlpTestState.Rule = [pscustomobject]@{
        Guid = $ruleId; Name = $Name; Comment = $Comment; Disabled = $Disabled
        ContentContainsSensitiveInformation = $conditions; RestrictAccess = $RestrictAccess
    }
    if ($global:PurviewDlpTestState.Scenario -eq 'MissingResponseBlock') {
        $global:PurviewDlpTestState.Rule.RestrictAccess = @($RestrictAccess[0])
    }
    if ($global:PurviewDlpTestState.Scenario -eq 'RuleTimeout') { throw 'synthetic-provider-secret' }
    $global:PurviewDlpTestState.Rule
}
function Set-DlpCompliancePolicy {
    [CmdletBinding()] param($Identity, $Mode)
    $global:PurviewDlpTestState.Events.Add('SetMode')
    Assert-True ($Identity -eq $policyId -and $null -ne $global:PurviewDlpTestState.Rule) 'Only the new verified policy may change mode.'
    $global:PurviewDlpTestState.Policy.Mode = $Mode
    if ($global:PurviewDlpTestState.Scenario -eq 'ModeTimeout') { throw 'synthetic-provider-secret' }
    if ($global:PurviewDlpTestState.Scenario -eq 'FinalModeMismatch') { $global:PurviewDlpTestState.Policy.Mode = 'Disable' }
}

$passed = 0
try {
    Reset-State
    $result = & $target @settings
    Assert-True ($result.Status -eq 'Preview' -and $global:PurviewDlpTestState.Events.Count -eq 0) 'Default preview must never mutate.'
    $passed++
    Reset-State
    $result = & $target @settings -Apply -WhatIf
    Assert-True ($result.Status -eq 'Preview' -and $global:PurviewDlpTestState.Events.Count -eq 0) 'WhatIf must guard all mutations locally.'
    $passed++
    Reset-State
    $result = & $target -TenantId $tenant -UserPrincipalName 'operator@example.invalid' -ListSensitiveInformationTypes
    Assert-True ($result.Id -eq $sit -and $global:PurviewDlpTestState.Events.Count -eq 0) 'SIT listing is read-only.'
    $passed++
    foreach ($mode in @('Enable', 'Disable', 'TestWithoutNotifications')) {
        Reset-State
        $result = & $target @settings -Apply -Mode $mode
        $expected = if ($mode -eq 'Disable') { 'NewPolicy,NewRule' } else { 'NewPolicy,NewRule,SetMode' }
        Assert-True (($global:PurviewDlpTestState.Events -join ',') -eq $expected) 'Mutation order is incorrect.'
        Assert-True ($result.Status -eq 'ConfigurationReadBack' -and $result.Mode -eq $mode -and
            $result.Enforcement -eq 'NotVerified' -and $result.DistributionStatus -eq 'Pending') 'Readback must not claim enforcement or distribution.'
        Assert-True ($null -eq $global:PurviewDlpTestState.Connection -and $null -eq $global:PurviewDlpTestState.Context) 'Owned sessions must close.'
        $passed++
    }
    Reset-State 'NormalizedSit'
    $result = & $target @settings -Apply
    Assert-True ($result.Status -eq 'ConfigurationReadBack') 'A normalized OR group should verify.'
    $passed++

    Reset-State
    $namedSettings = $settings.Clone()
    $namedSettings.SensitiveInformationType = @('Synthetic SIT')
    $result = & $target @namedSettings -Apply
    Assert-True ($result.SensitiveInformationTypes[0].Id -eq $sit) 'Exact SIT name must resolve to its immutable ID.'
    $passed++
    Reset-State
    $global:PurviewDlpTestState.Connection = [pscustomobject]@{ ConnectionId = $otherId }
    $caught = $null
    try { & $target @settings -Apply | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught -and $global:PurviewDlpTestState.Events.Count -eq 0 -and
        $global:PurviewDlpTestState.Connection.ConnectionId -eq $otherId) 'Existing SCC sessions must be preserved and block creation.'
    $passed++
    Reset-State
    $global:PurviewDlpTestState.Context = [pscustomobject]@{ TenantId = $otherId }
    $caught = $null
    try { & $target @settings -Apply | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught -and $global:PurviewDlpTestState.Events.Count -eq 0 -and
        $global:PurviewDlpTestState.Context.TenantId -eq $otherId) 'Existing Graph sessions must be preserved and block creation.'
    $passed++

    $cases = @(
        @{ Scenario = 'WrongGraphTenant'; Expected = '' },
        @{ Scenario = 'WrongPurviewTenant'; Expected = '' },
        @{ Scenario = 'WrongBlueprint'; Expected = '' },
        @{ Scenario = 'BlueprintTarget'; Expected = '' },
        @{ Scenario = 'NonAgent'; Expected = '' },
        @{ Scenario = 'MissingSit'; Expected = '' },
        @{ Scenario = 'DuplicateSit'; Expected = '' },
        @{ Scenario = 'AmbiguousSit'; Expected = '' },
        @{ Scenario = 'SitReadFailure'; Expected = '' },
        @{ Scenario = 'ExistingPolicy'; Expected = '' },
        @{ Scenario = 'ExistingRule'; Expected = '' },
        @{ Scenario = 'InventoryFailure'; Expected = '' },
        @{ Scenario = 'PolicyTimeout'; Expected = 'NewPolicy' },
        @{ Scenario = 'PolicyReadFailure'; Expected = 'NewPolicy' },
        @{ Scenario = 'WideScope'; Expected = 'NewPolicy' },
        @{ Scenario = 'RuleTimeout'; Expected = 'NewPolicy,NewRule' },
        @{ Scenario = 'BadThreshold'; Expected = 'NewPolicy,NewRule' },
        @{ Scenario = 'MissingResponseBlock'; Expected = 'NewPolicy,NewRule' },
        @{ Scenario = 'WrongReadbackSitId'; Expected = 'NewPolicy,NewRule' },
        @{ Scenario = 'AmbiguousReadbackName'; Expected = 'NewPolicy,NewRule' },
        @{ Scenario = 'ModeTimeout'; Expected = 'NewPolicy,NewRule,SetMode' },
        @{ Scenario = 'FinalModeMismatch'; Expected = 'NewPolicy,NewRule,SetMode' }
    )
    foreach ($case in $cases) {
        Reset-State $case.Scenario
        $parameters = $settings.Clone()
        switch ($case.Scenario) {
            'WrongBlueprint' { $global:PurviewDlpTestState.Agent.agentIdentityBlueprintId = $otherId }
            'BlueprintTarget' { $parameters.AgentApplicationId = $blueprint }
            'NonAgent' { $global:PurviewDlpTestState.Agent['@odata.type'] = '#microsoft.graph.servicePrincipal' }
            'MissingSit' { $parameters.SensitiveInformationType = @('Missing synthetic SIT') }
            'DuplicateSit' { $parameters.SensitiveInformationType = @($sit, 'Synthetic SIT') }
            'AmbiguousSit' { $parameters.SensitiveInformationType = @('Synthetic SIT') }
        }
        $caught = $null
        try { & $target @parameters -Apply | Out-Null } catch { $caught = $_ }
        Assert-True ($null -ne $caught) "Scenario $($case.Scenario) must stop."
        Assert-True (($global:PurviewDlpTestState.Events -join ',') -eq $case.Expected) "Unexpected mutation or retry in $($case.Scenario)."
        Assert-True ($caught.Exception.Message -notmatch 'synthetic-provider-secret') 'Raw provider failures must be sanitized.'
        if ($case.Expected) {
            Assert-True ($caught.Exception.Message -match 'Outcome unconfirmed') 'Unknown outcomes must remain unconfirmed.'
        }
        Assert-True ($null -eq $global:PurviewDlpTestState.Context -and $null -eq $global:PurviewDlpTestState.Connection) 'Failure must close owned sessions.'
        $passed++
    }
    Write-Output "Passed $passed offline Purview authoring behavior checks. Live tenant creation and enforcement: skipped."
}
finally { Remove-Variable PurviewDlpTestState -Scope Global -ErrorAction SilentlyContinue }
