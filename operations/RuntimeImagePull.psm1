Set-StrictMode -Version Latest

$script:AcrPullRoleDefinitionGuid = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
$script:ArmGuidNamespace = [guid]'11fb06fb-712d-4ddd-98c7-e71bbd588830'

function Convert-GuidByteOrder {
    param([byte[]]$Bytes)

    [array]::Reverse($Bytes, 0, 4)
    [array]::Reverse($Bytes, 4, 2)
    [array]::Reverse($Bytes, 6, 2)
}

function Get-ArmDeterministicGuid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Values
    )

    # ARM/Bicep guid() is UUID v5 using this fixed namespace and the stringified
    # arguments joined with '-'. RFC 4122 hashes the namespace in network order.
    $namespaceBytes = $script:ArmGuidNamespace.ToByteArray()
    Convert-GuidByteOrder -Bytes $namespaceBytes
    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes(($Values -join '-'))
    $hashInput = [byte[]]::new($namespaceBytes.Length + $nameBytes.Length)
    [array]::Copy($namespaceBytes, 0, $hashInput, 0, $namespaceBytes.Length)
    [array]::Copy($nameBytes, 0, $hashInput, $namespaceBytes.Length, $nameBytes.Length)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($hashInput)
    }
    finally {
        $sha1.Dispose()
    }

    $guidBytes = [byte[]]::new(16)
    [array]::Copy($hash, $guidBytes, 16)
    $guidBytes[6] = [byte](($guidBytes[6] -band 0x0f) -bor 0x50)
    $guidBytes[8] = [byte](($guidBytes[8] -band 0x3f) -bor 0x80)
    Convert-GuidByteOrder -Bytes $guidBytes
    return ([guid]::new($guidBytes)).ToString('D')
}

function Invoke-RuntimeImagePullAzureJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage,

        [scriptblock]$AzureInvoker
    )

    if ($null -eq $AzureInvoker) {
        $AzureInvoker = {
            param([string[]]$Arguments)

            $result = & az @Arguments 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw 'Azure CLI read failed.'
            }
            return $result
        }
    }

    try {
        $raw = & $AzureInvoker -Arguments $Arguments
        $json = ($raw | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw 'Azure CLI returned no JSON.'
        }
        return $json | ConvertFrom-Json
    }
    catch {
        throw $FailureMessage
    }
}

