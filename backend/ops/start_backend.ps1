<#
.SYNOPSIS
    Starts the Kindle Dashboard backend right now, however autostart was
    installed.

.DESCRIPTION
    If the "Kindle Dashboard Backend" Scheduled Task exists, starts it that
    way. Otherwise (no-admin / Startup-folder autostart, or autostart not
    installed at all yet) launches run_backend.ps1 directly as a hidden,
    detached process -- same end result either way.
#>

$ErrorActionPreference = "Continue"
$TaskName = "Kindle Dashboard Backend"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WrapperScript = Join-Path $RepoRoot "backend\ops\run_backend.ps1"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Start requested via Scheduled Task." -ForegroundColor Green
} else {
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WrapperScript`"" `
        -WindowStyle Hidden
    Write-Host "Start requested directly (no Scheduled Task installed)." -ForegroundColor Green
}

Write-Host "Double-click Check_Status.bat in a few seconds to confirm."

# --- Keep the Kindle's saved laptop IP in sync -----------------------------
# Your laptop's LAN IP is handed out by your router's DHCP and can change
# (e.g. after a router reboot). If the Kindle's config.lua still has an old
# IP, the dashboard shows "OFFLINE" even though the backend above is running
# fine. This automatically detects your current IP and pushes it to the
# Kindle every time you start the backend, so that mismatch can't happen
# again. If the Kindle isn't reachable right now (asleep, SSH server off,
# still off Wi-Fi, etc.) this just skips quietly -- it never blocks the
# backend from starting.
Write-Host ""
Write-Host "Checking the Kindle has the right IP for this laptop..."
try {
    $KindleIpCacheFile = Join-Path $RepoRoot "kindle-daemon\ops\.last_kindle_ip.txt"
    if (-not (Test-Path $KindleIpCacheFile)) {
        Write-Host "(No saved Kindle IP yet -- run Start_Dashboard.bat once first. Skipping.)" -ForegroundColor DarkGray
    } else {
        $KindleIp = (Get-Content $KindleIpCacheFile -Raw).Trim()
        $subnetPrefix = ($KindleIp -split '\.')[0..2] -join '.'

        # Only trust an address on the SAME /24 as the Kindle -- a laptop can
        # have several IPs at once (Ethernet, Bluetooth PAN, VPN, etc.) and we
        # don't want to guess wrong.
        $myIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like "$subnetPrefix.*" -and $_.IPAddress -ne $KindleIp } |
            Select-Object -First 1 -ExpandProperty IPAddress

        if (-not $myIp) {
            Write-Host "(Could not find a laptop IP on the Kindle's network right now -- skipping.)" -ForegroundColor DarkGray
        } else {
            $sshOpts = @("-o", "ConnectTimeout=4", "-o", "StrictHostKeyChecking=accept-new", "-p", "2222")
            $sshTarget = "root@$KindleIp"
            $configPath = "/mnt/us/kindle-daemon/src/config.lua"

            $currentLine = & ssh @sshOpts $sshTarget "grep -oE 'laptop_ip = \"[0-9.]+\"' $configPath 2>/dev/null"
            if ($LASTEXITCODE -ne 0 -or -not $currentLine) {
                Write-Host "(Kindle not reachable right now -- skipping IP check. It'll retry next time.)" -ForegroundColor DarkGray
            } elseif ($currentLine -notmatch [Regex]::Escape($myIp)) {
                Write-Host "Kindle has an old laptop IP saved -- updating it to $myIp ..." -ForegroundColor Yellow
                & ssh @sshOpts $sshTarget "sed -i 's/laptop_ip = \"[0-9.]*\"/laptop_ip = \"$myIp\"/' $configPath" 2>$null | Out-Null

                $stillRunning = & ssh @sshOpts $sshTarget "ps | grep '[l]uajit'" 2>$null
                if ($stillRunning) {
                    & ssh @sshOpts $sshTarget ('killall -q -s KILL luajit 2>/dev/null; rm -f /mnt/us/kindle-daemon/crash.log; ' +
                        'cd /mnt/us/kindle-daemon/bin && nohup sh run.sh > /tmp/runsh_stdout.log 2>&1 & sleep 3; echo done') 2>$null | Out-Null
                    Write-Host "Dashboard was already running, so it was restarted to pick up the new IP." -ForegroundColor Green
                } else {
                    Write-Host "Updated. It'll take effect next time you run Start_Dashboard.bat." -ForegroundColor Green
                }
            } else {
                Write-Host "OK: Kindle already has the right IP ($myIp)." -ForegroundColor Green
            }
        }
    }
} catch {
    Write-Host "(Skipped the Kindle IP check due to an unexpected error -- not a problem, the backend is still running.)" -ForegroundColor DarkGray
}
