#Requires -Version 7.0

<#
.SYNOPSIS
    Builds and promotes only the hosted Admin UI of one completed bootstrap deployment.

.DESCRIPTION
    This is a narrow, same-resource-group upgrade path. It never rewrites the
    accepted clean-bootstrap plan, never deploys the API or worker, and never reads
    Service Bus messages. It records a separate, safe upgrade receipt under the
    ignored .bootstrap/evidence tree before each external mutation.
#>

[CmdletBinding()]
param(
    [string]$Config = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap/config.json'),
    [switch]$Yes,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $Yes) {
    throw 'Admin UI upgrade requires --yes to accept the exact source, scope, What-If, and build intent before any mutation.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Azure.psm1') -Force -DisableNameChecking

function Save-AdminUiUpgradeReceipt {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$Path
    )

    $Receipt['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ".receipt-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        ConvertTo-Json -InputObject (ConvertTo-BootstrapCanonicalValue -Value $Receipt) -Depth 100 |
            Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
        if ($IsWindows) {
            $acl = Get-Acl -LiteralPath $temporary
            $acl.SetAccessRuleProtection($true, $false)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'FullControl',
                'Allow')
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $temporary -AclObject $acl
        }
        elseif (Get-Command chmod -ErrorAction SilentlyContinue) {
            & chmod 600 $temporary
            if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the Admin UI upgrade receipt to the current user.' }
        }
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Read-AdminUiUpgradeReceipt {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $convertParameters = @{ AsHashtable = $true; Depth = 100; ErrorAction = 'Stop' }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $convertParameters['DateKind'] = 'String'
        }
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json @convertParameters
    }
    catch {
        throw 'The Admin UI upgrade receipt is malformed. Preserve it for review; do not edit it to claim completion.'
    }
}

function Get-RequiredCompletedEvidence {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$Name
    )
    $step = if ($State.steps -is [System.Collections.IDictionary]) { $State.steps[$Name] } else { $null }
    if ($step -isnot [System.Collections.IDictionary] -or
        [string]$step.status -cne 'Completed' -or
        $step.evidence -isnot [System.Collections.IDictionary]) {
        throw "Admin UI upgrade requires completed and evidenced bootstrap step '$Name'. Run gateway resume and gateway verify first."
    }
    return $step.evidence
}

function Assert-CompletedBootstrapBoundary {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )

    if ($State.acceptedPlan -isnot [System.Collections.IDictionary]) {
        throw 'Admin UI upgrade requires the preserved accepted bootstrap plan.'
    }
    foreach ($name in @(
        'Azure foundation',
        'Gateway API identity',
        'Immutable workload images',
        'Inert identity deployment',
        'Agent 365 seed blueprint',
        'Workflow v3 Entra configuration',
        'SQL private endpoint',
        'Gateway database',
        'Admin UI identity',
        'Admin UI Key Vault credential',
        'Gateway runtime deployment',
        'Admin UI deployment',
        'Admin UI redirect URIs',
        'Network hardening',
        'End-to-end deployment verification')) {
        $null = Get-RequiredCompletedEvidence -State $State -Name $name
    }

    $verificationStep = $State.steps['End-to-end deployment verification']
    $verification = if ($State.outputs -is [System.Collections.IDictionary]) { $State.outputs['verification'] } else { $null }
    if ($verification -isnot [System.Collections.IDictionary] -or
        [string]$verification.verifiedAtUtc -cne [string]$verificationStep.evidence.verifiedAtUtc) {
        throw 'Admin UI upgrade requires one current, completed bootstrap verification receipt.'
    }

    $canonicalOwnership = ([guid][string]$State.deploymentOwnershipId).ToString('D')
    if ([string]$State.deploymentOwnershipId -cne $canonicalOwnership -or
        [string]$State.configuration.subscriptionId -cne [string]$Configuration.subscriptionId -or
        [string]$State.configuration.tenantId -cne [string]$Configuration.tenantId -or
        [string]$State.configuration.resourceGroupName -cne [string]$Configuration.resourceGroupName -or
        [string]$State.configuration.projectName -cne [string]$Configuration.projectName -or
        [string]$State.configuration.environment -cne [string]$Configuration.environment) {
        throw 'Bootstrap state does not match the exact configured subscription, tenant, resource group, project, environment, and ownership boundary.'
    }

    if ($State.Contains('databaseRecoveryPlan')) {
        $recovery = $State.databaseRecoveryPlan
        $database = $State.steps['Gateway database'].evidence
        if ($recovery -isnot [System.Collections.IDictionary] -or
            [string]$recovery.status -cne 'Completed' -or
            [string]$recovery.deploymentOwnershipId -cne $canonicalOwnership -or
            [string]$database.databaseRecoveryPlanFingerprint -cne [string]$recovery.planFingerprint -or
            (Get-BootstrapObjectFingerprint -InputObject $database) -cne [string]$recovery.databaseEvidenceFingerprint) {
            throw 'The post-recovery database receipt is not exact, completed, or bound to the verified bootstrap state.'
        }
    }

    return [ordered]@{
        deploymentOwnershipId = $canonicalOwnership
        acceptedPlanFingerprint = [string]$State.acceptedPlan.planFingerprint
        acceptedPlanRecordFingerprint = Get-BootstrapObjectFingerprint -InputObject $State.acceptedPlan
        verifiedAtUtc = [string]$verification.verifiedAtUtc
    }
}

function Get-ContainerAppSnapshot {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExpectedOwnershipId,
        [Parameter(Mandatory)][string]$ExpectedBootstrapSourceFingerprint
    )

    $app = Invoke-AzJson -Arguments @(
        'containerapp', 'show', '--resource-group', [string]$Configuration.resourceGroupName,
        '--name', $Name)
    $containers = @($app.properties.template.containers)
    if ([string]$app.name -cne $Name -or
        [string]$app.properties.provisioningState -cne 'Succeeded' -or
        [string]$app.tags.bootstrapOwnershipId -cne $ExpectedOwnershipId -or
        [string]$app.tags.bootstrapSourceFingerprint -cne $ExpectedBootstrapSourceFingerprint -or
        $containers.Count -ne 1 -or
        [string]$containers[0].image -cnotmatch '@sha256:[0-9a-f]{64}$') {
        throw "Container App '$Name' is not the exact ownership/source-bound, digest-pinned baseline."
    }
    return [ordered]@{
        id = [string]$app.id
        name = $Name
        image = [string]$containers[0].image
        latestReadyRevisionName = [string]$app.properties.latestReadyRevisionName
        configurationFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
            identity = $app.identity
            configuration = $app.properties.configuration
            template = $app.properties.template
        })
    }
}

