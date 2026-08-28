@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  where winget.exe >nul 2>nul
  if errorlevel 1 (
    echo PowerShell 7 is required. Install it from https://aka.ms/powershell-release?tag=stable
    exit /b 1
  )
  echo Installing PowerShell 7...
  winget install --id Microsoft.PowerShell --exact --accept-package-agreements --accept-source-agreements
  if errorlevel 1 exit /b %errorlevel%
)
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  "%ProgramFiles%\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -File "%~dp0bootstrap.ps1" %*
) else (
  pwsh.exe -NoLogo -NoProfile -File "%~dp0bootstrap.ps1" %*
)
exit /b %errorlevel%
