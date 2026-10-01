#Requires -Version 7.0
<#
.SYNOPSIS
Builds a new, uniquely owned source snapshot of the production UI and browser host.
.DESCRIPTION
No baseline suite, production settings, launch profile, database or provider is used.
Build-only keeps its printed .work directory so the browser harness can run its DLL.
-Verify also checks host HTTP rendering/control/assets and removes its workspace.
-Verify -KeepBuild leaves that verified snapshot for a later Chrome harness.
Stop the printed DLL's process before deleting its entire printed workspace.
#>
[CmdletBinding()]
param(
    [switch] $Verify,
    [switch] $KeepBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$workspace = Join-Path $PSScriptRoot ('.work\browser-host-' + [Guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $workspace 'source'
$process = $null
$succeeded = $false
$checks = 0

function Assert-Condition([bool] $Condition, [string] $Description) {
    if (-not $Condition) { throw "Browser host verification failed: $Description" }
    $script:checks++
}

try {
    New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($rootFile in @('Directory.Build.props', 'global.json', 'nuget.config')) {
        $paths.Add((Join-Path $repository $rootFile))
    }
    foreach ($sourceDirectory in @('src\Gateway.Contracts', 'src\Gateway.AdminUi', 'tests\Gateway.AdminUi.BrowserHost')) {
        Get-ChildItem -LiteralPath (Join-Path $repository $sourceDirectory) -File -Recurse |
            Where-Object {
                $_.FullName -notmatch '[\\/](bin|obj|\.work|\.git)[\\/]' -and
                $_.Extension -in @('.cs', '.csproj', '.razor', '.css', '.js', '.png', '.svg', '.ico', '.woff', '.woff2', '.ps1')
            } | ForEach-Object { $paths.Add($_.FullName) }
    }
    $paths.Add((Join-Path $repository 'src\Gateway.Purview\Automation\Connect-PurviewTenant.ps1'))
    $paths.Add((Join-Path $repository 'src\Gateway.Application\Agents\Queries\ListAgentsCursor.cs'))
    $inputs = foreach ($path in ($paths | Sort-Object -Unique)) {
        $relative = [IO.Path]::GetRelativePath($repository, $path)
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $destination = Join-Path $sourceRoot $relative
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
        Copy-Item -LiteralPath $path -Destination $destination
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $hash) {
            throw "Authored input changed during copy: $relative. Re-run to capture a coherent snapshot."
        }
        [ordered]@{ path = $relative; sha256 = $hash }
    }
    $sourceManifest = Join-Path $workspace 'source-inputs.json'
    $inputs | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sourceManifest -Encoding utf8
    $sourceFingerprint = (Get-FileHash -LiteralPath $sourceManifest -Algorithm SHA256).Hash
    $project = Join-Path $sourceRoot 'tests\Gateway.AdminUi.BrowserHost\Gateway.AdminUi.BrowserHost.csproj'
    $dotnet = (Get-Command dotnet -ErrorAction Stop).Source
    & $dotnet build $project --configuration Release --nologo --verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw "Fresh source build failed ($LASTEXITCODE)." }
    $dll = Join-Path $sourceRoot 'tests\Gateway.AdminUi.BrowserHost\bin\Release\net10.0\Gateway.AdminUi.BrowserHost.dll'
    & $dotnet $dll --self-test
    if ($LASTEXITCODE -ne 0) { throw "Browser fixture self-tests failed ($LASTEXITCODE)." }

    if ($Verify) {
        $start = [Diagnostics.ProcessStartInfo]::new($dotnet)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.WorkingDirectory = $sourceRoot
        $start.ArgumentList.Add($dll)
        $start.ArgumentList.Add('--port')
        $start.ArgumentList.Add('0')
        $start.ArgumentList.Add('--mutation-delay-ms')
        $start.ArgumentList.Add('0')
        $start.Environment.Clear()
        foreach ($name in @('SystemRoot', 'WINDIR', 'PATH')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if ($value) { $start.Environment[$name] = $value }
        }
        # Deliberately hostile, non-secret settings prove the empty builder does
        # not bind ambient host URLs or downstream configuration.
        $start.Environment['ASPNETCORE_URLS'] = 'http://0.0.0.0:45678'
        $start.Environment['GatewayApi__BaseUrl'] = 'https://must-not-be-used.browser-fixture.invalid/'
        $start.Environment['ASPNETCORE_ENVIRONMENT'] = 'Development'
        $process = [Diagnostics.Process]::Start($start)
        $stderr = $process.StandardError.ReadToEndAsync()
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        $ready = $null
        $lineTask = $process.StandardOutput.ReadLineAsync()
        while ([DateTime]::UtcNow -lt $deadline -and -not $ready) {
            if ($lineTask.Wait(250)) {
                $line = $lineTask.Result
                if ($line -and $line.StartsWith('BROWSER_FIXTURE_READY ', [StringComparison]::Ordinal)) {
                    $ready = $line.Substring('BROWSER_FIXTURE_READY '.Length) | ConvertFrom-Json
                    break
                }
                if ($process.HasExited) { throw "Browser host exited before readiness: $($stderr.Result)" }
                $lineTask = $process.StandardOutput.ReadLineAsync()
            }
        }
        Assert-Condition ($null -ne $ready) 'bounded startup returned readiness'
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $baseUrl = $ready.url
        Assert-Condition (([Uri]$baseUrl).Host -eq '127.0.0.1' -and ([Uri]$baseUrl).Port -ne 45678) 'loopback ignores ambient URL configuration'
        $health = Invoke-RestMethod -Uri "$baseUrl/__fixture/health"
        Assert-Condition ($health.status -eq 'ready' -and $health.componentAssembly -eq 'Gateway.AdminUi') 'production component assembly is loaded'
        Assert-Condition (@($health.configurationSources | Where-Object { $_ -ne 'MemoryConfigurationSource' }).Count -eq 0) 'no environment/JSON/user-secrets configuration source'
        Assert-Condition ($health.gatewayApiBaseUrl -eq 'https://gateway.browser-fixture.invalid/') 'Gateway options ignore ambient downstream configuration'
        $root = Invoke-WebRequest -Uri "$baseUrl/"
        Assert-Condition ($root.StatusCode -eq 200 -and $root.Content.Contains('Registered agents')) 'real Home component renders'
        foreach ($metric in @(@('registered', '237'), @('active', '177'), @('action-required', '30'))) {
            $pattern = 'data-count="' + $metric[0] + '"[^>]*>.*?<strong[^>]*class="metric-value"[^>]*>([^<]+)</strong>'
            $value = [regex]::Match($root.Content, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline).Groups[1].Value
            Assert-Condition ($value -eq $metric[1]) "production overview reads authoritative $($metric[0]) total"
        }
        $setup = Invoke-WebRequest -Uri "$baseUrl/setup"
        Assert-Condition ($setup.StatusCode -eq 200 -and $setup.Content.Contains('Getting started')) 'real SetupCenter component renders'
        $list = Invoke-WebRequest -Uri "$baseUrl/agents"
        Assert-Condition ($list.StatusCode -eq 200 -and $list.Content.Contains('Synthetic agent 001')) 'real agent list consumes synthetic DTOs'
        $filtered = Invoke-WebRequest -Uri "$baseUrl/agents?search=invoice-eu&status=Active&environment=Development"
        Assert-Condition ($filtered.StatusCode -eq 200 -and $filtered.Content.Contains('of 137 matching agents')) 'production query route reports 137 combined matches within the 237-agent fleet'
        $registration = Invoke-WebRequest -Uri "$baseUrl/agents/register"
        Assert-Condition ($registration.StatusCode -eq 200 -and $registration.Content.Contains('Compatible synthetic blueprint')) 'real registration renders blueprint inventory'
        $state = Invoke-RestMethod -Uri "$baseUrl/__fixture/state"
        $details = Invoke-WebRequest -Uri "$baseUrl/agents/$($state.fixture.primaryAgentId)"
        Assert-Condition ($details.StatusCode -eq 200 -and $details.Content.Contains('fixture-agent-001')) 'real details component renders'
        $recovery = Invoke-WebRequest -Uri "$baseUrl/agents/register?pendingExternalId=fixture-agent-001"
        Assert-Condition ($recovery.StatusCode -eq 200 -and $recovery.Content.Contains('Check existing registration')) 'pending external ID opens production lookup-only recovery'
        Assert-Condition (-not $recovery.Content.Contains('id="registration-form"')) 'lookup-only recovery omits the registration form'
        $state = Invoke-RestMethod -Uri "$baseUrl/__fixture/state"
        Assert-Condition (-not $state.fixture.counters.PSObject.Properties['RegisterAgentAsync']) 'recovery rendering never dispatches registration'

        $assets = [regex]::Matches($root.Content, '(?:src|href)="([^"]+)"') |
            ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) } |
            Where-Object { $_ -match '\.(css|js)(\?|$)' } | Sort-Object -Unique
        Assert-Condition (@($assets).Count -ge 6) 'production root references CSS, Fluent UI and Blazor assets'
        foreach ($asset in $assets) {
            $uri = [Uri]::new([Uri]"$baseUrl/", $asset)
            Assert-Condition ($uri.Host -eq '127.0.0.1' -and $uri.Port -eq ([Uri]$baseUrl).Port) "asset is local: $asset"
            $response = Invoke-WebRequest -Uri $uri
            Assert-Condition ($response.StatusCode -eq 200 -and $response.RawContentLength -gt 30) "asset is served: $asset"
            Assert-Condition (-not $response.Headers['Content-Type'].ToString().StartsWith('text/html')) "asset is not a fallback HTML page: $asset"
        }
        $productionCss = Get-Content -LiteralPath (Join-Path $sourceRoot 'src\Gateway.AdminUi\wwwroot\app.css') -Raw
        $servedCss = (Invoke-WebRequest -Uri "$baseUrl/app.css").Content
        Assert-Condition ($servedCss -eq $productionCss) 'served CSS exactly matches fresh production input'
        $blazor = Invoke-WebRequest -Uri "$baseUrl/_framework/blazor.web.js"
        Assert-Condition ($blazor.RawContentLength -gt 100000) 'real Blazor runtime is served'
        $notStatic = Invoke-WebRequest -Uri "$baseUrl/appsettings.json" -SkipHttpErrorCheck
        Assert-Condition ($notStatic.StatusCode -eq 404) 'production configuration is not a served asset'
        $notAnApi = Invoke-WebRequest -Uri "$baseUrl/api/v1/agents" -SkipHttpErrorCheck
        Assert-Condition ($notAnApi.StatusCode -eq 404) 'unknown HTTP paths do not proxy to a Gateway'
        $state = Invoke-RestMethod -Uri "$baseUrl/__fixture/state"
        Assert-Condition (@($state.fixture.unexpectedCalls).Count -eq 0) 'administrator rendering made no unscripted API calls'

        $headers = @{ 'X-Browser-Fixture' = '1' }
        $resetBody = @{ scenario = 'empty'; role = 'Administrator'; mutationDelayMs = 0 } | ConvertTo-Json
        $denied = Invoke-WebRequest -Uri "$baseUrl/__fixture/reset" -Method Post -ContentType 'application/json' -Body $resetBody -SkipHttpErrorCheck
        Assert-Condition ($denied.StatusCode -eq 403) 'control rejects missing driver header'
        $foreignHeaders = @{ 'X-Browser-Fixture' = '1'; Origin = 'https://foreign.browser-fixture.invalid' }
        $denied = Invoke-WebRequest -Uri "$baseUrl/__fixture/reset" -Method Post -Headers $foreignHeaders -ContentType 'application/json' -Body $resetBody -SkipHttpErrorCheck
        Assert-Condition ($denied.StatusCode -eq 403) 'control rejects foreign Origin'
        $foreignHost = Invoke-WebRequest -Uri "$baseUrl/__fixture/health" -Headers @{ Host = 'foreign.browser-fixture.invalid' } -SkipHttpErrorCheck
        Assert-Condition ($foreignHost.StatusCode -eq 403) 'host rejects DNS-rebinding Host'
        Invoke-RestMethod -Uri "$baseUrl/__fixture/reset" -Method Post -Headers $headers -ContentType 'application/json' -Body $resetBody | Out-Null
        $empty = Invoke-WebRequest -Uri "$baseUrl/agents"
        Assert-Condition ($empty.Content.Contains('No agents registered')) 'reset renders the real empty state'
        $badControl = Invoke-WebRequest -Uri "$baseUrl/__fixture/read-errors" -Method Post -Headers $headers -ContentType 'application/json' -Body '{"methods":["RegisterAgentAsync"]}' -SkipHttpErrorCheck
        Assert-Condition ($badControl.StatusCode -eq 400) 'unsupported control operation is rejected'
        $manual = Invoke-RestMethod -Uri "$baseUrl/__fixture/reset" -Method Post -Headers $headers -ContentType 'application/json' -Body '{"scenario":"operation-manual","role":"Administrator","mutationDelayMs":0}'
        foreach ($visit in 1..2) {
            $operation = Invoke-WebRequest -Uri "$baseUrl/operations/$($manual.primaryOperationId)"
            Assert-Condition ($operation.StatusCode -eq 200 -and $operation.Content.Contains('Synthetic agent 001')) "operation context renders on direct/reopened visit $visit"
        }
        $state = Invoke-RestMethod -Uri "$baseUrl/__fixture/state"
        Assert-Condition ($state.fixture.counters.GetOperationStatusAsync -eq 2 -and $state.fixture.counters.GetAgentAsync -eq 2) 'each operation document reads its bound context once'
        Assert-Condition (-not $state.fixture.counters.PSObject.Properties['CompleteAgent365RegistrationAsync']) 'direct/reopened operation never manufactures an automatic permit'
        Assert-Condition (@($state.fixture.unexpectedCalls).Count -eq 0) 'operation rendering uses only supported interface methods'
        Invoke-RestMethod -Uri "$baseUrl/__fixture/operation" -Method Post -Headers $headers -ContentType 'application/json' -Body '{"status":"Completed","available":false}' | Out-Null
        $completed = Invoke-WebRequest -Uri "$baseUrl/operations/$($manual.primaryOperationId)"
        Assert-Condition ($completed.StatusCode -eq 200 -and $completed.Content.Contains('This setup operation completed.')) 'control advancement renders final operation state'
        Invoke-RestMethod -Uri "$baseUrl/__fixture/reset" -Method Post -Headers $headers -ContentType 'application/json' -Body '{"scenario":"fleet","role":"SupportReader","mutationDelayMs":0}' | Out-Null
        $reader = Invoke-WebRequest -Uri "$baseUrl/setup"
        Assert-Condition ($reader.Content.Contains('SupportReader') -and -not $reader.Content.Contains('href="/agents/register"')) 'synthetic reader respects production navigation visibility'
        $restricted = Invoke-WebRequest -Uri "$baseUrl/agents/register" -SkipHttpErrorCheck
        Assert-Condition ($restricted.StatusCode -eq 403) 'server route authorization rejects restricted role'
        $signIn = Invoke-WebRequest -Uri "$baseUrl/authentication/login" -SkipHttpErrorCheck
        Assert-Condition ($signIn.StatusCode -eq 409 -and -not $signIn.Headers.ContainsKey('Location')) 'sign-in is terminal and never redirects externally'
        $state = Invoke-RestMethod -Uri "$baseUrl/__fixture/state"
        Assert-Condition (@($state.fixture.unexpectedCalls).Count -eq 0) 'rendering made no unscripted API calls'
        Assert-Condition ($state.guards.httpAttempts -eq 0 -and $state.guards.clientFactoryAttempts -eq 0 -and
            $state.guards.tokenAttempts -eq 0 -and $state.guards.runtimeAttempts -eq 0) 'rendering attempted no provider transport/authentication'
        Write-Output "BROWSER_FIXTURE_HTTP_VERIFICATION passed=$checks; failed=0; browserInteraction=not-run"
    }
    $succeeded = $true
    Write-Output ('BROWSER_FIXTURE_BUILD_READY ' + ([ordered]@{
        workspace = $workspace
        sourceRoot = $sourceRoot
        dll = $dll
        sourceFingerprint = $sourceFingerprint
        sourceManifest = $sourceManifest
        retained = (-not $Verify -or $KeepBuild.IsPresent)
    } | ConvertTo-Json -Compress))
}
finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }
    if (-not $succeeded -or ($Verify -and -not $KeepBuild)) {
        if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force }
    }
}