function Get-AdminUiUpgradeSourceMetadata {
    $buildSourceFingerprint = Get-BootstrapSourceFingerprint -Root $repositoryRoot
    $toolPath = Join-Path $repositoryRoot 'operations/upgrade-bootstrap-admin-ui.ps1'
    $toolFingerprint = "sha256:$((Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash.ToLowerInvariant())"
    Assert-BootstrapFingerprintValue -Value $buildSourceFingerprint -Label 'Admin UI build source fingerprint'
    Assert-BootstrapFingerprintValue -Value $toolFingerprint -Label 'Admin UI upgrade tool fingerprint'
    return [ordered]@{
        buildSourceFingerprint = $buildSourceFingerprint
        toolFingerprint = $toolFingerprint
        upgradeSourceFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
            buildSourceFingerprint = $buildSourceFingerprint
            toolFingerprint = $toolFingerprint
        })
    }
}

function Assert-AdminUiUpgradeReceipt {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SourceMetadata,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Completion,
        [Parameter(Mandatory)][string]$OwnershipId,
        [Parameter(Mandatory)][string]$ConfigurationFingerprint,
        [Parameter(Mandatory)][string]$IntentId,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$DeploymentName,
        [Parameter(Mandatory)][string]$LocatorFingerprint
    )

    if ([string]$Receipt.schemaVersion -cne '1' -or
        [string]$Receipt.operation -cne 'BootstrapAdminUiOnlyUpgrade' -or
        $Receipt.acceptedPlan -isnot [System.Collections.IDictionary] -or
        $Receipt.build -isnot [System.Collections.IDictionary] -or
        $Receipt.deployment -isnot [System.Collections.IDictionary]) {
        throw 'The Admin UI upgrade receipt has an unsupported or incomplete contract.'
    }
    Assert-BootstrapFingerprintValue -Value ([string]$Receipt.planFingerprint) -Label 'Admin UI accepted upgrade plan fingerprint'
    Assert-BootstrapFingerprintValue -Value ([string]$Receipt.locatorFingerprint) -Label 'Admin UI upgrade receipt locator fingerprint'
    if ((Get-BootstrapObjectFingerprint -InputObject $Receipt.acceptedPlan) -cne [string]$Receipt.planFingerprint -or
        [string]$Receipt.locatorFingerprint -cne $LocatorFingerprint) {
        throw 'The immutable accepted Admin UI upgrade plan or its deterministic receipt locator does not match its fingerprint.'
    }

    $plan = $Receipt.acceptedPlan
    if ([string]$plan.operation -cne 'BootstrapAdminUiOnlyUpgrade' -or
        [string]$plan.deploymentOwnershipId -cne $OwnershipId -or
        [string]$plan.configurationFingerprint -cne $ConfigurationFingerprint -or
        [string]$plan.acceptedBootstrapPlanFingerprint -cne [string]$Completion.acceptedPlanFingerprint -or
        [string]$plan.acceptedBootstrapPlanRecordFingerprint -cne [string]$Completion.acceptedPlanRecordFingerprint -or
        [string]$plan.buildSourceFingerprint -cne [string]$SourceMetadata.buildSourceFingerprint -or
        [string]$plan.upgradeToolFingerprint -cne [string]$SourceMetadata.toolFingerprint -or
        [string]$plan.upgradeSourceFingerprint -cne [string]$SourceMetadata.upgradeSourceFingerprint -or
        [string]$plan.build.intentId -cne $IntentId -or
        [string]$plan.build.tag -cne $Tag -or
        [string]$plan.build.component -cne 'adminUi' -or
        [string]$plan.build.repository -cne 'gateway-admin' -or
        [string]$plan.build.dockerfile -cne 'src/Gateway.AdminUi/Dockerfile' -or
        [string]$plan.deployment.name -cne $DeploymentName -or
        [string]$plan.deployment.mode -cne 'Incremental' -or
        [string]$plan.deployment.deployKeyVaultPrivateEndpoint -cne 'False') {
        throw 'The Admin UI upgrade receipt belongs to a different source, owner, configuration, build, deployment, or accepted bootstrap plan.'
    }

    if ([string]$Receipt.build.intentId -cne $IntentId -or
        [string]$Receipt.build.tag -cne $Tag -or
        [string]$Receipt.build.state -notin @('IntentRecorded', 'RunQueued', 'DigestCheckpointed') -or
        [string]$Receipt.deployment.name -cne $DeploymentName -or
        [string]$Receipt.deployment.mode -cne 'Incremental' -or
        [string]$Receipt.deployment.deployKeyVaultPrivateEndpoint -cne 'False' -or
        [string]$Receipt.deployment.state -notin @('Planned', 'IntentRecorded', 'Succeeded') -or
        [string]$Receipt.status -notin @('Accepted', 'Verified')) {
        throw 'The mutable Admin UI upgrade recovery checkpoints are malformed or outside the accepted plan.'
    }
    if ([string]$Receipt.build.state -ceq 'DigestCheckpointed') {
        if ([string]$Receipt.build.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$' -or
            [string]$Receipt.build.digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$Receipt.build.image -cne "$($plan.baseline.foundation.acrLoginServer)/gateway-admin@$($Receipt.build.digest)") {
            throw 'The Admin UI build checkpoint does not contain the one exact accepted immutable image.'
        }
    }
    elseif ([string]$Receipt.build.state -ceq 'RunQueued' -and
        [string]$Receipt.build.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$') {
        throw 'The queued Admin UI build checkpoint has no exact ACR run identifier.'
    }
    if ([string]$Receipt.deployment.state -in @('IntentRecorded', 'Succeeded') -and
        [string]$Receipt.build.state -cne 'DigestCheckpointed') {
        throw 'The Admin UI deployment checkpoint advanced without an immutable build digest.'
    }
    if ([string]$Receipt.status -ceq 'Verified' -and
        ([string]$Receipt.build.state -cne 'DigestCheckpointed' -or [string]$Receipt.deployment.state -cne 'Succeeded')) {
        throw 'The Admin UI upgrade receipt claims verification without completed build and deployment checkpoints.'
    }
    return $true
}

