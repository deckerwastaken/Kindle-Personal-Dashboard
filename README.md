# Kindle Dashboard

A personal dashboard on a jailbroken Kindle e-reader: a Today screen with
your task list and Claude usage, a Learning screen tracking your progress
through courses and books, and a Telegram bot to feed both — rendered
directly to the e-ink screen and controlled by touch, swipe, and the
power button (which locks the screen and idles the dashboard). No cloud,
no third-party service — the backend runs on your own laptop.

## Start here

Want to know what it actually does, in plain English? Read
**`CHANGELOG.md`** — a no-jargon tour of every feature in version 2.

New to this repo? Read **`docs/LAUNCH_GUIDE.md`** — the single
start-to-finish setup walkthrough. It links out to more detailed guides
for each piece as needed.

Already set up? Day-to-day use is two double-clickable scripts:
`kindle-daemon/ops/Start_Dashboard.bat` and `Stop_Dashboard.bat` — see
`kindle-daemon/ops/README.md`.

## Layout

```
backend/       -- FastAPI service (runs on your laptop): Telegram bot,
                  Anthropic usage polling, WebSocket push to the Kindle.
                  See backend/README.md.
kindle-daemon/ -- standalone Lua daemon that runs directly on the Kindle
                  (not inside KOReader): renders the dashboard via FBInk,
                  reads touch via evdev, connects to the backend.
                  See kindle-daemon/README.md (architecture) and
                  kindle-daemon/INSTALL.md (on-device setup).
lockscreen/    -- optional: replaces the Kindle's stock screensaver with
                  custom text. See lockscreen/README.md.
docs/          -- setup guide, jailbreak reference, and secrets policy.
```

## Tests

There are eight suites. All of them run on your laptop with no Kindle, no
network, and nothing to install beyond what the backend already needs:

```
cd kindle-daemon/tests && luajit test_gestures.lua        # tap/swipe classification
cd kindle-daemon/tests && luajit test_keys.lua            # power button / screen lock
cd kindle-daemon/tests && luajit test_layout.lua          # every screen's layout
cd kindle-daemon/tests && luajit test_hit_resolution.lua  # what a tap actually hits
cd kindle-daemon/tests && luajit test_poll_pacing.lua     # wakeups + connection watchdog
cd kindle-daemon/tests && luajit test_discovery.lua       # beacon parsing/validation
python backend/tests/test_learnings.py                    # from the repo root
python backend/tests/test_discovery.py                    # from the repo root
```

`test_layout.lua` swaps a recorder in for the `fbink` CLI, renders each
screen, and checks the drawing commands that *would* have been sent —
nothing off-screen, no overlapping tap targets, none under 40px,
pagination eliding the right pages.

`test_hit_resolution.lua` covers the gap that leaves: it takes those same
tap zones and runs the *daemon's* own hit-testing over concrete pixel
coordinates, asserting each lands on the control you aimed at. That
distinction is not academic — a bug that made the entire task area
untappable was invisible to the layout test (the layout was perfectly
self-consistent; the consumer resolved it wrong) and is caught
immediately by this one.

`test_poll_pacing.lua` is about battery rather than pixels. The daemon
sleeps until its next piece of timed work instead of waking on a fixed
tick (~120 wakeups an hour rather than 7200), which is only safe as long
as every deadline actually moves forward when it fires — one that doesn't
turns the loop into a spin. This suite runs those timers against a
simulated clock and counts, and covers the watchdog that spots a
connection which has died without being closed.

The two `test_discovery` suites sit on either side of one wire format:
Python builds the beacon, Lua parses it, and nothing but the format
connects them — a drift produces no error anywhere, just a dashboard that
quietly loses the ability to recover from an IP change. Each side pins the
format, and the Lua one leans hardest on the *rejection* cases, since that
parser decides where the daemon connects and any device on your network
can send it a beacon.

Together they cover the arithmetic. They deliberately cannot tell you
whether anything *looks* right on real e-ink — ghosting, whether the
pixel-art arrows read as triangles, whether a 2px outline is visible at
167ppi. `kindle-daemon/tools/` holds the on-device diagnostics for that.

## Is my Kindle compatible?

This project needs a **jailbroken** Kindle (meaning its normal software
restrictions have been removed, so it can run programs Amazon didn't put
there — see `docs/JAILBREAK_REFERENCE.md`), with KUAL and KOReader
installed on top of that. It was built and tested against a Kindle 7th
Gen (2014, model WP63GW, KT2 hardware) jailbroken via WinterBreak2. Other
jailbroken Kindle models will likely also work once KUAL/KOReader are
installed, but haven't been tested — check
`kindle-daemon/README.md`'s "What is genuinely unverified" section
before investing time on a different device.

## Security

Real secrets (Telegram bot token, Anthropic API key, the Kindle's local
config) never live in this repo — see `docs/SECRETS.md` for the policy
this project follows.

## License

MIT — see `LICENSE`. Use it, fork it, adapt it for your own Kindle.
