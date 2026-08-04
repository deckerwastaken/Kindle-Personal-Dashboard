# Making the Backend Start Automatically (No Terminal Required)

This guide sets up the Kindle Dashboard backend so that it:

- Starts by itself whenever you log in to Windows -- no terminal window to open or leave running.
- Restarts itself automatically if it ever crashes.
- Writes everything it does to a log file you can open later if something looks wrong.
- Can be stopped, restarted, or checked on with a single double-click, whenever you want to update code or change your secrets in `backend/.env`.

You do **not** need to install anything extra or understand Windows "services" --
everything here uses Windows' built-in Task Scheduler, driven by a few
double-click-able files in this folder (`backend\ops\`).

You only need to do the numbered **Setup** section once. Everything after that
("Everyday use") is for whenever you want to check on it, stop it, or restart it.

---

## Before you start (one-time, only if you haven't already)

If you already followed `backend/README.md` to install Python, install the
dependencies, and create `backend/.env` with your real secrets, skip straight
to **Setup** below.

If not:

1. Install Python 3.11+ from [python.org](https://www.python.org/downloads/) if it isn't already installed.
2. Open PowerShell, then run (replacing the path with wherever you downloaded this project):
   ```
   cd "<path to the folder you downloaded this project into>"
   python -m pip install -r backend/requirements.txt
   ```
3. Copy `backend\.env.example` to `backend\.env` and fill in your real secrets (Telegram token, chat ID, Anthropic admin key, and optionally the claude.ai session key/org ID). See `backend/README.md` for details on each value.

---

## Setup (do this once)

### Step 1: Install autostart

In File Explorer, go to the `backend\ops\` folder inside wherever you downloaded
this project, e.g.:

```
<path to the folder you downloaded this project into>\backend\ops\
```

Double-click **`Install_Autostart.bat`**.

A black window will pop up and print a few lines, ending with something like:

```
Task state:        Running
Last run result:   0  (0 = started OK)

The backend will now start automatically every time you log in to Windows,
and will keep restarting itself if it ever crashes.
```

Press any key (as prompted) to close the window.

> **If Windows shows a blue "Windows protected your PC" popup:** click **More
> info**, then **Run anyway**. This can happen the first time you run a
> script that isn't digitally signed; it's expected and safe here since you
> can see exactly what the script does (it's a plain text file you can open
> in Notepad if you're curious).

> **If you instead see `Access is denied` / `Register-ScheduledTask : Access
> is denied`:** your Windows account isn't allowed to register Scheduled
> Tasks (common on managed/locked-down accounts), even though this task
> doesn't otherwise need admin rights. Skip to **No-admin alternative**
> below instead -- it does the same job a different way.

That's it -- the backend is now running in the background, and will keep
running (and restart itself if it crashes) from now on, including after you
restart your laptop.

### Step 2: Confirm it's actually working

Double-click **`Check_Status.bat`**. You should see something like:

```
Scheduled task state: Running
Last run time:        ...
Last result code:     0  (0 = OK)

Checking http://localhost:8000/health ...
SUCCESS: server responded -> {"status":"ok"}

Latest log file: <your repo folder>\backend\logs\backend_2026-07-30.log
Last 10 lines:
...
```

If you see `SUCCESS`, you're done -- the Kindle can now connect to your
laptop the same as before, except you never have to manually start anything
again.

If you see `FAILED`, see **Troubleshooting** below.

---

## No-admin alternative

If `Install_Autostart.bat` gave you an `Access is denied` error, use
**`Install_Autostart_NoAdmin.bat`** instead -- same folder, same two steps
(double-click it, then `Check_Status.bat` to confirm). It does the exact
same job -- start the backend automatically at logon, restart it if it
crashes -- but triggers it via a shortcut in your Windows **Startup
folder** instead of a Scheduled Task, which never needs elevated
permissions to set up.

Everything in **Everyday use** and **Troubleshooting** below works exactly
the same regardless of which of the two you installed -- `Check_Status.bat`,
`Stop_Backend.bat`, `Start_Backend_Now.bat`, and `Restart_Backend.bat` all
detect whichever method you used automatically.

To remove it later, use `Uninstall_Autostart_NoAdmin.bat` (not
`Uninstall_Autostart.bat`, which only looks for the Scheduled Task version).

---

## Everyday use

Everything below lives in `backend\ops\`. Just double-click the one you need.

| File | What it does | When to use it |
|---|---|---|
| `Check_Status.bat` | Shows whether the backend is running, and whether it actually responds, plus the last few log lines. | Anytime you want a quick health check. |
| `Stop_Backend.bat` | Stops the backend right now. | Before updating code, or changing `backend\.env`. |
| `Start_Backend_Now.bat` | Starts the backend right now (without waiting for a fresh login). | After `Stop_Backend.bat`, once you're done making changes. |
| `Restart_Backend.bat` | Stops then starts it again. | Quick way to apply a code/config change without two clicks. |
| `View_Latest_Log.bat` | Opens today's log file in Notepad. | Something looks wrong and you want to see what happened. |
| `Uninstall_Autostart.bat` | Removes Scheduled Task autostart entirely (stops it and un-registers it from Windows). | You installed via `Install_Autostart.bat` and want to go back to running it manually, or retire the project. |
| `Uninstall_Autostart_NoAdmin.bat` | Removes Startup-folder autostart entirely (stops it and deletes the shortcut). | You installed via `Install_Autostart_NoAdmin.bat` instead. |

### Updating code or credentials

1. Double-click `Stop_Backend.bat`.
2. Make your changes (edit `backend\.env`, pull new code, etc.).
3. Double-click `Start_Backend_Now.bat` (or just log out and back in -- it starts automatically too).
4. Double-click `Check_Status.bat` to confirm it came back up.

---

## Troubleshooting

**`Check_Status.bat` says `FAILED: could not reach the server`.**

1. Double-click `View_Latest_Log.bat` and look at the end of the file for an
   error message (e.g. Python not found, a typo in `backend\.env`, or the
   port already being used by something else).
2. If it just says `Scheduled task: NOT INSTALLED`, run `Install_Autostart.bat` again.
3. If the task shows as running but the health check still fails, wait about
   10 seconds and try `Check_Status.bat` again -- the backend can take a
   few seconds to fully start after a crash-restart.

**Nothing happens when I double-click one of the `.bat` files.**

Right-click it and choose "Run as administrator" is *not* needed here and
shouldn't be necessary -- if a `.bat` file seems to do nothing, try opening
it by right-click > Edit to confirm the file wasn't corrupted, or re-download
this `ops` folder.

**I restarted my laptop and the Kindle isn't updating.**

- Make sure you actually logged back in to Windows (the task starts at
  *logon*, not at boot, so if the laptop is sitting at the lock screen the
  backend isn't running yet).
- Laptop sleep also pauses everything, including the backend -- this is
  expected for a service running on a personal laptop rather than a
  dedicated server. If you want the Kindle to always be able to reach it,
  keep the laptop plugged in and awake (Windows Settings > System > Power &
  battery > Screen and sleep -- set "When plugged in, put my device to sleep"
  to Never).

**I want to see everything, not just the last 10 lines.**

Log files live in `backend\logs\`, one per day (e.g.
`backend_2026-07-30.log`). Open any of them in Notepad. Logs older than 30
days are deleted automatically so this folder doesn't grow forever.

---

## How this works, in plain terms

- `run_backend.ps1` is a small script that starts the actual server
  (`uvicorn backend.main:app`), writes everything it prints to a log file in
  `backend\logs\`, and -- if the server process ever stops for any reason --
  waits 5 seconds and starts it again. This loop is what makes it
  "auto-restart on crash."
- `Install_Autostart.bat` registers that script as a Windows **Scheduled
  Task** named "Kindle Dashboard Backend," set to run automatically whenever
  you log in, with no visible window. This is a built-in Windows feature --
  nothing extra was installed on your laptop to make this work.
- `Install_Autostart_NoAdmin.bat` does the same job a different way: it
  drops a shortcut into your personal Windows **Startup folder**
  (`shell:startup`), which Windows already runs automatically at every
  logon for every user, with no special permissions involved -- it's just a
  normal folder. Use whichever installer actually worked for you; you don't
  need both.
- The other `.bat` files are just convenient one-click shortcuts around
  starting, stopping, and checking on the backend -- they automatically
  detect whichever of the two methods above you installed, so you never
  need to open Task Scheduler's own (fairly technical-looking) window
  yourself, or know which method is in use.