function Get-QueueCountSnapshot {
    param([Parameter(Mandatory)]$Configuration)
    $namespaceName = "sb-$($Configuration.projectName)-$($Configuration.environment)"
    $queues = @(Invoke-AzJson -Arguments @(
        'servicebus', 'queue', 'list',
        '--resource-group', [string]$Configuration.resourceGroupName,
        '--namespace-name', $namespaceName,
        '--query', '[].{name:name,active:countDetails.activeMessageCount,scheduled:countDetails.scheduledMessageCount,deadLetter:countDetails.deadLetterMessageCount,transfer:countDetails.transferMessageCount,transferDeadLetter:countDetails.transferDeadLetterMessageCount}'))
    if ($queues.Count -eq 0) { throw 'The verified Gateway Service Bus namespace returned no queues.' }
    $result = [Collections.Generic.List[object]]::new()
    foreach ($queue in @($queues | Sort-Object name)) {
        if ([string]$queue.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,259}$') {
            throw 'Service Bus queue count readback returned a malformed queue name.'
        }
        $entry = [ordered]@{ name = [string]$queue.name }
        foreach ($name in @('active', 'scheduled', 'deadLetter', 'transfer', 'transferDeadLetter')) {
            $value = 0L
            if (-not [long]::TryParse([string]$queue.$name, [ref]$value) -or $value -lt 0) {
                throw 'Service Bus queue count readback returned a malformed nonnegative count.'
            }
            $entry[$name] = $value
        }
        $result.Add($entry)
    }
    return @($result)
}

function Get-ExactAdminRoleAssignment {
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$RoleDefinitionGuid
    )
    $assignments = @(Invoke-AzJson -Arguments @(
        'role', 'assignment', 'list', '--assignee-object-id', $PrincipalId,
        '--scope', $Scope, '--include-inherited',
        '--query', '[].{id:id,principalId:principalId,scope:scope,roleDefinitionId:roleDefinitionId}'))
    if ($assignments.Count -ne 1 -or
        -not ([string]$assignments[0].principalId).Equals($PrincipalId, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$assignments[0].scope).Equals($Scope, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$assignments[0].roleDefinitionId).EndsWith("/$RoleDefinitionGuid", [StringComparison]::OrdinalIgnoreCase) -or
        [string]$assignments[0].id -cnotmatch '^/subscriptions/[0-9a-f-]{36}/.+/providers/Microsoft.Authorization/roleAssignments/[0-9a-f-]{36}$') {
        throw 'Admin UI managed identity does not have the one exact least-privilege role assignment.'
    }
    return [string]$assignments[0].id
}

function Get-AdminUiLiveBoundary {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$OwnershipId,
        [Parameter(Mandatory)][string]$BootstrapSourceFingerprint
    )
    $foundation = $State.steps['Azure foundation'].evidence
    $adminEvidence = $State.steps['Admin UI deployment'].evidence
    $credential = $State.steps['Admin UI Key Vault credential'].evidence
    $identityName = "id-gateway-admin-$($Configuration.environment)"
    $appName = "ca-gateway-admin-$($Configuration.environment)"
    $identity = Invoke-AzJson -Arguments @(
        'identity', 'show', '--resource-group', [string]$Configuration.resourceGroupName,
        '--name', $identityName)
    $app = Invoke-AzJson -Arguments @(
        'containerapp', 'show', '--resource-group', [string]$Configuration.resourceGroupName,
        '--name', $appName)
    $containers = @($app.properties.template.containers)
    $attachedIdentityIds = @($app.identity.userAssignedIdentities.PSObject.Properties.Name)
    $secrets = @($app.properties.configuration.secrets)
    $secretUri = [string]$credential.secretUri
    if ([string]$identity.name -cne $identityName -or
        [string]$identity.principalId -cne [string]$adminEvidence.adminUiPrincipalId -or
        [string]$identity.tags.bootstrapOwnershipId -cne $OwnershipId -or
        [string]$identity.tags.bootstrapSourceFingerprint -cne $BootstrapSourceFingerprint -or
        [string]$app.name -cne $appName -or
        [string]$app.properties.provisioningState -cne 'Succeeded' -or
        [string]$app.properties.configuration.activeRevisionsMode -cne 'Single' -or
        [string]$app.tags.bootstrapOwnershipId -cne $OwnershipId -or
        [string]$app.tags.bootstrapSourceFingerprint -cne $BootstrapSourceFingerprint -or
        [string]$app.identity.type -cne 'UserAssigned' -or
        $containers.Count -ne 1 -or
        [string]$containers[0].image -cnotmatch '@sha256:[0-9a-f]{64}$' -or
        $attachedIdentityIds.Count -ne 1 -or
        -not ([string]$attachedIdentityIds[0]).Equals([string]$identity.id, [StringComparison]::OrdinalIgnoreCase) -or
        @($app.properties.configuration.registries).Count -ne 1 -or
        [string]$app.properties.configuration.registries[0].server -cne [string]$foundation.acrLoginServer -or
        -not ([string]$app.properties.configuration.registries[0].identity).Equals([string]$identity.id, [StringComparison]::OrdinalIgnoreCase) -or
        $secrets.Count -ne 1 -or [string]$secrets[0].name -cne 'admin-ui-entra-client-secret' -or
        [string]$secrets[0].keyVaultUrl -cne $secretUri -or
        -not ([string]$secrets[0].identity).Equals([string]$identity.id, [StringComparison]::OrdinalIgnoreCase) -or
        $secretUri -cnotmatch '^https://[a-z0-9-]+\.vault\.azure\.net/secrets/admin-ui-entra-client-secret$') {
        throw 'The live Admin UI identity, registry pull, versionless Key Vault secret, source, or ownership boundary is not exact.'
    }
    $acrScope = "/subscriptions/$($Configuration.subscriptionId)/resourceGroups/$($Configuration.resourceGroupName)/providers/Microsoft.ContainerRegistry/registries/$($foundation.acrName)"
    $secretScope = "/subscriptions/$($Configuration.subscriptionId)/resourceGroups/$($Configuration.resourceGroupName)/providers/Microsoft.KeyVault/vaults/kv-$($Configuration.projectName)-$($Configuration.environment)/secrets/admin-ui-entra-client-secret"
    $registry = Invoke-AzJson -Arguments @(
        'resource', 'show', '--ids', $acrScope, '--api-version', '2023-11-01-preview')
    $vault = Invoke-AzJson -Arguments @(
        'keyvault', 'show', '--resource-group', [string]$Configuration.resourceGroupName,
        '--name', "kv-$($Configuration.projectName)-$($Configuration.environment)")
    if ([string]$registry.properties.adminUserEnabled -cne 'False' -or
        [string]$registry.properties.policies.azureADAuthenticationAsArmPolicy.status -cne 'enabled' -or
        [string]$vault.properties.enableRbacAuthorization -cne 'True' -or
        [string]$vault.properties.publicNetworkAccess -cne 'Disabled') {
        throw 'Admin UI dependencies are not on the required Entra/RBAC-only ACR and private Key Vault boundary.'
    }
    $acrRole = Get-ExactAdminRoleAssignment -PrincipalId ([string]$identity.principalId) -Scope $acrScope -RoleDefinitionGuid '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    $secretRole = Get-ExactAdminRoleAssignment -PrincipalId ([string]$identity.principalId) -Scope $secretScope -RoleDefinitionGuid '4633458b-17de-408a-b874-0445c86b69e6'
    return [ordered]@{
        app = $app
        appId = [string]$app.id
        appName = $appName
        image = [string]$containers[0].image
        fqdn = [string]$app.properties.configuration.ingress.fqdn
        identityId = [string]$identity.id
        principalId = [string]$identity.principalId
        secretUri = $secretUri
        secretResourceId = $secretScope
        allowedRoleAssignmentIds = @(@($acrRole, $secretRole) | Sort-Object)
        localRegistryAuthenticationDisabled = $true
        keyVaultRbacOnly = $true
        keyVaultPublicNetworkDisabled = $true
    }
}

