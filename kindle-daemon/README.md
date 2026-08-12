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

## Screens

`src/daemon.lua` owns a `ui_mode` state machine; `src/ui.lua` owns all
drawing and layout and stays a pure "given this state, draw these pixels
and return hit_zones" renderer.

| `ui_mode`      | Screen                | Nav tab    |
|----------------|-----------------------|------------|
| `dashboard`    | Today: tasks, Claude usage card, footer controls | Today |
| `learning`     | Learning: courses + books, progress bars | Learning |
| `keyboard`     | Add Task on-screen keyboard | (none) |
| `confirm_exit` | Exit Dashboard confirmation | (none) |

The bottom nav bar's tabs are Today / Learning / Habits / Home. Today and
Learning are real screens and switch instantly; Habits and Home are still
stubs that raise a "coming soon" toast. `ui.NAV_TAB_IMPLEMENTED` is what
decides which is which, and it also drives the bar's three visual states:
active (inverted black), available (plain black text), unavailable
(gray).

### The Claude usage card

Sits at a fixed position on the Today screen, above the footer controls,
showing claude.ai's own "current session" rate-limit percentage, a
progress bar and when it resets.

**Tap anywhere on the card to refresh it** — the label, the percentage,
the bar, the resets line, all of it — rather than only the small circular
-arrow icon in its corner. The icon is still drawn, because it is the only
thing that says the card *does* anything, but it is no longer the target.

That icon's own hit zone was 24x24, the single tap target in `ui.lua`
under the 40px floor everything else meets, and it was recorded as a known
exception in `tests/test_layout.lua` rather than fixed. Widening the icon
would have cost vertical budget this card does not have (`usage_card_h`
has already been trimmed twice to fund the footer); making the card itself
the target cost no layout at all and gives a 552x110 region. On an IR
panel whose calibration has never been confirmed, that is the difference
between "usually works" and "always works". `KNOWN_SMALL_ZONES` is now
empty as a result.

A refresh is rate-limited server-side (`backend/claude_session_usage.py`);
a rejected repeat tap comes back as a toast, so tapping the card twice in
quick succession tells you so rather than doing nothing.

### The Learning screen

A dedicated full screen listing what you're working through -- online
courses (you set the percentage) and books (you record the page, the
percentage is worked out for you). It shows *only* learnings: no tasks,
no usage card, no footer controls.

It is **read-only on the device, deliberately.** Every learning edit
needs a number, and the on-screen keyboard is lowercase letters and space
only -- it has no digits at all. Rather than build a numeric keypad,
Telegram owns all learning mutation (`/course`, `/book`, `/percent`,
`/page`, `/total` -- see `backend/telegram_bot.py`). Consequently item
rows register no hit zone: a registered-but-inert tap target is worse
than none, because the user taps, nothing happens, and they learn to
distrust the surface.

Each row draws from four fields the backend has already derived -- `name`,
`percent`, `detail`, `done` -- so nothing on the device branches on
whether an item is a course or a book, and nothing divides. A book is
simply a row whose `detail` is non-empty, and that string doubles as the
type signal, which is why there's no separate badge or icon. See
`backend/README.md`'s field notes and `_recompute` in `backend/state.py`.

### Paging and swiping

Both list screens paginate rather than scroll (e-ink can't scroll
smoothly, and every redraw is a visible flash). Two ways to move:

- **The pager row**: a previous arrow, directly tappable page numbers,
  and a next arrow. Page 1 and the last page are always present in the
  strip, so from anywhere in a long list either end is one tap away; the
  middle window slides. Arrows at the ends are drawn gray and register no
  hit zone -- they disable rather than wrap, because a "previous" that
  jumps to the last page is a trap once real page numbers are visible.
- **Swiping** left/right anywhere over the list. `src/touch.lua`
  classifies each down-up gesture as a tap, a directional swipe, or an
  ambiguous "drag" by comparing where the finger landed against where it
  lifted. The drag case matters: before classification existed, any long
  drag registered as a tap wherever the finger came up, so a sloppy
  gesture across the task list could toggle or arm deletion on whatever
  row it ended on. Vertical swipes and diagonal smears are now
  deliberately inert.

  Swipes hit-test against where the gesture *started*, since a swipe can
  easily release outside the region it began in, and direction is
  computed *after* the screen transform, so `swap_xy`/`invert_*` can't
  produce a page turn that goes the opposite way from the user's thumb.

### Screen lock (power button, and idle auto-lock)

