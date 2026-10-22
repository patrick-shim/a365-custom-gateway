#Requires -Version 7.0
<#
.SYNOPSIS
Previews or creates a new Purview Application policy for one individual Entra agent.
.DESCRIPTION
Copy this file to any Windows PC with PowerShell 7. Requires ExchangeOnlineManagement
and (except for SIT listing) Microsoft.Graph.Authentication. No Gateway files are used.
Default execution reads and previews only. -Apply creates new objects; existing names
are never adopted. Unknown mutation outcomes require manual reconciliation.
.LINK
https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-dlpcompliancerule
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Create')]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$UserPrincipalName,
    [Parameter(Mandatory, ParameterSetName = 'List')][switch]$ListSensitiveInformationTypes,
    [Parameter(Mandatory, ParameterSetName = 'Create')][guid]$AgentApplicationId,
    [Parameter(Mandatory, ParameterSetName = 'Create')][guid]$BlueprintApplicationId,
    [Parameter(Mandatory, ParameterSetName = 'Create')][ValidateNotNullOrEmpty()][string]$PolicyName,
    [Parameter(Mandatory, ParameterSetName = 'Create')][ValidateNotNullOrEmpty()][string]$RuleName,
    [Parameter(Mandatory, ParameterSetName = 'Create')]
    [ValidateCount(1, 50)][string[]]$SensitiveInformationType,
    [Parameter(ParameterSetName = 'Create')][ValidateRange(1, 1000)][int]$MinimumCount = 1,
    [Parameter(ParameterSetName = 'Create')][ValidateRange(1, 100)][int]$MinimumConfidence = 85,
    [Parameter(ParameterSetName = 'Create')]
    [ValidateSet('Enable', 'Disable', 'TestWithoutNotifications')][string]$Mode = 'Enable',
    [Parameter(ParameterSetName = 'Create')][switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Read-Field($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Assert-Text([string]$Value, [int]$Maximum = 256) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $Maximum -or
        $Value -cne $Value.Trim() -or $Value -match '[\x00-\x1f\x7f]') {
        throw 'Invalid text value.'
    }
}

function Read-Guid($Value) {
    $id = [guid]::Empty
    if (-not [guid]::TryParse([string]$Value, [ref]$id) -or $id -eq [guid]::Empty) {
        throw 'A nonempty GUID is required.'
    }
    return $id.ToString('D')
}

function Assert-Connections {
    $connections = @(Get-ConnectionInformation -ErrorAction Stop)
    if ($connections.Count -ne 1 -or
        [string]$connections[0].ConnectionId -ne $script:ownedConnectionId -or
        $connections[0].IsEopSession -ne $true -or
        [string]$connections[0].State -ne 'Connected' -or
        [string]$connections[0].TokenStatus -ne 'Active' -or
        [string]$connections[0].TenantID -ne $TenantId.ToString('D') -or
        [string]$connections[0].UserPrincipalName -ne $UserPrincipalName) {
        throw 'Purview session does not match the selected tenant and account.'
    }
    if (-not $ListSensitiveInformationTypes) {
        $context = Get-MgContext -ErrorAction Stop
        if ($null -eq $context -or [string]$context.TenantId -ne $TenantId.ToString('D') -or
            [string]$context.Account -ne $UserPrincipalName -or [string]$context.AuthType -ne 'Delegated') {
            throw 'Graph session does not match the selected tenant and account.'
        }
    }
}

