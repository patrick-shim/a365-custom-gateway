Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This module is invoked under bootstrap's existing deployment lock. It never
# upgrades a completed older deployment or uses a recovery receipt as authority.
# Each external dispatch has its own persisted intent. Unknown outcomes are
# read-only reconciliation, including absence after a lost response.
function Invoke-PurviewBootstrapOnce {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Operations,
        [Parameter(Mandatory)][Alias('Name')][string]$OperationName,
        [Parameter(Mandatory)][Collections.IDictionary]$Intent,
        [Parameter(Mandatory)][scriptblock]$Checkpoint,
        [Parameter(Mandatory)][scriptblock]$Discover,
        [Parameter(Mandatory)][scriptblock]$Mutate,
        [switch]$ReadOnly
    )
    $fingerprint = Get-BootstrapObjectFingerprint -InputObject $Intent
    $operation = if ($Operations.Contains($OperationName)) { $Operations[$OperationName] } else { $null }
    if ($null -ne $operation -and (
        $operation -isnot [Collections.IDictionary] -or
        [string]$operation.intentFingerprint -cne $fingerprint -or
        [string]$operation.status -cnotin @('Started', 'Completed'))) {
        throw 'Purview executor mutation intent changed or is invalid.'
    }
    # Discover callbacks return only independently validated safe identifiers.
    # A null return means proven absence, not unavailable/unknown/malformed.
    $observed = & $Discover
    if ($null -ne $observed) {
        if ($null -eq $operation) { throw 'An unowned Purview executor resource already exists.' }
        $observedFingerprint = Get-BootstrapObjectFingerprint -InputObject $observed
        if ([string]$operation.status -ceq 'Completed' -and
            [string]$operation.evidenceFingerprint -cne $observedFingerprint) {
            throw 'Purview executor exact readback changed after completion.'
        }
        if (-not $ReadOnly -and [string]$operation.status -cne 'Completed') {
            $operation.status = 'Completed'
            $operation.evidenceFingerprint = $observedFingerprint
            & $Checkpoint | Out-Null
        }
        return $observed
    }
    if ($null -ne $operation) { throw 'Purview executor dispatch is ambiguous or its resource disappeared; automatic resubmission is forbidden.' }
    if ($ReadOnly) { throw 'Purview executor exact resource is absent during verification.' }
    $operation = [ordered]@{ intentFingerprint = $fingerprint; status = 'Started' }
    $Operations[$OperationName] = $operation
    & $Checkpoint | Out-Null
    & $Mutate | Out-Null
    $observed = & $Discover
    if ($null -eq $observed) { throw 'Purview executor dispatch is ambiguous; exact readback is not yet available. Resume without resubmission.' }
    $operation.status = 'Completed'
    $operation.evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $observed
    & $Checkpoint | Out-Null
    return $observed
}

function Assert-PurviewExecutorEqual {
    param([AllowNull()]$Actual, [AllowNull()]$Expected, [Parameter(Mandatory)][string]$Label)
    if ((Get-BootstrapObjectFingerprint -InputObject $Actual) -cne
        (Get-BootstrapObjectFingerprint -InputObject $Expected)) {
        throw "Purview executor $Label does not match the accepted intent."
    }
}

function Assert-PurviewExecutorEmptyCollection {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $value = $Object.$Name
    if ($value -isnot [Array] -or $value.Count -ne 0) {
        throw "Purview executor $Name must be an independently returned empty collection."
    }
}

function Get-PurviewExecutorRole {
    return [ordered]@{
        id = '14d900aa-8e2f-4bdd-9a28-0741d94bf353'
        value = 'Purview.Executor.Invoke'
        displayName = 'Invoke Purview executor'
        description = 'Invoke the fixed private Purview executor operations.'
        isEnabled = $true
        allowedMemberTypes = @('Application')
    }
}

function Assert-PurviewExecutorRole {
    param([Parameter(Mandatory)]$Object)
    $roles = @(Get-OptionalObjectPropertyValue -InputObject $Object -PropertyName 'appRoles')
    $expected = Get-PurviewExecutorRole
    if ($roles.Count -ne 1 -or $null -eq $roles[0]) { throw 'The executor must expose exactly one application role.' }
    foreach ($field in $expected.Keys) {
        $actual = $roles[0].$field
        Assert-PurviewExecutorEqual -Actual $actual -Expected $expected[$field] -Label "application role $field"
    }
}

function Get-PurviewExecutorApplication {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Tags)
    $app = Get-ExactApplicationByDisplayName -DisplayName $Name
    if ($null -eq $app) { return $null }
    Assert-GuidValue -Value ([string]$app.id) -Label 'Executor application object ID'
    Assert-GuidValue -Value ([string]$app.appId) -Label 'Executor application client ID'
    if ([string]$app.displayName -cne $Name -or [string]$app.signInAudience -cne 'AzureADMyOrg' -or
        -not (Test-ExactStringSet -Actual @($app.tags) -Expected $Tags) -or
        $app.api.requestedAccessTokenVersion -ne 2) { throw 'Executor application ownership or audience is invalid.' }
    Assert-ExactApplicationAuthenticationSurface -Application $app -ApplicationLabel 'Purview executor' | Out-Null
    Assert-PurviewExecutorRole -Object $app
    foreach ($property in @('requiredResourceAccess', 'passwordCredentials', 'keyCredentials')) {
        Assert-PurviewExecutorEmptyCollection -Object $app -Name $property
    }
    foreach ($platform in @('web', 'spa', 'publicClient')) {
        Assert-PurviewExecutorEmptyCollection -Object $app.$platform -Name 'redirectUris'
    }
    Assert-PurviewExecutorEmptyCollection -Object $app.api -Name 'oauth2PermissionScopes'
    $uris = @($app.identifierUris)
    if ($uris.Count -gt 1 -or ($uris.Count -eq 1 -and [string]$uris[0] -cne "api://$($app.appId)")) {
        throw 'Executor application exposes an unapproved audience.'
    }
    $federations = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/applications/$($app.id)/federatedIdentityCredentials")
    if ($federations.Count -ne 0) { throw 'Executor API application must not have federation credentials.' }
    return $app
}

