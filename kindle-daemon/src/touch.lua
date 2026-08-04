--[[
touch.lua -- finds the touchscreen's /dev/input/eventX node and turns the
raw event stream into simple "tap at (x, y)" callbacks.

CONFIRMED ON HARDWARE (2026-08-02): this device's panel (zforce2, Kindle 7
2014 / KT2, infrared/Neonode zForce-style) sends "type B" multitouch
events -- EV_ABS ABS_MT_POSITION_X/Y (codes 53/54) + ABS_MT_TRACKING_ID
(code 57) going to -1 on release, committed on EV_SYN SYN_REPORT -- but
ALSO fires EV_KEY BTN_TOUCH (the "type A" signal) for the exact same
release, in the same event burst. This module still handles both styles
(useful if this code ever runs against a different panel), but resolves
"was a release seen" exactly once per SYN_REPORT rather than acting the
instant either signal arrives, specifically so this hybrid device doesn't
get double-counted as two taps per physical tap. If you're bringing up a
new/different panel, still run `tools/evtest.lua` by hand over SSH first
(see INSTALL.md step 3) and compare its raw dump against this -- don't
assume every zforce2-name panel necessarily behaves identically.

Device auto-detection reads /proc/bus/input/devices (plain text, no FFI
needed) looking for a device whose Name line contains a touch-ish keyword,
and picks the eventN handler listed for it. You can always override this
by setting `touch_device_path` explicitly in config.lua if auto-detect
guesses wrong (it will list every candidate it saw in the log either way).
]]

local posix = require("posix")

local M = {}

-- Linux input event type/code constants we need (stable kernel ABI,
-- from <linux/input-event-codes.h> -- these numbers do not change).
local EV_SYN = 0x00
local EV_KEY = 0x01
local EV_ABS = 0x03

local SYN_REPORT = 0

local BTN_TOUCH = 0x14a

local ABS_X = 0x00
local ABS_Y = 0x01
local ABS_MT_POSITION_X = 0x35
local ABS_MT_POSITION_Y = 0x36
local ABS_MT_TRACKING_ID = 0x39

