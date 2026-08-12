#!/./luajit
--[[
daemon.lua -- entry point. Run via bin/run.sh, which cd's into this
directory first (so require("config") etc. resolve relative to here) and
execs `luajit daemon.lua`. See kindle-daemon/README.md for the overall
design and kindle-daemon/INSTALL.md for how to actually get this running
and boot-persistent on the device.

This process is meant to run forever. Per embedded-systems practice, the
per-iteration body of the main loop is wrapped in pcall so a single bad
event (a malformed touch read, a JSON decode hiccup, a drawing call that
fails) gets logged and the loop keeps going instead of taking the whole
dashboard down. If something well and truly unexpected escapes anyway,
we log it and exit(1) rather than spin -- the upstart job (see
install/kindle-dashboard.conf) has `respawn`, so upstart will restart us
cleanly rather than the process wedging in a bad state forever.
]]

local log = require("log")
local ok_cfg, config = pcall(require, "config")
if not ok_cfg then
    io.stderr:write("FATAL: could not load config.lua -- did you copy " ..
        "config.example.lua to config.lua and edit it? See INSTALL.md.\n")
    os.exit(1)
end

log.init(config.log_path)
log.info("daemon starting up")

-- config.laptop_ip is a static fallback; it goes stale the moment the
-- laptop switches wifi networks (different router = different subnet).
-- ops/start_dashboard.ps1 auto-detects the laptop's current LAN IP and
-- passes it here via LAPTOP_IP every run, so no manual config.lua edit is
-- needed after a network change -- this override just wins when present.
local env_laptop_ip = os.getenv("LAPTOP_IP")
if env_laptop_ip and env_laptop_ip ~= "" then
    log.info("daemon: overriding config.laptop_ip with LAPTOP_IP env var (" .. env_laptop_ip .. ")")
    config.laptop_ip = env_laptop_ip
end

local posix = require("posix")
local websocket = require("websocket")
local touch = require("touch")
local keys = require("keys")
local json = require("json")
local ui = require("ui")
local battery = require("battery")

ui.init(config.fbink_path, log)

-- Probe the battery once at startup and cache whichever source worked
-- (see src/battery.lua for the ranked chain and why it's probed once
-- rather than per read). nil here just means "unknown" -- the UI renders
-- that state explicitly and the dashboard is fully usable without it.
local battery_percent = battery.init(log)
local last_battery_poll_ms = 0

-- 60s. Kept as a local constant rather than a config.lua setting on
-- purpose: config.lua is a file every existing install already has a
-- copy of, so a new key added there would read as nil on every machine
-- that hasn't re-copied config.example.lua -- a silent breakage for a
-- value nobody needs to tune. The underlying gas gauge only updates on
-- the order of tens of seconds anyway, so polling faster would return
-- the identical integer.
local BATTERY_POLL_INTERVAL_MS = 60 * 1000

-- ===================== touch input setup =====================

local touch_device_path = config.touch_device_path
if not touch_device_path then
    touch_device_path = touch.autodetect_device(log)
    if not touch_device_path then
        log.warn("touch: could not auto-detect a touch device from " ..
            "/proc/bus/input/devices. Touch input will be disabled -- " ..
            "the dashboard will still display and update from the " ..
            "backend, but taps won't do anything until you set " ..
            "touch_device_path explicitly in config.lua. See INSTALL.md step 3.")
    end
end

-- Screen-orientation transform for the touch panel, from config.lua.
-- Held in a named local rather than inlined at the open() call because
-- the main loop RE-OPENS the reader after a read error, and that reopen
-- previously passed no transform at all -- so a device configured with
-- swap_xy/invert_* would silently start reporting untransformed
-- coordinates after one transient error. That now matters more than it
-- used to: with gestures, a lost invert_x doesn't just misplace taps, it
-- mirrors swipe DIRECTIONS, so page turns would start running backwards.
local touch_transform = {
    swap_xy = config.touch_swap_xy,
    invert_x = config.touch_invert_x,
    invert_y = config.touch_invert_y,
    screen_w = 600,
    screen_h = 800,
}

local touch_reader = nil
if touch_device_path then
    local tr, err = touch.open(touch_device_path, log, touch_transform)
    if tr then
        touch_reader = tr
    else
        log.warn("touch: " .. tostring(err))
    end
end

-- ===================== power button setup =====================
--
-- Optional: if no power-button device is found, everything else works
-- exactly as before and only the screen-lock feature is unavailable.
-- config.power_key_device_path forces a specific node (existing
-- config.lua files won't have the key at all, which reads as nil and
-- means "auto-detect" -- so no config regeneration is needed).

local power_key_path = config.power_key_device_path
if not power_key_path then
    power_key_path = keys.autodetect_device(log)
end

local key_reader = nil
if power_key_path then
    local kr, kerr = keys.open(power_key_path, log)
    if kr then
        key_reader = kr
    else
        log.warn("keys: " .. tostring(kerr) .. " -- screen lock disabled")
    end
end

-- ===================== websocket connection management =====================

local conn = nil
local conn_status = "connecting" -- "connecting" | "open" | "offline"
local reconnect_backoff_ms = config.reconnect_min_ms
local next_reconnect_at = 0 -- os.clock()-based monotonic-ish deadline

-- Monotonic-ish clock in milliseconds, read from /proc/uptime (plain
-- text, no FFI needed). We deliberately do NOT use os.clock(): that
-- measures CPU time, not wall-clock time, and barely advances while this
-- process is blocked inside poll() waiting for input -- which is most of
-- the time -- so backoff/redraw timers built on it would effectively
-- never fire. Falls back to os.time()*1000 (1-second resolution, but
-- still real wall-clock time) if /proc/uptime is ever unreadable.
local function now_ms()
    local f = io.open("/proc/uptime", "r")
    if f then
        local line = f:read("*l")
        f:close()
        local seconds = line and tonumber(line:match("^%S+"))
        if seconds then
            return math.floor(seconds * 1000)
        end
    end
    return os.time() * 1000
end