function Get-RuntimeImagePullOptionalProperty {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Assert-RuntimeImageAcrBinding {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,

        [AllowEmptyString()]
        [string]$ExpectedAcrName,

        [AllowEmptyString()]
        [string]$ExpectedAcrLoginServer,

        [Parameter(Mandatory = $true)]
        [string]$AcrScope,

        [Parameter(Mandatory = $true)]
        [string]$ActualAcrLoginServer,

        [AllowEmptyString()]
        [string]$ApiContainerImage,

        [AllowEmptyString()]
        [string]$WorkerContainerImage
    )

    $expectedAcrId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ContainerRegistry/registries/$ExpectedAcrName"
    if ($ExpectedAcrName -cnotmatch '^[a-z0-9]{5,50}$' -or
        $ExpectedAcrLoginServer -cnotmatch '^[a-z0-9][a-z0-9.-]+$' -or
        -not [string]::Equals($AcrScope, $expectedAcrId, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($ActualAcrLoginServer, $ExpectedAcrLoginServer, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runtime image-pull validation requires the exact expected deployment ACR name, resource ID, and login server.'
    }

    $imagePattern = '^{0}/[a-z0-9._/-]+@sha256:[0-9a-f]{{64}}$' -f [regex]::Escape($ExpectedAcrLoginServer)
    if ($ApiContainerImage -cnotmatch $imagePattern -or
        $WorkerContainerImage -cnotmatch $imagePattern) {
        throw 'Runtime images must be immutable digest references hosted by the exact expected deployment ACR.'
    }
}

function Assert-ExactAcrPullAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$AcrScope,

        [Parameter(Mandatory = $true)]
        [string]$PrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedAssignmentName,

        [scriptblock]$AzureInvoker
    )

    $expectedAssignmentId = "$($AcrScope.TrimEnd('/'))/providers/Microsoft.Authorization/roleAssignments/$ExpectedAssignmentName"
    [object[]]$assignments = @(Invoke-RuntimeImagePullAzureJson -Arguments @(
            'role', 'assignment', 'list',
            '--scope', $AcrScope,
            '--assignee-object-id', $PrincipalId,
            '--fill-principal-name', 'false',
            '--fill-role-definition-name', 'false',
            '--subscription', $SubscriptionId,
            '--query', '[].{id:id,name:name,principalId:principalId,principalType:principalType,scope:scope,roleDefinitionId:roleDefinitionId,condition:condition,conditionVersion:conditionVersion,delegatedManagedIdentityResourceId:delegatedManagedIdentityResourceId}',
            '--output', 'json',
            '--only-show-errors'
        ) -FailureMessage 'The exact runtime image-pull AcrPull assignment could not be read back.' -AzureInvoker $AzureInvoker)
    $expectedRoleDefinitionId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$($script:AcrPullRoleDefinitionGuid)"
    if ($assignments.Count -ne 1) {
        throw 'Runtime image pull requires the exact deterministic direct AcrPull assignment.'
    }
    $assignment = $assignments[0]
    if (-not [string]::Equals([string]$assignment.name, $ExpectedAssignmentName, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$assignment.id, $expectedAssignmentId, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$assignment.principalId, $PrincipalId, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]$assignment.principalType -cne 'ServicePrincipal' -or
        -not [string]::Equals([string]$assignment.scope, $AcrScope, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$assignment.roleDefinitionId, $expectedRoleDefinitionId, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-RuntimeImagePullOptionalProperty -InputObject $assignment -Name 'condition')) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-RuntimeImagePullOptionalProperty -InputObject $assignment -Name 'conditionVersion')) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-RuntimeImagePullOptionalProperty -InputObject $assignment -Name 'delegatedManagedIdentityResourceId'))) {
        throw 'Runtime image pull requires the exact deterministic direct AcrPull assignment.'
    }

    return $expectedAssignmentId
}

function Assert-NoDirectSystemAcrPullAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$AcrScope,

        [Parameter(Mandatory = $true)]
        [string]$PrincipalId,

        [scriptblock]$AzureInvoker
    )

    [object[]]$assignments = @(Invoke-RuntimeImagePullAzureJson -Arguments @(
            'role', 'assignment', 'list',
            '--scope', $AcrScope,
            '--assignee-object-id', $PrincipalId,
            '--fill-principal-name', 'false',
            '--fill-role-definition-name', 'false',
            '--subscription', $SubscriptionId,
            '--query', '[].{id:id,principalId:principalId,principalType:principalType,scope:scope,roleDefinitionId:roleDefinitionId,condition:condition,conditionVersion:conditionVersion,delegatedManagedIdentityResourceId:delegatedManagedIdentityResourceId}',
            '--output', 'json',
            '--only-show-errors'
        ) -FailureMessage 'Existing workload system-identity AcrPull assignments could not be read back.' -AzureInvoker $AzureInvoker)
    $expectedRoleDefinitionId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$($script:AcrPullRoleDefinitionGuid)"
    $directAcrPull = @($assignments | Where-Object {
            [string]::Equals([string]$_.principalId, $PrincipalId, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$_.scope, $AcrScope, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$_.roleDefinitionId, $expectedRoleDefinitionId, [System.StringComparison]::OrdinalIgnoreCase)
        })
    if ($directAcrPull.Count -ne 0) {
        throw 'Populated runtime image-pull receipts cannot silently migrate an existing system-identity deployment while direct system AcrPull remains. Use a separately reviewed migration; this path never deletes role assignments.'
    }
}

function Assert-GatewayRuntimeImagePullContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroup,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ApiContainerAppName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkerContainerAppName,

        [AllowEmptyString()]
        [string]$ExpectedAcrName = '',

        [AllowEmptyString()]
        [string]$ExpectedAcrLoginServer = '',

        [AllowEmptyString()]
        [string]$ApiContainerImage = '',

        [AllowEmptyString()]
        [string]$WorkerContainerImage = '',

        [AllowEmptyString()]
        [string]$RuntimeImagePullIdentityId = '',

        [AllowEmptyString()]
        [string]$RuntimeImagePullIdentityPrincipalId = '',

        [AllowEmptyString()]
        [string]$RuntimeImagePullAcrPullRoleAssignmentId = '',

        [switch]$AllowExistingLegacySystemAssignedImagePull,

        [switch]$AllowFreshDedicatedImagePull,

        [scriptblock]$AzureInvoker
    )

    $subscriptionGuid = [guid]::Empty
    if (-not [guid]::TryParse($SubscriptionId, [ref]$subscriptionGuid) -or
        $subscriptionGuid -eq [guid]::Empty) {
        throw 'SubscriptionId must be one non-empty GUID.'
    }
    $canonicalSubscriptionId = $subscriptionGuid.ToString('D')
    $values = @(
        $RuntimeImagePullIdentityId,
        $RuntimeImagePullIdentityPrincipalId,
        $RuntimeImagePullAcrPullRoleAssignmentId)
    $populatedCount = @($values | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }).Count
    if ($populatedCount -notin @(0, 3)) {
        throw 'Runtime image-pull identity inputs must be either all empty for a guarded legacy update or all populated with the exact foundation receipts.'
    }

    $guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    if ($populatedCount -eq 3) {
        $identityId = $RuntimeImagePullIdentityId.TrimEnd('/')
        $roleAssignmentId = $RuntimeImagePullAcrPullRoleAssignmentId.TrimEnd('/')
        $identityMatch = [regex]::Match(
            $identityId,
            "^/subscriptions/(?<subscription>$guidPattern)/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/(?<name>[^/]+)$",
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $roleMatch = [regex]::Match(
            $roleAssignmentId,
            "^(?<scope>/subscriptions/(?<subscription>$guidPattern)/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.ContainerRegistry/registries/(?<registry>[^/]+))/providers/Microsoft\.Authorization/roleAssignments/(?<assignment>$guidPattern)$",
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $principalGuid = [guid]::Empty
        if (-not $identityMatch.Success -or
            -not $roleMatch.Success -or
            -not [guid]::TryParse($RuntimeImagePullIdentityPrincipalId, [ref]$principalGuid) -or
            $principalGuid -eq [guid]::Empty -or
            $RuntimeImagePullIdentityPrincipalId -cne $principalGuid.ToString('D') -or
            -not [string]::Equals($identityMatch.Groups['subscription'].Value, $canonicalSubscriptionId, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($roleMatch.Groups['subscription'].Value, $canonicalSubscriptionId, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($identityMatch.Groups['resourceGroup'].Value, $ResourceGroup, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($roleMatch.Groups['resourceGroup'].Value, $ResourceGroup, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Runtime image-pull identity receipts are not canonical or do not match the selected subscription/resource group.'
        }

        $identity = Invoke-RuntimeImagePullAzureJson -Arguments @(
            'identity', 'show',
            '--ids', $identityId,
            '--subscription', $canonicalSubscriptionId,
            '--query', '{id:id,principalId:principalId}',
            '--output', 'json',
            '--only-show-errors'
        ) -FailureMessage 'The dedicated runtime image-pull identity could not be read back.' -AzureInvoker $AzureInvoker
        if (-not [string]::Equals([string]$identity.id, $identityId, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$identity.principalId, $principalGuid.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'The dedicated runtime image-pull identity readback does not match the supplied receipts.'
        }

        $acrScope = $roleMatch.Groups['scope'].Value
        if (-not [string]::Equals(
                $roleMatch.Groups['registry'].Value,
                $ExpectedAcrName,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'The dedicated runtime image-pull role receipt is not scoped to the exact expected deployment ACR.'
        }
        $expectedAssignmentName = Get-ArmDeterministicGuid -Values @(
            $acrScope,
            $identityId,
            $script:AcrPullRoleDefinitionGuid)
        if (-not [string]::Equals(
                $roleMatch.Groups['assignment'].Value,
                $expectedAssignmentName,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'The dedicated runtime image-pull role receipt does not have the exact deterministic assignment name.'
        }
        $validatedAssignmentId = Assert-ExactAcrPullAssignment `
            -SubscriptionId $canonicalSubscriptionId `
            -AcrScope $acrScope `
            -PrincipalId $principalGuid.ToString('D') `
            -ExpectedAssignmentName $expectedAssignmentName `
            -AzureInvoker $AzureInvoker

        $acr = Invoke-RuntimeImagePullAzureJson -Arguments @(
            'acr', 'show',
            '--ids', $acrScope,
            '--subscription', $canonicalSubscriptionId,
            '--query', '{id:id,loginServer:loginServer}',
            '--output', 'json',
            '--only-show-errors'
        ) -FailureMessage 'The exact ACR could not be read back for dedicated runtime image-pull validation.' -AzureInvoker $AzureInvoker
        if (-not [string]::Equals([string]$acr.id, $acrScope, [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::IsNullOrWhiteSpace([string]$acr.loginServer)) {
            throw 'The dedicated runtime image-pull ACR readback does not match the exact role-assignment scope.'
        }
        Assert-RuntimeImageAcrBinding `
            -SubscriptionId $canonicalSubscriptionId `
            -ResourceGroup $ResourceGroup `
            -ExpectedAcrName $ExpectedAcrName `
            -ExpectedAcrLoginServer $ExpectedAcrLoginServer `
            -AcrScope $acrScope `
            -ActualAcrLoginServer ([string]$acr.loginServer) `
            -ApiContainerImage $ApiContainerImage `
            -WorkerContainerImage $WorkerContainerImage

        $containerApps = @(Invoke-RuntimeImagePullAzureJson -Arguments @(
                'containerapp', 'list',
                '--resource-group', $ResourceGroup,
                '--subscription', $canonicalSubscriptionId,
                '--query', '[].{name:name,id:id,principalId:identity.principalId,identityType:identity.type,userAssignedIdentities:identity.userAssignedIdentities,registries:properties.configuration.registries[].{server:server,identity:identity}}',
                '--output', 'json',
                '--only-show-errors'
            ) -FailureMessage 'Existing workload identity and registry configuration could not be read back.' -AzureInvoker $AzureInvoker)
        $expectedWorkloads = @(
            @{ Label = 'API'; Name = $ApiContainerAppName },
            @{ Label = 'worker'; Name = $WorkerContainerAppName })
        $existingWorkloads = [System.Collections.Generic.List[object]]::new()
        foreach ($expectedWorkload in $expectedWorkloads) {
            $matches = @($containerApps | Where-Object {
                    [string]::Equals(
                        [string]$_.name,
                        [string]$expectedWorkload.Name,
                        [System.StringComparison]::OrdinalIgnoreCase)
                })
            if ($matches.Count -gt 1) {
                throw "Existing $($expectedWorkload.Label) Container App readback is ambiguous."
            }
            if ($matches.Count -eq 1) {
                $existingWorkloads.Add([pscustomobject]@{
                        Label = $expectedWorkload.Label
                        Name = $expectedWorkload.Name
                        Value = $matches[0]
                    })
            }
        }

        if ($AllowFreshDedicatedImagePull) {
            if ($existingWorkloads.Count -ne 0) {
                throw 'Fresh dedicated runtime image-pull authorization requires both workload Container Apps to be absent. Existing workloads require a separately reviewed migration.'
            }
        }
        else {
            if ($existingWorkloads.Count -ne 2) {
                throw 'Dedicated runtime image-pull deployment is neither an explicitly authorized fresh deployment nor an already-migrated exact workload pair.'
            }
            foreach ($workload in $existingWorkloads) {
                $observed = $workload.Value
                $expectedAppId = "/subscriptions/$canonicalSubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$($workload.Name)"
                $systemPrincipalGuid = [guid]::Empty
                [string[]]$identityTypes = @(([string]$observed.identityType).Split(',') | ForEach-Object {
                        $_.Trim()
                    })
                [string[]]$userAssignedIdentityIds = @()
                $userAssignedIdentities = Get-RuntimeImagePullOptionalProperty `
                    -InputObject $observed `
                    -Name 'userAssignedIdentities'
                if ($null -ne $userAssignedIdentities) {
                    $userAssignedIdentityIds = @(
                        $userAssignedIdentities.PSObject.Properties |
                            ForEach-Object { $_.Name }
                    )
                }
                [object[]]$registries = @($observed.registries)
                if (-not [string]::Equals([string]$observed.id, $expectedAppId, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $identityTypes -notcontains 'SystemAssigned' -or
                    $identityTypes -notcontains 'UserAssigned' -or
                    -not [guid]::TryParse([string]$observed.principalId, [ref]$systemPrincipalGuid) -or
                    $systemPrincipalGuid -eq [guid]::Empty -or
                    $userAssignedIdentityIds.Count -ne 1 -or
                    -not [string]::Equals([string]$userAssignedIdentityIds[0], $identityId, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $registries.Count -ne 1 -or
                    -not [string]::Equals([string]$registries[0].server, [string]$acr.loginServer, [System.StringComparison]::OrdinalIgnoreCase) -or
                    -not [string]::Equals([string]$registries[0].identity, $identityId, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Existing $($workload.Label) Container App is not already migrated to exactly the supplied dedicated runtime image-pull identity. Use a separately reviewed migration."
                }
                Assert-NoDirectSystemAcrPullAssignment `
                    -SubscriptionId $canonicalSubscriptionId `
                    -AcrScope $acrScope `
                    -PrincipalId $systemPrincipalGuid.ToString('D') `
                    -AzureInvoker $AzureInvoker
            }
        }

        return [pscustomobject]@{
            Mode = 'DedicatedUserAssignedIdentity'
            IdentityId = $identityId
            PrincipalId = $principalGuid.ToString('D')
            RoleAssignmentId = $validatedAssignmentId
            AllowLegacySystemAssignedImagePull = $false
        }
    }

    if (-not $AllowExistingLegacySystemAssignedImagePull) {
        throw 'A fresh private-image deployment cannot use the legacy post-compute system-identity AcrPull path. Supply the complete pre-authorized runtime image-pull identity receipt triple.'
    }

    $workloads = @(
        @{ Label = 'API'; Name = $ApiContainerAppName },
        @{ Label = 'worker'; Name = $WorkerContainerAppName })
    $validatedWorkloads = [System.Collections.Generic.List[object]]::new()
    foreach ($workload in $workloads) {
        $observed = Invoke-RuntimeImagePullAzureJson -Arguments @(
            'containerapp', 'show',
            '--name', $workload.Name,
            '--resource-group', $ResourceGroup,
            '--subscription', $canonicalSubscriptionId,
            '--query', '{id:id,principalId:identity.principalId,identityType:identity.type,userAssignedIdentities:identity.userAssignedIdentities,registries:properties.configuration.registries[].{server:server,identity:identity}}',
            '--output', 'json',
            '--only-show-errors'
        ) -FailureMessage "Legacy runtime image pull requires the existing $($workload.Label) Container App." -AzureInvoker $AzureInvoker
        $expectedAppId = "/subscriptions/$canonicalSubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$($workload.Name)"
        $principalGuid = [guid]::Empty
        [object[]]$registries = @($observed.registries)
        [string[]]$identityTypes = @(([string]$observed.identityType).Split(',') | ForEach-Object {
                $_.Trim()
            })
        [string[]]$userAssignedIdentityIds = @()
        $userAssignedIdentities = Get-RuntimeImagePullOptionalProperty `
            -InputObject $observed `
            -Name 'userAssignedIdentities'
        if ($null -ne $userAssignedIdentities) {
            $userAssignedIdentityIds = @(
                $userAssignedIdentities.PSObject.Properties |
                    ForEach-Object { $_.Name }
            )
        }
        if (-not [string]::Equals([string]$observed.id, $expectedAppId, [System.StringComparison]::OrdinalIgnoreCase) -or
            $identityTypes.Count -ne 1 -or
            -not [string]::Equals([string]$identityTypes[0], 'SystemAssigned', [System.StringComparison]::Ordinal) -or
            $userAssignedIdentityIds.Count -ne 0 -or
            -not [guid]::TryParse([string]$observed.principalId, [ref]$principalGuid) -or
            $principalGuid -eq [guid]::Empty -or
            $registries.Count -ne 1 -or
            [string]::IsNullOrWhiteSpace([string]$registries[0].server) -or
            -not [string]::Equals([string]$registries[0].identity, 'system', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Legacy runtime image pull requires the existing $($workload.Label) Container App to use exactly its system identity for one ACR registry entry."
        }
        $validatedWorkloads.Add([pscustomobject]@{
                Label = $workload.Label
                PrincipalId = $principalGuid.ToString('D')
                RegistryServer = [string]$registries[0].server
            })
    }

    if (-not [string]::Equals(
            $validatedWorkloads[0].RegistryServer,
            $validatedWorkloads[1].RegistryServer,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Legacy runtime image pull requires the existing API and worker to use the same exact ACR login server.'
    }
    $registries = @(Invoke-RuntimeImagePullAzureJson -Arguments @(
            'acr', 'list',
            '--resource-group', $ResourceGroup,
            '--subscription', $canonicalSubscriptionId,
            '--query', '[].{id:id,loginServer:loginServer}',
            '--output', 'json',
            '--only-show-errors'
        ) -FailureMessage 'The existing ACR could not be read back for legacy runtime image-pull validation.' -AzureInvoker $AzureInvoker)
    $matchingRegistries = @($registries | Where-Object {
            [string]::Equals(
                [string]$_.loginServer,
                [string]$validatedWorkloads[0].RegistryServer,
                [System.StringComparison]::OrdinalIgnoreCase)
        })
    $acrScopePattern = "^/subscriptions/$canonicalSubscriptionId/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.ContainerRegistry/registries/(?<registry>[^/]+)$"
    if ($matchingRegistries.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$matchingRegistries[0].id) -or
        -not [regex]::IsMatch([string]$matchingRegistries[0].id, $acrScopePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        throw 'Legacy runtime image pull requires one exact existing ACR matching both workload registry entries.'
    }
    $acrScope = ([string]$matchingRegistries[0].id).TrimEnd('/')
    Assert-RuntimeImageAcrBinding `
        -SubscriptionId $canonicalSubscriptionId `
        -ResourceGroup $ResourceGroup `
        -ExpectedAcrName $ExpectedAcrName `
        -ExpectedAcrLoginServer $ExpectedAcrLoginServer `
        -AcrScope $acrScope `
        -ActualAcrLoginServer ([string]$matchingRegistries[0].loginServer) `
        -ApiContainerImage $ApiContainerImage `
        -WorkerContainerImage $WorkerContainerImage
    foreach ($workload in $validatedWorkloads) {
        $expectedAssignmentName = Get-ArmDeterministicGuid -Values @(
            "/subscriptions/$canonicalSubscriptionId",
            $workload.PrincipalId,
            $acrScope,
            $script:AcrPullRoleDefinitionGuid)
        Assert-ExactAcrPullAssignment `
            -SubscriptionId $canonicalSubscriptionId `
            -AcrScope $acrScope `
            -PrincipalId $workload.PrincipalId `
            -ExpectedAssignmentName $expectedAssignmentName `
            -AzureInvoker $AzureInvoker | Out-Null
    }

    return [pscustomobject]@{
        Mode = 'LegacySystemAssignedIdentity'
        IdentityId = ''
        PrincipalId = ''
        RoleAssignmentId = ''
        AllowLegacySystemAssignedImagePull = $true
    }
}

Export-ModuleMember -Function @(
    'Assert-GatewayRuntimeImagePullContract',
    'Get-ArmDeterministicGuid')
