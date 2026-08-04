@echo off
title Kindle Dashboard Backend - Restart
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0stop_backend.ps1'; Start-Sleep -Seconds 2; & '%~dp0start_backend.ps1'"
echo.
pause
