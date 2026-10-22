#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Install', 'Status', 'Remove')]
    [string]$Mode = 'Status'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WeatherSampleStartupContext {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$RepositoryRoot = (Join-Path $PSScriptRoot '../../..')
    )

    $root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $sampleDirectory = [IO.Path]::GetFullPath((Join-Path $root 'samples/python-foundry-weather-agent'))
    $pythonw = [IO.Path]::GetFullPath((Join-Path $sampleDirectory '.venv/Scripts/pythonw.exe'))
    $python = [IO.Path]::GetFullPath((Join-Path $sampleDirectory '.venv/Scripts/python.exe'))
    $app = [IO.Path]::GetFullPath((Join-Path $sampleDirectory 'app.py'))
    $environment = [IO.Path]::GetFullPath((Join-Path $sampleDirectory '.env'))
    $canonicalOwner = $root.ToUpperInvariant()
    $ownerHash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonicalOwner))
    ).ToLowerInvariant()
    $taskName = 'A365Gateway-WeatherSample-' + $ownerHash.Substring(0, 16)
    $description = "A365 Gateway weather sample startup; owner=sha256:$ownerHash"
    $argument = '"' + $app + '"'

    foreach ($path in @($root, $sampleDirectory, $pythonw, $python, $app, $environment)) {
        if ($path -match '["\r\n]') { throw 'The checkout path contains characters unsupported by the weather sample supervisor.' }
    }

    [pscustomobject]@{
        RepositoryRoot = $root
        SampleDirectory = $sampleDirectory
        Pythonw = $pythonw
        Python = $python
        App = $app
        Environment = $environment
        TaskName = $taskName
        Description = $description
        Argument = $argument
    }
}

function Get-WeatherSampleCurrentSid {
    [CmdletBinding()]
    param()
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Resolve-WeatherSamplePrincipalSid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserId)

    try {
        ([Security.Principal.NTAccount]$UserId).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        try { ([Security.Principal.SecurityIdentifier]$UserId).Value }
        catch { throw 'The existing weather sample task principal could not be verified; refusing the operation.' }
    }
}

function Assert-OwnedWeatherSampleTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)]$Context,
        [Parameter()][string]$CurrentSid = (Get-WeatherSampleCurrentSid)
    )

    $actions = @($Task.Actions)
    $principalSid = Resolve-WeatherSamplePrincipalSid -UserId ([string]$Task.Principal.UserId)
    $owned = $actions.Count -eq 1 -and
        [IO.Path]::GetFullPath([string]$actions[0].Execute) -ieq $Context.Pythonw -and
        [string]$actions[0].Arguments -ceq $Context.Argument -and
        [IO.Path]::GetFullPath([string]$actions[0].WorkingDirectory) -ieq $Context.SampleDirectory -and
        [string]$Task.Description -ceq $Context.Description -and
        $principalSid -eq $CurrentSid
    if (-not $owned) {
        throw "Scheduled task '$($Context.TaskName)' is not the exact task owned by this checkout; refusing the operation."
    }
}

function Assert-WeatherSampleTaskShape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter()][string]$CurrentSid = (Get-WeatherSampleCurrentSid)
    )

    $triggers = @($Task.Triggers)
    $trigger = if ($triggers.Count -eq 1) { $triggers[0] } else { $null }
    $repetition = if ($null -ne $trigger) { $trigger.Repetition } else { $null }
    $interval = if ($null -ne $repetition) { [string]$repetition.Interval } else { '' }
    $duration = if ($null -ne $repetition) { [string]$repetition.Duration } else { '' }
    $isLogon = $null -ne $trigger -and (
        [string]$trigger.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -or
        [string]$trigger.GetType().Name -match 'LogonTrigger'
    )
    if (-not $isLogon -or $interval -or $duration) {
        throw 'The weather sample task readback is not one non-repeating logon trigger.'
    }
    $triggerSid = Resolve-WeatherSamplePrincipalSid -UserId ([string]$trigger.UserId)
    if ($triggerSid -ne $CurrentSid) {
        throw 'The weather sample task logon trigger does not belong to the current user.'
    }
    if ([string]$Task.Principal.LogonType -ne 'Interactive' -or [string]$Task.Principal.RunLevel -ne 'Limited') {
        throw 'The weather sample task readback does not use the limited interactive principal.'
    }
    $settings = $Task.Settings
    if (-not $settings.StartWhenAvailable -or $settings.DisallowStartIfOnBatteries -or $settings.StopIfGoingOnBatteries -or
        [string]$settings.MultipleInstances -ne 'IgnoreNew' -or [int]$settings.RestartCount -ne 3 -or
        [string]$settings.RestartInterval -ne 'PT1M' -or [string]$settings.ExecutionTimeLimit -ne 'PT0S') {
        throw 'The weather sample task readback does not match the bounded restart and availability contract.'
    }
}

function Invoke-WeatherSampleConfigurationCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    foreach ($required in @($Context.SampleDirectory, $Context.Python, $Context.Pythonw, $Context.App, $Context.Environment)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "Weather sample prerequisite is missing: $required"
        }
    }

    $code = @'
import json
from dotenv import load_dotenv
from weather_agent.config import AppConfig
load_dotenv(dotenv_path=".env", override=False)
config = AppConfig.from_env()
print(json.dumps({"host": config.flask_host, "port": config.flask_port}))
'@
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Context.Python
    $start.WorkingDirectory = $Context.SampleDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.ArgumentList.Add('-c')
    $start.ArgumentList.Add($code)
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEnd()
    $null = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw 'The weather sample virtual environment or .env configuration is invalid. Run app.py interactively to review its safe startup error.'
    }
    try { $result = $stdout.Trim() | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'The weather sample configuration check returned an invalid result.' }
    if ([string]$result.host -notin @('127.0.0.1', '::1', 'localhost') -or
        [int]$result.port -lt 1 -or [int]$result.port -gt 65535) {
        throw 'The weather sample must remain bound to a lexical loopback host and a valid port.'
    }
    $result
}