function Ensure-PurviewExecutorIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Context,
        [Parameter(Mandatory)][Collections.IDictionary]$Operations,
        [Parameter(Mandatory)][scriptblock]$Checkpoint,
        [switch]$ReadOnly
    )
    $name = "A365 Gateway Purview Executor - $($Context.deploymentOwnershipId)"
    $tags = @(Get-BootstrapApplicationTags -DeploymentOwnershipId $Context.deploymentOwnershipId) +
        @("A365GatewaySource:$($Context.sourceFingerprint)", 'A365GatewayPurviewExecutor')
    $role = Get-PurviewExecutorRole
    $once = @{ Operations = $Operations; Checkpoint = $Checkpoint; ReadOnly = $ReadOnly }
    $application = Invoke-PurviewBootstrapOnce @once -Name application -Intent @{
        name = $name; tags = $tags; role = $role; tenantId = $Context.tenantId
    } -Discover {
        $app = Get-PurviewExecutorApplication -Name $name -Tags $tags
        if ($null -ne $app) { return [ordered]@{ objectId = [string]$app.id; applicationId = [string]$app.appId } }
    } -Mutate {
        # Microsoft Graph v1.0 application creation. No delegated scope or credential.
        Invoke-GraphJsonBody -Method POST -Url 'https://graph.microsoft.com/v1.0/applications' -Body @{
            displayName = $name; signInAudience = 'AzureADMyOrg'; tags = $tags
            isFallbackPublicClient = $false; identifierUris = @()
            api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(); acceptMappedClaims = $false }
            appRoles = @($role); requiredResourceAccess = @()
            web = @{ redirectUris = @(); implicitGrantSettings = @{ enableAccessTokenIssuance = $false; enableIdTokenIssuance = $false } }
            spa = @{ redirectUris = @() }; publicClient = @{ redirectUris = @() }
        } | Out-Null
    }
    $null = Invoke-PurviewBootstrapOnce @once -Name audience -Intent @{
        objectId = $application.objectId; audience = "api://$($application.applicationId)"
    } -Discover {
        $app = Get-PurviewExecutorApplication -Name $name -Tags $tags
        if ($null -eq $app -or [string]$app.id -cne $application.objectId -or
            [string]$app.appId -cne $application.applicationId) { throw 'Executor application identity changed.' }
        if (@($app.identifierUris).Count -eq 1) { return @{ audience = [string]$app.identifierUris[0] } }
    } -Mutate {
        Invoke-GraphJsonBody -Method PATCH -Url "https://graph.microsoft.com/v1.0/applications/$($application.objectId)" `
            -Body @{ identifierUris = @("api://$($application.applicationId)") } | Out-Null
    }
    $principal = Invoke-PurviewBootstrapOnce @once -Name principal -Intent @{
        applicationId = $application.applicationId; tags = $tags; assignmentRequired = $true
    } -Discover {
        $sp = Get-ServicePrincipalByAppId -AppId $application.applicationId
        if ($null -eq $sp) { return $null }
        Assert-GuidValue -Value ([string]$sp.id) -Label 'Executor API service principal'
        if ([string]$sp.appId -cne $application.applicationId -or
            [string]$sp.servicePrincipalType -cne 'Application' -or
            $sp.accountEnabled -ne $true -or $sp.appRoleAssignmentRequired -ne $true -or
            -not (Test-ExactStringSet -Actual @($sp.tags) -Expected $tags) -or
            -not (Test-ExactStringSet -Actual @($sp.servicePrincipalNames) -Expected @($application.applicationId, "api://$($application.applicationId)"))) {
            throw 'Executor API service principal authority is not exact.'
        }
        Assert-PurviewExecutorRole -Object $sp
        foreach ($property in @('passwordCredentials', 'keyCredentials', 'oauth2PermissionScopes', 'alternativeNames')) {
            Assert-PurviewExecutorEmptyCollection -Object $sp -Name $property
        }
        foreach ($suffix in @('appRoleAssignments', 'transitiveMemberOf')) {
            if (@(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/$suffix").Count -ne 0) {
                throw 'Executor API service principal has unapproved downstream authority.'
            }
        }
        return [ordered]@{ objectId = [string]$sp.id; applicationId = [string]$sp.appId }
    } -Mutate {
        Invoke-GraphJsonBody -Method POST -Url 'https://graph.microsoft.com/v1.0/servicePrincipals' -Body @{
            appId = $application.applicationId; accountEnabled = $true; appRoleAssignmentRequired = $true; tags = $tags
        } | Out-Null
    }
    # Read the exact worker principal, never adopt a display-name match or a UAMI.
    $worker = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url',
        "https://graph.microsoft.com/v1.0/servicePrincipals/$($Context.workerPrincipalId)?`$select=id,appId,servicePrincipalType")
    if ([string]$worker.id -cne $Context.workerPrincipalId -or [string]$worker.appId -cne $Context.workerApplicationId -or
        [string]$worker.servicePrincipalType -cne 'ManagedIdentity') { throw 'The exact executor caller is not the accepted worker managed identity.' }
    $assignment = Invoke-PurviewBootstrapOnce @once -Name invokeRole -Intent @{
        principalId = $Context.workerPrincipalId; resourceId = $principal.objectId; appRoleId = $role.id
    } -Discover {
        $assignments = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.objectId)/appRoleAssignedTo")
        if ($assignments.Count -eq 0) { return $null }
        if ($assignments.Count -ne 1 -or [string]$assignments[0].principalId -cne $Context.workerPrincipalId -or
            [string]$assignments[0].resourceId -cne $principal.objectId -or
            [string]$assignments[0].appRoleId -cne $role.id -or [string]$assignments[0].principalType -cne 'ServicePrincipal') {
            throw 'Executor invoke authority must belong only to the exact worker.'
        }
        return [ordered]@{ id = [string]$assignments[0].id }
    } -Mutate {
        Invoke-GraphJsonBody -Method POST -Url "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.objectId)/appRoleAssignedTo" `
            -Body @{ principalId = $Context.workerPrincipalId; resourceId = $principal.objectId; appRoleId = $role.id } | Out-Null
    }
    return [ordered]@{
        applicationObjectId = $application.objectId; applicationId = $application.applicationId
        servicePrincipalId = $principal.objectId; roleAssignmentId = $assignment.id
    }
}

function Invoke-PurviewExecutorDeployment {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][Collections.IDictionary]$Parameters,
        [Parameter(Mandatory)][Collections.IDictionary]$Operations,
        [Parameter(Mandatory)][scriptblock]$Checkpoint,
        [AllowNull()][Collections.IDictionary]$PublisherRecoveryState,
        [switch]$ReadOnly
    )
    $root = Get-BootstrapExecutionSourceRoot
    if ($null -ne $PublisherRecoveryState -and $PublisherRecoveryState.Contains('publisherMetadataReconciliation')) {
        $root = Get-BootstrapAssetSourceRoot -State $PublisherRecoveryState `
            -ExecutionSourceFingerprint $PublisherRecoveryState.publisherMetadataReconciliation.plan.correctedSourceFingerprint `
            -DeploymentSourceFingerprint $PublisherRecoveryState.acceptedPlan.sourceFingerprint
    }
    $templatePath = Join-Path $root $Template
    $templateHash = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    return Invoke-PurviewBootstrapOnce -Operations $Operations -Name $Name `
        -Intent @{ templateSha256 = $templateHash; parameters = $Parameters } -Checkpoint $Checkpoint -ReadOnly:$ReadOnly `
        -Discover {
            $matches = @(Invoke-AzJsonArray -OperationLabel 'Exact executor ARM deployment discovery' -Arguments @(
                'deployment', 'group', 'list', '--subscription', $Config.subscriptionId,
                '--resource-group', $Config.resourceGroupName, '--query', "[?name=='$Name'].{name:name}"))
            if ($matches.Count -eq 0) { return $null }
            if ($matches.Count -ne 1 -or [string]$matches[0].name -cne $Name) { throw 'Executor ARM deployment discovery is ambiguous.' }
            $deployment = Invoke-AzJson -Arguments @(
                'deployment', 'group', 'show', '--subscription', $Config.subscriptionId,
                '--resource-group', $Config.resourceGroupName, '--name', $Name,
                '--query', '{state:properties.provisioningState,parameters:properties.parameters,outputs:properties.outputs}')
            if ([string]$deployment.state -cne 'Succeeded') { throw 'The exact executor deployment is not Succeeded; no repeat deployment was submitted.' }
            Assert-GatewayExactReadableArmParameters -ActualParameters $deployment.parameters -ExpectedParameters $Parameters | Out-Null
            # Templates contain only safe identifiers/configuration in their outputs.
            return $deployment.outputs | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable -Depth 30
        } -Mutate {
            Invoke-ArmDeploymentWithSecureParameters -SubscriptionId $Config.subscriptionId -ResourceGroup $Config.resourceGroupName `
                -Name $Name -TemplateFile $templatePath -Parameters $Parameters | Out-Null
        }
}

