@echo off
title All Users Temp File Cleaner

:: Get script directory
set SCRIPT_DIR=%~dp0
set PS_SCRIPT=%SCRIPT_DIR%TempFileCleanerUtility.ps1

:: Check for admin rights
net session >nul 2>&1
if %errorLevel% neq 0 (
echo Requesting administrator privileges...
powershell -Command "Start-Process cmd -ArgumentList '/c "%~f0"' -Verb RunAs"
exit
)

:: Run PowerShell script
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"

pause