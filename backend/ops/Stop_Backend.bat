@echo off
title Kindle Dashboard Backend - Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop_backend.ps1"
echo.
pause
