@echo off
title Kindle Dashboard Backend - Uninstall Autostart
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall_autostart.ps1"
echo.
pause
