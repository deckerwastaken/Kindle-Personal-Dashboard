# lockscreen

Replaces the stock Amazon "screensaver" (the image shown when the device
sleeps) with a plain screen showing the text **"My Dashboard"**, centered.
That's the whole feature -- it was explicitly requested as simple, and
the design below stays simple on purpose.

For the step-by-step install/test procedure, see `INSTALL.md`. This
document explains the research behind the approach and why it's split
into two tiers.

---

## What the research found

Kindle screensaver replacement has a long community history, but almost
all of the well-documented, actively-maintained hacks (the MobileRead
"Screen Saver Hack" family, the "K5 FW 5.x ScreenSavers Hack" thread,
`linkss`, etc.) predate or target **soft-float** Kindle firmware. This
device -- Kindle 7 (2014)/KT2, firmware 5.12.2.2 -- is **hard-float**.
Checked directly against kindlemodding.org's own current jailbreak FAQ
(the most up-to-date community reference available) during research for
this project, in two separate places:

> "There are currently no extensions to change the screensavers in
> hard-float firmware. If you're running on soft-float firmware it is
> still possible to change them with NiLuJe's screensaver hack."

> "You can easily change screensavers with KOReader" (recommended
> alternative for hard-float devices).

In other words: the community's own current answer for *this exact class
of device* is not a system-level hook at all -- it's "use KOReader's
built-in screensaver feature." Since KOReader is already installed and
working on this device, that's the lowest-risk, most realistic path, and
it's what this project leads with.

## Two tiers

### Tier 1 -- KOReader's built-in Screensaver setting (recommended, do this first)

No new code. KOReader has a Screensaver feature that can show a custom
message instead of a book cover or Amazon's own image. This fires
whenever **KOReader itself** is the app that goes to sleep (e.g. you were
reading, or the kindle-daemon... no -- see caveat below). Zero bricking
risk: it's a settings change inside an app that's already proven to work
on this device, fully reversible by changing the setting back.

**Caveat, stated plainly**: KOReader's screensaver hook fires when
*KOReader* suspends. If the device goes to sleep while the native Kindle
Home screen (or the separate `kindle-daemon` dashboard from this same
project) is what's on screen, that's a different code path, and it's not
confirmed here whether KOReader's hook also covers that case system-wide
on this firmware. This is flagged, not swept under the rug -- see
INSTALL.md for how to actually test which situations it covers on your
device.

### Tier 2 -- experimental system-level upstart hook (optional, only if Tier 1 doesn't cover your case)

A tiny shell script (`src/draw_lockscreen.sh`, one `fbink` call to clear
the screen and print centered text) plus an upstart job
(`install/kindle-lockscreen.conf`) meant to fire right before the device
suspends, regardless of which app was frontmost -- mirroring, in spirit,
how the old hard-float-unsupported screensaver hacks worked: hook the
suspend point, draw before the stock rotation would.

This tier is marked **experimental** for a specific, honest reason: research
for this project could not confirm a single, reliable upstart event name
for "about to suspend" that's guaranteed to exist on this exact
firmware build (unlike the boot-time event used in `kindle-daemon/`,
which had a well-corroborated community convention -- see that project's
README for the difference). `install/kindle-lockscreen.conf` ships with a
placeholder you must fill in yourself after inspecting your own device's
`/etc/upstart/` job files, per the instructions in the file and in
INSTALL.md. If you can't find a confident candidate, skip Tier 2
entirely -- Tier 1 alone is a reasonable, safe place to stop.

## Why a shell script, not Lua like kindle-daemon

`kindle-daemon` needed real logic (WebSocket client, touch parsing,
reconnect/backoff state) that plain shell can't do well, which is why it
reaches for LuaJIT. This feature needs none of that -- it's "clear the
screen, print one centered string, refresh." A single `fbink` invocation
via a POSIX shell script is the simplest thing that could possibly work,
and simplest is exactly what was asked for. It reuses the same `fbink`
CLI binary as `kindle-daemon` (no new tool introduced), just without
pulling in an interpreter for a one-line job.

---

## File layout

```
lockscreen/
  README.md                    -- this file
  INSTALL.md                   -- step-by-step on-device install/test guide
  src/
    draw_lockscreen.sh          -- the whole feature: clear + centered text + refresh
  install/
    kindle-lockscreen.conf       -- Tier 2 experimental upstart hook (fill in the event yourself)
```
