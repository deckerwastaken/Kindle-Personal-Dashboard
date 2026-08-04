# kindle-daemon

A standalone dashboard that runs directly on the Kindle's Linux userspace
(not inside KOReader, not inside the browser), auto-started at boot, that
renders the "Today" dashboard to the e-ink screen, reads touch input
directly from the touchscreen, and stays connected to the laptop backend
over WebSocket (`ws://<laptop-ip>:8000/ws` -- see `backend/README.md` for
the protocol this was built against).

This document explains **why it's built the way it is**. For the actual
step-by-step install/test procedure, see `INSTALL.md`.

---

## The runtime decision

The device is a Kindle 7 (2014), WP63GW, KT2 hardware platform, firmware
5.12.2.2, jailbroken via WinterBreak2 with KUAL installed via PEKI. It has
**no Python interpreter**, and no cross-compilation toolchain exists on
the development machine this was built from (and setting one up, without
ever being able to test-flash the result on the real hardware, is exactly
the kind of "nontrivial extra surface" the project brief warned against).

Three options were on the table:

1. **Shell script driving the `fbink` CLI binary.** FBInk ships a
   standalone command-line tool (confirmed present at `/mnt/us/koreader/fbink`
   on this device, since KOReader itself uses it -- see below) that can
   print text and images to the framebuffer, do partial/full refreshes
   with different e-ink waveform modes, and even run in a background
   "daemon" mode with a FIFO for repeated draw commands. It's mature,
   well-documented, and already proven to work on this exact device
   (KOReader's own Kindle launcher script shells out to it for its splash
   screen). **What it can't do**: parse the binary `struct input_event`
   records from `/dev/input/eventX` for touch, or speak the WebSocket
   protocol (framing, masking, the SHA-1/base64 handshake) -- POSIX shell
   has no binary-safe struct parsing and no crypto primitives to lean on.
2. **A C program using libfbink directly, cross-compiled.** Best
   performance and control, but requires an ARM cross-compilation
   toolchain that isn't set up here, can't be test-built against this
   device's exact libc/kernel ABI without the hardware in hand, and would
   leave whoever maintains this afterward needing to reproduce that whole
   toolchain to change one line of code. Ruled out per the project brief:
   not realistic for someone without a cross-compilation setup, especially
   sight-unseen.
3. **KOReader's bundled LuaJIT interpreter, invoked standalone.** KOReader
   is already installed and working on this device. Its Kindle package
   includes a general-purpose `luajit` binary at `/mnt/us/koreader/luajit`
   -- it's just an interpreter, not something hardcoded to only ever run
   KOReader's own `reader.lua`. Nothing stops it from running an entirely
   different `.lua` script with none of KOReader's UI framework loaded.

**Chosen approach: option 3, but deliberately narrow.** This daemon runs
as `luajit daemon.lua`, completely outside KOReader's app framework (no
`require("ui/...")`, no KOReader widgets, no dependency on KOReader's
internal package-path setup). It uses LuaJIT for two things a real
language is good at and shell isn't:

