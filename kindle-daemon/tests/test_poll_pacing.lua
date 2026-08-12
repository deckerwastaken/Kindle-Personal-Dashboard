--[[
test_poll_pacing.lua -- checks that the main loop actually sleeps when
there is nothing to do, and that nothing makes it spin instead.

Runs on your LAPTOP:

    cd kindle-daemon/tests
    luajit test_poll_pacing.lua

WHY THIS EXISTS
---------------
daemon.lua used to wait a flat 500ms per iteration, so the CPU woke twice
a second forever. It now sleeps until the soonest DEADLINE any of the
loop's timed blocks is waiting on. That is strictly better when it works
and strictly worse when it doesn't: a deadline that fires without being
advanced sits permanently in the past, compute_poll_timeout() returns its
floor every iteration, and the daemon busy-loops on a battery device.
The old flat tick hid exactly that failure -- it just re-checked and did
nothing -- so it is invisible until this pacing is introduced.

One such deadline already existed: the periodic clock redraw goes through
redraw_if_dashboard(), which draws nothing while the Add Task keyboard or
the exit-confirm screen is up, and only a real draw stamps
last_clock_redraw_ms. The keyboard-screen test below is that case.

Like tests/test_hit_resolution.lua, this file cannot require() daemon.lua
(it opens input devices and a socket at load), so the logic under test is
MIRRORED below. If you change compute_poll_timeout, or add a timed block
to the main loop, change the mirror too. The mirror is written against an
explicit state table rather than file-level locals; that is the only
intended difference from the original.
]]

-- ---- mirrored from src/daemon.lua ----

local POLL_FLOOR_MS = 500          -- = max(config.poll_timeout_ms, 50)
local POLL_CEILING_MS = 60 * 1000
local BATTERY_POLL_INTERVAL_MS = 60 * 1000
local CLOCK_REDRAW_INTERVAL_MS = 60 * 1000 -- = config.clock_redraw_interval_ms
local WS_PING_INTERVAL_MS = 30 * 1000
local WS_SILENCE_TIMEOUT_MS = 90 * 1000

local function compute_poll_timeout(s)
    local now = s.now
    local timeout = POLL_CEILING_MS

    local function until_deadline(deadline)
        if deadline == nil then return end
        local remaining = deadline - now
        if remaining < timeout then timeout = remaining end
    end

    if s.conn then
        if s.conn_status == "open" then
            until_deadline(s.last_ws_ping_ms + WS_PING_INTERVAL_MS)
            until_deadline(s.last_ws_rx_ms + WS_SILENCE_TIMEOUT_MS)
        end
    else
        until_deadline(s.next_reconnect_at)
    end

    if s.screen_locked then
        -- deliberately nothing: see the original's comment
    else
        until_deadline(s.last_clock_redraw_ms + CLOCK_REDRAW_INTERVAL_MS)
        until_deadline(s.last_battery_poll_ms + BATTERY_POLL_INTERVAL_MS)
        if s.flash_expire_at_ms then until_deadline(s.flash_expire_at_ms) end
        if s.armed_delete_id ~= nil then until_deadline(s.armed_delete_until_ms) end
        if s.auto_lock_idle_ms then until_deadline(s.last_input_ms + s.auto_lock_idle_ms) end
    end

    if timeout < POLL_FLOOR_MS then return POLL_FLOOR_MS end
    return timeout
end

