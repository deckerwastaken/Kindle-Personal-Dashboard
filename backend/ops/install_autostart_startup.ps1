<#
.SYNOPSIS
    Registers the Kindle Dashboard backend to auto-start at logon WITHOUT
    needing Administrator rights, using the Windows Startup folder instead
    of a Scheduled Task.

.DESCRIPTION
    Use this instead of install_autostart.ps1 if that one fails with
    "Access is denied" -- some locked-down or managed Windows accounts
    can't register Scheduled Tasks even for themselves.

    Run this ONCE (double-click Install_Autostart_NoAdmin.bat instead of
    this file directly). Safe to run again later -- it just replaces the
    existing shortcut.

    Creates a shortcut in your personal Startup folder that runs
    backend\ops\run_backend.ps1 hidden, every time you log in.
    run_backend.ps1 itself still does all the real work -- starting
    uvicorn, logging, and restarting it if it crashes -- this only changes
    *how* it gets triggered at login, and needs no special permissions
    because the Startup folder is just a normal folder inside your own
    user profile.

    Trade-off vs. the Scheduled Task version: if the wrapper script's own
    PowerShell process is ever killed outright (rare -- its internal loop
    already restarts uvicorn if that crashes), nothing brings the wrapper
    itself back until your next login. The Scheduled Task version has an
    extra outer retry for that specific case; this one trades that away
    for not needing admin rights to install.
#>

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WrapperScript = Join-Path $RepoRoot "backend\ops\run_backend.ps1"
$StartupDir = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupDir "Kindle Dashboard Backend.lnk"

Write-Host "=== Installing autostart for Kindle Dashboard Backend (no admin required) ===" -ForegroundColor Cyan
Write-Host "Repo root:      $RepoRoot"
Write-Host "Wrapper script: $WrapperScript"
Write-Host "Shortcut:       $ShortcutPath"
Write-Host ""

if (-not (Test-Path $WrapperScript)) {
    Write-Host "ERROR: Could not find $WrapperScript" -ForegroundColor Red
    Write-Host "Make sure this .bat/.ps1 pair is still inside backend\ops\ of the repo." -ForegroundColor Red
    exit 1
}

$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WrapperScript`""
$Shortcut.WorkingDirectory = $RepoRoot
$Shortcut.WindowStyle = 7  # Minimized, belt-and-suspenders alongside -WindowStyle Hidden above
$Shortcut.Description = "Starts the Kindle Dashboard backend at logon (no-admin autostart)"
$Shortcut.Save()

Write-Host "Startup shortcut installed." -ForegroundColor Green
Write-Host "Starting it now (no need to log out/in)..."
Start-Process -FilePath "powershell.exe" `
    -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WrapperScript`"" `
    -WindowStyle Hidden

Start-Sleep -Seconds 3
Write-Host ""
Write-Host "The backend will now start automatically every time you log in to Windows," -ForegroundColor Green
Write-Host "and will keep restarting itself if it ever crashes." -ForegroundColor Green
Write-Host ""
Write-Host "Next: double-click Check_Status.bat to confirm it's actually responding."
