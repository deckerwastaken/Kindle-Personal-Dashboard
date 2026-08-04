<#
.SYNOPSIS
    Stops the Kindle Dashboard backend, however it was started.

.DESCRIPTION
    Works regardless of which autostart method is installed:
      - If the "Kindle Dashboard Backend" Scheduled Task exists, stops it
        (which kills its whole process tree).
      - Either way, also directly kills any leftover run_backend.ps1 wrapper
        or uvicorn process by matching command lines -- this is what makes
        Stop_Backend.bat work under the no-admin (Startup folder) autostart
        method too, where there's no Scheduled Task to stop.
#>

$ErrorActionPreference = "Continue"
$TaskName = "Kindle Dashboard Backend"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and ($_.CommandLine -like "*run_backend.ps1*" -or $_.CommandLine -like "*uvicorn*backend.main*") } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

Write-Host "Backend stopped." -ForegroundColor Yellow
Write-Host "It will start again next time you log in (if autostart is installed), or if you double-click Start_Backend_Now.bat."
