#Requires -Version 7.0

<#+
.SYNOPSIS
    Configures, plans, provisions, inspects, or verifies an A365 Custom Gateway deployment.

.DESCRIPTION
    This is the canonical runtime bootstrap engine. The root gateway
    launchers provide a friendly cross-platform command surface over this script.
    Runtime state contains safe identifiers only under .bootstrap/. Credentials,
    access tokens, Gateway keys, prompts, responses, and dependency bodies are not
    configuration or state. Interrupted checkpoints require review; Destroy is intentionally absent.

    The supported core is Plan, Apply, and Verify:
    [ValidateSet('Plan', 'Apply', 'Verify')]

.EXAMPLE
    ./gateway up

.EXAMPLE
    ./gateway doctor

.EXAMPLE
    ./gateway plan -Config ./bootstrap/config.json

.EXAMPLE
    ./gateway status -OutputFormat Json
#>

[CmdletBinding()]
param(
    [ValidateSet('Init', 'Doctor', 'Plan', 'Apply', 'Status', 'Verify', 'Open', 'Diagnose', 'Up')]
    [string]$Mode = 'Plan',

    [string]$Config = (Join-Path $PSScriptRoot 'config.json'),

    [bool]$InstallPrerequisites = $true,

    [switch]$NonInteractive,

    [switch]$OpenBrowser,

    [switch]$Yes,

    [switch]$Force,

    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text',

    [string]$DiagnosticPath = '',

    [string]$ExpectedPlanFingerprint = '',

    [string]$ExpectedConfigurationFileFingerprint = '',

    [switch]$EventStreamOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$expectedConfigurationFileFingerprintSupplied =
    $PSBoundParameters.ContainsKey('ExpectedConfigurationFileFingerprint')
if ($OutputFormat -eq 'Json') {
    # Keep module Write-Host messages out of structured output. Experience events
    # use Console.Out deliberately; Common suppresses no-capture provider streams.
    $PSDefaultParameterValues['Write-Host:InformationAction'] = 'Ignore'
    $WarningPreference = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'
}

foreach ($module in @('Common', 'Experience', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Runtime', 'RuntimePurview', 'Lifecycle')) {
    Import-Module (Join-Path $PSScriptRoot "modules/$module.psm1") -Force -DisableNameChecking
}
Set-BootstrapStructuredOutput -Enabled ([bool]($OutputFormat -eq 'Json'))
$script:GatewayFailureStage = 'Bootstrap'
$script:GatewayFailureCode = 'bootstrap'
$setupLease = $null
try {
if ($Mode -in @('Init','Plan','Apply','Up')) { $setupLease = Enter-GatewaySetupLock }
if ($EventStreamOnly -and $OutputFormat -ne 'Json') {
    Write-GatewayExperienceEvent -Type Warning -Message 'EventStreamOnly requires JSON output.' -Data ([ordered]@{ step = 'Bootstrap'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
    throw 'Invalid event-stream mode.'
}
if ($EventStreamOnly -and $Mode -notin @('Plan', 'Up')) {
    Write-GatewayExperienceEvent -Type Warning -Message 'EventStreamOnly is valid only for Plan or Up.' -Data ([ordered]@{ step = 'Bootstrap'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
    throw 'Invalid event-stream command.'
}
if ($expectedConfigurationFileFingerprintSupplied) {
    if ($Mode -cne 'Plan') {
        Write-GatewayExperienceEvent -Type Warning -Message 'ExpectedConfigurationFileFingerprint is valid only for Plan.' -Data ([ordered]@{ step = 'Configuration'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
        throw 'Invalid expected-configuration-file mode.'
    }
    if ($ExpectedConfigurationFileFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        Write-GatewayExperienceEvent -Type Warning -Message 'ExpectedConfigurationFileFingerprint must use canonical lowercase sha256 format.' -Data ([ordered]@{ step = 'Configuration'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
        throw 'Invalid expected-configuration-file fingerprint.'
    }
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint)) {
    if ($Mode -notin @('Plan', 'Apply', 'Up')) {
        Write-GatewayExperienceEvent -Type Warning -Message 'ExpectedPlanFingerprint is valid only for Plan, Apply, or Up.' -Data ([ordered]@{ step = 'Plan review'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
        throw 'Invalid expected-plan mode.'
    }
    if ($ExpectedPlanFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        Write-GatewayExperienceEvent -Type Warning -Message 'ExpectedPlanFingerprint must use canonical lowercase sha256 format.' -Data ([ordered]@{ step = 'Plan review'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
        throw 'Invalid expected-plan fingerprint.'
    }
}
if ($Mode -eq 'Doctor') {
    $doctor = Get-GatewayDoctorReport -ConfigPath $Config
    Show-GatewayDoctorReport -Report $doctor -OutputFormat $OutputFormat
    return
}

if ($Mode -eq 'Init') {
    $created = New-GatewayBootstrapConfiguration -Path $Config -NonInteractive:$NonInteractive -Force:$Force
    if ($OutputFormat -eq 'Json') { Write-GatewayResult -Value $created -OutputFormat Json }
    else { Write-GatewayExperienceEvent -Type Result -Message "Configuration written to $($created.configPath). Run gateway plan next." }
    return
}

if ($Mode -eq 'Diagnose') {
    $script:GatewayFailureStage = 'Diagnostics'
    $script:GatewayFailureCode = 'diagnose'
    $doctor = Get-GatewayDoctorReport -ConfigPath $Config
    $configuration = $null
    $status = $null
    $configurationStatus = if (Test-Path -LiteralPath $Config) { 'Invalid' } else { 'Missing' }
    if (Test-Path -LiteralPath $Config) {
        try {
            $configuration = Read-BootstrapConfig -Path $Config
            $configurationStatus = 'Validated'
        }
        catch {
            $configuration = $null
            $configurationStatus = 'Invalid'
        }
        if ($null -ne $configuration) {
            try {
                $statePath = Get-BootstrapStatePath -Config $configuration
                $state = Read-BootstrapState -Path $statePath -Config $configuration
                $status = Get-GatewayBootstrapStatus -Config $configuration -State $state -StatePath $statePath
            }
            catch {
                $status = $null
                $configurationStatus = 'StateUnavailable'
            }
        }
    }
    $diagnostic = Write-GatewayDiagnosticBundle -Config $configuration -Doctor $doctor -Status $status -ConfigurationStatus $configurationStatus -Path $DiagnosticPath
    if ($OutputFormat -eq 'Json') {
        Write-GatewayResult -Value ([ordered]@{ diagnosticPath = $diagnostic.diagnosticPath; safeFieldsOnly = $true }) -OutputFormat Json
    }
    else {
        Write-GatewayExperienceEvent -Type Result -Message "Safe diagnostic bundle written to $($diagnostic.diagnosticPath). It excludes credentials, tokens, Gateway keys, prompts, responses, and dependency bodies."
    }
    return
}

if ($Mode -eq 'Up' -and -not (Test-Path -LiteralPath $Config)) {
    Write-GatewayExperienceEvent -Type Info -Message 'No bootstrap configuration exists; starting the guided runtime setup.' -Data ([ordered]@{
        step = 'Configuration'; index = 1; total = (Get-GatewayBootstrapStepNames).Count
    }) -OutputFormat $OutputFormat
    $null = New-GatewayBootstrapConfiguration -Path $Config -NonInteractive:$NonInteractive -Force:$Force
}

$script:GatewayFailureStage = 'Configuration'
$script:GatewayFailureCode = 'configuration'
if (-not (Test-Path -LiteralPath $Config)) {
    throw "Bootstrap configuration '$Config' does not exist. Run gateway init (guided TUI) or gateway init, then plan/apply. Do not hand-edit JSON."
}

$configLeaf = [IO.Path]::GetFileName([string]$Config)
if ($configLeaf -match '(?i)^config\.example') {
    throw "Refusing example configuration '$Config'. Run 'gateway init' or 'gateway up' with no --config so the guided wizard creates your real bootstrap/config.json."
}

$configuration = if ($expectedConfigurationFileFingerprintSupplied) {
    Read-BootstrapConfig `
        -Path $Config `
        -ExpectedConfigurationFileFingerprint $ExpectedConfigurationFileFingerprint
}
else {
    Read-BootstrapConfig -Path $Config
}
$script:GatewayFailureStage = 'Bootstrap state'
$script:GatewayFailureCode = 'state'
$statePath = Get-BootstrapStatePath -Config $configuration
Set-BootstrapDiagnosticsDirectory -Path (Join-Path (Get-RepositoryRoot) '.bootstrap/diagnostics')
$state = Read-BootstrapState -Path $statePath -Config $configuration

if ($Mode -in @('Plan', 'Apply', 'Up', 'Verify')) {
    $script:GatewayFailureStage = 'Runtime profile'
    $script:GatewayFailureCode = 'runtime'
    if ($Mode -eq 'Verify') {
        $runtime = $state.steps['Gateway runtime'].evidence
        if ($null -eq $runtime) {
            throw 'Runtime verification requires a completed Gateway runtime checkpoint. Run gateway apply first.'
        }
        $null = Test-GatewayRuntimeHealth `
            -HealthUrl ([string]$runtime.apiHealthUrl) `
            -ReadyUrl ([string]$runtime.apiReadyUrl) `
            -ConsoleConfigUrl ([string]$runtime.consoleConfigUrl) `
            -ConsoleProxyHealthUrl ([string]$runtime.consoleProxyHealthUrl) `
            -TimeoutSeconds 60
        Write-GatewayExperienceEvent -Type Result -Message "Runtime verification passed. Console: $($runtime.consoleUrl)" -Data @{consoleUrl=$runtime.consoleUrl} -OutputFormat $OutputFormat
        return
    }

    if ($Mode -in @('Plan', 'Up')) {
        $plan = Invoke-GatewayRuntimePlanWorkflow `
            -Configuration $configuration `
            -State $state `
            -StatePath $statePath `
            -Format $OutputFormat `
            -InstallLocalPrerequisites:$InstallPrerequisites `
            -StreamOnly:$EventStreamOnly
        if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and
            $ExpectedPlanFingerprint -cne [string]$plan.planFingerprint) {
            Clear-BootstrapAcceptedPlan -State $state -StatePath $statePath | Out-Null
            throw 'Expected plan fingerprint mismatch.'
        }
        if ($Mode -eq 'Plan') {
            $acceptPlan = $Yes
            if (-not $NonInteractive -and -not $Yes) {
                $acceptPlan = Read-GatewayYesNo -Prompt 'Accept this exact runtime plan for Apply' -Default $false
            }
            if ($NonInteractive -and -not $Yes) {
                $reviewMessage = if ($EventStreamOnly) { 'Plan ready. Review the settings above before installing.' } else { 'Non-interactive Plan was not accepted; rerun with -Yes after review.' }
                Write-GatewayExperienceEvent -Type Info -Message $reviewMessage -OutputFormat $OutputFormat
                return
            }
            if (-not $acceptPlan) {
                Clear-BootstrapAcceptedPlan -State $state -StatePath $statePath | Out-Null
                Write-GatewayExperienceEvent -Type Info -Message 'Runtime plan was not accepted.' -OutputFormat $OutputFormat
                return
            }
            Set-BootstrapAcceptedPlan `
                -State $state `
                -StatePath $statePath `
                -PlanFingerprint ([string]$plan.planFingerprint) `
                -ConfigurationFingerprint ([string]$plan.configurationFingerprint) `
                -SourceFingerprint ([string]$plan.sourceFingerprint) | Out-Null
            Write-GatewayExperienceEvent -Type Result -Message "Runtime plan accepted: $($plan.planFingerprint)" -OutputFormat $OutputFormat
            return
        }
    }

    if ($Mode -in @('Apply', 'Up')) {
        if (-not ($state.Contains('acceptedPlan') -and $state.acceptedPlan -is [System.Collections.IDictionary])) {
            if ($Mode -eq 'Apply') {
                throw 'Runtime Apply requires an accepted plan. Run gateway plan -Yes first, or use gateway up.'
            }
            if ($null -eq $plan) {
                throw 'Runtime Up did not compute a plan before apply.'
            }
            $acceptUp = $Yes.IsPresent -or $Yes -eq $true
            if ($NonInteractive.IsPresent -and -not $acceptUp) {
                throw 'Non-interactive runtime Up requires -Yes to accept the computed plan and apply it.'
            }
            if (-not $NonInteractive.IsPresent -and -not $acceptUp) {
                $acceptUp = Read-GatewayYesNo -Prompt 'Accept this runtime plan and apply it now' -Default $false
            }
            if (-not $acceptUp) {
                Write-GatewayExperienceEvent -Type Info -Message 'Runtime Up stopped before apply; plan was not accepted.' -OutputFormat $OutputFormat
                return
            }
            Set-BootstrapAcceptedPlan `
                -State $state `
                -StatePath $statePath `
                -PlanFingerprint ([string]$plan.planFingerprint) `
                -ConfigurationFingerprint ([string]$plan.configurationFingerprint) `
                -SourceFingerprint ([string]$plan.sourceFingerprint) | Out-Null
        }
        if (-not $Yes -and $Mode -eq 'Apply' -and -not $NonInteractive) {
            $proceed = Read-GatewayYesNo -Prompt 'Apply the accepted runtime plan now' -Default $false
            if (-not $proceed) { return }
        }
        if ($NonInteractive -and -not $Yes -and $Mode -eq 'Apply') {
            throw 'Non-interactive runtime Apply requires -Yes.'
        }

        $null = Invoke-GatewayRuntimeApplyWorkflow `
            -Configuration $configuration `
            -State $state `
            -StatePath $statePath `
            -Format $OutputFormat `
            -InstallLocalPrerequisites:$InstallPrerequisites `
            -NonInteractive:([bool]$NonInteractive) `
            -AcceptedPlanFingerprint ([string]$state.acceptedPlan.planFingerprint)
        if ($OpenBrowser) {
            $status = Get-GatewayBootstrapStatus -Config $configuration -State $state -StatePath $statePath
            $null = Open-GatewayAdminUi -Status $status
        }
        return
    }
}

if ($Mode -eq 'Status') {
    $script:GatewayFailureStage = 'Status'
    $script:GatewayFailureCode = 'status'
    $status = Get-GatewayBootstrapStatus -Config $configuration -State $state -StatePath $statePath
    Show-GatewayBootstrapStatus -Status $status -OutputFormat $OutputFormat
    return
}

if ($Mode -eq 'Open') {
    $script:GatewayFailureStage = 'Open Admin UI'
    $script:GatewayFailureCode = 'open'
    $status = Get-GatewayBootstrapStatus -Config $configuration -State $state -StatePath $statePath
    $opened = Open-GatewayAdminUi -Status $status
    if ($OutputFormat -eq 'Json') { Write-GatewayResult -Value $opened -OutputFormat Json }
    else { Write-GatewayExperienceEvent -Type Result -Message "Opened $($opened.adminUiUrl)" }
    return
}

}
catch {
    if ($_.Exception.Data.Contains('BootstrapStep')) {
        $script:GatewayFailureStage = [string]$_.Exception.Data['BootstrapStep']
    }
    if ($_.Exception.Data.Contains('BootstrapFailureCode')) {
        $script:GatewayFailureCode = [string]$_.Exception.Data['BootstrapFailureCode']
    }
    $providerCodes = @(Get-BootstrapExceptionProviderErrorCodes -Exception $_.Exception)
    $message = "Runtime bootstrap stopped during $script:GatewayFailureStage. Keep .bootstrap intact and run gateway doctor or gateway diagnose before retrying."
    $planGuidance = @{
        plan_prerequisites = 'Check gateway doctor: Docker must be running, .NET 10, Git and Azure CLI installed, and Bicep available when Content Safety is selected. Purview requires Windows and ExchangeOnlineManagement 3.10.1 for this account.'
        plan_account = 'Sign in to the configured tenant using az login, and confirm the selected subscription is accessible.'
        plan_entra_namespace = 'Confirm Microsoft Graph read access and that the application names belong to this installation. Do not delete or adopt unrelated applications.'
        plan_content_safety_ownership = 'The selected resource group and Content Safety account must be new or owned by this installation. Review the configured resource group.'
        plan_prompt_shield_capacity = 'Check Content Safety availability and F0 quota in the selected subscription and region.'
        plan_state = 'A checkpoint is not recognized by this installer. Preserve .bootstrap and review the deployment state before retrying.'
    }
    if ($planGuidance.ContainsKey($script:GatewayFailureCode)) { $message += ' ' + $planGuidance[$script:GatewayFailureCode] }
    if ($_.Exception.Message.StartsWith('This installer supports only the runtime deployment profile.', [StringComparison]::Ordinal)) {
        $message = 'This installer supports only the runtime deployment profile. Run gateway init to configure it.'
    }
    if ($providerCodes.Count) { $message += " Provider codes: $($providerCodes -join ', ')." }
    Write-GatewayExperienceEvent -Type Warning -Message $message -Data ([ordered]@{
        step = $script:GatewayFailureStage; failureCode = $script:GatewayFailureCode
    }) -OutputFormat $OutputFormat
    exit 1
}
finally {
    if ($null -ne $setupLease) { $setupLease.Dispose() }
    Set-BootstrapStructuredOutput -Enabled $false
}
