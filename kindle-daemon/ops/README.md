# Kindle Dashboard — day-to-day on/off

Two files you double-click on your laptop to switch the Kindle between
its normal reading mode and the dashboard. No reinstalling, no rebooting
by hand.

## Every time you want the dashboard

1. **On the Kindle**: open KOReader, go to Tools > SSH server, turn it on.
   Leave that screen open so you can read the IP address it shows.
2. **On your laptop**: double-click `Start_Dashboard.bat`. It'll ask for
   the Kindle's IP (shown in step 1) — press Enter to reuse the last one
   if it hasn't changed. It checks your laptop backend, connects over
   SSH, and starts the dashboard. Takes a few seconds; watch your Kindle
   screen switch over.

## When you want your Kindle back for reading

Double-click `Stop_Dashboard.bat`. It asks for the IP the same way,
stops the dashboard, and reboots the Kindle — after ~30-60 seconds it
comes back up showing the normal Kindle/KOReader home screen, exactly as
if the dashboard had never been installed.

(Stopping always reboots, deliberately — cleanly restarting the Kindle's
own reading UI without a reboot isn't something that could be tested
safely, so a reboot is the one path that's actually been proven to work.)

## Notes

- The Kindle's IP address changes over time (your router hands out a new
  one). Both scripts remember the last one that worked in
  `.last_kindle_ip.txt` in this folder, so most of the time you can just
  press Enter — but if a script fails to connect, that's almost always
  why; check the current IP on KOReader's SSH server screen and try
  again.
- Your laptop backend needs to be running for the dashboard to show real
  data (it should be running automatically already — see
  `backend/ops/AUTOSTART_SETUP.md`). `Start_Dashboard.bat` warns you if
  it can't reach it, but still starts the dashboard either way — it'll
  just show `OFFLINE` until the backend's reachable.
- Your laptop's own IP address doesn't need to be kept up to date by hand
  anymore. `Start_Dashboard.bat` auto-detects it fresh every time you run
  it and tells the Kindle, so switching wifi networks (new house, new
  router, coffee shop, etc.) just works on the next start — no editing
  `config.lua` required. (`config.lua`'s `laptop_ip` value is still there
  as a fallback for the manual SSH-testing steps in `INSTALL.md`, but the
  normal day-to-day path here always overrides it.)
- **And if your laptop's address changes while the dashboard is already
  running, it now recovers on its own** — the backend announces its
  address on the network every few seconds and the Kindle re-finds it. In
  practice: the badge goes OFFLINE within about 90 seconds of the link
  dying, then back to ONLINE a second or two later. You don't have to do
  anything. If it's still OFFLINE after a couple of minutes, then run
  `Start_Dashboard.bat` — and if that doesn't fix it, check the laptop
  backend is actually running (`Check_Status.bat`) before suspecting the
  Kindle.
- If `Start_Dashboard.bat` reports a crash instead of success, the
  Kindle's screen won't have switched over — your book/KOReader session
  is untouched and safe.
- **A screen showing just the word "Locked" is normal, not a crash.** The
  dashboard locks itself after 15 minutes of nobody touching it, to save
  battery; the power button locks and unlocks it on demand too. Press the
  power button once and the dashboard comes straight back on whatever tab
  it was on. (An entirely *blank* screen with no word on it is a different
  thing and does mean something went wrong — check
  `/mnt/us/kindle-daemon/daemon.log`.) To turn the automatic lock off, set
  `auto_lock_idle_ms = 0` in the Kindle's `src/config.lua`.

## Resolved issue: starting the dashboard used to reboot the Kindle

**FIXED on 2026-08-02 -- this was a real bug in `bin/run.sh`, not a device
problem.** For a while, starting the dashboard reliably rebooted the
Kindle within a few seconds every time (an earlier version of this note
incorrectly blamed a WiFi driver crash for this -- that was a plausible-
looking but wrong theory; the real cause and fix are below).

**Root cause**: `run.sh` used to kill Xorg outright (`killall -s KILL
Xorg`, later tuned to a couple of gentle retries) to free up the
touchscreen. That looks like a *crash* to the stock upstart monitor
(not a deliberate stop), because `lab126_gui` (the stock UI's own
upstart job) stops when Xorg stops and gets respawned by its monitor --
which then raced against our own retry logic. `lab126_gui.conf`'s own
pre-start script has explicit logic for exactly this pattern: restart 3
times in a session (`MAX_RESTARTS=3`) and it calls `reboot` itself,
deliberately -- a stock Amazon crash-recovery safety net, not a random
failure. Confirmed via `/proc/uptime` and live monitoring: starting the
dashboard rebooted the device within single-digit seconds, every time --
too fast for the 60s hardware watchdog, consistent with that explicit
`reboot` call instead.

