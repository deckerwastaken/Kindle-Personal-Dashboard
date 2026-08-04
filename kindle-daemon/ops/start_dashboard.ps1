<#
.SYNOPSIS
    Starts the Kindle Dashboard on the physical Kindle over SSH, without
    rebooting the device. Requires KOReader's SSH server to already be
    turned on, on the Kindle itself (KOReader's Tools menu > SSH server) --
    this script can't turn that on for you, it has to be done by hand on
    the device first.

    This runs the exact same kindle-daemon/bin/run.sh that INSTALL.md has
    you test by hand over SSH -- nothing new/untested, just automated.
#>

$ErrorActionPreference = "Continue"
$IpCacheFile = Join-Path $PSScriptRoot ".last_kindle_ip.txt"

Write-Host "=== Start Kindle Dashboard ===" -ForegroundColor Cyan
Write-Host ""

$lastIp = if (Test-Path $IpCacheFile) { (Get-Content $IpCacheFile -Raw).Trim() } else { $null }
if ($lastIp) {
    $inputIp = Read-Host "Kindle IP address [$lastIp] (find the current one on the KOReader SSH server screen if it's changed)"
} else {
    $inputIp = Read-Host "Kindle IP address (find it on the KOReader SSH server screen)"
}
$KindleIp = if ([string]::IsNullOrWhiteSpace($inputIp)) { $lastIp } else { $inputIp.Trim() }

if ([string]::IsNullOrWhiteSpace($KindleIp)) {
    Write-Host "No IP address given, and no previous one saved. Cannot continue." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Checking laptop backend (http://localhost:8000/health) ..."
try {
    $resp = Invoke-RestMethod -Uri "http://localhost:8000/health" -TimeoutSec 5
    Write-Host "OK: backend responded -> $($resp | ConvertTo-Json -Compress)" -ForegroundColor Green
} catch {
    Write-Host "WARNING: backend did not respond. The dashboard will still start and show" -ForegroundColor Yellow
    Write-Host "'OFFLINE' until the backend is reachable -- it retries connecting on its own." -ForegroundColor Yellow
}

# Auto-detect this laptop's current LAN IP so the Kindle always gets a
# fresh address, even after switching wifi networks (config.lua's
# laptop_ip is just a fallback -- see daemon.lua). Picks the IPv4 address
# on the interface holding the default route, which is the actual
# internet-facing adapter regardless of how many adapters/VPNs are present.
$LaptopIp = $null
$defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Sort-Object -Property RouteMetric | Select-Object -First 1
if ($defaultRoute) {
    $LaptopIp = (Get-NetIPAddress -InterfaceIndex $defaultRoute.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
}
if ($LaptopIp) {
    Write-Host "Detected this laptop's LAN IP: $LaptopIp" -ForegroundColor Green
} else {
    Write-Host "Could not auto-detect this laptop's LAN IP." -ForegroundColor Yellow
    $LaptopIp = Read-Host "Enter it manually (check with 'ipconfig', IPv4 Address under your active adapter)"
}

# $LaptopIp gets embedded directly into a remote shell command string below
# (export LAPTOP_IP='...'), so validate it's a literal IPv4 address first --
# closes off shell injection via the manual-entry fallback above.
if ($LaptopIp -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
    Write-Host "'$LaptopIp' doesn't look like a valid IPv4 address. Cannot continue." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Connecting to Kindle at $KindleIp ..."
$sshTarget = "root@$KindleIp"
$sshOpts = @("-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new", "-p", "2222")

# Quick reachability check first, so a wrong/stale IP gives a clear error
# instead of a confusing downstream failure.
$testResult = & ssh @sshOpts $sshTarget "echo ok" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAILED to connect to $KindleIp" -ForegroundColor Red
    Write-Host $testResult -ForegroundColor Red
    Write-Host ""
    Write-Host "Common causes: KOReader's SSH server isn't turned on, or the IP has" -ForegroundColor Yellow
    Write-Host "changed since last time (it moves around via DHCP) -- check the current" -ForegroundColor Yellow
    Write-Host "IP on the Kindle's SSH server screen and run this again." -ForegroundColor Yellow
    exit 1
}

# Only save the IP once we know it actually works, so next time's default
# is never a stale/wrong one.
Set-Content -Path $IpCacheFile -Value $KindleIp -NoNewline

Write-Host "Connected. Starting the dashboard -- this also stops KOReader's own UI on" -ForegroundColor Green
Write-Host "the Kindle (expected; see kindle-daemon/README.md for why)." -ForegroundColor Green

$startCmd = "killall -q -s KILL luajit 2>/dev/null; rm -f /mnt/us/kindle-daemon/crash.log; " +
            "export LAPTOP_IP='$LaptopIp'; " +
            'cd /mnt/us/kindle-daemon/bin && nohup sh run.sh > /tmp/runsh_stdout.log 2>&1 & sleep 3; echo done'
& ssh @sshOpts $sshTarget $startCmd | Out-Null

Write-Host ""
Write-Host "Checking it started cleanly ..."
$psOut = & ssh @sshOpts $sshTarget 'ps | grep "[l]uajit"'
$crashOut = & ssh @sshOpts $sshTarget 'cat /mnt/us/kindle-daemon/crash.log 2>/dev/null'
# crash.log always has one benign status line from run.sh itself
# ("stopping KOReader/Xorg...") even on a totally clean start, so its
# mere presence isn't a failure signal -- LuaJIT's actual crash output
# always includes "stack traceback:", which is what we check for instead.
$looksCrashed = $crashOut -match "stack traceback:"

if ($psOut -and -not $looksCrashed) {
    Write-Host "SUCCESS: the dashboard is running on the Kindle." -ForegroundColor Green
} elseif ($psOut) {
    Write-Host "Process is running, but crash.log shows an error trace:" -ForegroundColor Red
    Write-Host $crashOut
} else {
    Write-Host "FAILED: the process is not running. crash.log:" -ForegroundColor Red
    Write-Host $crashOut
}