function Read-IndividualAgent {
    $uri = "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$AgentApplicationId')?`$select=id,appId"
    $principal = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
    if ((Read-Guid (Read-Field $principal 'appId')) -ne $AgentApplicationId.ToString('D')) {
        throw 'Application identity mismatch.'
    }
    $objectId = Read-Guid (Read-Field $principal 'id')
    $uri = "https://graph.microsoft.com/v1.0/servicePrincipals/$objectId/microsoft.graph.agentIdentity" +
        '?$select=id,appId,displayName,agentIdentityBlueprintId'
    $agent = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
    if ((Read-Guid (Read-Field $agent 'id')) -ne $objectId -or
        (Read-Guid (Read-Field $agent 'appId')) -ne $AgentApplicationId.ToString('D') -or
        (Read-Guid (Read-Field $agent 'agentIdentityBlueprintId')) -ne $BlueprintApplicationId.ToString('D') -or
        [string](Read-Field $agent '@odata.type') -ne '#microsoft.graph.agentIdentity') {
        throw 'Individual agent or blueprint relationship mismatch.'
    }
    Assert-Text ([string](Read-Field $agent 'displayName'))
    return $agent
}

function Assert-NewNames {
    # Failed inventory is never interpreted as absence. Exact names are compared locally.
    $policies = @(Get-DlpCompliancePolicy -ErrorAction Stop)
    $rules = @(Get-DlpComplianceRule -ErrorAction Stop)
    if (@($policies | Where-Object { [string](Read-Field $_ 'Name') -eq $PolicyName }).Count -gt 0 -or
        @($rules | Where-Object { [string](Read-Field $_ 'Name') -eq $RuleName }).Count -gt 0) {
        throw 'Existing policy or rule name; reconcile instead of replacing it.'
    }
}

function Read-VerifiedPolicy([string]$Identity, [string]$ExpectedMode) {
    $items = @(Get-DlpCompliancePolicy -Identity $Identity -ErrorAction Stop)
    if ($items.Count -ne 1) { throw 'Ambiguous policy readback.' }
    $policy = $items[0]
    if ((Read-Guid (Read-Field $policy 'Guid')) -ne $Identity -or
        [string](Read-Field $policy 'Name') -cne $PolicyName -or
        [string](Read-Field $policy 'Comment') -cne $script:ownershipComment -or
        [string](Read-Field $policy 'Mode') -ne $ExpectedMode) {
        throw 'Policy ownership or mode readback mismatch.'
    }
    $planes = @(Read-Field $policy 'EnforcementPlanes')
    $locations = @(ConvertFrom-Json -InputObject ([string](Read-Field $policy 'Locations')) -Depth 30)
    if ($planes.Count -ne 1 -or [string]$planes[0] -ne 'Application' -or $locations.Count -ne 1) {
        throw 'Policy plane or scope readback mismatch.'
    }
    $location = $locations[0]
    $inclusions = @(Read-Field $location 'Inclusions')
    $exclusions = @(Read-Field $location 'Exclusions' | Where-Object { $null -ne $_ })
    if ([string](Read-Field $location 'Workload') -ne 'Applications' -or
        [string](Read-Field $location 'LocationSource') -ne 'Entra' -or
        [string](Read-Field $location 'LocationType') -ne 'Individual' -or
        (Read-Guid (Read-Field $location 'Location')) -ne $AgentApplicationId.ToString('D') -or
        $exclusions.Count -ne 0 -or $inclusions.Count -ne 1 -or
        [string](Read-Field $inclusions[0] 'Type') -ne 'Tenant' -or
        [string](Read-Field $inclusions[0] 'Identity') -ne 'All') {
        throw 'Individual policy target readback mismatch.'
    }
    return $policy
}

