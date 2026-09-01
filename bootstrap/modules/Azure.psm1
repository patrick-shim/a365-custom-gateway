Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-GatewayCanonicalAzureLocation {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Location)

    if ([string]::IsNullOrEmpty($Location) -or $Location -cnotmatch '\A[A-Za-z0-9 ]+\z') {
        throw 'An Azure location must contain only ASCII letters, digits, and spaces.'
    }
    $canonical = $Location.Replace(' ', '').ToLowerInvariant()
    if ([string]::IsNullOrEmpty($canonical)) {
        throw 'An Azure location cannot be empty after removing ASCII spaces.'
    }
    return $canonical
}

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

function Assert-BootstrapAzureContext {
    param([Parameter(Mandatory)]$Config)

    $account = Invoke-AzJson -Arguments @('account', 'show')
    if (-not $account -or
        [string]$account.tenantId -ne [string]$Config.tenantId -or
        [string]$account.id -ne [string]$Config.subscriptionId) {
        throw 'The explicitly pinned Azure subscription no longer resolves to the configured tenant and subscription.'
    }
    return $true
}

function Get-GatewayAzureCapabilityProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($InputObject -is [Collections.IDictionary]) {
        if (-not $InputObject.Contains($Name)) { return $null }
        $value = $InputObject[$Name]
        if ($value -is [System.Array]) { return ,$value }
        return $value
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    if ($property.Value -is [System.Array]) { return ,$property.Value }
    return $property.Value
}

function Get-GatewayAzureCapabilityArray {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $value = Get-GatewayAzureCapabilityProperty -InputObject $InputObject -Name $Name
    if ($value -isnot [System.Array]) {
        throw [IO.InvalidDataException]::new("The Azure capability property '$Name' was not an array.")
    }
    return $value
}

function Test-GatewayAzureCapabilityAvailable {
    param([Parameter(Mandatory)]$Capability)

    $status = Get-GatewayAzureCapabilityProperty -InputObject $Capability -Name 'status'
    return $status -is [string] -and [string]$status -cin @('Available', 'Default')
}

function Get-GatewayAzureCapabilityInt32 {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Label,
        [switch]$NonNegative
    )

    $value = Get-GatewayAzureCapabilityProperty -InputObject $InputObject -Name $Name
    # ConvertFrom-Json materializes JSON integer tokens as Int64. Requiring that
    # exact runtime type rejects quoted numbers, floating-point values, booleans,
    # and every other coercible-but-out-of-schema representation.
    if ($value -isnot [long] -or
        $value -lt [int]::MinValue -or
        $value -gt [int]::MaxValue -or
        ($NonNegative -and $value -lt 0)) {
        throw [IO.InvalidDataException]::new("$Label was not a valid int32 JSON value.")
    }
    return [int]$value
}

function ConvertTo-GatewaySqlCapabilityBytes {
    param([Parameter(Mandatory)]$SizeValue)

    $unitValue = Get-GatewayAzureCapabilityProperty -InputObject $SizeValue -Name 'unit'
    if ($unitValue -isnot [string]) {
        throw [IO.InvalidDataException]::new('An Azure SQL size capability was incomplete.')
    }

    $limit = Get-GatewayAzureCapabilityInt32 `
        -InputObject $SizeValue `
        -Name 'limit' `
        -Label 'An Azure SQL size capability limit' `
        -NonNegative

    $multiplier = switch -CaseSensitive ([string]$unitValue) {
        'Megabytes' { [decimal]1048576 }
        'Gigabytes' { [decimal]1073741824 }
        'Terabytes' { [decimal]1099511627776 }
        'Petabytes' { [decimal]1125899906842624 }
        default { throw [IO.InvalidDataException]::new('An Azure SQL size capability used an unknown unit.') }
    }
    $bytes = $limit * $multiplier
    if ($bytes -ne [decimal]::Truncate($bytes) -or $bytes -gt [long]::MaxValue) {
        throw [IO.InvalidDataException]::new('An Azure SQL size capability could not be represented exactly in bytes.')
    }
    return [long]$bytes
}

function Assert-GatewaySqlRegionalAvailability {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $location = [string]$Config.location
    $skuName = [string]$Config.sql.skuName
    $skuTier = [string]$Config.sql.skuTier
    $safeFailure = "Azure SQL $skuName/$skuTier (2 GiB, LRS) is not currently proven available in '$location'. Choose another region and run Plan again. Provider details were suppressed."
    $safeCheck = 'configuration'

    try {
        Assert-GuidValue -Value ([string]$Config.subscriptionId) -Label 'Subscription ID'
        $subscriptionId = ([guid][string]$Config.subscriptionId).ToString('D')
        if ([string]$Config.subscriptionId -cne $subscriptionId -or
            $location -cnotmatch '^[a-z0-9]+$') {
            throw [IO.InvalidDataException]::new('The SQL capability target was not canonical.')
        }

        $skuContracts = [ordered]@{
            Basic = [ordered]@{ tier = 'Basic'; capabilitySkuName = 'Basic'; capacity = 5 }
            S0 = [ordered]@{ tier = 'Standard'; capabilitySkuName = 'Standard'; capacity = 10 }
            S1 = [ordered]@{ tier = 'Standard'; capabilitySkuName = 'Standard'; capacity = 20 }
            S2 = [ordered]@{ tier = 'Standard'; capabilitySkuName = 'Standard'; capacity = 50 }
            S3 = [ordered]@{ tier = 'Standard'; capabilitySkuName = 'Standard'; capacity = 100 }
            P1 = [ordered]@{ tier = 'Premium'; capabilitySkuName = 'Premium'; capacity = 125 }
            P2 = [ordered]@{ tier = 'Premium'; capabilitySkuName = 'Premium'; capacity = 250 }
            GP_S_Gen5_1 = [ordered]@{ tier = 'GeneralPurpose'; capabilitySkuName = 'GP_S_Gen5'; family = 'Gen5'; capacity = 1 }
            GP_S_Gen5_2 = [ordered]@{ tier = 'GeneralPurpose'; capabilitySkuName = 'GP_S_Gen5'; family = 'Gen5'; capacity = 2 }
        }
        if (-not $skuContracts.Contains($skuName)) {
            throw [IO.InvalidDataException]::new('The SQL SKU was outside the deployed contract.')
        }
        $skuContract = $skuContracts[$skuName]
        if ([string]$skuContract.tier -cne $skuTier) {
            throw [IO.InvalidDataException]::new('The SQL tier did not match the selected SKU.')
        }

        $safeCheck = 'provider request'
        $url = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Sql/locations/$location/capabilities?api-version=2023-08-01"
        try {
            $raw = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @(
                'rest', '--method', 'GET', '--url', $url,
                '--subscription', $subscriptionId,
                '--output', 'json', '--only-show-errors'
            ) -CaptureStdoutOnly
        }
        catch {
            throw [IO.InvalidDataException]::new('The Azure SQL capability request failed.')
        }
        if ([string]::IsNullOrWhiteSpace($raw) -or
            [Text.Encoding]::UTF8.GetByteCount($raw) -gt 16777216) {
            throw [IO.InvalidDataException]::new('The Azure SQL capability response was empty or oversized.')
        }
        try {
            $capabilities = ConvertFrom-Json -InputObject $raw -Depth 100 -ErrorAction Stop
        }
        catch {
            throw [IO.InvalidDataException]::new('The Azure SQL capability response was malformed.')
        }
        $safeCheck = 'location'
        if ($null -eq $capabilities -or $capabilities -is [System.Array] -or
            -not (Test-GatewayAzureCapabilityAvailable -Capability $capabilities)) {
            throw [IO.InvalidDataException]::new('The Azure SQL location capability was unavailable.')
        }

        $safeCheck = 'server version'
        $serverMatches = @(Get-GatewayAzureCapabilityArray -InputObject $capabilities -Name 'supportedServerVersions' |
            Where-Object { [string](Get-GatewayAzureCapabilityProperty -InputObject $_ -Name 'name') -ceq '12.0' })
        if ($serverMatches.Count -ne 1 -or -not (Test-GatewayAzureCapabilityAvailable -Capability $serverMatches[0])) {
            throw [IO.InvalidDataException]::new('The Azure SQL server capability was unavailable or ambiguous.')
        }

        $safeCheck = 'edition'
        $editionMatches = @(Get-GatewayAzureCapabilityArray -InputObject $serverMatches[0] -Name 'supportedEditions' |
            Where-Object { [string](Get-GatewayAzureCapabilityProperty -InputObject $_ -Name 'name') -ceq $skuTier })
        if ($editionMatches.Count -ne 1 -or -not (Test-GatewayAzureCapabilityAvailable -Capability $editionMatches[0])) {
            throw [IO.InvalidDataException]::new('The Azure SQL edition capability was unavailable or ambiguous.')
        }

        $safeCheck = 'service objective'
        $objectiveMatches = @(Get-GatewayAzureCapabilityArray -InputObject $editionMatches[0] -Name 'supportedServiceLevelObjectives' |
            Where-Object { [string](Get-GatewayAzureCapabilityProperty -InputObject $_ -Name 'name') -ceq $skuName })
        if ($objectiveMatches.Count -ne 1 -or -not (Test-GatewayAzureCapabilityAvailable -Capability $objectiveMatches[0])) {
            throw [IO.InvalidDataException]::new('The Azure SQL service objective was unavailable or ambiguous.')
        }
        $safeCheck = 'SKU'
        $objective = $objectiveMatches[0]
        $capabilitySku = Get-GatewayAzureCapabilityProperty -InputObject $objective -Name 'sku'
        $capabilityCapacity = if ($null -ne $capabilitySku) {
            Get-GatewayAzureCapabilityInt32 `
                -InputObject $capabilitySku `
                -Name 'capacity' `
                -Label 'The Azure SQL SKU capacity' `
                -NonNegative
        }
        else { $null }
        if ($null -eq $capabilitySku -or
            [string](Get-GatewayAzureCapabilityProperty -InputObject $capabilitySku -Name 'name') -cne [string]$skuContract.capabilitySkuName -or
            [string](Get-GatewayAzureCapabilityProperty -InputObject $capabilitySku -Name 'tier') -cne $skuTier -or
            $capabilityCapacity -ne [int]$skuContract.capacity) {
            throw [IO.InvalidDataException]::new('The Azure SQL SKU capability did not match the selected contract.')
        }
        if ($skuContract.Contains('family') -and
            [string](Get-GatewayAzureCapabilityProperty -InputObject $capabilitySku -Name 'family') -cne [string]$skuContract.family) {
            throw [IO.InvalidDataException]::new('The Azure SQL SKU family did not match the selected contract.')
        }

        $safeCheck = 'maximum size'
        $targetBytes = 2147483648L
        $matchingSizes = [Collections.Generic.List[object]]::new()
        foreach ($sizeCapability in @(Get-GatewayAzureCapabilityArray -InputObject $objective -Name 'supportedMaxSizes')) {
            $minimum = ConvertTo-GatewaySqlCapabilityBytes -SizeValue (Get-GatewayAzureCapabilityProperty -InputObject $sizeCapability -Name 'minValue')
            $maximum = ConvertTo-GatewaySqlCapabilityBytes -SizeValue (Get-GatewayAzureCapabilityProperty -InputObject $sizeCapability -Name 'maxValue')
            $scale = ConvertTo-GatewaySqlCapabilityBytes -SizeValue (Get-GatewayAzureCapabilityProperty -InputObject $sizeCapability -Name 'scaleSize')
            if ($minimum -gt $maximum) {
                throw [IO.InvalidDataException]::new('An Azure SQL maximum-size range was invalid.')
            }
            $matchesTarget = $targetBytes -ge $minimum -and $targetBytes -le $maximum
            if ($matchesTarget) {
                $matchesTarget = if ($scale -eq 0) {
                    $minimum -eq $maximum -and $targetBytes -eq $minimum
                }
                else {
                    (($targetBytes - $minimum) % $scale) -eq 0
                }
            }
            if ($matchesTarget) { $matchingSizes.Add($sizeCapability) }
        }
        if ($matchingSizes.Count -ne 1 -or
            -not (Test-GatewayAzureCapabilityAvailable -Capability $matchingSizes[0])) {
            throw [IO.InvalidDataException]::new('The exact Azure SQL maximum-size capability was unavailable or ambiguous.')
        }

        $safeCheck = 'backup storage redundancy'
        $storageMatches = @(Get-GatewayAzureCapabilityArray -InputObject $editionMatches[0] -Name 'supportedStorageCapabilities' |
            Where-Object { [string](Get-GatewayAzureCapabilityProperty -InputObject $_ -Name 'storageAccountType') -ceq 'LRS' })
        if ($storageMatches.Count -ne 1 -or
            -not (Test-GatewayAzureCapabilityAvailable -Capability $storageMatches[0])) {
            throw [IO.InvalidDataException]::new('The Azure SQL LRS capability was unavailable or ambiguous.')
        }
    }
    catch {
        throw "$safeFailure Check: $safeCheck."
    }

    return $true
}

function Register-BootstrapResourceProviders {
    foreach ($provider in @(
        'Microsoft.AlertsManagement',
        'Microsoft.App',
        'Microsoft.ContainerRegistry',
        'Microsoft.EventGrid',
        'Microsoft.Insights',
        'Microsoft.KeyVault',
        'Microsoft.ManagedIdentity',
        'Microsoft.Network',
        'Microsoft.OperationalInsights',
        'Microsoft.ServiceBus',
        'Microsoft.Sql',
        'Microsoft.Storage'
    )) {
        Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('provider', 'register', '--namespace', $provider, '--wait', '--only-show-errors') | Out-Null
        $state = Invoke-AzTsv -Arguments @('provider', 'show', '--namespace', $provider, '--query', 'registrationState')
        if ($state -ne 'Registered') { throw "Resource provider $provider did not reach Registered state." }
    }
    return [ordered]@{ registered = $true; verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O') }
}

function Deploy-BootstrapFoundation {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )
    $root = Get-BootstrapExecutionSourceRoot
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Foundation deployment ownership ID must be a canonical lowercase GUID from the current bootstrap state.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Foundation source fingerprint'
    if ((Get-BootstrapSourceFingerprint -Root $root) -cne $SourceFingerprint) {
        throw 'The foundation deployment source no longer matches the accepted content-addressed snapshot.'
    }
    $groupExists = Invoke-AzTsv -Arguments @('group', 'exists', '--name', [string]$Config.resourceGroupName)
    if ($groupExists -notin @('true', 'false')) {
        throw 'Azure returned an invalid resource-group existence result; no foundation mutation was attempted.'
    }
    if ($groupExists -ne 'false') {
        throw 'Clean bootstrap refuses to deploy a fresh foundation into an existing resource group. Use only exact state-bound Resume recovery.'
    }
    # Subscription deployments share one name namespace across resource groups.
    # Include the project discriminator so two development Gateways in the same
    # subscription cannot overwrite each other's deployment record.
    $deploymentName = "a365gw-$($Config.projectName)-bootstrap-foundation-$($Config.environment)"
    $result = Invoke-AzJson -Arguments @(
        'deployment', 'sub', 'create',
        '--name', $deploymentName,
        '--location', [string]$Config.location,
        '--template-file', (Join-Path $root 'bootstrap/infra/subscription.bicep'),
        '--parameters',
        "resourceGroupName=$($Config.resourceGroupName)",
        "location=$($Config.location)",
        "environment=$($Config.environment)",
        "projectName=$($Config.projectName)",
        "deploymentOwnershipId=$canonicalOwnershipId",
        "bootstrapSourceFingerprint=$SourceFingerprint"
    )
    $outputs = $result.properties.outputs
    if ([string]$outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$outputs.bootstrapSourceFingerprint.value -cne $SourceFingerprint) {
        throw 'Foundation deployment did not echo the exact bootstrap ownership and source boundary.'
    }
    return [ordered]@{
        deploymentName = $deploymentName
        deploymentOwnershipId = $canonicalOwnershipId
        sourceFingerprint = $SourceFingerprint
        resourceGroupName = [string]$outputs.resourceGroupName.value
        containerAppsEnvironmentName = [string]$outputs.containerAppsEnvironmentName.value
        containerAppsEnvironmentId = [string]$outputs.containerAppsEnvironmentId.value
        virtualNetworkName = [string]$outputs.virtualNetworkName.value
        virtualNetworkId = [string]$outputs.virtualNetworkId.value
        privateEndpointSubnetName = [string]$outputs.privateEndpointSubnetName.value
        privateEndpointSubnetId = [string]$outputs.privateEndpointSubnetId.value
        logAnalyticsWorkspaceName = [string]$outputs.logAnalyticsWorkspaceName.value
        acrLoginServer = [string]$outputs.acrLoginServer.value
        acrName = [string]$outputs.acrName.value
        runtimeImagePullIdentityId = [string]$outputs.runtimeImagePullIdentityId.value
        runtimeImagePullIdentityPrincipalId = [string]$outputs.runtimeImagePullIdentityPrincipalId.value
        runtimeImagePullAcrPullRoleAssignmentId = [string]$outputs.runtimeImagePullAcrPullRoleAssignmentId.value
    }
}

function Get-BootstrapFoundationEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Foundation recovery ownership ID is not canonical.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Foundation recovery source fingerprint'
    $deploymentName = "a365gw-$($Config.projectName)-bootstrap-foundation-$($Config.environment)"
    $result = Invoke-AzJson -Arguments @(
        'deployment', 'sub', 'show', '--subscription', [string]$Config.subscriptionId,
        '--name', $deploymentName
    )
    if (-not $result -or [string]$result.properties.provisioningState -ne 'Succeeded' -or
        [string]$result.properties.parameters.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$result.properties.outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$result.properties.parameters.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
        [string]$result.properties.outputs.bootstrapSourceFingerprint.value -cne $SourceFingerprint) {
        throw 'The prior foundation deployment was absent, incomplete, or not owned by this bootstrap state.'
    }
    $outputs = $result.properties.outputs
    return [ordered]@{
        deploymentName = $deploymentName
        deploymentOwnershipId = $canonicalOwnershipId
        sourceFingerprint = $SourceFingerprint
        resourceGroupName = [string]$outputs.resourceGroupName.value
        containerAppsEnvironmentName = [string]$outputs.containerAppsEnvironmentName.value
        containerAppsEnvironmentId = [string]$outputs.containerAppsEnvironmentId.value
        virtualNetworkName = [string]$outputs.virtualNetworkName.value
        virtualNetworkId = [string]$outputs.virtualNetworkId.value
        privateEndpointSubnetName = [string]$outputs.privateEndpointSubnetName.value
        privateEndpointSubnetId = [string]$outputs.privateEndpointSubnetId.value
        logAnalyticsWorkspaceName = [string]$outputs.logAnalyticsWorkspaceName.value
        acrLoginServer = [string]$outputs.acrLoginServer.value
        acrName = [string]$outputs.acrName.value
        runtimeImagePullIdentityId = [string]$outputs.runtimeImagePullIdentityId.value
        runtimeImagePullIdentityPrincipalId = [string]$outputs.runtimeImagePullIdentityPrincipalId.value
        runtimeImagePullAcrPullRoleAssignmentId = [string]$outputs.runtimeImagePullAcrPullRoleAssignmentId.value
    }
}

function Invoke-ArmDeploymentWithSecureParameters {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TemplateFile,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [Parameter()][ValidateSet('Incremental')][string]$Mode = 'Incremental'
    )
    $parameterObject = [ordered]@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = [ordered]@{} }
    foreach ($entry in $Parameters.GetEnumerator()) { $parameterObject.parameters[$entry.Key] = @{ value = $entry.Value } }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) "a365gw-bootstrap-$([guid]::NewGuid().ToString('N')).json"
    try {
        $parameterObject | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
        if ($IsWindows) {
            $acl = Get-Acl -LiteralPath $temporary
            $acl.SetAccessRuleProtection($true, $false)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().Name, 'FullControl', 'Allow')
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $temporary -AclObject $acl
        }
        elseif (Get-Command chmod -ErrorAction SilentlyContinue) {
            & chmod 600 $temporary
            if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the temporary ARM parameter file to the current user.' }
        }
        return Invoke-AzJson -Arguments @(
            'deployment', 'group', 'create', '--resource-group', $ResourceGroup,
            '--name', $Name, '--mode', $Mode, '--template-file', $TemplateFile,
            '--parameters', "@$temporary"
        )
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-GatewayArmObjectPropertyNames {
    param([AllowNull()]$Object)
    if ($null -eq $Object) { return @() }
    if ($Object -is [System.Collections.IDictionary]) { return @($Object.Keys | ForEach-Object { [string]$_ }) }
    return @($Object.PSObject.Properties.Name | ForEach-Object { [string]$_ })
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

function Get-GatewayArmArrayItems {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return }
    return $Value
}

function Assert-GatewayRuntimeImagePullFoundationEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation
    )
    $expectedIdentityId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-runtime-pull-$($Config.environment)"
    $identityId = [string](Get-GatewayArmObjectProperty -Object $Foundation -Name 'runtimeImagePullIdentityId')
    if ([string]::IsNullOrWhiteSpace($identityId) -or
        -not $identityId.Equals($expectedIdentityId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Foundation runtime image-pull identity evidence does not match the exact deployment scope and name.'
    }

    $principalId = [string](Get-GatewayArmObjectProperty -Object $Foundation -Name 'runtimeImagePullIdentityPrincipalId')
    $parsedPrincipalId = [guid]::Empty
    if (-not [guid]::TryParse($principalId, [ref]$parsedPrincipalId) -or
        $parsedPrincipalId -eq [guid]::Empty -or $principalId -cne $parsedPrincipalId.ToString('D')) {
        throw 'Foundation runtime image-pull principal evidence is not one canonical nonempty GUID.'
    }

    $acrName = [string](Get-GatewayArmObjectProperty -Object $Foundation -Name 'acrName')
    if ($acrName -cnotmatch '^[a-z0-9]{5,50}$') {
        throw 'Foundation ACR evidence is invalid for runtime image-pull recovery.'
    }
    $roleAssignmentId = [string](Get-GatewayArmObjectProperty -Object $Foundation -Name 'runtimeImagePullAcrPullRoleAssignmentId')
    $expectedRolePrefix = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.ContainerRegistry/registries/$acrName/providers/Microsoft.Authorization/roleAssignments/"
    if (-not $roleAssignmentId.StartsWith($expectedRolePrefix, [StringComparison]::Ordinal) -or
        $roleAssignmentId.Length -ne ($expectedRolePrefix.Length + 36)) {
        throw 'Foundation runtime image-pull role-assignment evidence is outside the exact ACR scope.'
    }
    $roleAssignmentName = $roleAssignmentId.Substring($expectedRolePrefix.Length)
    $parsedRoleAssignmentName = [guid]::Empty
    if (-not [guid]::TryParse($roleAssignmentName, [ref]$parsedRoleAssignmentName) -or
        $parsedRoleAssignmentName -eq [guid]::Empty -or $roleAssignmentName -cne $parsedRoleAssignmentName.ToString('D')) {
        throw 'Foundation runtime image-pull role-assignment evidence is not canonical.'
    }

    return [ordered]@{
        identityId = $identityId
        principalId = $principalId
        roleAssignmentId = $roleAssignmentId
    }
}

