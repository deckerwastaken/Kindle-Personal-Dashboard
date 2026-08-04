# kindle-daemon -- On-device install & test guide

Written for someone physically holding the Kindle, who has never used
upstart, FBInk, or Lua before. Follow the steps **in order** -- do not
skip ahead to the "auto-start at boot" step until every earlier step has
worked. Every step before that is designed so a mistake just means "the
dashboard doesn't work yet", never "the Kindle won't turn on."

You'll need:
- The Kindle, jailbroken, with KUAL and KOReader already working (see
  `docs/JAILBREAK_REFERENCE.md` if you haven't done this yet -- this
  guide assumes that part is already done).
- A way to get files onto the Kindle (USB Mass Storage mode) and a shell
  prompt on it (SSH). If you don't have SSH access set up yet, see
  **"Before you start: get a shell (SSH) prompt on the Kindle"** right
  below -- do that first, then come back here.
- Your laptop's LAN IP address. On Windows: open Command Prompt, run
  `ipconfig`, and look for "IPv4 Address" under your WiFi adapter (looks
  like `192.168.1.xxx`).

---

## Before you start: get a shell (SSH) prompt on the Kindle

Steps 3 onward run commands directly on the Kindle, so you need a
terminal into it before then. If you already have SSH or Telnet working
(e.g. a KUAL extension from jailbreaking), skip ahead to Step 0. Otherwise,
here's the confirmed-working way, using KOReader's own built-in SSH
server (no extra jailbreak extension needed):

### One-time setup

