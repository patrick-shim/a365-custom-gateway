[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Apply', 'Verify')][string]$Mode,
    [string]$ApprovalFingerprint = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root '.test-work\live-acceptance-20260912\exchange-permission-correction'
$python = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\python.exe'
$tenant = 'ff8b1e46-ff0f-4bc2-ab02-caf2b92da496'
$subscription = '6f6ae863-dcb7-456f-a7f0-d6f9887cfb76'
$applicationId = 'de95e881-cf7d-457f-b92d-6a733308d8f1'
$applicationObjectId = 'ddaa137d-e4ae-42b4-8c84-116a5187fea4'
$principalId = 'b4db4a4c-de15-4adf-9fdb-ad6ecac81558'
$exchangeId = 'b22f6ca3-891b-445f-854c-18088f85f026'
$exchangeAppId = '00000002-0000-0ff1-ce00-000000000000'
$exchangeRoleId = 'dc50a0fb-09a3-484d-be87-e023b12c6440'
$legacyId = '94455c77-f0e8-4dfb-80a0-61b82f40eb50'
$legacyAppId = '00000007-0000-0ff1-ce00-000000000000'
$legacyRoleId = '455e5cd2-84e8-4751-8344-5672145dfa17'
$ownership = '9b34fc6e-3ba5-4d2e-b40d-d706ba23833f'
$operatorId = '2db7287c-9462-404f-810e-17e57377618d'
$statePath = Join-Path $root ".test-work\fresh-full-0911g\.bootstrap\state\$subscription-rg-gw0911g-dev-dev.json"
$stateHash = '716269a7e668e85b67f8504b8fa1b8d3a6316676f3d8912cef8f7dc653c6a1ac'

function Hash-File([string]$Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Canonical($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $sorted = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) { $sorted[$key] = Canonical $Value[$key] }
        return $sorted
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { Canonical $_ }) }
    return $Value
}
function Fingerprint($Value) {
    'sha256:' + [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes((Canonical $Value | ConvertTo-Json -Depth 30 -Compress))))
}
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ((Fingerprint $Actual) -cne (Fingerprint $Expected)) { throw "ExchangePermissionCorrection:$Label" }
}
function Save-New([string]$Name, $Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 30))
    $stream = [IO.File]::Open((Join-Path $work $Name), 'CreateNew', 'Write', 'None')
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Assert-Intent([string]$Name, $Expected) {
    $path = Join-Path $work $Name
    if (-not (Test-Path $path)) { throw 'ExchangePermissionCorrection:UnownedTarget' }
    Assert-Equal (Get-Content $path -Raw | ConvertFrom-Json -AsHashtable -Depth 30 -DateKind String) $Expected 'IntentChanged'
}
function Run-Az([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($python)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    foreach ($argument in @('-X', 'utf8', '-IBm', 'azure.cli') + $Arguments + @('--only-show-errors', '-o', 'json')) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(90000)) {
            $process.Kill($true); $process.WaitForExit()
            throw 'ExchangePermissionCorrection:OutcomeUnverified'
        }
        if ($process.ExitCode -ne 0) { throw 'ExchangePermissionCorrection:OutcomeUnverified' }
        if ([string]::IsNullOrWhiteSpace($output.Result)) { return $null }
        return $output.Result | ConvertFrom-Json -AsHashtable -Depth 30 -DateKind String
    }
    finally { $process.Dispose() }
}
function Read-Graph([string]$Path) {
    Run-Az @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/$Path")
}
function Read-Collection([string]$Path) {
    $result = Read-Graph $Path
    if ($result.Contains('@odata.nextLink')) { throw 'ExchangePermissionCorrection:UnexpectedPagination' }
    return ,@($result.value)
}
function Write-Graph([string]$Method, [string]$Path, $Body) {
    $null = Run-Az @('rest', '--method', $Method, '--url', "https://graph.microsoft.com/v1.0/$Path",
        '--headers', 'Content-Type=application/json', '--body', ($Body | ConvertTo-Json -Depth 20 -Compress))
}
function Requirements($Items) {
    @($Items | Sort-Object resourceAppId | ForEach-Object {
        @{ resourceAppId = $_.resourceAppId; resourceAccess = @($_.resourceAccess | Sort-Object id, type) }
    })
}
function Read-Snapshot {
    $app = Read-Graph "applications/$applicationObjectId`?`$select=id,appId,displayName,tags,requiredResourceAccess"
    $sp = Read-Graph "servicePrincipals/$principalId`?`$select=id,appId,accountEnabled,appOwnerOrganizationId,tags,servicePrincipalType"
    $owners = Read-Collection "applications/$applicationObjectId/owners?`$select=id"
    Assert-Equal @($owners.id) @($operatorId) 'ApplicationOwnerChanged'
    Assert-Equal @($app.tags | Sort-Object) @("A365GatewayBootstrap", "A365GatewayOwnership:$ownership" | Sort-Object) 'ApplicationOwnershipChanged'
    Assert-Equal @($sp.tags | Sort-Object) @($app.tags | Sort-Object) 'PrincipalOwnershipChanged'
    if ($app.id -cne $applicationObjectId -or $app.appId -cne $applicationId -or
        $app.displayName -cne 'A365 Gateway Purview Automation - gw0911g-dev' -or
        $sp.id -cne $principalId -or $sp.appId -cne $applicationId -or
        $sp.accountEnabled -ne $true -or $sp.appOwnerOrganizationId -cne $tenant -or
        $sp.servicePrincipalType -cne 'Application') { throw 'ExchangePermissionCorrection:IdentityChanged' }
    $grants = Read-Collection "servicePrincipals/$principalId/appRoleAssignments?`$select=principalId,resourceId,appRoleId"
    $directory = Read-Collection ("roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20'$principalId'&" +
        '$select=principalId,roleDefinitionId,directoryScopeId')
    Assert-Equal @($directory) @(@{ principalId = $principalId;
        roleDefinitionId = '17315797-102d-40b4-93e0-432062caca18'; directoryScopeId = '/' }) 'DirectoryRoleChanged'
    @{ declaration = @(Requirements $app.requiredResourceAccess);
        grants = @($grants | Sort-Object resourceId, appRoleId); directoryRoles = @($directory) }
}
function Source-Proof {
    $proof = [ordered]@{}
    foreach ($path in @('operations\repair-gw0911g-exchange-permission.ps1',
            'bootstrap\modules\Entra.psm1', 'bootstrap\modules\Experience.psm1',
            'operations\GatewayUpgradeExecution.psm1',
            'src\Gateway.Infrastructure\Services\CapabilityPreparationReceipt.cs')) {
        $proof[$path] = Hash-File (Join-Path $root $path)
    }
    return $proof
}
$legacyRequirement = @{ resourceAppId = $legacyAppId; resourceAccess = @(@{ id = $legacyRoleId; type = 'Role' }) }
$exchangeRequirement = @{ resourceAppId = $exchangeAppId; resourceAccess = @(@{ id = $exchangeRoleId; type = 'Role' }) }
$legacyGrant = @{ principalId = $principalId; resourceId = $legacyId; appRoleId = $legacyRoleId }
$newGrant = @{ principalId = $principalId; resourceId = $exchangeId; appRoleId = $exchangeRoleId }
$originalDeclaration = @(Requirements @($legacyRequirement))
$targetDeclaration = @(Requirements @($legacyRequirement, $exchangeRequirement))
$originalGrants = @($legacyGrant)
$targetGrants = @($legacyGrant, $newGrant | Sort-Object resourceId, appRoleId)
[IO.Directory]::CreateDirectory($work) | Out-Null
$lock = [IO.File]::Open((Join-Path $work 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    if ((Hash-File $statePath) -cne $stateHash) { throw 'ExchangePermissionCorrection:AcceptedStateChanged' }
    $account = Run-Az @('account', 'show', '--query', '{id:id,tenantId:tenantId}')
    Assert-Equal $account @{ id = $subscription; tenantId = $tenant } 'CliAuthorityChanged'
    $me = Read-Graph 'me?$select=id'
    if ($me.id -cne $operatorId) { throw 'ExchangePermissionCorrection:OperatorChanged' }
    $resource = Read-Graph "servicePrincipals/$exchangeId`?`$select=id,appId,servicePrincipalNames,appRoles"
    $role = @($resource.appRoles | Where-Object { $_.id -ceq $exchangeRoleId -and
        $_.value -ceq 'Exchange.ManageAsApp' -and $_.isEnabled -eq $true -and
        'Application' -cin @($_.allowedMemberTypes) })
    if ($resource.id -cne $exchangeId -or $resource.appId -cne $exchangeAppId -or $role.Count -ne 1 -or
        'https://ps.compliance.protection.outlook.com' -cnotin @($resource.servicePrincipalNames)) {
        throw 'ExchangePermissionCorrection:ActualResourceChanged'
    }
    $snapshot = Read-Snapshot
    $planPath = Join-Path $work 'plan.json'
    if ($Mode -eq 'Plan') {
        Assert-Equal $snapshot.declaration $originalDeclaration 'OriginalDeclarationChanged'
        Assert-Equal $snapshot.grants $originalGrants 'OriginalGrantsChanged'
        $plan = @{ tenantId = $tenant; subscriptionId = $subscription; applicationId = $applicationId;
            applicationObjectId = $applicationObjectId; principalId = $principalId; sourceProof = Source-Proof;
            before = $snapshot; targetDeclaration = $targetDeclaration; targetGrants = $targetGrants;
            existingLegacyPermissionPreserved = $true; directoryRolesUnchanged = $true;
            certificateOrCredentialOperations = 0; newServicePrincipals = 0; acceptedStateHash = $stateHash;
            evidence = 'Successful service-principal sign-ins for Office 365 Exchange Online; compliance endpoint is registered to that resource; its exact ManageAsApp grant is absent.' }
        Save-New 'plan.json' $plan
        @{ stage = 'Plan'; approvalFingerprint = Fingerprint $plan } | ConvertTo-Json -Compress
        return
    }
    $plan = Get-Content $planPath -Raw | ConvertFrom-Json -AsHashtable -Depth 30 -DateKind String
    if ($ApprovalFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        (Fingerprint $plan) -cne $ApprovalFingerprint) { throw 'ExchangePermissionCorrection:ExactPlanApprovalRequired' }
    Assert-Equal (Source-Proof) $plan.sourceProof 'ReviewedSourceChanged'
    Assert-Equal $targetDeclaration $plan.targetDeclaration 'TargetDeclarationChanged'
    Assert-Equal $targetGrants $plan.targetGrants 'TargetGrantsChanged'
    if ($Mode -eq 'Apply') {
        if ((Fingerprint $snapshot.declaration) -cne (Fingerprint $targetDeclaration)) {
            Assert-Equal $snapshot.declaration $originalDeclaration 'UnownedDeclaration'
            Assert-Equal $snapshot.grants $originalGrants 'UnownedGrants'
            Save-New 'declaration-intent.json' @{ plan = $ApprovalFingerprint; target = $targetDeclaration }
            Write-Graph 'PATCH' "applications/$applicationObjectId" @{ requiredResourceAccess = $targetDeclaration }
        } else {
            Assert-Intent 'declaration-intent.json' @{ plan = $ApprovalFingerprint; target = $targetDeclaration }
        }
        $snapshot = Read-Snapshot
        Assert-Equal $snapshot.declaration $targetDeclaration 'DeclarationNotVerified'
        if ((Fingerprint $snapshot.grants) -cne (Fingerprint $targetGrants)) {
            Assert-Equal $snapshot.grants $originalGrants 'UnownedGrants'
            Save-New 'grant-intent.json' @{ plan = $ApprovalFingerprint; target = $newGrant }
            Write-Graph 'POST' "servicePrincipals/$principalId/appRoleAssignments" $newGrant
        } else {
            Assert-Intent 'grant-intent.json' @{ plan = $ApprovalFingerprint; target = $newGrant }
        }
    }
    Assert-Intent 'declaration-intent.json' @{ plan = $ApprovalFingerprint; target = $targetDeclaration }
    Assert-Intent 'grant-intent.json' @{ plan = $ApprovalFingerprint; target = $newGrant }
    $snapshot = Read-Snapshot
    Assert-Equal $snapshot.declaration $targetDeclaration 'FinalDeclarationNotVerified'
    Assert-Equal $snapshot.grants $targetGrants 'FinalGrantsNotVerified'
    Assert-Equal $snapshot.directoryRoles $plan.before.directoryRoles 'DirectoryRolesChanged'
    if ((Hash-File $statePath) -cne $stateHash) { throw 'ExchangePermissionCorrection:AcceptedStateChanged' }
    $receipt = @{ plan = $ApprovalFingerprint; applicationId = $applicationId; principalId = $principalId;
        after = $snapshot; correctedResource = $exchangeAppId; correctedRole = $exchangeRoleId;
        directoryRolesUnchanged = $true; legacyPermissionPreserved = $true;
        credentialsOrCertificatesChanged = $false; acceptedStateHash = $stateHash; status = 'ExactReadbackVerified' }
    $receiptPath = Join-Path $work 'verified.json'
    if (Test-Path $receiptPath) {
        Assert-Equal (Get-Content $receiptPath -Raw | ConvertFrom-Json -AsHashtable -Depth 30 -DateKind String) $receipt 'ExistingReceiptChanged'
    } else { Save-New 'verified.json' $receipt }
    $receipt | ConvertTo-Json -Depth 20
}
finally { $lock.Dispose() }
