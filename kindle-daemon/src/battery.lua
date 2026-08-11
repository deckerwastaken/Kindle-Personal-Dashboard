--[[
battery.lua -- reads the Kindle's battery charge percentage.

DEVICE NOTE, and it matters: this project targets the Kindle 7th gen
(2014, model WP63GW), whose codename is KT2 and whose PLATFORM is
"wario" (i.MX6SL SoC, MAX77696 PMIC). Amazon names the battery sysfs
node after the platform, not the model, so the correct primary path here
is .../wario_battery/... Two nearby names are easy to grab by mistake
and are wrong for this device:

  - yoshi_battery  -- the i.MX50 platform: Kindle 4, Kindle Touch,
                      Paperwhite 1. Structurally absent on KT2.
  - bd7181x_bat    -- the "zelda" platform, i.e. the Kindle 8th gen
                      (2016, SY69JL / KT3). Confusingly, KOReader calls
                      THAT device class "KindleBasic2" while ours is
                      "KindleBasic" -- so a search for "Kindle Basic 2
                      battery path" returns the wrong file for a Kindle
                      that is, in plain English, the second basic Kindle.

Both are kept in the probe chain below anyway: they cost one failed
io.open() each, once, at startup, and they make this module do something
sensible if it's ever run on one of those devices (see this project's
README on other Kindle models being plausible-but-untested).

STRATEGY: probe every known source ONCE at startup, cache whichever one
worked, and read only that one from then on. Re-walking the whole chain
on every poll would be wasteful, and worse, a single transient read error
on the good source would silently and permanently demote us to a worse
one with nothing recording that it happened.

Tiers 1-2 are sysfs reads (a plain file open, no process spawned) and are
what this device is expected to use. Tiers 3-4 shell out and are ranked
last for that reason -- on a single-core ARM this costs a fork+exec per
reading. They are still worth having: lipc talks to `powerd`, which
bin/run.sh deliberately leaves RUNNING (it stops framework/kb/x only), so
that path stays available even with the stock GUI torn down.

UNVERIFIED ON HARDWARE, flagged per this project's convention: which of
these paths actually exists on this specific firmware has not been
confirmed on the device. That is exactly why this is a probe chain with a
logged winner rather than a single hardcoded path -- and why
M.read() returns nil rather than a fallback number when everything fails,
so the UI can render an explicit "unknown" instead of a plausible lie.
tools/battery_probe.sh dumps the real state of all of these over SSH.
]]

local M = {}

M.debug_log = nil
M._source = nil -- the winning source, cached after probe()

--- Parse a battery reading out of whatever a source printed, and reject
--- anything that isn't a believable percentage.
---
--- This is deliberately stricter than "did the read succeed". Kindle gas
--- gauge drivers are documented to report -1 while the fuel gauge is
--- still calibrating (notably right after a cold boot or a battery
--- disconnect), and out-of-range values above 100 have been seen in the
--- wild. Both parse fine as numbers and would render as a confident,
--- wrong battery level.
---
--- The leading %s* / trailing-junk tolerance also covers the shell tiers,
--- where sibling flags of the same tool print units ("4204 mV",
--- "73 Fahrenheit") -- matching the digits rather than converting the
--- whole string means a source that starts emitting a unit suffix
--- degrades to "correct number" instead of "nil".
local function parse_percent(s)
    if type(s) ~= "string" then return nil end
    local n = tonumber(s:match("^%s*(%-?%d+)"))
    if not n or n < 0 or n > 100 then return nil end
    return n
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    return line
end

local function read_command(cmd)
    local fh = io.popen(cmd .. " 2>/dev/null")
    if not fh then return nil end
    local out = fh:read("*a")
    fh:close()
    return out
end