1. **Turn on KOReader's SSH server.** On the Kindle, open KOReader, go to
   its tools/settings menu, and find **SSH server** (this runs a small
   program called "dropbear" -- you don't need to know anything about it
   beyond that it's what listens for your connection). Turning it on
   shows a screen with the Kindle's current IP address and port. Leave
   this screen open for now.
2. **Generate a key pair on your laptop** (one time only). Open
   PowerShell and run:
   ```
   ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_ed25519" -N '""'
   ```
   Press Enter through any prompts (default location, no passphrase).
   This creates a private key file (never copy this one off your laptop)
   and a matching `.pub` public key file.
3. **Copy the public key onto the Kindle.** Open the `.pub` file from
   step 2 in Notepad and copy its one line of text. Connect the Kindle
   over USB as storage, then create/open this file on the device and
   paste that line in (create the `SSH` folder if it isn't there yet):
   ```
   <kindle-drive-letter>:\koreader\settings\SSH\authorized_keys
   ```
   Save the file, then eject the Kindle safely ("Safely Remove
   Hardware" -- don't just unplug it).
4. Back on the Kindle's SSH server settings screen, turn on the option
   for **key-based login only** (wording may vary slightly by KOReader
   version). This disables password login entirely -- from then on, only
   your laptop's private key can get in.

### Every time you want to connect

1. On the Kindle, open KOReader's SSH server screen -- it shows the
   current IP address and port (normally **2222**, not the default 22).
   - **The Kindle's IP can change** any time it reconnects to WiFi (your
     router hands out a new one via DHCP). Always read the current IP
     off this screen, or your router's "connected devices" admin page,
     rather than trusting an IP you used last time.
2. On your laptop, open PowerShell and run (swap in the current IP):
   ```
   ssh root@<kindle-ip> -p 2222
   ```
   No password prompt -- it logs in automatically using the key from
   setup steps 2--3.
   - If SSH warns the host key doesn't match what it expected, but
     you're sure it's still the same Kindle (just a new IP), it's safe
     to accept -- this is expected whenever the IP changes.
   - If you get **"Connection refused"** specifically (not a timeout,
     not "no route to host") -- even if `ping` to that IP still works --
     the most likely cause is the IP changed and that address now
     belongs to a different device (or nothing). Go back to step 1 and
     re-read the current IP; don't assume the SSH server itself crashed.

You now have a root shell on the Kindle. Continue to Step 0 below.

---

## Step 0: Back up before touching anything

You will not be editing any stock Amazon files for this daemon (unlike
the screensaver piece in `lockscreen/`, which does touch a shared boot
mechanism) -- everything here lives in a new folder you create. Still,
take two minutes now:

1. Connect the Kindle over USB, mount it as storage.
2. Copy the entire `documents` folder and the `koreader` folder somewhere
   safe on your computer, just in case. (You almost certainly won't need
   this for this particular piece, but it costs nothing and the habit
   matters for the `lockscreen/` steps later, which are riskier.)

---

## Step 1: Copy the files onto the Kindle

1. Connect the Kindle over USB, mount it as storage.
2. Copy this entire `kindle-daemon` folder to the Kindle's root, so you
   end up with `/mnt/us/kindle-daemon/` on the device (on Windows,
   that's the Kindle's drive letter, e.g. `E:\kindle-daemon\`).
3. On the device (or by editing the file on your computer before
   copying it over -- either works), copy the config template:
   - Rename/copy `kindle-daemon/config.example.lua` to
     `kindle-daemon/src/config.lua` (note: it must end up **inside**
     `src/`, not next to it).
   - Open `config.lua` in a plain text editor and set `laptop_ip` to
     your laptop's actual LAN IP address from the "you'll need" list
     above. Leave everything else at its default for now.
4. Eject the Kindle safely (use Windows' "Safely Remove Hardware", don't
   just unplug it -- an interrupted USB write is a common way these
   devices get stuck in a bad state during setup, per
   `docs/JAILBREAK_REFERENCE.md`).

---

## Step 2: Make sure your laptop backend is actually running

On your laptop, from the repo root (the folder where you downloaded/cloned this
project -- e.g. `cd "C:\Users\<you>\kindle-dashboard"`, wherever you put it):

```
cd "<path to the folder you downloaded this project into>"
uvicorn backend.main:app --host 0.0.0.0 --port 8000
```

Leave this window open. Confirm it's reachable from another device on
your WiFi (e.g. open `http://<laptop-ip>:8000/health` in a phone browser
on the same WiFi network) -- you should see `{"status":"ok"}`. If that
doesn't work, fix it before continuing; nothing past this point will
connect successfully otherwise (though the daemon is designed to just
keep retrying quietly rather than crash, so it's not dangerous to
continue anyway if you want to test drawing first).

---

## Step 3: Test touch input BEFORE trusting it

Get a shell prompt on the Kindle (SSH/Telnet, however your jailbreak
setup provides it). Then:

```sh
cd /mnt/us/kindle-daemon/tools
/mnt/us/koreader/luajit evtest.lua
```

**Before you run this: expect KOReader's UI to disappear from the
screen.** Confirmed on-device (2026-08-02) -- while KOReader is running,
Xorg (the X server it runs under) holds an exclusive grab on the
touchscreen device, so nothing else can read a single touch event from
it, no matter what. `evtest.lua` kills `reader.lua`/`Xorg` itself before
opening the device, for the same reason `run.sh` does the same thing for
the real daemon (see Step 5) -- otherwise this test wouldn't tell you
anything true about how the daemon will actually behave. If your screen
goes blank/frozen after running this, that's expected, not a bug; a
normal reboot brings KOReader straight back, nothing here is persisted.
If you *don't* see this happen and taps still produce no output, that's
the interesting case -- paste the raw output for help, per below.

- It will print a list of input devices it found and which one it
  guessed is the touchscreen.
- **Tap the screen firmly, once, in one spot.** You should see a burst
  of printed lines.
- Read the comment at the top of `evtest.lua` (or `src/touch.lua`) for
  what to look for. You're checking whether this matches the "type A"
  or "type B" touch protocol the code already handles -- if you see
  neither, stop and don't proceed past this step until you understand
  what your panel is actually sending (paste the raw output somewhere
  you can get help interpreting it).
- Press Ctrl+C to stop it.

If auto-detect picked the wrong device (e.g. it's grabbing a button
device instead of the touch panel), note the correct `/dev/input/eventN`
path from the printed list and set `touch_device_path` in
`src/config.lua` to that exact path, then re-run `evtest.lua` with that
path as an argument to confirm:

```sh
/mnt/us/koreader/luajit evtest.lua /dev/input/event2
```

---

## Step 4: Calibrate the screen drawing BEFORE trusting it

```sh
cd /mnt/us/kindle-daemon/tools
sh fbink_selftest.sh
```

This draws five small text labels near the four corners and the center
of the screen. Read the on-screen instructions it prints afterward. If
the labels don't land roughly where their text says they should, follow
the adjustment note it prints (editing `LAYOUT.origin_x`/`origin_y` in
`src/ui.lua`) before moving on -- otherwise the real dashboard's layout
will be off in the same way.

---

## Step 5: Run the daemon manually (NOT via boot yet)

This is the most important safety step in this whole guide: **you must
run this by hand and watch it work before it is ever allowed to start
automatically at boot.** A script that hangs or crashes when run manually
is easy to stop (Ctrl+C) and fix. The same script wired into boot, if it
somehow interfered with the boot sequence, would be much harder to
recover from.

```sh
cd /mnt/us/kindle-daemon/bin
sh run.sh
```

What should happen:
- The screen clears and redraws as the dashboard: time/date header,
  "TODAY" with your task list (or "Waiting for data from laptop..." if
  the backend isn't reachable yet), a "CLAUDE USAGE" card, and a bottom
  nav bar.
- Within a few seconds (once it reaches your laptop), the header's
  status indicator should say `ONLINE` instead of `OFFLINE`/`CONNECTING`.
- Tapping a task's checkbox should toggle it (check the log file at
  `/mnt/us/kindle-daemon/daemon.log` if nothing visibly happens --
  it logs every tap and what zone, if any, it hit).
- Tapping "Lists", "Habits", or "Home" should flash a small "coming soon"
  message near the bottom.

Leave it running for a few minutes. Try:
- Turning your laptop's WiFi off and back on, or restarting the backend
  process -- the dashboard should show `OFFLINE`, then recover to
  `ONLINE` on its own without you touching the Kindle.
- Sending `/add something` via Telegram to your bot -- the new task
  should appear on the Kindle without you tapping anything.

### Also test the on-device controls (new)

Do these BEFORE trusting them day-to-day -- they're described in detail
in README.md's "On-device controls" section:

- **Add Task**: tap "+ Add Task" below your task list. You should see a
  full-screen lowercase keyboard. Type a short word, watch the preview
  strip update after each key (should feel snappy -- it's a fast partial
  refresh, not a full-screen redraw), then tap "Add". You should land
  back on the dashboard and see your new task appear (also check it shows
  up via Telegram/the backend, confirming the WebSocket round-trip
  worked). Try "Cancel" too, and confirm it discards your typing without
  sending anything.
- **Delete Task**: tap the small "x" at the right edge of a task row --
  the row should visibly highlight ("armed"). Tap the SAME "x" again
  within a few seconds -- the task should disappear. Then try arming one
  and tapping somewhere else instead (a different task, empty space) --
  it should just un-highlight with nothing deleted.
- **Restart SSH**: with SSH already connected (like the session you're
  reading this over), tap "Restart SSH" -- it should show a toast saying
  SSH is already running (harmless no-op). To actually test the "start
  it from cold" path, you'd need SSH to be OFF when you tap it, which
  means testing this specific path requires physical access to the
  Kindle's screen without an existing SSH session -- not something to
  test for the first time when SSH is your only way back in. The command
  it runs (`config.ssh_restart_cmd` in `config.lua`) is copied directly
  from KOReader's own SSH server code (see config.example.lua's comment
  for exactly what was verified), so it's expected to work, but hasn't
  been exercised end-to-end via this button specifically yet.
- **Exit Dashboard**: save this for last, once everything else above has
  checked out -- tapping "Yes, Shut Down" reboots the device. Tap "Exit
  Dashboard", confirm you land on the Cancel/"Yes, Shut Down" screen, tap
  **Cancel** first to confirm that path works and returns you to the
  dashboard. Only then, when you're ready, tap "Exit Dashboard" again and
  confirm for real -- the Kindle should show "Shutting down...", then
  reboot back to normal KOReader within the usual 30-60 seconds.

Stop it with Ctrl+C when you're satisfied. Check
`/mnt/us/kindle-daemon/daemon.log` and
`/mnt/us/kindle-daemon/crash.log` -- the second one should be empty or
near-empty; if `run.sh` immediately printed an error into it and exited,
fix that (missing config.lua, wrong `KOREADER_DIR` path in `run.sh`,
etc.) before proceeding.

**Do not continue to Step 6 until Step 5 has worked cleanly at least
once.**

---

## Step 6: Auto-start at boot

**This step is optional, and not the recommended default.** It means the
dashboard launches automatically on every boot, taking over the screen
from KOReader every time -- normal Kindle boot no longer stays available
for reading. Most people want the opposite: keep normal reading mode as
the default, and start the dashboard on demand only when you want it.
For that, see `kindle-daemon/ops/README.md` instead --
`Start_Dashboard.bat`/`Stop_Dashboard.bat` on your laptop start/stop the
dashboard over SSH without ever touching boot behavior. Only continue
with this step if you specifically want true boot-time autostart instead.

Only once Step 5 works:

1. Look at what upstart jobs already exist on your device, so you can
   sanity-check the assumption this project makes:

   ```sh
   ls /etc/upstart/
   cat /etc/upstart/*.conf | grep -i "lab126_gui\|start on"
   ```

   `install/kindle-dashboard.conf` (in this folder) starts our daemon
   on the event `start on started lab126_gui` -- the most commonly
   documented convention for "once the native Kindle UI has come up" on
   jailbroken Kindles. If your `grep` above shows a *different* job name
   handling the native UI startup on your firmware, edit
   `install/kindle-dashboard.conf`'s `start on`/`stop on` lines to match
   before copying it in. If you're not sure, it's safe to proceed with
   the default -- worst case, if the event name doesn't exist on your
   firmware, this job simply never triggers (the dashboard just won't
   auto-start, exactly like before you added it), not a boot failure.

2. Copy the job file into place:

   ```sh
   cp /mnt/us/kindle-daemon/install/kindle-dashboard.conf /etc/upstart/kindle-dashboard.conf
   ```

   (If `/etc/upstart` is read-only on your device, you'll get a
   permission error here -- that means the filesystem needs remounting
   read-write first, which is a bigger step than this guide covers by
   itself; if you hit this, stop and confirm the correct remount command
   for your specific jailbreak/firmware before continuing, rather than
   guessing.)

3. **Reboot and watch.** Hold the power slider for the reboot (or use
   whatever restart method you've used before on this device).

4. After it boots, check that the dashboard appears automatically, and
   that it still works (touch, WebSocket connection) the same way it did
   in Step 5.

---

## Rollback / restore

Because this job only ever *adds* a new file, rolling back is a single
command, run over SSH/Telnet:

```sh
rm /etc/upstart/kindle-dashboard.conf
```

Reboot afterward. This removes the auto-start behavior entirely; nothing
else on the device was modified by this piece, so there is nothing else
to restore. (`/mnt/us/kindle-daemon/` itself is just a folder of scripts
-- deleting it, if you ever want to fully remove this project, is also
always safe and doesn't touch anything else on the device.)

If the device ever fails to boot normally after Step 6 and you can still
get to a recovery shell or USB access, the fix is the same one-line
`rm` above run from whatever recovery access you have, followed by a
reboot -- this project deliberately avoided anything that modifies
existing stock files specifically so this rollback stays this simple.

---

## Ongoing use

- Logs: `/mnt/us/kindle-daemon/daemon.log` (application-level: taps,
  redraws, connection state) and `/mnt/us/kindle-daemon/crash.log`
  (raw stdout/stderr -- should normally stay empty).
- To change the laptop IP or any other setting, edit
  `/mnt/us/kindle-daemon/src/config.lua` directly on the device and
  either reboot or (if you're SSH'd in) find and kill the running
  `luajit daemon.lua` process -- upstart's `respawn` will bring it back
  up with the new config.
