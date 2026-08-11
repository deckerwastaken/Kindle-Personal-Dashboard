--[[
keys.lua -- reads hardware BUTTON presses (currently just the power
button) from an evdev node, the way touch.lua reads the touchscreen.

Deliberately a separate module from touch.lua rather than another mode
inside it: touch.lua's whole job is turning a stream of absolute
coordinates into taps and swipes, and none of that applies to a key that
only ever reports "down" and "up". Sharing the file would mean one
module with two unrelated state machines in it.

CONFIRMED ON HARDWARE (2026-08-11, Kindle 7 / KT2, this device):

  - The power button is the PMIC's on-key: /proc/bus/input/devices lists
    it as N: Name="max77696-onkey" on /dev/input/event0, with a KEY
    bitmap of `100000 0 0 0` -- bit 20 of word 3, i.e. key code 116,
    KEY_POWER.
  - Pressing it emits exactly the textbook sequence and nothing else:
        EV_KEY KEY_POWER value=1   (press)
        EV_SYN SYN_REPORT
        EV_KEY KEY_POWER value=0   (release)
        EV_SYN SYN_REPORT
    No key repeat, no bounce, no phantom events. Verified by capturing
    raw bytes off the node with `cat` and decoding them.
  - Nothing else on the device claims it while the dashboard is running.
    `powerd` is still alive (bin/run.sh stops framework/kb/x only), but
    it does NOT suspend the device or otherwise react -- confirmed by
    watching /proc/uptime across presses for a time jump (none) and by
    the user watching the screen (no change). No process holds the node
    open, so there is no exclusive grab to fight either.

    This matters because it is NOT the situation on the touch panel,
    where Xorg does hold an exclusive grab and has to be stopped first
    (see kindle-daemon/README.md). The power button needs no such
    handling.
]]

local posix = require("posix")

local M = {}

-- Linux input event constants (stable kernel ABI).
local EV_KEY = 0x01
M.KEY_POWER = 116

--- Auto-detect the node carrying the power button.
---
--- Primary test is the CAPABILITY bitmap, not the device name: a node
--- that advertises KEY_POWER is the power button, whatever the vendor
--- called it. Name matching is kept only as a fallback for a device
--- whose /proc entry omits or mangles the bitmap, since names vary
--- wildly across Kindle generations ("max77696-onkey" here, but
--- "gpio-keys" and "mxckpd" appear on other models).
---
--- /proc/bus/input/devices prints the KEY bitmap as space-separated hex
--- words, MOST significant first, e.g.:
---     B: KEY=100000 0 0 0
--- Key code 116 lives in bit 116%32 = 20 of word 116/32 = 3 (counting
--- words from the least significant end), which in that printed order is
--- the FIRST word here -- 0x100000, i.e. exactly bit 20. That example is
--- this device's real line.
function M.autodetect_device(log)
    local f = io.open("/proc/bus/input/devices", "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()

    local by_capability, by_name = nil, nil
    local candidates = {}

    for block in (text .. "\n\n"):gmatch("(.-)\n\n") do
        local name = block:match('N:%s*Name="([^"]*)"')
        local handlers = block:match("H:%s*Handlers=([^\n]*)")
        local keybits = block:match("B:%s*KEY=([^\n]*)")
        local eventnum = handlers and handlers:match("event(%d+)")

        if name and eventnum then
            local path = "/dev/input/event" .. eventnum
            local has_power = false

            if keybits then
                -- Split into words, then index from the least-significant
                -- end so the arithmetic below doesn't depend on how many
                -- words the kernel happened to print.
                local words = {}
                for w in keybits:gmatch("%x+") do words[#words + 1] = w end
                local target_word = math.floor(M.KEY_POWER / 32)   -- 3
                local target_bit = M.KEY_POWER % 32                 -- 20
                local idx = #words - target_word
                if idx >= 1 then
                    local value = tonumber(words[idx], 16)
                    if value then
                        -- 2^20 rather than a bit-library shift: the value
                        -- fits comfortably in a double, and this avoids
                        -- depending on `bit` being present.
                        if math.floor(value / (2 ^ target_bit)) % 2 == 1 then
                            has_power = true
                        end
                    end
                end
            end

            candidates[#candidates + 1] = { name = name, path = path, has_power = has_power }
            if has_power and not by_capability then
                by_capability = path
            end
            if not by_name then
                local lname = name:lower()
                if lname:find("onkey", 1, true) or lname:find("power", 1, true)
                    or lname:find("gpio-keys", 1, true) then
                    by_name = path
                end
            end
        end
    end

    local chosen = by_capability or by_name
    if log then
        log.info("keys: scanning /proc/bus/input/devices for a power button:")
        for _, c in ipairs(candidates) do
            log.info(string.format("  %s name=%q%s%s", c.path, c.name,
                c.has_power and "  [advertises KEY_POWER]" or "",
                (c.path == chosen) and "  <-- selected" or ""))
        end
        if not chosen then
            log.warn("keys: no power-button device found. Screen lock via the " ..
                "power button will be unavailable; everything else works as normal. " ..
                "Set power_key_device_path in config.lua to force one.")
        elseif not by_capability then
            log.warn("keys: no device advertised KEY_POWER; falling back to a " ..
                "name match on " .. chosen .. ". If the power button doesn't " ..
                "toggle the lock, this guess is the first thing to check.")
        end
    end
    return chosen
end

--- Open a key device. Returns an object with :fd and
--- :feed(bytes) -> array of { code = <key code>, value = "press"|"release" },
--- or nil + message.
---
--- Key repeat (evdev value 2, emitted by some drivers while a key is
--- held) is dropped: every caller here wants discrete presses, and a
--- held button should never read as dozens of them. This device doesn't
--- emit repeats at all, but a different one might.
function M.open(device_path, log)
    local fd, err = posix.open_ro_nonblock(device_path)
    if not fd then
        return nil, "could not open " .. device_path .. ": errno " .. tostring(err)
    end

    local self = { fd = fd, path = device_path }

    function self:feed(raw_bytes)
        local out = {}
        local events = posix.parse_input_events(raw_bytes)
        for _, ev in ipairs(events) do
            if ev.type == EV_KEY then
                if ev.value == 1 then
                    out[#out + 1] = { code = ev.code, value = "press" }
                elseif ev.value == 0 then
                    out[#out + 1] = { code = ev.code, value = "release" }
                end
            end
        end
        return out
    end

    function self:close()
        posix.close(self.fd)
    end

    if log then log.info("keys: opened " .. device_path) end
    return self
end

return M