-- Ordered probe chain. Each entry: a human label for the log, and a
-- read() returning a raw string (or nil). Cheap file sources first.
local SOURCES = {
    {
        label = "sysfs wario_battery (Kindle 7/KT2 native)",
        cheap = true,
        read = function()
            return read_file("/sys/devices/system/wario_battery/wario_battery0/battery_capacity")
        end,
    },
    {
        label = "sysfs max77696-battery (wario power_supply class)",
        cheap = true,
        read = function()
            return read_file("/sys/class/power_supply/max77696-battery/capacity")
        end,
    },
    {
        label = "sysfs yoshi_battery (i.MX50 Kindles -- not expected here)",
        cheap = true,
        read = function()
            return read_file("/sys/devices/system/yoshi_battery/yoshi_battery0/battery_capacity")
        end,
    },
    {
        label = "sysfs bd7181x_bat (Kindle 8th gen/KT3 -- not expected here)",
        cheap = true,
        read = function()
            return read_file("/sys/class/power_supply/bd7181x_bat/capacity")
        end,
    },
    {
        label = "lipc-get-prop powerd battLevel",
        cheap = false,
        read = function()
            return read_command("lipc-get-prop com.lab126.powerd battLevel")
        end,
    },
    {
        label = "gasgauge-info -c",
        cheap = false,
        read = function()
            return read_command("gasgauge-info -c")
        end,
    },
}

--- Last-resort discovery: enumerate whatever the kernel actually exposes
--- under /sys/class/power_supply and try each one's `capacity`. Costs one
--- io.popen, once, and only if every hardcoded path above already failed.
---
--- This is the entry that makes the module have a real chance of working
--- on a Kindle model this project has never been run on, instead of
--- silently showing "--%" forever because the node is named after a
--- platform nobody added to the list above.
local function discover_power_supply_sources()
    local found = {}
    local listing = read_command("ls /sys/class/power_supply/")
    if not listing then return found end
    for name in listing:gmatch("[^%s]+") do
        local path = "/sys/class/power_supply/" .. name .. "/capacity"
        found[#found + 1] = {
            label = "sysfs discovered " .. path,
            cheap = true,
            read = function() return read_file(path) end,
        }
    end
    return found
end

--- Try every source in order, keep the first that yields a valid
--- percentage, and log the whole outcome once. Safe to call more than
--- once (re-probes from scratch); daemon.lua calls it at startup.
--- Returns the percentage found, or nil if no source worked.
function M.probe()
    local log = M.debug_log
    local candidates = {}
    for _, s in ipairs(SOURCES) do candidates[#candidates + 1] = s end

    for _, source in ipairs(candidates) do
        local ok, raw = pcall(source.read)
        local pct = ok and parse_percent(raw) or nil
        if pct then
            M._source = source
            if log then
                log.info(string.format("battery: using %s (reads %d%%)", source.label, pct))
            end
            return pct
        elseif log then
            log.info("battery: no usable reading from " .. source.label)
        end
    end

    for _, source in ipairs(discover_power_supply_sources()) do
        local ok, raw = pcall(source.read)
        local pct = ok and parse_percent(raw) or nil
        if pct then
            M._source = source
            if log then
                log.info(string.format("battery: using %s (reads %d%%)", source.label, pct))
            end
            return pct
        end
    end

    M._source = nil
    if log then
        log.warn("battery: no working battery source found -- the dashboard " ..
            "will show '--%' instead of a level. Run tools/battery_probe.sh " ..
            "over SSH to see what this device actually exposes, then add the " ..
            "working path to SOURCES in src/battery.lua.")
    end
    return nil
end

--- Current battery percentage (0-100), or nil if unknown.
---
--- Returns nil rather than a stale or default value on failure, on
--- purpose: the UI renders nil as an explicit "--%", and a visibly
--- unknown battery is much better than a plausible wrong one, which
--- never looks broken and so never gets investigated.
function M.read()
    if not M._source then return nil end
    local ok, raw = pcall(M._source.read)
    if not ok then return nil end
    return parse_percent(raw)
end

--- True if a working source was found at probe time. Only used for
--- logging/diagnostics -- M.read() returning nil is the signal callers
--- actually branch on.
function M.available()
    return M._source ~= nil
end

function M.init(log)
    M.debug_log = log
    return M.probe()
end

return M