function Assert-GatewayExactReadableArmParameters {
    param(
        [Parameter(Mandatory)]$ActualParameters,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedParameters,
        [Parameter()][string[]]$SecureParameterNames = @()
    )
    $expectedNames = @($ExpectedParameters.Keys | ForEach-Object { [string]$_ })
    $actualNames = @(Get-GatewayArmObjectPropertyNames -Object $ActualParameters)
    if ($actualNames.Count -ne $expectedNames.Count -or
        (($actualNames | Sort-Object -CaseSensitive) -join '|') -cne (($expectedNames | Sort-Object -CaseSensitive) -join '|')) {
        throw 'The prior inert deployment parameter surface does not exactly match the current reviewed template contract.'
    }
    foreach ($name in $expectedNames) {
        $actualParameter = Get-GatewayArmObjectProperty -Object $ActualParameters -Name $name
        if ($null -eq $actualParameter) {
            throw 'The prior inert deployment is missing a reviewed parameter.'
        }
        if ($name -in $SecureParameterNames) { continue }
        if (-not (Test-GatewayArmObjectProperty -Object $actualParameter -Name 'value')) {
            throw 'A non-secret prior inert deployment parameter has no readable value.'
        }
        $actualValue = Get-GatewayArmObjectProperty -Object $actualParameter -Name 'value'
        $matches = if ($name -ceq 'runtimeImagePullIdentityId') {
            [string]$actualValue -ieq [string]$ExpectedParameters[$name]
        }
        else {
            (Get-BootstrapObjectFingerprint -InputObject $actualValue) -ceq
                (Get-BootstrapObjectFingerprint -InputObject $ExpectedParameters[$name])
        }
        if (-not $matches) {
            throw "A prior inert deployment parameter does not match the exact reviewed value contract ($name)."
        }
    }
    return $true
}

function New-GatewayInertDeploymentRetryReceipt {
    param([Parameter(Mandatory)]$Deployment)
    $state = [string]$Deployment.properties.provisioningState
    if ($state -notin @('Failed', 'Canceled')) {
        throw 'Only a terminal Failed or Canceled inert deployment can produce a retry receipt.'
    }
    $correlationId = [string]$Deployment.properties.correlationId
    $parsedCorrelationId = [guid]::Empty
    if (-not [guid]::TryParse($correlationId, [ref]$parsedCorrelationId) -or
        $parsedCorrelationId -eq [guid]::Empty -or $correlationId -cne $parsedCorrelationId.ToString('D')) {
        throw 'The terminal inert deployment correlation ID is not canonical.'
    }
    $timestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        [string]$Deployment.properties.timestamp,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$timestamp)) {
        throw 'The terminal inert deployment timestamp is invalid.'
    }
    if ([string]$Deployment.properties.mode -cne 'Incremental') {
        throw 'The terminal inert deployment was not an Incremental deployment.'
    }
    return [ordered]@{
        state = $state
        correlationId = $correlationId
        timestamp = $timestamp.ToUniversalTime().ToString('O')
        mode = 'Incremental'
    }
}

function Assert-GatewayExactPartialEnvironmentSubset {
    param(
        [AllowNull()]$Entries,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedValues,
        [switch]$RequireComplete
    )
    $actualEntries = @(Get-GatewayArmArrayItems -Value $Entries)
    if ($RequireComplete -and $actualEntries.Count -ne $ExpectedValues.Count) {
        throw 'A completed child Container App environment is not complete.'
    }
    $expectedByName = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $ExpectedValues.GetEnumerator()) {
        if (-not $expectedByName.TryAdd([string]$entry.Key, $entry.Value)) {
            throw 'The reviewed partial Container App environment contract contains a duplicate exact name.'
        }
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $actualEntries) {
        $name = [string](Get-GatewayArmObjectProperty -Object $entry -Name 'name')
        if ([string]::IsNullOrWhiteSpace($name) -or -not $seen.Add($name) -or -not $expectedByName.ContainsKey($name)) {
            throw 'A partial Container App environment contains a missing, duplicate, or unreviewed name.'
        }
        if (-not [string]::IsNullOrWhiteSpace([string](Get-GatewayArmObjectProperty -Object $entry -Name 'secretRef')) -or
            -not (Test-GatewayArmObjectProperty -Object $entry -Name 'value') -or
            [string](Get-GatewayArmObjectProperty -Object $entry -Name 'value') -cne [string]$expectedByName[$name]) {
            throw 'A partial Container App environment value does not match its exact inert plain-value contract.'
        }
    }
    return $true
}

function Assert-GatewayExactTagMap {
    param(
        [Parameter(Mandatory)]$ActualTags,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedTags
    )
    $actualNames = @(Get-GatewayArmObjectPropertyNames -Object $ActualTags)
    $expectedNames = @($ExpectedTags.Keys | ForEach-Object { [string]$_ })
    if ($actualNames.Count -ne $expectedNames.Count -or
        (($actualNames | Sort-Object -CaseSensitive) -join '|') -cne (($expectedNames | Sort-Object -CaseSensitive) -join '|')) {
        throw 'A partial Gateway resource tag surface is not exact.'
    }
    foreach ($name in $expectedNames) {
        if ([string](Get-GatewayArmObjectProperty -Object $ActualTags -Name $name) -cne [string]$ExpectedTags[$name]) {
            throw 'A partial Gateway resource tag value does not match the current ownership and source boundary.'
        }
    }
    return $true
}

function Assert-GatewayPresentTerminalProvisioningState {
    param([Parameter(Mandatory)]$Object)
    if (Test-GatewayArmObjectProperty -Object $Object -Name 'provisioningState') {
        if ([string](Get-GatewayArmObjectProperty -Object $Object -Name 'provisioningState') -notin @('Succeeded', 'Failed', 'Canceled')) {
            throw 'A present partial-resource provisioning state is not terminal.'
        }
    }
    return $true
}

function Assert-GatewayExactImagePullIdentityEnvelope {
    param(
        [AllowNull()]$Identity,
        [Parameter(Mandatory)][string]$ExpectedIdentityId,
        [Parameter(Mandatory)][string]$ExpectedIdentityPrincipalId,
        [Parameter(Mandatory)][string]$ExpectedTenantId,
        [switch]$RequireComplete
    )
    if ($null -eq $Identity) {
        if ($RequireComplete) { throw 'A completed Container App has no managed-identity envelope.' }
        return $true
    }
    if (Test-GatewayArmObjectProperty -Object $Identity -Name 'type') {
        $types = @(([string](Get-GatewayArmObjectProperty -Object $Identity -Name 'type')).Split(',') | ForEach-Object { $_.Trim() })
        if ($types.Count -ne 2 -or $types -cnotcontains 'SystemAssigned' -or $types -cnotcontains 'UserAssigned') {
            throw 'A Container App identity is not exactly system-assigned plus the dedicated pull identity.'
        }
    }
    elseif ($RequireComplete) { throw 'A completed Container App identity type is absent.' }

    if (Test-GatewayArmObjectProperty -Object $Identity -Name 'principalId') {
        $principalId = [string](Get-GatewayArmObjectProperty -Object $Identity -Name 'principalId')
        $parsedPrincipalId = [guid]::Empty
        if (-not [guid]::TryParse($principalId, [ref]$parsedPrincipalId) -or $parsedPrincipalId -eq [guid]::Empty -or
            $principalId -cne $parsedPrincipalId.ToString('D')) {
            throw 'A Container App system-assigned principal ID is not canonical.'
        }
    }
    elseif ($RequireComplete) { throw 'A completed Container App system-assigned principal ID is absent.' }

    if (Test-GatewayArmObjectProperty -Object $Identity -Name 'tenantId') {
        if ([string](Get-GatewayArmObjectProperty -Object $Identity -Name 'tenantId') -cne $ExpectedTenantId) {
            throw 'A Container App identity tenant does not match the exact deployment tenant.'
        }
    }
    elseif ($RequireComplete) { throw 'A completed Container App identity tenant is absent.' }

    $hasUserAssigned = Test-GatewayArmObjectProperty -Object $Identity -Name 'userAssignedIdentities'
    $userAssigned = if ($hasUserAssigned) { Get-GatewayArmObjectProperty -Object $Identity -Name 'userAssignedIdentities' } else { $null }
    if ($null -ne $userAssigned) {
        $ids = @(Get-GatewayArmObjectPropertyNames -Object $userAssigned)
        if ($ids.Count -ne 1 -or -not $ids[0].Equals($ExpectedIdentityId, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A Container App user-assigned identity set is not exactly the foundation pull identity.'
        }
        $identityDetails = Get-GatewayArmObjectProperty -Object $userAssigned -Name $ids[0]
        if ($null -ne $identityDetails -and (Test-GatewayArmObjectProperty -Object $identityDetails -Name 'principalId')) {
            if ([string](Get-GatewayArmObjectProperty -Object $identityDetails -Name 'principalId') -cne $ExpectedIdentityPrincipalId) {
                throw 'A Container App pull-identity principal readback does not match Foundation evidence.'
            }
        }
        if ($null -ne $identityDetails -and (Test-GatewayArmObjectProperty -Object $identityDetails -Name 'clientId')) {
            $clientId = [string](Get-GatewayArmObjectProperty -Object $identityDetails -Name 'clientId')
            $parsedClientId = [guid]::Empty
            if (-not [guid]::TryParse($clientId, [ref]$parsedClientId) -or $parsedClientId -eq [guid]::Empty -or
                $clientId -cne $parsedClientId.ToString('D')) {
                throw 'A present Container App pull-identity client ID is not canonical.'
            }
        }
    }
    elseif ($RequireComplete) { throw 'A completed Container App pull-identity map is absent.' }
    return $true
}

function Assert-GatewayExactPartialRegistryEnvelope {
    param(
        [AllowNull()]$Registries,
        [Parameter(Mandatory)][string]$ExpectedServer,
        [Parameter(Mandatory)][string]$ExpectedIdentityId,
        [switch]$RequireComplete
    )
    $entries = @(Get-GatewayArmArrayItems -Value $Registries)
    if ($entries.Count -eq 0) {
        if ($RequireComplete) { throw 'A completed Container App registry envelope is absent.' }
        return $true
    }
    if ($entries.Count -ne 1 -or [string](Get-GatewayArmObjectProperty -Object $entries[0] -Name 'server') -cne $ExpectedServer -or
        -not ([string](Get-GatewayArmObjectProperty -Object $entries[0] -Name 'identity')).Equals($ExpectedIdentityId, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-GatewayArmObjectProperty -Object $entries[0] -Name 'username')) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-GatewayArmObjectProperty -Object $entries[0] -Name 'passwordSecretRef'))) {
        throw 'A Container App registry envelope is not the exact secret-free dedicated-identity contract.'
    }
    return $true
}

function Assert-GatewayExactPartialContainerAppEnvelope {
    param(
        [Parameter(Mandatory)]$App,
        [Parameter(Mandatory)][ValidateSet('Api', 'Worker')][string]$Role,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][string]$ExpectedImage,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedEnvironment
    )
    $expectedContainerEnvironment = [ordered]@{}
    foreach ($entry in $ExpectedEnvironment.GetEnumerator()) {
        if ([string]$entry.Key -cne '__recoveryApiFqdn') { $expectedContainerEnvironment[$entry.Key] = $entry.Value }
    }
    $name = if ($Role -ceq 'Api') { "ca-gateway-api-$($Config.environment)" } else { "ca-gateway-worker-$($Config.environment)-v3" }
    $expectedId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.App/containerApps/$name"
    if ([string]$App.name -cne $name -or [string]$App.type -cne 'Microsoft.App/containerApps' -or
        (ConvertTo-GatewayCanonicalAzureLocation -Location ([string]$App.location)) -cne
            (ConvertTo-GatewayCanonicalAzureLocation -Location ([string]$Config.location)) -or
        -not ([string]$App.id).Equals($expectedId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A partial Container App is outside the exact name, type, location, and resource scope.'
    }
    Assert-GatewayExactTagMap -ActualTags $App.tags -ExpectedTags ([ordered]@{
        project = 'a365-gateway'
        environment = [string]$Config.environment
        managedBy = 'bicep'
        projectName = [string]$Config.projectName
        deploymentId = "$($Config.projectName)-$($Config.environment)"
        bootstrapOwnershipId = $DeploymentOwnershipId
        bootstrapSourceFingerprint = $SourceFingerprint
    }) | Out-Null

    $properties = Get-GatewayArmObjectProperty -Object $App -Name 'properties'
    if ($null -eq $properties) { throw 'A partial Container App has no readable properties envelope.' }
    Assert-GatewayPresentTerminalProvisioningState -Object $properties | Out-Null
    $requireComplete = [string](Get-GatewayArmObjectProperty -Object $properties -Name 'provisioningState') -ceq 'Succeeded'
    if (Test-GatewayArmObjectProperty -Object $properties -Name 'managedEnvironmentId') {
        if (-not ([string](Get-GatewayArmObjectProperty -Object $properties -Name 'managedEnvironmentId')).Equals(
            [string]$Foundation.containerAppsEnvironmentId, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A partial Container App is not bound to the exact Foundation Container Apps environment.'
        }
    }
    elseif ($requireComplete) { throw 'A completed child Container App has no managed-environment binding.' }
    Assert-GatewayExactImagePullIdentityEnvelope -Identity (Get-GatewayArmObjectProperty -Object $App -Name 'identity') `
        -ExpectedIdentityId ([string]$Foundation.runtimeImagePullIdentityId) `
        -ExpectedIdentityPrincipalId ([string]$Foundation.runtimeImagePullIdentityPrincipalId) `
        -ExpectedTenantId ([string]$Config.tenantId) -RequireComplete:$requireComplete | Out-Null

    $configuration = Get-GatewayArmObjectProperty -Object $properties -Name 'configuration'
    if ($requireComplete -and $null -eq $configuration) { throw 'A completed child Container App has no configuration envelope.' }
    if ($null -ne $configuration) {
        if ((Test-GatewayArmObjectProperty -Object $configuration -Name 'activeRevisionsMode') -and
            [string](Get-GatewayArmObjectProperty -Object $configuration -Name 'activeRevisionsMode') -cne 'Single') {
            throw 'A partial Container App revision mode is not exact.'
        }
        if ($requireComplete -and -not (Test-GatewayArmObjectProperty -Object $configuration -Name 'activeRevisionsMode')) {
            throw 'A completed child Container App has no active-revision mode.'
        }
        $secretCount = 0
        if (-not (Test-GatewayArmObjectProperty -Object $configuration -Name 'secretCount') -or
            -not [int]::TryParse([string](Get-GatewayArmObjectProperty -Object $configuration -Name 'secretCount'), [ref]$secretCount) -or
            $secretCount -ne 0) {
            throw 'A partial inert Container App unexpectedly contains application secrets.'
        }
        if (Test-GatewayArmObjectProperty -Object $configuration -Name 'registries') {
            Assert-GatewayExactPartialRegistryEnvelope `
                -Registries (Get-GatewayArmObjectProperty -Object $configuration -Name 'registries') `
                -ExpectedServer ([string]$Foundation.acrLoginServer) `
                -ExpectedIdentityId ([string]$Foundation.runtimeImagePullIdentityId) -RequireComplete:$requireComplete | Out-Null
        }
        elseif ($requireComplete) { throw 'A completed child Container App has no registry envelope.' }
        $ingress = Get-GatewayArmObjectProperty -Object $configuration -Name 'ingress'
        if ($Role -ceq 'Worker') {
            if ($null -ne $ingress) { throw 'A partial inert worker unexpectedly exposes ingress.' }
        }
        elseif ($null -ne $ingress) {
            foreach ($entry in ([ordered]@{ external = $true; allowInsecure = $false; targetPort = 8080; transport = 'auto' }).GetEnumerator()) {
                if ($requireComplete -and -not (Test-GatewayArmObjectProperty -Object $ingress -Name ([string]$entry.Key))) {
                    throw 'A completed child API ingress field is absent.'
                }
                if (Test-GatewayArmObjectProperty -Object $ingress -Name ([string]$entry.Key)) {
                    $actualValue = Get-GatewayArmObjectProperty -Object $ingress -Name ([string]$entry.Key)
                    $matches = if ([string]$entry.Key -ceq 'transport') {
                        ([string]$actualValue).Equals([string]$entry.Value, [StringComparison]::OrdinalIgnoreCase)
                    }
                    else {
                        (Get-BootstrapObjectFingerprint -InputObject $actualValue) -ceq
                            (Get-BootstrapObjectFingerprint -InputObject $entry.Value)
                    }
                    if (-not $matches) {
                        throw 'A partial API ingress field is outside the exact external HTTPS-only contract.'
                    }
                }
            }
            if (Test-GatewayArmObjectProperty -Object $ingress -Name 'fqdn') {
                $expectedFqdn = [string]$ExpectedEnvironment['__recoveryApiFqdn']
                if ([string](Get-GatewayArmObjectProperty -Object $ingress -Name 'fqdn') -cne $expectedFqdn) {
                    throw 'A partial API ingress FQDN is outside the exact Container Apps environment domain.'
                }
            }
            elseif ($requireComplete) { throw 'A completed child API ingress FQDN is absent.' }
            foreach ($collectionName in @('customDomains', 'ipSecurityRestrictions')) {
                if (@(Get-GatewayArmArrayItems -Value (Get-GatewayArmObjectProperty -Object $ingress -Name $collectionName)).Count -ne 0) {
                    throw 'A partial API ingress contains an unreviewed custom-domain or network-restriction entry.'
                }
            }
        }
        elseif ($requireComplete) { throw 'A completed child API Container App has no ingress envelope.' }
    }

    $template = Get-GatewayArmObjectProperty -Object $properties -Name 'template'
    if ($requireComplete -and $null -eq $template) { throw 'A completed child Container App has no template envelope.' }
    if ($null -ne $template) {
        $containers = @(Get-GatewayArmArrayItems -Value (Get-GatewayArmObjectProperty -Object $template -Name 'containers'))
        if ($containers.Count -gt 1) { throw 'A partial Container App contains more than the one reviewed container.' }
        if ($requireComplete -and $containers.Count -ne 1) { throw 'A completed child Container App does not contain the one reviewed container.' }
        if ($containers.Count -eq 1) {
            $container = $containers[0]
            if ([string](Get-GatewayArmObjectProperty -Object $container -Name 'name') -cne $name -or
                [string](Get-GatewayArmObjectProperty -Object $container -Name 'image') -cne $ExpectedImage) {
                throw 'A partial Container App container name or immutable image is not exact.'
            }
            foreach ($collectionName in @('command', 'args', 'probes', 'volumeMounts')) {
                if (@(Get-GatewayArmArrayItems -Value (Get-GatewayArmObjectProperty -Object $container -Name $collectionName)).Count -ne 0) {
                    throw 'A partial Container App container contains an unreviewed execution or mount override.'
                }
            }
            $resources = Get-GatewayArmObjectProperty -Object $container -Name 'resources'
            if ($requireComplete -and $null -eq $resources) { throw 'A completed child Container App resource allocation is absent.' }
            if ($null -ne $resources) {
                $expectedCpu = if ($Role -ceq 'Api') { 0.5 } else { 0.25 }
                $expectedMemory = if ($Role -ceq 'Api') { '1Gi' } else { '0.5Gi' }
                if ($requireComplete -and (-not (Test-GatewayArmObjectProperty -Object $resources -Name 'cpu') -or
                    -not (Test-GatewayArmObjectProperty -Object $resources -Name 'memory'))) {
                    throw 'A completed child Container App CPU or memory allocation is absent.'
                }
                if ((Test-GatewayArmObjectProperty -Object $resources -Name 'cpu') -and [double](Get-GatewayArmObjectProperty -Object $resources -Name 'cpu') -ne $expectedCpu) {
                    throw 'A partial Container App CPU allocation is not exact.'
                }
                if ((Test-GatewayArmObjectProperty -Object $resources -Name 'memory') -and [string](Get-GatewayArmObjectProperty -Object $resources -Name 'memory') -cne $expectedMemory) {
                    throw 'A partial Container App memory allocation is not exact.'
                }
            }
            if (Test-GatewayArmObjectProperty -Object $container -Name 'env') {
                Assert-GatewayExactPartialEnvironmentSubset `
                    -Entries (Get-GatewayArmObjectProperty -Object $container -Name 'env') `
                    -ExpectedValues $expectedContainerEnvironment -RequireComplete:$requireComplete | Out-Null
            }
            elseif ($requireComplete) { throw 'A completed child Container App has no environment-variable envelope.' }
        }
        if (@(Get-GatewayArmArrayItems -Value (Get-GatewayArmObjectProperty -Object $template -Name 'volumes')).Count -ne 0) {
            throw 'A partial inert Container App unexpectedly contains volumes.'
        }
        $scale = Get-GatewayArmObjectProperty -Object $template -Name 'scale'
        if ($requireComplete -and $null -eq $scale) { throw 'A completed child Container App has no scale envelope.' }
        if ($null -ne $scale) {
            $expectedMin = if ($Role -ceq 'Api') { 1 } else { 0 }
            foreach ($entry in ([ordered]@{ minReplicas = $expectedMin; maxReplicas = 3 }).GetEnumerator()) {
                if ($requireComplete -and -not (Test-GatewayArmObjectProperty -Object $scale -Name ([string]$entry.Key))) {
                    throw 'A completed child Container App scale boundary is absent.'
                }
                if ((Test-GatewayArmObjectProperty -Object $scale -Name ([string]$entry.Key)) -and
                    [int](Get-GatewayArmObjectProperty -Object $scale -Name ([string]$entry.Key)) -ne [int]$entry.Value) {
                    throw 'A partial inert Container App scale boundary is not exact.'
                }
            }
            if (@(Get-GatewayArmArrayItems -Value (Get-GatewayArmObjectProperty -Object $scale -Name 'rules')).Count -ne 0) {
                throw 'A partial inert Container App unexpectedly contains a scale rule.'
            }
        }
    }
    return $true
}