- **FFI bindings to plain POSIX/libc** (`src/posix.lua`) for raw TCP
  sockets and for reading `/dev/input/eventX`. These bind against stable,
  decades-old kernel/POSIX ABIs (a `struct input_event` on 32-bit ARM
  hasn't changed shape since long before this device existed), which is a
  fundamentally lower-risk kind of FFI binding than trying to guess the
  layout of `FBInkConfig`/`FBInkState` -- FBInk's own library structs,
  which *do* change between FBInk versions and would need to exactly
  match whatever version happens to be compiled into this specific
  KOReader release.
- **A hand-rolled minimal WebSocket client** (`src/websocket.lua`, plus
  `src/sha1.lua`/`src/base64.lua` for the handshake) on top of those raw
  sockets, since neither shell nor a bare libc binding gives you HTTP
  upgrade handshakes or frame masking for free, and KOReader's bundled
  LuaSocket isn't something this standalone script relies on (see below).

**All actual screen drawing goes through the `fbink` CLI binary as a
subprocess** (`src/ui.lua` builds and runs `fbink` command lines), exactly
like option 1 -- this project doesn't link against `libfbink.so` at all.
That's a deliberate hybrid: shelling out to the CLI means every draw
operation goes through FBInk's own stable, versioned, human-readable
command-line interface instead of a struct layout this project would have
to reverse-engineer and could silently get wrong. It also means you can
copy any line logged by this daemon and re-run it by hand over SSH to see
exactly what it was trying to draw -- much easier for a non-expert to
debug than a crash inside an FFI struct call.

### Why not just run this inside KOReader instead (again)?

An earlier version of this project did exactly that (a KOReader plugin
widget), and it's the approach this project is explicitly replacing:
fragile manual pixel-offset widget positioning, being bound to KOReader's
release cycle and internal APIs, and never quite behaving like a real
full-screen app (stuck inside KOReader's own widget toolkit, competing
with its gestures and lifecycle) were all real problems in practice. Using
KOReader's *interpreter binary* as a lightweight embedded scripting
runtime -- the same way you might use BusyBox's `ash` as a shell without
adopting an entire distro -- is a different thing from running inside
KOReader's widget toolkit, even though both technically depend on
KOReader being installed.

### Why not use koreader's bundled LuaSocket / JSON module?

Because this script is standalone, `src/websocket.lua` and `src/json.lua`
are self-contained (no dependency on KOReader's `setupkoenv.lua` or its
internal `package.path`/`LD_LIBRARY_PATH` setup). If a future KOReader
update rearranges where its bundled Lua modules live -- which has
happened before, per the GitHub issues referenced during research for
this project -- this daemon keeps working as long as `luajit` and `fbink`
still exist at their current paths. That's a small amount of code
(a pure-Lua SHA-1, a tiny JSON encoder/decoder, ~150 lines of WebSocket
framing) traded for one fewer thing that can break on a KOReader upgrade.

---

## On-device controls (Exit Dashboard, Restart SSH, Add/Delete Task)

Beyond the read-only Today view described above, the dashboard has four
pieces of interactive UI, all handled by `src/daemon.lua`'s `ui_mode`
state machine (`"dashboard"` / `"keyboard"` / `"confirm_exit"`) dispatch
in `handle_tap`, with all drawing/layout owned by `src/ui.lua` as usual:

- **Exit Dashboard.** A small button in the row directly above the nav
  bar. Tapping it does NOT immediately act -- it switches to a dedicated
  full-screen confirmation (`ui.draw_confirm_exit()`) with explicit
  Cancel / "Yes, Shut Down" buttons, specifically so one mis-tap can't
  reboot the device. Confirming logs the action, draws a brief
  "Shutting down..." message, defensively removes
  `/etc/upstart/kindle-dashboard.conf` (in case boot-autostart was ever
  turned on -- see INSTALL.md Step 6), then runs `sync; reboot`. This is
  the on-device answer to the "you need SSH to stop the dashboard, but
  stopping it is what you'd do to get SSH back" problem -- no
  laptop/SSH involvement needed.
- **Restart SSH.** The button next to Exit Dashboard. Checks whether
  dropbear (KOReader's bundled SSH server) is already running (a real
  `ps`/`grep` process check, not just a pidfile) and, if not, starts it
  via the configurable `config.ssh_restart_cmd` (see config.example.lua
  -- **this command is now CONFIRMED on hardware**, copied directly from
  KOReader's own installed `SSH.koplugin/main.lua`, not a guess -- see
  the comment above that field for exactly what was verified and how).
  Always leaves a toast (`ui.flash_message`) saying what happened:
  already running / started / failed (with whatever output it could
  capture).
- **Add Task.** An always-visible "+ Add Task" row at the bottom of the
  task list (see `max_visible_tasks` in `src/ui.lua` for how the row
  budget was resized to always leave room for this). Tapping it switches
  to a full-screen lowercase-only on-screen QWERTY keyboard
  (`ui.draw_keyboard`/`ui.update_keyboard_preview`) -- v1 deliberately
  has no shift/symbols/numbers, just letters + space + backspace, to
  keep the layout (and the code generating it) simple. Each keypress
  does a fast A2 partial-refresh of just the preview strip, not a full
  keyboard redraw, so typing stays responsive on e-ink. Confirm sends
  `{"action":"add_task","text":...}` (same connected-check pattern as
  everything else) and returns to the dashboard with a normal full GC16
  redraw; Cancel discards the buffer with no side effects.
- **Delete Task.** Each task row has a small "x" zone at its right edge.
  First tap arms it (highlighted row, a few seconds' window, using the
  same `now_ms()` monotonic clock the websocket reconnect backoff
  already relies on); a second tap on the *same* armed zone within that
  window sends `{"action":"delete_task","id":...}`. Any other tap
  (including on a *different* task's delete zone, or anywhere else)
  disarms it with no side effect, rather than also performing whatever
  that other tap would normally do -- while a delete confirmation is
  showing, a stray tap should read as "cancel that", not "cancel that
  AND also do this other thing". `touch.lua` only does single-tap
  down/up detection (no long-press), which is exactly why this is a
  two-single-taps pattern rather than a press-and-hold.

None of the pixel-centering inside the on-screen keyboard's key labels
has been measured against real hardware (there was no confirmed
per-glyph width figure to build on, only the confirmed 8px/unit *text
height* this file's header comment already established) -- see
`KBD_CHAR_W_ESTIMATE` in `src/ui.lua` if key labels look visibly
off-center once this is actually running on the device.

---

## What is genuinely unverified (read this before relying on any of it)

**UPDATE**: this section originally described everything below as untested
guesswork, written before this project had access to the physical device.
It's since been extensively used on real hardware (the whole dashboard --
tasks, touch, the Claude usage card, reconnect handling -- has been live
and working for real day-to-day use). Most of the items below are now
confirmed rather than unverified; kept here (updated, not deleted) since a
couple of points are genuinely still device-specific and worth checking on
*your* Kindle even though they held up fine on the reference device:

1. **`/mnt/us/koreader/fbink` and `/mnt/us/koreader/luajit` at those exact
   paths**: CONFIRMED -- this is exactly where they are on the reference
   device (a whole-`koreader`-folder install, see
   `docs/JAILBREAK_REFERENCE.md`), and every tool in this project (INSTALL.md's
   steps, `bin/run.sh`, `tools/fbink_selftest.sh`) has been run against
   them successfully many times.
2. **The touchscreen's evdev protocol** (`src/touch.lua`,
   `tools/evtest.lua`). The Kindle 7's touch panel is infrared, and
   different Kindle touch generations have used both "type A" (plain
   `ABS_X`/`ABS_Y` + `BTN_TOUCH`) and "type B" multitouch (`ABS_MT_*`)
   evdev protocols historically. The code handles both, and taps have
   worked reliably in extended real use on the reference device -- but if
   you're on different hardware, your panel could still use the other
   variant, or need its raw X/Y swapped/flipped
   (`touch_swap_xy`/`touch_invert_x`/`touch_invert_y` in `config.lua`) if
   your controller is wired up landscape-native regardless of how the
   screen is used. `tools/evtest.lua` exists so you can check this by hand
   on your own device before trusting it, rather than assuming the
   reference device's config just works everywhere.

   **CONFIRMED on-device (2026-08-02), separate from the protocol
   question above:** while KOReader is running, Xorg (the X server it
   runs under on this device/firmware) holds an exclusive grab on
   `/dev/input/eventN` -- `open()` on the device succeeds for any other
   reader, but `read()` never returns a single byte while X is up, which
   looks identical to "the panel sends nothing" if you don't know to
   check for it (diagnosed by confirming zero bytes reach a plain `cat`
   of the raw device, then checking `/proc/*/fd` for who else has it
   open). Both `run.sh` and `tools/evtest.lua` now `killall -s KILL
   reader.lua Xorg` before touching the device, mirroring the same
   pattern the stock `x.conf` upstart job already uses when it restarts
   X itself. This means the dashboard daemon and KOReader's normal
   reading UI cannot both be usable at once on this device -- whichever
   started most recently owns the touchscreen and framebuffer. A normal
   reboot brings KOReader back; nothing about this is persisted at the
   OS level.
3. **The pixel-coordinate assumption in `src/ui.lua`** -- that
   `fbink -x 0 -y 0 -X <px> -Y <px>` places text at exact pixel `(px, px)`
   from the screen's top-left corner: CONFIRMED (see the big comment at
   the top of `src/ui.lua` -- text height is a clean 8px per `-S` size
   unit, and glyph *width* at size=1 is exactly 8px too, both measured
   directly via `fbink -E`, which echoes back the exact pixel rect it
   just drew). `tools/fbink_selftest.sh` is still here as the calibration
   script to re-run this check on your own device/font/firmware
   combination, since none of this is guaranteed to hold on different
   hardware.
