<#
.SYNOPSIS
    Stops the Kindle Dashboard and reboots the Kindle back to its normal
    home screen / KOReader. Also removes the boot-time autostart job if
    it's present (idempotent -- safe whether or not it's actually there),
    so a reboot never surprises you by relaunching the dashboard on its
    own -- it should only ever start when you explicitly run
    Start_Dashboard.bat.
#>

$ErrorActionPreference = "Continue"
$IpCacheFile = Join-Path $PSScriptRoot ".last_kindle_ip.txt"

Write-Host "=== Stop Kindle Dashboard ===" -ForegroundColor Cyan
Write-Host ""

$lastIp = if (Test-Path $IpCacheFile) { (Get-Content $IpCacheFile -Raw).Trim() } else { $null }
if ($lastIp) {
    $inputIp = Read-Host "Kindle IP address [$lastIp]"
} else {
    $inputIp = Read-Host "Kindle IP address (find it on the KOReader SSH server screen)"
}
$KindleIp = if ([string]::IsNullOrWhiteSpace($inputIp)) { $lastIp } else { $inputIp.Trim() }

if ([string]::IsNullOrWhiteSpace($KindleIp)) {
    Write-Host "No IP address given, and no previous one saved. Cannot continue." -ForegroundColor Red
    exit 1
}

$sshTarget = "root@$KindleIp"
$sshOpts = @("-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new", "-p", "2222")

Write-Host ""
Write-Host "Connecting to Kindle at $KindleIp ..."
$testResult = & ssh @sshOpts $sshTarget "echo ok" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAILED to connect to $KindleIp" -ForegroundColor Red
    Write-Host $testResult -ForegroundColor Red
    Write-Host ""
    Write-Host "Common causes: KOReader's SSH server isn't turned on, or the IP has" -ForegroundColor Yellow
    Write-Host "changed since last time -- check the current IP on the Kindle's SSH" -ForegroundColor Yellow
    Write-Host "server screen and run this again." -ForegroundColor Yellow
    exit 1
}

Set-Content -Path $IpCacheFile -Value $KindleIp -NoNewline

Write-Host "Connected. Stopping the dashboard and rebooting back to normal..." -ForegroundColor Green
Write-Host "(also removing the boot-time autostart job if present, so a reboot" -ForegroundColor Green
Write-Host "never relaunches the dashboard on its own)" -ForegroundColor Green

$stopCmd = 'killall -q -s KILL luajit 2>/dev/null; rm -f /etc/upstart/kindle-dashboard.conf; sync; reboot'
& ssh @sshOpts $sshTarget $stopCmd 2>&1 | Out-Null

Write-Host ""
Write-Host "SUCCESS: stop command sent, the Kindle is rebooting now." -ForegroundColor Green
Write-Host "Give it 30-60 seconds -- it should come back up showing the normal" -ForegroundColor Green
Write-Host "Kindle/KOReader screen." -ForegroundColor Green
