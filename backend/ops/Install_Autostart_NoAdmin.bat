@echo off
title Kindle Dashboard Backend - Install Autostart (No Admin)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_autostart_startup.ps1"
echo.
pause
