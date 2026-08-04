@echo off
title Kindle Dashboard - Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop_dashboard.ps1"
echo.
pause
