Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Microsoft product setup only: exact-tenant authentication and optional Content Safety.
# Azure-hosted gateway deployment, resource adoption and recovery are retired.

function Connect-BootstrapAzure {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [switch]$NonInteractive)
    Clear-BootstrapAzureSubscriptionContext
    $account = $null
    try { $account = Invoke-AzJson -Arguments @('account', 'show') } catch { }
    if (-not $account -or [string]$account.tenantId -ne [string]$Config.tenantId) {
        if ($NonInteractive) { throw 'Azure CLI is not signed in to the configured tenant.' }
        Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('login', '--tenant', [string]$Config.tenantId, '--allow-no-subscriptions') -NoCapture | Out-Null
    }
    Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('account', 'set', '--subscription', [string]$Config.subscriptionId) | Out-Null
    $account = Invoke-AzJson -Arguments @('account', 'show')
    if ([string]$account.tenantId -ne [string]$Config.tenantId -or [string]$account.id -ne [string]$Config.subscriptionId) {
        throw 'Azure CLI tenant/subscription selection does not match bootstrap configuration.'
    }
    Set-BootstrapAzureSubscriptionContext `
        -SubscriptionId ([string]$Config.subscriptionId) `
        -TenantId ([string]$Config.tenantId)
    $user = Invoke-AzJson -Arguments @(
        'rest', '--method', 'GET', '--url',
        'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName,displayName'
    )
    Assert-GuidValue -Value ([string]$user.id) -Label 'Signed-in user object ID'
    return [ordered]@{
        subscriptionId = [string]$account.id
        tenantId = [string]$account.tenantId
        userObjectId = [string]$user.id
        userPrincipalName = [string]$user.userPrincipalName
        userDisplayName = [string]$user.displayName
    }
}

function Test-GatewayArmObjectProperty {
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-GatewayArmObjectProperty {
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-GatewayArmObjectProperty -Object $Object -Name $Name)) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return ,$Object[$Name] }
    return ,$Object.PSObject.Properties[$Name].Value
}

function Get-GatewayConflictingFreeContentSafetyAccountId {
    <#
        .SYNOPSIS
        Names an existing subscription free-tier Content Safety account that would
        make the workload deployment fail ARM preflight.

        .DESCRIPTION
        Azure allows exactly one free account per Cognitive Services account type
        per subscription. When Prompt Shields is enabled on a free SKU and another
        free ContentSafety account already exists outside the target resource
        group, ARM rejects the whole template at preflight before any deployment
        record is created, so the operator sees a stopped step with no deployment
        to inspect. This read-only discovery names the conflict up front instead.

        Returns a conflict descriptor, or $null when the requested SKU is not free,
        Prompt Shields is disabled, or no conflict exists.

        A soft-deleted Cognitive Services account keeps its free-tier slot for the
        rest of its retention window and never appears in a resource listing, so
        deleting the resource group does not release the quota and every retry is
        rejected identically. Both the live accounts and the soft-deleted accounts
        are discovered here, because only the second listing explains why a fully
        cleaned subscription still reports CanNotCreateMultipleFreeAccounts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ResourceGroupName
    )

    if ($Config.promptShield.enabled -ne $true) { return $null }
    $skuName = [string]$Config.promptShield.skuName
    if ($skuName -cnotmatch '^F[0-9]$') { return $null }

    $accounts = @(Invoke-AzJson -Arguments @(
        'resource', 'list', '--resource-type', 'Microsoft.CognitiveServices/accounts',
        '--query', "[?kind=='ContentSafety'].{id:id,name:name,location:location,resourceGroup:resourceGroup,sku:sku.name}"
    ))
    foreach ($account in $accounts) {
        $accountSku = [string](Get-GatewayArmObjectProperty -Object $account -Name 'sku')
        if ($accountSku -cnotmatch '^F[0-9]$') { continue }
        $accountResourceGroup = [string](Get-GatewayArmObjectProperty -Object $account -Name 'resourceGroup')
        if ($accountResourceGroup.Equals($ResourceGroupName, [StringComparison]::OrdinalIgnoreCase)) { continue }
        return [ordered]@{
            id = [string](Get-GatewayArmObjectProperty -Object $account -Name 'id')
            state = 'Active'
            name = [string](Get-GatewayArmObjectProperty -Object $account -Name 'name')
            location = [string](Get-GatewayArmObjectProperty -Object $account -Name 'location')
            resourceGroupName = $accountResourceGroup
        }
    }

    # A soft-deleted account is absent from the resource listing above yet still
    # consumes the one free account this subscription is allowed. Never exempt one
    # by resource group: the workload always creates a freshly suffixed account
    # rather than recovering a deleted name, so a same-named group does not help.
    $deletedAccounts = @(Invoke-AzJson -Arguments @(
        'cognitiveservices', 'account', 'list-deleted',
        '--query', "[?kind=='ContentSafety'].{id:id,name:name,location:location,sku:sku.name}"
    ))
    foreach ($account in $deletedAccounts) {
        $accountSku = [string](Get-GatewayArmObjectProperty -Object $account -Name 'sku')
        if ($accountSku -cnotmatch '^F[0-9]$') { continue }
        $accountId = [string](Get-GatewayArmObjectProperty -Object $account -Name 'id')
        # A deleted account reports a null resource group, so the originating group
        # is read from the resource ID. Without it there is no purge command to
        # name, and an ID of any other shape is not a soft-deleted account at all.
        if ($accountId -cnotmatch '/resourceGroups/(?<group>[^/]+)/deletedAccounts/(?<account>[^/]+)$') { continue }
        return [ordered]@{
            id = $accountId
            state = 'SoftDeleted'
            name = [string]$Matches['account']
            location = [string](Get-GatewayArmObjectProperty -Object $account -Name 'location')
            resourceGroupName = [string]$Matches['group']
        }
    }
    return $null
}