-- Toast auto-dismiss state (only meaningful while ui_mode == "dashboard"
-- -- the toast overlays the nav bar, which only exists in dashboard
-- mode; see ui.flash_message()'s doc comment in ui.lua). User-requested
-- (2026-08-02 live device session): every toast is pure FYI with nothing
-- clickable of its own, so it doesn't need to sit on screen indefinitely
-- waiting for some unrelated redraw to clear it. show_flash() below is
-- the ONLY place in this file that should call ui.flash_message()
-- directly from here on -- every OTHER call site in this file should go
-- through show_flash() instead, so every toast gets this timer for free
-- rather than some call sites remembering to set it and others not.
-- Declared up here (immediately after now_ms(), its only dependency)
-- rather than down with the rest of the UI-mode state below, specifically
-- so handle_restart_ssh() further down can already use it -- Lua locals
-- must be declared before use, no hoisting.
local flash_expire_at_ms = nil
local FLASH_DURATION_MS = 3000

-- Screen lock (power button). Deliberately NOT another ui_mode value:
-- locking is orthogonal to which screen you were on, and modelling it as
-- a mode would mean remembering and restoring the previous one by hand.
-- As a separate flag, unlocking just redraws whatever ui_mode still says,
-- including the Add Task keyboard with its typed buffer intact.
--
-- What "locked" actually means, and why -- the point of this feature is
-- power, and on e-ink a static image costs NOTHING to keep on screen.
-- All the power goes on screen REFRESHES and on the CPU waking up to do
-- them. So locking suppresses the WORK, not just the pixels:
--   * the periodic clock redraw stops
--   * the battery poll stops (the read too, not only the drawing)
--   * incoming state pushes update current_state but draw nothing
--   * touch input is ignored entirely
-- That last one is a feature in its own right: a locked dashboard in a
-- bag shouldn't be completing tasks.
--
-- The WebSocket is deliberately left CONNECTED. Dropping it would save a
-- little more radio power, but an unlock would then show stale data
-- until a reconnect completed, and this device's wifi is historically
-- the least reliable part of the system (see ops/README.md) -- extra
-- reconnect churn is exactly what we don't want to introduce.
--
-- Declared HERE, well above the rest of the UI state, specifically so
-- show_flash() below can already see it: Lua locals must exist before
-- they're referenced and there is no hoisting.
local screen_locked = false

-- When the last real user input (tap, swipe, power button) happened.
-- Backend state pushes deliberately do NOT count: the dashboard updating
-- itself in the corner of the room is not somebody using it, and if it
-- reset this the idle timer would never expire on a busy day.
local last_input_ms = 0 -- set properly just before the main loop, once
                         -- now_ms() has a real uptime to read

-- Idle auto-lock: lock the screen after this long with no input, exactly
-- as if the power button had been pressed (press it again to come back).
--
-- Read from config.lua if present, but defaulted HERE, for the same
-- reason BATTERY_POLL_INTERVAL_MS is a constant: config.lua is a file
-- every existing install already has on the device (it's gitignored and
-- device-local), so a setting that only exists in config.example.lua
-- would be nil on every machine this is deployed to and the feature
-- would silently never run. Set `auto_lock_idle_ms = 0` in config.lua to
-- turn it off.
local AUTO_LOCK_IDLE_MS = config.auto_lock_idle_ms
if AUTO_LOCK_IDLE_MS == nil then AUTO_LOCK_IDLE_MS = 15 * 60 * 1000 end
if AUTO_LOCK_IDLE_MS <= 0 then AUTO_LOCK_IDLE_MS = nil end

local function show_flash(text)
    -- Toasts draw straight to the screen rather than going through
    -- redraw(), so redraw()'s own lock guard doesn't cover them. This is
    -- the single choke point for every toast in this file (see the
    -- comment above), which makes it the right place to enforce it --
    -- otherwise a backend rejection arriving just after the user locked
    -- the screen would stamp a black bar across the blank display.
    if screen_locked then
        log.info("suppressing toast while screen is locked: " .. tostring(text))
        return
    end
    ui.flash_message(text)
    flash_expire_at_ms = now_ms() + FLASH_DURATION_MS
end

--- Run a shell command and capture its combined stdout+stderr output, for
--- the one feature (Restart SSH) that actually needs to see what a shell
--- command printed rather than just fire-and-forget it. Everywhere else
--- in this codebase (ui.lua, tools/*.lua) uses os.execute() instead,
--- since they only ever cared about pass/fail, not output -- io.popen is
--- the standard Lua idiom for the "I need the output" case os.execute
--- can't cover.
---
--- Returns (output_string, close_ok). close_ok mirrors the same
--- platform-dependent looseness ui.lua's M.run() already documents for
--- os.execute()'s return value -- treat it as informational, not as the
--- sole source of truth (the Restart SSH feature re-checks with a real
--- process check afterward rather than trusting this alone; see
--- handle_restart_ssh below).
local function shell_capture(cmd)
    -- Wrap in a subshell before appending 2>&1: config.ssh_restart_cmd is
    -- a multi-statement compound command (cd && dropbear; iptables ...;
    -- iptables ...) -- appending redirection to the bare string only
    -- scopes it over the LAST clause, silently dropping stderr from
    -- every earlier statement, which is exactly the diagnostic most
    -- likely to explain a failure (e.g. `cd` failing because
    -- config.lua's koreader path is wrong). The parens make the
    -- redirection apply to the whole compound command instead.
    local fh = io.popen("(" .. cmd .. ") 2>&1")
    if not fh then
        return nil, false
    end
    local output = fh:read("*a") or ""
    local close_ok = fh:close()
    return output, (close_ok == true)
end

--- CONFIRMED ON HARDWARE (2026-08-02, live SSH session): dropbear is the
--- process KOReader's own SSH.koplugin starts, and it's a real running
--- process (not just a pidfile) whenever SSH is up. Uses `ps | grep` with
--- the classic "[d]ropbear" bracket trick (so the grep process's own argv
--- doesn't match itself) rather than `pgrep -f dropbear` -- pgrep's
--- presence on this device's busybox build was not separately confirmed,
--- while `ps`/`grep` are already relied on elsewhere in this project's
--- tooling assumptions, so this is the more conservative choice.
local function is_dropbear_running()
    local output = shell_capture("ps | grep '[d]ropbear'")
    return output ~= nil and output:find("%S") ~= nil
end

--- Handles the "Restart SSH" button: starts dropbear (KOReader's SSH
--- server) via config.ssh_restart_cmd if it isn't already running, and
--- always leaves the user with an on-screen toast saying what happened --
--- this is the one piece of on-device UI that exists specifically so a
--- lost SSH session can be recovered without a full device reboot.
local function handle_restart_ssh()
    log.info("restart_ssh: button tapped")
    if is_dropbear_running() then
        log.info("restart_ssh: dropbear already running, nothing to do")
        show_flash("SSH already running")
        return
    end

    if not config.ssh_restart_cmd or config.ssh_restart_cmd == "" then
        log.warn("restart_ssh: config.ssh_restart_cmd is not set in config.lua")
        show_flash("SSH restart not configured")
        return
    end

    log.info("restart_ssh: dropbear not running, attempting to start it")
    local output = shell_capture(config.ssh_restart_cmd)
    log.info("restart_ssh: command output: " .. tostring(output))

    -- dropbear daemonizes itself (forks to background) rather than
    -- blocking, per the confirmed start command this mirrors -- give it
    -- a brief moment before re-checking rather than racing the fork.
    os.execute("sleep 1")

    if is_dropbear_running() then
        log.info("restart_ssh: dropbear started successfully")
        show_flash("SSH started (port 2222)")
    else
        log.warn("restart_ssh: dropbear still not running after start attempt")
        local trimmed = (output or ""):gsub("%s+$", ""):sub(1, 60)
        show_flash("SSH start failed" .. (trimmed ~= "" and (": " .. trimmed) or ""))
    end
end

local function try_connect()
    log.info(string.format("ws: attempting connection to %s:%d%s",
        config.laptop_ip, config.laptop_port, config.ws_path))
    local c, err = websocket.connect(config.laptop_ip, config.laptop_port, config.ws_path)
    if not c then
        log.warn("ws: connect failed: " .. tostring(err))
        conn = nil
        conn_status = "offline"
        -- Same backoff the "closed" event handler applies after a
        -- connect-then-drop -- previously missing here, so an outright
        -- connect() failure (e.g. no route to host during a real network
        -- outage) retried as fast as the main loop's poll cadence allowed
        -- (~every poll_timeout_ms) instead of backing off.
        next_reconnect_at = now_ms() + reconnect_backoff_ms
        reconnect_backoff_ms = math.min(reconnect_backoff_ms * 2, config.reconnect_max_ms)
        return
    end
    conn = c
    conn_status = "connecting"
end

-- ===================== dashboard state + redraw =====================

local current_state = nil
local current_hit_zones = {}
local last_clock_redraw_ms = 0
local task_page = 1 -- which page of tasks is showing; see ui.lua's
                     -- draw_dashboard doc comment for the pagination model
local learning_page = 1 -- the same, for the Learning screen. Kept
                         -- separate from task_page so switching tabs
                         -- back and forth doesn't reset where you were
                         -- in the other list.

-- UI mode: which screen is currently on the e-ink display and therefore
-- which set of hit_zones current_hit_zones holds. daemon.lua is the sole
-- owner of this (and all other UI-adjacent state below) -- ui.lua stays a
-- pure "given this state, draw these pixels and return hit_zones"
-- renderer, matching the existing separation of concerns in this file.
--   "dashboard" -- the normal Today view (default)
--   "learning"  -- the Learning list (courses + books), reached from the
--                  nav bar. Read-only on the device: every learning
--                  edit needs a number, and the on-screen keyboard has
--                  no digits, so Telegram owns all mutation.
--   "keyboard"  -- the on-screen keyboard for the Add Task flow
--   "confirm_exit" -- the Exit Dashboard confirmation screen
local ui_mode = "dashboard"

-- Which nav tab each ui_mode corresponds to. Only the two screens that
-- actually draw a nav bar appear here; the keyboard and exit-confirm
-- screens draw none, and nil is the right answer for them (see the
-- toast-dismiss path, which must not paint a nav bar over a screen that
-- doesn't have one).
local UI_MODE_TAB = { dashboard = "Today", learning = "Learning" }

-- Which ui_mode a nav tab switches to, for the tabs that are real
-- screens. Anything absent is still a "coming soon" stub.
local TAB_UI_MODE = { Today = "dashboard", Learning = "learning" }

-- Add Task flow state (only meaningful while ui_mode == "keyboard").
local keyboard_buffer = ""

-- Delete-armed state (only meaningful while ui_mode == "dashboard"): the
-- id of a task whose delete zone was tapped once and is now waiting for
-- a confirming second tap within DELETE_CONFIRM_WINDOW_MS. Reuses the
-- now_ms() monotonic-ish clock already defined above, same as the
-- websocket reconnect backoff does.
local armed_delete_id = nil
local armed_delete_until_ms = 0
local DELETE_CONFIRM_WINDOW_MS = 4000

local function redraw(reason)
    -- A locked screen absorbs every redraw request, wherever it came
    -- from. Enforcing it HERE rather than at each call site is what
    -- makes the guarantee actually hold: there are a dozen paths that
    -- can trigger a draw (state pushes, taps, timers, toasts, page
    -- turns), and one of them forgetting to check would put pixels back
    -- on a screen the user has locked. The lock/unlock transition itself
    -- goes through set_screen_locked below, which draws directly.
    if screen_locked then
        log.info("redraw suppressed (screen locked): " .. reason)
        return
    end

    log.info("redraw: " .. reason .. " (mode=" .. ui_mode .. ")")
    local ok, hit_zones_or_err, effective_page = pcall(function()
        if ui_mode == "keyboard" then
            return ui.draw_keyboard(keyboard_buffer)
        elseif ui_mode == "confirm_exit" then
            return ui.draw_confirm_exit()
        elseif ui_mode == "learning" then
            return ui.draw_learning(current_state, conn_status, learning_page, battery_percent)
        else
            return ui.draw_dashboard(current_state, conn_status, task_page, armed_delete_id, battery_percent)
        end
    end)
    if ok then
        current_hit_zones = hit_zones_or_err
        if ui_mode == "dashboard" then
            -- ui.lua clamps task_page to however many pages currently
            -- exist (e.g. after tasks are completed/deleted and the list
            -- shrinks); store that back so we don't keep requesting a
            -- page that no longer exists. Not meaningful for the other
            -- ui_modes, which don't return a second value.
            task_page = effective_page or task_page
        elseif ui_mode == "learning" then
            learning_page = effective_page or learning_page
        end
        last_clock_redraw_ms = now_ms()
    else
        log.error("redraw failed: " .. tostring(hit_zones_or_err))
    end
end

--- Like redraw(), but only actually redraws while the dashboard is the
--- active screen -- for the passive/background triggers (a new state
--- push from the backend, a connection status change, the periodic clock
--- tick) that should update quietly behind the scenes rather than
--- yanking the user out of the keyboard or the exit-confirm screen
--- they're currently looking at. current_state/conn_status themselves
--- are still updated by the caller either way; this only gates whether
--- that change gets drawn right now. Whatever's pending is picked up by
--- the next redraw() once ui_mode returns to "dashboard" (both the
--- keyboard's cancel/confirm paths and the confirm-exit's cancel path
--- already call redraw() unconditionally on the way back).
local function redraw_if_dashboard(reason)
    if ui_mode == "dashboard" then
        redraw(reason)
    end
end

--- Like redraw_if_dashboard(), but for changes that affect EVERY screen
--- which renders backend state -- currently the dashboard and the
--- Learning list. A fresh state push changes the learning list just as
--- much as it changes the task list, and the connection badge is drawn
--- on both, so gating those on "dashboard only" would leave the Learning
--- screen showing stale progress with no indication anything was wrong.
---
--- Kept as a SEPARATE helper from redraw_if_dashboard rather than
--- widening that one, because the two remaining callers of the narrower
--- version are genuinely dashboard-only concerns: the periodic clock
--- tick (the Learning screen has no clock, so redrawing it on that
--- timer would be a full-screen e-ink flash for a pixel that didn't
--- change) and the delete-confirmation expiry (an armed task delete
--- only exists on the dashboard).
local function redraw_if_showing_state(reason)
    if ui_mode == "dashboard" or ui_mode == "learning" then
        redraw(reason)
    end
end

--- Locks or unlocks the screen. The single place that transition
--- happens, so the drawing and the state flag can never disagree.
---
--- Locking blanks the screen and drops all hit zones, so even if
--- something did manage to hit-test while locked there would be nothing
--- to hit. Unlocking sets the flag FIRST and then calls redraw(), which
--- would otherwise suppress itself -- and that full redraw is what
--- brings the screen back up to date with any state that arrived while
--- the user wasn't looking.
local function set_screen_locked(locked, reason)
    if locked == screen_locked then return end
    screen_locked = locked

    if locked then
        log.info("screen LOCKED (" .. reason .. ") -- blanking, and pausing " ..
            "the clock redraw, battery poll, and touch input")
        current_hit_zones = {}
        local ok, err = pcall(ui.draw_blank_screen)
        if not ok then
            -- Don't leave the flag claiming "locked" over a screen that
            -- still shows the dashboard: that would silently deaden
            -- every control while everything still LOOKS tappable, which
            -- is far worse than the lock simply not engaging.
            log.error("lock: blanking the screen failed (" .. tostring(err) ..
                ") -- staying unlocked")
            screen_locked = false
            return
        end
    else
        log.info("screen UNLOCKED (" .. reason .. ") -- restoring " .. ui_mode)
        -- Unlocking IS input. Without this the idle timer would still be
        -- measuring from the last tap before the lock, so a screen
        -- unlocked after a long idle period would re-lock itself on the
        -- very next check -- pressing power would look like it did
        -- nothing at all.
        last_input_ms = now_ms()
        redraw("unlocked")
    end
end

local function zone_contains(z, x, y)
    return x >= z.x and x < z.x + z.w and y >= z.y and y < z.y + z.h
end

--- Zone kinds that describe a GESTURE REGION rather than a tap target.
---
--- These deliberately span whole areas ON TOP OF the individual tap
--- targets inside them -- the task-list swipe area contains every task
--- row, its delete zones, the pager and the "+ Add Task" row. They must
--- therefore be invisible to tap resolution, or the first one registered
--- swallows every tap in its band.
---
--- This is not hypothetical. Without this exclusion, `task_swipe_area`
--- was hit_zones[1] and the ENTIRE Today task area went inert the moment
--- the first state snapshot arrived: checkboxes, per-row delete, the
--- pager, and "+ Add Task" all resolved to the swipe zone, which no tap
--- handler has a branch for, so every one of them silently did nothing.
--- Only the footer and nav bar (below the region) still responded.
---
--- Filtering by kind here, rather than relying on registration ORDER, is
--- deliberate: ordering would work but would make the position of one
--- table insert load-bearing and unremarked, which is how this broke in
--- the first place.
local GESTURE_ZONE_KINDS = {
    task_swipe_area = true,
    learning_swipe_area = true,
}

--- Resolves a TAP: the first non-gesture zone containing the point.
local function hit_test(x, y)
    for _, z in ipairs(current_hit_zones) do
        if not GESTURE_ZONE_KINDS[z.kind] and zone_contains(z, x, y) then
            return z
        end
    end
    return nil
end

--- Resolves a GESTURE: finds a zone of a specific kind containing
--- (x, y), ignoring the tap targets that overlap it. The mirror image of
--- hit_test above -- between them, tap targets and gesture regions can
--- freely overlap in both directions without either lookup interfering
--- with the other.
local function find_zone_by_kind(kind, x, y)
    for _, z in ipairs(current_hit_zones) do
        if z.kind == kind and zone_contains(z, x, y) then
            return z
        end
    end
    return nil
end

--- Bottom nav bar taps, shared by every screen that draws one. Declared
--- before the per-screen tap handlers below because Lua locals must
--- exist before they're referenced -- there is no hoisting.
local function handle_nav_tap(zone)
    local target_mode = TAB_UI_MODE[zone.name]
    if not target_mode then
        show_flash(zone.name .. " is coming soon.")
        return
    end
    if target_mode == ui_mode then
        -- Already here. Deliberately silent: a redraw would cost a
        -- full-screen e-ink flash to produce the identical screen, and a
        -- toast saying "you're already on this tab" is noise for
        -- something the highlighted tab already shows.
        return
    end
    ui_mode = target_mode
    redraw("switched to the " .. zone.name .. " tab")
end

local function handle_dashboard_tap(zone)
    -- Delete-armed state takes priority over everything else: if a
    -- delete is currently armed, this tap either confirms it (same zone,
    -- within the window) or disarms it -- and does NOTHING else, even if
    -- it also happens to land on some other tappable zone. This is
    -- deliberate: while a delete confirmation is showing, a stray tap
    -- elsewhere should read as "never mind, cancel that", not as
    -- simultaneously cancelling AND performing some unrelated action.
    if armed_delete_id ~= nil then
        local n = now_ms()
        local still_armed = n < armed_delete_until_ms
        if still_armed and zone and zone.kind == "delete_task_zone" and zone.id == armed_delete_id then
            -- CONFIRMED ON HARDWARE (2026-08-02): show_flash() then
            -- redraw() (the original order here) meant the very next full
            -- dashboard redraw immediately painted over the toast before
            -- it was ever visible -- redraw() always wins since it draws
            -- the ENTIRE screen, including the nav bar the toast overlays.
            -- Fixed by flipping the order: redraw() first (so the row's
            -- armed/not-armed state is correct), then show_flash() LAST
            -- so it's the last thing painted and actually stays visible
            -- for its full auto-dismiss window instead of for zero
            -- perceptible time.
            local failure_toast = nil
            if conn and conn_status == "open" then
                local send_ok, send_err = conn:send_text(json.encode({ action = "delete_task", id = armed_delete_id }))
                if send_ok then
                    log.info("sent delete_task id=" .. tostring(armed_delete_id))
                    armed_delete_id = nil
                else
                    -- conn_status can still read "open" here even though
                    -- the write itself just failed -- conn_status only
                    -- flips to "offline" once poll() notices the socket
                    -- error on a LATER loop iteration. Don't clear
                    -- armed_delete_id or claim success: leave the row
                    -- armed so the existing expiry timeout disarms it
                    -- visibly instead of silently pretending this worked.
                    log.warn("delete_task send failed: " .. tostring(send_err))
                    failure_toast = "Couldn't send -- not connected?"
                end
            else
                failure_toast = "Not connected -- can't delete tasks right now"
                armed_delete_id = nil
            end
            redraw("delete confirmed")
            if failure_toast then
                show_flash(failure_toast)
            end
            return
        else
            log.info("delete confirmation disarmed (tapped elsewhere or window expired)")
            armed_delete_id = nil
            redraw("delete disarmed")
            return
        end
    end

    if not zone then
        log.info("tap did not hit any known zone")
        return
    end

    if zone.kind == "toggle_task" then
        if conn and conn_status == "open" then
            local send_ok, send_err = conn:send_text(json.encode({ action = "toggle_task", id = zone.id }))
            if send_ok then
                log.info("sent toggle_task id=" .. tostring(zone.id))
            else
                log.warn("toggle_task send failed: " .. tostring(send_err))
                show_flash("Couldn't send -- not connected?")
            end
        else
            show_flash("Not connected -- can't update tasks right now")
        end
    elseif zone.kind == "delete_task_zone" then
        armed_delete_id = zone.id
        armed_delete_until_ms = now_ms() + DELETE_CONFIRM_WINDOW_MS
        log.info("delete armed for task id=" .. tostring(zone.id))
        redraw("delete armed")
    elseif zone.kind == "page_prev" or zone.kind == "page_next" or zone.kind == "page_goto" then
        -- One handler for all three pager controls: ui.lua already
        -- resolved each of them to a concrete destination page and
        -- refused to emit a zone at all for a move that isn't possible
        -- (a disabled end arrow, or the current page's own cell), so
        -- there is nothing left to validate or clamp here.
        --
        -- zone.target says WHICH paged list was tapped, so the same
        -- control can be reused on other screens without this branch
        -- having to guess.
        if zone.target == "tasks" then
            task_page = zone.page
            redraw("jumped to task page " .. tostring(zone.page))
        end
    elseif zone.kind == "add_task_button" then
        keyboard_buffer = ""
        ui_mode = "keyboard"
        redraw("add task tapped, entering keyboard")
    elseif zone.kind == "exit_dashboard_button" then
        ui_mode = "confirm_exit"
        redraw("exit dashboard tapped, showing confirmation")
    elseif zone.kind == "restart_ssh_button" then
        handle_restart_ssh()
    elseif zone.kind == "refresh_usage_button" then
        if conn and conn_status == "open" then
            local send_ok, send_err = conn:send_text(json.encode({ action = "refresh_usage" }))
            if send_ok then
                log.info("sent refresh_usage")
                show_flash("Refreshing usage...")
            else
                log.warn("refresh_usage send failed: " .. tostring(send_err))
                show_flash("Couldn't send -- not connected?")
            end
        else
            show_flash("Not connected -- can't refresh right now")
        end
    elseif zone.kind == "nav_tab" then
        handle_nav_tap(zone)
    end
end

--- The Learning screen is READ-ONLY on the device, deliberately: every
--- edit a learning supports needs a number (a percentage, a page), and
--- the on-screen keyboard is lowercase letters and space only -- it has
--- no digits at all. So there is no "+ Add" affordance to tap here and
--- no per-row action; Telegram owns all mutation.
---
--- That also means item rows register no hit zone at all. A registered
--- but inert zone would be worse than none: the user taps, gets either a
--- redraw flash or nothing, and learns not to trust the surface.
local function handle_learning_tap(zone)
    if not zone then return end

    if zone.kind == "page_prev" or zone.kind == "page_next" or zone.kind == "page_goto" then
        if zone.target == "learning" then
            learning_page = zone.page
            redraw("jumped to learning page " .. tostring(zone.page))
        end
    elseif zone.kind == "nav_tab" then
        handle_nav_tap(zone)
    end
end

local function handle_keyboard_tap(zone)
    if not zone then return end

    if zone.kind == "keyboard_key" then
        keyboard_buffer = keyboard_buffer .. zone.char
        ui.update_keyboard_preview(keyboard_buffer) -- fast partial refresh, not a full redraw()
    elseif zone.kind == "keyboard_space" then
        keyboard_buffer = keyboard_buffer .. " "
        ui.update_keyboard_preview(keyboard_buffer)
    elseif zone.kind == "keyboard_backspace" then
        if #keyboard_buffer > 0 then
            keyboard_buffer = keyboard_buffer:sub(1, -2)
            ui.update_keyboard_preview(keyboard_buffer)
        end
    elseif zone.kind == "keyboard_cancel" then
        log.info("add task cancelled, buffer discarded")
        keyboard_buffer = ""
        ui_mode = "dashboard"
        redraw("add task cancelled")
    elseif zone.kind == "keyboard_confirm" then
        if keyboard_buffer:match("^%s*$") then
            -- Nothing typed (or only spaces -- backend/main.py's own
            -- add_task strips the text server-side and rejects an
            -- all-whitespace result with a bad_request error; matching
            -- that same "^%s*$" emptiness check here means a few taps of
            -- SPACE can never round-trip to the backend and back as a
            -- visible error toast in the first place). Silently ignore
            -- rather than showing a toast: flash_message()'s fixed screen
            -- position is tuned for the dashboard's nav-bar layout, not
            -- this screen's, and since only the preview strip gets
            -- partial-refreshed here (see ui.update_keyboard_preview), a
            -- toast drawn elsewhere on this screen would stay stuck on
            -- top of the keyboard until the next full redraw. Simplest
            -- safe behavior: do nothing until there's actually something
            -- to add.
            return
        end
        if conn and conn_status == "open" then
            local send_ok, send_err = conn:send_text(json.encode({ action = "add_task", text = keyboard_buffer }))
            if send_ok then
                log.info("sent add_task text=" .. keyboard_buffer)
                keyboard_buffer = ""
                ui_mode = "dashboard"
                redraw("add task confirmed and sent")
            else
                -- conn_status can still read "open" here even though the
                -- write itself just failed -- see the matching comment on
                -- the delete_task path above. Same treatment as the
                -- not-connected branch below: keep the user in keyboard
                -- mode with their typed text intact rather than claiming
                -- success and silently losing it.
                log.warn("add_task send failed: " .. tostring(send_err))
            end
        else
            -- Same reasoning as the empty-buffer case above: no toast,
            -- since it would leave stale pixels on this screen. The
            -- user's typed text is preserved (not cleared, ui_mode
            -- unchanged) so they don't lose it -- they can retry Add
            -- once the connection recovers, or Cancel out.
            log.warn("add_task: not connected, keeping user in keyboard with buffer intact")
        end
    end
end

local function handle_confirm_exit_tap(zone)
    if not zone then return end

    if zone.kind == "confirm_exit_cancel" then
        log.info("exit dashboard cancelled")
        ui_mode = "dashboard"
        redraw("exit cancelled")
    elseif zone.kind == "confirm_exit_yes" then
        -- Per the project's established safety pattern (see this
        -- project's memory / README.md): always reboot rather than
        -- attempting a live in-place restart of the stock UI, which was
        -- previously found to trip lab126_gui's own crash-recovery
        -- safety net. No need to self-kill this luajit process first --
        -- the reboot tears everything down anyway.
        log.info("exit dashboard confirmed -- shutting down and rebooting")
        ui.draw_shutdown_message()
        local rm_ok = os.execute("rm -f /etc/upstart/kindle-dashboard.conf")
        if not (rm_ok == true or rm_ok == 0) then
            -- Not fatal (falls through to reboot regardless -- reboot is
            -- the actual point of this action, not the cleanup), but if
            -- autostart really was enabled and this silently failed, the
            -- only symptom after reboot is "the dashboard came back even
            -- though I chose Shut Down" with nothing explaining why.
            -- One log line now is cheap insurance against that.
            log.warn("exit: removing /etc/upstart/kindle-dashboard.conf may have failed (rc=" .. tostring(rm_ok) .. ")")
        end
        os.execute("sync; reboot")
    end
end

local function handle_tap(x, y)
    log.info(string.format("tap at (%d, %d)", x, y))
    local zone = hit_test(x, y)

    if ui_mode == "keyboard" then
        handle_keyboard_tap(zone)
    elseif ui_mode == "confirm_exit" then
        handle_confirm_exit_tap(zone)
    elseif ui_mode == "learning" then
        handle_learning_tap(zone)
    else
        handle_dashboard_tap(zone)
    end
end

--- Swipe handling. Only the two paged list screens react to swipes: the
--- keyboard and exit-confirm screens have no paged content, and silently
--- doing nothing there is better than inventing a gesture (a "swipe to
--- cancel" nobody asked for) on the two screens where a wrong guess is
--- most costly.
---
--- Direction mapping follows the page-turn convention every e-reader
--- (including this device's own stock reader) already uses: swiping LEFT
--- drags the current page off to the left, revealing the NEXT one, and
--- swiping right goes back. Matching what the user's thumb already
--- expects from reading books on this exact hardware matters more here
--- than any abstract argument about direction.
---
--- Deliberately CLAMPS at the ends rather than wrapping, even though the
--- old "See more tasks" button wrapped: a wrap is fine for a single
--- button whose whole job is "show me another page", but with numbered
--- pages now visible, jumping 5 -> 1 on a swipe reads as a glitch. At an
--- end, this does nothing at all -- no redraw, so no e-ink flash for a
--- gesture that changed nothing.
local function handle_swipe(gesture)
    if gesture.dir ~= "left" and gesture.dir ~= "right" then
        -- Vertical swipes are classified by touch.lua but unused here:
        -- both lists paginate rather than scroll, so there is nothing
        -- for an up/down gesture to mean. Swallowing it is the point --
        -- before gesture classification existed, that same finger
        -- movement landed as a tap and could toggle a task.
        return
    end

    local zone_kind, current_page
    if ui_mode == "dashboard" then
        zone_kind, current_page = "task_swipe_area", task_page
    elseif ui_mode == "learning" then
        zone_kind, current_page = "learning_swipe_area", learning_page
    else
        return
    end

    -- Hit-tested against where the swipe STARTED, not where it ended: a
    -- swipe that begins on the list and travels 200px can easily release
    -- outside it, and the user's intent is set by where they put their
    -- finger down.
    local area = find_zone_by_kind(zone_kind, gesture.start_x, gesture.start_y)
    if not area then
        log.info("swipe ignored: did not start on the list")
        return
    end

    local total_pages = area.total_pages or 1
    local new_page = current_page + ((gesture.dir == "left") and 1 or -1)
    if new_page < 1 or new_page > total_pages then
        log.info(string.format("swipe %s ignored: already at page %d of %d",
            gesture.dir, current_page, total_pages))
        return
    end

    if ui_mode == "dashboard" then
        task_page = new_page
    else
        learning_page = new_page
    end
    redraw(string.format("swiped %s to page %d", gesture.dir, new_page))
end

--- Single entry point for everything touch.lua produces. Kept separate
--- from handle_tap above so the tap path stays exactly as it was.
local function handle_gesture(gesture)
    -- A locked screen ignores touch outright -- taps, swipes, the lot.
    -- Only the power button can bring it back. This is deliberate: if a
    -- tap unlocked it, the dashboard would wake every time it shifted in
    -- a bag, which defeats the whole feature.
    if screen_locked then
        log.info("ignoring " .. tostring(gesture.kind) .. " -- screen is locked")
        return
    end

    -- Feeds the idle auto-lock. Set for EVERY gesture kind, including the
    -- inert "drag" below: a drag is a finger on the glass, so it means
    -- somebody is here, even though nothing on screen acts on it.
    last_input_ms = now_ms()

    if gesture.kind == "tap" then
        handle_tap(gesture.x, gesture.y)
    elseif gesture.kind == "swipe" then
        log.info(string.format("swipe %s from (%d, %d) to (%d, %d)",
            gesture.dir, gesture.start_x, gesture.start_y, gesture.x, gesture.y))
        handle_swipe(gesture)
    else
        -- "drag": travelled too far to be a tap, too diagonally to be a
        -- swipe. Intentionally inert -- see classify_gesture() in
        -- touch.lua for why it's reported instead of dropped there.
        log.info(string.format("ignoring %s gesture from (%d, %d) to (%d, %d)",
            tostring(gesture.kind), gesture.start_x, gesture.start_y, gesture.x, gesture.y))
    end
end

-- ===================== poll pacing (power) =====================
--
-- The loop used to wait a flat config.poll_timeout_ms (500ms) on every
-- iteration, so the CPU woke twice a second forever, whether or not
-- there was anything to do. That is pure waste on a battery device:
-- poll() returns the INSTANT a touch, a power-button press or a
-- WebSocket byte arrives regardless of the timeout, so the timeout only
-- ever governs work that is driven by a DEADLINE, never responsiveness.
--
-- So: sleep until the nearest real deadline instead of on a fixed tick.
-- Idle wakeups drop from ~2/second to ~1/minute (the clock redraw and
-- battery poll, the only recurring deadlines) and to nearly none while
-- locked, where even those are suspended. Touch and unlock latency are
-- completely unchanged -- they never depended on this number.
--
-- config.poll_timeout_ms is still honoured, now as the FLOOR: no wait is
-- ever shortened below it, so an install that tuned it down for
-- responsiveness still gets what it asked for.
local POLL_FLOOR_MS = math.max(config.poll_timeout_ms or 500, 50)

-- Longest a single poll() may wait. Bounds the case where nothing at all
-- is scheduled (essentially: while locked), and keeps one loop iteration
-- a bounded unit of time so anything ever added to the loop can't be
-- starved for minutes.
--
-- 60s, matching the clock redraw interval, deliberately: a lower ceiling
-- binds BELOW the soonest real deadline on an idle dashboard and splits
-- every one-minute sleep into two for no benefit -- tests/test_poll_pacing
-- .lua measured exactly that (120 wakeups an hour at a 30s ceiling
-- against the 60 the deadlines actually allow).
local POLL_CEILING_MS = 60 * 1000

--- How long poll() should wait this iteration: the time until the
--- soonest deadline any of the loop's timer-driven blocks is waiting on,
--- clamped to [POLL_FLOOR_MS, POLL_CEILING_MS].
---
--- Every deadline considered here MUST correspond to a block below that
--- unconditionally advances it when it fires. If one ever fires without
--- moving forward, this returns the floor every iteration for as long as
--- that lasts -- a busy loop, not a hang, but the exact opposite of the
--- point. That is not hypothetical: the periodic clock tick had this
--- shape already (redraw_if_dashboard does nothing while the keyboard is
--- up, and redraw() only stamps last_clock_redraw_ms on a draw that
--- actually happened), which the flat 500ms tick hid. See the clock
--- block in the loop for the fix that makes it hold.
local function compute_poll_timeout()
    local now = now_ms()
    local timeout = POLL_CEILING_MS

    local function until_deadline(deadline)
        if deadline == nil then return end
        local remaining = deadline - now
        if remaining < timeout then timeout = remaining end
    end

    if screen_locked then
        -- Locked suspends the clock redraw, the battery poll and touch
        -- handling, so none of their deadlines are live -- and including
        -- them here would be actively wrong: they are left in the PAST
        -- while locked (nothing advances them), so they would pin every
        -- wait to the floor and burn exactly the power locking is meant
        -- to save. Reconnect is the only thing still on a timer.
        if not conn then until_deadline(next_reconnect_at) end
    else
        until_deadline(last_clock_redraw_ms + config.clock_redraw_interval_ms)
        until_deadline(last_battery_poll_ms + BATTERY_POLL_INTERVAL_MS)
        if not conn then until_deadline(next_reconnect_at) end
        if flash_expire_at_ms then until_deadline(flash_expire_at_ms) end
        if armed_delete_id ~= nil then until_deadline(armed_delete_until_ms) end
        if AUTO_LOCK_IDLE_MS then until_deadline(last_input_ms + AUTO_LOCK_IDLE_MS) end
    end

    if timeout < POLL_FLOOR_MS then return POLL_FLOOR_MS end
    return timeout
end

-- ===================== main loop =====================

redraw("startup")
try_connect()

-- Start the idle clock from here rather than from 0: /proc/uptime is
-- already minutes old by the time the dashboard is started by hand over
-- SSH, and a 0 would mean "idle since boot" -- the very first check
-- would lock the screen the user just asked for.
last_input_ms = now_ms()

log.info("entering main loop")

while true do
    local ok, err = pcall(function()
        local poll_entries = {}
        if touch_reader then
            poll_entries[#poll_entries + 1] = { fd = touch_reader.fd }
        end
        -- The power button is polled even while locked -- it is the ONLY
        -- way back, so it must never be gated on the lock state.
        if key_reader then
            poll_entries[#poll_entries + 1] = { fd = key_reader.fd }
        end
        if conn then
            poll_entries[#poll_entries + 1] = { fd = conn.fd, want_write = conn:wants_write() }
        end

        local poll_timeout = compute_poll_timeout()

        local results
        if #poll_entries > 0 then
            results = posix.poll(poll_entries, poll_timeout)
        else
            results = {}
            -- nothing to poll (no touch device, no connection yet) --
            -- avoid a busy loop while we wait for reconnect timing
            if poll_timeout > 0 then
                os.execute("sleep " .. string.format("%.1f", poll_timeout / 1000))
            end
        end

        -- --- touch input ---
        if touch_reader then
            local r = results[touch_reader.fd]
            if r and r.readable then
                local bytes, rerr = posix.read_available(touch_reader.fd)
                if bytes == nil then
                    log.warn("touch: read error " .. tostring(rerr) .. " -- closing and retrying")
                    touch_reader:close()
                    -- Must pass touch_transform: without it the reopened
                    -- reader would drop the panel's orientation settings
                    -- and start reporting raw coordinates (and mirrored
                    -- swipe directions) for the rest of the process's
                    -- life. See touch_transform's definition above.
                    local reopened, reopen_err = touch.open(touch_device_path, log, touch_transform)
                    touch_reader = reopened
                    if not reopened then
                        -- Previously this silently assigned nil and touch
                        -- stayed dead until the daemon was restarted,
                        -- with nothing in the log explaining why the
                        -- screen had stopped responding. It still stays
                        -- dead (there's no retry timer), but at least the
                        -- log now says so in as many words.
                        log.error("touch: could not reopen " .. tostring(touch_device_path) ..
                            " (" .. tostring(reopen_err) .. ") -- TOUCH IS NOW DISABLED for " ..
                            "this run. The dashboard will keep displaying and updating, but " ..
                            "taps will do nothing until it is restarted.")
                    end
                elseif bytes ~= "" then
                    local gestures = touch_reader:feed(bytes)
                    for _, gesture in ipairs(gestures) do
                        handle_gesture(gesture)
                    end
                end
            end
        end

        -- --- power button ---
        if key_reader then
            local r = results[key_reader.fd]
            if r and r.readable then
                local bytes, kerr = posix.read_available(key_reader.fd)
                if bytes == nil then
                    log.warn("keys: read error " .. tostring(kerr) .. " -- closing and retrying")
                    key_reader:close()
                    local reopened, reopen_err = keys.open(power_key_path, log)
                    key_reader = reopened
                    if not reopened then
                        log.error("keys: could not reopen " .. tostring(power_key_path) ..
                            " (" .. tostring(reopen_err) .. ") -- the power button will no " ..
                            "longer lock/unlock the screen for the rest of this run. If the " ..
                            "screen is currently locked, restart the dashboard to get it back.")
                    end
                elseif bytes ~= "" then
                    for _, ev in ipairs(key_reader:feed(bytes)) do
                        -- Act on RELEASE, not press. Two reasons: it's
                        -- the conventional edge for a toggle, and this
                        -- PMIC also has a separate long-press
                        -- "manual reset" line that powers the device off
                        -- -- triggering on press would fire the toggle
                        -- on the way into a deliberate power-off too.
                        if ev.code == keys.KEY_POWER and ev.value == "release" then
                            -- Also counts as input for the idle timer, so
                            -- a deliberate lock-then-immediate-unlock
                            -- gives a full fresh idle window. (The unlock
                            -- side of set_screen_locked stamps it too;
                            -- this covers the lock side, which returns
                            -- early without redrawing.)
                            last_input_ms = now_ms()
                            set_screen_locked(not screen_locked, "power button")
                        end
                    end
                end
            end
        end

        -- --- websocket ---
        if conn then
            local prev_status = conn_status
            local events = conn:step(results[conn.fd])
            for _, ev in ipairs(events) do
                if ev.type == "open" then
                    conn_status = "open"
                    reconnect_backoff_ms = config.reconnect_min_ms
                    log.info("ws: connected")
                elseif ev.type == "text" then
                    local decode_ok, decoded = pcall(json.decode, ev.data)
                    if decode_ok and type(decoded) == "table" and decoded.error then
                        -- backend/main.py replies to a rejected action
                        -- (bad_request/not_found/internal_error) on this
                        -- SAME connection, with no "type" field to tell it
                        -- apart from a real state.snapshot() push -- e.g.
                        -- add_task with an all-whitespace buffer (see the
                        -- keyboard_confirm guard below) or a delete/toggle
                        -- racing a change made elsewhere (Telegram). Must
                        -- NOT fall into current_state = decoded below: an
                        -- error object has no .tasks, so draw_dashboard
                        -- would render "No tasks yet." and an empty usage
                        -- card even though the real backend state is
                        -- untouched -- a normal mis-tap making the whole
                        -- task list appear to vanish until some unrelated
                        -- future broadcast overwrites it.
                        log.warn("ws: backend rejected an action: " .. tostring(decoded.error) ..
                            " -- " .. tostring(decoded.detail))
                        show_flash(tostring(decoded.detail or decoded.error))
                    elseif decode_ok then
                        current_state = decoded
                        -- Not redraw() -- if the user is mid-typing on
                        -- the keyboard screen or looking at the exit
                        -- confirmation, a state push shouldn't yank them
                        -- back or draw underneath whatever's currently
                        -- on screen. See redraw_if_showing_state()'s doc
                        -- comment above.
                        redraw_if_showing_state("new state from backend")
                    else
                        log.warn("ws: failed to decode message as JSON: " .. tostring(decoded))
                    end
                elseif ev.type == "closed" then
                    log.warn("ws: connection closed (" .. tostring(ev.reason) .. ")")
                    conn = nil
                    conn_status = "offline"
                    next_reconnect_at = now_ms() + reconnect_backoff_ms
                    reconnect_backoff_ms = math.min(reconnect_backoff_ms * 2, config.reconnect_max_ms)
                end
            end
            if conn_status ~= prev_status and conn_status ~= "open" then
                redraw_if_showing_state("connection status changed to " .. conn_status)
            end
        elseif now_ms() >= next_reconnect_at then
            try_connect()
        end

        -- --- delete-confirmation expiry ---
        -- armed_delete_id is only cleared by a follow-up tap (confirm or
        -- disarm, see handle_dashboard_tap) -- if the user just walks away
        -- mid-confirmation, nothing else was clearing it, so the row kept
        -- showing the "tap again to delete" highlight indefinitely after
        -- DELETE_CONFIRM_WINDOW_MS actually elapsed (a stray tap after
        -- that point was still handled correctly as a no-op disarm, since
        -- handle_dashboard_tap checks the deadline too -- but the on-screen
        -- state was lying about the window still being open until then).
        -- Checked every loop iteration (poll_timeout_ms cadence) so the
        -- highlight clears itself promptly instead of waiting for the
        -- next unrelated redraw.
        if armed_delete_id ~= nil and now_ms() >= armed_delete_until_ms then
            log.info("delete confirmation expired (no follow-up tap)")
            armed_delete_id = nil
            redraw_if_dashboard("delete confirmation expired")
        end

        -- --- toast auto-dismiss ---
        -- Deliberately does NOT use redraw_if_dashboard() (which would do
        -- a full, comparatively expensive GC16 dashboard redraw just to
        -- clear a toast) -- ui.clear_flash_message() only repaints the
        -- nav bar strip the toast overlaid, which is all that needs
        -- restoring. Gated on the current screen actually HAVING a nav
        -- bar: if the user has since moved to the keyboard or
        -- exit-confirm screen, calling ui.clear_flash_message() would
        -- incorrectly paint a nav bar over whatever that screen is
        -- showing at that same pixel region. UI_MODE_TAB is nil for
        -- exactly those two screens, which is what makes this the same
        -- question as "which tab should be highlighted". In that case
        -- just clear the timer with nothing drawn -- those screens' own
        -- cancel/confirm paths already do a full unconditional redraw()
        -- on the way back, which clears any stale toast pixels too.
        --
        -- The tab name is passed through rather than assumed: restoring
        -- the bar without it would repaint "Today" as the active tab
        -- even when the user is sitting on the Learning screen.
        if flash_expire_at_ms ~= nil and now_ms() >= flash_expire_at_ms then
            flash_expire_at_ms = nil
            -- Also gated on the lock, and note this one does NOT go
            -- through redraw() -- ui.clear_flash_message() paints the nav
            -- bar strip directly, so redraw()'s own lock guard would not
            -- catch it. Without this check, a toast that happened to be
            -- on screen when the user locked would, three seconds later,
            -- stamp a nav bar across the blank screen.
            local active_tab = UI_MODE_TAB[ui_mode]
            if active_tab and not screen_locked then
                ui.clear_flash_message(active_tab)
            end
        end

        -- --- periodic battery poll ---
        -- Two separate rate limits here, doing two different jobs:
        --   BATTERY_POLL_INTERVAL_MS gates how often we READ the battery.
        --   The "did the number change" check gates how often we DRAW it.
        -- The read is a cheap sysfs file open, but every draw is a
        -- visible e-ink refresh, and this device's charge moves about 1%
        -- per 15-30 idle minutes -- so polling each minute while only
        -- repainting on a real change works out to a couple of tiny
        -- refreshes an hour instead of one per minute.
        --
        -- Deliberately NOT a full redraw(): ui.draw_battery_only()
        -- repaints and flushes just the header corner, the same
        -- partial-refresh treatment the toast dismissal already gets,
        -- rather than flashing the entire screen for two digits.
        -- Skipped entirely while locked. Not just the drawing -- the READ
        -- too, so the CPU isn't woken to open a sysfs file for a number
        -- nobody can see. Same for the clock tick below. Suppressing this
        -- work is the actual power saving; the blank screen itself costs
        -- nothing either way on e-ink.
        if not screen_locked and (now_ms() - last_battery_poll_ms) >= BATTERY_POLL_INTERVAL_MS then
            last_battery_poll_ms = now_ms()
            local fresh = battery.read()
            if fresh ~= battery_percent then
                log.info("battery: " .. tostring(battery_percent) .. " -> " .. tostring(fresh))
                battery_percent = fresh
                -- Repaint on any screen that actually DRAWS the battery
                -- into L.battery_region_* -- the dashboard and the
                -- Learning screen both do, at identical coordinates. The
                -- keyboard and exit-confirm screens don't draw a header
                -- at all, so painting there would drop a battery glyph on
                -- top of unrelated content.
                --
                -- UI_MODE_TAB is exactly the set of screens with a header
                -- and a nav bar, so it answers this question too rather
                -- than introducing a third list to keep in sync. The
                -- value above is updated regardless, so any screen is
                -- correct as soon as it's next drawn in full.
                if UI_MODE_TAB[ui_mode] then
                    ui.draw_battery_only(battery_percent)
                end
            end
        end

        -- --- periodic clock redraw ---
        -- The `not screen_locked` test is load-bearing, not just an
        -- optimisation. redraw() suppresses itself while locked and
        -- returns WITHOUT updating last_clock_redraw_ms -- so without
        -- this guard the condition below would stay true forever and
        -- fire on every single loop iteration (~500ms), spamming the log
        -- and burning CPU for the entire time the screen is locked,
        -- which is the exact opposite of what locking is for.
        if not screen_locked
            and (now_ms() - last_clock_redraw_ms) >= config.clock_redraw_interval_ms then
            redraw_if_dashboard("periodic clock tick")
            -- redraw() stamps last_clock_redraw_ms, but only on a draw
            -- that actually happened -- and redraw_if_dashboard draws
            -- nothing while the keyboard or exit-confirm screen is up.
            -- So the deadline can still be in the past here, and must be
            -- pushed forward by hand or it stays permanently overdue.
            -- Harmless on the old flat 500ms tick (it just re-checked and
            -- did nothing); with compute_poll_timeout() now sleeping
            -- until the nearest deadline, an overdue one that never
            -- advances would pin every wait to the floor for as long as
            -- that screen is up. See compute_poll_timeout's doc comment.
            if (now_ms() - last_clock_redraw_ms) >= config.clock_redraw_interval_ms then
                last_clock_redraw_ms = now_ms()
            end
        end

        -- --- idle auto-lock ---
        -- Same destination as a power-button press: blank + "Locked",
        -- timers suspended, press power to come back. Deliberately runs
        -- on every screen, not just the dashboard -- an Add Task keyboard
        -- left untouched for a quarter of an hour is exactly as idle as a
        -- task list, and unlocking restores it with its typed buffer
        -- intact (see set_screen_locked's doc comment).
        --
        -- The `not screen_locked` guard is what stops this re-firing: a
        -- locked screen leaves last_input_ms alone, so the condition
        -- stays true for the whole locked period.
        if AUTO_LOCK_IDLE_MS and not screen_locked
            and (now_ms() - last_input_ms) >= AUTO_LOCK_IDLE_MS then
            -- Stamped BEFORE the attempt, not after a success. If
            -- blanking fails, set_screen_locked deliberately stays
            -- unlocked (see its comment) -- without this, the condition
            -- would still be true on the very next iteration and the
            -- daemon would retry, and log the failure, at the floor
            -- interval forever. Restarting the idle window instead means
            -- a failed auto-lock is retried once every idle period.
            last_input_ms = now_ms()
            set_screen_locked(true, string.format("idle for %d min",
                math.floor(AUTO_LOCK_IDLE_MS / 60000)))
        end
    end)

    if not ok then
        log.error("main loop iteration raised an error (continuing): " .. tostring(err))
    end
end
