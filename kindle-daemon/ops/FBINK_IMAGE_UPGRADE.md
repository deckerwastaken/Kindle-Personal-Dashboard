# Optional: showing a picture on the lock screen

By default the lock screen ("Locked" on a plain white page) is drawn
entirely with text and flat rectangles, because the copy of `fbink`
already on your Kindle (the one bundled with KOReader, at
`/mnt/us/koreader/fbink`) doesn't have image support built in -- run
`fbink --help` over SSH and you'll see `Image=No` near the top of the
banner. That's deliberate on KOReader's part (KOReader decodes book pages
and covers itself, so it doesn't need `fbink`'s own image loader), but it
means this project can't hand `fbink` a PNG and have it show up.

This guide adds a **second**, separate `fbink` that *does* have image
support, purely so the lock screen can show a picture instead of the
plain page. It does **not** touch or replace the `fbink` your KOReader
install already uses -- everything else in the dashboard keeps working
exactly as it does today, calibrated the same way it always was.

If you skip this guide entirely, nothing changes: the lock screen stays
the plain "Locked" text page it's always been.

## What you're downloading

A ready-made, single-file `fbink` binary built for Kindle devices,
version 1.25.0, from the tool's own author (NiLuJe). It's posted as a
forum attachment here:

<https://www.mobileread.com/forums/showthread.php?t=299620>

(look for the attachment named **`FBInk-v1.25.0-kindle.tar.gz`** in the
first post). You'll need a free MobileRead forum account to download
forum attachments -- registering is free and doesn't require anything
beyond an email address.

Unlike the copy bundled with KOReader, this standalone build is NOT the
size-trimmed "minimal" version, so it should include image support --
but the one certain way to know is to check it yourself once it's on the
Kindle (step 4 below shows you exactly how). If it turns out this
particular download also says `Image=No`, stop and ask for help rather
than guessing further -- it means a source build is needed instead,
which is a bigger job than this guide covers.

## Steps

1. **Download and unzip** `FBInk-v1.25.0-kindle.tar.gz` on your laptop.
   Inside, look for a file simply called `fbink` (no file extension --
   this is the program itself). It should be a few megabytes.

2. **Turn on SSH on the Kindle**, same as always: open KOReader, go to
   Tools > SSH server, turn it on, and note the IP address it shows (see
   `kindle-daemon/INSTALL.md` if any of this is unfamiliar).

3. **Copy the new binary onto the Kindle, to a NEW filename** -- this is
   the important part, so it can never be confused with or overwrite the
   one KOReader relies on. Open PowerShell on your laptop and run (swap
   in the current IP, and the real path to wherever you unzipped the
   file):
   ```
   scp -P 2222 "C:\path\to\fbink" root@<kindle-ip>:/mnt/us/koreader/fbink-image
   ```

4. **Check it actually has image support** before trusting it with
   anything. SSH in (`ssh root@<kindle-ip> -p 2222`, same as
   `INSTALL.md`) and run:
   ```
   chmod +x /mnt/us/koreader/fbink-image
   /mnt/us/koreader/fbink-image --help | grep Image
   ```
   You want to see `Image=Yes`. If you see `Image=No` here too, stop --
   this download wasn't the right one, and the fix is bigger than this
   guide (a from-source build with the `IMAGE=1` option) -- don't
   continue to step 5 until this actually says `Image=Yes`.

5. **Put the picture itself on the Kindle.** Copy
   `kindle-daemon/assets/lock_screen.png` (from this project, already
   sized and tuned for the screen -- see that file for how it was made)
   onto the device:
   ```
   scp -P 2222 "kindle-daemon\assets\lock_screen.png" root@<kindle-ip>:/mnt/us/kindle-dashboard/assets/lock_screen.png
   ```
   (create the `assets` folder first with `ssh root@<kindle-ip> -p 2222
   "mkdir -p /mnt/us/kindle-dashboard/assets"` if `scp` complains it
   doesn't exist.)

6. **Turn the feature on** in the Kindle's `src/config.lua` (NOT
   `config.example.lua` -- see that file for the difference) by setting:
   ```lua
   fbink_image_path = "/mnt/us/koreader/fbink-image",
   lock_screen_image_path = "/mnt/us/kindle-dashboard/assets/lock_screen.png",
   ```

7. **Restart the dashboard** (`Stop_Dashboard.bat` then
   `Start_Dashboard.bat`, same as any other config.lua change) and lock
   the screen (power button) to see it.

## If something looks wrong

- **Still shows the plain "Locked" text, no picture**: the daemon checks
  for both files on every single lock, and silently falls back to the
  plain page if either one is missing -- so this almost always means a
  typo in one of the two paths in `config.lua`, or step 3/5 didn't
  actually land the file where `config.lua` says it did. Double check
  with `ssh root@<kindle-ip> -p 2222 "ls -la /mnt/us/koreader/fbink-image
  /mnt/us/kindle-dashboard/assets/lock_screen.png"` -- both should show
  up with a real file size, not "No such file or directory".
- **Picture looks blocky, banded, or muddy**: that's a dithering/image
  question, not a wiring problem -- see `kindle-daemon/assets/` for
  whatever notes exist there on how `lock_screen.png` was generated and
  how to regenerate it with different settings.
- **Anything else looks broken**: unset `fbink_image_path` back to `nil`
  in `config.lua` and restart -- that's a full, instant rollback to the
  exact behavior this project had before this guide, nothing else about
  the dashboard depends on this feature.
