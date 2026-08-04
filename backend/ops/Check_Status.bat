@echo off
title Kindle Dashboard Backend - Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0status.ps1"
echo.
pause
