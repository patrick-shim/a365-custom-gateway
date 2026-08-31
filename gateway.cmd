@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "COMMAND=%~1"
if "%COMMAND%"=="" set "COMMAND=up"
if not "%~1"=="" shift
set "GATEWAY_MODE="

if /I "%COMMAND%"=="setup" set "GATEWAY_MODE=Setup"
if /I "%COMMAND%"=="up" set "GATEWAY_MODE=Up"
if /I "%COMMAND%"=="init" set "GATEWAY_MODE=Init"
if /I "%COMMAND%"=="doctor" set "GATEWAY_MODE=Doctor"
if /I "%COMMAND%"=="plan" set "GATEWAY_MODE=Plan"
if /I "%COMMAND%"=="apply" set "GATEWAY_MODE=Apply"
if /I "%COMMAND%"=="resume" set "GATEWAY_MODE=Resume"
if /I "%COMMAND%"=="recover-database" set "GATEWAY_MODE=RecoverDatabase"
if /I "%COMMAND%"=="repair-database" set "GATEWAY_MODE=RepairDatabase"
if /I "%COMMAND%"=="upgrade-admin-ui" set "GATEWAY_MODE=UpgradeAdminUi"
if /I "%COMMAND%"=="status" set "GATEWAY_MODE=Status"
if /I "%COMMAND%"=="verify" set "GATEWAY_MODE=Verify"
if /I "%COMMAND%"=="open" set "GATEWAY_MODE=Open"
if /I "%COMMAND%"=="diagnose" set "GATEWAY_MODE=Diagnose"
if /I "%COMMAND%"=="help" goto help
if /I "%COMMAND%"=="-h" goto help
if /I "%COMMAND%"=="--help" goto help
if /I "%GATEWAY_MODE%"=="Setup" goto parse_setup
if /I "%GATEWAY_MODE%"=="UpgradeAdminUi" goto parse_upgrade
if defined GATEWAY_MODE goto parse

echo Unknown command. Run gateway.cmd --help for the supported surface. 1>&2
echo. 1>&2
goto help_error

:parse
set "GATEWAY_ROOT=%~dp0"
set "GATEWAY_CONFIG_SET=0"
set "GATEWAY_OUTPUT_FORMAT=Text"
set "GATEWAY_NONINTERACTIVE=0"
set "GATEWAY_YES=0"
set "GATEWAY_EXPECTED_PLAN_SET=0"
set "GATEWAY_EVENT_STREAM_ONLY=0"
set "GATEWAY_FORCE=0"
set "GATEWAY_OPEN=0"
set "GATEWAY_NO_INSTALL=0"
set "GATEWAY_DIAGNOSTIC_SET=0"

:parse_next
if "%~1"=="" goto run
if /I "%~1"=="--config" goto option_config
if /I "%~1"=="-Config" goto option_config
if /I "%~1"=="--json" goto option_json
if /I "%~1"=="--non-interactive" goto option_noninteractive
if /I "%~1"=="-NonInteractive" goto option_noninteractive
if /I "%~1"=="--yes" goto option_yes
if /I "%~1"=="-Yes" goto option_yes
if /I "%~1"=="--expected-plan-fingerprint" goto option_expected
if /I "%~1"=="-ExpectedPlanFingerprint" goto option_expected
if /I "%~1"=="--event-stream-only" goto option_stream
if /I "%~1"=="-EventStreamOnly" goto option_stream
if /I "%~1"=="--force" goto option_force
if /I "%~1"=="-Force" goto option_force
if /I "%~1"=="--open" goto option_open
if /I "%~1"=="-OpenBrowser" goto option_open
if /I "%~1"=="--no-install" goto option_noinstall
if /I "%~1"=="-InstallPrerequisites:$false" goto option_noinstall
if /I "%~1"=="--diagnostic-path" goto option_diagnostic
if /I "%~1"=="-DiagnosticPath" goto option_diagnostic
if /I "%~1"=="-OutputFormat" goto option_output
if /I "%~1"=="-h" goto help
if /I "%~1"=="--help" goto help
echo Unknown option. Run gateway.cmd --help for the supported surface. 1>&2
exit /b 2