function Get-GatewayInertPartialEnvironmentContract {
    param(
        [Parameter(Mandatory)][ValidateSet('Api', 'Worker')][string[]]$Roles,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )
    $environment = Invoke-AzJson -Arguments @(
        'containerapp', 'env', 'show', '--resource-group', [string]$Config.resourceGroupName,
        '--name', [string]$Foundation.containerAppsEnvironmentName,
        '--query', '{id:id,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint,defaultDomain:properties.defaultDomain}'
    )
    if (-not $environment -or
        -not ([string]$environment.id).Equals([string]$Foundation.containerAppsEnvironmentId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$environment.ownershipId -cne $DeploymentOwnershipId -or
        [string]$environment.sourceFingerprint -cne $SourceFingerprint -or
        [string]$environment.defaultDomain -cnotmatch '^[a-z0-9](?:[a-z0-9.-]{1,251}[a-z0-9])?$') {
        throw 'The exact Foundation Container Apps environment readback needed for inert recovery is unavailable.'
    }
    $appInsightsName = "ai-$($Config.projectName)-$($Config.environment)"
    $appInsights = Invoke-AzJson -Arguments @(
        'monitor', 'app-insights', 'component', 'show', '--resource-group', [string]$Config.resourceGroupName,
        '--app', $appInsightsName,
        '--query', '{ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint,connectionString:connectionString}'
    )
    if (-not $appInsights -or [string]$appInsights.ownershipId -cne $DeploymentOwnershipId -or
        [string]$appInsights.sourceFingerprint -cne $SourceFingerprint -or
        [string]::IsNullOrWhiteSpace([string]$appInsights.connectionString)) {
        throw 'The exact source-owned Application Insights readback needed for inert recovery is unavailable.'
    }

    $sqlConnection = "Server=tcp:sql-$($Config.projectName)-$($Config.environment).database.windows.net,1433;Database=GatewayDb;Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;"
    $serviceBusNamespace = "sb-$($Config.projectName)-$($Config.environment).servicebus.windows.net"
    $apiFqdn = "ca-gateway-api-$($Config.environment).$($environment.defaultDomain)"
    $booleanEnvironment = Get-GatewayArmBooleanEnvironmentContract `
        -RuntimeEnabled $false `
        -RegistryPreviewEnabled $false `
        -PurviewEnabled $false `
        -PurviewPolicyProvisioningEnabled $false `
        -PromptShieldEnabled ([bool]$Config.promptShield.enabled)
    $contracts = [ordered]@{}
    if ($Roles -contains 'Worker') {
        $contracts.Worker = [ordered]@{
            'ConnectionStrings__GatewayDb' = $sqlConnection
            'ServiceBus__FullyQualifiedNamespace' = $serviceBusNamespace
            'ServiceBus__QueueName' = 'gateway-provisioning-v3'
            'OutboxRelay__Enabled' = 'false'
            'Observability__ApplicationInsightsConnectionString' = [string]$appInsights.connectionString
            'KeyVault__VaultUri' = "https://kv-$($Config.projectName)-$($Config.environment).vault.azure.net/"
            'Agent365__TenantId' = [string]$Config.tenantId
            'Agent365__ObservabilityServerAddress' = $apiFqdn
            'Agent365__ProvisioningManagedIdentityPrincipalId' = ''
            'ProvisioningWorker__QueueName' = 'gateway-provisioning-v3'
            'ProvisioningWorker__MaxConcurrentCalls' = '5'
            'ProvisioningWorker__ProcessingEnabled' = $booleanEnvironment.Worker['ProvisioningWorker__ProcessingEnabled']
            'ProvisioningWorker__ProvisioningExecutionEnabled' = $booleanEnvironment.Worker['ProvisioningWorker__ProvisioningExecutionEnabled']
            'Purview__Enabled' = $booleanEnvironment.Worker['Purview__Enabled']
            'Purview__PolicyProvisioningEnabled' = $booleanEnvironment.Worker['Purview__PolicyProvisioningEnabled']
            'Purview__PolicyProvisioningOrganization' = [string]$Config.purview.policyProvisioningOrganization
            'Purview__PolicyProvisioningApplicationId' = [string]$Config.purview.policyProvisioningApplicationId
            'Purview__PolicyProvisioningCertificateSecretUri' = [string]$Config.purview.policyProvisioningCertificateSecretUri
            'Purview__DefaultSensitiveInformationTypeId' = [string]$Config.purview.sensitiveInformationTypeId
            'Purview__DefaultSensitiveInformationType' = [string]$Config.purview.sensitiveInformationType
            'DOTNET_ENVIRONMENT' = 'Production'
        }
    }
    if ($Roles -notcontains 'Api') { return $contracts }

    $storageNames = @(Invoke-AzJson -Arguments @(
        'resource', 'list', '--resource-group', [string]$Config.resourceGroupName,
        '--resource-type', 'Microsoft.Storage/storageAccounts', '--query',
        "[?tags.bootstrapOwnershipId=='$DeploymentOwnershipId' && tags.bootstrapSourceFingerprint=='$SourceFingerprint' && tags.projectName=='$($Config.projectName)' && tags.environment=='$($Config.environment)' && tags.managedBy=='bicep'].name"
    ))
    if ($storageNames.Count -ne 1 -or [string]$storageNames[0] -cnotmatch '^[a-z0-9]{3,24}$') {
        throw 'The exact source-owned Storage account needed for inert API recovery was not unique.'
    }
    $storageName = [string]$storageNames[0]

    $promptShieldEndpoint = ''
    if ($Config.promptShield.enabled -eq $true) {
        $contentNames = @(Invoke-AzJson -Arguments @(
            'resource', 'list', '--resource-group', [string]$Config.resourceGroupName,
            '--resource-type', 'Microsoft.CognitiveServices/accounts', '--query',
            "[?kind=='ContentSafety' && tags.bootstrapOwnershipId=='$DeploymentOwnershipId' && tags.bootstrapSourceFingerprint=='$SourceFingerprint' && tags.workload=='prompt-protection'].name"
        ))
        if ($contentNames.Count -ne 1 -or
            [string]$contentNames[0] -cnotmatch "^cs-$([regex]::Escape([string]$Config.projectName))-$([regex]::Escape([string]$Config.environment))-[a-z0-9]{6}$") {
            throw 'The exact source-owned Content Safety account needed for inert API recovery was not unique.'
        }
        $promptShieldEndpoint = "https://$($contentNames[0]).cognitiveservices.azure.com/"
    }
    $contracts.Api = [ordered]@{
        'ConnectionStrings__GatewayDb' = $sqlConnection
        'ServiceBus__FullyQualifiedNamespace' = $serviceBusNamespace
        'ServiceBus__QueueName' = 'gateway-provisioning-v3'
        'Provisioning__ExecutionEnabled' = $booleanEnvironment.Api['Provisioning__ExecutionEnabled']
        'Provisioning__AllowContinuousDevelopmentAccess' = $booleanEnvironment.Api['Provisioning__AllowContinuousDevelopmentAccess']
        'BlobStorage__ServiceUri' = "https://$storageName.blob.core.windows.net/"
        'BlobStorage__ContainerName' = 'a365-gateway-interactions'
        'Observability__ApplicationInsightsConnectionString' = [string]$appInsights.connectionString
        'EntraId__TenantId' = [string]$Config.tenantId
        'EntraId__ClientId' = [string]$Identity.gatewayApiClientId
        'EntraId__Audience' = [string]$Identity.gatewayApiTokenAudience
        'EntraId__ClientCredentials__0__SourceType' = 'SignedAssertionFromManagedIdentity'
        'EntraId__ClientCredentials__0__TokenExchangeUrl' = 'api://AzureADTokenExchange'
        'KeyVault__VaultUri' = "https://kv-$($Config.projectName)-$($Config.environment).vault.azure.net/"
        'Agent365__TenantId' = [string]$Config.tenantId
        'Agent365__DelegatedRegistry__Enabled' = $booleanEnvironment.Api['Agent365__DelegatedRegistry__Enabled']
        'Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess' = $booleanEnvironment.Api['Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess']
        'Agent365__DelegatedRegistry__Scopes__0' = 'https://graph.microsoft.com/AgentRegistration.ReadWrite.All'
        'Agent365__DelegatedRegistry__Scopes__1' = 'https://graph.microsoft.com/AgentRegistration.Read.All'
        'Purview__Enabled' = $booleanEnvironment.Api['Purview__Enabled']
        'PromptShield__Enabled' = $booleanEnvironment.Api['PromptShield__Enabled']
        'PromptShield__Endpoint' = $promptShieldEndpoint
        'PromptShield__ApiVersion' = '2024-09-01'
        'DatabaseAttestation__Enabled' = $booleanEnvironment.Api['DatabaseAttestation__Enabled']
        'DatabaseAttestation__DeploymentOwnershipId' = ''
        'DatabaseAttestation__AcceptedSourceFingerprint' = ''
        'DatabaseAttestation__ExpectedSchemaFingerprint' = ''
        'DatabaseAttestation__SqlServerFqdn' = ''
        'DatabaseAttestation__DatabaseName' = ''
        'DatabaseAttestation__ApiPrincipalName' = ''
        'DatabaseAttestation__ApiPrincipalClientId' = ''
        'DatabaseAttestation__WorkerPrincipalName' = ''
        'DatabaseAttestation__WorkerPrincipalClientId' = ''
        'OutboxRelay__PollingIntervalSeconds' = '5'
        'OutboxRelay__BatchSize' = '10'
        'ASPNETCORE_ENVIRONMENT' = 'Production'
        '__recoveryApiFqdn' = $apiFqdn
    }
    return $contracts
}

function Get-GatewayCoreOutputValue {
    param([Parameter(Mandatory)]$Outputs, [Parameter(Mandatory)][string]$Name)
    $output = Get-GatewayArmObjectProperty -Object $Outputs -Name $Name
    if ($null -eq $output -or -not (Test-GatewayArmObjectProperty -Object $output -Name 'value')) {
        throw 'The workload deployment omitted a required reviewed output.'
    }
    return Get-GatewayArmObjectProperty -Object $output -Name 'value'
}

function New-GatewayCoreEvidence {
    param(
        [Parameter(Mandatory)][string]$DeploymentName,
        [Parameter(Mandatory)]$Outputs,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [Parameter()][object[]]$RetryReceipts = @(),
        [Parameter()][System.Collections.IDictionary]$ObservedPartialPrincipalIds = ([ordered]@{})
    )
    if ([string](Get-GatewayCoreOutputValue -Outputs $Outputs -Name 'deploymentOwnershipId') -cne [string]$Parameters.deploymentOwnershipId -or
        [string](Get-GatewayCoreOutputValue -Outputs $Outputs -Name 'bootstrapSourceFingerprint') -cne [string]$Parameters.bootstrapSourceFingerprint -or
        [string](Get-GatewayCoreOutputValue -Outputs $Outputs -Name 'apiContainerImage') -cne [string]$Parameters.apiContainerImage -or
        [string](Get-GatewayCoreOutputValue -Outputs $Outputs -Name 'workerContainerImage') -cne [string]$Parameters.workerContainerImage -or
        -not ([string](Get-GatewayCoreOutputValue -Outputs $Outputs -Name 'runtimeImagePullIdentityId')).Equals([string]$Foundation.runtimeImagePullIdentityId, [StringComparison]::OrdinalIgnoreCase) -or
        [string](Get-GatewayCoreOutputValue -Outputs $Outputs -Name 'runtimeImagePullIdentityPrincipalId') -cne [string]$Foundation.runtimeImagePullIdentityPrincipalId -or
        [string](Get-GatewayCoreOutputValue -Outputs $Outputs -Name 'runtimeImagePullAcrPullRoleAssignmentId') -cne [string]$Foundation.runtimeImagePullAcrPullRoleAssignmentId) {
        throw 'The workload deployment did not echo the exact ownership, source, image, and dedicated-pull-identity boundary.'
    }
    $evidence = [ordered]@{
        deploymentName = $DeploymentName
        deploymentOwnershipId = [string]$Parameters.deploymentOwnershipId
        sourceFingerprint = [string]$Parameters.bootstrapSourceFingerprint
        apiImage = [string]$Parameters.apiContainerImage
        workerImage = [string]$Parameters.workerContainerImage
        runtimeImagePullIdentityId = [string]$Foundation.runtimeImagePullIdentityId
        runtimeImagePullIdentityPrincipalId = [string]$Foundation.runtimeImagePullIdentityPrincipalId
        runtimeImagePullAcrPullRoleAssignmentId = [string]$Foundation.runtimeImagePullAcrPullRoleAssignmentId
    }
    foreach ($mapping in @(
        @('apiFqdn', 'apiFqdn'), @('apiPrincipalId', 'apiPrincipalId'), @('workerPrincipalId', 'workerPrincipalId'),
        @('adminUiFqdn', 'adminUiFqdn'), @('acrLoginServer', 'acrLoginServer'), @('containerRegistryId', 'containerRegistryId'),
        @('keyVaultUri', 'keyVaultUri'), @('sharedKeyVaultId', 'sharedKeyVaultId'), @('storageAccountId', 'storageAccountId'),
        @('storageBlobPrivateEndpointId', 'storageBlobPrivateEndpointId'),
        @('storageBlobPrivateDnsZoneId', 'storageBlobPrivateDnsZoneId'),
        @('sqlServerFqdn', 'sqlServerFqdn'), @('serviceBusQueueName', 'serviceBusQueueName'), @('serviceBusQueueId', 'serviceBusQueueId'),
        @('promptShieldEndpoint', 'promptShieldEndpoint'),
        @('promptShieldAccountId', 'promptShieldAccountId'), @('promptShieldAccountName', 'promptShieldAccountName'),
        @('databaseAttestationExpectedSchemaFingerprint', 'databaseAttestationExpectedSchemaFingerprint'),
        @('databaseAttestationApiPrincipalName', 'databaseAttestationApiPrincipalName'),
        @('databaseAttestationApiPrincipalClientId', 'databaseAttestationApiPrincipalClientId'),
        @('databaseAttestationWorkerPrincipalName', 'databaseAttestationWorkerPrincipalName'),
        @('databaseAttestationWorkerPrincipalClientId', 'databaseAttestationWorkerPrincipalClientId'),
        @('databaseAttestationDatabaseName', 'databaseAttestationDatabaseName')
    )) { $evidence[$mapping[1]] = [string](Get-GatewayCoreOutputValue -Outputs $Outputs -Name $mapping[0]) }
    foreach ($mapping in @(
        @('provisioningExecutionEnabled', 'provisioningExecutionEnabled'),
        @('workerProcessingEnabled', 'workerProcessingEnabled'),
        @('databaseAttestationEnabled', 'databaseAttestationEnabled')
    )) { $evidence[$mapping[1]] = [bool](Get-GatewayCoreOutputValue -Outputs $Outputs -Name $mapping[0]) }
    foreach ($entry in $ObservedPartialPrincipalIds.GetEnumerator()) {
        $outputName = if ([string]$entry.Key -ceq 'Api') { 'apiPrincipalId' } elseif ([string]$entry.Key -ceq 'Worker') { 'workerPrincipalId' } else { '' }
        if ([string]::IsNullOrWhiteSpace($outputName) -or [string]$evidence[$outputName] -cne [string]$entry.Value) {
            throw 'A recovered Container App system principal drifted across the same-name ARM retry.'
        }
    }
    if ($RetryReceipts.Count -gt 0) { $evidence.terminalDeploymentRetryReceipts = @($RetryReceipts) }
    if ($ObservedPartialPrincipalIds.Count -gt 0) { $evidence.observedPartialPrincipalIds = $ObservedPartialPrincipalIds }
    return $evidence
}

function Get-GatewayInertRecoveredRetryReceipts {
    param(
        [AllowNull()]$RecoveredEvidence,
        [Parameter(Mandatory)][string]$DeploymentName,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )
    if ($null -eq $RecoveredEvidence) { return [ordered]@{ receipts = @(); principalIds = [ordered]@{} } }
    foreach ($entry in ([ordered]@{
        deploymentName = $DeploymentName
        deploymentOwnershipId = $DeploymentOwnershipId
        sourceFingerprint = $SourceFingerprint
    }).GetEnumerator()) {
        if ([string](Get-GatewayArmObjectProperty -Object $RecoveredEvidence -Name ([string]$entry.Key)) -cne [string]$entry.Value) {
            throw 'Recovered inert retry evidence is not bound to the exact deployment, owner, and source.'
        }
    }
    $receipts = @(Get-GatewayArmArrayItems -Value (Get-GatewayArmObjectProperty -Object $RecoveredEvidence -Name 'terminalDeploymentRetryReceipts'))
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($receipt in $receipts) {
        $names = @(Get-GatewayArmObjectPropertyNames -Object $receipt)
        if ($names.Count -ne 4 -or (($names | Sort-Object -CaseSensitive) -join '|') -cne 'correlationId|mode|state|timestamp') {
            throw 'Recovered inert retry evidence contains a non-minimal receipt.'
        }
        $correlationId = [string](Get-GatewayArmObjectProperty -Object $receipt -Name 'correlationId')
        $parsed = [guid]::Empty
        $timestamp = [DateTimeOffset]::MinValue
        if (-not $seen.Add($correlationId) -or -not [guid]::TryParse($correlationId, [ref]$parsed) -or $parsed -eq [guid]::Empty -or
            $correlationId -cne $parsed.ToString('D') -or [string](Get-GatewayArmObjectProperty -Object $receipt -Name 'state') -notin @('Failed', 'Canceled') -or
            [string](Get-GatewayArmObjectProperty -Object $receipt -Name 'mode') -cne 'Incremental' -or
            -not [DateTimeOffset]::TryParse([string](Get-GatewayArmObjectProperty -Object $receipt -Name 'timestamp'), [ref]$timestamp)) {
            throw 'Recovered inert retry evidence contains an invalid receipt.'
        }
    }
    $principalIds = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $recoveredPrincipalIds = Get-GatewayArmObjectProperty -Object $RecoveredEvidence -Name 'observedPartialPrincipalIds'
    if ($null -ne $recoveredPrincipalIds) {
        foreach ($role in @(Get-GatewayArmObjectPropertyNames -Object $recoveredPrincipalIds)) {
            $value = [string](Get-GatewayArmObjectProperty -Object $recoveredPrincipalIds -Name $role)
            $parsedPrincipalId = [guid]::Empty
            if ($role -cnotin @('Api', 'Worker') -or -not [guid]::TryParse($value, [ref]$parsedPrincipalId) -or
                $parsedPrincipalId -eq [guid]::Empty -or $value -cne $parsedPrincipalId.ToString('D')) {
                throw 'Recovered inert retry evidence contains an invalid observed principal binding.'
            }
            $principalIds[$role] = $value
        }
    }
    foreach ($entry in ([ordered]@{ Api = 'apiPrincipalId'; Worker = 'workerPrincipalId' }).GetEnumerator()) {
        $value = [string](Get-GatewayArmObjectProperty -Object $RecoveredEvidence -Name ([string]$entry.Value))
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $parsedPrincipalId = [guid]::Empty
        if (-not [guid]::TryParse($value, [ref]$parsedPrincipalId) -or $parsedPrincipalId -eq [guid]::Empty -or
            $value -cne $parsedPrincipalId.ToString('D') -or
            ($principalIds.ContainsKey([string]$entry.Key) -and [string]$principalIds[$entry.Key] -cne $value)) {
            throw 'Recovered completed inert evidence conflicts with its observed principal binding.'
        }
        $principalIds[$entry.Key] = $value
    }
    return [ordered]@{ receipts = @($receipts); principalIds = $principalIds }
}

function Assert-GatewaySucceededContainerAppBoundary {
    param(
        [Parameter(Mandatory)]$App,
        [Parameter(Mandatory)][ValidateSet('Api', 'Worker')][string]$Role,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][string]$ExpectedImage,
        [Parameter(Mandatory)][string]$ExpectedPrincipalId,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )
    $name = if ($Role -ceq 'Api') { "ca-gateway-api-$($Config.environment)" } else { "ca-gateway-worker-$($Config.environment)-v3" }
    if ([string]$App.name -cne $name -or [string]$App.properties.provisioningState -cne 'Succeeded' -or
        (ConvertTo-GatewayCanonicalAzureLocation -Location ([string]$App.location)) -cne
            (ConvertTo-GatewayCanonicalAzureLocation -Location ([string]$Config.location)) -or
        [string]$App.properties.template.containers[0].name -cne $name -or
        [string]$App.properties.template.containers[0].image -cne $ExpectedImage -or
        [string]$App.identity.principalId -cne $ExpectedPrincipalId -or
        -not ([string]$App.properties.managedEnvironmentId).Equals([string]$Foundation.containerAppsEnvironmentId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$App.properties.configuration.activeRevisionsMode -cne 'Single' -or
        @(Get-GatewayArmArrayItems -Value (Get-GatewayArmObjectProperty -Object $App.properties.configuration -Name 'secrets')).Count -ne 0) {
        throw 'A completed inert Container App is outside the exact image, identity, environment, and secret-free boundary.'
    }
    Assert-GatewayExactTagMap -ActualTags $App.tags -ExpectedTags ([ordered]@{
        project = 'a365-gateway'; environment = [string]$Config.environment; managedBy = 'bicep'
        projectName = [string]$Config.projectName; deploymentId = "$($Config.projectName)-$($Config.environment)"
        bootstrapOwnershipId = $DeploymentOwnershipId; bootstrapSourceFingerprint = $SourceFingerprint
    }) | Out-Null
    Assert-GatewayExactImagePullIdentityEnvelope -Identity $App.identity `
        -ExpectedIdentityId ([string]$Foundation.runtimeImagePullIdentityId) `
        -ExpectedIdentityPrincipalId ([string]$Foundation.runtimeImagePullIdentityPrincipalId) `
        -ExpectedTenantId ([string]$Config.tenantId) -RequireComplete | Out-Null
    Assert-GatewayExactPartialRegistryEnvelope -Registries $App.properties.configuration.registries `
        -ExpectedServer ([string]$Foundation.acrLoginServer) `
        -ExpectedIdentityId ([string]$Foundation.runtimeImagePullIdentityId) -RequireComplete | Out-Null
    $ingress = Get-GatewayArmObjectProperty -Object $App.properties.configuration -Name 'ingress'
    if ($Role -ceq 'Worker' -and $null -ne $ingress) { throw 'A completed inert worker unexpectedly exposes ingress.' }
    if ($Role -ceq 'Api' -and ($null -eq $ingress -or $ingress.external -ne $true -or $ingress.allowInsecure -ne $false -or
        [int]$ingress.targetPort -ne 8080 -or
        -not ([string]$ingress.transport).Equals('auto', [StringComparison]::OrdinalIgnoreCase))) {
        throw 'A completed inert API does not retain the exact external HTTPS-only ingress boundary.'
    }
    return $true
}

function Deploy-GatewayCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$ApiImage,
        [Parameter(Mandatory)][string]$WorkerImage,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkerPrincipalId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ManagerApplicationIds,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter()]$Database,
        [Parameter()][string]$AdminUiImage = '',
        [Parameter()][string]$AdminUiClientId = '',
        [Parameter()][string]$AdminUiSecretUri = '',
        [Parameter()][switch]$Initial,
        [Parameter()][switch]$EnableWorkerProcessing,
        [Parameter()][switch]$EnableProvisioning,
        [Parameter()][switch]$EnablePurview,
        [Parameter()][AllowNull()]$RecoveredEvidence,
        [Parameter()][scriptblock]$Checkpoint,
        [Parameter()][switch]$SucceededRecoveryOnly,
        [Parameter()][string]$ExecutionSourceFingerprint = ''
    )
    if ($SucceededRecoveryOnly -and -not $Initial) {
        throw 'Succeeded-only workload recovery is available only for the initial inert deployment.'
    }
    $root = Get-BootstrapExecutionSourceRoot
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Deployment ownership ID must be a canonical lowercase GUID from the current bootstrap state.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Deployment source fingerprint'
    if ([string]::IsNullOrWhiteSpace($ExecutionSourceFingerprint)) {
        $ExecutionSourceFingerprint = $SourceFingerprint
    }
    Assert-BootstrapFingerprintValue -Value $ExecutionSourceFingerprint -Label 'Workload execution source fingerprint'
    if ((Get-BootstrapSourceFingerprint -Root $root) -cne $ExecutionSourceFingerprint) {
        throw 'The workload execution source no longer matches the accepted content-addressed snapshot.'
    }
    $subscriptionId = ([guid][string]$Config.subscriptionId).ToString('D')
    $tenantId = ([guid][string]$Config.tenantId).ToString('D')
    if ([string]$Config.subscriptionId -cne $subscriptionId -or [string]$Config.tenantId -cne $tenantId) {
        throw 'Gateway core scope requires canonical subscription and tenant IDs.'
    }
    $pullEvidence = Assert-GatewayRuntimeImagePullFoundationEvidence -Config $Config -Foundation $Foundation
    $expectedCaeName = "cae-$($Config.projectName)-$($Config.environment)-vnet"
    $expectedCaeId = "/subscriptions/$subscriptionId/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.App/managedEnvironments/$expectedCaeName"
    $expectedAcrPrefix = "acr$($Config.projectName)$($Config.environment)"
    if ([string]$Foundation.deploymentOwnershipId -cne $canonicalOwnershipId -or
        [string]$Foundation.sourceFingerprint -cne $SourceFingerprint -or
        [string]$Foundation.resourceGroupName -cne [string]$Config.resourceGroupName -or
        [string]$Foundation.containerAppsEnvironmentName -cne $expectedCaeName -or
        -not ([string]$Foundation.containerAppsEnvironmentId).Equals($expectedCaeId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$Foundation.virtualNetworkName -cne "vnet-$($Config.projectName)-$($Config.environment)" -or
        [string]$Foundation.privateEndpointSubnetName -cne 'snet-private-endpoints' -or
        [string]$Foundation.acrName -cnotmatch "^$([regex]::Escape($expectedAcrPrefix))[a-z0-9]{6}$" -or
        [string]$Foundation.acrLoginServer -cne "$($Foundation.acrName).azurecr.io") {
        throw 'Gateway core Foundation evidence is not the exact current owner/source-bound deployment foundation.'
    }
    foreach ($entry in ([ordered]@{
        gatewayApiClientId = [string]$Identity.gatewayApiClientId
        userObjectId = [string]$Identity.userObjectId
    }).GetEnumerator()) {
        $parsedIdentityGuid = [guid]::Empty
        if (-not [guid]::TryParse([string]$entry.Value, [ref]$parsedIdentityGuid) -or $parsedIdentityGuid -eq [guid]::Empty -or
            [string]$entry.Value -cne $parsedIdentityGuid.ToString('D')) {
            throw 'Gateway core identity evidence contains a noncanonical application or administrator ID.'
        }
    }
    $expectedGatewayApiScopeBaseUri = "api://a365-gateway-$($Config.projectName)-$($Config.environment)"
    if ([string]$Identity.gatewayApiScopeBaseUri -cne $expectedGatewayApiScopeBaseUri -or
        [string]$Identity.gatewayApiTokenAudience -cne [string]$Identity.gatewayApiClientId -or
        [string]::IsNullOrWhiteSpace([string]$Identity.userPrincipalName)) {
        throw 'Gateway core identity evidence does not match the exact API application authority contract.'
    }
    if ($Initial) {
        if ($WorkerPrincipalId -cne '' -or $ManagerApplicationIds.Count -ne 0) {
            throw 'Initial inert deployment requires empty worker and managerApplications authority inputs.'
        }
        if ($null -ne $Database -or
            $EnableWorkerProcessing -or $EnableProvisioning -or $EnablePurview -or
            -not [string]::IsNullOrEmpty($AdminUiImage) -or
            -not [string]::IsNullOrEmpty($AdminUiClientId) -or
            -not [string]::IsNullOrEmpty($AdminUiSecretUri)) {
            throw 'Initial inert deployment rejects database, activation, Purview, and Admin UI runtime inputs.'
        }
    }
    else {
        $parsedWorkerPrincipalId = [guid]::Empty
        if (-not [guid]::TryParse($WorkerPrincipalId, [ref]$parsedWorkerPrincipalId) -or
            $parsedWorkerPrincipalId -eq [guid]::Empty -or
            $WorkerPrincipalId -cne $parsedWorkerPrincipalId.ToString('D')) {
            throw 'Runtime deployment requires one canonical lowercase worker managed-identity principal ID.'
        }
    }
    $canonicalManagerApplicationIds = @()
    if (-not $Initial) {
        $reviewedManagerIds = @($Config.agent365.reviewedManagerApplicationIds | ForEach-Object { ([guid][string]$_).ToString('D') } | Sort-Object -Unique)
        $requestedManagerIds = @($ManagerApplicationIds | ForEach-Object { ([guid][string]$_).ToString('D') } | Sort-Object -Unique)
        if ($reviewedManagerIds.Count -eq 0 -or
            $reviewedManagerIds.Count -ne @($Config.agent365.reviewedManagerApplicationIds).Count -or
            $requestedManagerIds.Count -ne $ManagerApplicationIds.Count -or
            ($reviewedManagerIds -join '|') -cne ($requestedManagerIds -join '|')) {
            throw 'Runtime managerApplications must exactly equal the independently reviewed configuration; provider-discovered authority is never accepted implicitly.'
        }
        $canonicalManagerApplicationIds = @($requestedManagerIds)
        if (-not $Database -or
            [string]$Database.deploymentOwnershipId -cne $canonicalOwnershipId -or
            [string]$Database.acceptedSourceFingerprint -cne $SourceFingerprint -or
            [string]$Database.server -cnotmatch '^[A-Za-z0-9-]+\.database\.windows\.net$' -or
            [string]$Database.database -cne 'GatewayDb' -or
            [string]$Database.schemaFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$Database.apiPrincipalName -cne "ca-gateway-api-$($Config.environment)" -or
            [string]$Database.workerPrincipalName -cne "ca-gateway-worker-$($Config.environment)-v3" -or
            [string]$Database.workerPrincipalObjectId -cne $WorkerPrincipalId) {
            throw 'Runtime deployment requires exact ownership/source-bound current database-attestation evidence.'
        }
        Assert-GuidValue -Value ([string]$Database.apiPrincipalClientId) -Label 'Gateway API database-principal client ID'
        Assert-GuidValue -Value ([string]$Database.workerPrincipalClientId) -Label 'Gateway worker database-principal client ID'
    }
    if ($EnablePurview -and $Config.purview.policyProvisioningEnabled -eq $true) {
        $configuredVaultHost = ([Uri][string]$Config.purview.policyProvisioningCertificateSecretUri).Host
        # The bootstrap foundation precedes the workload deployment that creates
        # Key Vault, so its evidence intentionally has no keyVaultUri output. The
        # shared vault name is nevertheless deterministic in the reviewed Bicep.
        $gatewayVaultHost = "kv-$($Config.projectName)-$($Config.environment).vault.azure.net"
        if (-not $configuredVaultHost.Equals($gatewayVaultHost, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Purview policy automation certificate must be stored in the Gateway shared Key Vault '$gatewayVaultHost' so the worker's read-only role remains narrowly scoped."
        }
    }
    $enablePreview = $EnableProvisioning -and [string]$Config.environment -eq 'dev' -and $Config.agent365.allowDevelopmentRegistryPreview -eq $true
    $parameters = [ordered]@{
        environment = [string]$Config.environment
        location = [string]$Config.location
        projectName = [string]$Config.projectName
        deploymentOwnershipId = $canonicalOwnershipId
        bootstrapSourceFingerprint = $SourceFingerprint
        databaseAttestationEnabled = [bool](-not $Initial)
        databaseAttestationExpectedSchemaFingerprint = if ($Initial) { '' } else { [string]$Database.schemaFingerprint }
        databaseAttestationApiPrincipalName = if ($Initial) { '' } else { [string]$Database.apiPrincipalName }
        databaseAttestationApiPrincipalClientId = if ($Initial) { '' } else { [string]$Database.apiPrincipalClientId }
        databaseAttestationWorkerPrincipalName = if ($Initial) { '' } else { [string]$Database.workerPrincipalName }
        databaseAttestationWorkerPrincipalClientId = if ($Initial) { '' } else { [string]$Database.workerPrincipalClientId }
        containerAppsEnvironmentName = [string]$Foundation.containerAppsEnvironmentName
        runtimeImagePullIdentityId = [string]$pullEvidence.identityId
        runtimeImagePullIdentityPrincipalId = [string]$pullEvidence.principalId
        runtimeImagePullAcrPullRoleAssignmentId = [string]$pullEvidence.roleAssignmentId
        virtualNetworkName = [string]$Foundation.virtualNetworkName
        privateEndpointSubnetName = [string]$Foundation.privateEndpointSubnetName
        entraIdTenantId = [string]$Config.tenantId
        entraIdClientId = [string]$Identity.gatewayApiClientId
        entraIdAudience = [string]$Identity.gatewayApiTokenAudience
        entraAdminObjectId = [string]$Identity.userObjectId
        entraAdminLogin = [string]$Identity.userPrincipalName
        apiContainerImage = $ApiImage
        workerContainerImage = $WorkerImage
        workerContainerAppName = "ca-gateway-worker-$($Config.environment)-v3"
        agent365ProvisioningManagedIdentityPrincipalId = $WorkerPrincipalId
        historicalWorkerContainerAppName = "ca-gateway-worker-$($Config.environment)"
        preserveExistingApiSecrets = -not $Initial
        allowLegacySystemAssignedImagePull = $false
        workerProcessingEnabled = [bool]$EnableWorkerProcessing
        provisioningExecutionEnabled = [bool]$EnableProvisioning
        continuousDevelopmentProvisioningEnabled = [bool]$enablePreview
        agent365DelegatedRegistryEnabled = [bool]$enablePreview
        agent365ManagerApplicationsPreflightConfirmed = [bool](-not $Initial -and $ManagerApplicationIds.Count -gt 0)
        agent365ManagerApplicationIds = @($canonicalManagerApplicationIds)
        purviewEnabled = [bool]$EnablePurview
        promptShieldEnabled = [bool]$Config.promptShield.enabled
        promptShieldSkuName = [string]$Config.promptShield.skuName
        purviewPolicyProvisioningEnabled = [bool]($EnablePurview -and $Config.purview.policyProvisioningEnabled -eq $true)
        purviewPolicyProvisioningOrganization = [string]$Config.purview.policyProvisioningOrganization
        purviewPolicyProvisioningApplicationId = [string]$Config.purview.policyProvisioningApplicationId
        purviewPolicyProvisioningCertificateSecretUri = [string]$Config.purview.policyProvisioningCertificateSecretUri
        purviewDefaultSensitiveInformationTypeId = [string]$Config.purview.sensitiveInformationTypeId
        purviewDefaultSensitiveInformationType = [string]$Config.purview.sensitiveInformationType
        deployAdminUi = -not [string]::IsNullOrWhiteSpace($AdminUiImage)
        adminUiContainerImage = $AdminUiImage
        adminUiEntraClientId = $AdminUiClientId
        adminUiEntraClientSecretKeyVaultSecretUri = $AdminUiSecretUri
        adminUiGatewayApiScope = if ([string]::IsNullOrWhiteSpace($AdminUiClientId)) { '' } else { "$($Identity.gatewayApiScopeBaseUri)/access_as_user" }
        alertEmail = [string]$Config.alertEmail
        logRetentionInDays = 30
        acrSku = 'Basic'
        sqlSkuName = [string]$Config.sql.skuName
        sqlSkuTier = [string]$Config.sql.skuTier
        serviceBusSku = 'Basic'
        serviceBusQueueName = 'gateway-provisioning-v3'
        storageSku = 'Standard_LRS'
        apiCpu = '0.5'
        apiMemory = '1Gi'
        apiMinReplicas = 1
        apiMaxReplicas = 3
        workerCpu = '0.25'
        workerMemory = '0.5Gi'
        workerMaxReplicas = 3
        adminUiCpu = '0.5'
        adminUiMemory = '1Gi'
        adminUiMinReplicas = 1
        adminUiMaxReplicas = 1
        keyVaultPurgeProtection = $true
    }
    $name = if ($Initial) { "a365gw-$($Config.projectName)-bootstrap-inert-$($Config.environment)" } else { "a365gw-$($Config.projectName)-bootstrap-runtime-$($Config.environment)" }
    $retryReceipts = @()
    $observedPartialPrincipalIds = [ordered]@{}
    if ($Initial) {
        $deploymentCountText = Invoke-AzTsv -Arguments @(
            'deployment', 'group', 'list', '--resource-group', [string]$Config.resourceGroupName,
            '--query', "length([?name=='$name'])"
        )
        $deploymentCount = 0
        if (-not [int]::TryParse($deploymentCountText, [ref]$deploymentCount) -or $deploymentCount -notin @(0, 1)) {
            throw 'Azure returned an invalid or duplicate inert deployment discovery result; no workload mutation was attempted.'
        }
        if ($deploymentCount -eq 0) {
            if ($SucceededRecoveryOnly) {
                throw 'The exact Succeeded inert deployment required for read-only recovery is absent.'
            }
            if ($null -ne $RecoveredEvidence) {
                throw 'A prior inert deployment receipt or evidence exists but the source-bound ARM deployment record is absent.'
            }
            foreach ($containerAppName in @("ca-gateway-api-$($Config.environment)", "ca-gateway-worker-$($Config.environment)-v3")) {
                $resourceCountText = Invoke-AzTsv -Arguments @(
                    'resource', 'list', '--resource-group', [string]$Config.resourceGroupName,
                    '--name', $containerAppName, '--resource-type', 'Microsoft.App/containerApps', '--query', 'length(@)'
                )
                $resourceCount = 0
                if (-not [int]::TryParse($resourceCountText, [ref]$resourceCount) -or $resourceCount -ne 0) {
                    throw "The fresh inert deployment target '$containerAppName' was not proven absent. Refusing to adopt or overwrite a pre-existing security principal."
                }
            }
        }
        else {
            $existingDeployment = Invoke-AzJson -Arguments @(
                'deployment', 'group', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $name
            )
            if (-not $existingDeployment -or [string]$existingDeployment.properties.mode -cne 'Incremental') {
                throw 'The existing inert deployment is absent, unreadable, or not the exact Incremental contract.'
            }
            Assert-GatewayExactReadableArmParameters `
                -ActualParameters $existingDeployment.properties.parameters `
                -ExpectedParameters $parameters `
                -SecureParameterNames @('adminUiEntraClientSecretKeyVaultSecretUri') | Out-Null
            $existingState = [string]$existingDeployment.properties.provisioningState
            $recoveryCheckpoint = Get-GatewayInertRecoveredRetryReceipts -RecoveredEvidence $RecoveredEvidence `
                -DeploymentName $name -DeploymentOwnershipId $canonicalOwnershipId -SourceFingerprint $SourceFingerprint
            $retryReceipts = @($recoveryCheckpoint.receipts)
            foreach ($entry in $recoveryCheckpoint.principalIds.GetEnumerator()) { $observedPartialPrincipalIds[$entry.Key] = $entry.Value }
            if ($existingState -ceq 'Succeeded') {
                $evidence = New-GatewayCoreEvidence -DeploymentName $name -Outputs $existingDeployment.properties.outputs `
                    -Foundation $Foundation -Parameters $parameters -RetryReceipts $retryReceipts `
                    -ObservedPartialPrincipalIds $observedPartialPrincipalIds
                $existingApi = Invoke-AzJson -Arguments @('containerapp', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', "ca-gateway-api-$($Config.environment)")
                $existingWorker = Invoke-AzJson -Arguments @('containerapp', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', "ca-gateway-worker-$($Config.environment)-v3")
                Assert-GatewaySucceededContainerAppBoundary -App $existingApi -Role Api -Config $Config -Foundation $Foundation `
                    -ExpectedImage $ApiImage -ExpectedPrincipalId ([string]$evidence.apiPrincipalId) `
                    -DeploymentOwnershipId $canonicalOwnershipId -SourceFingerprint $SourceFingerprint | Out-Null
                Assert-GatewaySucceededContainerAppBoundary -App $existingWorker -Role Worker -Config $Config -Foundation $Foundation `
                    -ExpectedImage $WorkerImage -ExpectedPrincipalId ([string]$evidence.workerPrincipalId) `
                    -DeploymentOwnershipId $canonicalOwnershipId -SourceFingerprint $SourceFingerprint | Out-Null
                if ($null -ne $Checkpoint) { & $Checkpoint $evidence | Out-Null }
                return $evidence
            }
            if ($SucceededRecoveryOnly) {
                throw 'The exact inert deployment required for read-only recovery is not Succeeded; no mutation was attempted.'
            }
            if ($existingState -notin @('Failed', 'Canceled')) {
                throw 'The existing inert deployment is nonterminal or has an unknown state; no mutation was attempted.'
            }

            $partialApps = @()
            foreach ($target in @(
                [ordered]@{ role = 'Api'; name = "ca-gateway-api-$($Config.environment)"; image = $ApiImage },
                [ordered]@{ role = 'Worker'; name = "ca-gateway-worker-$($Config.environment)-v3"; image = $WorkerImage }
            )) {
                $resourceCountText = Invoke-AzTsv -Arguments @(
                    'resource', 'list', '--resource-group', [string]$Config.resourceGroupName,
                    '--name', [string]$target.name, '--resource-type', 'Microsoft.App/containerApps', '--query', 'length(@)'
                )
                $resourceCount = 0
                if (-not [int]::TryParse($resourceCountText, [ref]$resourceCount) -or $resourceCount -notin @(0, 1)) {
                    throw 'The terminal inert deployment has an invalid or duplicate partial Container App boundary.'
                }
                if ($resourceCount -eq 1) { $partialApps += ,$target }
            }
            $environmentContracts = if ($partialApps.Count -gt 0) {
                Get-GatewayInertPartialEnvironmentContract -Roles @($partialApps | ForEach-Object { [string]$_.role }) `
                    -Config $Config -Foundation $Foundation -Identity $Identity `
                    -DeploymentOwnershipId $canonicalOwnershipId -SourceFingerprint $SourceFingerprint
            }
            else { [ordered]@{} }
            $currentPartialPrincipalIds = [ordered]@{}
            foreach ($target in $partialApps) {
                $partialApp = Invoke-AzJson -Arguments @(
                    'containerapp', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', [string]$target.name,
                    '--query', '{id:id,name:name,type:type,location:location,tags:tags,identity:identity,properties:{provisioningState:properties.provisioningState,managedEnvironmentId:properties.managedEnvironmentId,configuration:{activeRevisionsMode:properties.configuration.activeRevisionsMode,secretCount:length(not_null(properties.configuration.secrets, `[]`)),registries:properties.configuration.registries,ingress:properties.configuration.ingress},template:{containers:properties.template.containers[].{name:name,image:image,resources:resources,env:env,command:command,args:args,probes:probes,volumeMounts:volumeMounts},volumes:properties.template.volumes,scale:properties.template.scale}}}'
                )
                Assert-GatewayExactPartialContainerAppEnvelope -App $partialApp -Role ([string]$target.role) `
                    -Config $Config -Foundation $Foundation -ExpectedImage ([string]$target.image) `
                    -DeploymentOwnershipId $canonicalOwnershipId -SourceFingerprint $SourceFingerprint `
                    -ExpectedEnvironment $environmentContracts[[string]$target.role] | Out-Null
                $principalId = [string](Get-GatewayArmObjectProperty `
                    -Object (Get-GatewayArmObjectProperty -Object $partialApp -Name 'identity') -Name 'principalId')
                if (-not [string]::IsNullOrWhiteSpace($principalId)) { $currentPartialPrincipalIds[[string]$target.role] = $principalId }
            }
            foreach ($entry in $observedPartialPrincipalIds.GetEnumerator()) {
                if (-not $currentPartialPrincipalIds.Contains($entry.Key) -or
                    [string]$currentPartialPrincipalIds[$entry.Key] -cne [string]$entry.Value) {
                    throw 'A previously observed partial Container App principal is absent or has drifted.'
                }
            }
            foreach ($entry in $currentPartialPrincipalIds.GetEnumerator()) {
                if ($observedPartialPrincipalIds.Contains($entry.Key) -and
                    [string]$observedPartialPrincipalIds[$entry.Key] -cne [string]$entry.Value) {
                    throw 'A partial Container App principal has drifted before retry.'
                }
                $observedPartialPrincipalIds[$entry.Key] = $entry.Value
            }

            $receipt = New-GatewayInertDeploymentRetryReceipt -Deployment $existingDeployment
            $matchingReceipt = @($retryReceipts | Where-Object { [string]$_.correlationId -ceq [string]$receipt.correlationId })
            if ($matchingReceipt.Count -gt 1 -or ($matchingReceipt.Count -eq 1 -and
                (Get-BootstrapObjectFingerprint -InputObject $matchingReceipt[0]) -cne (Get-BootstrapObjectFingerprint -InputObject $receipt))) {
                throw 'The current terminal deployment receipt conflicts with preserved retry history.'
            }
            if ($matchingReceipt.Count -eq 0) { $retryReceipts += ,$receipt }
            if ($null -eq $Checkpoint) {
                throw 'Terminal inert deployment recovery requires a durable pre-retry checkpoint callback.'
            }
            & $Checkpoint ([ordered]@{
                deploymentName = $name
                deploymentOwnershipId = $canonicalOwnershipId
                sourceFingerprint = $SourceFingerprint
                terminalDeploymentRetryReceipts = @($retryReceipts)
                observedPartialPrincipalIds = $observedPartialPrincipalIds
            }) | Out-Null
        }
    }
    if ($SucceededRecoveryOnly) {
        throw 'The exact Succeeded inert deployment required for read-only recovery was not recovered; no mutation was attempted.'
    }
    $deployment = Invoke-ArmDeploymentWithSecureParameters -ResourceGroup ([string]$Config.resourceGroupName) -Name $name `
        -TemplateFile (Join-Path $root 'infrastructure/bicep/main.bicep') -Parameters $parameters -Mode Incremental
    if (-not $deployment -or [string]$deployment.properties.provisioningState -cne 'Succeeded') {
        throw 'The workload ARM deployment did not return a completed Succeeded result.'
    }
    $evidence = New-GatewayCoreEvidence -DeploymentName $name -Outputs $deployment.properties.outputs `
        -Foundation $Foundation -Parameters $parameters -RetryReceipts $retryReceipts `
        -ObservedPartialPrincipalIds $observedPartialPrincipalIds
    if ($Initial -and $null -ne $Checkpoint) { & $Checkpoint $evidence | Out-Null }
    return $evidence
}

function ConvertTo-GatewayCanonicalArmResourceId {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Label
    )
    $targetPrefix = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/"
    if ([string]::IsNullOrWhiteSpace($ResourceId) -or
        -not $ResourceId.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $ResourceId.Length -le $targetPrefix.Length -or $ResourceId.EndsWith('/', [StringComparison]::Ordinal) -or
        $ResourceId.Contains('?') -or $ResourceId.Contains('#') -or $ResourceId.Contains('//')) {
        throw "$Label is outside the exact target resource-group provider boundary."
    }
    return $ResourceId.ToLowerInvariant()
}

function Get-GatewayInertBoundaryResource {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$ApiVersion
    )
    $resource = Invoke-AzJson -Arguments @(
        'resource', 'show', '--ids', $ResourceId, '--api-version', $ApiVersion
    )
    if ($null -eq $resource) {
        throw 'An exact inert recovery resource was absent or unreadable.'
    }
    return $resource
}

function Get-GatewayInertBoundaryTypeInventory {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ResourceType
    )
    return @(Invoke-AzJson -Arguments @(
        'resource', 'list', '--resource-group', [string]$Config.resourceGroupName,
        '--resource-type', $ResourceType, '--query', '[].{id:id}'
    ))
}

function Assert-GatewayInertBoundaryResourceEnvelope {
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][string]$ExpectedId,
        [Parameter(Mandatory)][string]$ExpectedType,
        [Parameter(Mandatory)][string]$ExpectedName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedLocation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedTags,
        [switch]$TagsAreProviderGenerated
    )
    $actualId = [string](Get-GatewayArmObjectProperty -Object $Resource -Name 'id')
    $actualType = [string](Get-GatewayArmObjectProperty -Object $Resource -Name 'type')
    $actualName = [string](Get-GatewayArmObjectProperty -Object $Resource -Name 'name')
    $actualLocation = [string](Get-GatewayArmObjectProperty -Object $Resource -Name 'location')
    if (-not $actualId.Equals($ExpectedId, [StringComparison]::OrdinalIgnoreCase) -or
        -not $actualType.Equals($ExpectedType, [StringComparison]::OrdinalIgnoreCase) -or
        $actualName -cne $ExpectedName -or
        -not $actualLocation.Equals($ExpectedLocation, [StringComparison]::OrdinalIgnoreCase)) {
        throw "An inert recovery resource does not match its exact ID, type, name, and location envelope ($ExpectedType/$ExpectedName)."
    }
    $properties = Get-GatewayArmObjectProperty -Object $Resource -Name 'properties'
    if ($null -ne $properties -and (Test-GatewayArmObjectProperty -Object $properties -Name 'provisioningState') -and
        [string](Get-GatewayArmObjectProperty -Object $properties -Name 'provisioningState') -cne 'Succeeded') {
        throw 'An inert recovery resource is not in the exact Succeeded state.'
    }
    if (-not $TagsAreProviderGenerated) {
        $actualTags = Get-GatewayArmObjectProperty -Object $Resource -Name 'tags'
        if ($null -eq $actualTags) { $actualTags = [ordered]@{} }
        Assert-GatewayExactTagMap -ActualTags $actualTags -ExpectedTags $ExpectedTags | Out-Null
    }
    return $true
}

function Assert-GatewayExactArmIdCollection {
    param(
        [AllowNull()]$Items,
        [Parameter(Mandatory)][string[]]$ExpectedIds,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Label
    )
    $expected = @($ExpectedIds | ForEach-Object {
        ConvertTo-GatewayCanonicalArmResourceId -ResourceId $_ -Config $Config -Label $Label
    } | Sort-Object -CaseSensitive)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $actual = @()
    foreach ($item in @(Get-GatewayArmArrayItems -Value $Items)) {
        $rawId = [string](Get-GatewayArmObjectProperty -Object $item -Name $PropertyName)
        $id = ConvertTo-GatewayCanonicalArmResourceId -ResourceId $rawId -Config $Config -Label $Label
        if (-not $seen.Add($id)) { throw "$Label contains a duplicate exact resource ID." }
        $actual += $id
    }
    $actual = @($actual | Sort-Object -CaseSensitive)
    if ($actual.Count -ne $expected.Count -or ($actual -join '|') -cne ($expected -join '|')) {
        throw "$Label contains a missing, extra, or mismatched resource relationship."
    }
    return $true
}

function New-GatewayInertWhatIfRecoveryBoundary {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$ApiImage,
        [Parameter(Mandatory)][string]$WorkerImage,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [AllowNull()][System.Collections.IDictionary]$AdditionalTypeInventoryResourceIds
    )
    if ($Config.promptShield.enabled -eq $true) {
        throw 'The exact 25-resource inert What-If recovery boundary does not include optional Prompt Shields resources.'
    }
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Inert What-If recovery source fingerprint'
    $deploymentName = "a365gw-$($Config.projectName)-bootstrap-inert-$($Config.environment)"
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId -or
        [string]$Evidence.deploymentName -cne $deploymentName -or
        [string]$Evidence.deploymentOwnershipId -cne $canonicalOwnershipId -or
        [string]$Evidence.sourceFingerprint -cne $SourceFingerprint -or
        [string]$Evidence.apiImage -cne $ApiImage -or [string]$Evidence.workerImage -cne $WorkerImage) {
        throw 'Succeeded inert evidence is not bound to the exact deployment, owner, source, and images.'
    }

    $additionalInventory = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    if ($null -ne $AdditionalTypeInventoryResourceIds) {
        [string[]]$expectedAdditionalTypes = @(
            'Microsoft.Network/networkInterfaces',
            'Microsoft.Network/privateDnsZones',
            'Microsoft.Network/privateDnsZones/virtualNetworkLinks',
            'Microsoft.Network/privateEndpoints'
        )
        [string[]]$actualAdditionalTypes = @($AdditionalTypeInventoryResourceIds.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($expectedAdditionalTypes, [StringComparer]::Ordinal)
        [Array]::Sort($actualAdditionalTypes, [StringComparer]::Ordinal)
        if ($actualAdditionalTypes.Count -ne $expectedAdditionalTypes.Count -or
            ($actualAdditionalTypes -join "`n") -cne ($expectedAdditionalTypes -join "`n")) {
            throw 'The inert recovery inventory extension does not match the exact SQL private-endpoint type surface.'
        }
        foreach ($resourceType in $expectedAdditionalTypes) {
            $rawIds = $AdditionalTypeInventoryResourceIds[$resourceType]
            if ($rawIds -isnot [System.Collections.IList] -or @($rawIds).Count -ne 1) {
                throw 'The inert recovery inventory extension must contain exactly one SQL private-endpoint resource per reviewed type.'
            }
            $canonicalId = ConvertTo-GatewayCanonicalArmResourceId `
                -ResourceId ([string]@($rawIds)[0]) `
                -Config $Config `
                -Label 'SQL private-endpoint recovery inventory extension'
            $additionalInventory[$resourceType] = @($canonicalId)
        }
    }

    $providerPrefix = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers"
    $baseTags = [ordered]@{
        project = 'a365-gateway'
        environment = [string]$Config.environment
        managedBy = 'bicep'
        projectName = [string]$Config.projectName
        deploymentId = "$($Config.projectName)-$($Config.environment)"
        bootstrapOwnershipId = $canonicalOwnershipId
        bootstrapSourceFingerprint = $SourceFingerprint
    }
    $privateEndpointTags = [ordered]@{}
    foreach ($entry in $baseTags.GetEnumerator()) { $privateEndpointTags[$entry.Key] = $entry.Value }
    $privateEndpointTags.workload = 'interaction-content'

    $acrPrefix = "acr$($Config.projectName)$($Config.environment)"
    if ([string]$Foundation.acrName -cnotmatch "^$([regex]::Escape($acrPrefix))[a-z0-9]{6}$") {
        throw 'The inert boundary cannot derive the exact storage suffix from current foundation evidence.'
    }
    $uniqueSuffix = ([string]$Foundation.acrName).Substring($acrPrefix.Length)
    $storageName = "st$($Config.projectName)$($Config.environment)$uniqueSuffix"
    $apiName = "ca-gateway-api-$($Config.environment)"
    $workerName = "ca-gateway-worker-$($Config.environment)-v3"
    $actionGroupId = "$providerPrefix/Microsoft.Insights/actionGroups/ag-gateway-alerts"
    $appInsightsId = "$providerPrefix/Microsoft.Insights/components/ai-$($Config.projectName)-$($Config.environment)"
    $smartDetectorName = "Failure Anomalies - ai-$($Config.projectName)-$($Config.environment)"
    $smartDetectorId = "$providerPrefix/Microsoft.AlertsManagement/smartDetectorAlertRules/$smartDetectorName"
    $sharedVaultId = "$providerPrefix/Microsoft.KeyVault/vaults/kv-$($Config.projectName)-$($Config.environment)"
    $storageId = "$providerPrefix/Microsoft.Storage/storageAccounts/$storageName"
    $privateEndpointName = "pe-$storageName-blob"
    $privateEndpointId = "$providerPrefix/Microsoft.Network/privateEndpoints/$privateEndpointName"
    $privateDnsZoneId = "$providerPrefix/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    $privateDnsLinkName = "link-$($Config.projectName)-$($Config.environment)-storage"
    $privateDnsLinkId = "$privateDnsZoneId/virtualNetworkLinks/$privateDnsLinkName"
    $serviceBusId = "$providerPrefix/Microsoft.ServiceBus/namespaces/sb-$($Config.projectName)-$($Config.environment)"
    $sqlServerId = "$providerPrefix/Microsoft.Sql/servers/sql-$($Config.projectName)-$($Config.environment)"
    $gatewayDatabaseId = "$sqlServerId/databases/GatewayDb"
    $masterDatabaseId = "$sqlServerId/databases/master"
    $apiId = "$providerPrefix/Microsoft.App/containerApps/$apiName"
    $workerId = "$providerPrefix/Microsoft.App/containerApps/$workerName"
    $expectedAcrId = "$providerPrefix/Microsoft.ContainerRegistry/registries/$($Foundation.acrName)"
    $expectedQueueId = "$serviceBusId/queues/gateway-provisioning-v3"

    foreach ($binding in @(
        @([string]$Evidence.containerRegistryId, $expectedAcrId),
        @([string]$Evidence.sharedKeyVaultId, $sharedVaultId),
        @([string]$Evidence.storageAccountId, $storageId),
        @([string]$Evidence.storageBlobPrivateEndpointId, $privateEndpointId),
        @([string]$Evidence.storageBlobPrivateDnsZoneId, $privateDnsZoneId),
        @([string]$Evidence.serviceBusQueueId, $expectedQueueId)
    )) {
        if (-not ([string]$binding[0]).Equals([string]$binding[1], [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Succeeded inert deployment outputs drifted from the exact deterministic resource graph.'
        }
    }
    if ([string]$Evidence.sqlServerFqdn -cne "sql-$($Config.projectName)-$($Config.environment).database.windows.net" -or
        [string]$Evidence.serviceBusQueueName -cne 'gateway-provisioning-v3') {
        throw 'Succeeded inert deployment outputs drifted from the exact SQL and Service Bus contract.'
    }

    $descriptors = [Collections.Generic.List[object]]::new()
    foreach ($descriptor in @(
        [ordered]@{ id = $apiId; type = 'Microsoft.App/containerApps'; name = $apiName; apiVersion = '2024-03-01'; location = [string]$Config.location; tags = $baseTags; alreadyValidated = $true },
        [ordered]@{ id = $workerId; type = 'Microsoft.App/containerApps'; name = $workerName; apiVersion = '2025-01-01'; location = [string]$Config.location; tags = $baseTags; alreadyValidated = $true },
        [ordered]@{ id = $actionGroupId; type = 'Microsoft.Insights/actionGroups'; name = 'ag-gateway-alerts'; apiVersion = '2023-01-01'; location = 'global'; tags = $baseTags },
        [ordered]@{ id = $appInsightsId; type = 'Microsoft.Insights/components'; name = "ai-$($Config.projectName)-$($Config.environment)"; apiVersion = '2020-02-02'; location = [string]$Config.location; tags = $baseTags },
        [ordered]@{ id = $smartDetectorId; type = 'Microsoft.AlertsManagement/smartDetectorAlertRules'; name = $smartDetectorName; apiVersion = '2021-04-01'; location = 'global'; tags = $baseTags },
        [ordered]@{ id = $sharedVaultId; type = 'Microsoft.KeyVault/vaults'; name = "kv-$($Config.projectName)-$($Config.environment)"; apiVersion = '2023-07-01'; location = [string]$Config.location; tags = $baseTags },
        [ordered]@{ id = $privateDnsZoneId; type = 'Microsoft.Network/privateDnsZones'; name = 'privatelink.blob.core.windows.net'; apiVersion = '2020-06-01'; location = 'global'; tags = ([ordered]@{}) },
        [ordered]@{ id = $privateDnsLinkId; type = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'; name = $privateDnsLinkName; apiVersion = '2020-06-01'; location = 'global'; tags = ([ordered]@{}) },
        [ordered]@{ id = $privateEndpointId; type = 'Microsoft.Network/privateEndpoints'; name = $privateEndpointName; apiVersion = '2023-11-01'; location = [string]$Config.location; tags = $privateEndpointTags },
        [ordered]@{ id = $serviceBusId; type = 'Microsoft.ServiceBus/namespaces'; name = "sb-$($Config.projectName)-$($Config.environment)"; apiVersion = '2022-10-01-preview'; location = [string]$Config.location; tags = $baseTags },
        [ordered]@{ id = $sqlServerId; type = 'Microsoft.Sql/servers'; name = "sql-$($Config.projectName)-$($Config.environment)"; apiVersion = '2023-08-01-preview'; location = [string]$Config.location; tags = $baseTags },
        [ordered]@{ id = $gatewayDatabaseId; type = 'Microsoft.Sql/servers/databases'; name = 'GatewayDb'; apiVersion = '2023-08-01-preview'; location = [string]$Config.location; tags = $baseTags },
        [ordered]@{ id = $masterDatabaseId; type = 'Microsoft.Sql/servers/databases'; name = 'master'; apiVersion = '2023-08-01-preview'; location = [string]$Config.location; tags = ([ordered]@{}); providerTags = $true },
        [ordered]@{ id = $storageId; type = 'Microsoft.Storage/storageAccounts'; name = $storageName; apiVersion = '2023-05-01'; location = [string]$Config.location; tags = $baseTags }
    )) { $descriptors.Add($descriptor) }

    $metricScopes = [ordered]@{
        "alert-sql-connection-failed-$($Config.environment)" = $gatewayDatabaseId
        "alert-servicebus-server-errors-$($Config.environment)" = $serviceBusId
        "alert-keyvault-availability-drop-$($Config.environment)" = $sharedVaultId
        "alert-servicebus-queue-depth-high-$($Config.environment)" = $serviceBusId
        "alert-servicebus-deadletter-depth-$($Config.environment)" = $serviceBusId
    }
    foreach ($entry in $metricScopes.GetEnumerator()) {
        $descriptors.Add([ordered]@{
            id = "$providerPrefix/Microsoft.Insights/metricAlerts/$($entry.Key)"
            type = 'Microsoft.Insights/metricAlerts'; name = [string]$entry.Key; apiVersion = '2018-03-01'
            location = 'global'; tags = $baseTags; scopeId = [string]$entry.Value; relationship = 'MetricAlert'
        })
    }
    foreach ($name in @(
        "alert-api-server-errors-$($Config.environment)",
        "alert-api-auth-failures-$($Config.environment)",
        "alert-api-response-latency-high-$($Config.environment)",
        "alert-identity-mismatch-$($Config.environment)",
        "alert-provisioning-failed-$($Config.environment)"
    )) {
        $descriptors.Add([ordered]@{
            id = "$providerPrefix/Microsoft.Insights/scheduledQueryRules/$name"
            type = 'Microsoft.Insights/scheduledQueryRules'; name = $name; apiVersion = '2023-03-15-preview'
            location = [string]$Config.location; tags = $baseTags; scopeId = $appInsightsId; relationship = 'ScheduledQuery'
        })
    }

    $resourcesById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($descriptor in @($descriptors)) {
        $canonicalId = ConvertTo-GatewayCanonicalArmResourceId -ResourceId ([string]$descriptor.id) -Config $Config -Label 'Inert recovery resource'
        if (-not $resourcesById.TryAdd($canonicalId, $descriptor)) {
            throw 'The inert recovery graph contains a duplicate deterministic resource ID.'
        }
        if ([bool](Get-GatewayArmObjectProperty -Object $descriptor -Name 'alreadyValidated')) { continue }
        $resource = Get-GatewayInertBoundaryResource -ResourceId ([string]$descriptor.id) -ApiVersion ([string]$descriptor.apiVersion)
        Assert-GatewayInertBoundaryResourceEnvelope -Resource $resource -ExpectedId ([string]$descriptor.id) `
            -ExpectedType ([string]$descriptor.type) -ExpectedName ([string]$descriptor.name) `
            -ExpectedLocation ([string]$descriptor.location) -ExpectedTags $descriptor.tags `
            -TagsAreProviderGenerated:([bool](Get-GatewayArmObjectProperty -Object $descriptor -Name 'providerTags')) | Out-Null
        $descriptor['resource'] = $resource
    }

    $appInsights = $resourcesById[(ConvertTo-GatewayCanonicalArmResourceId -ResourceId $appInsightsId -Config $Config -Label 'Application Insights resource')].resource
    $expectedWorkspaceId = "$providerPrefix/Microsoft.OperationalInsights/workspaces/$($Foundation.logAnalyticsWorkspaceName)"
    if (-not ([string]$appInsights.properties.WorkspaceResourceId).Equals($expectedWorkspaceId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Application Insights is not bound to the exact source-owned Log Analytics workspace.'
    }
    foreach ($descriptor in @($descriptors | Where-Object {
        [string](Get-GatewayArmObjectProperty -Object $_ -Name 'relationship') -in @('MetricAlert', 'ScheduledQuery')
    })) {
        $resource = $descriptor.resource
        Assert-GatewayExactArmIdCollection -Items @($resource.properties.scopes | ForEach-Object { [ordered]@{ id = $_ } }) `
            -ExpectedIds @([string]$descriptor.scopeId) -PropertyName 'id' -Config $Config -Label 'Alert scope relationship' | Out-Null
        $actionIds = if ([string]$descriptor.relationship -ceq 'MetricAlert') {
            @($resource.properties.actions | ForEach-Object { [ordered]@{ id = $_.actionGroupId } })
        }
        else {
            @($resource.properties.actions.actionGroups | ForEach-Object { [ordered]@{ id = $_ } })
        }
        Assert-GatewayExactArmIdCollection -Items $actionIds -ExpectedIds @($actionGroupId) -PropertyName 'id' `
            -Config $Config -Label 'Alert action-group relationship' | Out-Null
    }

    $smartDetector = $resourcesById[(ConvertTo-GatewayCanonicalArmResourceId `
        -ResourceId $smartDetectorId -Config $Config -Label 'Failure Anomalies smart-detector rule')].resource
    $smartDetectorProperties = $smartDetector.properties
    if ([string]$smartDetectorProperties.description -cne 'Failure Anomalies for the A365 Gateway Application Insights resource.' -or
        [string]$smartDetectorProperties.state -cne 'Enabled' -or
        [string]$smartDetectorProperties.severity -cne 'Sev3' -or
        [string]$smartDetectorProperties.frequency -cne 'PT1M' -or
        [string]$smartDetectorProperties.detector.id -cne 'FailureAnomaliesDetector' -or
        -not [string]::IsNullOrEmpty([string]$smartDetectorProperties.actionGroups.customEmailSubject) -or
        -not [string]::IsNullOrEmpty([string]$smartDetectorProperties.actionGroups.customWebhookPayload)) {
        throw 'The Failure Anomalies smart-detector rule does not match the exact enabled detector contract.'
    }
    Assert-GatewayExactArmIdCollection `
        -Items @($smartDetectorProperties.scope | ForEach-Object { [ordered]@{ id = $_ } }) `
        -ExpectedIds @($appInsightsId) `
        -PropertyName 'id' `
        -Config $Config `
        -Label 'Failure Anomalies Application Insights scope' | Out-Null
    Assert-GatewayExactArmIdCollection `
        -Items @($smartDetectorProperties.actionGroups.groupIds | ForEach-Object { [ordered]@{ id = $_ } }) `
        -ExpectedIds @($actionGroupId) `
        -PropertyName 'id' `
        -Config $Config `
        -Label 'Failure Anomalies action-group binding' | Out-Null

    $dnsLink = $resourcesById[(ConvertTo-GatewayCanonicalArmResourceId -ResourceId $privateDnsLinkId -Config $Config -Label 'Private DNS link')].resource
    if ($dnsLink.properties.registrationEnabled -ne $false -or
        -not ([string]$dnsLink.properties.virtualNetwork.id).Equals([string]$Foundation.virtualNetworkId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Blob private DNS link is not exactly bound to the foundation virtual network.'
    }
    $privateEndpoint = $resourcesById[(ConvertTo-GatewayCanonicalArmResourceId -ResourceId $privateEndpointId -Config $Config -Label 'Storage private endpoint')].resource
    if (-not ([string]$privateEndpoint.properties.subnet.id).Equals([string]$Foundation.privateEndpointSubnetId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Storage private endpoint is not bound to the exact foundation subnet.'
    }
    $connections = @($privateEndpoint.properties.privateLinkServiceConnections)
    if ($connections.Count -ne 1 -or [string]$connections[0].name -cne "peconn-$storageName-blob" -or
        -not ([string]$connections[0].properties.privateLinkServiceId).Equals($storageId, [StringComparison]::OrdinalIgnoreCase) -or
        @($connections[0].properties.groupIds).Count -ne 1 -or [string]$connections[0].properties.groupIds[0] -cne 'blob') {
        throw 'The Storage private endpoint connection is missing, ambiguous, or outside the exact Storage blob relationship.'
    }
    $networkInterfaces = @($privateEndpoint.properties.networkInterfaces)
    if ($networkInterfaces.Count -ne 1) {
        throw 'The Storage private endpoint does not expose exactly one generated network interface.'
    }
    $nicId = ConvertTo-GatewayCanonicalArmResourceId -ResourceId ([string]$networkInterfaces[0].id) -Config $Config -Label 'Generated private-endpoint network interface'
    $nicPrefix = ("$providerPrefix/Microsoft.Network/networkInterfaces/$privateEndpointName.nic.").ToLowerInvariant()
    if (-not $nicId.StartsWith($nicPrefix, [StringComparison]::Ordinal)) {
        throw 'The generated network interface name is not reverse-bound to the exact Storage private endpoint.'
    }
    $nicGuidText = $nicId.Substring($nicPrefix.Length)
    $nicGuid = [guid]::Empty
    if (-not [guid]::TryParse($nicGuidText, [ref]$nicGuid) -or $nicGuid -eq [guid]::Empty -or
        $nicGuidText -cne $nicGuid.ToString('D')) {
        throw 'The generated private-endpoint network-interface suffix is not one canonical GUID.'
    }
    $nicName = "$privateEndpointName.nic.$nicGuidText"
    $nic = Get-GatewayInertBoundaryResource -ResourceId $nicId -ApiVersion '2023-11-01'
    Assert-GatewayInertBoundaryResourceEnvelope -Resource $nic -ExpectedId $nicId -ExpectedType 'Microsoft.Network/networkInterfaces' `
        -ExpectedName $nicName -ExpectedLocation ([string]$Config.location) -ExpectedTags ([ordered]@{}) -TagsAreProviderGenerated | Out-Null
    if (-not ([string]$nic.properties.privateEndpoint.id).Equals($privateEndpointId, [StringComparison]::OrdinalIgnoreCase) -or
        @($nic.properties.ipConfigurations).Count -ne 1 -or
        -not ([string]$nic.properties.ipConfigurations[0].properties.subnet.id).Equals([string]$Foundation.privateEndpointSubnetId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The generated network interface does not reverse-bind exactly to the private endpoint and foundation subnet.'
    }
    $nicDescriptor = [ordered]@{
        id = $nicId; type = 'Microsoft.Network/networkInterfaces'; name = $nicName
        apiVersion = '2023-11-01'; location = [string]$Config.location; tags = ([ordered]@{}); providerTags = $true
    }
    if (-not $resourcesById.TryAdd($nicId, $nicDescriptor)) {
        throw 'The generated network interface duplicates another inert recovery resource ID.'
    }
    $descriptors.Add($nicDescriptor)

    $dnsZoneGroupId = "$privateEndpointId/privateDnsZoneGroups/storageBlobDnsGroup"
    $dnsZoneGroup = Get-GatewayInertBoundaryResource -ResourceId $dnsZoneGroupId -ApiVersion '2023-11-01'
    Assert-GatewayInertBoundaryResourceEnvelope -Resource $dnsZoneGroup -ExpectedId $dnsZoneGroupId `
        -ExpectedType 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' `
        -ExpectedName 'storageBlobDnsGroup' -ExpectedLocation '' `
        -ExpectedTags ([ordered]@{}) -TagsAreProviderGenerated | Out-Null
    $dnsConfigs = @($dnsZoneGroup.properties.privateDnsZoneConfigs)
    if ($dnsConfigs.Count -ne 1 -or [string]$dnsConfigs[0].name -cne 'blob' -or
        -not ([string]$dnsConfigs[0].properties.privateDnsZoneId).Equals($privateDnsZoneId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Storage private endpoint DNS group is not exactly bound to the Blob private DNS zone.'
    }

    if ($descriptors.Count -ne 25 -or $resourcesById.Count -ne 25) {
        throw 'The inert recovery graph is not the exact reviewed 25-resource What-If Ignore boundary.'
    }
    foreach ($typeGroup in @($descriptors | Group-Object -Property {
        [string](Get-GatewayArmObjectProperty -Object $_ -Name 'type')
    })) {
        $expectedTypeIds = @($typeGroup.Group | ForEach-Object {
            ConvertTo-GatewayCanonicalArmResourceId -ResourceId ([string]$_.id) -Config $Config -Label 'Inert type inventory'
        })
        if ($additionalInventory.ContainsKey([string]$typeGroup.Name)) {
            $expectedTypeIds += @($additionalInventory[[string]$typeGroup.Name])
        }
        $expectedTypeIds = @($expectedTypeIds | Sort-Object -CaseSensitive)
        if (@($expectedTypeIds | Sort-Object -Unique -CaseSensitive).Count -ne $expectedTypeIds.Count) {
            throw 'The inert recovery inventory extension overlaps the exact inert resource graph.'
        }
        $inventory = @(Get-GatewayInertBoundaryTypeInventory -Config $Config -ResourceType ([string]$typeGroup.Name))
        $seenInventoryIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $actualTypeIds = @()
        foreach ($item in $inventory) {
            $inventoryId = ConvertTo-GatewayCanonicalArmResourceId `
                -ResourceId ([string](Get-GatewayArmObjectProperty -Object $item -Name 'id')) `
                -Config $Config -Label 'Inert type inventory'
            if (-not $seenInventoryIds.Add($inventoryId)) {
                throw 'The inert type inventory contains a duplicate resource ID.'
            }
            $actualTypeIds += $inventoryId
        }
        $actualTypeIds = @($actualTypeIds | Sort-Object -CaseSensitive)
        if ($actualTypeIds.Count -ne $expectedTypeIds.Count -or ($actualTypeIds -join '|') -cne ($expectedTypeIds -join '|')) {
            throw 'The inert type inventory contains a missing, extra, out-of-boundary, or unowned resource.'
        }
    }

    $resourceIds = @($resourcesById.Keys | Sort-Object -CaseSensitive)
    $boundary = [ordered]@{
        schemaVersion = 2
        phase = 'InertIdentityDeployment'
        deploymentName = $deploymentName
        deploymentOwnershipId = $canonicalOwnershipId
        sourceFingerprint = $SourceFingerprint
        resourceIds = $resourceIds
        generatedNicBinding = [ordered]@{
            nicId = $nicId
            privateEndpointId = $privateEndpointId.ToLowerInvariant()
            subnetId = ([string]$Foundation.privateEndpointSubnetId).ToLowerInvariant()
        }
        masterDatabaseBinding = [ordered]@{
            databaseId = $masterDatabaseId.ToLowerInvariant()
            sqlServerId = $sqlServerId.ToLowerInvariant()
        }
    }
    $boundary.boundaryFingerprint = Get-BootstrapObjectFingerprint -InputObject $boundary
    return $boundary
}

function Get-GatewayInertWhatIfRecoveryBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$ApiImage,
        [Parameter(Mandatory)][string]$WorkerImage,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [AllowNull()][System.Collections.IDictionary]$AdditionalTypeInventoryResourceIds,
        [Parameter()][string]$ExecutionSourceFingerprint = ''
    )
    $evidence = Deploy-GatewayCore -Config $Config -Foundation $Foundation -Identity $Identity `
        -ApiImage $ApiImage -WorkerImage $WorkerImage -WorkerPrincipalId '' -ManagerApplicationIds @() `
        -DeploymentOwnershipId $DeploymentOwnershipId -SourceFingerprint $SourceFingerprint `
        -ExecutionSourceFingerprint $ExecutionSourceFingerprint `
        -Initial -SucceededRecoveryOnly
    $boundary = New-GatewayInertWhatIfRecoveryBoundary -Config $Config -Foundation $Foundation `
        -Evidence $evidence -ApiImage $ApiImage -WorkerImage $WorkerImage `
        -DeploymentOwnershipId $DeploymentOwnershipId -SourceFingerprint $SourceFingerprint `
        -AdditionalTypeInventoryResourceIds $AdditionalTypeInventoryResourceIds
    return [ordered]@{ evidence = $evidence; boundary = $boundary }
}

function Get-GatewayAcrBuildSourceFiles {
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $projectRoots = @(
        'Gateway.Api', 'Gateway.Application', 'Gateway.Domain', 'Gateway.Contracts',
        'Gateway.Infrastructure', 'Gateway.Agent365', 'Gateway.Purview',
        'Gateway.ContentSafety', 'Gateway.Observability', 'Gateway.Provisioning.Worker',
        'Gateway.AdminUi'
    )
    $toolRoots = @('Gateway.DatabaseMigrator')
    $sqlRoot = 'infrastructure/sql'
    $rootFiles = @('global.json', 'nuget.config', 'Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props')
    $candidatePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git -and (Test-Path -LiteralPath (Join-Path $RepositoryRoot '.git'))) {
        $sourceArguments = @($projectRoots | ForEach-Object { "src/$_" }) +
            @($toolRoots | ForEach-Object { "tools/$_" }) + @($sqlRoot) + $rootFiles
        foreach ($mode in @('tracked', 'untracked')) {
            $arguments = if ($mode -eq 'tracked') {
                @('-C', $RepositoryRoot, 'ls-files', '--') + $sourceArguments
            }
            else {
                @('-C', $RepositoryRoot, 'ls-files', '--others', '--exclude-standard', '--') + $sourceArguments
            }
            foreach ($path in @(& $git.Source @arguments 2>$null)) {
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$path)) {
                    $null = $candidatePaths.Add(([string]$path).Replace('\', '/'))
                }
            }
        }
    }
    if ($candidatePaths.Count -eq 0) {
        foreach ($rootFile in $rootFiles) {
            if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $rootFile) -PathType Leaf) { $null = $candidatePaths.Add($rootFile) }
        }
        foreach ($projectRoot in $projectRoots) {
            $fullProjectRoot = Join-Path $RepositoryRoot "src/$projectRoot"
            foreach ($file in @(Get-ChildItem -LiteralPath $fullProjectRoot -File -Recurse -Force)) {
                $null = $candidatePaths.Add([IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName).Replace('\', '/'))
            }
        }
        foreach ($toolRoot in $toolRoots) {
            $fullToolRoot = Join-Path $RepositoryRoot "tools/$toolRoot"
            foreach ($file in @(Get-ChildItem -LiteralPath $fullToolRoot -File -Recurse -Force)) {
                $null = $candidatePaths.Add([IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName).Replace('\', '/'))
            }
        }
        $fullSqlRoot = Join-Path $RepositoryRoot $sqlRoot
        foreach ($file in @(Get-ChildItem -LiteralPath $fullSqlRoot -File -Recurse -Force)) {
            $null = $candidatePaths.Add([IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName).Replace('\', '/'))
        }
    }

    $allowedExtensions = @('.cs', '.csproj', '.razor', '.css', '.js', '.ps1', '.png', '.svg', '.ico', '.resx', '.woff', '.woff2', '.ttf', '.eot', '.map')
    $files = @($candidatePaths | Where-Object {
        if (Test-BootstrapSourcePathIsSensitive -RelativePath ([string]$_)) { return $false }
        if ($_ -in $rootFiles) { return $true }
        if ($_ -cmatch '^infrastructure/sql/(.+\.sql)$') { return $true }
        if ($_ -cmatch '^src/([^/]+)/(.+)$') {
            if ($Matches[1] -notin $projectRoots) { return $false }
        }
        elseif ($_ -cmatch '^tools/([^/]+)/(.+)$') {
            if ($Matches[1] -notin $toolRoots) { return $false }
        }
        else { return $false }
        $name = [IO.Path]::GetFileName($_)
        if ($name -eq 'Dockerfile') { return $true }
        if ($name -eq 'appsettings.json') { return $true }
        return [IO.Path]::GetExtension($name).ToLowerInvariant() -in $allowedExtensions
    } | Sort-Object -Unique)

    foreach ($required in @(
        'global.json', 'nuget.config',
        'src/Gateway.Api/Dockerfile', 'src/Gateway.Api/Gateway.Api.csproj',
        'src/Gateway.Provisioning.Worker/Dockerfile', 'src/Gateway.Provisioning.Worker/Gateway.Provisioning.Worker.csproj',
        'src/Gateway.AdminUi/Dockerfile', 'src/Gateway.AdminUi/Gateway.AdminUi.csproj',
        'tools/Gateway.DatabaseMigrator/Dockerfile', 'tools/Gateway.DatabaseMigrator/Gateway.DatabaseMigrator.csproj'
    )) {
        if ($files -notcontains $required) { throw "Allowlisted ACR build input '$required' is absent from the repository source set." }
    }
    if (@($files | Where-Object { $_ -cmatch '^infrastructure/sql/[^/]+\.sql$' }).Count -eq 0) {
        throw "Allowlisted ACR build input '$sqlRoot' contains no reviewed SQL migration."
    }
    return @($files)
}

function Assert-GatewayCredentialFreeNuGetConfig {
    param([Parameter(Mandatory)][string]$Path)

    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $document = [Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    try {
        $reader = [Xml.XmlReader]::Create($Path, $settings)
        try { $document.Load($reader) } finally { $reader.Dispose() }
        $root = $document.DocumentElement
        if (-not $root -or $root.Name -cne 'configuration' -or $root.Attributes.Count -ne 0) { throw 'invalid-root' }
        $sections = @($root.ChildNodes | Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element })
        if ($sections.Count -gt 1 -or ($sections.Count -eq 1 -and $sections[0].Name -cne 'packageSources')) {
            throw 'unreviewed-section'
        }
        if ($sections.Count -eq 0) { return $true }
        if ($sections[0].Attributes.Count -ne 0) { throw 'package-sources-attributes' }

        $sourceKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $clearCount = 0
        foreach ($node in @($sections[0].ChildNodes | Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element })) {
            if ($node.Name -ceq 'clear') {
                $clearCount++
                if ($clearCount -ne 1 -or $node.Attributes.Count -ne 0 -or -not [string]::IsNullOrWhiteSpace($node.InnerText)) {
                    throw 'invalid-clear'
                }
                continue
            }
            if ($node.Name -cne 'add') { throw 'unreviewed-source-node' }
            $attributeNames = @($node.Attributes | ForEach-Object { [string]$_.Name })
            if (@($attributeNames | Where-Object { $_ -notin @('key', 'value', 'protocolVersion') }).Count -ne 0 -or
                @($attributeNames | Sort-Object -Unique).Count -ne $attributeNames.Count -or
                -not [string]::IsNullOrWhiteSpace($node.InnerText)) {
                throw 'unreviewed-source-attribute'
            }
            $key = [string]$node.GetAttribute('key')
            $value = [string]$node.GetAttribute('value')
            $protocolVersion = [string]$node.GetAttribute('protocolVersion')
            if ($key -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or
                -not $sourceKeys.Add($key) -or
                (-not [string]::IsNullOrWhiteSpace($protocolVersion) -and $protocolVersion -cne '3')) {
                throw 'invalid-source-metadata'
            }
            $uri = $null
            if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -cne 'https' -or
                (-not $uri.IsDefaultPort -and $uri.Port -ne 443) -or
                -not [string]::IsNullOrEmpty($uri.UserInfo) -or
                -not [string]::IsNullOrEmpty($uri.Query) -or
                -not [string]::IsNullOrEmpty($uri.Fragment)) {
                throw 'unsafe-source-uri'
            }
            $allowedSource =
                ($uri.Host.Equals('api.nuget.org', [StringComparison]::OrdinalIgnoreCase) -and $uri.AbsolutePath -ceq '/v3/index.json') -or
                ($uri.Host.Equals('packagefeedproxy.microsoft.io', [StringComparison]::OrdinalIgnoreCase) -and $uri.AbsolutePath -ceq '/nuget/v3/index.json')
            if (-not $allowedSource) { throw 'unreviewed-source-host' }
        }
        return $true
    }
    catch {
        throw 'The ACR build refuses NuGet configuration outside the exact credential-free HTTPS source allowlist. No configuration value was rendered.'
    }
}

function New-GatewayAcrBuildContext {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $context = [IO.Directory]::CreateTempSubdirectory('a365gw-acr-build-').FullName
    try {
        Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Image-build source fingerprint'
        $manifest = @(Get-BootstrapSourceManifest -Root $RepositoryRoot)
        if ((Get-BootstrapObjectFingerprint -InputObject $manifest) -cne $SourceFingerprint) {
            throw 'The image-build source does not match the accepted content-addressed snapshot.'
        }
        $expectedHashes = @{}
        foreach ($entry in $manifest) { $expectedHashes[[string]$entry.path] = [string]$entry.sha256 }
        foreach ($relativePath in @(Get-GatewayAcrBuildSourceFiles -RepositoryRoot $RepositoryRoot)) {
            if (-not $expectedHashes.ContainsKey($relativePath)) {
                throw "Allowlisted ACR build input '$relativePath' is outside the accepted source manifest."
            }
            Assert-BootstrapSourcePathIsRegular -Root $RepositoryRoot -RelativePath $relativePath | Out-Null
            $source = Join-Path $RepositoryRoot $relativePath
            $destination = Join-Path $context $relativePath
            [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedHashes[$relativePath]) {
                throw "Allowlisted ACR build input '$relativePath' changed after plan acceptance."
            }
        }
        $nugetConfig = Join-Path $context 'nuget.config'
        Assert-GatewayCredentialFreeNuGetConfig -Path $nugetConfig | Out-Null
        return $context
    }
    catch {
        if (Test-Path -LiteralPath $context) { Remove-Item -LiteralPath $context -Recurse -Force }
        throw
    }
}

function Invoke-GatewayAcrExactStringArray {
    param(
        [Parameter(Mandatory)][string]$OperationLabel,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$ExpectedValue
    )

    $raw = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList ($Arguments + @('--output', 'json', '--only-show-errors'))
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "$OperationLabel returned no JSON result."
    }

    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($raw)
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Array) {
            throw 'root-not-array'
        }
        $values = [Collections.Generic.List[string]]::new()
        foreach ($element in $document.RootElement.EnumerateArray()) {
            if ($element.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'item-not-string' }
            $value = $element.GetString()
            if ($value -cne $ExpectedValue) { throw 'unexpected-value' }
            $values.Add($value)
        }
        if ($values.Count -gt 1) { throw 'duplicate-value' }
        return @($values)
    }
    catch {
        throw "$OperationLabel returned a malformed or non-exact discovery result."
    }
    finally {
        if ($document) { $document.Dispose() }
    }
}

function Get-GatewayAcrExactTagDigest {
    param(
        [Parameter(Mandatory)][string]$Registry,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag
    )

    if ($Registry -cnotmatch '^[a-z0-9]{5,50}$' -or
        $Repository -cnotmatch '^[a-z0-9]+(?:[._/-][a-z0-9]+)*$' -or
        $Tag -cnotmatch '^bootstrap-[0-9a-f]{32}-[0-9a-f]{32}-[0-9a-f]{32}$') {
        throw 'The exact ACR discovery target is malformed.'
    }

    $repositories = @(Invoke-GatewayAcrExactStringArray `
        -OperationLabel 'ACR repository discovery' `
        -ExpectedValue $Repository `
        -Arguments @('acr', 'repository', 'list', '--name', $Registry, '--query', "[?@=='$Repository']"))
    if ($repositories.Count -eq 0) { return $null }

    $tags = @(Invoke-GatewayAcrExactStringArray `
        -OperationLabel 'ACR deterministic-tag discovery' `
        -ExpectedValue $Tag `
        -Arguments @('acr', 'repository', 'show-tags', '--name', $Registry, '--repository', $Repository, '--query', "[?@=='$Tag']"))
    if ($tags.Count -eq 0) { return $null }

    $digest = Invoke-AzTsv -Arguments @(
        'acr', 'manifest', 'show-metadata', '--registry', $Registry,
        '--name', "${Repository}:$Tag", '--query', 'digest')
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'ACR deterministic-tag discovery did not resolve one canonical immutable digest.'
    }
    return [pscustomobject]@{ tag = $Tag; digest = $digest }
}

function Get-GatewayAcrExactImageRuns {
    param(
        [Parameter(Mandatory)][string]$Registry,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag
    )

    if ($Registry -cnotmatch '^[a-z0-9]{5,50}$' -or
        $Repository -cnotmatch '^[a-z0-9]+(?:[._/-][a-z0-9]+)*$' -or
        $Tag -cnotmatch '^bootstrap-[0-9a-f]{32}-[0-9a-f]{32}-[0-9a-f]{32}$') {
        throw 'The exact ACR run-discovery target is malformed.'
    }
    # `az acr task list-runs --image` resolves the tag through the repository
    # manifest first, so it cannot discover a queued/running quick build whose
    # output manifest does not exist yet. Scan a bounded registry-wide projection
    # and select only the run carrying this exact unique intent tag.
    $raw = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @(
        'acr', 'task', 'list-runs', '--registry', $Registry,
        '--top', '101',
        '--query', '[].{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}}',
        '--output', 'json', '--only-show-errors'
    )
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'ACR exact image-run discovery returned no JSON array.'
    }
    try {
        $runs = ConvertFrom-Json -InputObject $raw -Depth 30 -NoEnumerate -ErrorAction Stop
    }
    catch {
        throw 'ACR exact image-run discovery returned malformed JSON.'
    }
    if ($runs -isnot [System.Array] -or $runs.Count -gt 101) {
        throw 'ACR exact image-run discovery was non-array or exceeded its bounded result contract.'
    }
    if ($runs.Count -eq 101) {
        throw 'ACR exact image-run discovery reached its truncation sentinel; absence and uniqueness were not proven.'
    }
    $matchingRuns = @()
    foreach ($run in @($runs)) {
        if ($run -isnot [pscustomobject]) {
            throw 'ACR exact image-run discovery returned a malformed run contract.'
        }
        $runPropertyNames = @($run.PSObject.Properties | ForEach-Object { [string]$_.Name })
        if ($runPropertyNames.Count -ne 4 -or
            @(@('runId', 'status', 'runType', 'outputImages') |
                    Where-Object { $runPropertyNames -cnotcontains $_ }).Count -ne 0 -or
            [string]$run.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$' -or
            @('QuickBuild', 'QuickRun', 'AutoBuild', 'AutoRun') -cnotcontains [string]$run.runType -or
            @('Queued', 'Started', 'Running', 'Succeeded', 'Failed', 'Canceled', 'Error', 'Timeout') -cnotcontains [string]$run.status) {
            throw 'ACR exact image-run discovery returned a malformed run contract.'
        }
        if ($null -eq $run.outputImages -or $run.outputImages -isnot [System.Array]) {
            throw 'ACR exact image-run discovery returned a malformed run contract.'
        }
        $outputImages = @($run.outputImages)
        foreach ($outputImage in $outputImages) {
            if ($outputImage -isnot [pscustomobject]) {
                throw 'ACR exact image-run discovery returned a malformed output-image contract.'
            }
            $imagePropertyNames = @($outputImage.PSObject.Properties | ForEach-Object { [string]$_.Name })
            if ($imagePropertyNames.Count -ne 3 -or
                @(@('repository', 'tag', 'digest') |
                        Where-Object { $imagePropertyNames -cnotcontains $_ }).Count -ne 0 -or
                [string]$outputImage.repository -cnotmatch '^[a-z0-9]+(?:[._/-][a-z0-9]+)*$' -or
                [string]$outputImage.tag -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$' -or
                (-not [string]::IsNullOrWhiteSpace([string]$outputImage.digest) -and
                    [string]$outputImage.digest -cnotmatch '^sha256:[0-9a-f]{64}$')) {
                throw 'ACR exact image-run discovery returned a malformed output-image contract.'
            }
        }

        $matchingOutputs = @($outputImages | Where-Object {
                [string]$_.repository -ceq $Repository -and [string]$_.tag -ceq $Tag
            })
        if ($matchingOutputs.Count -eq 0) { continue }
        if ($matchingOutputs.Count -ne 1 -or $outputImages.Count -ne 1) {
            throw 'An ACR run carrying the exact intent tag reported an ambiguous output-image contract.'
        }
        if ([string]$run.runType -cne 'QuickRun') {
            throw 'ACR exact image-run discovery returned a malformed run contract.'
        }
        if ([string]$run.status -ceq 'Succeeded') {
            if ([string]$matchingOutputs[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
                throw 'A succeeded ACR run did not report the one exact intended output image.'
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$matchingOutputs[0].digest) -and
            [string]$matchingOutputs[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
            throw 'A non-succeeded ACR run reported a mismatched output image contract.'
        }
        $matchingRuns += $run
    }
    if ($matchingRuns.Count -gt 1) {
        throw 'ACR exact image-run discovery found more than one run for the unique intent tag.'
    }
    return @($matchingRuns)
}

function Get-GatewayAcrExactRunById {
    param(
        [Parameter(Mandatory)][string]$Registry,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$RunId
    )

    if ($Registry -cnotmatch '^[a-z0-9]{5,50}$' -or
        $Repository -cnotmatch '^[a-z0-9]+(?:[._/-][a-z0-9]+)*$' -or
        $Tag -cnotmatch '^bootstrap-[0-9a-f]{32}-[0-9a-f]{32}-[0-9a-f]{32}$' -or
        $RunId -cnotmatch '^[A-Za-z0-9-]{1,64}$') {
        throw 'The exact ACR run readback target is malformed.'
    }
    $raw = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @(
        'acr', 'task', 'show-run', '--registry', $Registry, '--run-id', $RunId,
        '--query', '{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}}',
        '--output', 'json', '--only-show-errors'
    )
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'ACR exact run readback returned no JSON object.'
    }
    try {
        $run = ConvertFrom-Json -InputObject $raw -Depth 30 -NoEnumerate -ErrorAction Stop
    }
    catch {
        throw 'ACR exact run readback returned malformed JSON.'
    }
    if ($run -isnot [pscustomobject]) {
        throw 'ACR exact run readback returned a different or malformed run.'
    }
    $propertyNames = @($run.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($propertyNames.Count -ne 4 -or
        @(@('runId', 'status', 'runType', 'outputImages') |
                Where-Object { $propertyNames -cnotcontains $_ }).Count -ne 0 -or
        [string]$run.runId -cne $RunId) {
        throw 'ACR exact run readback returned a different or malformed run.'
    }
    if ([string]$run.runType -cne 'QuickRun' -or
        @('Queued', 'Started', 'Running', 'Succeeded', 'Failed', 'Canceled', 'Error', 'Timeout') -cnotcontains [string]$run.status) {
        throw 'ACR exact run readback returned a malformed run contract.'
    }
    $outputImages = @($run.outputImages)
    if ([string]$run.status -ceq 'Succeeded') {
        if ($outputImages.Count -ne 1 -or
            [string]$outputImages[0].repository -cne $Repository -or
            [string]$outputImages[0].tag -cne $Tag -or
            [string]$outputImages[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
            throw 'A succeeded ACR run did not report the one exact intended output image.'
        }
    }
    elseif ($outputImages.Count -gt 1 -or ($outputImages.Count -eq 1 -and (
        [string]$outputImages[0].repository -cne $Repository -or
        [string]$outputImages[0].tag -cne $Tag -or
        (-not [string]::IsNullOrWhiteSpace([string]$outputImages[0].digest) -and
            [string]$outputImages[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$')))) {
        throw 'A non-succeeded ACR run reported a mismatched output image contract.'
    }
    return $run
}

function Assert-GatewayAcrCompletedBuildContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$Run,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag
    )

    if ($Run -isnot [pscustomobject]) {
        throw 'The submitted ACR build did not return one exact successful QuickRun contract.'
    }
    $runPropertyNames = @($Run.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($runPropertyNames.Count -ne 4 -or
        @(@('runId', 'status', 'runType', 'outputImages') |
                Where-Object { $runPropertyNames -cnotcontains $_ }).Count -ne 0 -or
        [string]$Run.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$' -or
        [string]$Run.status -cne 'Succeeded' -or
        [string]$Run.runType -cne 'QuickRun' -or
        $null -eq $Run.outputImages -or
        $Run.outputImages -isnot [System.Array]) {
        throw 'The submitted ACR build did not return one exact successful QuickRun contract.'
    }
    $outputImages = @($Run.outputImages)
    if ($outputImages.Count -ne 1 -or $outputImages[0] -isnot [pscustomobject]) {
        throw 'The submitted ACR build did not return one exact successful QuickRun contract.'
    }
    $imagePropertyNames = @($outputImages[0].PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($imagePropertyNames.Count -ne 3 -or
        @(@('repository', 'tag', 'digest') |
                Where-Object { $imagePropertyNames -cnotcontains $_ }).Count -ne 0 -or
        [string]$outputImages[0].repository -cne $Repository -or
        [string]$outputImages[0].tag -cne $Tag -or
        [string]$outputImages[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'The submitted ACR build did not return one exact successful QuickRun contract.'
    }
    return $Run
}

function Build-GatewayImages {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AcrLoginServer,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter()][AllowNull()]$RecoveredEvidence,
        [Parameter(Mandatory)][scriptblock]$Checkpoint
    )
    $root = Get-BootstrapExecutionSourceRoot
    $registry = $AcrLoginServer.Split('.')[0]
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Image-build source fingerprint'
    if ((Get-BootstrapSourceFingerprint -Root $root) -cne $SourceFingerprint) {
        throw 'The image-build source no longer matches the accepted content-addressed snapshot.'
    }
    $definitions = [ordered]@{
        api = @{ repository = 'gateway-api'; dockerfile = 'src/Gateway.Api/Dockerfile' }
        worker = @{ repository = 'gateway-worker'; dockerfile = 'src/Gateway.Provisioning.Worker/Dockerfile' }
        adminUi = @{ repository = 'gateway-admin'; dockerfile = 'src/Gateway.AdminUi/Dockerfile' }
        databaseMigrator = @{ repository = 'gateway-db-migrator'; dockerfile = 'tools/Gateway.DatabaseMigrator/Dockerfile' }
    }
    $result = [ordered]@{
        schemaVersion = 3
        registry = $registry
        sourceFingerprint = $SourceFingerprint
        deploymentOwnershipId = $DeploymentOwnershipId
        provenance = 'BootstrapPreMutationIntentV3'
        buildIntents = [ordered]@{}
        checkpointedComponents = @()
    }
    if ($RecoveredEvidence) {
        if ([int]$RecoveredEvidence.schemaVersion -ne 3 -or
            [string]$RecoveredEvidence.registry -cne $registry -or
            [string]$RecoveredEvidence.sourceFingerprint -cne $SourceFingerprint -or
            [string]$RecoveredEvidence.deploymentOwnershipId -cne $DeploymentOwnershipId -or
            [string]$RecoveredEvidence.provenance -cne 'BootstrapPreMutationIntentV3' -or
            $RecoveredEvidence.buildIntents -isnot [System.Collections.IDictionary]) {
            throw 'Partial image-build evidence belongs to a different registry, state, or accepted source.'
        }
        $recoveredComponents = @($RecoveredEvidence.checkpointedComponents | ForEach-Object { [string]$_ })
        $uniqueRecoveredComponents = @($recoveredComponents | Sort-Object -Unique)
        if ($recoveredComponents.Count -ne $uniqueRecoveredComponents.Count -or
            @($uniqueRecoveredComponents | Where-Object { $_ -notin @('api', 'worker', 'adminUi', 'databaseMigrator') }).Count -ne 0) {
            throw 'Partial image-build evidence contains an invalid component checkpoint set.'
        }
        $result.checkpointedComponents = @($uniqueRecoveredComponents)
        $recoveredIntentComponents = @($RecoveredEvidence.buildIntents.Keys | ForEach-Object { [string]$_ })
        $uniqueIntentComponents = @($recoveredIntentComponents | Sort-Object -Unique)
        if ($recoveredIntentComponents.Count -ne $uniqueIntentComponents.Count -or
            @($uniqueIntentComponents | Where-Object { $_ -notin @('api', 'worker', 'adminUi', 'databaseMigrator') }).Count -ne 0) {
            throw 'Partial image-build evidence contains an invalid pre-mutation intent set.'
        }
        foreach ($component in $uniqueIntentComponents) {
            $definition = $definitions[$component]
            $intent = $RecoveredEvidence.buildIntents[$component]
            $canonicalIntentId = ([guid][string]$intent.intentId).ToString('D')
            $expectedTag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $DeploymentOwnershipId `
                -SourceFingerprint $SourceFingerprint `
                -IntentId $canonicalIntentId
            if ([string]$intent.component -cne $component -or
                [string]$intent.repository -cne [string]$definition.repository -or
                [string]$intent.intentId -cne $canonicalIntentId -or
                [string]$intent.tag -cne $expectedTag -or
                [string]$intent.state -notin @('IntentRecorded', 'RunQueued', 'DigestCheckpointed')) {
                throw 'Partial image-build evidence contains a malformed or mismatched pre-mutation intent.'
            }
            $copiedIntent = [ordered]@{
                component = $component
                repository = [string]$definition.repository
                intentId = $canonicalIntentId
                tag = $expectedTag
                state = [string]$intent.state
            }
            if ([string]$intent.state -in @('RunQueued', 'DigestCheckpointed')) {
                if ([string]$intent.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$') {
                    throw 'A submitted image-build intent has no canonical ACR run identifier.'
                }
                $copiedIntent.runId = [string]$intent.runId
            }
            if ([string]$intent.state -ceq 'DigestCheckpointed') {
                $digest = [string]$intent.digest
                $image = "$AcrLoginServer/$($definition.repository)@$digest"
                if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
                    [string]$intent.image -cne $image -or
                    [string]$RecoveredEvidence["${component}Digest"] -cne $digest -or
                    [string]$RecoveredEvidence[$component] -cne $image -or
                    $component -notin $uniqueRecoveredComponents) {
                    throw 'A completed image-build intent has incomplete or mismatched digest evidence.'
                }
                $copiedIntent.digest = $digest
                $copiedIntent.image = $image
                $result[$component] = $image
                $result["${component}Digest"] = $digest
            }
            elseif ($component -in $uniqueRecoveredComponents -or
                $RecoveredEvidence.Contains($component) -or $RecoveredEvidence.Contains("${component}Digest")) {
                throw 'An uncompleted image-build intent cannot carry completed image evidence.'
            }
            $result.buildIntents[$component] = $copiedIntent
        }
        if (@($uniqueRecoveredComponents | Where-Object { $_ -notin $uniqueIntentComponents }).Count -ne 0) {
            throw 'A completed image checkpoint has no matching durable pre-mutation intent.'
        }
    }
    $buildContext = $null
    try {
        foreach ($entry in $definitions.GetEnumerator()) {
            $component = [string]$entry.Key
            $repository = [string]$entry.Value.repository
            $intent = if ($result.buildIntents.Contains($component)) { $result.buildIntents[$component] } else { $null }
            $intentCreatedThisInvocation = $false
            if (-not $intent) {
                $intentId = [guid]::NewGuid().ToString('D')
                $intentTag = Get-BootstrapImageBuildIntentTag `
                    -DeploymentOwnershipId $DeploymentOwnershipId `
                    -SourceFingerprint $SourceFingerprint `
                    -IntentId $intentId
                $preexisting = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $intentTag
                $preexistingRuns = @(Get-GatewayAcrExactImageRuns -Registry $registry -Repository $repository -Tag $intentTag)
                if ($preexisting -or $preexistingRuns.Count -ne 0) {
                    throw 'A freshly generated image-build intent tag already exists; refusing to claim or overwrite it.'
                }
                $intent = [ordered]@{
                    component = $component
                    repository = $repository
                    intentId = $intentId
                    tag = $intentTag
                    state = 'IntentRecorded'
                }
                $result.buildIntents[$component] = $intent
                # This checkpoint is deliberately before the first external build mutation.
                & $Checkpoint $result
                $intentCreatedThisInvocation = $true
            }

            $tag = [string]$intent.tag
            $imageTag = "${repository}:$tag"
            if ([string]$intent.state -ceq 'DigestCheckpointed') {
                $discovered = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag
                $expectedDigest = [string]$intent.digest
                $expectedImage = "$AcrLoginServer/$repository@$expectedDigest"
                if (-not $discovered -or [string]$discovered.digest -cne $expectedDigest -or
                    [string]$intent.image -cne $expectedImage -or
                    [string]$result[$component] -cne $expectedImage) {
                    throw 'A checkpointed image no longer matches its exact intent tag and immutable digest.'
                }
                continue
            }

            if ([string]$intent.state -ceq 'IntentRecorded') {
                $runs = @()
                for ($discoveryAttempt = 1; $discoveryAttempt -le 6 -and $runs.Count -eq 0; $discoveryAttempt++) {
                    $runs = @(Get-GatewayAcrExactImageRuns -Registry $registry -Repository $repository -Tag $tag)
                    if ($runs.Count -eq 0 -and -not $intentCreatedThisInvocation -and $discoveryAttempt -lt 6) {
                        Start-Sleep -Seconds 2
                    }
                    elseif ($intentCreatedThisInvocation) { break }
                }

                if ($runs.Count -eq 0) {
                    if (-not $intentCreatedThisInvocation) {
                        throw 'A recovered image-build intent has neither an exact ACR run nor a digest. Submission outcome is ambiguous, so automatic resubmission is forbidden.'
                    }
                    if (-not $buildContext) {
                        $buildContext = New-GatewayAcrBuildContext -RepositoryRoot $root -SourceFingerprint $SourceFingerprint
                    }
                    # Azure CLI deliberately discards command output for
                    # supports_no_wait. `--no-logs` instead schedules once, polls
                    # that returned run ID to success without streaming build
                    # logs, and returns the final projected run on stdout.
                    $completedRun = Invoke-AzJson -CaptureStdoutOnly -Arguments @(
                        'acr', 'build', '--registry', $registry, '--image', $imageTag,
                        '--file', [string]$entry.Value.dockerfile,
                        $buildContext, '--no-logs',
                        '--query', '{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}}')
                    $completedRun = Assert-GatewayAcrCompletedBuildContract `
                        -Run $completedRun `
                        -Repository $repository `
                        -Tag $tag
                    $intent.runId = [string]$completedRun.runId
                }
                else {
                    $intent.runId = [string]$runs[0].runId
                }
                $intent.state = 'RunQueued'
                & $Checkpoint $result
            }

            $terminalRun = $null
            for ($attempt = 1; $attempt -le 30; $attempt++) {
                $currentRun = Get-GatewayAcrExactRunById `
                    -Registry $registry `
                    -Repository $repository `
                    -Tag $tag `
                    -RunId ([string]$intent.runId)
                if ([string]$currentRun.status -ceq 'Succeeded') { $terminalRun = $currentRun; break }
                if ([string]$currentRun.status -in @('Failed', 'Canceled', 'Error', 'Timeout')) {
                    throw 'The exact ACR build reached a terminal failure. Automatic resubmission is forbidden; review the run and start a newly accepted plan.'
                }
                if ($attempt -lt 30) { Start-Sleep -Seconds 2 }
            }
            if (-not $terminalRun) {
                throw 'The exact ACR build is still pending or temporarily unavailable. Resume later; no second build was submitted.'
            }
            $runOutputImages = @($terminalRun.outputImages)
            $digest = [string]$runOutputImages[0].digest
            $discovered = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag
            if (-not $discovered -or [string]$discovered.digest -cne $digest) {
                throw 'The succeeded ACR run did not reconcile to the exact intent tag and output digest.'
            }
            $image = "$AcrLoginServer/$repository@$digest"
            $intent.state = 'DigestCheckpointed'
            $intent.digest = $digest
            $intent.image = $image
            $result[$component] = $image
            $result["${component}Digest"] = $digest
            $result.checkpointedComponents = @(@($result.checkpointedComponents) + $component | Sort-Object -Unique)
            & $Checkpoint $result
        }
    }
    finally {
        if ($buildContext -and (Test-Path -LiteralPath $buildContext)) {
            Remove-Item -LiteralPath $buildContext -Recurse -Force
        }
    }
    return $result
}

function Build-GatewayDatabaseRecoveryImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AcrLoginServer,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$RecoveryPlanFingerprint,
        [Parameter(Mandatory)][System.Collections.IDictionary]$BuildIntent,
        [Parameter(Mandatory)][scriptblock]$Checkpoint
    )

    $root = Get-BootstrapExecutionSourceRoot
    $registry = $AcrLoginServer.Split('.')[0]
    $repository = 'gateway-db-migrator'
    $dockerfile = 'tools/Gateway.DatabaseMigrator/Dockerfile'
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Database recovery image source fingerprint'
    Assert-BootstrapFingerprintValue -Value $RecoveryPlanFingerprint -Label 'Database recovery plan fingerprint'
    Assert-GuidValue -Value $DeploymentOwnershipId -Label 'Database recovery deployment ownership ID'
    if ($registry -cnotmatch '^[a-z0-9]{5,50}$' -or
        $AcrLoginServer -cne "$registry.azurecr.io" -or
        (Get-BootstrapSourceFingerprint -Root $root) -cne $SourceFingerprint) {
        throw 'The database recovery image source or deployment ACR boundary is invalid.'
    }
    foreach ($name in @('component', 'repository', 'dockerfile', 'intentId', 'tag', 'state')) {
        if (-not $BuildIntent.Contains($name)) { throw "Database recovery image intent is missing '$name'." }
    }
    $canonicalIntentId = ([guid][string]$BuildIntent.intentId).ToString('D')
    $expectedTag = Get-BootstrapImageBuildIntentTag `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint `
        -IntentId $canonicalIntentId
    if ([string]$BuildIntent.component -cne 'databaseMigratorRecovery' -or
        [string]$BuildIntent.repository -cne $repository -or
        [string]$BuildIntent.dockerfile -cne $dockerfile -or
        [string]$BuildIntent.intentId -cne $canonicalIntentId -or
        [guid]$canonicalIntentId -eq [guid]::Empty -or
        [string]$BuildIntent.tag -cne $expectedTag -or
        [string]$BuildIntent.state -cnotin @('Planned', 'IntentRecorded', 'RunQueued', 'DigestCheckpointed')) {
        throw 'The database recovery image intent is malformed or belongs to another source/owner.'
    }
    $result = ConvertTo-BootstrapCanonicalValue -Value $BuildIntent
    $result['schemaVersion'] = 1
    $result['recoveryPlanFingerprint'] = $RecoveryPlanFingerprint
    $result['sourceFingerprint'] = $SourceFingerprint
    $result['deploymentOwnershipId'] = ([guid]$DeploymentOwnershipId).ToString('D')
    $intentCreatedThisInvocation = $false
    $buildContext = $null
    try {
        if ([string]$result.state -ceq 'DigestCheckpointed') {
            $digest = [string]$result.digest
            $image = "$AcrLoginServer/$repository@$digest"
            $discovered = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $expectedTag
            if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
                [string]$result.image -cne $image -or
                -not $discovered -or [string]$discovered.digest -cne $digest) {
                throw 'The checkpointed database recovery image no longer matches its exact ACR tag and digest.'
            }
            return $result
        }

        if ([string]$result.state -ceq 'Planned') {
            $preexisting = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $expectedTag
            $preexistingRuns = @(Get-GatewayAcrExactImageRuns -Registry $registry -Repository $repository -Tag $expectedTag)
            if ($preexisting -or $preexistingRuns.Count -ne 0) {
                throw 'The planned database recovery image intent already has provider state; refusing to adopt or overwrite it.'
            }
            $result.state = 'IntentRecorded'
            & $Checkpoint $result
            $intentCreatedThisInvocation = $true
        }

        if ([string]$result.state -ceq 'IntentRecorded') {
            $runs = @()
            for ($attempt = 1; $attempt -le 6 -and $runs.Count -eq 0; $attempt++) {
                $runs = @(Get-GatewayAcrExactImageRuns -Registry $registry -Repository $repository -Tag $expectedTag)
                if ($runs.Count -eq 0 -and -not $intentCreatedThisInvocation -and $attempt -lt 6) { Start-Sleep -Seconds 2 }
                elseif ($intentCreatedThisInvocation) { break }
            }
            if ($runs.Count -eq 0) {
                if (-not $intentCreatedThisInvocation) {
                    throw 'The recorded database recovery image intent has no exact ACR run or digest. Its submission outcome is ambiguous; automatic resubmission is forbidden.'
                }
                $buildContext = New-GatewayAcrBuildContext -RepositoryRoot $root -SourceFingerprint $SourceFingerprint
                $completedRun = Invoke-AzJson -CaptureStdoutOnly -Arguments @(
                    'acr', 'build', '--registry', $registry, '--image', "${repository}:$expectedTag",
                    '--file', $dockerfile, $buildContext, '--no-logs',
                    '--query', '{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}}')
                $completedRun = Assert-GatewayAcrCompletedBuildContract -Run $completedRun -Repository $repository -Tag $expectedTag
                $result.runId = [string]$completedRun.runId
            }
            else {
                $result.runId = [string]$runs[0].runId
            }
            $result.state = 'RunQueued'
            & $Checkpoint $result
        }

        if ([string]$result.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$') {
            throw 'The database recovery image intent has no canonical ACR run identifier.'
        }
        $terminalRun = $null
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            $currentRun = Get-GatewayAcrExactRunById -Registry $registry -Repository $repository -Tag $expectedTag -RunId ([string]$result.runId)
            if ([string]$currentRun.status -ceq 'Succeeded') { $terminalRun = $currentRun; break }
            if ([string]$currentRun.status -in @('Failed', 'Canceled', 'Error', 'Timeout')) {
                throw 'The exact database recovery ACR build reached a terminal failure. Automatic resubmission is forbidden.'
            }
            if ($attempt -lt 30) { Start-Sleep -Seconds 2 }
        }
        if (-not $terminalRun) {
            throw 'The exact database recovery ACR build is pending or unavailable. Retry reconciliation later; no second build was submitted.'
        }
        $digest = [string]@($terminalRun.outputImages)[0].digest
        $discovered = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $expectedTag
        if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or -not $discovered -or [string]$discovered.digest -cne $digest) {
            throw 'The succeeded database recovery ACR run did not reconcile to its exact intent tag and digest.'
        }
        $result.state = 'DigestCheckpointed'
        $result.digest = $digest
        $result.image = "$AcrLoginServer/$repository@$digest"
        & $Checkpoint $result
        return $result
    }
    finally {
        if ($buildContext -and (Test-Path -LiteralPath $buildContext)) {
            Remove-Item -LiteralPath $buildContext -Recurse -Force
        }
    }
}