function Assert-GatewayPromptShieldFreeTierCapacity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ResourceGroupName
    )

    $conflict = Get-GatewayConflictingFreeContentSafetyAccountId -Config $Config -ResourceGroupName $ResourceGroupName
    if ($null -eq $conflict) { return $true }
    $purgeCommand = (
        'az cognitiveservices account purge --location ' + [string]$conflict.location +
        ' --resource-group ' + [string]$conflict.resourceGroupName +
        ' --name ' + [string]$conflict.name
    )
    $cause = (
        "Prompt Shields requests the free '$([string]$Config.promptShield.skuName)' Content Safety SKU, but this " +
        "subscription already has a free ContentSafety account at '$([string]$conflict.id)'. Azure allows one free " +
        'account per account type per subscription, so ARM would reject the whole workload template at preflight and ' +
        'create no deployment record. '
    )
    $resolution = if ([string]$conflict.state -ceq 'SoftDeleted') {
        'That account is soft-deleted rather than gone. A soft-deleted Cognitive Services account keeps its free-tier ' +
        'slot for the rest of its retention window and is invisible to a resource listing, so deleting its resource ' +
        'group did not release the quota and every retry fails identically. Resolve it in exactly one of three ways, ' +
        "then rerun gateway plan: purge the account with '$purgeCommand', set promptShield.skuName to a paid SKU such as " +
        "'S0' in bootstrap/config.json, or set promptShield.enabled to false and configure Prompt Shields after base " +
        'verification.'
    }
    else {
        'Resolve it in exactly one of three ways, then rerun gateway plan: set promptShield.skuName to a paid SKU such as ' +
        "'S0' in bootstrap/config.json, set promptShield.enabled to false and configure Prompt Shields after base " +
        'verification, or delete the unused account named above from its own resource group and then release its ' +
        "free-tier slot with '$purgeCommand', because deleting alone leaves the account soft-deleted and still " +
        'holding the quota.'
    }
    throw ($cause + $resolution + ' No workload mutation was attempted.')
}

Export-ModuleMember -Function *
