#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap\modules\Common.psm1') -DisableNameChecking

function Assert-GatewayUpgradeOperatorBinding {
    param($Operator, [string]$TenantId)
    $keys = @('tenantId', 'objectId', 'userType', 'automationOwnerObjectId')
    if ($Operator -isnot [Collections.IDictionary] -or $Operator.Count -ne $keys.Count -or
        @($Operator.Keys | Where-Object { $_ -cnotin $keys }).Count -ne 0 -or
        $Operator.tenantId -cne $TenantId -or $Operator.userType -cne 'Member' -or
        [string]$Operator.objectId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
        $Operator.objectId -ceq '00000000-0000-0000-0000-000000000000' -or
        $Operator.automationOwnerObjectId -cne $Operator.objectId) {
        throw 'UpgradeAuthorizationRequired: exact reviewed Member operator and automation owner binding is missing or invalid.'
    }
}

function Read-GatewayUpgradeOperatorProjection {
    param([string[]]$Arguments, [string[]]$Keys)
    $raw = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList ($Arguments + @('--output', 'json', '--only-show-errors'))
    if ($raw -isnot [string] -or $raw.Length -gt 2048) { throw 'UpgradeAuthenticationRequired: operator projection is missing or oversized.' }
    $document = [Text.Json.JsonDocument]::Parse($raw)
    try {
        $value = & (Get-Module GatewayUpgrade) { param($element) ConvertFrom-GatewayUpgradeJsonElement $element } $document.RootElement
    }
    finally { $document.Dispose() }
    if ($value -isnot [Collections.IDictionary] -or $value.Count -ne $Keys.Count -or
        @($value.Keys | Where-Object { $_ -cnotin $Keys }).Count -ne 0) {
        throw 'UpgradeAuthenticationRequired: operator projection shape differs.'
    }
    return $value
}

function Get-GatewayUpgradeAuthenticatedOperator {
    param([string]$TenantId, [string]$SubscriptionId)
    # Direct native reads avoid reusing a cached Graph token after an external CLI account change.
    # Neither command logs in nor changes the selected Azure account.
    $account = Read-GatewayUpgradeOperatorProjection @('account', 'show', '--subscription', $SubscriptionId,
        '--query', '{id:id,tenantId:tenantId,userType:user.type}') @('id', 'tenantId', 'userType')
    if ($account.id -cne $SubscriptionId -or $account.tenantId -cne $TenantId -or $account.userType -cne 'user') {
        throw 'UpgradeAuthenticationRequired: the reviewed tenant/subscription user account is not authenticated.'
    }
    $me = Read-GatewayUpgradeOperatorProjection @('rest', '--method', 'GET', '--subscription', $SubscriptionId,
        '--url', 'https://graph.microsoft.com/v1.0/me?$select=id,userType',
        '--query', '{id:id,userType:userType}') @('id', 'userType')
    $operator = @{ tenantId = $TenantId; objectId = $me.id; userType = $me.userType; automationOwnerObjectId = $me.id }
    Assert-GatewayUpgradeOperatorBinding $operator $TenantId
    return $operator
}

function Assert-GatewayUpgradeCurrentOperator {
    param($Plan)
    Assert-GatewayUpgradeOperatorBinding $Plan.authorizedOperator $Plan.request.target.tenantId
    $current = Get-GatewayUpgradeAuthenticatedOperator $Plan.request.target.tenantId $Plan.request.target.subscriptionId
    if ((Get-GatewayUpgradeFingerprint $current) -cne (Get-GatewayUpgradeFingerprint $Plan.authorizedOperator)) {
        throw 'UpgradeAuthorizationRequired: authenticated operator differs from the exact approved Plan owner.'
    }
    return $current
}

Export-ModuleMember -Function Get-GatewayUpgradeAuthenticatedOperator, Assert-GatewayUpgradeOperatorBinding, Assert-GatewayUpgradeCurrentOperator