function New-ArmParameterFile {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Parameters)
    $parameterObject = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{}
    }
    foreach ($entry in $Parameters.GetEnumerator()) {
        $parameterObject.parameters[$entry.Key] = @{ value = $entry.Value }
    }
    $path = Join-Path ([IO.Path]::GetTempPath()) "a365gw-admin-upgrade-$([guid]::NewGuid().ToString('N')).json"
    $parameterObject | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    if (-not $IsWindows -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
        & chmod 600 $path
        if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the temporary Admin UI ARM parameter file.' }
    }
    return $path
}

function Get-AdminUiUpgradeParameters {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$OwnershipId,
        [Parameter(Mandatory)][string]$BootstrapSourceFingerprint,
        [Parameter(Mandatory)][string]$UpgradeSourceFingerprint,
        [Parameter(Mandatory)][string]$Image
    )
    $foundation = $State.steps['Azure foundation'].evidence
    $apiIdentity = $State.steps['Gateway API identity'].evidence
    $adminIdentity = $State.steps['Admin UI identity'].evidence
    $credential = $State.steps['Admin UI Key Vault credential'].evidence
    return [ordered]@{
        environment = [string]$Configuration.environment
        projectName = [string]$Configuration.projectName
        deploymentOwnershipId = $OwnershipId
        bootstrapSourceFingerprint = $BootstrapSourceFingerprint
        adminUiUpgradeSourceFingerprint = $UpgradeSourceFingerprint
        containerAppsEnvironmentName = [string]$foundation.containerAppsEnvironmentName
        adminUiContainerImage = $Image
        entraIdTenantId = [string]$Configuration.tenantId
        adminUiEntraClientId = [string]$adminIdentity.adminUiClientId
        adminUiEntraClientSecretKeyVaultSecretUri = [string]$credential.secretUri
        adminUiGatewayApiScope = "$($apiIdentity.gatewayApiScopeBaseUri)/access_as_user"
        deployKeyVaultPrivateEndpoint = $false
    }
}

function Invoke-AdminUiUpgradeWhatIf {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [Parameter(Mandatory)][string[]]$AllowedResourceIds,
        [Parameter(Mandatory)][string]$AdminAppId
    )
    $temporary = New-ArmParameterFile -Parameters $Parameters
    try {
        $result = Invoke-AzJson -Arguments @(
            'deployment', 'group', 'what-if',
            '--resource-group', [string]$Configuration.resourceGroupName,
            '--template-file', (Join-Path $repositoryRoot 'infrastructure/bicep/admin-ui.bicep'),
            '--parameters', "@$temporary", '--result-format', 'ResourceIdOnly')
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    if (-not $result -or [string]$result.status -cne 'Succeeded') {
        throw 'Admin UI ARM What-If did not complete successfully.'
    }
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $AllowedResourceIds) { $null = $allowed.Add($id) }
    $changes = [Collections.Generic.List[object]]::new()
    foreach ($change in @($result.changes)) {
        $resourceId = [string]$change.resourceId
        $changeType = [string]$change.changeType
        if ($changeType -in @('Delete', 'Create') -or
            $changeType -notin @('Modify', 'Deploy', 'NoChange', 'Ignore') -or
            -not $allowed.Contains($resourceId)) {
            throw 'Admin UI What-If contains a deletion, creation, unsupported change, or resource outside the exact Admin UI allowlist.'
        }
        $changes.Add([ordered]@{ resourceId = $resourceId.ToLowerInvariant(); changeType = $changeType })
    }
    if ($changes.Count -eq 0 -or
        @($changes | Where-Object { [string]$_.resourceId -eq $AdminAppId.ToLowerInvariant() -or [string]$_.resourceId -like '*/providers/microsoft.resources/deployments/deploy-admin-ui-app' }).Count -eq 0) {
        throw 'Admin UI What-If did not contain the exact Admin UI app/module update.'
    }
    return @($changes | Sort-Object resourceId, changeType)
}

