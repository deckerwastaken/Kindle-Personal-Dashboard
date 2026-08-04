<#
.SYNOPSIS
    Removes the "Kindle Dashboard Backend" auto-start Scheduled Task.

.DESCRIPTION
    Run this (via Uninstall_Autostart.bat) if you want to stop the backend
    from starting automatically at logon -- e.g. before uninstalling the
    whole project, or to switch back to running it manually from a
    terminal for debugging. Stops the running backend first, then deletes
    the scheduled task entirely. Does not touch any of your files, code,
    or backend\.env secrets.
#>

$ErrorActionPreference = "Continue"
$TaskName = "Kindle Dashboard Backend"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host "No scheduled task named '$TaskName' found (already removed)." -ForegroundColor Yellow
    exit 0
}

Write-Host "Stopping the backend..."
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

Write-Host "Removing scheduled task '$TaskName'..."
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false

Write-Host "Done. The backend will no longer start automatically at logon." -ForegroundColor Green
Write-Host "You can still run it manually with: uvicorn backend.main:app --host 0.0.0.0 --port 8000"
