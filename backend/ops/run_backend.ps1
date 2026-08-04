<#
.SYNOPSIS
    Auto-restarting launcher for the Kindle Dashboard backend.

.DESCRIPTION
    This is the script that actually keeps the backend alive. It is NOT meant
    to be double-clicked directly by a user -- it is launched automatically
    by the "Kindle Dashboard Backend" Windows Scheduled Task (see
    install_autostart.ps1 / backend\ops\Install_Autostart.bat).

    What it does, forever, until the task is stopped:
      1. Runs `uvicorn backend.main:app` from the repo root.
      2. Appends everything uvicorn prints (stdout + stderr) to a dated log
         file under backend\logs\.
      3. If uvicorn ever exits for any reason (crash, unhandled exception,
         killed process, etc.), it waits 5 seconds and starts it again.
      4. Deletes log files older than 30 days so backend\logs\ doesn't grow
         forever.

    Stopping this loop is done from the OUTSIDE (Task Scheduler stopping the
    task kills this whole process tree, including the uvicorn child) -- see
    Stop_Backend.bat / Restart_Backend.bat.
#>

$ErrorActionPreference = "Continue"

# backend\ops\run_backend.ps1 -> repo root is two levels up.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $RepoRoot

$LogDir = Join-Path $RepoRoot "backend\logs"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-WrapperLog {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [wrapper] $Message"
    $logFile = Join-Path $LogDir "backend_$(Get-Date -Format 'yyyy-MM-dd').log"
    Add-Content -Path $logFile -Value $line
}

# Prefer the `python` launcher; fall back to the `py` launcher if that's
# what's installed. Both are checked here once at startup rather than on
# every restart loop.
$PythonCmd = $null
foreach ($candidate in @("python", "py")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) {
        $PythonCmd = $candidate
        break
    }
}

if (-not $PythonCmd) {
    Write-WrapperLog "FATAL: no 'python' or 'py' command found on PATH. Cannot start the backend."
    Write-WrapperLog "Install Python 3.11+ and make sure it's on PATH, then restart the backend."
    exit 1
}

# Clean up log files older than 30 days (keeps backend\logs\ from growing
# forever on a service that's meant to run indefinitely).
Get-ChildItem -Path $LogDir -Filter "backend_*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-WrapperLog "=== Wrapper started (PID $PID), using '$PythonCmd' ==="

$restartCount = 0

while ($true) {
    # Recompute in case midnight passed since the loop started, so output
    # always lands in *today's* log file.
    $logFile = Join-Path $LogDir "backend_$(Get-Date -Format 'yyyy-MM-dd').log"

    Write-WrapperLog "Starting uvicorn (attempt #$($restartCount + 1))..."

    # NOTE: PowerShell's own redirection operators (`*>>`, `2>&1`, or piping
    # to Out-File) mangle a native process's output in Windows PowerShell
    # 5.1 -- either garbled UTF-16 encoding, or stderr lines get wrapped in
    # multi-line "NativeCommandError" noise. Shelling out through cmd.exe
    # for the actual `>>` / `2>&1` redirection sidesteps both problems: it's
    # a real OS-level file redirection, so the log file ends up as plain,
    # readable text exactly as it would look in a terminal.
    $uvicornCmd = "`"$PythonCmd`" -m uvicorn backend.main:app --host 0.0.0.0 --port 8000"
    $fullCmd = "$uvicornCmd >> `"$logFile`" 2>&1"
    & cmd.exe /c $fullCmd
    $exitCode = $LASTEXITCODE

    Write-WrapperLog "uvicorn exited (code $exitCode)."
    $restartCount++

    Write-WrapperLog "Restarting in 5 seconds..."
    Start-Sleep -Seconds 5
}