function Build-PurviewExecutorPublisher {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][Collections.IDictionary]$Record,
        [Parameter(Mandatory)][scriptblock]$Checkpoint,
        [AllowNull()][Collections.IDictionary]$PublisherRecoveryState,
        [switch]$ReadOnly
    )
    $context = $Record.context
    $registry = [string]$Foundation.acrName
    $repository = 'gateway-purview-package-publisher'
    $tag = Get-BootstrapImageBuildIntentTag -DeploymentOwnershipId $context.deploymentOwnershipId `
        -SourceFingerprint $context.sourceFingerprint -IntentId $Record.intentId
    return Invoke-PurviewBootstrapOnce -Operations $Record.operations -Name publisherImage `
        -Intent @{ registry = $registry; repository = $repository; tag = $tag; receiptFingerprint = $Record.package.receiptFingerprint } `
        -Checkpoint $Checkpoint -ReadOnly:$ReadOnly -Discover {
            $runs = @(Get-GatewayAcrExactImageRuns -Registry $registry -Repository $repository -Tag $tag)
            if ($runs.Count -eq 0) {
                if ($null -ne (Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag)) {
                    throw 'An executor publisher image has no exact source-bound build run.'
                }
                return $null
            }
            if ($runs.Count -ne 1) { throw 'The publisher has multiple builds for one durable intent.' }
            $run = Get-GatewayAcrExactRunById -Registry $registry -Repository $repository -Tag $tag -RunId $runs[0].runId
            $run = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository $repository -Tag $tag
            $digest = [string]$run.outputImages[0].digest
            $image = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag
            if ($null -eq $image -or [string]$image.digest -cne $digest) { throw 'Publisher immutable image differs from its exact ACR run.' }
            return [ordered]@{ digest = $digest; runId = [string]$run.runId }
        } -Mutate {
            $root = Get-BootstrapExecutionSourceRoot
            if ($null -ne $PublisherRecoveryState -and $PublisherRecoveryState.Contains('publisherMetadataReconciliation')) {
                $root = Get-BootstrapAssetSourceRoot -State $PublisherRecoveryState `
                    -ExecutionSourceFingerprint $PublisherRecoveryState.publisherMetadataReconciliation.plan.correctedSourceFingerprint `
                    -DeploymentSourceFingerprint $context.sourceFingerprint
                throw 'Publisher metadata reconciliation never authorizes rebuilding the existing publisher image.'
            }
            $buildContext = New-PurviewPublisherBuildContext -RepositoryRoot $root -SourceFingerprint $context.sourceFingerprint `
                -PackageDirectory $Record.packageDirectory -ExpectedReceiptFingerprint $Record.package.receiptFingerprint `
                -OutputDirectory (Join-Path $root ".bootstrap/purview-publisher/$([guid]::NewGuid().ToString('D'))")
            Invoke-AzJson -CaptureStdoutOnly -Arguments @(
                'acr', 'build', '--subscription', $Config.subscriptionId, '--registry', $registry,
                '--image', "${repository}:$tag", '--file', 'src/Gateway.Purview.PackagePublisher/Dockerfile',
                $buildContext, '--no-logs', '--query',
                '{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}}') | Out-Null
        }
}

function Get-PurviewExecutorArmScope {
    param([Parameter(Mandatory)][string]$Id)
    # These non-secret identifiers are established by Common's context setter.
    # An --ids argument can override the CLI default subscription: bind both it
    # and the explicit selector before entering Common's independent scope guard.
    $subscription = [Environment]::GetEnvironmentVariable('A365GW_BOOTSTRAP_SUBSCRIPTION_ID', 'Process')
    $tenant = [Environment]::GetEnvironmentVariable('A365GW_BOOTSTRAP_TENANT_ID', 'Process')
    if ([string]::IsNullOrWhiteSpace($subscription) -or [string]::IsNullOrWhiteSpace($tenant)) {
        throw 'Executor ARM reads require the initialized exact subscription and tenant context.'
    }
    Assert-GuidValue -Value $subscription -Label 'Executor ARM subscription context'
    Assert-GuidValue -Value $tenant -Label 'Executor ARM tenant context'
    if ($Id -notmatch '^/subscriptions/(?<subscription>[0-9a-f-]{36})/resourceGroups/(?<group>[A-Za-z0-9_.()-]+)/providers/(?<path>Microsoft\.[A-Za-z0-9]+(?:/[A-Za-z0-9_.()-]+){2,})$' -or
        $Id -match '(?:^|/)\.{1,2}(?:/|$)') {
        throw 'Executor ARM resource ID is not a supported scoped resource path.'
    }
    if ([string]$Matches.subscription -cne $subscription) {
        throw 'Executor ARM resource ID differs from the scoped subscription.'
    }
    return @{ subscriptionId = $subscription; resourceGroup = [string]$Matches.group; resourcePath = [string]$Matches.path }
}

function Get-PurviewExecutorArmResource {
    param([Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidatePattern('^20\d{2}-\d{2}-\d{2}(-preview)?$')][string]$ApiVersion)
    $scope = Get-PurviewExecutorArmScope -Id $Id
    # Common's rest-shaped lane is exclusively Graph, including when stdout-only
    # capture is requested. Use the guarded native ARM command families instead.
    # A collection is not a complete --ids resource. These three documented list
    # commands consume their management-plane pagers; never set --top/--max-items.
    $listArguments = switch -Regex ($scope.resourcePath) {
        '^Microsoft.Network/privateEndpoints/(?<name>[^/]+)/privateDnsZoneGroups$' {
            @('network', 'private-endpoint', 'dns-zone-group', 'list', '--endpoint-name', $Matches.name)
        }
        '^Microsoft.Network/privateDnsZones/(?<name>[^/]+)/virtualNetworkLinks$' {
            @('network', 'private-dns', 'link', 'vnet', 'list', '--zone-name', $Matches.name)
        }
        '^Microsoft.Storage/storageAccounts/(?<name>[^/]+)/blobServices/default/containers$' {
            @('storage', 'container-rm', 'list', '--storage-account', $Matches.name)
        }
    }
    if ($null -ne $listArguments) {
        $listing = Invoke-AzJson -CaptureStdoutOnly -Arguments ($listArguments + @(
                '--subscription', $scope.subscriptionId, '--resource-group', $scope.resourceGroup, '--query', '{value:@}'))
        Assert-PurviewExecutorCompleteArmCollection -Collection $listing
        $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $listing.value) {
            $childId = [string](Get-OptionalObjectPropertyValue -InputObject $entry -PropertyName 'id')
            if ($childId -notmatch ('^' + [regex]::Escape($Id) + '/[A-Za-z0-9_.()-]+$') -or -not $ids.Add($childId)) {
                throw 'Executor ARM collection has an unknown, duplicate or out-of-scope child ID.'
            }
        }
        # Specialized CLI serializers flatten properties. Independently read each
        # exact child through generic resource GET to retain the ARM shape expected
        # by the existing ownership, network and DNS guards. Validate ALL IDs first.
        $resources = [Collections.Generic.List[object]]::new()
        foreach ($entry in $listing.value) {
            $resources.Add((Get-PurviewExecutorArmResource -Id ([string]$entry.id) -ApiVersion $ApiVersion))
        }
        return [pscustomobject]@{ value = $resources.ToArray() }
    }
    if (($scope.resourcePath.Split('/').Count % 2) -ne 1) {
        throw 'Executor ARM collection type is outside the reviewed read boundary.'
    }
    # Never list app settings, publishing profiles, keys or certificate values.
    $resource = Invoke-AzJson -CaptureStdoutOnly -Arguments @(
        'resource', 'show', '--subscription', $scope.subscriptionId, '--ids', $Id, '--api-version', $ApiVersion)
    if ($null -eq $resource -or $resource -is [Array] -or
        -not ([string](Get-OptionalObjectPropertyValue -InputObject $resource -PropertyName 'id')).Equals($Id, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Executor ARM resource readback is absent, unknown or differs from the exact requested ID.'
    }
    return $resource
}

function Get-PurviewExecutorArmSettings {
    param([Parameter(Mandatory)][string]$SiteId)
    $scope = Get-PurviewExecutorArmScope -Id $SiteId
    if ($scope.resourcePath -notmatch '^Microsoft.Web/sites/[A-Za-z0-9-]+$') {
        throw 'Executor settings read requires the exact owned Web site resource ID.'
    }
    # This fixed POST/list is a read action, not a configuration mutation. The
    # caller has already verified host ownership and the non-secret-only template.
    return Invoke-AzJson -CaptureStdoutOnly -Arguments @(
        'resource', 'invoke-action', '--subscription', $scope.subscriptionId,
        '--ids', "$SiteId/config/appsettings", '--action', 'list', '--api-version', '2024-11-01', '--query', 'properties')
}

function Assert-PurviewExecutorCompleteArmCollection {
    param([Parameter(Mandatory)]$Collection)
    if ($Collection.value -isnot [Array] -or
        -not [string]::IsNullOrEmpty([string](Get-OptionalObjectPropertyValue -InputObject $Collection -PropertyName 'nextLink'))) {
        throw 'Executor ARM collection is unknown or truncated; exact absence/cardinality is not proven.'
    }
}

function Assert-PurviewExecutorOwnedResource {
    param([Parameter(Mandatory)]$Resource, [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][Collections.IDictionary]$Context)
    if (-not ([string]$Resource.id).Equals($Id, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$Resource.tags.bootstrapOwnershipId -cne $Context.deploymentOwnershipId -or
        [string]$Resource.tags.bootstrapSourceFingerprint -cne $Context.sourceFingerprint) {
        throw 'Executor infrastructure ownership/source readback is not exact.'
    }
}

function Get-PurviewExecutorStorageNetwork {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Runtime, [Parameter(Mandatory)][Collections.IDictionary]$Context)
    $storageId = [string]$Runtime.storageAccountId
    $storage = Get-PurviewExecutorArmResource -Id $storageId -ApiVersion '2023-05-01'
    Assert-PurviewExecutorOwnedResource -Resource $storage -Id $storageId -Context $Context
    if ([string]$storage.properties.publicNetworkAccess -cne 'Disabled' -or
        $storage.properties.allowBlobPublicAccess -ne $false -or $storage.properties.allowSharedKeyAccess -ne $false) {
        throw 'Executor package storage must be private, nonpublic and Entra-only before publication.'
    }
    $connections = @($storage.properties.privateEndpointConnections)
    $blobConnections = [Collections.Generic.List[object]]::new()
    foreach ($connection in $connections) {
        if ([string]$connection.properties.privateLinkServiceConnectionState.status -cne 'Approved') {
            throw 'Executor storage private endpoint connection is not approved.'
        }
        $endpointId = [string]$connection.properties.privateEndpoint.id
        $prefix = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.Network/privateEndpoints/"
        if (-not $endpointId.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Storage private endpoint is outside the deployment.' }
        $endpoint = Get-PurviewExecutorArmResource -Id $endpointId -ApiVersion '2023-11-01'
        Assert-PurviewExecutorOwnedResource -Resource $endpoint -Id $endpointId -Context $Context
        $links = @($endpoint.properties.privateLinkServiceConnections)
        if ($links.Count -ne 1 -or [string]$endpoint.properties.subnet.id -cne $Foundation.privateEndpointSubnetId -or
            [string]$links[0].properties.privateLinkServiceId -cne $storageId -or
            [string]$links[0].properties.privateLinkServiceConnectionState.status -cne 'Approved') {
            throw 'Storage private endpoint network identity is not exact.'
        }
        if ((@($links[0].properties.groupIds) -join '|') -ceq 'blob') { $blobConnections.Add($endpoint) }
        else { throw 'An unreviewed storage private endpoint exists.' }
    }
    if ($blobConnections.Count -ne 1) { throw 'Exactly one owned Blob private endpoint is required.' }
    $blobEndpoint = $blobConnections[0]
    $nics = @($blobEndpoint.properties.networkInterfaces)
    if ($nics.Count -ne 1) { throw 'Blob private endpoint must have exactly one network interface.' }
    $nic = Get-PurviewExecutorArmResource -Id ([string]$nics[0].id) -ApiVersion '2023-11-01'
    $configs = @($nic.properties.ipConfigurations)
    if ($configs.Count -ne 1 -or [string]$configs[0].properties.subnet.id -cne $Foundation.privateEndpointSubnetId) {
        throw 'Blob private endpoint IP or NIC subnet is ambiguous.'
    }
    $ip = [string]$configs[0].properties.privateIPAddress
    $parsed = [Net.IPAddress]::None
    if (-not [Net.IPAddress]::TryParse($ip, [ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $ip -notmatch '^10\.42\.2\.\d{1,3}$') { throw 'Blob private endpoint IP is outside the reviewed private subnet.' }
    $scope = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)"
    $zoneId = "$scope/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    $groups = Get-PurviewExecutorArmResource -Id "$($blobEndpoint.id)/privateDnsZoneGroups" -ApiVersion '2023-11-01'
    Assert-PurviewExecutorCompleteArmCollection -Collection $groups
    $zoneGroups = @($groups.value)
    if ($zoneGroups.Count -ne 1 -or @($zoneGroups[0].properties.privateDnsZoneConfigs).Count -ne 1 -or
        [string]$zoneGroups[0].properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId -cne $zoneId) {
        throw 'Blob private DNS zone group is not exact.'
    }
    $links = Get-PurviewExecutorArmResource -Id "$zoneId/virtualNetworkLinks" -ApiVersion '2020-06-01'
    Assert-PurviewExecutorCompleteArmCollection -Collection $links
    $vnetId = "$scope/providers/Microsoft.Network/virtualNetworks/$($Foundation.virtualNetworkName)"
    $vnet = Get-PurviewExecutorArmResource -Id $vnetId -ApiVersion '2023-11-01'
    Assert-PurviewExecutorOwnedResource -Resource $vnet -Id $vnetId -Context $Context
    if ((@($vnet.properties.addressSpace.addressPrefixes) -join '|') -cne '10.42.0.0/16') {
        throw 'Executor network address space differs from the accepted foundation.'
    }
    if (@($links.value).Count -ne 1 -or [string]$links.value[0].properties.virtualNetwork.id -cne $vnetId -or
        $links.value[0].properties.registrationEnabled -ne $false -or
        [string]$links.value[0].properties.virtualNetworkLinkState -cne 'Completed') { throw 'Blob private DNS network link is not exact.' }
    $record = Get-PurviewExecutorArmResource -Id "$zoneId/A/$($storage.name)" -ApiVersion '2020-06-01'
    if (@($record.properties.aRecords).Count -ne 1 -or [string]$record.properties.aRecords[0].ipv4Address -cne $ip) {
        throw 'Blob private DNS address does not match the exact endpoint.'
    }
    $environment = Get-PurviewExecutorArmResource -Id $Foundation.containerAppsEnvironmentId -ApiVersion '2025-01-01'
    Assert-PurviewExecutorOwnedResource -Resource $environment -Id $Foundation.containerAppsEnvironmentId -Context $Context
    if ([string]$environment.properties.vnetConfiguration.infrastructureSubnetId -cne "$vnetId/subnets/snet-container-apps") {
        throw 'Publisher Container Apps environment is outside the owned private network.'
    }
    return [ordered]@{ storageAccountName = [string]$storage.name; privateEndpointIp = $ip }
}

function Assert-PurviewExecutorRoles {
    param([Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][object[]]$Expected)
    $roles = @(Invoke-AzJsonArray -OperationLabel 'Executor exact scoped Azure roles' -Arguments @(
        'role', 'assignment', 'list', '--assignee-object-id', $PrincipalId, '--all', '--include-inherited',
        '--query', '[].{principalId:principalId,scope:scope,roleDefinitionId:roleDefinitionId}'))
    if ($roles.Count -ne $Expected.Count) { throw 'Executor or publisher has missing or excess Azure authority.' }
    foreach ($entry in $Expected) {
        $matches = @($roles | Where-Object {
            [string]$_.principalId -ceq $PrincipalId -and
            ([string]$_.scope).Equals([string]$entry.scope, [StringComparison]::OrdinalIgnoreCase) -and
            ([string]$_.roleDefinitionId).EndsWith("/$($entry.role)", [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -ne 1) { throw 'Executor or publisher Azure role scope is not exact.' }
    }
    foreach ($suffix in @('appRoleAssignments', 'transitiveMemberOf')) {
        if (@(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/$suffix").Count -ne 0) {
            throw 'Executor or publisher system identity has unapproved directory authority.'
        }
    }
}

function Assert-PurviewExecutorHost {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][Collections.IDictionary]$Record, [switch]$Enabled)
    $context = $Record.context
    $outputs = $Record.host
    $siteId = [string]$outputs.executorId.value
    $site = Get-PurviewExecutorArmResource -Id $siteId -ApiVersion '2024-11-01'
    Assert-PurviewExecutorOwnedResource -Resource $site -Id $siteId -Context $context
    if ([string]$site.tags.purviewExecutionSourceFingerprint -cne $context.sourceFingerprint -or
        [string]$site.identity.type -cne 'SystemAssigned' -or
        [string]$site.identity.principalId -cne [string]$outputs.executorPrincipalId.value -or
        [string]$site.properties.publicNetworkAccess -cne 'Disabled' -or $site.properties.httpsOnly -ne $true -or
        $site.properties.enabled -ne [bool]$Enabled -or
        [string]$site.properties.virtualNetworkSubnetId -cne [string]$outputs.integrationSubnetId.value -or
        [string]$outputs.executorEndpoint.value -cne "https://$($site.properties.defaultHostName)") {
        throw 'Private Windows host readback differs from the accepted identity/network intent.'
    }
    $binding = $outputs.executorBinding.value
    $planId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.Web/serverfarms/asp-$($Config.projectName)-$($Config.environment)-purview"
    $plan = Get-PurviewExecutorArmResource -Id $planId -ApiVersion '2024-11-01'
    Assert-PurviewExecutorOwnedResource -Resource $plan -Id $planId -Context $context
    if (-not ([string]$site.properties.serverFarmId).Equals($planId, [StringComparison]::OrdinalIgnoreCase) -or
        $plan.properties.reserved -ne $false -or [string]$plan.sku.name -cne 'B1' -or $plan.sku.capacity -ne 1 -or
        $site.properties.outboundVnetRouting.allTraffic -ne $true) { throw 'Executor must use the owned Windows plan and private outbound routing.' }
    $subnet = Get-PurviewExecutorArmResource -Id $outputs.integrationSubnetId.value -ApiVersion '2023-11-01'
    if ([string]$subnet.properties.addressPrefix -cne '10.42.3.0/26' -or
        @($subnet.properties.delegations).Count -ne 1 -or
        [string]$subnet.properties.delegations[0].properties.serviceName -cne 'Microsoft.Web/serverFarms') {
        throw 'Executor integration subnet is not the dedicated reviewed delegation.'
    }
    $expectedBinding = [ordered]@{
        DeploymentOwnershipId = $context.deploymentOwnershipId; TenantId = $context.tenantId
        BootstrapSourceFingerprint = $context.sourceFingerprint; ExecutionSourceFingerprint = $context.sourceFingerprint
        PackageDigest = $Record.package.receipt.packageDigest
        AutomationApplicationId = $context.automationApplicationId
        AutomationServicePrincipalObjectId = $context.automationServicePrincipalId
        KeyVaultResourceId = $context.keyVaultResourceId; CertificateName = $context.certificateName
        CertificateSecretUri = $context.certificateSecretUri
        GatewayApiPrincipalId = $context.apiPrincipalId; GatewayWorkerPrincipalId = $context.workerPrincipalId
        RuntimeClientId = $context.runtimeClientId; RuntimePrincipalId = $context.runtimePrincipalId
        ExecutorApplicationId = $Record.identity.applicationId; ExecutorPrincipalId = [string]$site.identity.principalId
        CallerApplicationId = $context.workerApplicationId
    }
    Assert-PurviewExecutorEqual -Actual $binding -Expected $expectedBinding -Label 'host binding'
    if ([string]$binding.ExecutorPrincipalId -cin @($context.apiPrincipalId, $context.workerPrincipalId, $context.runtimePrincipalId)) {
        throw 'Executor system identity is not independent.'
    }
    $auth = Get-PurviewExecutorArmResource -Id "$siteId/config/authsettingsV2" -ApiVersion '2024-11-01'
    $aad = $auth.properties.identityProviders.azureActiveDirectory
    if ($auth.properties.platform.enabled -ne $true -or $auth.properties.globalValidation.requireAuthentication -ne $true -or
        [string]$auth.properties.globalValidation.unauthenticatedClientAction -cne 'Return401' -or
        $aad.enabled -ne $true -or [string]$aad.registration.clientId -cne $Record.identity.applicationId -or
        [string]$aad.registration.openIdIssuer -cne "https://login.microsoftonline.com/$($context.tenantId)/v2.0" -or
        (@($aad.validation.allowedAudiences) -join '|') -cne $Record.identity.applicationId -or
        (@($aad.validation.defaultAuthorizationPolicy.allowedApplications) -join '|') -cne $context.workerApplicationId -or
        (@($aad.validation.defaultAuthorizationPolicy.allowedPrincipals.identities) -join '|') -cne $context.workerPrincipalId -or
        $auth.properties.login.tokenStore.enabled -ne $false) { throw 'Executor platform authentication is not restricted to the exact worker.' }
    foreach ($name in @('ftp', 'scm')) {
        $policy = Get-PurviewExecutorArmResource -Id "$siteId/basicPublishingCredentialsPolicies/$name" -ApiVersion '2024-11-01'
        if ($policy.properties.allow -ne $false) { throw 'Executor basic publishing must remain disabled.' }
    }
    $web = Get-PurviewExecutorArmResource -Id "$siteId/config/web" -ApiVersion '2024-11-01'
    if ([string]$web.properties.ftpsState -cne 'Disabled' -or $web.properties.use32BitWorkerProcess -ne $false -or
        $web.properties.remoteDebuggingEnabled -ne $false -or $web.properties.httpLoggingEnabled -ne $false -or
        $web.properties.detailedErrorLoggingEnabled -ne $false -or $web.properties.requestTracingEnabled -ne $false -or
        [string]$web.properties.minTlsVersion -cne '1.2') { throw 'Executor Windows runtime settings are not exact.' }
    $endpoint = Get-PurviewExecutorArmResource -Id $outputs.privateEndpointId.value -ApiVersion '2023-11-01'
    Assert-PurviewExecutorOwnedResource -Resource $endpoint -Id $outputs.privateEndpointId.value -Context $context
    $links = @($endpoint.properties.privateLinkServiceConnections)
    if ([string]$endpoint.properties.subnet.id -cne $Foundation.privateEndpointSubnetId -or $links.Count -ne 1 -or
        [string]$links[0].properties.privateLinkServiceId -cne $siteId -or
        (@($links[0].properties.groupIds) -join '|') -cne 'sites' -or
        [string]$links[0].properties.privateLinkServiceConnectionState.status -cne 'Approved') {
        throw 'Executor private endpoint is not the exact approved sites connection.'
    }
    $zoneGroups = Get-PurviewExecutorArmResource -Id "$($outputs.privateEndpointId.value)/privateDnsZoneGroups" -ApiVersion '2023-11-01'
    Assert-PurviewExecutorCompleteArmCollection -Collection $zoneGroups
    if (@($zoneGroups.value).Count -ne 1 -or @($zoneGroups.value[0].properties.privateDnsZoneConfigs).Count -ne 1 -or
        [string]$zoneGroups.value[0].properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId -cne $outputs.privateDnsZoneId.value) {
        throw 'Executor private DNS group differs from the accepted zone.'
    }
    $zoneLinks = Get-PurviewExecutorArmResource -Id "$($outputs.privateDnsZoneId.value)/virtualNetworkLinks" -ApiVersion '2020-06-01'
    Assert-PurviewExecutorCompleteArmCollection -Collection $zoneLinks
    $vnetId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($Foundation.virtualNetworkName)"
    if (@($zoneLinks.value).Count -ne 1 -or [string]$zoneLinks.value[0].properties.virtualNetwork.id -cne $vnetId -or
        $zoneLinks.value[0].properties.registrationEnabled -ne $false -or
        [string]$zoneLinks.value[0].properties.virtualNetworkLinkState -cne 'Completed') { throw 'Executor private DNS network link is not exact.' }
    $nics = @($endpoint.properties.networkInterfaces)
    if ($nics.Count -ne 1) { throw 'Executor private endpoint NIC is ambiguous.' }
    $nic = Get-PurviewExecutorArmResource -Id $nics[0].id -ApiVersion '2023-11-01'
    $ips = @($nic.properties.ipConfigurations)
    if ($ips.Count -ne 1 -or [string]$ips[0].properties.subnet.id -cne $Foundation.privateEndpointSubnetId) {
        throw 'Executor private endpoint address or NIC subnet is ambiguous.'
    }
    foreach ($recordName in @([string]$site.name, "$($site.name).scm")) {
        $dnsRecord = Get-PurviewExecutorArmResource -Id "$($outputs.privateDnsZoneId.value)/A/$recordName" -ApiVersion '2020-06-01'
        if (@($dnsRecord.properties.aRecords).Count -ne 1 -or
            [string]$dnsRecord.properties.aRecords[0].ipv4Address -cne [string]$ips[0].properties.privateIPAddress) {
            throw 'Executor app and SCM must resolve to the exact private endpoint.'
        }
    }
    Assert-PurviewExecutorRoles -PrincipalId ([string]$site.identity.principalId) -Expected @(
        @{ scope = $outputs.packageContainerId.value; role = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' },
        @{ scope = $outputs.claimsContainerId.value; role = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' },
        @{ scope = "$($context.keyVaultResourceId)/secrets/$($context.certificateName)"; role = '4633458b-17de-408a-b874-0445c86b69e6' })
    if ($Enabled) {
        $expectedSettings = [ordered]@{
            WEBSITE_RUN_FROM_PACKAGE = "$($outputs.packageContainerUri.value)/$(([string]$Record.package.receipt.packageDigest).Substring(7)).zip"
            WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID = 'SystemAssigned'; SCM_DO_BUILD_DURING_DEPLOYMENT = 'false'
            DOTNET_EnableDiagnostics = '0'; ASPNETCORE_ENVIRONMENT = 'Production'
            Executor__ClaimsContainerUri = "$($outputs.packageContainerUri.value -replace '/purview-executor-packages$', '/purview-executor-claims')"
            Executor__RuntimeManifestDigest = $Record.package.receipt.runtimeManifestDigest; Executor__OperationTimeoutSeconds = '195'
            Purview__PolicyProvisioningEnabled = 'true'; Purview__PolicyProvisioningOrganization = $context.organization
            Purview__PolicyProvisioningApplicationId = $context.automationApplicationId
            Purview__PolicyProvisioningCertificateSecretUri = $context.certificateSecretUri
            Purview__PolicyProvisioningTimeoutSeconds = '180'
        }
        foreach ($entry in $expectedBinding.GetEnumerator()) { $expectedSettings["Executor__Binding__$($entry.Key)"] = [string]$entry.Value }
        # The owned template contains only non-secret settings. Never request
        # publishing profiles, connection strings or Key Vault data-plane values.
        $settings = Get-PurviewExecutorArmSettings -SiteId $siteId
        Assert-PurviewExecutorEqual -Actual $settings -Expected $expectedSettings -Label 'non-secret host settings'
    }
}

function Assert-PurviewPublisherObjectFields {
    param([AllowNull()]$Object, [string[]]$Required = @(), [string[]]$Optional = @())
    if ($null -eq $Object -or ($Object -isnot [Collections.IDictionary] -and $Object -isnot [pscustomobject])) {
        throw 'Publisher metadata requires a known object shape.'
    }
    $names = @(Get-GatewayArmObjectPropertyNames -Object $Object)
    if (@($Required | Where-Object { $_ -cnotin $names }).Count -ne 0 -or
        @($names | Where-Object { $_ -cnotin @($Required + $Optional) }).Count -ne 0) {
        throw 'Publisher metadata has missing or unreviewed properties.'
    }
}

function Assert-PurviewPublisherEmptyOptionalArray {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $value = Get-GatewayArmObjectProperty -Object $Object -Name $Name
    if ($null -ne $value -and ($value -isnot [Array] -or $value.Count -ne 0)) {
        throw 'Publisher optional execution collections must be absent or empty, never overridden.'
    }
}

function ConvertTo-PurviewPublisherExecutionTemplate {
    param([Parameter(Mandatory)]$Template, [switch]$JobTemplate)
    # The 2025-01-01 ARM JobTemplate and JobExecutionTemplate are different
    # schemas. Only the job has volumes/probes/mounts. Prove those are empty
    # before projecting, and normalize only documented optional empty fields.
    # Never use this projection for persisted intent or provider mutations.
    $templateOptional = @('initContainers')
    if ($JobTemplate) { $templateOptional += 'volumes' }
    Assert-PurviewPublisherObjectFields -Object $Template -Required @('containers') -Optional $templateOptional
    foreach ($name in $templateOptional) { Assert-PurviewPublisherEmptyOptionalArray -Object $Template -Name $name }
    if ($Template.containers -isnot [Array] -or $Template.containers.Count -ne 1) {
        throw 'Publisher execution requires exactly one container.'
    }
    $container = $Template.containers[0]
    $containerOptional = @('command', 'args')
    if ($JobTemplate) { $containerOptional += @('probes', 'volumeMounts') }
    $metadataOptional = @()
    if (-not $JobTemplate) { $metadataOptional += 'imageType' }
    Assert-PurviewPublisherObjectFields -Object $container -Required @('name', 'image', 'resources', 'env') -Optional @($containerOptional + $metadataOptional)
    # Service/schema discrepancy: stable 2025-01-01 executions return imageType,
    # although Jobs.JobExecutionContainer omits it. The official Microsoft.App
    # 2025-02-02-preview CommonDefinitions.BaseContainer enum defines ContainerImage
    # as a user-provided image, distinct from CloudBuild. Accept only that exact
    # execution-side discriminator, not a preview API or an unknown-field bypass.
    if (-not $JobTemplate -and (Test-GatewayArmObjectProperty -Object $container -Name 'imageType')) {
        $imageType = Get-GatewayArmObjectProperty -Object $container -Name 'imageType'
        if ($imageType -isnot [string] -or $imageType -cne 'ContainerImage') {
            throw 'Publisher execution image type is unsupported or unverifiable.'
        }
    }
    foreach ($name in $containerOptional) { Assert-PurviewPublisherEmptyOptionalArray -Object $container -Name $name }
    if ($container.name -isnot [string] -or $container.image -isnot [string] -or $container.env -isnot [Array]) {
        throw 'Publisher execution container metadata is malformed.'
    }
    Assert-PurviewPublisherObjectFields -Object $container.resources -Required @('cpu', 'memory') -Optional @('ephemeralStorage')
    $cpu = $container.resources.cpu
    if (($cpu -isnot [double] -and $cpu -isnot [decimal] -and $cpu -isnot [int] -and $cpu -isnot [long]) -or
        $container.resources.memory -isnot [string]) { throw 'Publisher resource metadata is malformed.' }
    $resources = [ordered]@{ cpu = $cpu; memory = $container.resources.memory }
    $ephemeral = Get-GatewayArmObjectProperty -Object $container.resources -Name 'ephemeralStorage'
    if ($null -ne $ephemeral) {
        if ($ephemeral -isnot [string]) { throw 'Publisher storage metadata is malformed.' }
        $resources.ephemeralStorage = $ephemeral
    }
    $environment = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $container.env) {
        Assert-PurviewPublisherObjectFields -Object $entry -Required @('name', 'value') -Optional @('secretRef')
        $reference = Get-GatewayArmObjectProperty -Object $entry -Name 'secretRef'
        if ($entry.name -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.name) -or $entry.value -isnot [string] -or
            ($null -ne $reference -and ($reference -isnot [string] -or $reference.Length -ne 0)) -or
            -not $environment.TryAdd($entry.name, $entry.value)) {
            throw 'Publisher execution environment is malformed, duplicated or secret-backed.'
        }
    }
    return [ordered]@{ containers = @([ordered]@{
                name = $container.name; image = $container.image; resources = $resources; env = $environment
            }) }
}

function Assert-PurviewPublisherJob {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][Collections.IDictionary]$Record, [Parameter(Mandatory)]$Network)
    $jobId = [string]$Record.publisher.jobId.value
    $job = Get-PurviewExecutorArmResource -Id $jobId -ApiVersion '2025-01-01'
    Assert-PurviewExecutorOwnedResource -Resource $job -Id $jobId -Context $Record.context
    $configuration = $job.properties.configuration
    # Jobs GET exposes the secret metadata collection; Secret.value is explicitly
    # create/update-only in the ARM schema. An explicitly present null is the
    # provider's unconfigured collection shape. Missing metadata is NOT absence.
    # Never call listSecrets or request secret values to repair this readback.
    if (-not (Test-GatewayArmObjectProperty -Object $configuration -Name 'secrets')) {
        throw 'Publisher secret metadata is missing; absence is not proven.'
    }
    $secretMetadata = Get-GatewayArmObjectProperty -Object $configuration -Name 'secrets'
    if ($null -ne $secretMetadata -and ($secretMetadata -isnot [Array] -or $secretMetadata.Count -ne 0)) {
        throw 'Publisher secret metadata must be explicitly null or an empty array.'
    }
    $expectedEnvironmentId = ConvertTo-GatewayCanonicalArmResourceId -ResourceId $Foundation.containerAppsEnvironmentId -Config $Config -Label 'Publisher environment'
    $actualEnvironmentId = ConvertTo-GatewayCanonicalArmResourceId -ResourceId $job.properties.environmentId -Config $Config -Label 'Publisher environment'
    if ([string]$job.identity.type -cne 'SystemAssigned, UserAssigned' -and
        [string]$job.identity.type -cne 'SystemAssigned,UserAssigned') { throw 'Publisher identity envelope is invalid.' }
    if ([string]$job.identity.principalId -cne $Record.publisher.jobPrincipalId.value -or
        $actualEnvironmentId -cne $expectedEnvironmentId -or
        [string]$configuration.triggerType -cne 'Manual' -or $configuration.replicaRetryLimit -ne 0 -or
        $configuration.replicaTimeout -ne 660 -or $configuration.manualTriggerConfig.parallelism -ne 1 -or
        $configuration.manualTriggerConfig.replicaCompletionCount -ne 1) {
        throw 'Publisher must have exact private environment, no secrets and one nonretrying manual execution.'
    }
    $userIdentities = @(Get-GatewayArmObjectPropertyNames -Object $job.identity.userAssignedIdentities)
    $null = Assert-GatewayExactArmIdCollection -Items @($userIdentities | ForEach-Object { @{ id = $_ } }) `
        -ExpectedIds @($Foundation.runtimeImagePullIdentityId) -PropertyName 'id' -Config $Config -Label 'Publisher image-pull identity'
    $null = Assert-GatewayExactContainerRegistry -Registries $configuration.registries `
        -ExpectedServer $Foundation.acrLoginServer -ExpectedIdentity $Foundation.runtimeImagePullIdentityId
    $pullId = ConvertTo-GatewayCanonicalArmResourceId -ResourceId $Foundation.runtimeImagePullIdentityId -Config $Config -Label 'Publisher image-pull identity'
    $settings = Get-GatewayArmObjectProperty -Object $configuration -Name 'identitySettings'
    if ($settings -isnot [Array] -or $settings.Count -ne 2) { throw 'Publisher identity lifecycle cardinality is not exact.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($setting in $settings) {
        Assert-PurviewPublisherObjectFields -Object $setting -Required @('identity', 'lifecycle')
        if ($setting.identity -isnot [string] -or $setting.lifecycle -isnot [string]) { throw 'Publisher identity lifecycle metadata is malformed.' }
        $identity = $setting.identity
        $lifecycle = 'Main'
        if ($identity -cne 'system') {
            $identity = ConvertTo-GatewayCanonicalArmResourceId -ResourceId $identity -Config $Config -Label 'Publisher lifecycle identity'
            if ($identity -cne $pullId) { throw 'Publisher lifecycle identity is not the exact pull identity.' }
            $lifecycle = 'None'
        }
        if (-not $seen.Add($identity) -or $setting.lifecycle -cne $lifecycle) {
            throw 'Publisher lifecycle identity is duplicated or has unapproved runtime authority.'
        }
    }
    $containers = @($job.properties.template.containers)
    foreach ($field in @('initContainers', 'volumes')) {
        $value = Get-OptionalObjectPropertyValue -InputObject $job.properties.template -PropertyName $field
        if ($null -ne $value -and @($value).Count -ne 0) { throw 'Publisher may not mount volumes or run additional containers.' }
    }
    if ($containers.Count -ne 1 -or [string]$containers[0].name -cne 'purview-package-publisher' -or
        [string]$containers[0].image -cne $Record.publisher.publisherImage.value) { throw 'Publisher image or container is not exact.' }
    foreach ($field in @('command', 'args', 'volumeMounts')) {
        $value = Get-OptionalObjectPropertyValue -InputObject $containers[0] -PropertyName $field
        if ($null -ne $value -and @($value).Count -ne 0) { throw 'Publisher command or filesystem was overridden.' }
    }
    $expectedEnvironment = @(
        @{ name = 'PUBLISHER_DEPLOYMENT_OWNERSHIP_ID'; value = $Record.context.deploymentOwnershipId },
        @{ name = 'PUBLISHER_EXECUTION_INTENT_ID'; value = $Record.intentId },
        @{ name = 'PUBLISHER_EXECUTION_SOURCE_FINGERPRINT'; value = $Record.context.sourceFingerprint },
        @{ name = 'PUBLISHER_PACKAGE_DIGEST'; value = $Record.package.receipt.packageDigest },
        @{ name = 'PUBLISHER_PACKAGE_BYTES'; value = [string]$Record.package.receipt.packageBytes },
        @{ name = 'PUBLISHER_CONTAINER_URI'; value = $Record.host.packageContainerUri.value },
        @{ name = 'PUBLISHER_PRIVATE_ENDPOINT_IP'; value = $Network.privateEndpointIp })
    $expectedValues = [ordered]@{}
    foreach ($entry in $expectedEnvironment) { $expectedValues[$entry.name] = $entry.value }
    Assert-GatewayExactContainerEnvironment -Entries @($containers[0].env) -ExpectedValues $expectedValues | Out-Null
    $null = ConvertTo-PurviewPublisherExecutionTemplate -Template $job.properties.template -JobTemplate
    Assert-PurviewExecutorRoles -PrincipalId $Record.publisher.jobPrincipalId.value -Expected @(
        @{ scope = $Record.host.packageContainerId.value; role = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' })
    return $job.properties.template
}

function Start-PurviewPublisherOnce {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Template,
        [Parameter(Mandatory)][Collections.IDictionary]$Record,
        [Parameter(Mandatory)][scriptblock]$Checkpoint, [switch]$ReadOnly)
    # Only static source-owned guard names cross the diagnostic boundary. This
    # mutable local context follows callbacks without copying provider values,
    # arbitrary labels or exception text. It is never publication evidence.
    $diagnostic = @{ property = 'publisher.publish.intent' }
    $publisherCheckpoint = $Checkpoint
    try {
    $jobName = [string]$Record.publisher.jobName.value
    return Invoke-PurviewBootstrapOnce -Operations $Record.operations -Name publish `
        -Intent @{ jobId = $Record.publisher.jobId.value; template = $Template; intentId = $Record.intentId } `
        -Checkpoint {
            $previousGuard = $diagnostic.property
            $diagnostic.property = 'publisher.publish.checkpoint'
            & $publisherCheckpoint | Out-Null
            $diagnostic.property = $previousGuard
        } -ReadOnly:$ReadOnly -Discover {
            $diagnostic.property = 'publisher.publish.discovery'
            $executions = @(Invoke-AzJsonArray -OperationLabel 'Exact publisher execution discovery' -Arguments @(
                'containerapp', 'job', 'execution', 'list', '--subscription', $Config.subscriptionId,
                '--resource-group', $Config.resourceGroupName, '--name', $jobName, '--query', '[].{name:name}'))
            if ($executions.Count -eq 0) {
                $diagnostic.property = 'publisher.publish.reconciliation'
                return $null
            }
            if ($executions.Count -ne 1 -or [string]$executions[0].name -cnotmatch '^[a-z0-9-]{1,80}$') {
                throw 'Publisher execution is ambiguous; no execution will be repeated.'
            }
            for ($attempt = 0; $attempt -lt 140; $attempt++) {
                $diagnostic.property = 'publisher.publish.execution.readback'
                $execution = Invoke-AzJson -Arguments @('containerapp', 'job', 'execution', 'show',
                    '--subscription', $Config.subscriptionId, '--resource-group', $Config.resourceGroupName,
                    '--name', $jobName, '--job-execution-name', $executions[0].name)
                $diagnostic.property = 'publisher.publish.execution.identity'
                if ([string]$execution.name -cne [string]$executions[0].name) { throw 'Publisher execution identity changed.' }
                $diagnostic.property = 'publisher.publish.execution.template'
                Assert-PurviewExecutorEqual `
                    -Actual (ConvertTo-PurviewPublisherExecutionTemplate -Template $execution.properties.template) `
                    -Expected (ConvertTo-PurviewPublisherExecutionTemplate -Template $Template -JobTemplate) `
                    -Label 'publisher execution template'
                $diagnostic.property = 'publisher.publish.execution.status'
                $status = [string]$execution.properties.status
                if ($status -ceq 'Succeeded') {
                    # This exact immutable entrypoint exits zero only after conditional
                    # upload AND separate ETag-bound, full-byte SHA256 readback.
                    $diagnostic.property = 'publisher.publish.reconciliation'
                    return [ordered]@{ name = [string]$execution.name; packageDigest = $Record.package.receipt.packageDigest }
                }
                if ($status -cnotin @('Running', 'Processing', 'Pending', 'Scheduled')) { throw 'Publisher execution is failed or unknown; no repeat start is authorized.' }
                if ($ReadOnly) { throw 'Publisher execution has not completed.' }
                Start-Sleep -Seconds 5
            }
            $diagnostic.property = 'publisher.publish.execution.deadline'
            throw 'Publisher execution deadline elapsed; resume exact readback without restarting.'
        } -Mutate {
            $diagnostic.property = 'publisher.publish.dispatch'
            Invoke-AzJson -CaptureStdoutOnly -Arguments @('containerapp', 'job', 'start',
                '--subscription', $Config.subscriptionId, '--resource-group', $Config.resourceGroupName,
                '--name', $jobName, '--query', '{name:name}') | Out-Null
        }
    }
    catch {
        # Contextual rethrow only: no retry, swallowed failure or provider body,
        # and no inner exception that could expose the rejected metadata.
        $failure = New-BootstrapValidationMismatchException -PropertyName $diagnostic.property
        $failure.Data['GatewayProviderErrorCodes'] = [string[]]@(Get-BootstrapExceptionProviderErrorCodes -Exception $_.Exception)
        throw $failure
    }
}

