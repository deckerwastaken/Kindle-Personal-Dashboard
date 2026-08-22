--[[
config.example.lua -- copy this file to config.lua and fill in your own
values. config.lua itself is not meant to be tracked in git if you ever
put real network details in it that you consider sensitive (a home LAN
IP is low-risk, but keep the habit).

On the Kindle, this file must sit next to daemon.lua (i.e. in
kindle-daemon/src/ alongside it), because daemon.lua does
`require("config")` using plain Lua package.path resolution rooted at
the script's own directory. See bin/run.sh for how that's set up.
]]

return {
    -- Your laptop's LAN IP address (NOT "localhost" -- that would mean
    -- the Kindle itself). Find it on Windows with `ipconfig` (look for
    -- "IPv4 Address" under your WiFi adapter). Must be reachable from the
    -- Kindle over the same home WiFi network. No DNS lookup is performed
    -- here (see src/posix.lua) -- it must be a literal IPv4 address.
    --
    -- This is only a FALLBACK: ops/start_dashboard.ps1 auto-detects the
    -- laptop's current LAN IP and overrides this value every run (see
    -- daemon.lua's LAPTOP_IP env var handling), so it self-corrects after
    -- a wifi network change without editing this file. It's only actually
    -- used if you run bin/run.sh manually over SSH without going through
    -- Start_Dashboard.bat (e.g. the INSTALL.md walkthrough steps).
    laptop_ip = "192.168.1.100",
    laptop_port = 8000,
    ws_path = "/ws",

    -- Path to the fbink CLI binary already bundled with your KOReader
    -- install. If you installed KOReader to the Kindle's root (as
    -- described in docs/JAILBREAK_REFERENCE.md), this is correct
    -- as-is. Adjust if your koreader folder lives somewhere else (e.g.
    -- under /mnt/us/extensions/koreader/ instead of /mnt/us/koreader/).
    fbink_path = "/mnt/us/koreader/fbink",

    -- OPTIONAL: path to a SECOND fbink binary that actually has image
    -- (PNG/JPEG) support compiled in, used only to show a picture on the
    -- lock screen instead of the plain "Locked" text. The binary above
    -- (fbink_path) is a MINIMAL build bundled with KOReader -- run
    -- `fbink --help` on the device and check for `Image=No` in the
    -- banner to confirm -- so it can't blit images at all, and every
    -- other screen in this project is calibrated against its exact
    -- current behavior, which is why this isn't just a second value for
    -- fbink_path itself. See kindle-daemon/ops/FBINK_IMAGE_UPGRADE.md for
    -- how to get one and where to put it. Leave as nil to keep the
    -- lock screen as plain text (the default, and also what you get
    -- automatically if this file or the image below is missing).
    fbink_image_path = nil,

    -- OPTIONAL: array of absolute paths (ON THE KINDLE) to the PNGs to
    -- show on the lock screen, e.g. "/mnt/us/kindle-daemon/assets/lock_screen.png"
    -- -- copy kindle-daemon/assets/*.png there. One is picked at random
    -- each time the screen locks, so with more than one entry you get a
    -- rotation rather than always the same picture. Only takes effect if
    -- fbink_image_path above is also set; entries that don't actually
    -- exist on the device are silently skipped (checked fresh on every
    -- lock, not just at startup) -- an empty list (or leaving this nil)
    -- falls back to the plain "Locked" text.
    lock_screen_image_paths = nil,

    -- Touch input device node. Leave as nil to auto-detect (recommended
    -- first try -- see src/touch.lua and tools/evtest.lua). If
    -- auto-detect picks the wrong /dev/input/eventN, hardcode the right
    -- one here once you've identified it.
    touch_device_path = nil,

    -- Power-button device node, used for the screen lock (press to blank
    -- the screen and pause the dashboard's timers, press again to bring
    -- it back -- see src/keys.lua). Leave as nil to auto-detect, which
    -- works by looking for a device that advertises the KEY_POWER
    -- capability rather than by matching a device name, so it should be
    -- correct on any Kindle. On the reference device (Kindle 7 / KT2)
    -- this resolves to /dev/input/event0, "max77696-onkey".
    --
    -- If no power button is found, everything else works exactly as
    -- normal and only the screen lock is unavailable -- the daemon logs
    -- which devices it considered, so check daemon.log before hardcoding
    -- a path here.
    power_key_device_path = nil,

    -- Touch coordinate calibration. Some e-ink touch controllers are
    -- wired up in a different orientation than the screen itself (e.g. a
    -- panel that's physically landscape-native reporting raw coordinates
    -- that need adjusting to line up with this portrait 600x800 UI).
    -- NOT confirmed either way for this device -- leave these false
    -- until you've tested with tools/evtest.lua (tap each corner of the
    -- screen and see whether the printed X/Y values increase in the
    -- directions you'd expect, and whether X and Y are swapped). See
    -- src/touch.lua's M.open() doc comment for exactly what each flag
    -- does.
    touch_swap_xy = false,
    touch_invert_x = false,
    touch_invert_y = false,

    -- Where to write the daemon's log file.
    log_path = "/mnt/us/kindle-daemon/daemon.log",

    -- How often to redraw the clock even if nothing else changed
    -- (milliseconds). The dashboard also redraws immediately any time a
    -- new state push arrives from the backend, regardless of this timer.
    clock_redraw_interval_ms = 60000,

    -- WebSocket reconnect backoff (milliseconds): starts at
    -- reconnect_min_ms and doubles up to reconnect_max_ms after each
    -- failed attempt, so a laptop that's asleep for hours doesn't get
    -- hammered with connection attempts.
    reconnect_min_ms = 2000,
    reconnect_max_ms = 30000,

    -- --- finding the laptop again after its IP changes ---
    -- The backend broadcasts its own address on your network every few
    -- seconds; the daemon listens for that and reconnects to the new
    -- address by itself. Without this, a router handing your laptop a
    -- different address mid-session leaves the dashboard stuck until you
    -- run Start_Dashboard.bat again.
    --
    -- The daemon only acts on a beacon when it is NOT connected, so this
    -- can never disturb a working connection.
    --
    -- Set discovery_enabled = false to switch it off and never open the
    -- socket. Worth knowing if you're deciding: these beacons are
    -- unauthenticated, so anything on your network could send a lookalike
    -- and point the dashboard at a different backend. The daemon refuses
    -- any address outside your own private network ranges, and this is
    -- the same trust model the rest of the project already has (there's
    -- no password on the WebSocket either) -- but it is your call.
    --
    -- Must match DISCOVERY_PORT in backend/.env if you change it. It is
    -- also the port bin/run.sh opens in the Kindle's firewall.
    discovery_enabled = true,
    discovery_port = 8001,

    -- Lock the screen automatically after this long with no taps, swipes
    -- or power-button presses (milliseconds) -- the same blank "Locked"
    -- screen the power button gives, and the same press to come back.
    -- This is the main power saving while the dashboard is left sitting
    -- there: locking suspends the clock redraw, the battery read and
    -- nearly all CPU wakeups.
    --
    -- Set to 0 to disable and keep the dashboard on screen until you
    -- press the power button yourself.
    --
    -- If this key is missing entirely (an older config.lua), the daemon
    -- uses the same 15 minutes, so an existing install doesn't have to be
    -- edited to get the feature.
    auto_lock_idle_ms = 15 * 60 * 1000,

    -- Main poll() loop FLOOR (milliseconds) -- the shortest the daemon
    -- will ever wait in one poll() call.
    --
    -- This used to be a fixed tick: the loop woke every 500ms whether or
    -- not there was anything to do. It now sleeps until whichever piece
    -- of timed work is due soonest (the clock redraw, the battery poll, a
    -- toast expiring, a reconnect), which is usually a minute away and,
    -- while locked, usually nothing at all -- so idle CPU wakeups drop by
    -- roughly two orders of magnitude.
    --
    -- Touch and power-button latency do NOT depend on this: poll() wakes
    -- the instant an event arrives, whatever the timeout was set to.
    poll_timeout_ms = 500,
}