--- Scan /proc/bus/input/devices for a plausible touchscreen node.
--- Returns path (e.g. "/dev/input/event2") or nil, plus a list of all
--- candidates seen (for logging).
function M.autodetect_device(log)
    local f = io.open("/proc/bus/input/devices", "r")
    if not f then
        return nil, {}
    end
    local text = f:read("*a")
    f:close()

    local keywords = { "touch", "zforce", "atmel", "melfas", "synaptics" }
    local candidates = {}
    local best = nil

    -- /proc/bus/input/devices lists devices as blocks separated by blank
    -- lines, each with lines like:
    --   N: Name="something"
    --   H: Handlers=kbd eventN mouse0
    for block in text:gmatch("(.-)\n\n") do
        local name = block:match('N:%s*Name="([^"]*)"')
        local handlers = block:match("H:%s*Handlers=([^\n]*)")
        if name and handlers then
            local eventnum = handlers:match("event(%d+)")
            if eventnum then
                candidates[#candidates + 1] = { name = name, event = eventnum }
                local lname = name:lower()
                if not best then
                    for _, kw in ipairs(keywords) do
                        if lname:find(kw, 1, true) then
                            best = "/dev/input/event" .. eventnum
                            break
                        end
                    end
                end
            end
        end
    end

    if log then
        log.info("touch: candidates found in /proc/bus/input/devices:")
        for _, c in ipairs(candidates) do
            log.info("  event" .. c.event .. ' name="' .. c.name .. '"' ..
                      (("/dev/input/event" .. c.event == best) and "  <-- selected" or ""))
        end
    end

    return best, candidates
end

--- Create a touch reader on the given device path. Returns an object
--- with :fd, :feed(bytes) -> array of {x=,y=} tap events (called once
--- per completed down->up gesture).
---
--- `transform` (optional) handles the other common hardware unknown
--- besides the type-A/type-B protocol question: some e-ink touch
--- controllers are wired up in a different orientation than the screen
--- (e.g. a panel that's physically landscape-native reporting raw
--- coordinates that need a swap and/or flip to line up with a portrait
--- 600x800 UI). This is NOT confirmed either way for this device -- if
--- taps in tools/evtest.lua look like they're at the wrong end of an
--- axis, or with X/Y swapped, compared to where you actually tapped, set
--- swap_xy / invert_x / invert_y here (surfaced via config.lua) rather
--- than editing ui.lua's layout math.
--- transform = { swap_xy = bool, invert_x = bool, invert_y = bool,
---               screen_w = 600, screen_h = 800 }
function M.open(device_path, log, transform)
    local fd, err = posix.open_ro_nonblock(device_path)
    if not fd then
        return nil, "could not open " .. device_path .. ": errno " .. tostring(err)
    end

    transform = transform or {}
    local screen_w = transform.screen_w or 600
    local screen_h = transform.screen_h or 800

    local function apply_transform(x, y)
        if transform.swap_xy then
            x, y = y, x
        end
        if transform.invert_x then x = screen_w - 1 - x end
        if transform.invert_y then y = screen_h - 1 - y end
        return x, y
    end

    local self = {
        fd = fd,
        path = device_path,
        _down = false,
        _x = nil,
        _y = nil,
        _next_x = nil,
        _next_y = nil,
        _mt_tracking_active = false,
        -- CONFIRMED gap, fixed 2026-08-02: must survive across separate
        -- :feed() calls, not just within one -- see the comment at its
        -- use site below.
        _release_seen = false,
    }

    function self:feed(raw_bytes)
        local taps = {}
        local events, leftover = posix.parse_input_events(raw_bytes)
        self._pending_leftover = leftover -- currently unused across reads;
                                            -- see note in daemon.lua about
                                            -- reads always landing on
                                            -- event boundaries in practice

        -- CONFIRMED ON HARDWARE (2026-08-02, Kindle 7/KT2 zforce2 panel):
        -- this device sends BOTH type-A (BTN_TOUCH) and type-B
        -- (ABS_MT_TRACKING_ID) release signals for the SAME physical
        -- release, in the same event burst before one shared SYN_REPORT.
        -- Deciding "tap complete" immediately at whichever signal arrives
        -- first (the old behavior) double-counted every tap. Instead,
        -- just latch a single release_seen flag from either signal and
        -- resolve it exactly once, at the SYN_REPORT that follows -- this
        -- is also just the standard evdev convention (nothing is final
        -- until SYN_REPORT commits it), so it stays correct for
        -- pure type-A-only or pure type-B-only panels too.
        --
        -- CONFIRMED gap, fixed 2026-08-02: this was originally a local
        -- variable, reset to false at the top of every :feed() call. That
        -- silently loses the signal if a tap's release edge and its
        -- concluding SYN_REPORT ever land in two separate read()/:feed()
        -- calls (plausible under scheduling jitter even though a single
        -- gesture's event burst is normally small) -- the tap would be
        -- dropped entirely rather than double-counted. Using self._release_seen
        -- instead makes it survive across calls, matching how
        -- self._down/self._mt_tracking_active are already handled.

        for _, ev in ipairs(events) do
            if ev.type == EV_ABS then
                if ev.code == ABS_X or ev.code == ABS_MT_POSITION_X then
                    self._next_x = ev.value
                elseif ev.code == ABS_Y or ev.code == ABS_MT_POSITION_Y then
                    self._next_y = ev.value
                elseif ev.code == ABS_MT_TRACKING_ID then
                    if ev.value == -1 then
                        if self._mt_tracking_active then
                            self._release_seen = true
                        end
                        self._mt_tracking_active = false
                    else
                        self._mt_tracking_active = true
                    end
                end
            elseif ev.type == EV_KEY and ev.code == BTN_TOUCH then
                if ev.value == 1 then
                    self._down = true
                elseif ev.value == 0 then
                    if self._down then
                        self._release_seen = true
                    end
                    self._down = false
                end
            elseif ev.type == EV_SYN and ev.code == SYN_REPORT then
                if self._next_x then self._x = self._next_x end
                if self._next_y then self._y = self._next_y end
                self._next_x, self._next_y = nil, nil

                if self._release_seen and self._x and self._y then
                    local tx, ty = apply_transform(self._x, self._y)
                    taps[#taps + 1] = { x = tx, y = ty }
                end
                self._release_seen = false
            end
        end
        return taps
    end

    function self:close()
        posix.close(self.fd)
    end

    if log then
        log.info("touch: opened " .. device_path)
    end
    return self
end

return M
