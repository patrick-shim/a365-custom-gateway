Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-HttpsHealth {
    param([Parameter(Mandatory)][string]$Url)
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 15 -SkipHttpErrorCheck
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                return [ordered]@{ url = $Url; statusCode = [int]$response.StatusCode }
            }
        }
        catch { }
        if ($attempt -lt 30) { Start-Sleep -Seconds 10 }
    }
    throw "Health endpoint '$Url' did not return a 2xx response within five minutes."
}

function Test-GatewayRecordedDatabaseAttestationBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)]$Database,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    try {
        $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
        Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Current database-attestation source fingerprint'
        $apiClientId = ([guid][string]$Database.apiPrincipalClientId).ToString('D')
        $workerClientId = ([guid][string]$Database.workerPrincipalClientId).ToString('D')
        $intent = $Database.initializationIntent
        if (-not $intent -or
            [string]$Database.deploymentOwnershipId -cne $canonicalOwnershipId -or
            [string]$Database.acceptedSourceFingerprint -cne $SourceFingerprint -or
            [string]$Database.server -cne [string]$Runtime.sqlServerFqdn -or
            [string]$Database.database -cne 'GatewayDb' -or
            [string]$Database.schemaFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$Database.apiPrincipalName -cne "ca-gateway-api-$($Config.environment)" -or
            [string]$Database.workerPrincipalName -cne "ca-gateway-worker-$($Config.environment)-v3" -or
            [string]$Database.apiPrincipalObjectId -cne ([guid][string]$Runtime.apiPrincipalId).ToString('D') -or
            [string]$Database.workerPrincipalObjectId -cne ([guid][string]$Runtime.workerPrincipalId).ToString('D') -or
            [string]$Database.apiPrincipalClientId -cne $apiClientId -or
            [string]$Database.workerPrincipalClientId -cne $workerClientId -or
            $apiClientId -ceq $workerClientId -or
            (@($Database.apiDirectPermissions | ForEach-Object { [string]$_ } | Sort-Object) -join '|') -cne 'VIEW DEFINITION' -or
            @($Database.workerDirectPermissions).Count -ne 0 -or
            [string]$intent.markerName -cne 'A365GatewayBootstrapInitializationIntent' -or
            [int]$intent.schemaVersion -ne 1 -or
            [string]$intent.deploymentOwnershipId -cne $canonicalOwnershipId -or
            [string]$intent.acceptedSourceFingerprint -cne $SourceFingerprint -or
            [string]$intent.server -cne [string]$Runtime.sqlServerFqdn -or
            [string]$intent.database -cne 'GatewayDb' -or
            [string]$intent.databaseCollation -cne 'SQL_Latin1_General_CP1_CI_AS' -or
            [string]$intent.catalogCollation -cne 'SQL_Latin1_General_CP1_CI_AS' -or
            [string]$intent.databaseOwnerSidSha256 -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            $intent.exactReadbackVerified -ne $true -or
            $Runtime.databaseAttestationEnabled -ne $true -or
            [string]$Runtime.databaseAttestationExpectedSchemaFingerprint -cne [string]$Database.schemaFingerprint -or
            [string]$Runtime.databaseAttestationApiPrincipalName -cne [string]$Database.apiPrincipalName -or
            [string]$Runtime.databaseAttestationApiPrincipalClientId -cne $apiClientId -or
            [string]$Runtime.databaseAttestationWorkerPrincipalName -cne [string]$Database.workerPrincipalName -or
            [string]$Runtime.databaseAttestationWorkerPrincipalClientId -cne $workerClientId -or
            [string]$Runtime.databaseAttestationDatabaseName -cne 'GatewayDb') {
            throw 'mismatch'
        }
        return $true
    }
    catch {
        throw 'Recorded database attestation is incomplete or does not match the exact runtime ownership, source, schema, initialization-intent, and principal boundary.'
    }
}

function Get-GatewayCurrentDatabaseAttestationEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApiFqdn)

    if ($ApiFqdn -cnotmatch '^[A-Za-z0-9.-]+$') {
        throw 'Gateway API FQDN is not canonical; current database attestation was not attempted.'
    }
    $uri = "https://$ApiFqdn/health/bootstrap-attestation"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec 30 -SkipHttpErrorCheck
            $content = [string]$response.Content
            if ([int]$response.StatusCode -eq 200 -and
                [Text.Encoding]::UTF8.GetByteCount($content) -le 512) {
                $payload = $content | ConvertFrom-Json -Depth 5 -ErrorAction Stop
                $properties = @($payload.PSObject.Properties.Name | Sort-Object)
                if (($properties -join '|') -ceq 'contractVersion|status' -and
                    [string]$payload.status -ceq 'Attested' -and
                    [int]$payload.contractVersion -eq 1) {
                    return [ordered]@{
                        status = 'Passed'
                        contractVersion = 1
                    }
                }
            }
        }
        catch { }
        if ($attempt -lt 3) { Start-Sleep -Seconds 5 }
    }
    throw 'The private-runtime database attestation endpoint did not return the exact bounded v1 success contract.'
}

function Test-ExactAdminUiRuntimeApplicationSurface {
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)][string]$ExpectedSignInRedirectUri,
        [Parameter(Mandatory)][string]$ExpectedSignedOutCallbackUri
    )

    Assert-ExactApplicationAuthenticationSurface -Application $Application -ApplicationLabel 'Admin UI application' | Out-Null
    return @($Application.web.redirectUris).Count -eq 1 -and
        [string]$Application.web.redirectUris[0] -ceq $ExpectedSignInRedirectUri -and
        [string]$Application.web.logoutUrl -ceq $ExpectedSignedOutCallbackUri -and
        [string]::IsNullOrWhiteSpace([string]$Application.web.homePageUrl) -and
        @($Application.spa.redirectUris).Count -eq 0 -and
        @($Application.publicClient.redirectUris).Count -eq 0 -and
        @($Application.keyCredentials).Count -eq 0
}

function Assert-GatewayRuntimeDeploymentOwnership {
    param(
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId
    )
    Assert-GuidValue -Value $DeploymentOwnershipId -Label 'Deployment ownership identifier'
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId -or
        [string]$Runtime.deploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Runtime deployment evidence is not bound to the canonical ownership identifier from the current bootstrap state.'
    }
    return $true
}

function Get-GatewayRuntimeProvisioningMode {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Runtime
    )
    $previewRequested = [string]$Config.environment -eq 'dev' -and $Config.agent365.allowDevelopmentRegistryPreview -eq $true
    $runtimePreviewEnabled = $previewRequested -and $Config.purview.policyProvisioningEnabled -ne $true
    $expectedRegistryProvider = if ($runtimePreviewEnabled) { 'DirectRegistryPreview' } else { 'Disabled' }
    if ($Runtime.provisioningExecutionEnabled -ne $runtimePreviewEnabled -or
        [string]$Runtime.registryProvider -cne $expectedRegistryProvider) {
        throw 'Runtime provisioning execution and Registry provider do not match the reviewed effective bootstrap mode.'
    }
    return [ordered]@{
        previewRequested = [bool]$previewRequested
        runtimePreviewEnabled = [bool]$runtimePreviewEnabled
        expectedRegistryProvider = $expectedRegistryProvider
    }
}