function Get-PurviewExecutorFreshContext {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][Collections.IDictionary]$State,
        [Parameter(Mandatory)]$Foundation, [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)]$Automation, [Parameter(Mandatory)]$Database)
    $root = Get-BootstrapExecutionSourceRoot
    if (-not $State.Contains('acceptedPlan') -or
        $State.acceptedPlan -isnot [Collections.IDictionary]) { throw 'Fresh executor requires an accepted bootstrap plan.' }
    $source = [string]$State.acceptedPlan.sourceFingerprint
    Assert-BootstrapFingerprintValue -Value $source -Label 'Fresh executor accepted source'
    if ($State.Contains('publisherMetadataReconciliation')) {
        $root = Get-BootstrapAssetSourceRoot -State $State `
            -ExecutionSourceFingerprint $State.publisherMetadataReconciliation.plan.correctedSourceFingerprint `
            -DeploymentSourceFingerprint $source
    }
    if ((Get-BootstrapSourceFingerprint -Root $root) -cne $source -or
        [string]$State.configurationFingerprint -cne [string]$State.acceptedPlan.configurationFingerprint -or
        (Get-BootstrapConfigurationFingerprint -Config $Config) -cne [string]$State.configurationFingerprint) {
        throw 'Fresh executor source/configuration must match the immutable accepted plan; recovery receipts do not authorize installation.'
    }
    foreach ($inputEvidence in @($Foundation, $Runtime, $Automation)) {
        if ([string]$inputEvidence.deploymentOwnershipId -cne [string]$State.deploymentOwnershipId -or
            [string]$inputEvidence.sourceFingerprint -cne $source) { throw 'Executor prerequisite evidence is from a different deployment generation.' }
    }
    if ([string]$Database.acceptedSourceFingerprint -cne $source -or
        [string]$Database.deploymentOwnershipId -cne [string]$State.deploymentOwnershipId -or
        [string]$Database.apiPrincipalObjectId -cne [string]$Runtime.apiPrincipalId -or
        [string]$Database.workerPrincipalObjectId -cne [string]$Runtime.workerPrincipalId -or
        [string]$Automation.status -cne 'Installed' -or [string]$Automation.policyConfiguration -cne 'NotPerformed' -or
        [string]$Automation.policyReadiness -cne 'NotClaimed') { throw 'Executor requires exact core SQL and capability-only prerequisites.' }
    $scope = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)"
    $vaultId = "$scope/providers/Microsoft.KeyVault/vaults/kv-$($Config.projectName)-$($Config.environment)"
    $certificateUri = "https://kv-$($Config.projectName)-$($Config.environment).vault.azure.net/secrets/purview-automation-certificate"
    if ([string]$Runtime.sharedKeyVaultId -cne $vaultId -or
        [string]$Automation.certificateSecretUri -cne $certificateUri -or
        [string]$Automation.certificateSecretResourceId -cne "$vaultId/secrets/purview-automation-certificate") {
        throw 'Executor certificate reference is outside the exact versionless shared-vault scope.'
    }
    $runtimeIdentity = Get-PurviewExecutorArmResource -Id $Foundation.runtimeImagePullIdentityId -ApiVersion '2023-01-31'
    if ([string]$runtimeIdentity.properties.principalId -cne $Foundation.runtimeImagePullIdentityPrincipalId -or
        [string]$runtimeIdentity.tags.bootstrapOwnershipId -cne $State.deploymentOwnershipId -or
        [string]$runtimeIdentity.tags.bootstrapSourceFingerprint -cne $source) {
        throw 'Executor runtime managed identity readback is not exact.'
    }
    $context = [ordered]@{
        deploymentOwnershipId = [string]$State.deploymentOwnershipId
        sourceFingerprint = $source; configurationFingerprint = [string]$State.configurationFingerprint
        planFingerprint = [string]$State.acceptedPlan.planFingerprint
        tenantId = [string]$Config.tenantId; subscriptionId = [string]$Config.subscriptionId
        resourceGroupName = [string]$Config.resourceGroupName
        apiPrincipalId = [string]$Runtime.apiPrincipalId; workerPrincipalId = [string]$Runtime.workerPrincipalId
        workerApplicationId = [string]$Database.workerPrincipalClientId
        runtimePrincipalId = [string]$Foundation.runtimeImagePullIdentityPrincipalId
        runtimeClientId = [string]$runtimeIdentity.properties.clientId
        automationApplicationId = [string]$Automation.automationApplicationId
        automationServicePrincipalId = [string]$Automation.automationServicePrincipalId
        organization = [string]$Automation.organization
        keyVaultResourceId = $vaultId; certificateName = 'purview-automation-certificate'; certificateSecretUri = $certificateUri
    }
    foreach ($field in @('deploymentOwnershipId', 'tenantId', 'subscriptionId', 'apiPrincipalId', 'workerPrincipalId',
        'workerApplicationId', 'runtimePrincipalId', 'runtimeClientId', 'automationApplicationId', 'automationServicePrincipalId')) {
        Assert-GuidValue -Value $context[$field] -Label "Executor $field"
        if ($context[$field] -cne ([guid]$context[$field]).ToString('D')) { throw 'Executor IDs must be canonical.' }
    }
    if ($context.organization -cnotmatch '^[a-z0-9][a-z0-9.-]*\.onmicrosoft\.com$') {
        throw 'Executor organization must be the independently verified initial tenant domain.'
    }
    return $context
}

