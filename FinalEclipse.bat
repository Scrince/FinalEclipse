@echo off
title FinalEclipse
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0FinalEclipse.ps1" %*
if errorlevel 1 pause
