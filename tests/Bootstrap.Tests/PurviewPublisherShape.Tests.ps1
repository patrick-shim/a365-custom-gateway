BeforeAll {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    foreach ($module in @('Common', 'Entra', 'Azure', 'Experience', 'PurviewExecutor')) {
        Import-Module "$root/bootstrap/modules/$module.psm1" -Force -DisableNameChecking
    }
    $originalPath = $env:PATH
    $native = Join-Path $TestDrive 'native'
    $null = New-Item -ItemType Directory -Path $native
    $env:A365GW_PUBLISHER_TEST_METADATA = Join-Path $TestDrive 'synthetic-metadata.json'
    $env:A365GW_PUBLISHER_TEST_CALLS = Join-Path $TestDrive 'native-arguments.jsonl'
    # No Azure executable is available on this test PATH. Exercise the real
    # executor/Common dispatch and ARM/Graph guards, substituting native I/O only.
    @'
$ErrorActionPreference = 'Stop'
[IO.File]::AppendAllText($env:A365GW_PUBLISHER_TEST_CALLS, (ConvertTo-Json -InputObject @($args) -Compress) + "`n")
$f = Get-Content -LiteralPath $env:A365GW_PUBLISHER_TEST_METADATA -Raw | ConvertFrom-Json -AsHashtable
if ($args[0] -ceq 'resource' -and $args[1] -ceq 'show') { $result = $f.job }
elseif ($args[0] -ceq 'role' -and $args[1] -ceq 'assignment' -and $args[2] -ceq 'list') { $result = $f.roles }
elseif ($args[0] -ceq 'account' -and $args[1] -ceq 'get-access-token') {
    $result = @{
        subscription = $f.subscription; tenant = $f.tenant; tokenType = 'Bearer'
        expires_on = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
        accessToken = 'synthetic-native-boundary-only'
    }
}
elseif (($args[0..3] -join ' ') -ceq 'containerapp job execution list') { $result = @(@{ name = 'exact-execution' }) }
elseif (($args[0..3] -join ' ') -ceq 'containerapp job execution show') { $result = $f.execution }
else { exit 93 }
[Console]::Out.Write((ConvertTo-Json -InputObject $result -Depth 60 -Compress))
exit 0
'@ | Set-Content (Join-Path $native 'fixture.ps1') -Encoding utf8NoBOM
    if ($IsWindows) {
        $nativeCommand = Join-Path $native 'az.cmd'
        "@echo off`r`n`"$PSHOME\pwsh.exe`" -NoProfile -NonInteractive -File `"%~dp0fixture.ps1`" %*`r`n" |
            Set-Content $nativeCommand -Encoding ascii
        Test-Path (Join-Path $TestDrive 'python.exe') | Should -BeFalse
    }
    else {
        $nativeCommand = Join-Path $native 'az'
        "#!/bin/sh`nexec '$PSHOME/pwsh' -NoProfile -NonInteractive -File '$native/fixture.ps1' `"`$@`"`n" |
            Set-Content $nativeCommand -Encoding utf8NoBOM
        & chmod 700 $nativeCommand
        $LASTEXITCODE | Should -Be 0
    }
    function Save-PublisherFixture {
        ConvertTo-Json -InputObject $fixture -Depth 60 -Compress |
            Set-Content $env:A365GW_PUBLISHER_TEST_METADATA -Encoding utf8NoBOM
    }
    function Assert-PublisherFixture {
        Save-PublisherFixture
        Assert-PurviewPublisherJob -Config $config -Foundation $foundation -Record $record -Network $network
    }
    function Invoke-PublisherReadOnlyFixture {
        $record.operations.publish = @{
            status = 'Started'
            intentFingerprint = Get-BootstrapObjectFingerprint -InputObject @{
                jobId = $record.publisher.jobId.value; template = $job.properties.template; intentId = $record.intentId
            }
        }
        Save-PublisherFixture
        $before = Get-BootstrapObjectFingerprint -InputObject $record
        $result = Start-PurviewPublisherOnce -Config $config -Template $job.properties.template -Record $record -ReadOnly -Checkpoint { throw 'No checkpoint authorized' }
        (Get-BootstrapObjectFingerprint -InputObject $record) | Should -BeExactly $before
        return $result
    }
}

