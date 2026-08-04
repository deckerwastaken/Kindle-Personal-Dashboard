@echo off
title Kindle Dashboard Backend - Uninstall Autostart (No Admin)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall_autostart_startup.ps1"
echo.
pause