function Get-PurviewExecutorHostParameters {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][Collections.IDictionary]$Record)
    $context = $Record.context
    $binding = [ordered]@{
        AutomationApplicationId = $context.automationApplicationId; AutomationServicePrincipalObjectId = $context.automationServicePrincipalId
        GatewayApiPrincipalId = $context.apiPrincipalId; RuntimeClientId = $context.runtimeClientId; RuntimePrincipalId = $context.runtimePrincipalId
    }
    return [ordered]@{
        deploymentOwnershipId = $context.deploymentOwnershipId; bootstrapSourceFingerprint = $context.sourceFingerprint
        executionSourceFingerprint = $context.sourceFingerprint; location = [string]$Config.location
        projectName = [string]$Config.projectName; environmentName = [string]$Config.environment
        virtualNetworkName = [string]$Foundation.virtualNetworkName; privateEndpointSubnetId = [string]$Foundation.privateEndpointSubnetId
        executorSubnetPrefix = '10.42.3.0/26'; storageAccountName = $Record.network.storageAccountName
        keyVaultName = "kv-$($Config.projectName)-$($Config.environment)"; certificateName = $context.certificateName
        executorApplicationId = $Record.identity.applicationId; workerApplicationId = $context.workerApplicationId
        workerPrincipalId = $context.workerPrincipalId; enableRuntime = $false
        packageSha256 = ([string]$Record.package.receipt.packageDigest).Substring(7)
        runtimeManifestDigest = $Record.package.receipt.runtimeManifestDigest
        executionBinding = $binding; organization = $context.organization
    }
}

