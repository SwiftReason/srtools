@echo off
setlocal

set "SCRIPT=%~dp0AMD_Chipset_Cleanup_Utility.ps1"

if not exist "%SCRIPT%" (
    echo [ERROR] PowerShell script not found:
    echo %SCRIPT%
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File "%SCRIPT%"

endlocal