AfterAll {
    $env:PATH = $originalPath
    $env:A365GW_PUBLISHER_TEST_METADATA = $null
    $env:A365GW_PUBLISHER_TEST_CALLS = $null
    Clear-BootstrapAzureSubscriptionContext
}

Describe 'Actual publisher guard provider metadata shapes' {
    BeforeEach {
        $subscription = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $tenant = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        $principal = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        $scope = "/subscriptions/$subscription/resourceGroups/rg-publisher"
        $config = @{ subscriptionId = $subscription; tenantId = $tenant; resourceGroupName = 'rg-publisher' }
        $foundation = @{
            runtimeImagePullIdentityId = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pull"
            containerAppsEnvironmentId = "$scope/providers/Microsoft.App/managedEnvironments/private"
            acrLoginServer = 'fixture.azurecr.io'
        }
        $network = @{ privateEndpointIp = '10.42.2.4' }
        $record = [ordered]@{
            context = @{ deploymentOwnershipId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'; sourceFingerprint = 'sha256:' + ('a' * 64) }
            intentId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'; operations = [ordered]@{}
            package = @{ receipt = @{ packageDigest = 'sha256:' + ('b' * 64); packageBytes = 1234 } }
            host = @{
                packageContainerId = @{ value = "$scope/providers/Microsoft.Storage/storageAccounts/package/blobServices/default/containers/purview-executor-packages" }
                packageContainerUri = @{ value = 'https://fixture.blob.core.windows.net/purview-executor-packages' }
            }
            publisher = @{
                jobId = @{ value = "$scope/providers/Microsoft.App/jobs/publisher" }; jobName = @{ value = 'publisher' }
                jobPrincipalId = @{ value = $principal }; publisherImage = @{ value = 'fixture.azurecr.io/publisher@sha256:' + ('c' * 64) }
            }
        }
        $values = [ordered]@{
            PUBLISHER_DEPLOYMENT_OWNERSHIP_ID = $record.context.deploymentOwnershipId
            PUBLISHER_EXECUTION_INTENT_ID = $record.intentId
            PUBLISHER_EXECUTION_SOURCE_FINGERPRINT = $record.context.sourceFingerprint
            PUBLISHER_PACKAGE_DIGEST = $record.package.receipt.packageDigest
            PUBLISHER_PACKAGE_BYTES = '1234'
            PUBLISHER_CONTAINER_URI = $record.host.packageContainerUri.value
            PUBLISHER_PRIVATE_ENDPOINT_IP = $network.privateEndpointIp
        }
        $container = @{
            name = 'purview-package-publisher'; image = $record.publisher.publisherImage.value
            resources = @{ cpu = 0.5; memory = '1Gi' }; probes = @(); volumeMounts = $null
            env = @($values.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value; secretRef = $null } })
            command = $null; args = @()
        }
        $job = @{
            id = $record.publisher.jobId.value
            tags = @{ bootstrapOwnershipId = $record.context.deploymentOwnershipId; bootstrapSourceFingerprint = $record.context.sourceFingerprint }
            identity = @{ type = 'SystemAssigned,UserAssigned'; principalId = $principal; userAssignedIdentities = @{ $foundation.runtimeImagePullIdentityId = @{} } }
            properties = @{
                environmentId = $foundation.containerAppsEnvironmentId
                configuration = @{
                    triggerType = 'Manual'; replicaRetryLimit = 0; replicaTimeout = 660
                    manualTriggerConfig = @{ parallelism = 1; replicaCompletionCount = 1 }
                    secrets = @()
                    registries = @(@{ server = $foundation.acrLoginServer; identity = $foundation.runtimeImagePullIdentityId })
                    identitySettings = @(@{ identity = 'system'; lifecycle = 'Main' }, @{ identity = $foundation.runtimeImagePullIdentityId; lifecycle = 'None' })
                }
                template = @{ containers = @($container); volumes = @(); initContainers = $null }
            }
        }
        $executionContainer = @{
            name = $container.name; image = $container.image; resources = @{ cpu = 0.5; memory = '1Gi' }
            env = @($values.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value } })
        }
        $fixture = @{
            subscription = $subscription; tenant = $tenant; job = $job
            roles = @(@{ principalId = $principal; scope = $record.host.packageContainerId.value; roleDefinitionId = "$scope/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe" })
            execution = @{ name = 'exact-execution'; properties = @{ status = 'Succeeded'; template = @{ containers = @($executionContainer); initContainers = @() } } }
        }
        [IO.File]::WriteAllText($env:A365GW_PUBLISHER_TEST_CALLS, '')
        $env:PATH = $native
        if ($IsWindows) { $env:PATH += ";$env:SystemRoot\System32" }
        (Get-Command az -ErrorAction Stop).Source | Should -BeExactly $nativeCommand
        Set-BootstrapAzureSubscriptionContext -SubscriptionId $subscription -TenantId $tenant
        $script:publisherHttp = [pscustomobject]@{}
        $script:publisherHttp | Add-Member -MemberType ScriptMethod -Name SendAsync -Value {
            param($Request, $CompletionOption)
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
            $response.Content = [Net.Http.StringContent]::new('{"value":[]}')
            $task = [Threading.Tasks.TaskCompletionSource[Net.Http.HttpResponseMessage]]::new()
            $task.SetResult($response)
            return $task.Task
        }
        Mock -ModuleName Common Get-BootstrapGraphHttpClient { $script:publisherHttp }
    }
    AfterEach {
        foreach ($line in Get-Content $env:A365GW_PUBLISHER_TEST_CALLS) {
            $call = @(ConvertFrom-Json $line)
            ($call -join ' ') | Should -Not -Match 'listSecrets|secret list|job start|rest|--show-values'
            @($call | Where-Object { $_ -ceq '--subscription' }).Count | Should -Be 1
            $call[[array]::IndexOf($call, '--subscription') + 1] | Should -BeExactly $subscription
        }
        $env:PATH = $originalPath
        Clear-BootstrapAzureSubscriptionContext
    }

    It 'accepts the exact publisher and explicit <Shape> no-secret metadata' -ForEach @(
        @{ Shape = 'null' }, @{ Shape = 'empty array' }
    ) {
        if ($Shape -eq 'null') { $job.properties.configuration.secrets = $null }
        (Assert-PublisherFixture).containers[0].name | Should -BeExactly 'purview-package-publisher'
        $record.operations.Count | Should -Be 0
    }

    It 'rejects unknown or nonempty secret metadata: <Shape>' -ForEach @(
        @{ Shape = 'missing' }, @{ Shape = 'object' }, @{ Shape = 'string' }, @{ Shape = 'false' },
        @{ Shape = 'number' }, @{ Shape = 'null entry' }, @{ Shape = 'named entry' }
    ) {
        switch ($Shape) {
            'missing' { $job.properties.configuration.Remove('secrets') }
            'object' { $job.properties.configuration.secrets = @{} }
            'string' { $job.properties.configuration.secrets = '' }
            'false' { $job.properties.configuration.secrets = $false }
            'number' { $job.properties.configuration.secrets = 0 }
            'null entry' { $job.properties.configuration.secrets = @($null) }
            'named entry' { $job.properties.configuration.secrets = @(@{ name = 'unapproved' }) }
        }
        { Assert-PublisherFixture } | Should -Throw
        @(Get-Content $env:A365GW_PUBLISHER_TEST_CALLS).Count | Should -Be 1
    }

    It 'accepts case-only ARM normalization for <Field>, without changing retained evidence' -ForEach @(
        @{ Field = 'UAMI map' }, @{ Field = 'registry' }, @{ Field = 'lifecycle' }, @{ Field = 'environment' }, @{ Field = 'all' }
    ) {
        $lower = $foundation.runtimeImagePullIdentityId.ToLowerInvariant()
        if ($Field -in @('UAMI map', 'all')) { $job.identity.userAssignedIdentities = @{ $lower = @{} } }
        if ($Field -in @('registry', 'all')) { $job.properties.configuration.registries[0].identity = $lower }
        if ($Field -in @('lifecycle', 'all')) { $job.properties.configuration.identitySettings[1].identity = $lower }
        if ($Field -in @('environment', 'all')) { $job.properties.environmentId = $foundation.containerAppsEnvironmentId.ToLowerInvariant() }
        $before = Get-BootstrapObjectFingerprint -InputObject $record
        $null = Assert-PublisherFixture
        (Get-BootstrapObjectFingerprint -InputObject $record) | Should -BeExactly $before
    }

    It 'accepts the actual combined null/case-only shape and reversed identity collection order' {
        $lower = $foundation.runtimeImagePullIdentityId.ToLowerInvariant()
        $job.properties.configuration.secrets = $null
        $job.identity.userAssignedIdentities = @{ $lower = @{} }
        $job.properties.configuration.registries[0].identity = $lower
        $job.properties.configuration.identitySettings = @(@{ identity = $lower; lifecycle = 'None' }, @{ identity = 'system'; lifecycle = 'Main' })
        $null = Assert-PublisherFixture
    }

    It 'rejects a wrong <Field> ARM relationship, even with a valid resource-ID shape' -ForEach @(
        @{ Field = 'UAMI map' }, @{ Field = 'registry' }, @{ Field = 'lifecycle' }, @{ Field = 'environment' }
    ) {
        $wrong = $foundation.runtimeImagePullIdentityId.Replace('/rg-publisher/', '/rg-other/')
        switch ($Field) {
            'UAMI map' { $job.identity.userAssignedIdentities = @{ $wrong = @{} } }
            'registry' { $job.properties.configuration.registries[0].identity = $wrong }
            'lifecycle' { $job.properties.configuration.identitySettings[1].identity = $wrong }
            'environment' { $job.properties.environmentId = $foundation.containerAppsEnvironmentId.Replace('/rg-publisher/', '/rg-other/') }
        }
        { Assert-PublisherFixture } | Should -Throw
    }

    It 'rejects missing/extra/duplicate identity or lifecycle data: <Fault>' -ForEach @(
        @{ Fault = 'empty UAMI' }, @{ Fault = 'duplicate UAMI' }, @{ Fault = 'wrong identity' },
        @{ Fault = 'missing lifecycle' }, @{ Fault = 'wrong lifecycle' }, @{ Fault = 'extra lifecycle property' },
        @{ Fault = 'duplicate lifecycle identity' }, @{ Fault = 'missing system' }, @{ Fault = 'wrong system casing' },
        @{ Fault = 'registry password reference' }, @{ Fault = 'registry username' }
    ) {
        switch ($Fault) {
            'empty UAMI' { $job.identity.userAssignedIdentities = @{} }
            'duplicate UAMI' {
                $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
                $map.Add($foundation.runtimeImagePullIdentityId, @{})
                $map.Add($foundation.runtimeImagePullIdentityId.ToLowerInvariant(), @{})
                $job.identity.userAssignedIdentities = $map
            }
            'wrong identity' { $job.properties.configuration.identitySettings[1].identity += '-other' }
            'missing lifecycle' { $job.properties.configuration.identitySettings[1].Remove('lifecycle') }
            'wrong lifecycle' { $job.properties.configuration.identitySettings[1].lifecycle = 'Main' }
            'extra lifecycle property' { $job.properties.configuration.identitySettings[1].extra = $true }
            'duplicate lifecycle identity' { $job.properties.configuration.identitySettings += @{ identity = $foundation.runtimeImagePullIdentityId.ToLowerInvariant(); lifecycle = 'None' } }
            'missing system' { $job.properties.configuration.identitySettings = @($job.properties.configuration.identitySettings[1]) }
            'wrong system casing' { $job.properties.configuration.identitySettings[0].identity = 'System' }
            'registry password reference' { $job.properties.configuration.registries[0].passwordSecretRef = 'unapproved-reference' }
            'registry username' { $job.properties.configuration.registries[0].username = 'unapproved-name' }
        }
        { Assert-PublisherFixture } | Should -Throw
    }

    It 'does not case-normalize <Field> immutable or directory evidence' -ForEach @(
        @{ Field = 'source' }, @{ Field = 'Graph principal' }, @{ Field = 'image' }, @{ Field = 'environment hash' }
    ) {
        switch ($Field) {
            'source' { $job.tags.bootstrapSourceFingerprint = $record.context.sourceFingerprint.ToUpperInvariant() }
            'Graph principal' { $job.identity.principalId = $principal.ToUpperInvariant() }
            'image' { $job.properties.template.containers[0].image = $record.publisher.publisherImage.value.ToUpperInvariant() }
            'environment hash' { ($job.properties.template.containers[0].env | Where-Object name -eq 'PUBLISHER_EXECUTION_SOURCE_FINGERPRINT').value = $record.context.sourceFingerprint.ToUpperInvariant() }
        }
        { Assert-PublisherFixture } | Should -Throw
    }

    It 'reconciles the documented execution template shape read-only, without persisting normalized intent' {
        $null = Assert-PublisherFixture
        (Invoke-PublisherReadOnlyFixture).name | Should -BeExactly 'exact-execution'
    }

    It 'normalizes only documented empty optional fields, with <Shape> job metadata' -ForEach @(
        @{ Shape = 'missing' }, @{ Shape = 'null' }, @{ Shape = 'empty array' }
    ) {
        foreach ($name in @('command', 'args', 'volumeMounts', 'probes')) {
            switch ($Shape) {
                'missing' { $container.Remove($name) }
                'null' { $container[$name] = $null }
                'empty array' { $container[$name] = @() }
            }
        }
        $container.resources.ephemeralStorage = $null
        $fixture.execution.properties.template.containers[0].env =
            @($fixture.execution.properties.template.containers[0].env | Sort-Object name -Descending)
        $null = Assert-PublisherFixture
        (Invoke-PublisherReadOnlyFixture).name | Should -BeExactly 'exact-execution'
    }

    It 'rejects malformed or unverifiable template metadata: <Fault>' -ForEach @(
        @{ Fault = 'scalar optional array' }, @{ Fault = 'false optional array' },
        @{ Fault = 'missing env value' }, @{ Fault = 'duplicate env' }, @{ Fault = 'extra env property' },
        @{ Fault = 'CPU string' }, @{ Fault = 'missing memory' }, @{ Fault = 'unknown resource field' },
        @{ Fault = 'nonnull ephemeral mismatch' }, @{ Fault = 'unreviewed execution volumes' }
    ) {
        $c = $fixture.execution.properties.template.containers[0]
        switch ($Fault) {
            'scalar optional array' { $c.args = '' }
            'false optional array' { $c.command = $false }
            'missing env value' { $c.env[0].Remove('value') }
            'duplicate env' { $c.env += $c.env[0] }
            'extra env property' { $c.env[0].extra = 'unapproved' }
            'CPU string' { $c.resources.cpu = '0.5' }
            'missing memory' { $c.resources.Remove('memory') }
            'unknown resource field' { $c.resources.extra = $true }
            'nonnull ephemeral mismatch' { $container.resources.ephemeralStorage = '1Gi' }
            'unreviewed execution volumes' { $fixture.execution.properties.template.volumes = @() }
        }
        { Invoke-PublisherReadOnlyFixture } | Should -Throw
    }

    It 'rejects nonempty or unknown job-only template data before execution projection: <Field>' -ForEach @(
        @{ Field = 'probes' }, @{ Field = 'volumeMounts' }, @{ Field = 'command' }, @{ Field = 'args' }, @{ Field = 'unknown' }
    ) {
        $job.properties.template.containers[0][$Field] = @(@{ unexpected = $true })
        { Assert-PublisherFixture } | Should -Throw
    }

    It 'does not hide execution-template drift in <Field>' -ForEach @(
        @{ Field = 'image' }, @{ Field = 'source hash' }, @{ Field = 'secret reference' }, @{ Field = 'command' },
        @{ Field = 'resource memory' }, @{ Field = 'extra environment' }, @{ Field = 'unknown field' }, @{ Field = 'extra container' }
    ) {
        $c = $fixture.execution.properties.template.containers[0]
        switch ($Field) {
            'image' { $c.image += '-other' }
            'source hash' { ($c.env | Where-Object name -eq 'PUBLISHER_EXECUTION_SOURCE_FINGERPRINT').value = $record.context.sourceFingerprint.ToUpperInvariant() }
            'secret reference' { $c.env[0].secretRef = 'unapproved-reference' }
            'command' { $c.command = @('override') }
            'resource memory' { $c.resources.memory = '2Gi' }
            'extra environment' { $c.env += @{ name = 'EXTRA'; value = 'unapproved' } }
            'unknown field' { $c.extra = $true }
            'extra container' { $fixture.execution.properties.template.containers += $c }
        }
        { Invoke-PublisherReadOnlyFixture } | Should -Throw
    }
}
