#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-RuntimePurviewPrerequisites {
    param([bool]$Enabled)
    if (-not $Enabled) { return }
    if (-not $IsWindows) { throw 'Purview setup requires the Windows account that will run the certificate-backed catalog service.' }
    if (-not (Get-Module -ListAvailable ExchangeOnlineManagement | Where-Object Version -EQ ([version]'3.10.1'))) {
        throw 'Install ExchangeOnlineManagement 3.10.1 for the current Windows account before Purview setup: Install-Module ExchangeOnlineManagement -RequiredVersion 3.10.1 -Scope CurrentUser'
    }
}

function Ensure-RuntimePurviewManagementIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$DeploymentOwnershipId,
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]{1,64}$')][string]$DeploymentName,
        [Parameter(Mandatory)][guid]$OwnerObjectId
    )
    if (-not $IsWindows) { throw 'Run Purview certificate setup on the Windows catalog host.' }
    $currentTenant = Invoke-AzTsv -Arguments @('account', 'show', '--query', 'tenantId')
    if ($currentTenant -ne $TenantId.ToString()) { throw 'The signed-in tenant does not match this deployment.' }
    # Current Microsoft guidance specifies EOP for Connect-IPPSSession.
    $resourceAppId = '00000007-0000-0ff1-ce00-000000000000'
    $resource = Get-ServicePrincipalByAppId -AppId $resourceAppId
    $roles = @($resource.appRoles | Where-Object {
        $_.id -eq '455e5cd2-84e8-4751-8344-5672145dfa17' -and
        $_.value -eq 'Exchange.ManageAsApp' -and $_.isEnabled -and
        $_.allowedMemberTypes -contains 'Application'
    })
    if ($roles.Count -ne 1) { throw 'The expected Security and Compliance application permission was not found.' }
    # This tenant resolves the compliance token audience to Exchange Online.
    # Verify that binding instead of assuming the similarly named EOP grant will
    # appear in a token for a different resource application.
    $exchange = Get-BootstrapPurviewExchangeRole
    $requiredAccess = @(
        @{ resourceAppId = $resourceAppId; resourceAccess = @(@{ id = $roles[0].id; type = 'Role' }) }
        @{ resourceAppId = '00000002-0000-0ff1-ce00-000000000000'; resourceAccess = @(@{ id = 'dc50a0fb-09a3-484d-be87-e023b12c6440'; type = 'Role' }) }
    )
    $displayName = "A365 Gateway Purview Policies - $DeploymentName"
    $app = Get-ExactApplicationByDisplayName -DisplayName $displayName
    if (-not $app) {
        $app = Invoke-GraphJsonBody -Method POST -Url 'https://graph.microsoft.com/v1.0/applications' -Body @{
            displayName = $displayName; signInAudience = 'AzureADMyOrg'
            tags = @(Get-BootstrapApplicationTags -DeploymentOwnershipId $DeploymentOwnershipId)
            isFallbackPublicClient = $false
            requiredResourceAccess = $requiredAccess
        }
    }
    Assert-BootstrapApplicationOwnership -Application $app -DeploymentOwnershipId $DeploymentOwnershipId -OwnerObjectId $OwnerObjectId -AllowAddMissingOwner | Out-Null
    $app = Get-ExactApplicationByDisplayName -DisplayName $displayName
    Assert-ExactApplicationAuthenticationSurface -Application $app -ApplicationLabel 'Runtime Purview management' | Out-Null
    if ($app.signInAudience -ne 'AzureADMyOrg' -or @($app.passwordCredentials).Count -ne 0 -or
        @($app.appRoles).Count -ne 0 -or @($app.api.oauth2PermissionScopes).Count -ne 0 -or
        @($app.web.redirectUris).Count -ne 0 -or @($app.spa.redirectUris).Count -ne 0 -or
        @($app.publicClient.redirectUris).Count -ne 0) {
        throw 'The dedicated management application has unexpected credentials or permissions; refusing to alter it.'
    }
    foreach ($access in @($app.requiredResourceAccess)) {
        $expected = @($requiredAccess | Where-Object resourceAppId -EQ $access.resourceAppId)
        if ($expected.Count -ne 1 -or @($access.resourceAccess).Count -ne 1 -or
            $access.resourceAccess[0].id -ne $expected[0].resourceAccess[0].id -or $access.resourceAccess[0].type -ne 'Role') {
            throw 'The management application requests an unexpected resource permission.'
        }
    }
    if (@($app.requiredResourceAccess).Count -gt 2 -or @($app.requiredResourceAccess.resourceAppId | Sort-Object -Unique).Count -ne @($app.requiredResourceAccess).Count) {
        throw 'The management application has duplicate or extra resource permissions.'
    }
    if (@($app.requiredResourceAccess).Count -ne 2) {
        Invoke-GraphJsonBody -Method PATCH -Url "https://graph.microsoft.com/v1.0/applications/$($app.id)" -Body @{ requiredResourceAccess = $requiredAccess } | Out-Null
    }
    $sp = Ensure-ServicePrincipal -AppId $app.appId -ServicePrincipalNames @($app.appId) -Tags @()
    if ($sp.appId -ne $app.appId -or -not $sp.accountEnabled -or @($sp.passwordCredentials).Count -ne 0) {
        throw 'The management service principal does not match the expected boundary.'
    }
    # Persist the private key in the Windows account certificate store, not a file,
    # bootstrap state, container environment, or command line. A retry finds the
    # same certificate before publishing its public key to Entra.
    $subject = "CN=a365gw-purview-$DeploymentOwnershipId-$($app.appId)"
    $certs = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object Subject -CEQ $subject)
    if ($certs.Count -gt 1) { throw 'More than one management certificate matches this deployment.' }
    if ($certs.Count -eq 0) {
        if (@($app.keyCredentials).Count -ne 0) { throw 'Entra has a certificate but this catalog host has no corresponding private key. Restore it; do not rotate implicitly.' }
        $certificate = New-SelfSignedCertificate -Subject $subject -CertStoreLocation Cert:\CurrentUser\My `
            -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider' -KeySpec KeyExchange `
            -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable `
            -NotAfter (Get-Date).AddYears(1)
    } else { $certificate = $certs[0] }
    if (-not $certificate.HasPrivateKey -or $certificate.NotAfter.ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(30)) {
        throw 'The management certificate is unavailable or expires within 30 days. Explicit rotation is required.'
    }
    $thumbprint = $certificate.Thumbprint
    $matchingKeys = @($app.keyCredentials | Where-Object {
        $_.customKeyIdentifier -eq [Convert]::ToBase64String($certificate.GetCertHash())
    })
    if (@($app.keyCredentials).Count -eq 0) {
        Invoke-GraphJsonBody -Method PATCH -Url "https://graph.microsoft.com/v1.0/applications/$($app.id)" -Body @{
            keyCredentials = @(@{
                keyId = [guid]::NewGuid().ToString(); displayName = 'runtime-purview-policies'
                type = 'AsymmetricX509Cert'; usage = 'Verify'
                key = [Convert]::ToBase64String($certificate.RawData)
                customKeyIdentifier = [Convert]::ToBase64String($certificate.GetCertHash())
                startDateTime = $certificate.NotBefore.ToUniversalTime().ToString('O')
                endDateTime = $certificate.NotAfter.ToUniversalTime().ToString('O')
            })
        } | Out-Null
    } elseif (@($app.keyCredentials).Count -ne 1 -or $matchingKeys.Count -ne 1) {
        throw 'The Entra certificate differs from the catalog-host certificate; refusing replacement.'
    }
    $readback = Get-ExactApplicationByDisplayName -DisplayName $displayName
    if (@($readback.requiredResourceAccess).Count -ne 2 -or @($requiredAccess | Where-Object {
        $expected = $_
        @($readback.requiredResourceAccess | Where-Object {
            $_.resourceAppId -eq $expected.resourceAppId -and @($_.resourceAccess).Count -eq 1 -and
            $_.resourceAccess[0].id -eq $expected.resourceAccess[0].id -and $_.resourceAccess[0].type -eq 'Role'
        }).Count -ne 1
    }).Count -ne 0) { throw 'Management application permission declaration has not been confirmed.' }
    if (@($readback.keyCredentials).Count -ne 1 -or
        $readback.keyCredentials[0].customKeyIdentifier -ne [Convert]::ToBase64String($certificate.GetCertHash())) {
        throw 'Management certificate publication has not been confirmed. Run gateway up for exact readback.'
    }
    $grantUrl = "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments"
    $grants = @(Get-BoundedGraphCollection -InitialUrl $grantUrl)
    $expectedGrants = @(
        @{ resourceId=$resource.id; appRoleId=$roles[0].id }
        @{ resourceId=$exchange.servicePrincipalId; appRoleId=$exchange.roleId }
    )
    if (@($grants | Where-Object {
        $grant = $_
        @($expectedGrants | Where-Object { $_.resourceId -eq $grant.resourceId -and $_.appRoleId -eq $grant.appRoleId }).Count -ne 1
    }).Count -ne 0) {
        throw 'The dedicated management identity has unexpected application grants.'
    }
    foreach ($expected in $expectedGrants) {
        if (@($grants | Where-Object { $_.resourceId -eq $expected.resourceId -and $_.appRoleId -eq $expected.appRoleId }).Count -eq 0) {
            Invoke-GraphJsonBody -Method POST -Url $grantUrl -Body @{
                principalId = $sp.id; resourceId = $expected.resourceId; appRoleId = $expected.appRoleId
            } | Out-Null
        }
    }
    $grants = @(Get-BoundedGraphCollection -InitialUrl $grantUrl)
    if ($grants.Count -ne 2 -or @($expectedGrants | Where-Object {
        $expected = $_
        @($grants | Where-Object { $_.resourceId -eq $expected.resourceId -and $_.appRoleId -eq $expected.appRoleId }).Count -ne 1
    }).Count -ne 0) {
        throw 'Management permission grant has not been confirmed. Run gateway up for exact readback.'
    }
    return [ordered]@{
        tenantId = $TenantId.ToString(); deploymentOwnershipId = $DeploymentOwnershipId.ToString()
        applicationId = [string]$app.appId; applicationObjectId = [string]$app.id
        servicePrincipalId = [string]$sp.id; displayName = $displayName
        organization = Get-BootstrapInitialTenantDomain
        certificateThumbprint = $thumbprint; certificateStore = 'CurrentUser/My'
        certificateExpiresAtUtc = $certificate.NotAfter.ToUniversalTime().ToString('O')
        roleGroupName = "A365 Gateway Policies $DeploymentOwnershipId"
        applicationPermissions = @('Exchange Online Protection: Exchange.ManageAsApp', 'Exchange Online: Exchange.ManageAsApp')
        accessVerified = $false
    }
}

function Set-RuntimePurviewManagementRoleGroup {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Identity, [Parameter(Mandatory)][string]$AdministratorUpn)
    Import-Module ExchangeOnlineManagement -RequiredVersion 3.10.1
    if (@(Get-ConnectionInformation).Count -ne 0) { throw 'Run Purview bootstrap in a fresh PowerShell process with no existing sessions.' }
    try {
        Connect-IPPSSession -UserPrincipalName $AdministratorUpn -DisableWAM -ShowBanner:$false -CommandName `
            Get-ServicePrincipal,New-ServicePrincipal,Get-RoleGroup,New-RoleGroup,Set-RoleGroup,Get-ManagementRole,Get-RoleGroupMember,Add-RoleGroupMember
        Assert-RuntimePurviewSessionTenant -TenantId $Identity.tenantId
        $principals = @(Get-ServicePrincipal | Where-Object AppId -EQ $Identity.applicationId)
        if ($principals.Count -eq 0) {
            New-ServicePrincipal -AppId $Identity.applicationId -ObjectId $Identity.servicePrincipalId -DisplayName $Identity.displayName | Out-Null
            $principals = @(Get-ServicePrincipal | Where-Object AppId -EQ $Identity.applicationId)
        }
        if ($principals.Count -ne 1 -or [string]$principals[0].ObjectId -ne $Identity.servicePrincipalId) {
            throw 'Purview management service principal readback did not match Entra.'
        }
        $groups = @(Get-RoleGroup | Where-Object Name -CEQ $Identity.roleGroupName)
        $role = Get-ManagementRole -Identity 'DLP Compliance Management'
        if ($role.RoleType -ne 'DLPComplianceManagement' -or -not $role.IsRootRole) { throw 'Unexpected Purview DLP role definition.' }
        $description = "Gateway existing-policy scope management; deployment $($Identity.deploymentOwnershipId)"
        if ($groups.Count -eq 0) {
            New-RoleGroup -Name $Identity.roleGroupName -DisplayName $Identity.roleGroupName -Description $description -Roles 'DLP Compliance Management' | Out-Null
            $groups = @(Get-RoleGroup | Where-Object Name -CEQ $Identity.roleGroupName)
        }
        if ($groups.Count -ne 1 -or $groups[0].Description -cne $description -or
            @($groups[0].Roles).Count -ne 1 -or
            [string]$groups[0].Roles[0] -ne ([string]$role.Identity).Replace('/Configuration/RBAC/Roles/', '/')) {
            throw 'The dedicated Purview role group has unexpected ownership or roles.'
        }
        if ([string]::IsNullOrEmpty([string]$groups[0].DisplayName)) {
            Set-RoleGroup -Identity $groups[0].Guid -DisplayName $Identity.roleGroupName | Out-Null
        }
        $members = @(Get-RoleGroupMember -Identity $groups[0].Guid)
        if (@($members | Where-Object { [string](Get-OptionalObjectPropertyValue $_ 'Guid') -ne $Identity.servicePrincipalId }).Count -ne 0) {
            throw 'The dedicated Purview role group has unexpected members.'
        }
        if ($members.Count -eq 0) { Add-RoleGroupMember -Identity $groups[0].Guid -Member $Identity.servicePrincipalId | Out-Null }
        $members = @(Get-RoleGroupMember -Identity $groups[0].Guid)
        if ($members.Count -ne 1 -or [string](Get-OptionalObjectPropertyValue $members[0] 'Guid') -ne $Identity.servicePrincipalId) {
            throw 'Purview management role membership has not been confirmed.'
        }
    } finally { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue }
}

