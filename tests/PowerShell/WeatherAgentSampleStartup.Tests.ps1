#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../../tools/scripts/setup/Set-WeatherAgentSampleStartup.ps1'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    [IO.Path]::GetFullPath($scriptPath),
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count) { throw ($errors | ForEach-Object Message | Join-String -Separator [Environment]::NewLine) }

$source = $ast.Extent.Text
$required = @(
    "ValidateSet('Install', 'Status', 'Remove')",
    "'.venv/Scripts/pythonw.exe'",
    'New-ScheduledTaskTrigger -AtLogOn -User $account',
    'New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited',
    '-MultipleInstances IgnoreNew -RestartCount 3',
    'Assert-OwnedWeatherSampleTask -Task $existing -Context $context',
    'Start-ScheduledTask -TaskName $context.TaskName',
    "Wait-WeatherSampleHttpStatus -Uri ([uri](`$address + 'api/status'))"
)
foreach ($text in $required) {
    if (-not $source.Contains($text, [StringComparison]::Ordinal)) {
        throw "Weather sample supervisor contract is missing: $text"
    }
}

foreach ($forbidden in @('-RepetitionInterval', 'powershell.exe', 'pwsh.exe', 'cmd.exe')) {
    if ($source.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Weather sample supervisor reintroduced forbidden launch behavior: $forbidden"
    }
}

$taskActions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-ScheduledTaskAction'
}, $true))
if ($taskActions.Count -ne 1) { throw 'Weather sample supervisor must define exactly one direct scheduled-task action.' }

Write-Output 'Weather sample startup supervisor source contract passed.'