function Install-BootstrapPurviewExecutor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)]$Automation,
        [Parameter(Mandatory)]$Database,
        [switch]$ReadOnly
    )
    # Core and Custom-without-Purview do not inspect Windows tools or contact providers.
    if ($Config.purview.enabled -ne $true) { return $null }
    $context = Get-PurviewExecutorFreshContext -Config $Config -State $State -Foundation $Foundation `
        -Runtime $Runtime -Automation $Automation -Database $Database
    $root = Get-BootstrapExecutionSourceRoot
    if ($State.Contains('publisherMetadataReconciliation')) {
        $root = Get-BootstrapAssetSourceRoot -State $State `
            -ExecutionSourceFingerprint $State.publisherMetadataReconciliation.plan.correctedSourceFingerprint `
            -DeploymentSourceFingerprint $context.sourceFingerprint
    }
    $checkpoint = { Save-BootstrapState -State $State -Path $StatePath }
    if (-not $State.Contains('freshPurviewExecutor')) {
        if ($ReadOnly) { throw 'Fresh Purview executor installation evidence is missing.' }
        if ($State.Contains('steps') -and $State.steps.Contains('Gateway runtime deployment') -and
            [string]$State.steps['Gateway runtime deployment'].status -ceq 'Completed') {
            throw 'Fresh executor installation cannot upgrade an already completed runtime.'
        }
        $State.freshPurviewExecutor = [ordered]@{
            schemaVersion = 1; status = 'Installing'; intentId = [guid]::NewGuid().ToString('D')
            context = $context; operations = [ordered]@{}
        }
        & $checkpoint | Out-Null
    }
    $record = $State.freshPurviewExecutor
    if ($record.schemaVersion -ne 1 -or $record.status -cnotin @('Installing', 'Installed') -or
        $record.operations -isnot [Collections.IDictionary]) { throw 'Fresh executor checkpoint schema is invalid.' }
    Assert-PurviewExecutorEqual -Actual $record.context -Expected $context -Label 'immutable fresh context'
    Assert-GuidValue -Value $record.intentId -Label 'Executor execution intent'
    if ($ReadOnly) {
        if ($record.status -cne 'Installed') { throw 'Executor installation has not completed.' }
        foreach ($field in @('package', 'identity', 'publisherImage', 'network', 'host', 'publisher', 'publication')) {
            if (-not $record.Contains($field)) { throw 'Completed executor installation evidence is incomplete.' }
        }
        $record = $record | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable -Depth 50
    }
    $providerState = Invoke-AzTsv -Arguments @('provider', 'show', '--namespace', 'Microsoft.Web', '--query', 'registrationState')
    if ($providerState -cne 'Registered') {
        if ($providerState -cnotin @('NotRegistered', 'Registering')) { throw 'Microsoft.Web registration state is unknown.' }
        $null = Invoke-PurviewBootstrapOnce -Operations $record.operations -Name webProvider -Intent @{ namespace = 'Microsoft.Web'; subscriptionId = $Config.subscriptionId } `
            -Checkpoint $checkpoint -ReadOnly:$ReadOnly -Discover {
                $stateValue = Invoke-AzTsv -Arguments @('provider', 'show', '--namespace', 'Microsoft.Web', '--query', 'registrationState')
                if ($stateValue -ceq 'Registered') { return @{ namespace = 'Microsoft.Web' } }
                if ($stateValue -cne 'NotRegistered') { throw 'Microsoft.Web registration is pending or unknown; no repeat dispatch.' }
            } -Mutate {
                Invoke-BootstrapCommand -FilePath az -ArgumentList @('provider', 'register', '--namespace', 'Microsoft.Web', '--wait', '--only-show-errors') | Out-Null
            }
    }
    if (-not $record.Contains('package')) {
        if ($State.Contains('publisherMetadataReconciliation')) { throw 'Publisher reconciliation cannot rebuild the original package.' }
        if ($ReadOnly) { throw 'Source-bound executor package is not checkpointed.' }
        # Interrupted local packaging can use a new local output; it has no provider
        # authority and no package has been accepted for publication yet.
        $directory = Join-Path $root ".bootstrap/purview-executor/$($record.intentId)/$([guid]::NewGuid().ToString('D'))"
        # Isolate the package builder's Common module imports from the engine's
        # accepted-source/event-writer state.
        Invoke-BootstrapCommand -FilePath 'pwsh' -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $root 'operations/build-purview-executor-package.ps1'),
            '-OutputDirectory', $directory, '-ExpectedSourceFingerprint', $context.sourceFingerprint) | Out-Null
        $package = Read-PurviewExecutorPackage -PackageDirectory $directory -ExpectedSourceFingerprint $context.sourceFingerprint
        $record.packageDirectory = $directory
        $record.package = [ordered]@{ receipt = $package.receipt; receiptFingerprint = $package.receiptFingerprint }
        & $checkpoint | Out-Null
    }
    # Verification does not require workstation package bytes; it binds the
    # immutable image/execution and the complete deployed package digest instead.
    if (-not $ReadOnly) {
        $package = Read-PurviewExecutorPackage -PackageDirectory $record.packageDirectory -ExpectedSourceFingerprint $context.sourceFingerprint
        Assert-PurviewExecutorEqual -Actual $package.receipt -Expected $record.package.receipt -Label 'package receipt'
        if ($package.receiptFingerprint -cne $record.package.receiptFingerprint) { throw 'Executor package receipt fingerprint changed.' }
    }
    $record.identity = Ensure-PurviewExecutorIdentity -Context $context -Operations $record.operations -Checkpoint $checkpoint -ReadOnly:$ReadOnly
    $record.publisherImage = Build-PurviewExecutorPublisher -Config $Config -Foundation $Foundation -Record $record `
        -Checkpoint $checkpoint -ReadOnly:$ReadOnly -PublisherRecoveryState $State
    $network = Get-PurviewExecutorStorageNetwork -Config $Config -Foundation $Foundation -Runtime $Runtime -Context $context
    if ($record.Contains('network')) { Assert-PurviewExecutorEqual -Actual $network -Expected $record.network -Label 'private storage network' }
    else { $record.network = $network; & $checkpoint | Out-Null }
    $binding = [ordered]@{
        AutomationApplicationId = $context.automationApplicationId; AutomationServicePrincipalObjectId = $context.automationServicePrincipalId
        GatewayApiPrincipalId = $context.apiPrincipalId; RuntimeClientId = $context.runtimeClientId; RuntimePrincipalId = $context.runtimePrincipalId
    }
    $hostParameters = [ordered]@{
        deploymentOwnershipId = $context.deploymentOwnershipId; bootstrapSourceFingerprint = $context.sourceFingerprint
        executionSourceFingerprint = $context.sourceFingerprint; location = [string]$Config.location
        projectName = [string]$Config.projectName; environmentName = [string]$Config.environment
        virtualNetworkName = [string]$Foundation.virtualNetworkName; privateEndpointSubnetId = [string]$Foundation.privateEndpointSubnetId
        executorSubnetPrefix = '10.42.3.0/26'; storageAccountName = $network.storageAccountName
        keyVaultName = "kv-$($Config.projectName)-$($Config.environment)"; certificateName = $context.certificateName
        executorApplicationId = $record.identity.applicationId; workerApplicationId = $context.workerApplicationId
        workerPrincipalId = $context.workerPrincipalId; enableRuntime = $false
        packageSha256 = ([string]$record.package.receipt.packageDigest).Substring(7)
        runtimeManifestDigest = $record.package.receipt.runtimeManifestDigest
        executionBinding = $binding; organization = $context.organization
    }
    $hostName = "a365gw-$($Config.projectName)-executor-host-$($Config.environment)"
    # The first host ARM deployment must not adopt pre-existing executor resources.
    if (-not $record.operations.Contains($hostName)) {
        $existing = @(Invoke-AzJsonArray -OperationLabel 'Executor resource absence' -Arguments @(
            'resource', 'list', '--subscription', $Config.subscriptionId, '--resource-group', $Config.resourceGroupName,
            '--query', "[?type=='Microsoft.Web/sites' || type=='Microsoft.Web/serverFarms' || (type=='Microsoft.Network/privateDnsZones' && name=='privatelink.azurewebsites.net')].{id:id}"))
        if ($existing.Count -ne 0) { throw 'Unowned Windows executor resources already exist.' }
        $vnetId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($Foundation.virtualNetworkName)"
        $vnet = Get-PurviewExecutorArmResource -Id $vnetId -ApiVersion '2023-11-01'
        if (@($vnet.properties.subnets | Where-Object { [string]$_.name -ceq 'snet-purview-executor' }).Count -ne 0) {
            throw 'The dedicated executor integration subnet already exists without its intent.'
        }
        $containers = Get-PurviewExecutorArmResource -Id "$($Runtime.storageAccountId)/blobServices/default/containers" -ApiVersion '2023-05-01'
        Assert-PurviewExecutorCompleteArmCollection -Collection $containers
        if ($containers.value -isnot [Array] -or
            @($containers.value | Where-Object { [string]$_.name -cin @('purview-executor-packages', 'purview-executor-claims') }).Count -ne 0) {
            throw 'Executor storage containers are unowned or their absence is unknown.'
        }
    }
    $deploymentArguments = @{ Config = $Config; Operations = $record.operations; Checkpoint = $checkpoint; ReadOnly = $ReadOnly; PublisherRecoveryState = $State }
    $record.host = Invoke-PurviewExecutorDeployment @deploymentArguments -Name $hostName `
        -Template 'bootstrap/infra/purview-windows-executor.bicep' -Parameters $hostParameters
    # A resumed enabled host is verified as enabled; it is never disabled again.
    $enableName = "a365gw-$($Config.projectName)-executor-enable-$($Config.environment)"
    Assert-PurviewExecutorHost -Config $Config -Foundation $Foundation -Record $record -Enabled:($record.operations.Contains($enableName))
    $publisherParameters = [ordered]@{
        location = [string]$Config.location; environmentName = [string]$Config.environment; projectName = [string]$Config.projectName
        deploymentOwnershipId = $context.deploymentOwnershipId; bootstrapSourceFingerprint = $context.sourceFingerprint
        executionSourceFingerprint = $context.sourceFingerprint; executionIntentId = $record.intentId
        containerAppsEnvironmentId = [string]$Foundation.containerAppsEnvironmentId
        imagePullIdentityResourceId = [string]$Foundation.runtimeImagePullIdentityId; acrLoginServer = [string]$Foundation.acrLoginServer
        publisherImageDigest = $record.publisherImage.digest; packageDigest = $record.package.receipt.packageDigest
        packageBytes = [int]$record.package.receipt.packageBytes; storageAccountName = $network.storageAccountName
        expectedStoragePrivateEndpointIp = $network.privateEndpointIp
    }
    $publisherName = "a365gw-$($Config.projectName)-executor-publisher-$($Config.environment)"
    if (-not $record.operations.Contains($publisherName)) {
        $existing = @(Invoke-AzJsonArray -OperationLabel 'Publisher job absence' -Arguments @(
            'containerapp', 'job', 'list', '--subscription', $Config.subscriptionId, '--resource-group', $Config.resourceGroupName,
            '--query', "[?name=='job-$($Config.projectName)-purview-package-$($Config.environment)'].{id:id}"))
        if ($existing.Count -ne 0) { throw 'An unowned publisher job already exists.' }
    }
    $record.publisher = Invoke-PurviewExecutorDeployment @deploymentArguments -Name $publisherName `
        -Template 'bootstrap/infra/purview-package-publisher-job.bicep' -Parameters $publisherParameters
    $template = Assert-PurviewPublisherJob -Config $Config -Foundation $Foundation -Record $record -Network $network
    $record.publication = Start-PurviewPublisherOnce -Config $Config -Template $template -Record $record -Checkpoint $checkpoint -ReadOnly:$ReadOnly
    $hostParameters.enableRuntime = $true
    $enabled = Invoke-PurviewExecutorDeployment @deploymentArguments -Name $enableName `
        -Template 'bootstrap/infra/purview-windows-executor.bicep' -Parameters $hostParameters
    Assert-PurviewExecutorEqual -Actual $enabled -Expected $record.host -Label 'enabled host identity'
    Assert-PurviewExecutorHost -Config $Config -Foundation $Foundation -Record $record -Enabled
    if (-not $ReadOnly) { $record.status = 'Installed'; & $checkpoint | Out-Null }
    return [ordered]@{
        enabled = $true; endpoint = [string]$record.host.executorEndpoint.value; binding = $record.host.executorBinding.value
        packageDigest = [string]$record.package.receipt.packageDigest; runtimeReadiness = 'NotClaimedByBootstrap'
    }
}

