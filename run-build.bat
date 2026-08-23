@echo off
set "ProgramFiles(x86)=C:\Program Files (x86)"
echo ProgramFiles(x86) = %ProgramFiles(x86)%
echo.
echo === RESTORING ===
"C:\Program Files\dotnet\dotnet.exe" restore src/A365Gateway.slnx --configfile nuget.config --verbosity minimal
if %ERRORLEVEL% NEQ 0 (
    echo RESTORE FAILED with code %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)
echo.
echo === BUILDING ===
"C:\Program Files\dotnet\dotnet.exe" build src/Gateway.Api/Gateway.Api.csproj --configuration Debug --no-restore
if %ERRORLEVEL% NEQ 0 (
    echo BUILD FAILED with code %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)
echo.
echo === BUILD SUCCEEDED ===