Pressing the Kindle's power button blanks the screen to a single centred
**Locked**; pressing it again brings the dashboard back on whatever tab
you left it on. `src/keys.lua` reads the button, `daemon.lua` owns the
`screen_locked` flag.

The screen also locks **by itself after 15 minutes with no taps, swipes
or button presses** — same state, same way back. Configurable via
`auto_lock_idle_ms` in `config.lua`; set it to `0` to switch it off. The
default lives in `daemon.lua`, not only in `config.example.lua`, so an
existing install picks the feature up without its device-local
`config.lua` being edited.

The word is not decoration. A completely blank Kindle is indistinguishable
from a daemon that has silently died — something this device has a
documented history of (see `ops/README.md`) — so an empty screen would
leave you guessing whether to press the button or restart the dashboard
from the laptop. This screen was fully blank until 2026-08-12 for exactly
the reason it isn't now.

**The point is power, and on e-ink a static image costs nothing to keep
on screen** — all the power goes on screen *refreshes* and on the CPU
waking to perform them. So locking suppresses the work, not just the
pixels:

- the periodic clock redraw stops
- the battery poll stops entirely (the sysfs read too, not just drawing)
- state pushes from the laptop still update memory but draw nothing, so
  unlocking shows current data rather than a stale screen
- touch input is ignored outright — a locked dashboard in a bag should
  not be completing tasks

`redraw()` enforces the lock centrally rather than each call site
checking, because a dozen paths can trigger a draw and one of them
forgetting would put pixels back on a locked screen. The two draws that
*don't* go through `redraw()` — the toast (`show_flash`) and the toast's
auto-dismiss — are guarded individually; both are noted in the code.

The WebSocket stays connected while locked. Dropping it would save a
little radio power, but an unlock would then show stale data until a
reconnect finished, and this device's wifi is historically the least
reliable part of the system (see `ops/README.md`). The bigger win, if
this is ever worth pushing further, would be real suspend-to-RAM —
`powerd` is still running and, confirmed on hardware, ignores the button
entirely, so that avenue is open.

### Finding the laptop again (discovery)

The daemon is told the laptop's address once, at startup. When a DHCP
lease moves the laptop mid-session, that address is simply wrong and
nothing on the device can fix it — which is exactly what happened on
2026-08-12, costing 25 minutes of taps that went nowhere.

So the backend broadcasts `KDASH1 <ip> <port>` on UDP 8001 every 5s
(`backend/discovery.py`), and `src/discovery.lua` listens for it.

**A beacon is only acted on while the daemon is NOT connected.** A
working connection already proves the address is right, and a beacon
can't improve on that — but it *can* make things worse: a laptop with
both wifi and ethernet may truthfully announce an address the Kindle has
no route to, and adopting it would drop a healthy connection for a dead
one. Waiting until we're offline costs nothing, because the case this
exists for always breaks the connection first. The watchdog notices
within 90s, and the next beacon is adopted within seconds. It also
self-heals a daemon launched with a stale `LAPTOP_IP`.

Beacons naming anything outside the private ranges are refused
(`tests/test_discovery.lua`). That is a limit on blast radius, not real
authentication: these broadcasts are unauthenticated, anything on your
LAN can send one, and `discovery_enabled = false` in `config.lua` turns
the whole thing off. The same trust model as the rest of the project —
the WebSocket has no authentication either — but now one packet easier
to abuse, which is a choice worth making deliberately.