--- The timed blocks of the main loop, in the same order, with the drawing
--- and I/O removed -- only the deadline bookkeeping, which is the part
--- this file is asserting about.
local function run_timed_blocks(s)
    local now = s.now

    -- connection watchdog. `s.server_replies` models a live peer: on a
    -- healthy link the pong (or any other frame) makes the socket
    -- readable, which is what refreshes last_ws_rx_ms in the real loop.
    if s.conn and s.conn_status == "open" then
        if (now - s.last_ws_ping_ms) >= WS_PING_INTERVAL_MS then
            s.last_ws_ping_ms = now
            if s.server_replies then s.last_ws_rx_ms = now end
        end
        if (now - s.last_ws_rx_ms) >= WS_SILENCE_TIMEOUT_MS then
            s.conn = false
            s.conn_status = "offline"
            s.next_reconnect_at = now + 2000
            s.watchdog_fired = (s.watchdog_fired or 0) + 1
        end
    end

    -- delete-confirmation expiry
    if s.armed_delete_id ~= nil and now >= s.armed_delete_until_ms then
        s.armed_delete_id = nil
    end

    -- toast auto-dismiss
    if s.flash_expire_at_ms ~= nil and now >= s.flash_expire_at_ms then
        s.flash_expire_at_ms = nil
    end

    -- battery poll (stamped unconditionally when it fires)
    if not s.screen_locked and (now - s.last_battery_poll_ms) >= BATTERY_POLL_INTERVAL_MS then
        s.last_battery_poll_ms = now
    end

    -- periodic clock redraw. redraw() stamps last_clock_redraw_ms only on
    -- a draw that actually happened; the fallback stamp is what keeps the
    -- deadline moving on the screens that draw no clock.
    if not s.screen_locked and (now - s.last_clock_redraw_ms) >= CLOCK_REDRAW_INTERVAL_MS then
        if s.ui_mode == "dashboard" then s.last_clock_redraw_ms = now end
        if (now - s.last_clock_redraw_ms) >= CLOCK_REDRAW_INTERVAL_MS then
            s.last_clock_redraw_ms = now
        end
    end

    -- idle auto-lock
    if s.auto_lock_idle_ms and not s.screen_locked
        and (now - s.last_input_ms) >= s.auto_lock_idle_ms then
        s.last_input_ms = now
        s.screen_locked = true
    end
end
-- ---- end mirror ----

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end
local function check_eq(name, got, want)
    if got == want then
        print(string.format("  ok   %s (%s)", name, tostring(got)))
    else
        failures = failures + 1
        print(string.format("  FAIL %s -- got %s, want %s", name, tostring(got), tostring(want)))
    end
end

local function new_state(over)
    local s = {
        now = 100000, -- a device that has been up a while, as it always has
        screen_locked = false,
        conn = true,
        conn_status = "open",
        server_replies = true, -- a healthy peer answers pings
        last_ws_rx_ms = 100000,
        last_ws_ping_ms = 100000,
        next_reconnect_at = 0,
        last_clock_redraw_ms = 100000,
        last_battery_poll_ms = 100000,
        flash_expire_at_ms = nil,
        armed_delete_id = nil,
        armed_delete_until_ms = 0,
        last_input_ms = 100000,
        auto_lock_idle_ms = nil,
        ui_mode = "dashboard",
    }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

--- Runs the loop for `duration_ms` of simulated time with NO external
--- events (no taps, no WebSocket traffic) -- i.e. the idle case, which is
--- the whole point -- and returns how many times it woke up.
local function wakeups_over(s, duration_ms)
    local deadline = s.now + duration_ms
    local count = 0
    while s.now < deadline do
        local timeout = compute_poll_timeout(s)
        if timeout < POLL_FLOOR_MS then
            -- Can't happen through compute_poll_timeout's own clamp; this
            -- guards the simulation itself against looping forever if it
            -- ever could.
            error("timeout below floor: " .. timeout)
        end
        s.now = s.now + timeout
        count = count + 1
        run_timed_blocks(s)
        if count > 100000 then error("simulation runaway") end
    end
    return count
end

local HOUR = 60 * 60 * 1000
-- Two wakeups per minute: the 30s liveness ping, which subsumes the 60s
-- clock redraw and battery poll. That is a deliberate, priced decision --
-- the ping doubled this from 60/hour, and it buys the ability to notice
-- a dead connection at all, which cost a user 25 minutes of tapping a
-- dashboard that had silently stopped talking to the laptop. The number
-- that matters is that it is ~120 and not the 7200 a flat 500ms tick
-- produces; the extra 60 wakeups an hour are well under a second of CPU
-- a day, measured.
local IDLE_WAKEUPS_PER_HOUR_MAX = 125