function Wait-WeatherSampleTaskState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$DesiredState,
        [Parameter()][int]$Seconds = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task -and $DesiredState -eq 'Absent') { return $null }
        if ($null -ne $task -and [string]$task.State -eq $DesiredState) { return $task }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Scheduled task '$TaskName' did not reach $DesiredState within $Seconds seconds."
}

function Wait-WeatherSampleHttpStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter()][int]$Seconds = 20
    )

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(3)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    try {
        do {
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($null -eq $task -or [string]$task.State -ne 'Running') { break }
            try {
                $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
                try {
                    $statusCode = [int]$response.StatusCode
                    if ($statusCode -ge 200 -and $statusCode -lt 300) {
                        return [pscustomobject]@{ Uri = $Uri.AbsoluteUri; StatusCode = $statusCode }
                    }
                }
                finally { $response.Dispose() }
            }
            catch [Net.Http.HttpRequestException] { }
            catch [Threading.Tasks.TaskCanceledException] { }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $deadline)
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    $result = if ($null -ne $info) { [int]$info.LastTaskResult } else { -1 }
    throw "The weather sample did not become reachable at /api/status. Scheduled task result: $result."
}

function Get-WeatherSampleTaskStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $task = Get-ScheduledTask -TaskName $Context.TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return [pscustomobject]@{ TaskName = $Context.TaskName; Installed = $false; State = 'Absent' }
    }
    Assert-OwnedWeatherSampleTask -Task $task -Context $Context
    Assert-WeatherSampleTaskShape -Task $task
    $info = Get-ScheduledTaskInfo -TaskName $Context.TaskName -ErrorAction Stop
    [pscustomobject]@{
        TaskName = $Context.TaskName
        Installed = $true
        State = [string]$task.State
        LastRunTime = $info.LastRunTime
        LastTaskResult = $info.LastTaskResult
        NextRunTime = $info.NextRunTime
        Executable = $Context.Pythonw
        WorkingDirectory = $Context.SampleDirectory
    }
}

if (-not $IsWindows) { throw 'The optional weather sample logon supervisor is supported only on Windows.' }
foreach ($command in @('Get-ScheduledTask', 'Get-ScheduledTaskInfo', 'Register-ScheduledTask', 'Unregister-ScheduledTask',
        'Start-ScheduledTask', 'Stop-ScheduledTask', 'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger',
        'New-ScheduledTaskPrincipal', 'New-ScheduledTaskSettingsSet')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required Windows Scheduled Tasks command is unavailable: $command" }
}

$context = Get-WeatherSampleStartupContext
$existing = Get-ScheduledTask -TaskName $context.TaskName -ErrorAction SilentlyContinue

switch ($Mode) {
    'Status' {
        Get-WeatherSampleTaskStatus -Context $context
    }
    'Remove' {
        if ($null -eq $existing) {
            [pscustomobject]@{ TaskName = $context.TaskName; Removed = $false; State = 'Already absent' }
            break
        }
        Assert-OwnedWeatherSampleTask -Task $existing -Context $context
        if ([string]$existing.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $context.TaskName
            $null = Wait-WeatherSampleTaskState -TaskName $context.TaskName -DesiredState 'Ready'
        }
        Unregister-ScheduledTask -TaskName $context.TaskName -Confirm:$false
        $null = Wait-WeatherSampleTaskState -TaskName $context.TaskName -DesiredState 'Absent'
        [pscustomobject]@{ TaskName = $context.TaskName; Removed = $true; State = 'Absent' }
    }
    'Install' {
        $sampleConfiguration = Invoke-WeatherSampleConfigurationCheck -Context $context
        if ($null -ne $existing) {
            Assert-OwnedWeatherSampleTask -Task $existing -Context $context
            if ([string]$existing.State -eq 'Running') {
                Stop-ScheduledTask -TaskName $context.TaskName
                $null = Wait-WeatherSampleTaskState -TaskName $context.TaskName -DesiredState 'Ready'
            }
        }

        $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action = New-ScheduledTaskAction -Execute $context.Pythonw -Argument $context.Argument -WorkingDirectory $context.SampleDirectory
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
        $principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $context.TaskName -Action $action -Trigger $trigger -Principal $principal `
            -Settings $settings -Description $context.Description -Force | Out-Null

        $registered = Get-ScheduledTask -TaskName $context.TaskName -ErrorAction Stop
        Assert-OwnedWeatherSampleTask -Task $registered -Context $context
        Assert-WeatherSampleTaskShape -Task $registered
        Start-ScheduledTask -TaskName $context.TaskName
        $running = Wait-WeatherSampleTaskState -TaskName $context.TaskName -DesiredState 'Running'
        $uriHost = if ([string]$sampleConfiguration.host -eq '::1') { '[::1]' } else { [string]$sampleConfiguration.host }
        $address = "http://${uriHost}:$($sampleConfiguration.port)/"
        $status = Wait-WeatherSampleHttpStatus -Uri ([uri]($address + 'api/status')) -TaskName $context.TaskName
        [pscustomobject]@{
            TaskName = $context.TaskName
            Installed = $true
            State = [string]$running.State
            Address = $address
            StatusEndpoint = $status.Uri
            StatusCode = $status.StatusCode
            Executable = $context.Pythonw
            WorkingDirectory = $context.SampleDirectory
        }
    }
}
