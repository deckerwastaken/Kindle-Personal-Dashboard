# lockscreen -- On-device install & test guide

Written for someone physically holding the Kindle. Do Tier 1 first,
always -- it's a KOReader settings change with no bricking risk at all.
Only consider Tier 2 afterward, and only if Tier 1 doesn't cover the
situation you care about.

---

## Tier 1: KOReader's built-in Screensaver message (do this first)

No files to copy, no scripts to run -- this is entirely inside KOReader,
which is already installed and working on this device.

1. Open KOReader (from its Home screen icon, or via KUAL).
2. Open KOReader's settings. The exact tap sequence varies slightly by
   KOReader version, so look for: a gear/wrench icon or a top menu,
   usually reached by tapping near the top of the screen while in the
   file browser (or the main menu if you're inside a book), then finding
   a **"Screensaver"** entry -- it may be directly in the top-level
   settings menu, or nested under something like "Screen" or "Taps and
   gestures" depending on your exact version. If you can't find it by
   browsing, KOReader has an in-app search for settings on newer
   versions -- try searching for "screensaver".
3. Inside the Screensaver settings, you're looking for two things:
   - A **screensaver type/mode** option (commonly: cover image / random
     image from a folder / book status / black screen / a text message).
     Choose the message/text option if offered as a type, OR:
   - A separate **custom message / "add a message"** option that
     overlays text on top of whatever screensaver type is active --
     newer KOReader versions tend to offer this as a toggle plus a text
     field, independent of the screensaver type.
4. Set the message text to exactly: `My Dashboard`
5. Back out of settings. Put the Kindle to sleep (however you normally
   do -- e.g. tap the power button briefly, or close it if you have a
   cover with a magnet sensor) **while KOReader is the active app** (i.e.
   you were inside KOReader, not on the native Home screen).
6. Wake it up and confirm you saw "My Dashboard" instead of Amazon's
   stock screensaver image.

If step 6 works: you're done, and you can stop here. This is genuinely
sufficient if you mostly interact with the device through KOReader (or
plan to make `kindle-daemon`'s dashboard the thing you leave open most of
the time and only occasionally return to the native Home screen).

### Now check the gap case

Go back to the **native Kindle Home screen** (exit KOReader, e.g. via its
own exit/home button), wait for the device to auto-sleep on its own (or
trigger sleep the same way you did in step 5), and check what screensaver
shows up.

- If you also see "My Dashboard": some KOReader installs do hook the
  system-wide screensaver even outside the app itself, in which case
  you're fully done and can ignore Tier 2 entirely.
- If you see Amazon's stock screensaver instead: that's the gap Tier 2
  (below) tries to close. Whether it's worth pursuing depends on how
  often you expect the device to be sitting on the native Home screen
  (or the `kindle-daemon` dashboard, which has the same gap) when it
  falls asleep, versus inside KOReader.

---

## Tier 2 (experimental): system-wide hook

Only continue here if the gap case above actually matters to you, and
you're comfortable with "experimental" meaning: this project could not
confirm the correct upstart event name for your exact firmware build
ahead of time, and you'll need to find it yourself, on your device, in
this step.

### Step 1: Back up

Same habit as always before touching `/etc/upstart/`:
1. Connect via USB, copy anything you're unsure about backing up.
2. Specifically, before Step 3 below, run `ls /etc/upstart/ > /mnt/us/etc-upstart-listing-backup.txt`
   over SSH so you have a record of what was there before you added
   anything, for comparison later.

### Step 2: Copy the files

1. Copy this entire `lockscreen` folder to the Kindle's root, so you end
   up with `/mnt/us/lockscreen/` on the device.
2. Make the script executable (over SSH):
   ```sh
   chmod +x /mnt/us/lockscreen/src/draw_lockscreen.sh
   ```

### Step 3: Test the drawing part manually FIRST

This part has zero risk regardless of whether Tier 2's boot hook ever
works -- it just draws on screen when you run it:

```sh
sh /mnt/us/lockscreen/src/draw_lockscreen.sh
```

Confirm the screen clears and shows "My Dashboard" centered. If the
text looks positioned oddly (not actually centered), that's FBInk's
`-m -M` (centered column / halfway row) flags behaving differently than
expected on this device/font -- note it, but it's cosmetic, not a safety
issue; you can adjust the `-S` (font size) argument in
`draw_lockscreen.sh` and re-run this same command to iterate safely as
many times as you like.

**Do not continue past this step until the manual run above draws
correctly.**

### Step 4: Find your device's actual suspend-related upstart event

Over SSH:

```sh
ls /etc/upstart/
grep -il "screensaver\|powerd\|suspend" /etc/upstart/*.conf
```

For each file the `grep` finds, look at its contents:

```sh
cat /etc/upstart/<name>.conf
```

You're looking for a job whose `start on`/`stop on` lines describe the
point right before the screen sleeps. Naming conventions differ across
firmware builds, which is exactly why this project doesn't hardcode a
guess here.

- **If you find a clear candidate**: open
  `/mnt/us/lockscreen/install/kindle-lockscreen.conf`, replace the
  placeholder `start on REPLACE_WITH_YOUR_DEVICES_SUSPEND_EVENT` line
  with the real event, matching the style of what you found.
- **If you don't find a confident candidate**: stop here. Rely on Tier 1
  only. Guessing at an unconfirmed suspend hook is not worth the risk for
  a cosmetic feature -- this is a legitimate, reasonable place to stop.

### Step 5: Install the hook

```sh
cp /mnt/us/lockscreen/install/kindle-lockscreen.conf /etc/upstart/kindle-lockscreen.conf
```

Reboot, then let the device sit until it auto-sleeps from the native
Home screen (or trigger sleep manually the same way as before). Check
whether "My Dashboard" now shows up there too.

### Rollback

```sh
rm /etc/upstart/kindle-lockscreen.conf
```

Reboot. As with `kindle-daemon`, this hook only ever added one new file
to `/etc/upstart/` -- it never edited or replaced any existing stock job
-- so removing that one file is the complete rollback.

If the device doesn't boot normally after adding this file and you can
reach a recovery shell or USB access, the same one-line `rm` above,
followed by a reboot, is the fix.