function Test-RuntimePurviewManagementAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Identity)
    Import-Module ExchangeOnlineManagement -RequiredVersion 3.10.1
    if (@(Get-ConnectionInformation).Count -ne 0) { throw 'Run Purview verification in a fresh PowerShell process with no existing sessions.' }
    try {
        Connect-IPPSSession -AppId $Identity.applicationId -Organization $Identity.organization `
            -CertificateThumbprint $Identity.certificateThumbprint -ShowBanner:$false `
            -CommandName Get-DlpCompliancePolicy,Get-DlpComplianceRule,Set-DlpCompliancePolicy
        Assert-RuntimePurviewSessionTenant -TenantId $Identity.tenantId
        foreach ($name in @('Get-DlpCompliancePolicy','Get-DlpComplianceRule','Set-DlpCompliancePolicy')) {
            if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Required Purview command is unavailable: $name" }
        }
        . (Join-Path $PSScriptRoot '../../src/Gateway.Purview/Automation/Read-PurviewPolicyCatalog.ps1')
        $catalog = Read-PurviewPolicyCatalog -TenantId $Identity.tenantId
        return [ordered]@{ verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O'); policyCount = @($catalog.items).Count; catalog = $catalog }
    } finally { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue }
}

function Assert-RuntimePurviewSessionTenant {
    param([Parameter(Mandatory)][guid]$TenantId)
    $connections = @(Get-ConnectionInformation)
    if ($TenantId -eq [guid]::Empty -or $connections.Count -ne 1 -or
        [string]$connections[0].TenantID -ne $TenantId.ToString() -or
        -not $connections[0].IsEopSession -or $connections[0].State -ne 'Connected' -or $connections[0].TokenStatus -ne 'Active') {
        throw 'The exact connected Purview tenant could not be confirmed.'
    }
}