**The Kindle's firewall must allow the port, and this is not optional.**
The INPUT chain's policy is DROP, and the rule that looks like a blanket
`ACCEPT all` in `iptables -L INPUT -n` is scoped to `usb0` — you only see
that with `-v`, which is what made the first reading of it wrong.
`bin/run.sh` adds the rule at every start (rules don't survive a reboot).
Verified in both directions: with the rule every beacon arrives; without
it, the chain's drop counter rises by exactly the number sent and nothing
is delivered. `tools/discovery_probe.lua` runs on the device and prints
whatever reaches the port, which separates "the network is blocking it"
from "it arrived and was rejected".

### Sockets are non-blocking via SOCK_NONBLOCK, not fcntl — read this before touching posix.lua

`fcntl(fd, F_SETFL, O_NONBLOCK)` **does not work through this FFI
binding on this device.** The third argument is passed variadically and
that marshalling silently fails: the call reports success, and the flag
is not set. `F_GETFL` is unaffected (it ignores that argument), which is
what makes `posix.is_nonblocking()` a trustworthy check.

Sockets are therefore created with `SOCK_NONBLOCK` OR'd into `socket()`'s
type argument, and `posix.ensure_nonblocking()` verifies it rather than
assuming.

This was live for months before anything noticed, because the symptoms
don't look like a socket-flags problem:

- `connect()` to an unreachable address **blocked the entire main
  loop** — touch, the power button, redraws — until the kernel gave up.
  Measured at 3 seconds to an unused LAN address; a black-holed one would
  be far worse.
- A read on an empty socket waited for data instead of returning EAGAIN.
  The discovery reader drains until EAGAIN, so it sat through up to 16
  beacon intervals per pass, turning a 1-second recovery into 35.

Both were found by measuring, not by reading the code: the recovery was
inexplicably ~35s, and the number only made sense as "16 reads × the 2.5s
gap between beacons".

### How often the daemon wakes up

The main loop used to wait a flat `poll_timeout_ms` (500ms) every
iteration, so the CPU woke twice a second forever, idle or not. It now
sleeps until whichever piece of *timed* work is due soonest — the clock
redraw, the battery poll, a toast expiring, a reconnect attempt, the idle
auto-lock — which is roughly **60 wakeups an hour instead of 7200**.

This costs nothing in responsiveness, and that is worth being precise
about: `poll()` returns the instant a touch, a power-button press or a
WebSocket byte arrives, whatever timeout it was given. The timeout only
ever governed deadline-driven work. `poll_timeout_ms` is still honoured,
now as the *floor*.

The failure mode this introduces is the one to know about. A deadline
that fires without being advanced sits permanently in the past, and every
wait then collapses to the floor — a busy loop on a battery device. The
flat tick hid exactly that, and one such deadline already existed: the
periodic clock redraw goes through `redraw_if_dashboard()`, which draws
nothing while the keyboard or exit-confirm screen is up, and only a real
draw stamps `last_clock_redraw_ms`. The clock block now advances it
either way. `tests/test_poll_pacing.lua` runs the loop's timers against a
simulated clock and counts the wakeups, so this stays honest — **any new
timed block in the main loop needs a deadline that always advances, and a
case in that test.**

CONFIRMED ON HARDWARE (2026-08-11): the button is the PMIC on-key
(`max77696-onkey`, `/dev/input/event0`) and emits a clean
`KEY_POWER` press/release pair with no repeat and no bounce. Nothing else
claims it — no process holds the node open, and `powerd` neither suspends
the device nor reacts. That is a different situation from the touch
panel, where Xorg *does* hold an exclusive grab and has to be stopped
first. The daemon acts on the **release** edge, both because that's the
conventional edge for a toggle and because this PMIC has a separate
long-press "manual reset" line that powers the device off — triggering on
press would fire the toggle on the way into a deliberate power-off.

### The battery indicator

Top-right of the header, on the clock's row. `src/battery.lua` probes a
ranked list of battery sources once at startup, caches whichever worked,
and reads only that one afterwards -- re-walking the chain every poll
would let one transient error silently and permanently demote the daemon
to a worse source.

Note the device naming trap documented at the top of that file: this
Kindle (7th gen, WP63GW, KT2) is the **wario** platform, so the native
path is `wario_battery` -- not `yoshi_battery` (i.MX50 Kindles) and not
`bd7181x_bat` (the 8th-gen KT3, which KOReader confusingly calls
"KindleBasic2" while this device is "KindleBasic").

If every source fails, the UI draws a gray battery and `--%` rather than
hiding the indicator or falling back to a number. A stale-but-plausible
percentage never looks broken, so it would never get investigated; a
visible dash does. `tools/battery_probe.sh` dumps what the device really
exposes.

## On-device controls (Exit Dashboard, Restart SSH, Add/Delete Task)

Beyond the read-only Today view described above, the dashboard has four
pieces of interactive UI, all handled by `src/daemon.lua`'s `ui_mode`
dispatch in `handle_tap`, with all drawing/layout owned by `src/ui.lua`:

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

Horizontal centering of text (the keyboard's key labels, the pager's page
numbers) depends on the per-glyph width at sizes above 1, which is
extrapolated from the confirmed 8px-at-size-1 measurement rather than
measured directly. All of it now goes through one `char_w()` helper in
`src/ui.lua` -- adjust that if labels look visibly off-center on the
device, and every screen corrects at once.

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
6. **Glyph width above size 1** (`src/ui.lua`, `char_w()`) -- extrapolated
   from the confirmed 8px-at-size-1 measurement (FBInk scales its built-in
   font by whole-number multiples, the same reason text *height* is a
   clean 8px per size unit), but not itself measured. Confirm with
   `fbink -E -S 2 "100%"`. This file previously carried a second,
   contradictory constant for the same quantity (`KBD_CHAR_W_ESTIMATE =
   12`, predating the size-1 measurement); the two have been unified, so
   a correction now lands in one place. Worst case is purely cosmetic
   (labels look slightly off-center, right-aligned text sits a few pixels
   off) -- tap zones are exact regardless of where label text lands
   inside them.
7. **Swipe distance thresholds** (`src/touch.lua`, `SWIPE_MIN_PX` /
   `SWIPE_AXIS_RATIO`) -- reasoned from the screen geometry (60px = 10%
   of the screen width, comfortably above an IR panel's jitter and well
   below a deliberate tap's slop), not measured against a real thumb on
   this panel. `tools/tap_test.lua` prints the classification and the raw
   travel for every gesture specifically so these can be checked. The
   classification arithmetic itself *is* covered, offline, by
   `tests/test_gestures.lua`.
8. **Which battery path this firmware exposes** (`src/battery.lua`) --
   the ranked source list is built from what the wario platform is
   documented to provide, but which nodes exist on your specific build is
   unconfirmed. This is handled by design rather than by assumption: the
   daemon probes the whole chain at startup, logs which source it settled
   on, and renders an explicit `--%` if none worked.
   `tools/battery_probe.sh` dumps the real state of every candidate.

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
    touch.lua             -- touch device auto-detect + gesture parsing
                              (tap / swipe / inert drag)
    battery.lua           -- battery percentage: ranked source probe,
                              cached winner, explicit "unknown" on failure
    keys.lua              -- hardware button (power key) reader + device
                              auto-detection by KEY_POWER capability
    websocket.lua         -- minimal RFC 6455 client (text frames only)
    sha1.lua              -- pure-Lua SHA-1 (WebSocket handshake only)
    base64.lua            -- pure-Lua base64 encode (handshake only)
    json.lua              -- minimal JSON encode/decode
    ui.lua                -- all screen rendering via the `fbink` CLI
    log.lua               -- simple size-capped file logger
  bin/
    run.sh                -- launcher used by both manual tests and upstart
  tests/                  -- run these on your LAPTOP with luajit; they need
                             no device and no network
    test_gestures.lua      -- tap/swipe/drag classification, incl. the screen
                              transform and gestures split across reads
    test_keys.lua          -- power-button decoding, and the KEY_POWER bitmap
                              arithmetic used to auto-detect the device (run
                              against this Kindle's real /proc content)
    test_layout.lua        -- renders every screen with a recorder in place of
                              fbink, then checks nothing is drawn off-screen,
                              no tap targets overlap or fall under 40px, and
                              the pager's windowing rules hold
    test_hit_resolution.lua -- runs daemon.lua's own tap/gesture resolution over
                              real hit zones at concrete pixel coordinates.
                              Covers the gap test_layout.lua leaves: the layout
                              can be perfectly self-consistent while the
                              CONSUMER resolves a tap to the wrong zone (which
                              is exactly how the full-region swipe zone once
                              swallowed every tap on the Today screen)
    test_poll_pacing.lua   -- drives the main loop's timers against a simulated
                              clock and counts wakeups, so an idle daemon is
                              proven to sleep (~120/hour, not 7200) and a stale
                              deadline can't quietly turn the loop into a spin;
                              also covers the connection watchdog
    test_discovery.lua     -- beacon parsing and validation. The rejection cases
                              are the feature: this parser decides where the
                              daemon connects, and anything on the LAN can send
                              it a beacon
  tools/                  -- run these ON THE DEVICE over SSH
    evtest.lua            -- standalone raw touch-event dumper (manual test)
    tap_test.lua           -- exercises touch.lua's real gesture detection,
                              not just the raw dump -- useful after any change
                              to touch.lua, when bringing up a new touch panel,
                              or to check the swipe thresholds feel right
    battery_probe.sh       -- dumps every battery interface this device really
                              exposes; use it if the battery reads "--%"
    discovery_probe.lua    -- prints every UDP datagram reaching the discovery
                              port. Tells "the firewall/AP is blocking beacons"
                              apart from "they arrive and are rejected", which
                              look identical from the daemon's side
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
