<#
.SYNOPSIS
    Removes the no-admin (Startup folder) autostart set up by
    install_autostart_startup.ps1.

.DESCRIPTION
    Run this (via Uninstall_Autostart_NoAdmin.bat) to stop the backend from
    starting automatically at logon via the Startup-folder method. Stops
    the running backend first, then deletes the shortcut. Does not touch
    any of your files, code, or backend\.env secrets.
#>

$ErrorActionPreference = "Continue"
$StartupDir = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupDir "Kindle Dashboard Backend.lnk"

Write-Host "Stopping the backend..."
& (Join-Path $PSScriptRoot "stop_backend.ps1")

if (Test-Path $ShortcutPath) {
    Remove-Item -Path $ShortcutPath -Force
    Write-Host "Removed startup shortcut: $ShortcutPath" -ForegroundColor Green
} else {
    Write-Host "No startup shortcut found (already removed)." -ForegroundColor Yellow
}

Write-Host "Done. The backend will no longer start automatically at logon." -ForegroundColor Green
Write-Host "You can still run it manually with: uvicorn backend.main:app --host 0.0.0.0 --port 8000"
