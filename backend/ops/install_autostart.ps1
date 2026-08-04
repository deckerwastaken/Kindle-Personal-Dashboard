<#
.SYNOPSIS
    Registers the Windows Scheduled Task that auto-starts the Kindle
    Dashboard backend at logon.

.DESCRIPTION
    Run this ONCE (double-click Install_Autostart.bat instead of this file
    directly). Safe to run again later -- it just replaces the existing task
    with the same settings.

    Creates a task named "Kindle Dashboard Backend" that:
      - Triggers "At log on" for the current user (no password stored,
        no admin rights required).
      - Runs backend\ops\run_backend.ps1 hidden (no visible window).
      - Has no execution time limit (default Windows behavior would kill
        it after 3 days -- that's disabled here since this must run
        indefinitely).
      - Retries automatically (via Task Scheduler itself) if the wrapper
        script's own process ever dies, on top of the wrapper's internal
        restart-on-crash loop for uvicorn.
    Then starts the task immediately so you don't have to log out/in to
    see it working.
#>

$ErrorActionPreference = "Stop"

$TaskName = "Kindle Dashboard Backend"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WrapperScript = Join-Path $RepoRoot "backend\ops\run_backend.ps1"

Write-Host "=== Installing autostart for Kindle Dashboard Backend ===" -ForegroundColor Cyan
Write-Host "Repo root:      $RepoRoot"
Write-Host "Wrapper script: $WrapperScript"
Write-Host ""

if (-not (Test-Path $WrapperScript)) {
    Write-Host "ERROR: Could not find $WrapperScript" -ForegroundColor Red
    Write-Host "Make sure this .bat/.ps1 pair is still inside backend\ops\ of the repo." -ForegroundColor Red
    exit 1
}

$Action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WrapperScript`""

$Trigger = New-ScheduledTaskTrigger -AtLogOn

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

# LogonType Interactive + no explicit password = no credentials are ever
# stored for this task. It simply runs as "you" whenever you're logged in,
# same as any normal app you'd open by hand.
$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
    -Settings $Settings -Principal $Principal -Force | Out-Null

Write-Host "Scheduled task '$TaskName' installed." -ForegroundColor Green
Write-Host "Starting it now (no need to restart your laptop)..."
Start-ScheduledTask -TaskName $TaskName

Start-Sleep -Seconds 3
$info = Get-ScheduledTaskInfo -TaskName $TaskName
$task = Get-ScheduledTask -TaskName $TaskName
Write-Host ""
Write-Host "Task state:        $($task.State)"
Write-Host "Last run result:   $($info.LastTaskResult)  (0 = started OK)"
Write-Host ""
Write-Host "The backend will now start automatically every time you log in to Windows," -ForegroundColor Green
Write-Host "and will keep restarting itself if it ever crashes." -ForegroundColor Green
Write-Host ""
Write-Host "Next: double-click Check_Status.bat to confirm it's actually responding."