:option_config
if "%~2"=="" (
  echo --config requires a path. 1>&2
  exit /b 2
)
set "GATEWAY_CONFIG=%~2"
set "GATEWAY_CONFIG_SET=1"
shift
shift
goto parse_next

:option_json
set "GATEWAY_OUTPUT_FORMAT=Json"
shift
goto parse_next

:option_output
if /I "%~2"=="Text" goto option_output_valid
if /I "%~2"=="Json" goto option_output_valid
echo -OutputFormat requires Text or Json. 1>&2
exit /b 2

:option_output_valid
set "GATEWAY_OUTPUT_FORMAT=%~2"
shift
shift
goto parse_next

:option_noninteractive
set "GATEWAY_NONINTERACTIVE=1"
shift
goto parse_next

:option_yes
set "GATEWAY_YES=1"
shift
goto parse_next

:option_expected
if "%~2"=="" (
  echo --expected-plan-fingerprint requires sha256:^<64 lowercase hex^>. 1>&2
  exit /b 2
)
set "GATEWAY_EXPECTED_PLAN=%~2"
set "GATEWAY_EXPECTED_PLAN_SET=1"
shift
shift
goto parse_next

:option_stream
set "GATEWAY_EVENT_STREAM_ONLY=1"
shift
goto parse_next

:option_force
set "GATEWAY_FORCE=1"
shift
goto parse_next

:option_open
set "GATEWAY_OPEN=1"
shift
goto parse_next

:option_noinstall
set "GATEWAY_NO_INSTALL=1"
shift
goto parse_next

:option_diagnostic
if "%~2"=="" (
  echo --diagnostic-path requires a path. 1>&2
  exit /b 2
)
set "GATEWAY_DIAGNOSTIC_PATH=%~2"
set "GATEWAY_DIAGNOSTIC_SET=1"
shift
shift
goto parse_next

:run
call :find_pwsh
if errorlevel 1 exit /b %errorlevel%

rem Values supplied by the caller cross into PowerShell through environment
rem variables, not through a reparsed command string. This preserves spaces and
rem prevents option values from becoming cmd.exe syntax.
"%GATEWAY_PWSH%" -NoLogo -NoProfile -Command "$ErrorActionPreference='Stop'; try { $p=@{ Mode=$env:GATEWAY_MODE; OutputFormat=$env:GATEWAY_OUTPUT_FORMAT }; if($env:GATEWAY_CONFIG_SET -eq '1'){$p.Config=$env:GATEWAY_CONFIG}; if($env:GATEWAY_NONINTERACTIVE -eq '1'){$p.NonInteractive=$true}; if($env:GATEWAY_YES -eq '1'){$p.Yes=$true}; if($env:GATEWAY_EXPECTED_PLAN_SET -eq '1'){$p.ExpectedPlanFingerprint=$env:GATEWAY_EXPECTED_PLAN}; if($env:GATEWAY_EVENT_STREAM_ONLY -eq '1'){$p.EventStreamOnly=$true}; if($env:GATEWAY_FORCE -eq '1'){$p.Force=$true}; if($env:GATEWAY_OPEN -eq '1'){$p.OpenBrowser=$true}; if($env:GATEWAY_NO_INSTALL -eq '1'){$p.InstallPrerequisites=$false}; if($env:GATEWAY_DIAGNOSTIC_SET -eq '1'){$p.DiagnosticPath=$env:GATEWAY_DIAGNOSTIC_PATH}; & (Join-Path $env:GATEWAY_ROOT 'bootstrap\bootstrap.ps1') @p; exit 0 } catch { [Console]::Error.WriteLine('Gateway bootstrap could not start safely. Dependency details were withheld.'); exit 1 }"
exit /b %errorlevel%

