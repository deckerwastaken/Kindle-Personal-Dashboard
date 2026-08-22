# Kindle Dashboard - Full Launch Guide (start to finish)

This is the single guide to follow to get the whole system running. It stitches
together three separate guides that already exist in this repo - you don't need to
read those separately, but they're linked below if you ever want more detail on one
piece. **No coding experience is assumed** - every command you're asked to type is
given in full, and every piece of jargon (SSH, jailbroken, etc.) is explained the
first time it comes up.

**Before you start, you need:**
- **A jailbroken Kindle** with KUAL and KOReader already installed. "Jailbroken" means
  the device's normal Amazon-imposed restrictions have been removed so it can run
  outside software - this is a separate, well-documented process this guide doesn't
  cover; see `docs/JAILBREAK_REFERENCE.md` if you haven't done this part yet. Everything
  below assumes it's already done.
- **A Windows laptop** that can stay on and connected to the same WiFi as the Kindle
  most of the time (it's what actually runs the "brain" of the dashboard - see
  Part 1).
- **This project's code, downloaded onto that laptop.** If you got this from GitHub and
  haven't done this yet: on the repo's GitHub page, click the green **Code** button →
  **Download ZIP**, then extract it somewhere you'll remember (e.g. your Desktop, or
  `Documents\kindle-dashboard`). Everywhere below that says "the repo root" or "the
  folder you downloaded this project into" means that extracted folder. (If you're
  comfortable with `git`, `git clone` works too - same result.)

**Do the parts in this order.** Each part is designed so nothing you do can brick the
Kindle, as long as you follow the "test manually before enabling autostart" steps and
don't skip them.

1. **Backend** (on your laptop) - the "brain": talks to Telegram and Anthropic, holds
   your task list.
2. **Kindle daemon** (on the Kindle) - the actual dashboard screen and touch handling.
3. **Lockscreen** (on the Kindle) - replaces the sleep screen with "My Dashboard".

You'll need about 30–45 minutes for Part 1, and more like 1–2 hours for Part 2 the
first time (it involves careful manual testing before anything auto-starts). Part 3
takes 5 minutes.

---

## Part 1: Backend (on your laptop)

More detail than you'll usually need: `backend/README.md` and
`backend/ops/AUTOSTART_SETUP.md` - these are written for developers (they cover things
like the WebSocket message format), so only open them if something below doesn't work
and you want to dig deeper. You shouldn't need to read them just to get set up.

### 1.1 Install Python and dependencies

