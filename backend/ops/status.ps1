<#
.SYNOPSIS
    Reports whether the Kindle Dashboard Backend auto-start is installed,
    running, and actually answering requests -- whichever of the two
    autostart methods (Scheduled Task or no-admin Startup folder) is in use.
#>

$ErrorActionPreference = "Continue"
$TaskName = "Kindle Dashboard Backend"
$StartupShortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "Kindle Dashboard Backend.lnk"

Write-Host "=== Kindle Dashboard Backend status ===" -ForegroundColor Cyan
Write-Host ""

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    $color = if ($task.State -eq "Running") { "Green" } else { "Yellow" }
    Write-Host "Autostart method:     Scheduled Task"
    Write-Host "Scheduled task state: $($task.State)" -ForegroundColor $color
    Write-Host "Last run time:        $($info.LastRunTime)"
    Write-Host "Last result code:     $($info.LastTaskResult)  (0 = OK)"
} elseif (Test-Path $StartupShortcut) {
    Write-Host "Autostart method:     Startup folder (no-admin)"
    $running = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*run_backend.ps1*" } |
        Select-Object -First 1
    if ($running) {
        Write-Host "Wrapper process:      Running (PID $($running.ProcessId))" -ForegroundColor Green
    } else {
        Write-Host "Wrapper process:      NOT running" -ForegroundColor Yellow
        Write-Host "Double-click Start_Backend_Now.bat to start it." -ForegroundColor Yellow
    }
} else {
    Write-Host "Autostart: NOT INSTALLED" -ForegroundColor Red
    Write-Host "Double-click Install_Autostart.bat (or Install_Autostart_NoAdmin.bat if that gives an" -ForegroundColor Red
    Write-Host "'Access is denied' error) to set it up." -ForegroundColor Red
}

Write-Host ""
Write-Host "Checking http://localhost:8000/health ..."
try {
    $resp = Invoke-RestMethod -Uri "http://localhost:8000/health" -TimeoutSec 5
    Write-Host "SUCCESS: server responded -> $($resp | ConvertTo-Json -Compress)" -ForegroundColor Green
} catch {
    Write-Host "FAILED: could not reach the server on port 8000." -ForegroundColor Red
    Write-Host "  - If you just installed/started it, wait a few seconds and try again." -ForegroundColor Red
    Write-Host "  - Otherwise, double-click View_Latest_Log.bat to see what happened." -ForegroundColor Red
}

Write-Host ""
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LogDir = Join-Path $RepoRoot "backend\logs"
$latest = Get-ChildItem -Path $LogDir -Filter "backend_*.log" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latest) {
    Write-Host "Latest log file: $($latest.FullName)"
    Write-Host "Last 10 lines:"
    Get-Content -Path $latest.FullName -Tail 10
} else {
    Write-Host "No log files found yet in $LogDir"
}