function Assert-RuleReadback([string]$PolicyId, [string]$RuleId, [object[]]$SelectedTypes) {
    $items = @(Get-DlpComplianceRule -Policy $PolicyId -ErrorAction Stop)
    if ($items.Count -ne 1) { throw 'Unexpected policy rules.' }
    $rule = $items[0]
    if ((Read-Guid (Read-Field $rule 'Guid')) -ne $RuleId -or
        [string](Read-Field $rule 'Name') -cne $RuleName -or
        (Read-Field $rule 'Disabled') -ne $false -or
        [string](Read-Field $rule 'Comment') -cne $script:ownershipComment) {
        throw 'Rule identity or enabled state readback mismatch.'
    }
    $actions = @(Read-Field $rule 'RestrictAccess')
    if ($actions.Count -ne 2) { throw 'Unexpected rule actions.' }
    foreach ($setting in @('UploadText', 'DownloadText')) {
        if (@($actions | Where-Object {
            [string](Read-Field $_ 'Setting') -eq $setting -and [string](Read-Field $_ 'Value') -eq 'Block'
        }).Count -ne 1) { throw 'Rule blocking action readback mismatch.' }
    }
    $types = @(Read-Field $rule 'ContentContainsSensitiveInformation')
    # SCC can return the flat SIT list or normalize it into a single OR group.
    if ($types.Count -eq 1 -and $null -ne (Read-Field $types[0] 'groups')) {
        $outerOperator = [string](Read-Field $types[0] 'operator')
        $groups = @(Read-Field $types[0] 'groups')
        if ($outerOperator -notin @('', 'And', 'Or') -or $groups.Count -ne 1 -or
            [string](Read-Field $groups[0] 'operator') -ne 'Or' -or
            @(Read-Field $groups[0] 'labels' | Where-Object { $null -ne $_ }).Count -ne 0) {
            throw 'Unexpected SIT condition grouping.'
        }
        $types = @(Read-Field $groups[0] 'sensitivetypes')
    }
    if ($types.Count -ne $SelectedTypes.Count) { throw 'Unexpected SIT conditions.' }
    foreach ($selected in $SelectedTypes) {
        $matches = @($types | Where-Object {
            $readId = [string](Read-Field $_ 'Id')
            $readName = [string](Read-Field $_ 'Name')
            if (-not [string]::IsNullOrWhiteSpace($readId)) { $readId -eq $selected.Id }
            else { $readName -eq $selected.Id -or ($selected.UniqueName -and $readName -ceq $selected.Name) }
        })
        if ($matches.Count -ne 1 -or
            [int](Read-Field $matches[0] 'minCount') -ne $MinimumCount -or
            [int](Read-Field $matches[0] 'minConfidence') -ne $MinimumConfidence) {
            throw 'SIT or threshold readback mismatch.'
        }
    }
}