print("=== idle dashboard sleeps to the next deadline, not on a tick ===")
do
    local s = new_state()
    local n = wakeups_over(s, HOUR)
    check(string.format("dashboard idle for an hour wakes %d times (<= %d)",
        n, IDLE_WAKEUPS_PER_HOUR_MAX), n <= IDLE_WAKEUPS_PER_HOUR_MAX)
    -- The old flat tick is the thing being replaced -- state it, so the
    -- assertion above can't quietly regress toward it.
    check("...which is far below the old flat 500ms tick (7200/hr)", n < 7200 / 10,
        n .. " wakeups")
    -- The soonest real deadline on a connected, idle dashboard is the
    -- liveness ping. Nothing may bind below it -- the ceiling sitting at
    -- 30s once did, splitting every sleep in two for no benefit.
    check_eq("an idle wait runs to the liveness ping", compute_poll_timeout(new_state()),
        WS_PING_INTERVAL_MS)
    check("...and the ceiling is not set below the clock interval",
        POLL_CEILING_MS >= CLOCK_REDRAW_INTERVAL_MS)

    -- Disconnected and with nothing scheduled, the ceiling is what's left.
    check_eq("with no connection and no deadlines, the ceiling applies",
        compute_poll_timeout(new_state({ conn = false, conn_status = "offline",
                                         next_reconnect_at = 100000 + 10 * HOUR })),
        POLL_CEILING_MS)
end

print("\n=== the keyboard screen does not spin (no clock draw to stamp) ===")
do
    -- The regression this file exists for: redraw_if_dashboard() draws
    -- nothing here, so without the fallback stamp the clock deadline
    -- stays overdue forever and every wait collapses to the floor.
    local s = new_state({ ui_mode = "keyboard" })
    local n = wakeups_over(s, HOUR)
    check(string.format("keyboard screen idle for an hour wakes %d times (<= %d)",
        n, IDLE_WAKEUPS_PER_HOUR_MAX), n <= IDLE_WAKEUPS_PER_HOUR_MAX,
        "a stale deadline is pinning the wait to the floor")

    local s2 = new_state({ ui_mode = "confirm_exit" })
    local n2 = wakeups_over(s2, HOUR)
    check(string.format("exit-confirm screen likewise (%d)", n2),
        n2 <= IDLE_WAKEUPS_PER_HOUR_MAX)
end

print("\n=== locked ignores the suspended timers entirely ===")
do
    -- While locked, the clock and battery deadlines are left in the past
    -- (nothing advances them, by design). Consulting them would pin every
    -- wait to the floor -- burning more power locked than unlocked, the
    -- exact opposite of the feature.
    local s = new_state({
        screen_locked = true,
        last_clock_redraw_ms = 0,   -- long overdue
        last_battery_poll_ms = 0,   -- long overdue
    })
    -- The ping still applies (liveness is not suspended by the lock), but
    -- the two overdue suspended timers must not drag the wait down to the
    -- floor -- that would burn more power locked than unlocked.
    check_eq("locked + overdue suspended timers still waits for the ping",
        compute_poll_timeout(s), WS_PING_INTERVAL_MS)

    local locked_disconnected = new_state({
        screen_locked = true, conn = false, conn_status = "offline",
        last_clock_redraw_ms = 0, last_battery_poll_ms = 0,
        next_reconnect_at = 100000 + 10 * HOUR,
    })
    check_eq("...and with no connection either, the full ceiling",
        compute_poll_timeout(locked_disconnected), POLL_CEILING_MS)

    local n = wakeups_over(s, HOUR)
    check(string.format("locked for an hour wakes %d times", n),
        n <= IDLE_WAKEUPS_PER_HOUR_MAX)
    check("...and stays locked (nothing unlocks itself)", s.screen_locked)
    check("...and the link stayed up the whole time", s.conn and s.watchdog_fired == nil)
end

print("\n=== locked but disconnected still honours reconnect timing ===")
do
    local s = new_state({ screen_locked = true, conn = false, conn_status = "offline",
                          next_reconnect_at = 100000 + 4000 })
    check_eq("waits until the reconnect deadline", compute_poll_timeout(s), 4000)

    local far = new_state({ screen_locked = true, conn = false, conn_status = "offline",
                            next_reconnect_at = 100000 + 10 * 60 * 1000 })
    check_eq("but never longer than the ceiling", compute_poll_timeout(far), POLL_CEILING_MS)
end