:find_pwsh
set "GATEWAY_PWSH=pwsh.exe"
where pwsh.exe >nul 2>nul
if not errorlevel 1 exit /b 0
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  set "GATEWAY_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
  exit /b 0
)
if "%GATEWAY_NO_INSTALL%"=="1" (
  echo PowerShell 7 is required and --no-install forbids installing it. Install PowerShell separately, then rerun this command. 1>&2
  exit /b 1
)
where winget.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 is required. Install it from https://aka.ms/powershell-release?tag=stable 1>&2
  exit /b 1
)
echo Installing PowerShell 7...
winget install --id Microsoft.PowerShell --exact --accept-package-agreements --accept-source-agreements
if errorlevel 1 exit /b %errorlevel%
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  set "GATEWAY_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
  exit /b 0
)
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 was installed but is not yet discoverable. Open a new terminal and rerun gateway.cmd. 1>&2
  exit /b 1
)
exit /b 0

:parse_setup
set "SETUP_NO_OPEN="

:parse_setup_next
if "%~1"=="" goto run_setup
if /I "%~1"=="--no-open" (
  set "SETUP_NO_OPEN=--no-open"
  shift
  goto parse_setup_next
)
if /I "%~1"=="-h" goto help_setup
if /I "%~1"=="--help" goto help_setup
echo Unknown setup option. Run gateway.cmd setup --help. 1>&2
exit /b 2

:run_setup
call :check_setup_prerequisites
if errorlevel 1 exit /b 1
dotnet run --project "%~dp0tools\Gateway.Setup\Gateway.Setup.csproj" -- --repo-root "%~dp0" %SETUP_NO_OPEN%
exit /b %errorlevel%

:check_setup_prerequisites
set "SETUP_PREREQUISITES_READY=1"
set "GATEWAY_SETUP_PWSH=pwsh.exe"
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    set "GATEWAY_SETUP_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
    set "PATH=%ProgramFiles%\PowerShell\7;%PATH%"
  ) else (
    echo Setup requires PowerShell 7 ^(pwsh^). Install: https://aka.ms/powershell-release?tag=stable 1>&2
    set "SETUP_PREREQUISITES_READY=0"
  )
)
if "%SETUP_PREREQUISITES_READY%"=="1" (
  "%GATEWAY_SETUP_PWSH%" -NoLogo -NoProfile -NonInteractive -Command "if ($PSVersionTable.PSVersion.Major -ge 7) { exit 0 }; exit 1" >nul 2>nul
  if errorlevel 1 (
    echo Setup requires PowerShell 7 ^(pwsh^). Install: https://aka.ms/powershell-release?tag=stable 1>&2
    set "SETUP_PREREQUISITES_READY=0"
  )
)

where dotnet.exe >nul 2>nul
if errorlevel 1 (
  echo Setup requires the .NET 10 SDK. Install: https://dotnet.microsoft.com/download/dotnet/10.0 1>&2
  set "SETUP_PREREQUISITES_READY=0"
) else (
  call :check_setup_dotnet_10
  if errorlevel 1 (
    echo Setup requires the .NET 10 SDK. Install: https://dotnet.microsoft.com/download/dotnet/10.0 1>&2
    set "SETUP_PREREQUISITES_READY=0"
  )
)

where az >nul 2>nul
if errorlevel 1 (
  echo Setup requires Azure CLI ^(az^). Install: https://learn.microsoft.com/cli/azure/install-azure-cli 1>&2
  set "SETUP_PREREQUISITES_READY=0"
) else (
  call az version >nul 2>nul
  if errorlevel 1 (
    echo Setup requires Azure CLI ^(az^). Install: https://learn.microsoft.com/cli/azure/install-azure-cli 1>&2
    set "SETUP_PREREQUISITES_READY=0"
  )
)

if "%SETUP_PREREQUISITES_READY%"=="0" (
  echo Install or repair the listed tools, open a new terminal, and rerun gateway.cmd setup. 1>&2
  exit /b 1
)
exit /b 0

:parse_upgrade
set "GATEWAY_ROOT=%~dp0"
set "GATEWAY_CONFIG_SET=0"
set "GATEWAY_NONINTERACTIVE=0"
set "GATEWAY_YES=0"