$script:ownedConnectionId = ''
$script:ownershipComment = 'Standalone agent DLP authoring operation ' + [guid]::NewGuid().ToString('D')
$graphConnectStarted = $false
$purviewConnectStarted = $false
$mutationStarted = $false
$stage = 'input validation'
$guidance = 'Use nonempty GUIDs and nonempty names without leading/trailing spaces or control characters.'
try {
    if (-not $IsWindows) { throw 'Windows is required for this utility.' }
    $null = Read-Guid $TenantId
    Assert-Text $UserPrincipalName
    if (-not $ListSensitiveInformationTypes) {
        $null = Read-Guid $AgentApplicationId
        $null = Read-Guid $BlueprintApplicationId
        if ($AgentApplicationId -eq $BlueprintApplicationId) { throw 'A blueprint cannot be a target.' }
        Assert-Text $PolicyName 64
        Assert-Text $RuleName 64
        foreach ($value in $SensitiveInformationType) { Assert-Text $value }
    }

    $stage = 'module and session checks'
    $guidance = 'Install the documented modules and run in a fresh PowerShell 7 process with no existing connections.'
    Import-Module ExchangeOnlineManagement -MinimumVersion 3.2.0 -ErrorAction Stop
    if (@(Get-ConnectionInformation -ErrorAction Stop).Count -ne 0) { throw 'Existing session.' }
    if (-not $ListSensitiveInformationTypes) {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        if ($null -ne (Get-MgContext -ErrorAction Stop)) { throw 'Existing Graph session.' }
        $stage = 'Graph sign-in'
        $guidance = 'Sign in to the selected tenant/account with Application.Read.All consent and agent read permission.'
        $graphConnectStarted = $true
        Connect-MgGraph -TenantId $TenantId -Scopes 'Application.Read.All' -ContextScope Process -NoWelcome -ErrorAction Stop | Out-Null
    }

    $stage = 'Purview sign-in and tenant validation'
    $guidance = 'Use the same selected tenant/account in both sign-ins and verify Security & Compliance permissions.'
    $purviewConnectStarted = $true
    Connect-IPPSSession -UserPrincipalName $UserPrincipalName `
        -AzureADAuthorizationEndpointUri "https://login.microsoftonline.com/$TenantId" `
        -ShowBanner:$false -ErrorAction Stop | Out-Null
    $connections = @(Get-ConnectionInformation -ErrorAction Stop)
    if ($connections.Count -ne 1) { throw 'Ambiguous connection.' }
    $script:ownedConnectionId = Read-Guid $connections[0].ConnectionId
    Assert-Connections

    $stage = 'SIT inventory'
    $guidance = 'Verify SIT read permission and that the SITs are published in this tenant.'
    $inventory = @(Get-DlpSensitiveInformationType -ErrorAction Stop)
    $types = @(foreach ($item in $inventory) {
        $name = [string](Read-Field $item 'Name')
        Assert-Text $name
        [pscustomobject]@{ Id = Read-Guid (Read-Field $item 'Id'); Name = $name }
    })
    if ($ListSensitiveInformationTypes) { $types | Sort-Object Name; return }

    $stage = 'individual agent validation'
    $guidance = 'Use the individual agent Application ID and its exact Blueprint Application ID; verify agent read permission.'
    $agent = Read-IndividualAgent
    $stage = 'SIT selection'
    $guidance = 'Select existing SIT GUIDs or exact names. Missing, ambiguous, or duplicate selections are rejected.'
    $selectedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $selectedTypes = @(foreach ($value in $SensitiveInformationType) {
        $id = [guid]::Empty
        $isGuid = [guid]::TryParse($value, [ref]$id)
        $matches = @($types | Where-Object {
            if ($isGuid) { $_.Id -eq $id.ToString('D') } else { $_.Name -ceq $value }
        })
        if ($matches.Count -ne 1 -or -not $selectedIds.Add($matches[0].Id)) { throw 'Invalid SIT selection.' }
        [pscustomobject]@{
            Id = $matches[0].Id; Name = $matches[0].Name
            UniqueName = @($types | Where-Object { $_.Name -ceq $matches[0].Name }).Count -eq 1
        }
    })
    $stage = 'new policy and rule name checks'
    $guidance = 'Reconcile any existing policy/rule with these names. This script never overwrites or resumes an existing object.'
    Assert-NewNames

    $locations = @(@{
        Workload = 'Applications'; Location = $AgentApplicationId.ToString('D')
        LocationDisplayName = [string](Read-Field $agent 'displayName')
        LocationSource = 'Entra'; LocationType = 'Individual'
        Inclusions = @(@{ Type = 'Tenant'; Identity = 'All' })
    })
    # -InputObject preserves the JSON array even when there is only one application.
    $locationsJson = ConvertTo-Json -InputObject $locations -Depth 8 -Compress
    $conditions = @(foreach ($selected in $selectedTypes) {
        @{ Name = $selected.Id; minCount = $MinimumCount; minConfidence = $MinimumConfidence }
    })
    $plan = [ordered]@{
        Status = 'Preview'; TenantId = $TenantId.ToString('D')
        AgentApplicationId = $AgentApplicationId.ToString('D')
        AgentName = [string](Read-Field $agent 'displayName')
        BlueprintApplicationId = $BlueprintApplicationId.ToString('D')
        PolicyName = $PolicyName; RuleName = $RuleName; Mode = $Mode
        EnforcementPlane = 'Application'; Locations = $locations
        SensitiveInformationTypes = @($selectedTypes | Select-Object Id,Name)
        MinimumCount = $MinimumCount; MinimumConfidence = $MinimumConfidence
        Actions = @('UploadText: Block', 'DownloadText: Block')
        Enforcement = 'NotVerified'
    }
    if (-not $Apply -or -not $PSCmdlet.ShouldProcess(
        "Tenant $TenantId, individual agent $AgentApplicationId",
        "Create policy '$PolicyName' and rule '$RuleName' in mode $Mode")) {
        [pscustomobject]$plan
        return
    }

    $stage = 'pre-apply tenant and identity revalidation'
    $guidance = 'Verify the selected tenant/account and individual agent relationship before applying again.'
    Assert-Connections
    $null = Read-IndividualAgent
    $stage = 'pre-apply name conflict check'
    $guidance = 'Reconcile any existing policy/rule with these names; existing objects are never overwritten.'
    Assert-NewNames
    $stage = 'create disabled policy'
    $guidance = 'Read back the policy/rule in Purview before any further change; no automatic retry or deletion is performed.'
    $mutationStarted = $true
    $created = @(New-DlpCompliancePolicy -Name $PolicyName -Comment $script:ownershipComment `
        -Locations $locationsJson -EnforcementPlanes @('Application') -Mode Disable -ErrorAction Stop)
    if ($created.Count -ne 1) { throw 'Policy creation result is ambiguous.' }
    $policyId = Read-Guid (Read-Field $created[0] 'Guid')
    $stage = 'read back disabled policy'
    $null = Read-VerifiedPolicy $policyId 'Disable'
    $stage = 'create SIT blocking rule'
    $createdRule = @(New-DlpComplianceRule -Name $RuleName -Policy $policyId `
        -Comment $script:ownershipComment -Disabled $false `
        -ContentContainsSensitiveInformation $conditions `
        -RestrictAccess @(@{ Setting = 'UploadText'; Value = 'Block' }, @{ Setting = 'DownloadText'; Value = 'Block' }) `
        -ErrorAction Stop)
    if ($createdRule.Count -ne 1) { throw 'Rule creation result is ambiguous.' }
    $ruleId = Read-Guid (Read-Field $createdRule[0] 'Guid')
    $stage = 'verify disabled policy and rule'
    $null = Read-VerifiedPolicy $policyId 'Disable'
    Assert-RuleReadback $policyId $ruleId $selectedTypes
    if ($Mode -ne 'Disable') {
        Assert-Connections
        $stage = 'set requested policy mode'
        Set-DlpCompliancePolicy -Identity $policyId -Mode $Mode -ErrorAction Stop | Out-Null
    }
    $stage = 'final configuration readback'
    $policy = Read-VerifiedPolicy $policyId $Mode
    Assert-RuleReadback $policyId $ruleId $selectedTypes
    $plan.Status = 'ConfigurationReadBack'
    $plan['PolicyId'] = $policyId
    $plan['RuleId'] = $ruleId
    $plan['DistributionStatus'] = [string](Read-Field $policy 'DistributionStatus')
    [pscustomobject]$plan
}
catch {
    $outcome = if ($mutationStarted) {
        "Outcome unconfirmed. Policy '$PolicyName'; rule '$RuleName'. "
    } else { 'No policy mutation was started. ' }
    # Never forward raw provider exception bodies, tokens, or user content.
    throw [InvalidOperationException]::new("Stopped at $stage. $outcome$guidance Reference: $script:ownershipComment")
}
finally {
    if ($purviewConnectStarted) {
        try {
            # No SCC/EXO connections existed before this invocation's sign-in.
            foreach ($connection in @(Get-ConnectionInformation -ErrorAction Stop)) {
                $id = Read-Guid (Read-Field $connection 'ConnectionId')
                Disconnect-ExchangeOnline -ConnectionId $id -Confirm:$false -ErrorAction Stop | Out-Null
            }
        } catch { Write-Warning 'Could not close the Purview session. Close this PowerShell process.' }
    }
    if ($graphConnectStarted) {
        try { Disconnect-MgGraph -ErrorAction Stop | Out-Null }
        catch { Write-Warning 'Could not close the Graph session. Close this PowerShell process.' }
    }
}