function Start-RuntimePurviewCatalogHost {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Identity, [Parameter(Mandatory)]$InitialCatalog)
    if (-not $IsWindows -or -not $Identity.accessVerified) { throw 'Verified Windows certificate access is required before starting catalog publication.' }
    $root = Get-RepositoryRoot
    $directory = Join-Path $root '.bootstrap/purview-catalog'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $connector = Join-Path $root '.bootstrap/purview-connector'
    [IO.Directory]::CreateDirectory($connector) | Out-Null
    $connectorIdPath = Join-Path $connector 'connector-instance-id.txt'
    if (-not (Test-Path -LiteralPath $connectorIdPath)) {
        [IO.File]::WriteAllText($connectorIdPath, ([guid]::NewGuid().ToString('D')))
    }
    $connectorId = [guid]::Empty
    if (-not [guid]::TryParse(([IO.File]::ReadAllText($connectorIdPath).Trim()), [ref]$connectorId) -or $connectorId -eq [guid]::Empty) {
        throw 'The existing Purview connector instance identifier is invalid; restore it rather than replacing it implicitly.'
    }
    if ($Identity -is [Collections.IDictionary]) { $Identity.connectorInstanceId = $connectorId.ToString('D') }
    elseif ($Identity.PSObject.Properties.Name -contains 'connectorInstanceId') { $Identity.connectorInstanceId = $connectorId.ToString('D') }
    else { $Identity | Add-Member -NotePropertyName connectorInstanceId -NotePropertyValue $connectorId.ToString('D') }
    $identityPath = Join-Path $directory 'identity.json'
    [IO.File]::WriteAllText($identityPath, ($Identity | ConvertTo-Json -Depth 10))
    $queue = Join-Path $root '.bootstrap/purview-assignments'
    [IO.Directory]::CreateDirectory($queue) | Out-Null
    $keyPath = Join-Path $root '.bootstrap/secrets/purview-assignment.key'
    if (-not (Test-Path -LiteralPath $keyPath)) {
        [IO.Directory]::CreateDirectory((Split-Path $keyPath -Parent)) | Out-Null
        [IO.File]::WriteAllText($keyPath, [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)))
    }
    if ([Convert]::FromBase64String([IO.File]::ReadAllText($keyPath).Trim()).Length -ne 32) { throw 'Invalid assignment authentication key.' }
    $output = Join-Path $root '.bootstrap/tools/purview-catalog-host'
    $executable = Join-Path $output 'Gateway.Purview.CatalogHost.exe'
    if (($identityPath + $directory + $connector + $queue + $keyPath) -match '["\r\n]') { throw 'Unsupported catalog host path.' }
    # The certificate private key belongs to this Windows user. Task Scheduler
    # supervises one headless listener; idle startup and heartbeat do not contact
    # Purview. Only authenticated connector or assignment work starts a bounded
    # provider child process.
    $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskName = 'A365Gateway-Purview-' + ([string]$Identity.applicationId)
    $legacyDescription = 'Refresh the gateway Purview catalog and process assignments using its current-user certificate.'
    $listenerDescription = 'Run the gateway Purview connector listener using its current-user certificate.'
    $registered = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($registered) {
        $actions = @($registered.Actions)
        $expectedExecutable = Join-Path $output 'Gateway.Purview.CatalogHost.exe'
        try {
            $registeredSid = ([Security.Principal.NTAccount]$registered.Principal.UserId).Translate([Security.Principal.SecurityIdentifier]).Value
        } catch { throw 'The existing Purview task principal could not be verified; refusing replacement.' }
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($actions.Count -ne 1 -or [IO.Path]::GetFullPath([string]$actions[0].Execute) -cne [IO.Path]::GetFullPath($expectedExecutable) -or
            [IO.Path]::GetFullPath([string]$actions[0].WorkingDirectory) -cne [IO.Path]::GetFullPath($root) -or
            $registeredSid -ne $currentSid -or [string]$registered.Description -cnotin @($legacyDescription, $listenerDescription)) {
            throw 'The existing Purview task is not the exact owned catalog host; refusing replacement.'
        }
    }
    if ($registered -and $registered.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        $stopDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 100
            $registered = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        } while ($registered -and $registered.State -eq 'Running' -and [DateTime]::UtcNow -lt $stopDeadline)
        if ($registered -and $registered.State -eq 'Running') { throw 'The previous Purview connector task did not stop.' }
    }

    # Migrate the former detached, long-running host only when its recorded
    # executable and start time still identify the exact process.
    $pidFile = Join-Path $directory 'host.json'
    if (Test-Path -LiteralPath $pidFile) {
        $record = ConvertFrom-BootstrapJson -Json (Get-Content -LiteralPath $pidFile -Raw)
        $existing = Get-Process -Id $record.processId -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.Path -eq $record.executable -and $existing.StartTime.ToUniversalTime().ToString('O') -eq $record.startedAtUtc) {
                $existing.Kill($true)
                if (-not $existing.WaitForExit(10000)) { throw 'The previous Purview catalog host did not stop.' }
            }
            # Process IDs can be reused after reboot. Do not touch that process.
        }
        [IO.File]::Delete($pidFile)
    }

    Invoke-BootstrapCommand -FilePath 'dotnet' -ArgumentList @('publish', (Join-Path $root 'src/Gateway.Purview.CatalogHost'), '-c', 'Release', '-o', $output, '--nologo') | Out-Null
    $executable = Join-Path $output 'Gateway.Purview.CatalogHost.exe'
    $assembly = Join-Path $output 'Gateway.Purview.CatalogHost.dll'
    $initialCatalogPath = Join-Path $directory ('bootstrap-catalog-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($initialCatalogPath, ($InitialCatalog | ConvertTo-Json -Depth 60 -Compress))
        # The scheduled listener uses the windowless apphost. Run the bounded
        # bootstrap publication through dotnet so setup waits for and observes
        # the managed process exit code without launching a GUI-subsystem host.
        Invoke-BootstrapCommand -FilePath 'dotnet' -ArgumentList @(
            $assembly, '--publish-bootstrap', $identityPath, $directory, $connector, $queue, $keyPath, $initialCatalogPath
        ) | Out-Null
    } finally {
        if (Test-Path -LiteralPath $initialCatalogPath) { [IO.File]::Delete($initialCatalogPath) }
    }
    $arguments = @("`"$identityPath`"", "`"$directory`"", "`"$connector`"", "`"$queue`"", "`"$keyPath`"")
    $action = New-ScheduledTaskAction -Execute $executable -Argument ($arguments -join ' ') -WorkingDirectory $root
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $account
    $principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $logonTrigger -Principal $principal -Settings $settings `
        -Description $listenerDescription -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    return [ordered]@{
        taskName=$taskName; executable=$executable; snapshotDirectory=$directory
        connectorDirectory=$connector; connectorInstanceId=$connectorId.ToString('D'); mode='logon-listener'
    }
}

Export-ModuleMember -Function Ensure-RuntimePurviewManagementIdentity,Set-RuntimePurviewManagementRoleGroup,Test-RuntimePurviewManagementAccess,Start-RuntimePurviewCatalogHost,Assert-RuntimePurviewPrerequisites
