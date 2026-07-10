@echo off
title FinalEclipse
cd /d "%~dp0"
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -WorkingDirectory '%~dp0' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%~dp0FinalEclipse.ps1"" %*'"
    if errorlevel 1 pause
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0FinalEclipse.ps1" %*
if errorlevel 1 pause