1. If you don't already have it, install Python 3.11 or newer from
   [python.org/downloads](https://www.python.org/downloads/). During install, make sure
   the checkbox **"Add python.exe to PATH"** is ticked.
2. Open PowerShell (Start menu → type "PowerShell" → Enter) and run (replacing the
   path below with the actual folder you downloaded this project into):
   ```
   cd "<path to the folder you downloaded this project into>"
   python -m pip install -r backend/requirements.txt
   ```

### 1.2 Add your secrets

1. In File Explorer, go into the `backend` folder inside wherever you downloaded this
   project, copy `.env.example`, and rename the copy to `.env`.
2. Open `.env` in Notepad and fill in:
   - **`TELEGRAM_TOKEN`** - message [@BotFather](https://t.me/BotFather) on Telegram,
     create a bot (`/newbot`), and it will give you a token.
   - **`CHAT_ID`** - your personal Telegram chat ID. Easiest way: message
     [@userinfobot](https://t.me/userinfobot) on Telegram and it will reply with your
     numeric ID.
   - **`ANTHROPIC_ADMIN_KEY`** - optional. From the Anthropic Console, an Admin-tier API
     key (starts with `sk-ant-admin`). Leave the placeholder if you don't have one yet -
     everything else still works, you just won't get Claude usage numbers.
   - **`CLAUDE_SESSION_KEY`** / **`CLAUDE_ORG_ID`** - optional, and more involved to set
     up (see `backend/README.md`'s step-by-step for these two specifically if you want
     the "how much of my Claude session have I used" card). Skip both for now if you'd
     rather come back to this later - everything else works fine without them.
3. Save and close. This file is already excluded from git - it will never accidentally
   get committed.

### 1.3 Test it manually once

```
cd "<path to the folder you downloaded this project into>"
uvicorn backend.main:app --host 0.0.0.0 --port 8000
```

Leave this window open. On your phone (connected to the same WiFi), open a browser and
go to `http://<your-laptop-ip>:8000/health` - find your laptop's IP by running
`ipconfig` in a **new** PowerShell window and looking for "IPv4 Address" under your WiFi
adapter (looks like `192.168.1.xxx`). You should see `{"status":"ok"}`.

> **If your phone's browser just hangs / times out here** (not an immediate error -
> specifically a request that never finishes loading), the most likely cause is
> Windows Firewall silently blocking the connection. Windows classifies every WiFi
> network as either "Public" or "Private," and by default a firewall rule allowing
> this only gets created for "Public" - many home networks are actually classified
> "Private." To check and fix: open PowerShell and run
> `Get-NetConnectionProfile` - look at the `NetworkCategory` value for your WiFi
> network. If it says `Private`, run this once (as an Administrator PowerShell
> window: right-click the Start button → "Terminal (Admin)" or "Windows PowerShell
> (Admin)") to explicitly allow this app through on any network profile, replacing
> the placeholder with your own `python.exe` path (find it by running
> `(Get-Command python).Source`):
> ```
> New-NetFirewallRule -DisplayName "Kindle Dashboard backend (port 8000, all profiles)" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Any -Program "<path to your python.exe>"
> ```
> Then try the phone test again.

Try messaging your bot on Telegram: `/add test task`, then `/list` - it should reply
with your task. Send `/help` to see everything it understands; typing `/` on your
phone also pops up a menu of every command, so you never have to memorise them.

To try the learning tracker: `/course Spanish` adds a course, `/percent L1 40` sets it
to 40%. `/book Atomic Habits 320` adds a book, `/page L2 120` records what page you're
on and works the percentage out for you. Tasks are numbered `#1 #2`, learning items
`L1 L2`, so the two never get mixed up.

If that works, close this window (Ctrl+C) and move to the next step.

### 1.4 Make it start automatically

1. Go to `backend\ops\` in File Explorer.
2. Double-click **`Install_Autostart.bat`**. If Windows shows a blue "Windows protected
   your PC" popup, click **More info** → **Run anyway** - this is expected for an
   unsigned script you wrote yourself.
   - If instead you get an **`Access is denied`** error, your Windows account isn't
     allowed to register Scheduled Tasks. Double-click **`Install_Autostart_NoAdmin.bat`**
     instead - it does the same job (auto-start at logon, restart on crash) via your
     Windows Startup folder instead, which never needs elevated permissions.
3. Double-click **`Check_Status.bat`** - you should see `SUCCESS: server responded`.

That's Part 1 done - the backend now runs automatically every time you log into
Windows, restarts itself if it crashes, and logs to `backend\logs\`. Full day-to-day
controls (`Stop_Backend.bat`, `Restart_Backend.bat`, `View_Latest_Log.bat`, etc.) are in
`backend\ops\AUTOSTART_SETUP.md`.

> **Keep in mind**: this only works while your laptop is logged in and awake. If you
> want the Kindle to always be able to reach it, go to Windows Settings → System →
> Power & battery → Screen and sleep, and set "When plugged in, put my device to sleep"
> to **Never**.

---

## Part 2: Kindle daemon (on the Kindle)

Full reference: `kindle-daemon/INSTALL.md` - this is the detailed version; below is the
same steps condensed. **Follow the detailed version if anything here is unclear**, it
has more explanation at each step.

Prerequisite: you need a shell prompt on the Kindle itself (SSH) - not just USB file
copying. **SSH** just means typing commands on the Kindle remotely from your laptop,
like a remote command line, instead of only being able to drag-and-drop files onto it
over USB. If you don't have that yet, see **"Before you start: get a shell (SSH) prompt
on the Kindle"** near the top of `kindle-daemon/INSTALL.md` - it walks through turning
on KOReader's built-in SSH server, generating a key on your laptop, and connecting. Two
things worth knowing up front:
- SSH is on port **2222**, not the default 22:
  `ssh root@<kindle-ip> -p 2222`
- The Kindle's IP address can change whenever it reconnects to WiFi. Always read the
  current one off the KOReader SSH server screen (or your router's connected-devices
  page) rather than reusing an old one - a "Connection refused" error (not a timeout)
  usually means the IP changed, not that the server crashed.

1. **Back up first**: connect the Kindle via USB, copy the `documents` and `koreader`
   folders somewhere safe on your computer. Costs two minutes, matters more for Part 3.
2. **Copy the files**: copy the whole `kindle-daemon` folder onto the Kindle's root
   (over USB), so you get `/mnt/us/kindle-daemon/` on the device. Eject safely
   afterward (Windows "Safely Remove Hardware" - don't just unplug).
3. **Configure it**: copy `kindle-daemon/config.example.lua` to
   `kindle-daemon/src/config.lua` and edit `laptop_ip` to your laptop's actual IP
   address (same one from step 1.3 above).
4. **Confirm the backend is reachable**: on your phone, visit
   `http://<laptop-ip>:8000/health` again - must say `{"status":"ok"}` before continuing.
5. **Test touch input** (over SSH on the Kindle):
   ```sh
   cd /mnt/us/kindle-daemon/tools
   /mnt/us/koreader/luajit evtest.lua
   ```
   **Expect KOReader's screen to go blank/frozen the moment you run this - that's
   normal, not a bug or a bricked device** (this tool needs exclusive access to the
   touch panel, so it briefly takes it away from KOReader). Tap the screen once
   firmly - you should see printed output in your SSH window. Ctrl+C to stop, and
   KOReader's screen comes back. See `kindle-daemon/INSTALL.md` step 3 if the output
   looks wrong or the wrong device gets picked.
6. **Test screen drawing**:
   ```sh
   cd /mnt/us/kindle-daemon/tools
   sh fbink_selftest.sh
   ```
   Confirms the on-screen text lands where it should. Follow its printed instructions if
   not.
7. **Run the real dashboard manually - do not skip this**:
   ```sh
   cd /mnt/us/kindle-daemon/bin
   sh run.sh
   ```
   You should see the dashboard: time/date, a battery percentage in the top-right,
   your tasks, a Claude usage card, and a bottom nav bar. It should say `ONLINE`
   within a few seconds. Tap a checkbox - it should toggle. Send `/add something` on
   Telegram - it should appear on screen without you touching anything. Tap the
   **Learning** tab at the bottom to see your courses and books, and **Today** to come
   back. Press the **power button** once to blank the screen (this also pauses the
   dashboard's background work to save battery) and again to bring it back. Let it run
   a few minutes, then Ctrl+C.

   If the battery shows a gray `--%`, the dashboard couldn't read this Kindle's battery
   level and is saying so honestly rather than showing a made-up number. Everything
   else still works; see "Battery shows `--%`" in `kindle-daemon/INSTALL.md` for the
   one-command fix.
8. **Set up on-demand start/stop from your laptop (the recommended day-to-day way to
   use this)** - once step 7 worked cleanly, you don't need to keep an SSH terminal
   open every time. Full reference: `kindle-daemon/ops/README.md`. Short version: turn
   on KOReader's SSH server on the Kindle, then double-click
   `kindle-daemon\ops\Start_Dashboard.bat` on your laptop - it connects and starts the
   dashboard for you. When you want your Kindle back for reading, double-click
   `kindle-daemon\ops\Stop_Dashboard.bat` - it stops the dashboard and reboots back to
   the normal Kindle/KOReader screen.

   **Alternative: boot-time autostart.** If you'd rather the dashboard launch
   automatically on every boot (meaning the Kindle would no longer boot into normal
   reading mode by default), `kindle-daemon/INSTALL.md` Step 6 covers that instead -
   it's a deliberate opt-in, not what this guide sets up by default, since most people
   want normal Kindle boot to stay available for reading.

---

## Part 3: Lockscreen - "My Dashboard" (on the Kindle)

Full reference: `lockscreen/INSTALL.md`. Do **Tier 1 only** first - it's a KOReader
settings change with zero risk.

1. Open KOReader on the Kindle.
2. Find its settings → **Screensaver** (may be nested under "Screen" depending on your
   KOReader version - use in-app settings search if you can't find it).
3. Set the screensaver's message/text to exactly: `My Dashboard`
4. Put the Kindle to sleep while KOReader is the active app, then wake it - confirm you
   see "My Dashboard".
5. Then check the **gap case**: go to the native Kindle Home screen (exit KOReader),
   let it sleep, and check what shows up there. If it's still Amazon's stock image, that
   gap is covered by an optional, more experimental **Tier 2** step in
   `lockscreen/INSTALL.md` - only worth doing if you expect the device to often be
   sitting on the native Home screen (rather than inside KOReader/the dashboard) when it
   falls asleep. It's clearly marked experimental for a reason: it requires you to find
   one Kindle-specific setting on your own device rather than relying on a guess, so
   follow that file's Step 4 carefully if you go there.

---

## Final check: is everything actually working end to end?

- [ ] Backend auto-starts when you log into Windows (`Check_Status.bat` says SUCCESS)
- [ ] `kindle-daemon\ops\Start_Dashboard.bat` connects and starts the dashboard, showing
      `ONLINE` (or `kindle-daemon/INSTALL.md` Step 6's boot-autostart, if you chose that
      alternative instead)
- [ ] Adding a task via Telegram shows up on the Kindle without touching it
- [ ] Tapping a checkbox on the Kindle marks it done (check via `/list` on Telegram too)
- [ ] Turning laptop WiFi off/on shows `OFFLINE` then `ONLINE` again on the Kindle
- [ ] Sleeping the Kindle shows "My Dashboard" instead of the stock screensaver

## If something needs fixing later

- Backend logs: `backend\logs\` (one file per day) - or double-click
  `backend\ops\View_Latest_Log.bat`.
- Kindle daemon logs: `/mnt/us/kindle-daemon/daemon.log` (taps, redraws, connection
  state) and `/mnt/us/kindle-daemon/crash.log` (should normally be empty).
- To change the laptop's IP or any daemon setting: edit
  `/mnt/us/kindle-daemon/src/config.lua` on the device and reboot (or kill the
  `luajit daemon.lua` process over SSH - upstart brings it back with the new config).
- To update backend code/secrets: `Stop_Backend.bat` → make your change →
  `Start_Backend_Now.bat` → `Check_Status.bat`.