**Actual current fix**: `run.sh` now calls upstart's own `/sbin/stop x`
(the real job name governing Xorg, confirmed via `initctl list`) instead
of killing Xorg directly. A `stop` issued through upstart's own CLI is a
*deliberate* stop from upstart's point of view -- it never touches the
`RESTARTS` counter `lab126_gui.conf` checks, so the whole reboot-safety-net
risk is gone rather than just made less likely. (An earlier, now-superseded
version of this fix just reduced the retry-kill from 30 attempts at 1s
intervals down to 2 gentle attempts -- that only reduced the risk; `stop x`
eliminates it. The retry-kill loop no longer exists in `run.sh` at all.)
Verified live, repeatedly: 5+ clean dashboard (re)starts in a single boot
session with zero reboots, `/proc/uptime` staying monotonic throughout.

**Known residual behavior, not currently a reboot risk, but can look like
a hang/crash**: Xorg (and sometimes KOReader's `reader.lua` itself) can
still respawn on its own some time after the dashboard starts -- the stock
monitor doesn't know we don't want it back, and this isn't something
`stop x` prevents from happening *later*, only from causing a *reboot*.
If a future session hears "the dashboard just silently stopped responding"
or "touch stopped working partway through a session," check `ps | grep
reader.lua` over SSH -- if it's back, that's the explanation, not a new
crash. This has been observed to correlate with the dashboard daemon's own
`luajit` process having already died for an unrelated reason (see the WS
disconnect issue below) rather than being the original cause.

## Resolved issue: dashboard worked, then dropped offline / rebooted a few seconds after connecting, only on some wifi networks

**FIXED on 2026-08-03.** After moving to a new wifi network, the dashboard
would connect successfully, then drop offline (or in some cases reboot the
Kindle) within about 3-8 seconds every time, then fail to reconnect with
"network unreachable" errors in `daemon.log`.

**Root cause**: the Kindle's own wifi radio power-save mode was **on**
(`iw wlan0 get power_save` read back "on"). With it on, the radio
periodically drops its own connection to save power — confirmed in
`/var/log/wpa_supplicant` as a *locally generated* disconnect
(`CTRL-EVENT-DISCONNECTED ... reason=3 locally_generated=1`), i.e. the
Kindle voluntarily dropping the link, not the router kicking it off. Each
drop killed the dashboard's WebSocket, and the resulting scramble
(wifi re-associating, the stock UI's own network-status handling kicking
in) sometimes cascaded into the stock reboot-safety-net described above.

This looked at first like it might be the wifi router's fault (e.g. a mesh
network's band-steering behavior), since it only started after switching
networks — but a laptop's IP changing on a new network is unrelated to
this, and the actual trigger (radio power-save) is a **per-boot Kindle
setting**, reset to "on" by every reboot, not something the router
controls.

**Fix**: `bin/run.sh` now runs `iw wlan0 set power_save off` every time the
dashboard starts, right alongside the existing screensaver-prevention
line. Verified live: WebSocket stayed connected with zero drops for 60+
seconds straight afterward, vs. dropping within single-digit seconds every
time before.

**If this ever recurs** (e.g. on a different Kindle unit, or after a
firmware update resets driver defaults), check `iw wlan0 get power_save`
first — if it reads "on" despite `run.sh` having run, either `iw` isn't on
`PATH` in that shell context or the interface name isn't `wlan0` on that
device.

## Minor fix: dashboard daemon didn't back off on a hard connect failure

**FIXED on 2026-08-03.** `daemon.lua`'s WebSocket reconnect logic applies
an exponential backoff (2s doubling up to 30s) when a connection opens and
then later drops — but that backoff was never applied when `connect()`
itself failed outright (e.g. genuinely no route to the laptop). In that
case it retried as fast as the main loop's ~500ms poll cadence allowed,
forever, instead of backing off during a real prolonged outage. Fixed so
both failure paths use the same backoff. Not confirmed to have caused any
specific incident on its own — found by reading the code while
investigating a one-off silent daemon death, and fixed as cheap insurance
either way.

## Known gap, deliberately left unfixed: Windows Firewall is Public-profile-only

**Not fixed — needs an admin PowerShell window, and the user chose to
defer it (2026-08-03).** The Windows Firewall rule that lets the Kindle
reach the laptop backend on port 8000 (`python.exe` inbound) is scoped to
the **Public** network-category profile only. It currently works because
`Get-NetConnectionProfile` shows the current wifi is itself classified
Public by Windows — but if a *future* wifi network gets classified
**Private** instead (a common default for home networks, independent of
anything this project controls), there's no matching rule and the Kindle
would be unable to reach the backend on that network at all.

**This shows up as "dashboard stuck on OFFLINE / can't connect on this
wifi network"** — not a reboot loop, a distinct symptom. If a future
session hits this, check `Get-NetConnectionProfile` (the `NetworkCategory`
column) and `Get-NetFirewallRule -DisplayName python.exe` (the `Profile`
column) before re-diagnosing the Kindle/daemon side again. The fix is a
single elevated command (run from an admin PowerShell window):

```powershell
New-NetFirewallRule -DisplayName "Kindle Dashboard backend (port 8000, all profiles)" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Any -Program "<path to your python.exe>"
```

To find your own `python.exe` path, run `(Get-Command python).Source` in
PowerShell and paste the result in place of `<path to your python.exe>` above.