function Test-AzureRoleAssignmentScopeIntersects {
    param(
        [Parameter(Mandatory)][string]$AssignmentScope,
        [Parameter(Mandatory)][string]$ResourceScope
    )
    $assignment = $AssignmentScope.TrimEnd('/')
    $resource = $ResourceScope.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($assignment) -or [string]::IsNullOrWhiteSpace($resource)) { return $false }
    return $assignment.Equals($resource, [StringComparison]::OrdinalIgnoreCase) -or
        $resource.StartsWith("$assignment/", [StringComparison]::OrdinalIgnoreCase) -or
        $assignment.StartsWith("$resource/", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-GatewayPrincipalExactAzureRoleAssignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][object[]]$ExpectedAssignments,
        [Parameter(Mandatory)][string]$PrincipalLabel
    )

    Assert-GuidValue -Value $PrincipalId -Label "$PrincipalLabel principal ID"
    Assert-GuidValue -Value $SubscriptionId -Label 'Azure subscription ID'
    $canonicalPrincipalId = ([guid]$PrincipalId).ToString('D')
    $canonicalSubscriptionId = ([guid]$SubscriptionId).ToString('D')
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expectedAssignmentIds = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($assignment in $ExpectedAssignments) {
        $scope = ([string]$assignment.scope).TrimEnd('/')
        $roleId = ([guid][string]$assignment.roleDefinitionId).ToString('D')
        $key = "$scope|$roleId"
        $expectedAssignmentId = if ($assignment -is [System.Collections.IDictionary]) {
            if ($assignment.Contains('assignmentId')) { [string]$assignment['assignmentId'] } else { '' }
        }
        elseif ($null -ne $assignment.PSObject.Properties['assignmentId']) {
            [string]$assignment.assignmentId
        }
        else { '' }
        if (-not $scope.StartsWith("/subscriptions/$canonicalSubscriptionId/", [StringComparison]::OrdinalIgnoreCase) -or
            -not $expected.Add($key)) {
            throw "$PrincipalLabel expected Azure role matrix is malformed or duplicated."
        }
        if (-not [string]::IsNullOrWhiteSpace($expectedAssignmentId)) {
            $assignmentPrefix = "$scope/providers/Microsoft.Authorization/roleAssignments/"
            $assignmentGuidText = if ($expectedAssignmentId.StartsWith($assignmentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                $expectedAssignmentId.Substring($assignmentPrefix.Length)
            }
            else { '' }
            $assignmentGuid = [guid]::Empty
            if (-not [guid]::TryParse($assignmentGuidText, [ref]$assignmentGuid) -or
                $assignmentGuid -eq [guid]::Empty -or
                $assignmentGuidText -cne $assignmentGuid.ToString('D')) {
                throw "$PrincipalLabel expected Azure role-assignment receipt is malformed."
            }
        }
        $expectedAssignmentIds.Add($key, $expectedAssignmentId)
    }

    $actualAssignments = @(Invoke-AzJsonArray -OperationLabel "$PrincipalLabel Azure role-assignment discovery" -Arguments @(
        'role', 'assignment', 'list',
        '--assignee-object-id', $canonicalPrincipalId,
        '--all', '--include-inherited',
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false',
        '--query', '[].{id:id,principalId:principalId,principalType:principalType,scope:scope,roleDefinitionId:roleDefinitionId,condition:condition,conditionVersion:conditionVersion,delegatedManagedIdentityResourceId:delegatedManagedIdentityResourceId}'
    ))
    if ($actualAssignments.Count -ne $expected.Count) {
        throw "$PrincipalLabel has missing, duplicate, inherited, or unreviewed Azure role assignments."
    }

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($assignment in $actualAssignments) {
        $principalType = if ($null -ne $assignment.PSObject.Properties['principalType']) { [string]$assignment.principalType } else { '' }
        $condition = if ($null -ne $assignment.PSObject.Properties['condition']) { [string]$assignment.condition } else { '' }
        $conditionVersion = if ($null -ne $assignment.PSObject.Properties['conditionVersion']) { [string]$assignment.conditionVersion } else { '' }
        $delegatedIdentity = if ($null -ne $assignment.PSObject.Properties['delegatedManagedIdentityResourceId']) { [string]$assignment.delegatedManagedIdentityResourceId } else { '' }
        $scope = ([string]$assignment.scope).TrimEnd('/')
        $roleDefinitionText = ([string]$assignment.roleDefinitionId).TrimEnd('/')
        $roleDefinitionParts = @($roleDefinitionText.Split('/', [StringSplitOptions]::RemoveEmptyEntries))
        $roleId = [guid]::Empty
        $assignmentId = [string]$assignment.id
        $assignmentIdParts = @($assignmentId.Split('/', [StringSplitOptions]::RemoveEmptyEntries))
        $assignmentGuid = [guid]::Empty
        if (-not ([string]$assignment.principalId).Equals($canonicalPrincipalId, [StringComparison]::OrdinalIgnoreCase) -or
            $principalType -cne 'ServicePrincipal' -or
            [string]::IsNullOrWhiteSpace($scope) -or
            -not [guid]::TryParse($roleDefinitionParts[-1], [ref]$roleId) -or
            -not [guid]::TryParse($assignmentIdParts[-1], [ref]$assignmentGuid) -or
            -not $assignmentId.StartsWith("$scope/providers/Microsoft.Authorization/roleAssignments/", [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::IsNullOrWhiteSpace($condition) -or
            -not [string]::IsNullOrWhiteSpace($conditionVersion) -or
            -not [string]::IsNullOrWhiteSpace($delegatedIdentity)) {
            throw "$PrincipalLabel Azure role-assignment evidence is malformed or carries an unreviewed condition/delegation."
        }
        $key = "$scope|$($roleId.ToString('D'))"
        $requiredAssignmentId = if ($expectedAssignmentIds.ContainsKey($key)) { $expectedAssignmentIds[$key] } else { '' }
        if (-not $expected.Contains($key) -or -not $seen.Add($key) -or
            (-not [string]::IsNullOrWhiteSpace($requiredAssignmentId) -and
                -not $assignmentId.Equals($requiredAssignmentId, [StringComparison]::OrdinalIgnoreCase))) {
            throw "$PrincipalLabel has duplicate, inherited, or unreviewed Azure role assignments."
        }
    }
    if ($seen.Count -ne $expected.Count) {
        throw "$PrincipalLabel Azure role assignments do not exactly match the reviewed least-privilege matrix."
    }
    return $true
}

function Assert-GatewayServicePrincipalHasNoDirectoryMemberships {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$PrincipalLabel
    )

    Assert-GuidValue -Value $PrincipalId -Label "$PrincipalLabel principal ID"
    $canonicalPrincipalId = ([guid]$PrincipalId).ToString('D')
    $memberships = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$canonicalPrincipalId/transitiveMemberOf?`$select=id")
    if ($memberships.Count -ne 0) {
        throw "$PrincipalLabel has an unreviewed direct or transitive group/directory-role membership."
    }
    return $true
}

function Assert-GatewayExactAzureRoleAssignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)]$AdminUi
    )

    $subscriptionId = ([guid][string]$Config.subscriptionId).ToString('D')
    $resourceGroupScope = "/subscriptions/$subscriptionId/resourceGroups/$($Config.resourceGroupName)"
    $registryName = ([string]$Runtime.acrLoginServer).Split('.')[0]
    $expectedRegistryId = "$resourceGroupScope/providers/Microsoft.ContainerRegistry/registries/$registryName"
    $expectedVaultId = "$resourceGroupScope/providers/Microsoft.KeyVault/vaults/kv-$($Config.projectName)-$($Config.environment)"
    $expectedQueueId = "$resourceGroupScope/providers/Microsoft.ServiceBus/namespaces/sb-$($Config.projectName)-$($Config.environment)/queues/$($Runtime.serviceBusQueueName)"
    $runtimeImagePullIdentityName = "id-gateway-runtime-pull-$($Config.environment)"
    $expectedRuntimeImagePullIdentityId = "$resourceGroupScope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$runtimeImagePullIdentityName"
    $storagePrefix = "$resourceGroupScope/providers/Microsoft.Storage/storageAccounts/"
    $storageId = ([string]$Runtime.storageAccountId).TrimEnd('/')
    $runtimeImagePullPrincipalId = [string]$Runtime.runtimeImagePullIdentityPrincipalId
    $parsedRuntimeImagePullPrincipalId = [guid]::Empty
    $runtimeImagePullRoleAssignmentId = [string]$Runtime.runtimeImagePullAcrPullRoleAssignmentId
    $runtimeImagePullRoleAssignmentPrefix = "$expectedRegistryId/providers/Microsoft.Authorization/roleAssignments/"
    $runtimeImagePullRoleAssignmentGuidText = if ($runtimeImagePullRoleAssignmentId.StartsWith($runtimeImagePullRoleAssignmentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $runtimeImagePullRoleAssignmentId.Substring($runtimeImagePullRoleAssignmentPrefix.Length)
    }
    else { '' }
    $parsedRuntimeImagePullRoleAssignmentId = [guid]::Empty
    if (-not ([string]$Runtime.containerRegistryId).Equals($expectedRegistryId, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$Runtime.sharedKeyVaultId).Equals($expectedVaultId, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$Runtime.serviceBusQueueId).Equals($expectedQueueId, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$Runtime.runtimeImagePullIdentityId).Equals($expectedRuntimeImagePullIdentityId, [StringComparison]::OrdinalIgnoreCase) -or
        -not [guid]::TryParse($runtimeImagePullPrincipalId, [ref]$parsedRuntimeImagePullPrincipalId) -or
        $parsedRuntimeImagePullPrincipalId -eq [guid]::Empty -or
        $runtimeImagePullPrincipalId -cne $parsedRuntimeImagePullPrincipalId.ToString('D') -or
        -not [guid]::TryParse($runtimeImagePullRoleAssignmentGuidText, [ref]$parsedRuntimeImagePullRoleAssignmentId) -or
        $parsedRuntimeImagePullRoleAssignmentId -eq [guid]::Empty -or
        $runtimeImagePullRoleAssignmentGuidText -cne $parsedRuntimeImagePullRoleAssignmentId.ToString('D') -or
        -not $storageId.StartsWith($storagePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $storageId.Substring($storagePrefix.Length) -cnotmatch '^[a-z0-9]{3,24}$') {
        throw 'Runtime resource IDs do not match the exact reviewed Azure RBAC scope boundary.'
    }

    $runtimeImagePullIdentity = Invoke-AzJson -Arguments @(
        'identity', 'show', '--subscription', $subscriptionId,
        '--resource-group', [string]$Config.resourceGroupName, '--name', $runtimeImagePullIdentityName,
        '--query', '{id:id,name:name,principalId:principalId,type:type,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
    )
    if (-not ([string]$runtimeImagePullIdentity.id).Equals($expectedRuntimeImagePullIdentityId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$runtimeImagePullIdentity.name -cne $runtimeImagePullIdentityName -or
        [string]$runtimeImagePullIdentity.principalId -cne $runtimeImagePullPrincipalId -or
        [string]$runtimeImagePullIdentity.type -cne 'Microsoft.ManagedIdentity/userAssignedIdentities' -or
        [string]$runtimeImagePullIdentity.ownershipId -cne [string]$Runtime.deploymentOwnershipId -or
        [string]$runtimeImagePullIdentity.sourceFingerprint -cne [string]$Runtime.sourceFingerprint) {
        throw 'Runtime image-pull identity resource is missing or outside the exact identity, ownership, and source boundary.'
    }

    foreach ($resource in @(
        [ordered]@{ id = $storageId; type = 'Microsoft.Storage/storageAccounts'; requireTags = $true },
        [ordered]@{ id = $expectedRegistryId; type = 'Microsoft.ContainerRegistry/registries'; requireTags = $true },
        [ordered]@{ id = $expectedVaultId; type = 'Microsoft.KeyVault/vaults'; requireTags = $true },
        [ordered]@{ id = $expectedQueueId; type = 'Microsoft.ServiceBus/namespaces/queues'; requireTags = $false }
    )) {
        $readback = Invoke-AzJson -Arguments @(
            'resource', 'show', '--ids', [string]$resource.id,
            '--query', '{id:id,type:type,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
        )
        if (-not ([string]$readback.id).Equals([string]$resource.id, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$readback.type).Equals([string]$resource.type, [StringComparison]::OrdinalIgnoreCase) -or
            ($resource.requireTags -and (
                [string]$readback.ownershipId -cne [string]$Runtime.deploymentOwnershipId -or
                [string]$readback.sourceFingerprint -cne [string]$Runtime.sourceFingerprint))) {
            throw 'An Azure RBAC target resource is missing or outside the exact deployment ownership/source boundary.'
        }
    }

    $storageContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    $serviceBusSender = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
    $serviceBusReceiver = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
    $acrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    $keyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
    $cognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'

    $apiExpected = [Collections.Generic.List[object]]::new()
    $apiExpected.Add([ordered]@{ scope = $storageId; roleDefinitionId = $storageContributor })
    $apiExpected.Add([ordered]@{ scope = $expectedQueueId; roleDefinitionId = $serviceBusSender })
    if ($Config.promptShield.enabled -eq $true) {
        $promptShieldId = ([string]$Runtime.promptShieldAccountId).TrimEnd('/')
        if (-not $promptShieldId.StartsWith("$resourceGroupScope/providers/Microsoft.CognitiveServices/accounts/", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Prompt Shield resource ID is outside the exact reviewed Azure RBAC scope boundary.'
        }
        $apiExpected.Add([ordered]@{ scope = $promptShieldId; roleDefinitionId = $cognitiveServicesUser })
    }

    $workerExpected = [Collections.Generic.List[object]]::new()
    $workerExpected.Add([ordered]@{ scope = $storageId; roleDefinitionId = $storageContributor })
    $workerExpected.Add([ordered]@{ scope = $expectedQueueId; roleDefinitionId = $serviceBusReceiver })
    if ($Config.purview.policyProvisioningEnabled -eq $true) {
        $certificateUri = [Uri][string]$Config.purview.policyProvisioningCertificateSecretUri
        $segments = @($certificateUri.AbsolutePath.Trim('/').Split('/', [StringSplitOptions]::RemoveEmptyEntries))
        if (-not $certificateUri.Host.Equals("kv-$($Config.projectName)-$($Config.environment).vault.azure.net", [StringComparison]::OrdinalIgnoreCase) -or
            $segments.Count -ne 2 -or [string]$segments[0] -cne 'secrets') {
            throw 'Purview certificate URI is outside the exact reviewed Azure RBAC secret scope.'
        }
        $workerExpected.Add([ordered]@{ scope = "$expectedVaultId/secrets/$([string]$segments[1])"; roleDefinitionId = $keyVaultSecretsUser })
    }

    $adminExpected = @(
        [ordered]@{ scope = $expectedRegistryId; roleDefinitionId = $acrPull },
        [ordered]@{ scope = "$expectedVaultId/secrets/admin-ui-entra-client-secret"; roleDefinitionId = $keyVaultSecretsUser }
    )
    $runtimeImagePullExpected = @(
        [ordered]@{
            scope = $expectedRegistryId
            roleDefinitionId = $acrPull
            assignmentId = $runtimeImagePullRoleAssignmentId
        }
    )

    Assert-GatewayServicePrincipalHasNoDirectoryMemberships -PrincipalId ([string]$Runtime.apiPrincipalId) -PrincipalLabel 'Gateway API identity' | Out-Null
    Assert-GatewayServicePrincipalHasNoDirectoryMemberships -PrincipalId ([string]$Runtime.workerPrincipalId) -PrincipalLabel 'Workflow-v3 worker identity' | Out-Null
    Assert-GatewayServicePrincipalHasNoDirectoryMemberships -PrincipalId $runtimeImagePullPrincipalId -PrincipalLabel 'Runtime image-pull identity' | Out-Null
    Assert-GatewayServicePrincipalHasNoDirectoryMemberships -PrincipalId ([string]$AdminUi.adminUiPrincipalId) -PrincipalLabel 'Admin UI identity' | Out-Null

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            Assert-GatewayPrincipalExactAzureRoleAssignments -PrincipalId ([string]$Runtime.apiPrincipalId) -SubscriptionId $subscriptionId -ExpectedAssignments @($apiExpected) -PrincipalLabel 'Gateway API identity' | Out-Null
            Assert-GatewayPrincipalExactAzureRoleAssignments -PrincipalId ([string]$Runtime.workerPrincipalId) -SubscriptionId $subscriptionId -ExpectedAssignments @($workerExpected) -PrincipalLabel 'Workflow-v3 worker identity' | Out-Null
            Assert-GatewayPrincipalExactAzureRoleAssignments -PrincipalId $runtimeImagePullPrincipalId -SubscriptionId $subscriptionId -ExpectedAssignments $runtimeImagePullExpected -PrincipalLabel 'Runtime image-pull identity' | Out-Null
            Assert-GatewayPrincipalExactAzureRoleAssignments -PrincipalId ([string]$AdminUi.adminUiPrincipalId) -SubscriptionId $subscriptionId -ExpectedAssignments $adminExpected -PrincipalLabel 'Admin UI identity' | Out-Null
            return $true
        }
        catch {
            if ($attempt -eq 6) {
                throw 'Dedicated runtime identities do not exactly match the reviewed Azure least-privilege role/scope matrix after bounded readback.'
            }
            Start-Sleep -Seconds 5
        }
    }
}

function Assert-GatewayExactAzureLocalCredentialControls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Runtime
    )

    $registryName = ([string]$Runtime.acrLoginServer).Split('.')[0]
    $subscriptionId = ([guid][string]$Config.subscriptionId).ToString('D')
    $registryId = "/subscriptions/$subscriptionId/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.ContainerRegistry/registries/$registryName"
    $registry = Invoke-AzJson -Arguments @(
        'resource', 'show', '--subscription', $subscriptionId,
        '--ids', $registryId, '--api-version', '2023-11-01-preview',
        '--query', '{id:id,adminUserEnabled:properties.adminUserEnabled,armAudienceStatus:properties.policies.azureADAuthenticationAsArmPolicy.status,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
    )
    if (-not ([string]$registry.id).Equals($registryId, [StringComparison]::OrdinalIgnoreCase) -or
        $registry.adminUserEnabled -ne $false -or
        [string]$registry.armAudienceStatus -cne 'enabled' -or
        [string]$registry.ownershipId -cne [string]$Runtime.deploymentOwnershipId -or
        [string]$registry.sourceFingerprint -cne [string]$Runtime.sourceFingerprint) {
        throw 'ACR local credentials, ARM-audience authentication, or deployment ownership/source controls are not exact.'
    }

    $storageName = ([string]$Runtime.storageAccountId).TrimEnd('/').Split('/')[-1]
    $storage = Invoke-AzJson -Arguments @(
        'storage', 'account', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $storageName,
        '--query', '{httpsOnly:enableHttpsTrafficOnly,minimumTlsVersion:minimumTlsVersion,allowBlobPublicAccess:allowBlobPublicAccess,allowSharedKeyAccess:allowSharedKeyAccess,publicNetworkAccess:publicNetworkAccess,defaultAction:networkRuleSet.defaultAction,bypass:networkRuleSet.bypass,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
    )
    if ($storage.httpsOnly -ne $true -or [string]$storage.minimumTlsVersion -cne 'TLS1_2' -or
        $storage.allowBlobPublicAccess -ne $false -or $storage.allowSharedKeyAccess -ne $false -or
        [string]$storage.publicNetworkAccess -cne 'Disabled' -or
        [string]$storage.defaultAction -cne 'Deny' -or [string]$storage.bypass -cne 'None' -or
        [string]$storage.ownershipId -cne [string]$Runtime.deploymentOwnershipId -or
        [string]$storage.sourceFingerprint -cne [string]$Runtime.sourceFingerprint) {
        throw 'Storage local keys, public access, TLS, network, or deployment controls are not exact.'
    }

    $serviceBusName = "sb-$($Config.projectName)-$($Config.environment)"
    $serviceBus = Invoke-AzJson -Arguments @(
        'servicebus', 'namespace', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $serviceBusName,
        '--query', '{disableLocalAuth:disableLocalAuth,minimumTlsVersion:minimumTlsVersion,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
    )
    if ($serviceBus.disableLocalAuth -ne $true -or [string]$serviceBus.minimumTlsVersion -cne '1.2' -or
        [string]$serviceBus.ownershipId -cne [string]$Runtime.deploymentOwnershipId -or
        [string]$serviceBus.sourceFingerprint -cne [string]$Runtime.sourceFingerprint) {
        throw 'Service Bus local authentication, TLS, or deployment controls are not exact.'
    }

    $serverName = ([string]$Runtime.sqlServerFqdn).Split('.')[0]
    $sql = Invoke-AzJson -Arguments @(
        'sql', 'server', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $serverName,
        '--query', '{minimalTlsVersion:minimalTlsVersion,publicNetworkAccess:publicNetworkAccess,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
    )
    $sqlAadOnly = Invoke-AzTsv -Arguments @(
        'sql', 'server', 'ad-only-auth', 'get', '--resource-group', [string]$Config.resourceGroupName,
        '--name', $serverName, '--query', 'azureAdOnlyAuthentication'
    )
    if ([string]$sql.minimalTlsVersion -cne '1.2' -or [string]$sql.publicNetworkAccess -cne 'Disabled' -or
        $sqlAadOnly -cne 'true' -or
        [string]$sql.ownershipId -cne [string]$Runtime.deploymentOwnershipId -or
        [string]$sql.sourceFingerprint -cne [string]$Runtime.sourceFingerprint) {
        throw 'Azure SQL Entra-only authentication, TLS, network, or deployment controls are not exact.'
    }

    foreach ($vaultName in @("kv-$($Config.projectName)-$($Config.environment)", "kv-$($Config.projectName)-$($Config.environment)-prov")) {
        $vault = Invoke-AzJson -Arguments @(
            'keyvault', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $vaultName,
            '--query', '{tenantId:properties.tenantId,enableRbacAuthorization:properties.enableRbacAuthorization,enableSoftDelete:properties.enableSoftDelete,softDeleteRetentionInDays:properties.softDeleteRetentionInDays,enablePurgeProtection:properties.enablePurgeProtection,enabledForDeployment:properties.enabledForDeployment,enabledForDiskEncryption:properties.enabledForDiskEncryption,enabledForTemplateDeployment:properties.enabledForTemplateDeployment,publicNetworkAccess:properties.publicNetworkAccess,defaultAction:properties.networkAcls.defaultAction,bypass:properties.networkAcls.bypass,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
        )
        if (-not ([string]$vault.tenantId).Equals([string]$Config.tenantId, [StringComparison]::OrdinalIgnoreCase) -or
            $vault.enableRbacAuthorization -ne $true -or $vault.enableSoftDelete -ne $true -or
            [int]$vault.softDeleteRetentionInDays -ne 90 -or $vault.enablePurgeProtection -ne $true -or
            $vault.enabledForDeployment -ne $false -or $vault.enabledForDiskEncryption -ne $false -or
            $vault.enabledForTemplateDeployment -ne $false -or [string]$vault.publicNetworkAccess -cne 'Disabled' -or
            [string]$vault.defaultAction -cne 'Allow' -or [string]$vault.bypass -cne 'AzureServices' -or
            [string]$vault.ownershipId -cne [string]$Runtime.deploymentOwnershipId -or
            [string]$vault.sourceFingerprint -cne [string]$Runtime.sourceFingerprint) {
            throw 'Key Vault RBAC, recovery, deployment, network, tenant, or source controls are not exact.'
        }
    }

    if ($Config.promptShield.enabled -eq $true) {
        $contentSafety = Invoke-AzJson -Arguments @(
            'resource', 'show', '--ids', [string]$Runtime.promptShieldAccountId, '--api-version', '2023-05-01',
            '--query', '{kind:kind,disableLocalAuth:properties.disableLocalAuth,publicNetworkAccess:properties.publicNetworkAccess,defaultAction:properties.networkAcls.defaultAction,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
        )
        if ([string]$contentSafety.kind -cne 'ContentSafety' -or $contentSafety.disableLocalAuth -ne $true -or
            [string]$contentSafety.publicNetworkAccess -cne 'Enabled' -or [string]$contentSafety.defaultAction -cne 'Allow' -or
            [string]$contentSafety.ownershipId -cne [string]$Runtime.deploymentOwnershipId -or
            [string]$contentSafety.sourceFingerprint -cne [string]$Runtime.sourceFingerprint) {
            throw 'Content Safety local authentication, network, or deployment controls are not exact.'
        }
    }
    return $true
}

function Assert-GatewayPurviewWorkerDeploymentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Runtime
    )

    $workerName = "ca-gateway-worker-$($Config.environment)-v3"
    $worker = Invoke-AzJson -Arguments @(
        'containerapp', 'show',
        '--resource-group', [string]$Config.resourceGroupName,
        '--name', $workerName
    )
    $containers = @($worker.properties.template.containers)
    if ($containers.Count -ne 1) {
        throw "Container App '$workerName' must expose exactly one reviewed worker container for Purview configuration readback."
    }

    $expectedEnvironment = [ordered]@{
        'Purview__Enabled' = ([bool]$Config.purview.activateGatewayAdapterAfterPolicyReadback).ToString().ToLowerInvariant()
        'Purview__PolicyProvisioningEnabled' = ([bool]$Config.purview.policyProvisioningEnabled).ToString().ToLowerInvariant()
        'Purview__PolicyProvisioningOrganization' = [string]$Config.purview.policyProvisioningOrganization
        'Purview__PolicyProvisioningApplicationId' = [string]$Config.purview.policyProvisioningApplicationId
        'Purview__PolicyProvisioningCertificateSecretUri' = [string]$Config.purview.policyProvisioningCertificateSecretUri
    }
    $environment = @($containers[0].env)
    foreach ($entry in $expectedEnvironment.GetEnumerator()) {
        $matches = @($environment | Where-Object { [string]$_.name -ceq [string]$entry.Key })
        if ($matches.Count -ne 1 -or [string]$matches[0].value -cne [string]$entry.Value) {
            throw "Container App '$workerName' does not exactly match the reviewed '$($entry.Key)' setting."
        }
    }

    $vaultName = "kv-$($Config.projectName)-$($Config.environment)"
    $vaultScope = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.KeyVault/vaults/$vaultName"
    $keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
    $workerRoleScope = $vaultScope
    if ($Config.purview.policyProvisioningEnabled -eq $true) {
        $certificateUri = [Uri][string]$Config.purview.policyProvisioningCertificateSecretUri
        $segments = @($certificateUri.AbsolutePath.Trim('/').Split('/', [StringSplitOptions]::RemoveEmptyEntries))
        if (-not $certificateUri.Host.Equals("$vaultName.vault.azure.net", [StringComparison]::OrdinalIgnoreCase) -or
            $segments.Count -ne 2 -or [string]$segments[0] -cne 'secrets') {
            throw 'The Purview automation certificate URI is outside the exact versionless shared-vault secret boundary.'
        }
        $secretName = [Uri]::UnescapeDataString([string]$segments[1])
        if ([string]::IsNullOrWhiteSpace($secretName) -or [Uri]::EscapeDataString($secretName) -cne [string]$segments[1]) {
            throw 'The Purview automation certificate secret name is not canonical.'
        }
        $workerRoleScope = "$vaultScope/secrets/$secretName"
    }
    $workerAssignments = @(Invoke-AzJsonArray -OperationLabel 'Worker shared-vault role-assignment verification' -Arguments @(
        'role', 'assignment', 'list',
        '--assignee-object-id', [string]$Runtime.workerPrincipalId,
        '--all',
        '--include-inherited',
        '--query', '[].{id:id,principalId:principalId,scope:scope,roleDefinitionId:roleDefinitionId}'
    ))
    $assignments = @($workerAssignments | Where-Object {
        Test-AzureRoleAssignmentScopeIntersects -AssignmentScope ([string]$_.scope) -ResourceScope $vaultScope
    })
    $expectedRoleCount = if ($Config.purview.policyProvisioningEnabled -eq $true) { 1 } else { 0 }
    if ($assignments.Count -ne $expectedRoleCount) {
        throw 'The worker has an unreviewed direct or inherited role at the Purview certificate vault.'
    }
    if ($expectedRoleCount -eq 1) {
        $assignment = $assignments[0]
        if (-not ([string]$assignment.principalId).Equals([string]$Runtime.workerPrincipalId, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$assignment.scope).Equals($workerRoleScope, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$assignment.roleDefinitionId).EndsWith("/$keyVaultSecretsUserRoleId", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The Purview certificate role must be only Key Vault Secrets User assigned to the exact worker identity at the exact certificate-secret scope.'
        }
    }

    $allApiAssignments = @(Invoke-AzJsonArray -OperationLabel 'Gateway API shared-vault role-assignment verification' -Arguments @(
        'role', 'assignment', 'list',
        '--assignee-object-id', [string]$Runtime.apiPrincipalId,
        '--all',
        '--include-inherited',
        '--query', '[].{id:id,principalId:principalId,scope:scope,roleDefinitionId:roleDefinitionId}'
    ))
    $apiVaultAssignments = @($allApiAssignments | Where-Object {
        Test-AzureRoleAssignmentScopeIntersects -AssignmentScope ([string]$_.scope) -ResourceScope $vaultScope
    })
    if ($apiVaultAssignments.Count -ne 0) {
        throw 'The Gateway API identity must have no direct or inherited Azure role at the shared Key Vault.'
    }
    return $true
}

function Get-GatewayPurviewCertificateMetadataEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    if ($Config.purview.policyProvisioningEnabled -ne $true) {
        return [ordered]@{
            status = 'NotConfigured'
            automationApplicationCertificateAndComplianceRbac = 'NotRequired'
            profileProvisioningReady = $true
        }
    }

    $secretUri = [Uri][string]$Config.purview.policyProvisioningCertificateSecretUri
    $expectedVaultName = "kv-$($Config.projectName)-$($Config.environment)"
    $expectedHost = "$expectedVaultName.vault.azure.net"
    $segments = @($secretUri.AbsolutePath.Trim('/').Split('/', [StringSplitOptions]::RemoveEmptyEntries))
    if (-not $secretUri.Host.Equals($expectedHost, [StringComparison]::OrdinalIgnoreCase) -or
        $segments.Count -ne 2 -or [string]$segments[0] -cne 'secrets') {
        throw 'Purview policy-provisioning certificate metadata is outside the exact shared-vault versionless secret boundary.'
    }
    $secretName = [Uri]::UnescapeDataString([string]$segments[1])
    if ([string]::IsNullOrWhiteSpace($secretName) -or [Uri]::EscapeDataString($secretName) -cne [string]$segments[1]) {
        throw 'Purview policy-provisioning certificate secret name is not canonical.'
    }
    $secretResourceId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.KeyVault/vaults/$expectedVaultName/secrets/$secretName"
    $secret = Invoke-AzJson -Arguments @(
        'resource', 'show', '--ids', $secretResourceId, '--api-version', '2023-07-01',
        '--query', '{id:id,name:name,enabled:properties.attributes.enabled}'
    )
    if (-not ([string]$secret.id).Equals($secretResourceId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$secret.name -cne $secretName -or $secret.enabled -ne $true) {
        throw 'Purview policy-provisioning certificate secret metadata was absent, disabled, or mismatched.'
    }
    return [ordered]@{
        status = 'MetadataPassed'
        secretResourceId = $secretResourceId
        secretEnabled = $true
        automationApplicationCertificateAndComplianceRbac = 'NotChecked'
        profileProvisioningReady = $false
    }
}

function Get-GatewayProvisioningPreflightArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$Blueprint,
        [Parameter(Mandatory)][string]$ExpectedRegistryProvider,
        [Parameter(Mandatory)][bool]$RuntimePreviewEnabled
    )

    # PowerShell array splatting is positional; strings such as '-Environment'
    # are not reparsed as named parameters. Keep this as one exact hashtable so
    # string-array values and switches reach the read-only preflight binder with
    # their intended names and types.
    $arguments = [ordered]@{
        Environment = [string]$Config.environment
        ExpectedSubscriptionId = [string]$Config.subscriptionId
        ExpectedTenantId = [string]$Config.tenantId
        ResourceGroup = [string]$Config.resourceGroupName
        ProjectName = [string]$Config.projectName
        ContainerAppsEnvironmentName = [string]$Foundation.containerAppsEnvironmentName
        WorkerContainerAppName = "ca-gateway-worker-$($Config.environment)-v3"
        ExpectedServiceBusQueueName = [string]$Runtime.serviceBusQueueName
        WorkerProcessingEnabled = [bool]$Runtime.workerProcessingEnabled
        ExpectedGatewayApiApplicationClientId = [string]$Identity.gatewayApiClientId
        ExpectedCredentialKeyVaultUri = "https://kv-$($Config.projectName)-$($Config.environment)-prov.vault.azure.net/"
        ExpectedManagerApplicationIds = [string[]]@($Blueprint.managerApplicationIds)
        RegistryProvider = $ExpectedRegistryProvider
        ExpectedGatewayApiFederatedCredentialName = "a365gw-$($Config.projectName)-api-obo-$($Config.environment)"
        ManagerApplicationsPreflightConfirmed = $true
        RequireDeployedConfigurationMatch = $true
    }
    if ($RuntimePreviewEnabled) {
        $arguments.DirectRegistryPreviewEnabled = $true
        $arguments.DelegatedRegistryEnabled = $true
        $arguments.RequireExecutionReady = $true
        $arguments.ExpectContinuousDevelopmentAccess = $true
    }
    return $arguments
}

function Test-GatewayBootstrapDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$Blueprint,
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)]$Database,
        [Parameter(Mandatory)]$SqlPrivateEndpoint,
        [Parameter(Mandatory)]$AdminUi,
        [Parameter(Mandatory)]$Images,
        [Parameter(Mandatory)]$AdminIdentity,
        [Parameter(Mandatory)]$AdminCredential,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [switch]$NonInteractive
    )
    $root = Get-BootstrapExecutionSourceRoot
    Assert-GatewayRuntimeDeploymentOwnership -Runtime $Runtime -DeploymentOwnershipId $DeploymentOwnershipId | Out-Null
    Test-GatewaySqlPrivateEndpointEvidence -Config $Config -Foundation $Foundation -SqlServerFqdn ([string]$Runtime.sqlServerFqdn) -Evidence $SqlPrivateEndpoint -DeploymentOwnershipId $DeploymentOwnershipId -SourceFingerprint ([string]$Images.sourceFingerprint) | Out-Null
    Assert-BootstrapFingerprintValue -Value ([string]$Images.sourceFingerprint) -Label 'Recorded image source fingerprint'
    Test-GatewayImmutableImageEvidence -Evidence $Images -SourceFingerprint ([string]$Images.sourceFingerprint) -DeploymentOwnershipId $DeploymentOwnershipId | Out-Null
    Test-GatewayRecordedDatabaseAttestationBoundary `
        -Config $Config `
        -Runtime $Runtime `
        -Database $Database `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint ([string]$Images.sourceFingerprint) | Out-Null
    Test-GatewayGroupDeploymentEvidence `
        -Config $Config `
        -Foundation $Foundation `
        -Identity $Identity `
        -Evidence $Runtime `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint ([string]$Images.sourceFingerprint) `
        -ApiImage ([string]$Images.api) `
        -WorkerImage ([string]$Images.worker) `
        -Database $Database | Out-Null
    Test-GatewayNamedGroupDeployment `
        -Config $Config `
        -Foundation $Foundation `
        -Runtime $Runtime `
        -Identity $Identity `
        -AdminIdentity $AdminIdentity `
        -AdminCredential $AdminCredential `
        -DeploymentName "a365gw-$($Config.projectName)-bootstrap-admin-$($Config.environment)" `
        -Evidence $AdminUi `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint ([string]$Images.sourceFingerprint) `
        -AdminUiImage ([string]$Images.adminUi) | Out-Null
    Assert-GatewayExactAzureRoleAssignments -Config $Config -Runtime $Runtime -AdminUi $AdminUi | Out-Null
    Assert-GatewayExactAzureLocalCredentialControls -Config $Config -Runtime $Runtime | Out-Null
    Test-GatewayApplicationEvidence -Config $Config -Evidence $Identity -ObjectIdProperty 'gatewayApiApplicationObjectId' -ClientIdProperty 'gatewayApiClientId' -ApplicationKind GatewayApi | Out-Null
    Test-GatewayApplicationEvidence -Config $Config -Evidence $AdminIdentity -ObjectIdProperty 'adminUiApplicationObjectId' -ClientIdProperty 'adminUiClientId' -ApplicationKind AdminUi -ExpectedAdminUiUrl ([string]$AdminUi.adminUiUrl) | Out-Null
    Test-GatewayBlueprintEvidence `
        -Config $Config `
        -Evidence $Blueprint `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint ([string]$Images.sourceFingerprint) `
        -SponsorObjectId ([string]$Identity.userObjectId) `
        -GatewayManagedIdentityPrincipalId ([string]$Runtime.workerPrincipalId) | Out-Null
    if ($Blueprint.managerApplicationsPreflightConfirmed -ne $true) {
        throw 'Agent 365 managerApplications were not independently confirmed against reviewed configuration.'
    }
    $credentialReadback = Get-AdminUiCredentialEvidenceFromMetadata -Config $Config -AdminIdentity $AdminIdentity -KeyVaultUri ([string]$Runtime.keyVaultUri) -MaximumAttempts 1
    $recordedExpiry = [DateTimeOffset]::MinValue
    $readbackExpiry = [DateTimeOffset]::MinValue
    if (-not ([string]$credentialReadback.credentialKeyId).Equals([string]$AdminCredential.credentialKeyId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$credentialReadback.secretUri -cne [string]$AdminCredential.secretUri -or
        -not [DateTimeOffset]::TryParse([string]$AdminCredential.credentialExpiresAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$recordedExpiry) -or
        -not [DateTimeOffset]::TryParse([string]$credentialReadback.credentialExpiresAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$readbackExpiry) -or
        $recordedExpiry.ToUniversalTime() -ne $readbackExpiry.ToUniversalTime()) {
        throw 'Admin UI credential evidence does not match exact Entra and Key Vault metadata during final verification.'
    }
    Assert-GatewayApiDelegatedPermissionBoundary -Identity $Identity -RequireComplete | Out-Null
    $expectedWorkerRoles = @(
        'Application.Read.All', 'AppRoleAssignment.ReadWrite.All',
        'AgentIdentityBlueprint.Create', 'AgentIdentityBlueprint.AddRemoveCreds.All',
        'AgentIdentityBlueprintPrincipal.Create', 'AgentIdentityBlueprint.Read.All',
        'AgentIdentity.Create.All', 'AgentIdentity.Read.All'
    )
    $expectedApiRoles = [Collections.Generic.List[string]]::new()
    $expectedApiRoles.Add('AgentIdentityBlueprint.Read.All')
    if ($Config.purview.enabled -eq $true) {
        foreach ($role in @('ProtectionScopes.Compute.User', 'Content.Process.User', 'ContentActivity.Write')) { $expectedApiRoles.Add($role) }
    }
    Assert-ExactGraphApplicationRoleAssignments -PrincipalId ([string]$Runtime.workerPrincipalId) -ExpectedRoleValues $expectedWorkerRoles | Out-Null
    Assert-ExactGraphApplicationRoleAssignments -PrincipalId ([string]$Runtime.apiPrincipalId) -ExpectedRoleValues @($expectedApiRoles) | Out-Null
    $serverName = ([string]$Runtime.sqlServerFqdn).Split('.')[0]
    $sqlPublic = Invoke-AzTsv -Arguments @('sql', 'server', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $serverName, '--query', 'publicNetworkAccess')
    if ($sqlPublic -ne 'Disabled') { throw 'Azure SQL public network access is not Disabled.' }
    foreach ($vault in @("kv-$($Config.projectName)-$($Config.environment)", "kv-$($Config.projectName)-$($Config.environment)-prov")) {
        $public = Invoke-AzTsv -Arguments @('keyvault', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $vault, '--query', 'properties.publicNetworkAccess')
        if ($public -ne 'Disabled') { throw "Key Vault '$vault' public network access is not Disabled." }
    }
    $expectedImages = [ordered]@{
        "ca-gateway-api-$($Config.environment)" = [string]$Images.api
        "ca-gateway-worker-$($Config.environment)-v3" = [string]$Images.worker
        "ca-gateway-admin-$($Config.environment)" = [string]$Images.adminUi
    }
    foreach ($entry in $expectedImages.GetEnumerator()) {
        $actualImage = Invoke-AzTsv -Arguments @('containerapp', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $entry.Key, '--query', 'properties.template.containers[0].image')
        if ($actualImage -ne $entry.Value) { throw "Container App '$($entry.Key)' is not running the recorded immutable image digest." }
    }
    Assert-GatewayPurviewWorkerDeploymentConfiguration -Config $Config -Runtime $Runtime | Out-Null
    $purviewProfilePrerequisites = Get-GatewayPurviewCertificateMetadataEvidence -Config $Config

    $purviewRoleIds = @(
        'fe696d63-5e1f-4515-8232-cccc316903c6',
        '24ceb246-ad29-4680-90b4-3e91ffad15eb',
        '2932e07a-3c29-44e4-bb36-6d0fc176387f'
    )
    if ($Config.purview.enabled -eq $true) {
        if ($NonInteractive) {
            throw 'Final Purview verification requires an interactive Security & Compliance session; non-interactive mode never starts or bypasses that sign-in.'
        }
        $assignments = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$($Runtime.apiPrincipalId)/appRoleAssignments?`$select=appRoleId,resourceId")
        $assignedIds = @($assignments | ForEach-Object { [string]$_.appRoleId })
        foreach ($roleId in $purviewRoleIds) {
            if ($assignedIds -notcontains $roleId) { throw "Gateway API managed identity is missing required Purview Graph role $roleId." }
        }
        $purviewConnectionId = ''
        try {
            $purviewConnectionId = Connect-BootstrapPurview -UserPrincipalName ([string]$Identity.userPrincipalName) -TenantId ([string]$Config.tenantId)
            $purviewReadback = Get-BootstrapPurviewPolicyEvidence -Config $Config -Blueprint $Blueprint -MaximumAttempts 1
            if ($purviewReadback.exactTypedReadback -ne $true) { throw 'Purview policy objects did not pass exact typed readback during final verification.' }
        }
        finally {
            if (-not [string]::IsNullOrWhiteSpace($purviewConnectionId)) { Disconnect-BootstrapPurview -ConnectionId $purviewConnectionId }
        }
    }

    $promptShieldVerification = 'NotConfigured'
    if ($Config.promptShield.enabled -eq $true) {
        if ([string]::IsNullOrWhiteSpace([string]$Runtime.promptShieldEndpoint) -or
            [string]::IsNullOrWhiteSpace([string]$Runtime.promptShieldAccountId) -or
            [string]::IsNullOrWhiteSpace([string]$Runtime.promptShieldAccountName)) {
            throw 'Prompt Shield is enabled but the Content Safety deployment outputs are incomplete.'
        }

        $contentSafety = Invoke-AzJson -Arguments @(
            'resource', 'show',
            '--ids', [string]$Runtime.promptShieldAccountId,
            '--api-version', '2023-05-01'
        )
        if ([string]$contentSafety.kind -ne 'ContentSafety') {
            throw "Resource '$($Runtime.promptShieldAccountName)' is not an Azure AI Content Safety account."
        }
        if ($contentSafety.properties.disableLocalAuth -ne $true) {
            throw "Azure AI Content Safety account '$($Runtime.promptShieldAccountName)' does not have local authentication disabled."
        }

        $promptShieldVerification = 'Passed'
    }

    $expectedSignIn = "$($AdminUi.adminUiUrl.TrimEnd('/'))/signin-oidc"
    $expectedSignOut = "$($AdminUi.adminUiUrl.TrimEnd('/'))/signout-callback-oidc"
    $redirectsVerified = $false
    for ($attempt = 1; $attempt -le 12 -and -not $redirectsVerified; $attempt++) {
        $adminApplication = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/applications/$($AdminIdentity.adminUiApplicationObjectId)?`$select=web,spa,publicClient,keyCredentials,api,isFallbackPublicClient")
        $redirectsVerified = Test-ExactAdminUiRuntimeApplicationSurface `
            -Application $adminApplication `
            -ExpectedSignInRedirectUri $expectedSignIn `
            -ExpectedSignedOutCallbackUri $expectedSignOut
        if (-not $redirectsVerified -and $attempt -lt 12) { Start-Sleep -Seconds 5 }
    }
    if (-not $redirectsVerified) {
        throw 'Admin UI Entra redirect/logout URIs do not match the deployed HTTPS endpoint.'
    }
    $allAdminGrants = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId%20eq%20'$($AdminIdentity.adminUiServicePrincipalId)'&`$select=id,resourceId,consentType,scope")
    $adminGrantScopes = if ($allAdminGrants.Count -eq 1) { @(([string]$allAdminGrants[0].scope).Split(' ', [StringSplitOptions]::RemoveEmptyEntries -bor [StringSplitOptions]::TrimEntries)) } else { @() }
    if ($allAdminGrants.Count -ne 1 -or
        -not ([string]$allAdminGrants[0].resourceId).Equals([string]$Identity.gatewayApiServicePrincipalId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$allAdminGrants[0].consentType -cne 'AllPrincipals' -or
        $adminGrantScopes.Count -ne 1 -or [string]$adminGrantScopes[0] -cne 'access_as_user') {
        throw 'Admin UI delegated consent is not exactly one tenant-wide access_as_user grant to the Gateway API.'
    }

    $provisioningMode = Get-GatewayRuntimeProvisioningMode -Config $Config -Runtime $Runtime
    $previewRequested = [bool]$provisioningMode.previewRequested
    $runtimePreviewEnabled = [bool]$provisioningMode.runtimePreviewEnabled
    $expectedRegistryProvider = [string]$provisioningMode.expectedRegistryProvider
    $provisioningAdmissionReady = $runtimePreviewEnabled -and $purviewProfilePrerequisites.profileProvisioningReady -eq $true
    $preflightArguments = Get-GatewayProvisioningPreflightArguments `
        -Config $Config `
        -Foundation $Foundation `
        -Runtime $Runtime `
        -Identity $Identity `
        -Blueprint $Blueprint `
        -ExpectedRegistryProvider $expectedRegistryProvider `
        -RuntimePreviewEnabled $runtimePreviewEnabled
    & (Join-Path $root 'operations/test-provisioning-prerequisites.ps1') @preflightArguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Read-only provisioning preflight failed.' }

    $apiHealth = Wait-HttpsHealth -Url "https://$($Runtime.apiFqdn)/health/checks"
    $databaseAttestation = Get-GatewayCurrentDatabaseAttestationEvidence -ApiFqdn ([string]$Runtime.apiFqdn)
    $adminHealth = Wait-HttpsHealth -Url "$($AdminUi.adminUiUrl.TrimEnd('/'))/health"
    return [ordered]@{
        verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        api = $apiHealth
        adminUi = $adminHealth
        sqlPublicNetworkAccess = $sqlPublic
        keyVaultPublicNetworkAccess = 'Disabled'
        sqlPrivateEndpoint = 'Passed'
        databaseAttestation = $databaseAttestation
        immutableImages = $expectedImages
        azureRbac = 'Passed'
        azureLocalCredentialControls = 'Passed'
        purviewGraphRoles = if ($Config.purview.enabled -eq $true) { 'Passed' } else { 'NotConfigured' }
        purviewWorkerConfiguration = 'Passed'
        purviewPolicyProfilePrerequisites = $purviewProfilePrerequisites
        promptShield = $promptShieldVerification
        adminUiIdentity = 'Passed'
        adminUiCredential = 'Passed'
        deploymentVerification = 'Passed'
        provisioningPreflight = if ($provisioningAdmissionReady) {
            'ExecutionReadyPassed'
        }
        elseif ($previewRequested -and $Config.purview.policyProvisioningEnabled -eq $true) {
            'ConfigurationVerifiedPurviewProfileAuthorityNotChecked'
        }
        else { 'ConfigurationVerifiedAdmissionClosed' }
        provisioningAdmissionReady = [bool]$provisioningAdmissionReady
        registrationMode = if ($provisioningAdmissionReady) {
            'ContinuousDevelopmentPreview'
        }
        elseif ($previewRequested -and $Config.purview.policyProvisioningEnabled -eq $true) {
            'DevelopmentPreviewPurviewProfileAuthorityNotChecked'
        }
        else { 'ClosedUnsupportedForProduction' }
    }
}

Export-ModuleMember -Function *
