<#
.SYNOPSIS
    Opens today's (or the most recent) backend log file in Notepad.
#>

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LogDir = Join-Path $RepoRoot "backend\logs"

$latest = Get-ChildItem -Path $LogDir -Filter "backend_*.log" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($latest) {
    Write-Host "Opening $($latest.FullName) in Notepad..."
    Start-Process notepad.exe -ArgumentList "`"$($latest.FullName)`""
} else {
    Write-Host "No log files found yet in $LogDir"
    Write-Host "(This is normal if the backend has never been started yet.)"
}