4. **The upstart job's `start on started lab126_gui` event name**
   (`install/kindle-dashboard.conf`) -- this is the most commonly
   reported convention in the Kindle jailbreak community for "run
   something once the native UI is up", but upstart job names have been
   observed to vary slightly across firmware/hardware combinations.
   INSTALL.md has you check your device's actual `/etc/upstart/*.conf`
   files before trusting this -- still genuinely worth checking per-device,
   not something that gets "confirmed" once for everyone.
5. **Timing/CPU behavior**: CONFIRMED responsive enough in extended real
   use -- the chosen `clock_redraw_interval_ms` and per-tap redraw
   approach doesn't feel sluggish on the reference device.
6. **On-screen keyboard key-label centering** (`src/ui.lua`,
   `KBD_CHAR_W_ESTIMATE`) -- still a genuine estimate (12px), not
   confirmed on hardware. Worth noting: the *card* section's analogous
   glyph-width constant (`CARD_CHAR_W_S1`) was also an unconfirmed guess
   until it was actually measured via `fbink -E` and turned out to be
   noticeably off (visibly misaligned text was the tell) -- so treat this
   keyboard one as likely wrong too until someone runs the same
   measurement for size=2. Worst case here is purely cosmetic (labels
   look slightly off-center), never a functional problem -- the tap
   zones themselves are exact regardless of where the label text is
   drawn inside them.