print("\n=== connection watchdog (the half-open socket that started this) ===")
do
    -- A healthy link answers pings, so it must never be torn down.
    local healthy = new_state({ server_replies = true })
    wakeups_over(healthy, 4 * HOUR)
    check("a healthy link survives four hours untouched",
        healthy.conn and healthy.watchdog_fired == nil)

    -- A peer that vanished without closing the socket: exactly the
    -- 2026-08-12 case, where the laptop's IP moved and the Kindle's
    -- socket stayed ESTABLISHED with the user's taps stuck in its send
    -- queue. Nothing arrives, so only the silence timeout can catch it.
    local dead = new_state({ server_replies = false })
    wakeups_over(dead, 5 * 60 * 1000)
    check("a silent peer is detected", dead.watchdog_fired ~= nil,
        "the dashboard would keep claiming ONLINE")
    check_eq("...and the connection is dropped", dead.conn, false)
    check_eq("...and it goes offline rather than pretending", dead.conn_status, "offline")

    -- Detection has to be prompt enough to be useful, and patient enough
    -- to survive one lost ping on this device's historically flaky wifi.
    local t = new_state({ server_replies = false })
    local start = t.now
    while t.conn and t.now - start < 10 * 60 * 1000 do
        t.now = t.now + compute_poll_timeout(t)
        run_timed_blocks(t)
    end
    local took = t.now - start
    check(string.format("detected in %ds (>60s, <=120s)", took / 1000),
        took > 60 * 1000 and took <= 120 * 1000)
    check("...which is more than one missed ping", took > WS_PING_INTERVAL_MS)

    -- And it must not thrash: once dropped, reconnect timing takes over.
    check("a dropped link schedules a reconnect", t.next_reconnect_at > t.now - 1)
end

print("\n=== short-lived UI timers are not slept through ===")
do
    local toast = new_state({ flash_expire_at_ms = 100000 + 3000 })
    check_eq("a pending toast shortens the wait to its expiry",
        compute_poll_timeout(toast), 3000)

    local armed = new_state({ armed_delete_id = 7, armed_delete_until_ms = 100000 + 4000 })
    check_eq("an armed delete shortens the wait to its window",
        compute_poll_timeout(armed), 4000)

    -- Both pending: the SOONER one wins, or the later one is missed.
    local both = new_state({ flash_expire_at_ms = 100000 + 3000,
                             armed_delete_id = 7, armed_delete_until_ms = 100000 + 4000 })
    check_eq("with both pending, the sooner one wins", compute_poll_timeout(both), 3000)

    -- An expired-but-not-yet-cleared deadline must not produce a negative
    -- or zero wait.
    local overdue = new_state({ flash_expire_at_ms = 100000 - 5000 })
    check_eq("an overdue deadline clamps to the floor",
        compute_poll_timeout(overdue), POLL_FLOOR_MS)
end

print("\n=== idle auto-lock ===")
do
    local FIFTEEN = 15 * 60 * 1000
    local s = new_state({ auto_lock_idle_ms = FIFTEEN })
    check_eq("the auto-lock deadline is not slept past",
        compute_poll_timeout(new_state({ auto_lock_idle_ms = 2000 })), 2000)

    wakeups_over(s, FIFTEEN + 60 * 1000)
    check("locks itself after the idle window", s.screen_locked)

    -- ...and having locked, it must not keep re-firing: last_input_ms is
    -- left alone while locked, so the condition stays true and only the
    -- screen_locked guard stops it.
    local n = wakeups_over(s, HOUR)
    check(string.format("stays quiet afterwards (%d wakeups in the next hour)", n),
        n <= IDLE_WAKEUPS_PER_HOUR_MAX)

    -- Input postpones it. A dashboard being used should never blank.
    local used = new_state({ auto_lock_idle_ms = FIFTEEN })
    for _ = 1, 20 do
        used.now = used.now + 10 * 60 * 1000 -- a tap every 10 minutes
        used.last_input_ms = used.now
        run_timed_blocks(used)
    end
    check("a tap every 10 min never triggers the 15 min lock", not used.screen_locked)

    -- Disabled means disabled.
    local off = new_state({ auto_lock_idle_ms = nil })
    wakeups_over(off, 4 * HOUR)
    check("auto_lock_idle_ms = 0/nil never locks", not off.screen_locked)
end

print("")
if failures == 0 then
    print("ALL CHECKS PASSED")
else
    print(failures .. " CHECK(S) FAILED")
    os.exit(1)
end
