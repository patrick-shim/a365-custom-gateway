@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "COMMAND=%~1"
if "%COMMAND%"=="" set "COMMAND=up"
if not "%~1"=="" shift
set "GATEWAY_MODE="
if /I "%COMMAND%"=="gui" goto gui

if /I "%COMMAND%"=="setup" set "GATEWAY_MODE=Init"
if /I "%COMMAND%"=="up" set "GATEWAY_MODE=Up"
if /I "%COMMAND%"=="init" set "GATEWAY_MODE=Init"
if /I "%COMMAND%"=="doctor" set "GATEWAY_MODE=Doctor"
if /I "%COMMAND%"=="plan" set "GATEWAY_MODE=Plan"
if /I "%COMMAND%"=="apply" set "GATEWAY_MODE=Apply"
if /I "%COMMAND%"=="status" set "GATEWAY_MODE=Status"
if /I "%COMMAND%"=="verify" set "GATEWAY_MODE=Verify"
if /I "%COMMAND%"=="open" set "GATEWAY_MODE=Open"
if /I "%COMMAND%"=="diagnose" set "GATEWAY_MODE=Diagnose"
if /I "%COMMAND%"=="help" goto help
if /I "%COMMAND%"=="-h" goto help
if /I "%COMMAND%"=="--help" goto help
if defined GATEWAY_MODE goto parse

echo Unknown command. Run gateway.cmd --help for the supported surface. 1>&2
echo. 1>&2
goto help_error

:gui
set "GATEWAY_NO_INSTALL=1"
call :find_pwsh
if errorlevel 1 exit /b %errorlevel%
if "%~1"=="" goto gui_open
if /I "%~1"=="--no-open" if "%~2"=="" goto gui_no_open
echo GUI accepts only --no-open. 1>&2
exit /b 2

:gui_open
"%GATEWAY_PWSH%" -NoLogo -NoProfile -File "%~dp0bootstrap\start-setup.ps1"
exit /b %errorlevel%

:gui_no_open
"%GATEWAY_PWSH%" -NoLogo -NoProfile -File "%~dp0bootstrap\start-setup.ps1" -NoOpen
exit /b %errorlevel%

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
"%GATEWAY_PWSH%" -NoLogo -NoProfile -Command "$ErrorActionPreference='Stop'; try { $p=@{ Mode=$env:GATEWAY_MODE; OutputFormat=$env:GATEWAY_OUTPUT_FORMAT }; if($env:GATEWAY_CONFIG_SET -eq '1'){$p.Config=$env:GATEWAY_CONFIG}; if($env:GATEWAY_NONINTERACTIVE -eq '1'){$p.NonInteractive=$true}; if($env:GATEWAY_YES -eq '1'){$p.Yes=$true}; if($env:GATEWAY_EXPECTED_PLAN_SET -eq '1'){$p.ExpectedPlanFingerprint=$env:GATEWAY_EXPECTED_PLAN}; if($env:GATEWAY_EVENT_STREAM_ONLY -eq '1'){$p.EventStreamOnly=$true}; if($env:GATEWAY_FORCE -eq '1'){$p.Force=$true}; if($env:GATEWAY_OPEN -eq '1'){$p.OpenBrowser=$true}; if($env:GATEWAY_NO_INSTALL -eq '1'){$p.InstallPrerequisites=$false}; if($env:GATEWAY_DIAGNOSTIC_SET -eq '1'){$p.DiagnosticPath=$env:GATEWAY_DIAGNOSTIC_PATH}; & (Join-Path $env:GATEWAY_ROOT 'bootstrap\bootstrap.ps1') @p; if(-not $?){exit 1}; exit 0 } catch { [Console]::Error.WriteLine('Gateway bootstrap could not start safely. Dependency details were withheld.'); exit 1 }"
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

:help
echo A365 Custom Gateway
echo.
echo Usage: gateway.cmd [command] [options]
echo.
echo Commands:
echo   setup, init Guided terminal setup for the runtime gateway
echo   gui         Open the React graphical installer on this computer
echo   up          Configure, review, deploy, and verify
echo   doctor      Check runtime tools and Microsoft product sign-in
echo   plan        Review the runtime deployment plan
echo   apply       Apply an accepted current plan
echo   status      Show saved checkpoints
echo   verify      Check the runtime gateway and Console
echo   open        Open the Console
echo   diagnose    Write a sanitized diagnostic bundle
echo.
echo Options:
echo   --config PATH
echo   --json  --non-interactive  --yes  --force  --open  --no-install
echo   --yes explicitly accepts the exact plan for automated plan/up/apply
echo   --expected-plan-fingerprint SHA256  --event-stream-only
echo   --diagnostic-path PATH
echo.
echo There is intentionally no destroy, Registry replay, retained-message, or cleanup command.
exit /b 0

:help_error
call :help
exit /b 2
