# Google Sheets Setup (optional)

This guide walks you through turning on one optional feature: every day, once
your daily habit list finishes for the day, the backend can copy that day's
results (which habits you did and didn't do) into a Google Sheet that you own.
Over time this builds you a permanent, easy-to-read history - one row per day,
one column per habit - that you can open on your phone or computer, sort,
filter, or build your own charts from.

**This is entirely optional.** If you skip this guide, nothing breaks - the
rest of the dashboard (tasks, learning tracker, Telegram bot, everything)
works exactly the same either way. You can also come back and set this up
later; there's no rush.

No coding experience is assumed. Every click is spelled out. It takes about
10–15 minutes the first time.

---

## What you'll end up with

- A Google Sheet, owned by you, with a tab called **"Daily Habits"** that
  fills itself in automatically - one row per day, one column per habit,
  with `TRUE`/`FALSE` in each cell.
- Two values pasted into your `backend/.env` file.
- No password or login step for the backend to worry about ever again - this
  uses something called a "service account" instead (explained below), which
  is a one-time setup, not something you log into each time.

---

## Step 1: Create (or open) a Google Cloud project

Google Cloud Console is the free control panel where you turn on Google APIs
(like the one that lets a program write to a Sheet). You don't need to pay
for anything here - everything in this guide stays within Google's free
tier.

1. Go to [console.cloud.google.com](https://console.cloud.google.com/) and
   sign in with the same Google account you'll use for your habit Sheet (any
   Google account works, including a plain Gmail one).
2. At the top of the page, click the project dropdown (it might say "Select a
   project" or show an existing project name).
3. Click **"New Project"**.
4. Give it any name you like - e.g. `Kindle Dashboard`. Leave "Location" as
   whatever it defaults to.
5. Click **"Create"**. Wait a few seconds for it to finish, then make sure
   this new project is the one selected in that same dropdown at the top -
   everything you do in the next steps needs to happen "inside" this project.

## Step 2: Turn on the Google Sheets API

By default, a new Google Cloud project can't talk to Google Sheets at all -
you have to explicitly switch that capability on.

1. In the search bar at the top of the Cloud Console, type `Google Sheets
   API` and click the result named exactly that.
2. Click the blue **"Enable"** button. Wait for it to finish (a few
   seconds).

## Step 3: Create a Service Account and download its key

A "service account" is a special kind of Google account meant for a program
to use instead of a person. It doesn't have a password you type in, and
nobody "logs into" it in a browser - instead, it has a small file (a key)
that proves who it is. This is exactly what you want for a backend that
restarts on its own and has no one sitting in front of it to click through a
login screen every time.

1. In the search bar, type `Service Accounts` and open that page (it may ask
   you to make sure the right project is still selected at the top - check
   that first).
2. Click **"+ Create Service Account"** at the top.
3. Give it any name, e.g. `kindle-dashboard-sheets`. Click **"Create and
   Continue"**.
4. On the next screen ("Grant this service account access to project"), you
   can just click **"Continue"** without picking anything - you don't need
   any project-wide permissions, only access to the one Sheet you'll share
   in Step 6.
5. On the next screen, click **"Done"**.
6. You're now on the Service Accounts list. Click the service account you
   just created (its email address, which will look something like
   `kindle-dashboard-sheets@your-project-id.iam.gserviceaccount.com`).
7. Click the **"Keys"** tab near the top.
8. Click **"Add Key"** → **"Create new key"**.
9. Choose **JSON** (should already be selected) and click **"Create"**.
10. A `.json` file will download to your computer automatically - usually
    into your Downloads folder. This file is the actual credential; keep it
    somewhere safe and never share it or post it anywhere (treat it like a
    password).

**Before moving on**, open that downloaded `.json` file in Notepad (right-click
it → "Open with" → "Notepad") and find the line that starts with
`"client_email":`. Copy that email address somewhere handy (e.g. paste it
into a sticky note) - you'll need it again in Step 6.

## Step 4: Save the key file where the backend expects it

1. In File Explorer, go into the `backend` folder inside wherever you
   downloaded this project (the same folder from the main
   `docs/LAUNCH_GUIDE.md`).
2. Inside `backend`, create a new folder named exactly `secrets` (if it
   doesn't already exist).
3. Move (don't just copy - move, so it's not sitting in your Downloads
   folder too) the `.json` file you downloaded in Step 3 into that new
   `backend/secrets` folder, and rename it to exactly `google_credentials.json`.

You should now have a file at:

```
backend/secrets/google_credentials.json
```

This folder is already excluded from git (see `backend/.gitignore`), so this
real key file can never accidentally get uploaded anywhere if you ever share
or back up this project's code.

## Step 5: Create (or reuse) a Google Sheet, and copy its ID

1. Go to [sheets.google.com](https://sheets.google.com/) and either create a
   new blank spreadsheet, or open an existing one you'd like to use - either
   is fine, the backend will add its own "Daily Habits" tab to whichever
   spreadsheet you point it at without disturbing any other tabs already
   there.
2. Look at the address bar in your browser. The URL will look like this:

   ```
   https://docs.google.com/spreadsheets/d/1AbCDefGHijKLmnOPqrsTUVwxyz1234567890/edit#gid=0
   ```

   The long jumble of letters and numbers between `/d/` and the next `/`
   (in the example above, `1AbCDefGHijKLmnOPqrsTUVwxyz1234567890`) is the
   **Spreadsheet ID**. Copy just that part - not the `https://...` prefix,
   not anything after the next `/`.

## Step 6: Share the Sheet with your service account

This is the step that actually gives the backend permission to write to your
Sheet. Without it, the backend will authenticate successfully (its
credentials are valid) but every write will be rejected - the same as any
other Google account trying to edit a Sheet nobody shared with them.

1. With your Sheet open, click the **"Share"** button (top right).
2. In the "Add people" box, paste the service account's email address you
   copied back in Step 3 - it looks like
   `something@your-project-id.iam.gserviceaccount.com`.
3. Make sure its permission is set to **"Editor"** (not "Viewer" - it needs
   to be able to write rows, not just read them).
4. Click **"Send"** (it's fine that this "person" can't receive an email -
   it's not a real inbox, just an identity Google recognizes).

## Step 7: Add the two values to your `.env` file

1. In File Explorer, open the `backend` folder and open `.env` in Notepad
   (if you don't have a `.env` yet, see `docs/LAUNCH_GUIDE.md` Part 1.2
   first - you need one for the rest of the dashboard anyway).
2. Find the commented-out lines that look like this:

   ```
   # GOOGLE_SHEETS_CREDENTIALS_FILE=backend/secrets/google_credentials.json
   # GOOGLE_SHEETS_SPREADSHEET_ID=PASTE_YOUR_SPREADSHEET_ID_HERE
   ```

3. Remove the `# ` from the start of both lines to turn them on, and replace
   the placeholder in the second line with the Spreadsheet ID you copied in
   Step 5. If you saved the key file exactly as described in Step 4, the
   first line's path is already correct and doesn't need to change. When
   you're done it should look like:

   ```
   GOOGLE_SHEETS_CREDENTIALS_FILE=backend/secrets/google_credentials.json
   GOOGLE_SHEETS_SPREADSHEET_ID=1AbCDefGHijKLmnOPqrsTUVwxyz1234567890
   ```

4. Save and close Notepad.
5. Restart the backend so it picks up the new `.env` values - if it's
   running in a PowerShell window, close that window and start it again
   (see `docs/LAUNCH_GUIDE.md` Part 1.3), or if you've already set it up to
   start automatically, restart your computer or restart the scheduled task
   (see `backend/ops/AUTOSTART_SETUP.md`).

## Step 8: Verify it worked

Message your Telegram bot with `/dailysync` - this forces an immediate test
push of today's habit list to the Sheet, so you don't have to wait for the
day to actually end to check that everything's wired up correctly. Then open
your Google Sheet and look for a new "Daily Habits" tab at the bottom with
today's row filled in.

If it doesn't show up, check the backend's log output (the PowerShell window
it's running in, or the log file if you've set up autostart - see
`backend/ops/AUTOSTART_SETUP.md`) for a line starting with "Google Sheets
sync failed" - it will say plainly what went wrong (most commonly: the
Sheet wasn't shared with the service account's email in Step 6, or the
Spreadsheet ID in `.env` doesn't match the Sheet you shared).