function Resolve-AdminUiBuild {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][bool]$ReceiptCreatedThisInvocation,
        [Parameter(Mandatory)][string]$BuildSourceFingerprint
    )
    $foundation = $Receipt.acceptedPlan.baseline.foundation
    $registry = [string]$foundation.acrName
    $loginServer = [string]$foundation.acrLoginServer
    $repository = 'gateway-admin'
    $intent = $Receipt.build
    $tag = [string]$intent.tag
    if ([string]$intent.state -ceq 'DigestCheckpointed') {
        $found = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag
        if (-not $found -or [string]$found.digest -cne [string]$intent.digest -or
            [string]$intent.image -cne "$loginServer/$repository@$($intent.digest)") {
            throw 'The checkpointed Admin UI build no longer matches its exact immutable ACR digest.'
        }
        return [string]$intent.image
    }

    $createdIntent = $ReceiptCreatedThisInvocation
    $runs = @(Get-GatewayAcrExactImageRuns -Registry $registry -Repository $repository -Tag $tag)
    if ([string]$intent.state -ceq 'IntentRecorded' -and $runs.Count -eq 0) {
        if (-not $createdIntent) {
            throw 'The recovered Admin UI build intent has no exact run or digest. Submission outcome is ambiguous; automatic resubmission is forbidden.'
        }
        $context = $null
        try {
            $context = New-GatewayAcrBuildContext -RepositoryRoot $repositoryRoot -SourceFingerprint $BuildSourceFingerprint
            $run = Invoke-AzJson -CaptureStdoutOnly -Arguments @(
                'acr', 'build', '--registry', $registry,
                '--image', "${repository}:$tag",
                '--file', 'src/Gateway.AdminUi/Dockerfile',
                $context, '--no-logs',
                '--query', '{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}}')
            $run = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository $repository -Tag $tag
            $intent['runId'] = [string]$run.runId
        }
        finally {
            if ($context -and (Test-Path -LiteralPath $context)) { Remove-Item -LiteralPath $context -Recurse -Force }
        }
    }
    elseif ($runs.Count -eq 1) {
        $intent['runId'] = [string]$runs[0].runId
    }
    elseif ($runs.Count -ne 0) {
        throw 'Admin UI build recovery found an ambiguous exact-tag run set.'
    }
    if ([string]$intent.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$') {
        throw 'Admin UI build did not produce one bounded ACR run identifier.'
    }
    $intent['state'] = 'RunQueued'
    Save-AdminUiUpgradeReceipt -Receipt $Receipt -Path $ReceiptPath

    $terminal = $null
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        $run = Get-GatewayAcrExactRunById -Registry $registry -Repository $repository -Tag $tag -RunId ([string]$intent.runId)
        if ([string]$run.status -ceq 'Succeeded') { $terminal = $run; break }
        if ([string]$run.status -in @('Failed', 'Canceled', 'Error', 'Timeout')) {
            throw 'The exact Admin UI ACR build reached a terminal failure. No automatic resubmission is permitted.'
        }
        if ($attempt -lt 60) { Start-Sleep -Seconds 2 }
    }
    if (-not $terminal) { throw 'The exact Admin UI build remains pending. Rerun the same command later; no second build will be submitted.' }
    $digest = [string]@($terminal.outputImages)[0].digest
    $found = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or -not $found -or [string]$found.digest -cne $digest) {
        throw 'The succeeded Admin UI build did not reconcile to its exact tag and immutable digest.'
    }
    $intent['state'] = 'DigestCheckpointed'
    $intent['digest'] = $digest
    $intent['image'] = "$loginServer/$repository@$digest"
    Save-AdminUiUpgradeReceipt -Receipt $Receipt -Path $ReceiptPath
    return [string]$intent.image
}

function Assert-AdminDeploymentResult {
    param(
        [Parameter(Mandatory)]$Deployment,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [Parameter(Mandatory)][string]$UpgradeSourceFingerprint,
        [Parameter(Mandatory)][string]$Image
    )
    if (-not $Deployment -or [string]$Deployment.properties.provisioningState -cne 'Succeeded') {
        throw 'The exact Admin UI upgrade deployment did not reach Succeeded.'
    }
    $actual = $Deployment.properties.parameters
    $outputs = $Deployment.properties.outputs
    foreach ($name in @('environment', 'projectName', 'deploymentOwnershipId', 'bootstrapSourceFingerprint', 'adminUiUpgradeSourceFingerprint', 'containerAppsEnvironmentName', 'adminUiContainerImage', 'entraIdTenantId', 'adminUiEntraClientId', 'adminUiGatewayApiScope', 'deployKeyVaultPrivateEndpoint')) {
        if ([string]$actual.$name.value -cne [string]$Parameters[$name]) {
            throw 'The Admin UI upgrade deployment parameter receipt does not match the accepted plan.'
        }
    }
    if ([string]$outputs.adminUiUpgradeSourceFingerprint.value -cne $UpgradeSourceFingerprint -or
        [string]$outputs.adminUiContainerImage.value -cne $Image -or
        [string]$outputs.deploymentOwnershipId.value -cne [string]$Parameters.deploymentOwnershipId -or
        [string]$outputs.bootstrapSourceFingerprint.value -cne [string]$Parameters.bootstrapSourceFingerprint) {
        throw 'The Admin UI upgrade deployment did not echo the exact original ownership/source plus separate upgrade source and digest.'
    }
    return $true
}

function Deploy-AdminUiUpgrade {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [Parameter(Mandatory)][string]$UpgradeSourceFingerprint,
        [Parameter(Mandatory)][string]$Image
    )
    $name = [string]$Receipt.deployment.name
    $startedThisInvocation = $false
    if ([string]$Receipt.deployment.state -ceq 'Planned') {
        $Receipt.deployment['state'] = 'IntentRecorded'
        Save-AdminUiUpgradeReceipt -Receipt $Receipt -Path $ReceiptPath
        $startedThisInvocation = $true
    }
    $existing = $null
    try {
        $existing = Invoke-AzJson -Arguments @(
            'deployment', 'group', 'show', '--resource-group', [string]$Configuration.resourceGroupName,
            '--name', $name)
    }
    catch { $existing = $null }
    if (-not $existing) {
        if (-not $startedThisInvocation) {
            throw 'The recovered Admin UI deployment intent has no ARM record. Its outcome is ambiguous; automatic replay is forbidden.'
        }
        $existing = Invoke-ArmDeploymentWithSecureParameters `
            -ResourceGroup ([string]$Configuration.resourceGroupName) `
            -Name $name `
            -TemplateFile (Join-Path $repositoryRoot 'infrastructure/bicep/admin-ui.bicep') `
            -Parameters $Parameters
    }
    $null = Assert-AdminDeploymentResult -Deployment $existing -Parameters $Parameters -UpgradeSourceFingerprint $UpgradeSourceFingerprint -Image $Image
    $Receipt.deployment['state'] = 'Succeeded'
    $Receipt.deployment['completedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    Save-AdminUiUpgradeReceipt -Receipt $Receipt -Path $ReceiptPath
    return $existing
}