function Get-GatewaySqlPrivateEndpointAddressSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][string]$SqlServerFqdn
    )

    $serverName = $SqlServerFqdn.Split('.')[0]
    if ($SqlServerFqdn -cne "$serverName.database.windows.net" -or
        $serverName -cne "sql-$($Config.projectName)-$($Config.environment)") {
        throw 'The SQL private-endpoint address boundary does not match the deterministic logical server.'
    }

    $providerPrefix = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers"
    $privateEndpointId = "$providerPrefix/Microsoft.Network/privateEndpoints/pe-$serverName"
    $zoneId = "$providerPrefix/Microsoft.Network/privateDnsZones/privatelink.database.windows.net"
    $recordSetId = "$zoneId/A/$serverName"
    $privateEndpoint = Invoke-AzJson -Arguments @(
        'network', 'private-endpoint', 'show', '--ids', $privateEndpointId,
        '--query', '{id:id,name:name,location:location,provisioningState:provisioningState,subnet:subnet,networkInterfaces:networkInterfaces}'
    )
    $networkInterfaces = @($privateEndpoint.networkInterfaces)
    if (-not ([string]$privateEndpoint.id).Equals($privateEndpointId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$privateEndpoint.name -cne "pe-$serverName" -or
        -not ([string]$privateEndpoint.location).Equals([string]$Config.location, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$privateEndpoint.provisioningState -cne 'Succeeded' -or
        -not ([string]$privateEndpoint.subnet.id).Equals([string]$Foundation.privateEndpointSubnetId, [StringComparison]::OrdinalIgnoreCase) -or
        $networkInterfaces.Count -ne 1) {
        throw 'The SQL private endpoint does not expose one exact ready network interface.'
    }

    $nicId = ConvertTo-GatewayCanonicalArmResourceId `
        -ResourceId ([string]$networkInterfaces[0].id) `
        -Config $Config `
        -Label 'SQL private-endpoint network interface'
    $nicPrefix = ("$providerPrefix/Microsoft.Network/networkInterfaces/pe-$serverName.nic.").ToLowerInvariant()
    if (-not $nicId.StartsWith($nicPrefix, [StringComparison]::Ordinal)) {
        throw 'The SQL private-endpoint network-interface name is not reverse-bound to the exact endpoint.'
    }
    $nicGuidText = $nicId.Substring($nicPrefix.Length)
    $nicGuid = [guid]::Empty
    if (-not [guid]::TryParse($nicGuidText, [ref]$nicGuid) -or $nicGuid -eq [guid]::Empty -or
        $nicGuidText -cne $nicGuid.ToString('D')) {
        throw 'The SQL private-endpoint network-interface suffix is not one canonical GUID.'
    }

    $nic = Invoke-AzJson -Arguments @(
        'resource', 'show', '--ids', $nicId, '--api-version', '2023-11-01',
        '--query', '{id:id,type:type,name:name,location:location,properties:properties}'
    )
    $ipConfigurations = @($nic.properties.ipConfigurations)
    if (-not ([string]$nic.id).Equals($nicId, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$nic.type).Equals('Microsoft.Network/networkInterfaces', [StringComparison]::OrdinalIgnoreCase) -or
        [string]$nic.name -cne "pe-$serverName.nic.$nicGuidText" -or
        -not ([string]$nic.location).Equals([string]$Config.location, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$nic.properties.provisioningState -cne 'Succeeded' -or
        -not ([string]$nic.properties.privateEndpoint.id).Equals($privateEndpointId, [StringComparison]::OrdinalIgnoreCase) -or
        $ipConfigurations.Count -ne 1 -or
        -not ([string]$ipConfigurations[0].properties.subnet.id).Equals([string]$Foundation.privateEndpointSubnetId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The SQL private-endpoint network interface does not exactly reverse-bind to the endpoint and foundation subnet.'
    }
    $privateEndpointIpv4Address = [string]$ipConfigurations[0].properties.privateIPAddress
    Assert-BootstrapIpv4Value -Value $privateEndpointIpv4Address -Label 'SQL private-endpoint network-interface IPv4 address'

    $recordSet = Invoke-AzJson -Arguments @(
        'network', 'private-dns', 'record-set', 'a', 'show',
        '--resource-group', [string]$Config.resourceGroupName,
        '--zone-name', 'privatelink.database.windows.net',
        '--name', $serverName,
        '--query', '{id:id,name:name,fqdn:fqdn,aRecords:aRecords}'
    )
    $aRecords = @($recordSet.aRecords)
    if (-not ([string]$recordSet.id).Equals($recordSetId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$recordSet.name -cne $serverName -or
        [string]$recordSet.fqdn -cne "$serverName.privatelink.database.windows.net." -or
        $aRecords.Count -ne 1) {
        throw 'The SQL private DNS record set is absent, ambiguous, or outside the exact server boundary.'
    }
    $privateDnsARecordIpv4Address = [string]$aRecords[0].ipv4Address
    Assert-BootstrapIpv4Value -Value $privateDnsARecordIpv4Address -Label 'SQL private DNS A-record IPv4 address'
    if ($privateDnsARecordIpv4Address -cne $privateEndpointIpv4Address) {
        throw 'The SQL private DNS A-record set does not equal the sole private-endpoint network-interface IPv4 address.'
    }

    return [ordered]@{
        privateEndpointNetworkInterfaceId = $nicId
        privateEndpointIpv4Address = $privateEndpointIpv4Address
        privateDnsARecordSetId = $recordSetId.ToLowerInvariant()
        privateDnsARecordName = $serverName
        privateDnsARecordIpv4Address = $privateDnsARecordIpv4Address
    }
}

function Get-GatewaySqlPrivateEndpointReadyAddressEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [ValidateRange(1, 241)][int]$MaximumAttempts = 121,
        [ValidateRange(0, 30)][int]$PollIntervalSeconds = 5
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            return Get-GatewaySqlPrivateEndpointAddressSnapshot `
                -Config $Config -Foundation $Foundation -SqlServerFqdn $SqlServerFqdn
        }
        catch {
            if ($attempt -eq $MaximumAttempts) {
                throw 'The exact SQL private-endpoint NIC and private-DNS A-record tuple did not converge within the bounded management-plane readiness window.'
            }
            if ($PollIntervalSeconds -gt 0) { Start-Sleep -Seconds $PollIntervalSeconds }
        }
    }
}