:parse_upgrade_next
if "%~1"=="" goto run_upgrade
if /I "%~1"=="--config" goto upgrade_option_config
if /I "%~1"=="-Config" goto upgrade_option_config
if /I "%~1"=="--yes" (
  set "GATEWAY_YES=1"
  shift
  goto parse_upgrade_next
)
if /I "%~1"=="-Yes" (
  set "GATEWAY_YES=1"
  shift
  goto parse_upgrade_next
)
if /I "%~1"=="--non-interactive" (
  set "GATEWAY_NONINTERACTIVE=1"
  shift
  goto parse_upgrade_next
)
if /I "%~1"=="-NonInteractive" (
  set "GATEWAY_NONINTERACTIVE=1"
  shift
  goto parse_upgrade_next
)
if /I "%~1"=="-h" goto help_upgrade
if /I "%~1"=="--help" goto help_upgrade
echo Unknown upgrade-admin-ui option. Run gateway.cmd upgrade-admin-ui --help. 1>&2
exit /b 2

:upgrade_option_config
if "%~2"=="" (
  echo --config requires a path. 1>&2
  exit /b 2
)
set "GATEWAY_CONFIG=%~2"
set "GATEWAY_CONFIG_SET=1"
shift
shift
goto parse_upgrade_next

:run_upgrade
set "GATEWAY_NO_INSTALL=1"
call :find_pwsh
if errorlevel 1 exit /b %errorlevel%
"%GATEWAY_PWSH%" -NoLogo -NoProfile -Command "$ErrorActionPreference='Stop'; try { $p=@{}; if($env:GATEWAY_CONFIG_SET -eq '1'){$p.Config=$env:GATEWAY_CONFIG}; if($env:GATEWAY_NONINTERACTIVE -eq '1'){$p.NonInteractive=$true}; if($env:GATEWAY_YES -eq '1'){$p.Yes=$true}; & (Join-Path $env:GATEWAY_ROOT 'operations\upgrade-bootstrap-admin-ui.ps1') @p; exit 0 } catch { [Console]::Error.WriteLine('Gateway Admin UI upgrade could not complete safely. Dependency details were withheld.'); exit 1 }"
exit /b %errorlevel%

:help_upgrade
echo Usage: gateway.cmd upgrade-admin-ui --config PATH --yes [--non-interactive]
exit /b 0

:check_setup_dotnet_10
set "GATEWAY_SETUP_DOTNET_VERSION="
for /f "delims=" %%V in ('dotnet --version 2^>nul') do set "GATEWAY_SETUP_DOTNET_VERSION=%%V"
if not defined GATEWAY_SETUP_DOTNET_VERSION exit /b 1
if "%GATEWAY_SETUP_DOTNET_VERSION:~0,3%"=="10." exit /b 0
exit /b 1

:help_setup
echo Usage: gateway.cmd setup [--no-open]
exit /b 0

:help
echo A365 Custom Gateway
echo.
echo Usage: gateway.cmd [command] [options]
echo.
echo Commands:
echo   setup       Start the temporary loopback-only Fluent setup UI
echo   up          Configure, plan, confirm, deploy/resume, and verify
echo   init        Create a reviewed non-secret configuration
echo   doctor      Check tools, configuration, and Azure sign-in readiness
echo   plan        Compile Bicep, show operations, and run Azure What-If
echo   apply       Apply an accepted current plan
echo   resume      Resume an interrupted accepted plan
echo   recover-database
echo               Run the reviewed one-time recovery for an eligible failed database bootstrap
echo   repair-database
echo               Run the one-shot manual repair after both automatic database recoveries failed
echo   upgrade-admin-ui
echo               Build and promote only the Admin UI of a completed bootstrap deployment
echo   status      Show checkpoint and truthful readiness status
echo   verify      Rerun read-only deployment verification
echo   open        Open the recorded verified Admin UI
echo   diagnose    Write a sanitized diagnostic bundle
echo.
echo Options:
echo   --config PATH
echo   --json  --non-interactive  --yes  --force  --open  --no-install
echo   --yes explicitly accepts the exact plan for automated plan/up/resume/recovery
echo   --expected-plan-fingerprint SHA256  --event-stream-only
echo   --diagnostic-path PATH
echo.
echo There is intentionally no destroy, Registry replay, retained-message, or cleanup command.
exit /b 0

:help_error
call :help
exit /b 2