function Test-AdminUiHttpBoundary {
    param(
        [Parameter(Mandatory)][string]$Fqdn,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId
    )
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        $health = $client.GetAsync("https://$Fqdn/health").GetAwaiter().GetResult()
        if ([int]$health.StatusCode -ne 200) { throw 'Admin UI health endpoint did not return HTTP 200.' }
        $signIn = $client.GetAsync("https://$Fqdn/MicrosoftIdentity/Account/SignIn?returnUrl=%2F").GetAwaiter().GetResult()
        $location = $signIn.Headers.Location
        if ([int]$signIn.StatusCode -notin @(302, 303) -or -not $location -or
            $location.Scheme -cne 'https' -or
            -not $location.IsDefaultPort -or
            -not $location.Host.Equals('login.microsoftonline.com', [StringComparison]::OrdinalIgnoreCase) -or
            -not $location.AbsolutePath.Contains("/$TenantId/", [StringComparison]::OrdinalIgnoreCase) -or
            $location.Query -cnotmatch "(?i)(?:[?&])client_id=$([regex]::Escape($ClientId))(?:&|$)") {
            throw 'Admin UI sign-in endpoint did not return the exact Entra authorization redirect shape.'
        }
        return [ordered]@{ healthStatus = 200; signInStatus = [int]$signIn.StatusCode; authorityHost = 'login.microsoftonline.com' }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Test-UpgradedAdminUi {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$OwnershipId,
        [Parameter(Mandatory)][string]$BootstrapSourceFingerprint,
        [Parameter(Mandatory)][string]$UpgradeSourceFingerprint,
        [Parameter(Mandatory)][string]$Image
    )
    $boundary = Get-AdminUiLiveBoundary -Configuration $Configuration -State $State -OwnershipId $OwnershipId -BootstrapSourceFingerprint $BootstrapSourceFingerprint
    $app = $boundary.app
    if ([string]$boundary.image -cne $Image -or
        [string]$app.tags.adminUiUpgradeSourceFingerprint -cne $UpgradeSourceFingerprint) {
        throw 'Admin UI did not read back the exact upgraded digest and separate source tag.'
    }
    $revisions = @(Invoke-AzJson -Arguments @(
        'containerapp', 'revision', 'list', '--resource-group', [string]$Configuration.resourceGroupName,
        '--name', [string]$boundary.appName,
        '--query', '[?properties.active==`true`].{name:name,healthState:properties.healthState,runningState:properties.runningState,replicas:properties.replicas}'))
    if ($revisions.Count -ne 1 -or
        [string]$revisions[0].name -cne [string]$app.properties.latestReadyRevisionName -or
        [string]$revisions[0].healthState -cne 'Healthy' -or
        [string]$revisions[0].runningState -cne 'Running' -or
        [int]$revisions[0].replicas -lt 1) {
        throw 'Admin UI does not have exactly one active, healthy, running, ready revision.'
    }
    $clientId = [string]$State.steps['Admin UI identity'].evidence.adminUiClientId
    $http = Test-AdminUiHttpBoundary -Fqdn ([string]$boundary.fqdn) -TenantId ([string]$Configuration.tenantId) -ClientId $clientId
    return [ordered]@{
        image = $Image
        digest = $Image.Split('@')[-1]
        fqdn = [string]$boundary.fqdn
        url = "https://$($boundary.fqdn)"
        revisionName = [string]$revisions[0].name
        principalId = [string]$boundary.principalId
        secretResourceId = [string]$boundary.secretResourceId
        versionlessSecretUri = $true
        managedIdentityRegistryPull = $true
        localRegistryAuthenticationDisabled = [bool]$boundary.localRegistryAuthenticationDisabled
        keyVaultRbacOnly = [bool]$boundary.keyVaultRbacOnly
        keyVaultPublicNetworkDisabled = [bool]$boundary.keyVaultPublicNetworkDisabled
        http = $http
    }
}