function Get-PurviewExecutorWorkerGrant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$VerificationContext,
        [Parameter(Mandatory)][string]$PrincipalId
    )
    # This is not an allow-nonGraph flag or a caller-supplied role tuple. Resolve
    # the single exception from the original accepted generation and independently
    # re-read the exact API app, SP, worker, and resource-side assignment.
    $config = $VerificationContext.Configuration
    $state = $VerificationContext.State
    $runtime = $VerificationContext.Runtime
    if ($state -isnot [Collections.IDictionary] -or -not $state.Contains('freshPurviewExecutor') -or
        $config.purview.enabled -ne $true -or
        $PrincipalId -cne [string]$runtime.workerPrincipalId) {
        throw 'Executor grant verification requires the selected worker and trusted fresh bootstrap state.'
    }
    $record = $state.freshPurviewExecutor
    if ($record -isnot [Collections.IDictionary] -or $record.schemaVersion -ne 1 -or
        [string]$record.status -cnotin @('Installing', 'Installed') -or
        $record.context -isnot [Collections.IDictionary] -or $record.operations -isnot [Collections.IDictionary] -or
        $state.acceptedPlan -isnot [Collections.IDictionary]) {
        throw 'Executor grant verification state is incomplete or unknown.'
    }
    $context = $record.context
    $source = [string]$state.acceptedPlan.sourceFingerprint
    $assetRoot = Get-BootstrapExecutionSourceRoot
    if ($state.Contains('publisherMetadataReconciliation')) {
        $assetRoot = Get-BootstrapAssetSourceRoot -State $state `
            -ExecutionSourceFingerprint $state.publisherMetadataReconciliation.plan.correctedSourceFingerprint `
            -DeploymentSourceFingerprint $source
    }
    Assert-BootstrapFingerprintValue -Value $source -Label 'Executor grant accepted source'
    $expected = @{
        deploymentOwnershipId = [string]$state.deploymentOwnershipId
        sourceFingerprint = $source
        configurationFingerprint = [string]$state.configurationFingerprint
        planFingerprint = [string]$state.acceptedPlan.planFingerprint
        tenantId = [string]$config.tenantId; subscriptionId = [string]$config.subscriptionId
        resourceGroupName = [string]$config.resourceGroupName; workerPrincipalId = $PrincipalId
    }
    foreach ($field in $expected.Keys) {
        if ([string]::IsNullOrWhiteSpace($expected[$field]) -or [string]$context[$field] -cne $expected[$field]) {
            throw 'Executor grant context differs from the accepted deployment binding.'
        }
    }
    if ([string]$state.acceptedPlan.configurationFingerprint -cne $expected.configurationFingerprint -or
        (Get-BootstrapConfigurationFingerprint -Config $config) -cne $expected.configurationFingerprint -or
        (Get-BootstrapSourceFingerprint -Root $assetRoot) -cne $source -or
        [string]$runtime.deploymentOwnershipId -cne $expected.deploymentOwnershipId -or
        [string]$runtime.sourceFingerprint -cne $source) {
        throw 'Executor grant source/configuration/runtime binding is not exact.'
    }
    if (-not $record.operations.Contains('invokeRole')) {
        if ([string]$record.status -cne 'Installing' -or $record.Contains('identity')) {
            throw 'Executor identity completion has no durable grant intent.'
        }
        # A pre-grant prefix remains eight-only. A later unrecorded grant is not
        # adopted; the worker-side guard rejects it as an unexpected assignment.
        return $null
    }
    $identity = Ensure-PurviewExecutorIdentity -Context $context -Operations $record.operations `
        -Checkpoint { throw 'Executor grant verification cannot checkpoint or mutate.' } -ReadOnly
    if ($record.Contains('identity')) {
        Assert-PurviewExecutorEqual -Actual $identity -Expected $record.identity -Label 'recorded executor identity'
    }
    if ([string]::IsNullOrWhiteSpace([string]$identity.roleAssignmentId)) { throw 'Executor grant has no exact assignment ID.' }
    return [ordered]@{
        id = [string]$identity.roleAssignmentId; principalId = $PrincipalId
        resourceId = [string]$identity.servicePrincipalId; appRoleId = [string](Get-PurviewExecutorRole).id
    }
}

function Get-PurviewExecutorWorkerEnvironment {
    param([AllowNull()]$Executor)
    # The complete ARM environment replacement removes old bindings when disabled.
    if ($null -eq $Executor) { return [ordered]@{} }
    $result = [ordered]@{
        PurviewExecutor__Enabled = if ($null -ne $Executor -and $Executor.enabled -eq $true) { 'True' } else { 'False' }
        PurviewExecutor__Endpoint = if ($null -ne $Executor) { [string]$Executor.endpoint } else { '' }
        PurviewExecutor__TimeoutSeconds = '215'
    }
    if ($null -ne $Executor -and $Executor.enabled -eq $true) {
        foreach ($entry in $Executor.binding.GetEnumerator()) { $result["PurviewExecutor__Binding__$($entry.Key)"] = [string]$entry.Value }
    }
    return $result
}

Export-ModuleMember -Function *