function Deploy-SqlPrivateEndpoint {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )
    $root = Get-BootstrapExecutionSourceRoot
    $serverName = $SqlServerFqdn.Split('.')[0]
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) { throw 'SQL private-endpoint ownership ID is not canonical.' }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'SQL private-endpoint source fingerprint'
    $deploymentName = "a365gw-$($Config.projectName)-bootstrap-sql-private-$($Config.environment)"
    $result = Invoke-AzJson -Arguments @(
        'deployment', 'group', 'create', '--resource-group', [string]$Config.resourceGroupName,
        '--name', $deploymentName,
        '--template-file', (Join-Path $root 'bootstrap/infra/sql-private-endpoint.bicep'),
        '--parameters', "location=$($Config.location)", "sqlServerName=$serverName",
        "privateEndpointSubnetId=$($Foundation.privateEndpointSubnetId)", "virtualNetworkId=$($Foundation.virtualNetworkId)",
        "projectName=$($Config.projectName)", "environment=$($Config.environment)",
        "deploymentOwnershipId=$canonicalOwnershipId", "bootstrapSourceFingerprint=$SourceFingerprint"
    )
    $outputs = $result.properties.outputs
    if ([string]$outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$outputs.bootstrapSourceFingerprint.value -cne $SourceFingerprint) {
        throw 'SQL private-endpoint deployment did not echo the exact ownership/source boundary.'
    }
    $addressEvidence = Get-GatewaySqlPrivateEndpointReadyAddressEvidence `
        -Config $Config -Foundation $Foundation -SqlServerFqdn $SqlServerFqdn
    return [ordered]@{
        deploymentName = $deploymentName
        deploymentOwnershipId = $canonicalOwnershipId
        sourceFingerprint = $SourceFingerprint
        privateEndpointId = [string]$outputs.privateEndpointId.value
        privateDnsZoneId = [string]$outputs.privateDnsZoneId.value
        virtualNetworkLinkId = [string]$outputs.virtualNetworkLinkId.value
        privateDnsZoneGroupId = [string]$outputs.privateDnsZoneGroupId.value
        sqlServerId = [string]$outputs.sqlServerId.value
        privateEndpointSubnetId = [string]$outputs.privateEndpointSubnetId.value
        virtualNetworkId = [string]$outputs.virtualNetworkId.value
        privateEndpointNetworkInterfaceId = [string]$addressEvidence.privateEndpointNetworkInterfaceId
        privateEndpointIpv4Address = [string]$addressEvidence.privateEndpointIpv4Address
        privateDnsARecordSetId = [string]$addressEvidence.privateDnsARecordSetId
        privateDnsARecordName = [string]$addressEvidence.privateDnsARecordName
        privateDnsARecordIpv4Address = [string]$addressEvidence.privateDnsARecordIpv4Address
    }
}

function Deploy-GatewayAdminUi {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$AdminIdentity,
        [Parameter(Mandatory)][string]$AdminUiImage,
        [Parameter(Mandatory)][string]$AdminUiSecretUri,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter()][string]$ExecutionSourceFingerprint = ''
    )
    $root = Get-BootstrapExecutionSourceRoot
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Admin UI deployment ownership ID must be a canonical lowercase GUID from the current bootstrap state.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Admin UI deployment source fingerprint'
    if ([string]::IsNullOrWhiteSpace($ExecutionSourceFingerprint)) {
        $ExecutionSourceFingerprint = $SourceFingerprint
    }
    Assert-BootstrapFingerprintValue -Value $ExecutionSourceFingerprint -Label 'Admin UI execution source fingerprint'
    if ((Get-BootstrapSourceFingerprint -Root $root) -cne $ExecutionSourceFingerprint) {
        throw 'The Admin UI execution source no longer matches the accepted content-addressed snapshot.'
    }
    $deploymentName = "a365gw-$($Config.projectName)-bootstrap-admin-$($Config.environment)"
    $deploymentCountText = Invoke-AzTsv -Arguments @(
        'deployment', 'group', 'list', '--resource-group', [string]$Config.resourceGroupName,
        '--query', "length([?name=='$deploymentName'])"
    )
    $deploymentCount = 0
    if (-not [int]::TryParse($deploymentCountText, [ref]$deploymentCount) -or $deploymentCount -ne 0) {
        throw 'The fresh Admin UI deployment record was not proven absent. Use only exact state-bound Resume recovery.'
    }
    foreach ($target in @(
        [ordered]@{ name = "id-gateway-admin-$($Config.environment)"; type = 'Microsoft.ManagedIdentity/userAssignedIdentities' },
        [ordered]@{ name = "ca-gateway-admin-$($Config.environment)"; type = 'Microsoft.App/containerApps' }
    )) {
        $resourceCountText = Invoke-AzTsv -Arguments @(
            'resource', 'list', '--resource-group', [string]$Config.resourceGroupName,
            '--name', [string]$target.name, '--resource-type', [string]$target.type,
            '--query', 'length(@)'
        )
        $resourceCount = 0
        if (-not [int]::TryParse($resourceCountText, [ref]$resourceCount) -or $resourceCount -ne 0) {
            throw "The fresh Admin UI target '$($target.name)' was not proven absent. Refusing to adopt a pre-existing credential-bearing identity or app."
        }
    }
    $parameters = [ordered]@{
        environment = [string]$Config.environment
        projectName = [string]$Config.projectName
        deploymentOwnershipId = $canonicalOwnershipId
        bootstrapSourceFingerprint = $SourceFingerprint
        containerAppsEnvironmentName = [string]$Foundation.containerAppsEnvironmentName
        adminUiContainerImage = $AdminUiImage
        entraIdTenantId = [string]$Config.tenantId
        adminUiEntraClientId = [string]$AdminIdentity.adminUiClientId
        adminUiEntraClientSecretKeyVaultSecretUri = $AdminUiSecretUri
        adminUiGatewayApiScope = "$($Identity.gatewayApiScopeBaseUri)/access_as_user"
        deployKeyVaultPrivateEndpoint = $true
        keyVaultPrivateEndpointSubnetId = [string]$Foundation.privateEndpointSubnetId
        keyVaultPrivateDnsVirtualNetworkId = [string]$Foundation.virtualNetworkId
    }
    $deployment = Invoke-ArmDeploymentWithSecureParameters -ResourceGroup ([string]$Config.resourceGroupName) -Name $deploymentName -TemplateFile (Join-Path $root 'infrastructure/bicep/admin-ui.bicep') -Parameters $parameters
    $outputs = $deployment.properties.outputs
    if ([string]$outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$outputs.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
        [string]$outputs.adminUiContainerImage.value -cne $AdminUiImage) {
        throw 'Admin UI deployment did not echo the exact bootstrap ownership, source, and immutable-image boundary.'
    }
    return [ordered]@{
        deploymentOwnershipId = $canonicalOwnershipId
        sourceFingerprint = $SourceFingerprint
        adminUiImage = $AdminUiImage
        adminUiFqdn = [string]$outputs.adminUiFqdn.value
        adminUiUrl = [string]$outputs.adminUiUrl.value
        adminUiPrincipalId = [string]$outputs.adminUiPrincipalId.value
        signInRedirectUri = [string]$outputs.adminUiSignInRedirectUri.value
        signedOutCallbackUri = [string]$outputs.adminUiSignedOutCallbackUri.value
    }
}

function Get-GatewayAdminUiDeploymentEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$AdminUiImage
    )
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Admin UI recovery ownership ID is not canonical.'
    }
    $deploymentName = "a365gw-$($Config.projectName)-bootstrap-admin-$($Config.environment)"
    $deployment = Invoke-AzJson -Arguments @(
        'deployment', 'group', 'show', '--resource-group', [string]$Config.resourceGroupName,
        '--name', $deploymentName
    )
    if (-not $deployment -or [string]$deployment.properties.provisioningState -ne 'Succeeded' -or
        [string]$deployment.properties.parameters.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$deployment.properties.outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$deployment.properties.parameters.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
        [string]$deployment.properties.outputs.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
        [string]$deployment.properties.parameters.adminUiContainerImage.value -cne $AdminUiImage -or
        [string]$deployment.properties.outputs.adminUiContainerImage.value -cne $AdminUiImage) {
        throw 'The prior Admin UI deployment was absent, incomplete, or not owned by this bootstrap state.'
    }
    $outputs = $deployment.properties.outputs
    return [ordered]@{
        deploymentOwnershipId = $canonicalOwnershipId
        sourceFingerprint = $SourceFingerprint
        adminUiImage = $AdminUiImage
        adminUiFqdn = [string]$outputs.adminUiFqdn.value
        adminUiUrl = [string]$outputs.adminUiUrl.value
        adminUiPrincipalId = [string]$outputs.adminUiPrincipalId.value
        signInRedirectUri = [string]$outputs.adminUiSignInRedirectUri.value
        signedOutCallbackUri = [string]$outputs.adminUiSignedOutCallbackUri.value
    }
}

function Set-GatewayNetworkHardening {
    param([Parameter(Mandatory)]$Config)
    $sharedVault = "kv-$($Config.projectName)-$($Config.environment)"
    Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('keyvault', 'update', '--resource-group', [string]$Config.resourceGroupName, '--name', $sharedVault, '--public-network-access', 'Disabled', '--only-show-errors') | Out-Null
    $actual = Invoke-AzTsv -Arguments @(
        'keyvault', 'show', '--resource-group', [string]$Config.resourceGroupName,
        '--name', $sharedVault, '--query', 'properties.publicNetworkAccess'
    )
    if ($actual -cne 'Disabled') {
        throw 'Shared Key Vault network hardening was not independently read back as Disabled.'
    }
    return [ordered]@{
        sharedKeyVault = $sharedVault
        publicNetworkAccess = 'Disabled'
        exactPostMutationReadback = $true
    }
}

Export-ModuleMember -Function *