$configuration = Read-BootstrapConfig -Path $Config
$statePath = Get-BootstrapStatePath -Config $configuration
$lock = Enter-BootstrapLock -StatePath $statePath
try {
    $state = Read-BootstrapState -Path $statePath -Config $configuration
    $completion = Assert-CompletedBootstrapBoundary -Configuration $configuration -State $state
    $null = Connect-BootstrapAzure -Config $configuration -NonInteractive:$NonInteractive
    $null = Assert-BootstrapAzureContext -Config $configuration

    $ownershipId = [string]$completion.deploymentOwnershipId
    $foundation = $state.steps['Azure foundation'].evidence
    $runtime = $state.steps['Gateway runtime deployment'].evidence
    $images = $state.steps['Immutable workload images'].evidence
    $bootstrapSourceFingerprint = [string]$state.steps['Admin UI deployment'].evidence.sourceFingerprint
    Assert-BootstrapFingerprintValue -Value $bootstrapSourceFingerprint -Label 'Baseline Admin UI bootstrap source fingerprint'

    $resourceGroup = Invoke-AzJson -Arguments @(
        'group', 'show', '--name', [string]$configuration.resourceGroupName,
        '--query', '{id:id,location:location,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}')
    if ([string]$resourceGroup.id -cne "/subscriptions/$($configuration.subscriptionId)/resourceGroups/$($configuration.resourceGroupName)" -or
        [string]$resourceGroup.ownershipId -cne $ownershipId -or
        [string]$resourceGroup.sourceFingerprint -cne [string]$foundation.sourceFingerprint) {
        throw 'The live resource group is outside the exact bootstrap subscription, resource-group, ownership, and source boundary.'
    }

    $apiBefore = Get-ContainerAppSnapshot -Configuration $configuration -Name "ca-gateway-api-$($configuration.environment)" -ExpectedOwnershipId $ownershipId -ExpectedBootstrapSourceFingerprint ([string]$runtime.sourceFingerprint)
    $workerBefore = Get-ContainerAppSnapshot -Configuration $configuration -Name "ca-gateway-worker-$($configuration.environment)-v3" -ExpectedOwnershipId $ownershipId -ExpectedBootstrapSourceFingerprint ([string]$runtime.sourceFingerprint)
    if ([string]$apiBefore.image -cne [string]$runtime.apiImage -or
        [string]$workerBefore.image -cne [string]$runtime.workerImage -or
        [string]$images.api -cne [string]$runtime.apiImage -or
        [string]$images.worker -cne [string]$runtime.workerImage) {
        throw 'API or worker live image does not match the completed bootstrap runtime evidence.'
    }
    $queuesBefore = @(Get-QueueCountSnapshot -Configuration $configuration)
    $adminBefore = Get-AdminUiLiveBoundary -Configuration $configuration -State $state -OwnershipId $ownershipId -BootstrapSourceFingerprint $bootstrapSourceFingerprint

    $sourceMetadata = Get-AdminUiUpgradeSourceMetadata
    $buildSourceFingerprint = [string]$sourceMetadata.buildSourceFingerprint
    $upgradeSourceFingerprint = [string]$sourceMetadata.upgradeSourceFingerprint
    Assert-BootstrapFingerprintValue -Value $upgradeSourceFingerprint -Label 'Admin UI upgrade source fingerprint'
    $intentId = Get-BootstrapDeterministicGuid -Material "$ownershipId|$upgradeSourceFingerprint|$($state.configurationFingerprint)|$($completion.verifiedAtUtc)|admin-ui-upgrade"
    $tag = Get-BootstrapImageBuildIntentTag -DeploymentOwnershipId $ownershipId -SourceFingerprint $upgradeSourceFingerprint -IntentId $intentId
    $deploymentName = "a365gw-$($configuration.projectName)-admin-upgrade-$($upgradeSourceFingerprint.Substring(7, 12))-$($configuration.environment)"
    $locatorFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
        operation = 'BootstrapAdminUiOnlyUpgrade'
        deploymentOwnershipId = $ownershipId
        configurationFingerprint = [string]$state.configurationFingerprint
        upgradeSourceFingerprint = $upgradeSourceFingerprint
        intentId = $intentId
    })
    $receiptPath = Join-Path $repositoryRoot ".bootstrap/evidence/$($configuration.resourceGroupName)/admin-ui-upgrade/$($locatorFingerprint.Substring(7)).json"
    $prospectiveImage = "$($foundation.acrLoginServer)/gateway-admin:$tag"
    $moduleDeploymentId = "/subscriptions/$($configuration.subscriptionId)/resourceGroups/$($configuration.resourceGroupName)/providers/Microsoft.Resources/deployments/deploy-admin-ui-app"
    $allowedIds = @([string]$adminBefore.appId, [string]$adminBefore.identityId, $moduleDeploymentId) + @($adminBefore.allowedRoleAssignmentIds)
    $prospectiveParameters = Get-AdminUiUpgradeParameters -Configuration $configuration -State $state -OwnershipId $ownershipId -BootstrapSourceFingerprint $bootstrapSourceFingerprint -UpgradeSourceFingerprint $upgradeSourceFingerprint -Image $prospectiveImage
    $prospectiveWhatIf = @(Invoke-AdminUiUpgradeWhatIf -Configuration $configuration -Parameters $prospectiveParameters -AllowedResourceIds $allowedIds -AdminAppId ([string]$adminBefore.appId))

    $receipt = Read-AdminUiUpgradeReceipt -Path $receiptPath
    $createdReceipt = $false
    if ($receipt) {
        $null = Assert-AdminUiUpgradeReceipt -Receipt $receipt -SourceMetadata $sourceMetadata -Completion $completion -OwnershipId $ownershipId -ConfigurationFingerprint ([string]$state.configurationFingerprint) -IntentId $intentId -Tag $tag -DeploymentName $deploymentName -LocatorFingerprint $locatorFingerprint
    }
    else {
        $preexistingTag = Get-GatewayAcrExactTagDigest -Registry ([string]$foundation.acrName) -Repository 'gateway-admin' -Tag $tag
        $preexistingRuns = @(Get-GatewayAcrExactImageRuns -Registry ([string]$foundation.acrName) -Repository 'gateway-admin' -Tag $tag)
        if ($preexistingTag -or $preexistingRuns.Count -ne 0) {
            throw 'Fresh Admin UI upgrade intent collides with existing ACR provider state.'
        }
        if ([string]$adminBefore.image -cne [string]$state.steps['Admin UI deployment'].evidence.adminUiImage) {
            throw 'Live Admin UI no longer matches the completed bootstrap baseline and no exact upgrade receipt exists.'
        }
        $acceptedPlan = [ordered]@{
            schemaVersion = 1
            operation = 'BootstrapAdminUiOnlyUpgrade'
            subscriptionId = [string]$configuration.subscriptionId
            tenantId = [string]$configuration.tenantId
            resourceGroupName = [string]$configuration.resourceGroupName
            projectName = [string]$configuration.projectName
            environment = [string]$configuration.environment
            deploymentOwnershipId = $ownershipId
            configurationFingerprint = [string]$state.configurationFingerprint
            acceptedBootstrapPlanFingerprint = [string]$completion.acceptedPlanFingerprint
            acceptedBootstrapPlanRecordFingerprint = [string]$completion.acceptedPlanRecordFingerprint
            baselineVerifiedAtUtc = [string]$completion.verifiedAtUtc
            baselineBootstrapSourceFingerprint = $bootstrapSourceFingerprint
            buildSourceFingerprint = $buildSourceFingerprint
            upgradeToolFingerprint = [string]$sourceMetadata.toolFingerprint
            upgradeSourceFingerprint = $upgradeSourceFingerprint
            baseline = [ordered]@{
                foundation = [ordered]@{ acrName = [string]$foundation.acrName; acrLoginServer = [string]$foundation.acrLoginServer }
                api = $apiBefore
                worker = $workerBefore
                queues = $queuesBefore
                adminUi = [ordered]@{ image = [string]$adminBefore.image; principalId = [string]$adminBefore.principalId; secretResourceId = [string]$adminBefore.secretResourceId }
            }
            build = [ordered]@{ component = 'adminUi'; repository = 'gateway-admin'; dockerfile = 'src/Gateway.AdminUi/Dockerfile'; intentId = $intentId; tag = $tag }
            prospectiveWhatIf = $prospectiveWhatIf
            deployment = [ordered]@{ name = $deploymentName; mode = 'Incremental'; deployKeyVaultPrivateEndpoint = $false }
        }
        $planFingerprint = Get-BootstrapObjectFingerprint -InputObject $acceptedPlan
        $receipt = [ordered]@{
            schemaVersion = 1
            operation = 'BootstrapAdminUiOnlyUpgrade'
            locatorFingerprint = $locatorFingerprint
            planFingerprint = $planFingerprint
            acceptedPlan = ConvertTo-BootstrapCanonicalValue -Value $acceptedPlan
            status = 'Accepted'
            acceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            build = [ordered]@{ intentId = $intentId; tag = $tag; state = 'IntentRecorded' }
            deployment = [ordered]@{ name = $deploymentName; mode = 'Incremental'; deployKeyVaultPrivateEndpoint = $false; state = 'Planned' }
        }
        Save-AdminUiUpgradeReceipt -Receipt $receipt -Path $receiptPath
        $createdReceipt = $true
        $null = Assert-AdminUiUpgradeReceipt -Receipt $receipt -SourceMetadata $sourceMetadata -Completion $completion -OwnershipId $ownershipId -ConfigurationFingerprint ([string]$state.configurationFingerprint) -IntentId $intentId -Tag $tag -DeploymentName $deploymentName -LocatorFingerprint $locatorFingerprint
    }

    $planFingerprint = [string]$receipt.planFingerprint
    $acceptedAdminImage = [string]$receipt.acceptedPlan.baseline.adminUi.image
    $targetImage = if ([string]$receipt.build.state -ceq 'DigestCheckpointed') { [string]$receipt.build.image } else { '' }
    $allowedCurrentAdminImages = @($acceptedAdminImage)
    if ([string]$receipt.deployment.state -ceq 'IntentRecorded' -and
        -not [string]::IsNullOrWhiteSpace($targetImage)) {
        $allowedCurrentAdminImages += $targetImage
    }
    elseif ([string]$receipt.deployment.state -ceq 'Succeeded') {
        $allowedCurrentAdminImages = @($targetImage)
    }
    if ($allowedCurrentAdminImages -cnotcontains [string]$adminBefore.image) {
        throw 'The live Admin UI image is outside the accepted upgrade recovery boundary.'
    }
    $receipt['verificationBaseline'] = [ordered]@{
        capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        api = $apiBefore
        worker = $workerBefore
        queues = $queuesBefore
        adminUiImage = [string]$adminBefore.image
        prospectiveWhatIf = $prospectiveWhatIf
    }
    Save-AdminUiUpgradeReceipt -Receipt $receipt -Path $receiptPath

    Write-Host "Accepted Admin UI-only upgrade plan: $planFingerprint"
    Write-Host "Scope: $($configuration.subscriptionId)/$($configuration.resourceGroupName); API and worker are read-only invariants."
    Write-Host "What-If: $($prospectiveWhatIf.Count) exact Admin UI changes; zero Create/Delete; private endpoint redeployment disabled."

    $currentSourceMetadata = Get-AdminUiUpgradeSourceMetadata
    if ([string]$currentSourceMetadata.upgradeSourceFingerprint -cne $upgradeSourceFingerprint) {
        throw 'Admin UI upgrade source changed after plan acceptance.'
    }
    $image = Resolve-AdminUiBuild -Configuration $configuration -Receipt $receipt -ReceiptPath $receiptPath -ReceiptCreatedThisInvocation:$createdReceipt -BuildSourceFingerprint $buildSourceFingerprint
    $exactParameters = Get-AdminUiUpgradeParameters -Configuration $configuration -State $state -OwnershipId $ownershipId -BootstrapSourceFingerprint $bootstrapSourceFingerprint -UpgradeSourceFingerprint $upgradeSourceFingerprint -Image $image
    $exactWhatIf = @(Invoke-AdminUiUpgradeWhatIf -Configuration $configuration -Parameters $exactParameters -AllowedResourceIds $allowedIds -AdminAppId ([string]$adminBefore.appId))
    $receipt['exactDigestWhatIf'] = $exactWhatIf
    Save-AdminUiUpgradeReceipt -Receipt $receipt -Path $receiptPath
    $currentSourceMetadata = Get-AdminUiUpgradeSourceMetadata
    if ([string]$currentSourceMetadata.upgradeSourceFingerprint -cne $upgradeSourceFingerprint) {
        throw 'Admin UI upgrade source changed before the exact digest deployment.'
    }

    $null = Deploy-AdminUiUpgrade -Configuration $configuration -Receipt $receipt -ReceiptPath $receiptPath -Parameters $exactParameters -UpgradeSourceFingerprint $upgradeSourceFingerprint -Image $image
    $adminResult = Test-UpgradedAdminUi -Configuration $configuration -State $state -OwnershipId $ownershipId -BootstrapSourceFingerprint $bootstrapSourceFingerprint -UpgradeSourceFingerprint $upgradeSourceFingerprint -Image $image
    $apiAfter = Get-ContainerAppSnapshot -Configuration $configuration -Name "ca-gateway-api-$($configuration.environment)" -ExpectedOwnershipId $ownershipId -ExpectedBootstrapSourceFingerprint ([string]$runtime.sourceFingerprint)
    $workerAfter = Get-ContainerAppSnapshot -Configuration $configuration -Name "ca-gateway-worker-$($configuration.environment)-v3" -ExpectedOwnershipId $ownershipId -ExpectedBootstrapSourceFingerprint ([string]$runtime.sourceFingerprint)
    $queuesAfter = @(Get-QueueCountSnapshot -Configuration $configuration)
    if ((Get-BootstrapObjectFingerprint -InputObject $apiAfter) -cne (Get-BootstrapObjectFingerprint -InputObject $apiBefore) -or
        (Get-BootstrapObjectFingerprint -InputObject $workerAfter) -cne (Get-BootstrapObjectFingerprint -InputObject $workerBefore) -or
        (Get-BootstrapObjectFingerprint -InputObject $queuesAfter) -cne (Get-BootstrapObjectFingerprint -InputObject $queuesBefore)) {
        throw 'API, worker, or Service Bus queue counts changed during the Admin UI-only upgrade.'
    }
    $stateAfter = Read-BootstrapState -Path $statePath -Config $configuration
    if ((Get-BootstrapObjectFingerprint -InputObject $stateAfter.acceptedPlan) -cne [string]$completion.acceptedPlanRecordFingerprint) {
        throw 'The accepted bootstrap plan changed during the separate Admin UI upgrade.'
    }
    $receipt['status'] = 'Verified'
    $receipt['verifiedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    $receipt['result'] = [ordered]@{
        adminUi = $adminResult
        unchangedInvariants = [ordered]@{
            api = [ordered]@{ image = [string]$apiBefore.image; beforeFingerprint = Get-BootstrapObjectFingerprint -InputObject $apiBefore; afterFingerprint = Get-BootstrapObjectFingerprint -InputObject $apiAfter }
            worker = [ordered]@{ image = [string]$workerBefore.image; beforeFingerprint = Get-BootstrapObjectFingerprint -InputObject $workerBefore; afterFingerprint = Get-BootstrapObjectFingerprint -InputObject $workerAfter }
            queueCountsBefore = $queuesBefore
            queueCountsAfter = $queuesAfter
        }
        acceptedBootstrapPlanUnchanged = $true
        rollbackBoundary = [ordered]@{
            priorAdminUiImage = [string]$receipt.acceptedPlan.baseline.adminUi.image
            apiImage = [string]$receipt.acceptedPlan.baseline.api.image
            workerImage = [string]$receipt.acceptedPlan.baseline.worker.image
        }
    }
    Save-AdminUiUpgradeReceipt -Receipt $receipt -Path $receiptPath
    Write-Host "Admin UI upgrade verified: $($adminResult.url)"
    Write-Host "Image digest: $($adminResult.digest)"
    Write-Host 'API, worker, queues, ownership, original bootstrap plan, managed-identity pull, versionless Key Vault reference, and Entra sign-in redirect are unchanged or exact.'
    Write-Host "Safe receipt: $receiptPath"
}
finally {
    Clear-BootstrapAzureSubscriptionContext
    if ($lock) { $lock.Dispose() }
}
