#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [Parameter(Mandatory)][string]$ExpectedSourceFingerprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The packaged Windows runtime requires a Windows qualification host.' }
$repository = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repository 'tools\LocalBaseline.psm1') -Force
Import-Module (Join-Path $repository 'bootstrap\modules\Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $repository 'bootstrap\modules\PurviewPackage.psm1') -Force -DisableNameChecking
$package = Read-PurviewExecutorPackage -PackageDirectory $PackageDirectory -ExpectedSourceFingerprint $ExpectedSourceFingerprint
$runName = "m1-$([guid]::NewGuid().ToString('N'))"
$workspace = Join-Path $repository ".test-work\$runName"
Assert-LocalBaselineUnlinkedPath -Path $workspace -Root $repository
if (Test-Path -LiteralPath $workspace) { throw 'The Windows package qualification directory must be new.' }
[IO.Directory]::CreateDirectory($workspace) | Out-Null
[IO.File]::WriteAllText((Join-Path $workspace '.local-baseline-owner'), $runName)
$root = Join-Path $workspace 'package'
$profile = Join-Path $workspace 'profile'
$hostProcess = $null
$client = $null
$failure = $null

function New-OfflinePackageProcess {
    param([Parameter(Mandatory)][string]$Executable)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $root $Executable
    $start.WorkingDirectory = $root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment.Clear()
    foreach ($name in @('SystemRoot', 'SystemDrive', 'windir', 'ProgramData', 'ProgramFiles',
        'ProgramFiles(x86)', 'CommonProgramFiles', 'CommonProgramFiles(x86)', 'OS', 'PATHEXT')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $start.Environment[$name] = $value }
    }
    $start.Environment['PATH'] = (Join-Path $root 'PowerShell') + ';' + (Join-Path $env:SystemRoot 'System32')
    $start.Environment['USERPROFILE'] = $profile
    $start.Environment['TEMP'] = Join-Path $profile 'Temp'
    $start.Environment['TMP'] = Join-Path $profile 'Temp'
    $start.Environment['LOCALAPPDATA'] = Join-Path $profile 'AppData\Local'
    $start.Environment['APPDATA'] = Join-Path $profile 'AppData\Roaming'
    $start.Environment['AZURE_CONFIG_DIR'] = Join-Path $profile 'no-azure-session'
    $start.Environment['AZD_CONFIG_DIR'] = Join-Path $profile 'no-azd-session'
    $start.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
    $start.Environment['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
    $start.Environment['DOTNET_ENVIRONMENT'] = 'Production'
    $start.Environment['ASPNETCORE_ENVIRONMENT'] = 'Production'
    return $start
}

function Test-OfflineChild {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$ExpectedExitCode,
        [Parameter()][AllowEmptyString()][string]$ExpectedOutput = '',
        [Parameter()][AllowEmptyString()][string]$ExpectedError = ''
    )
    $start = New-OfflinePackageProcess -Executable 'Gateway.Purview.PowerShellHost.exe'
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { throw 'The owned Windows child exceeded its 60-second limit.' }
        if ($process.ExitCode -ne $ExpectedExitCode -or
            $stdout.GetAwaiter().GetResult() -cne $ExpectedOutput -or
            $stderr.GetAwaiter().GetResult().TrimEnd("`r", "`n") -cne $ExpectedError) {
            throw "Windows child qualification failed: expected exit $ExpectedExitCode; actual exit $($process.ExitCode). Output withheld."
        }
    }
    finally {
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

try {
    [IO.Compression.ZipFile]::ExtractToDirectory($package.packagePath, $root)
    foreach ($relative in @('Temp', 'AppData\Local', 'AppData\Roaming')) {
        [IO.Directory]::CreateDirectory((Join-Path $profile $relative)) | Out-Null
    }
    $digest = [string]$package.receipt.runtimeManifestDigest
    Test-OfflineChild -Arguments @('--manifest', $digest, '--probe') -ExpectedExitCode 0 -ExpectedOutput '7.6.5|3.10.1'
    Test-OfflineChild -Arguments @('--manifest', ('sha256:' + ('0' * 64)), '--probe') -ExpectedExitCode 65 -ExpectedError 'PURVIEW_CHILD_FAILED'
    Test-OfflineChild -Arguments @('--manifest', 'unbound-fixture', '--probe') -ExpectedExitCode 64 -ExpectedError 'PURVIEW_CHILD_FAILED'
    Test-OfflineChild -Arguments @('--manifest', $digest, '--script', 'not-an-approved-script.ps1') -ExpectedExitCode 66 -ExpectedError 'PURVIEW_CHILD_FAILED'

    $start = New-OfflinePackageProcess -Executable 'Gateway.Purview.Executor.exe'
    $binding = [ordered]@{
        DeploymentOwnershipId = '11111111-1111-4111-8111-111111111111'
        TenantId = '22222222-2222-4222-8222-222222222222'
        BootstrapSourceFingerprint = $ExpectedSourceFingerprint
        ExecutionSourceFingerprint = $ExpectedSourceFingerprint
        PackageDigest = [string]$package.receipt.packageDigest
        AutomationApplicationId = '33333333-3333-4333-8333-333333333333'
        AutomationServicePrincipalObjectId = '44444444-4444-4444-8444-444444444444'
        KeyVaultResourceId = '/subscriptions/55555555-5555-4555-8555-555555555555/resourceGroups/rg-offline-fixture/providers/Microsoft.KeyVault/vaults/fixture-vault'
        CertificateName = 'fixture-certificate'
        CertificateSecretUri = 'https://fixture-vault.vault.azure.net/secrets/fixture-certificate'
        GatewayApiPrincipalId = '66666666-6666-4666-8666-666666666666'
        GatewayWorkerPrincipalId = '77777777-7777-4777-8777-777777777777'
        RuntimeClientId = '88888888-8888-4888-8888-888888888888'
        RuntimePrincipalId = '99999999-9999-4999-8999-999999999999'
        ExecutorApplicationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        ExecutorPrincipalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        CallerApplicationId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    }
    foreach ($key in $binding.Keys) { $start.Environment["Executor__Binding__$key"] = [string]$binding[$key] }
    $start.Environment['Executor__RuntimeManifestDigest'] = $digest
    $start.Environment['Executor__ClaimsContainerUri'] = 'https://fixturestorage.blob.core.windows.net/purview-executor-claims'
    $start.Environment['Purview__PolicyProvisioningEnabled'] = 'true'
    $start.Environment['Purview__PolicyProvisioningApplicationId'] = [string]$binding.AutomationApplicationId
    $start.Environment['Purview__PolicyProvisioningCertificateSecretUri'] = [string]$binding.CertificateSecretUri
    $reservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $reservation.Start()
    $port = ([Net.IPEndPoint]$reservation.LocalEndpoint).Port
    $reservation.Stop()
    $start.Environment['ASPNETCORE_URLS'] = "http://127.0.0.1:$port"
    $hostProcess = [Diagnostics.Process]::Start($start)
    $hostOutput = $hostProcess.StandardOutput.ReadToEndAsync()
    $hostError = $hostProcess.StandardError.ReadToEndAsync()
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(90)
    $ready = $false
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ($hostProcess.HasExited) { throw "The packaged executor stopped during startup (exit $($hostProcess.ExitCode)); output withheld." }
        try {
            $response = $client.GetAsync("http://127.0.0.1:$port/health/ready").GetAwaiter().GetResult()
            try {
                if ([int]$response.StatusCode -ne 401) { throw 'The packaged executor exposed health without authentication.' }
                $ready = $true
                break
            }
            finally { $response.Dispose() }
        }
        catch [Net.Http.HttpRequestException] {
            Start-Sleep -Milliseconds 100
        }
        catch [Threading.Tasks.TaskCanceledException] {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $ready) { throw 'The packaged executor did not become responsive within 90 seconds.' }
    $ownedListeners = @(Get-NetTCPConnection -OwningProcess $hostProcess.Id -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalAddress -ceq '127.0.0.1' -and $_.LocalPort -eq $port })
    if ($ownedListeners.Count -ne 1) { throw 'The test endpoint is not owned by the packaged executor process.' }
    # No token or provider command is supplied. Authorization must stop this at the host boundary.
    $body = [Net.Http.StringContent]::new('{}', [Text.Encoding]::UTF8, 'application/json')
    try {
        $response = $client.PostAsync("http://127.0.0.1:$port/executor/v1/execute", $body).GetAwaiter().GetResult()
        try {
            if ([int]$response.StatusCode -ne 401) { throw 'The packaged executor admitted an unauthenticated execution request.' }
        }
        finally { $response.Dispose() }
    }
    finally { $body.Dispose() }
    [pscustomobject]@{
        checks = 6
        sourceFingerprint = $ExpectedSourceFingerprint
        packageDigest = [string]$package.receipt.packageDigest
        runtimeManifestDigest = $digest
        boundary = 'Local Windows package only; no authenticated provider or hosted acceptance'
    }
}
catch {
    $failure = $_
    throw
}
finally {
    if ($null -ne $client) { $client.Dispose() }
    if ($null -ne $hostProcess) {
        if (-not $hostProcess.HasExited) { $hostProcess.Kill($true); $hostProcess.WaitForExit() }
        $hostOutput.GetAwaiter().GetResult() | Out-Null
        $hostError.GetAwaiter().GetResult() | Out-Null
        $hostProcess.Dispose()
    }
    try {
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            try {
                Remove-LocalBaselineWorkspace -Workspace $workspace -RepositoryRoot $repository
                break
            }
            catch [UnauthorizedAccessException] {
                if ($attempt -eq 9) { throw }
                Start-Sleep -Milliseconds 500
            }
            catch [IO.IOException] {
                if ($attempt -eq 9) { throw }
                Start-Sleep -Milliseconds 500
            }
        }
    }
    catch {
        if ($null -eq $failure) { throw }
        Write-Warning "Qualification failed and its owned work directory could not be completely removed: $workspace"
    }
}