None of the above being wrong should be able to brick anything -- worst
case is "the dashboard doesn't draw right" or "taps don't register" or
"it doesn't start at boot", all of which are recoverable by editing a
config value or deleting one file. See INSTALL.md's safety steps.

---

## File layout

```
kindle-daemon/
  README.md              -- this file
  INSTALL.md             -- step-by-step on-device install/test guide
  config.example.lua      -- copy to config.lua and edit (laptop IP, paths)
  src/
    daemon.lua            -- main entry point / event loop
    posix.lua             -- FFI bindings: raw TCP sockets, evdev reads, poll()
    touch.lua             -- touch device auto-detect + tap parsing
    websocket.lua         -- minimal RFC 6455 client (text frames only)
    sha1.lua              -- pure-Lua SHA-1 (WebSocket handshake only)
    base64.lua            -- pure-Lua base64 encode (handshake only)
    json.lua              -- minimal JSON encode/decode
    ui.lua                -- dashboard rendering via the `fbink` CLI
    log.lua               -- simple size-capped file logger
  bin/
    run.sh                -- launcher used by both manual tests and upstart
  tools/
    evtest.lua            -- standalone raw touch-event dumper (manual test)
    tap_test.lua           -- exercises touch.lua's real tap-detection logic,
                              not just the raw dump -- useful after any change
                              to touch.lua, or bringing up a new touch panel
    fbink_selftest.sh      -- standalone pixel-coordinate calibration test
  install/
    kindle-dashboard.conf  -- upstart job (optional boot-autostart, see
                              INSTALL.md Step 6 -- NOT the recommended default)
    setup_autostart.sh     -- bundles Step 6's commands into one script
  ops/
    Start_Dashboard.bat / Stop_Dashboard.bat -- the RECOMMENDED day-to-day
                              way to use this: on-demand start/stop from your
                              laptop over SSH, no boot-time autostart needed.
                              See ops/README.md.
```
