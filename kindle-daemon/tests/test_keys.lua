--[[
test_keys.lua -- offline tests for keys.lua: power-button event decoding
and power-button device auto-detection.

Runs on your LAPTOP:

    cd kindle-daemon/tests
    luajit test_keys.lua

WHAT'S ACTUALLY AT RISK HERE
----------------------------
Two things, and neither needs hardware to check:

1. The KEY-bitmap arithmetic in autodetect_device(). /proc/bus/input/
   devices prints capability bitmaps as hex words, MOST significant
   first, and finding key code 116 in that means indexing from the far
   end and testing bit 20 of word 3. That is exactly the sort of
   off-by-one nobody spots by reading, and getting it wrong means either
   silently picking the touchscreen as the "power button" or finding
   nothing at all. The fixture below is this device's REAL
   /proc/bus/input/devices content, captured on 2026-08-11.

2. Press/release decoding, including dropping key repeat.

What this canNOT check is whether the button is physically wired to the
node we picked, or whether some other process eats the events -- both
were verified on the device by capturing raw bytes (see keys.lua's
header for what was confirmed and how).
]]

local this_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."

-- keys.lua only needs posix for open/close/parse_input_events; stub them
-- so no Linux and no /dev/input node is required.
local fake_bursts = {}
package.loaded["posix"] = {
    open_ro_nonblock = function() return 9 end,
    close = function() end,
    parse_input_events = function(buf) return fake_bursts[buf] or {}, "" end,
}

local keys = dofile(this_dir .. "/../src/keys.lua")

local failures = 0
local function check(name, got, want)
    if got == want then
        print(string.format("  ok   %-52s %s", name, tostring(got)))
    else
        failures = failures + 1
        print(string.format("  FAIL %-52s got=%s want=%s", name, tostring(got), tostring(want)))
    end
end

-- ===================== auto-detection =====================
--
-- The real /proc/bus/input/devices from the Kindle 7 / KT2, verbatim.
local REAL_KT2_DEVICES = [[
I: Bus=0000 Vendor=0000 Product=0000 Version=0000
N: Name="max77696-onkey"
P: Phys=max77696-onkey/input0
S: Sysfs=/devices/platform/imx-i2c.0/i2c-0/0-003c/max77696-onkey.0/input/input0
U: Uniq=
H: Handlers=kbd event0
B: PROP=0
B: EV=3
B: KEY=100000 0 0 0

I: Bus=0000 Vendor=0000 Product=0000 Version=0000
N: Name="zforce2"
P: Phys=zforce2/input0
S: Sysfs=/devices/platform/zforce2.0/input/input1
U: Uniq=
H: Handlers=event1
B: PROP=0
B: EV=b
B: KEY=6420 0 0 0 0 0 0 0 0 0 0
B: ABS=2608000 0

]]

--- Redirect io.open so autodetect reads a fixture instead of /proc.
local real_io_open = io.open
local function with_devices(text, fn)
    io.open = function(path, mode)
        if path == "/proc/bus/input/devices" then
            local pos = 1
            return {
                read = function(_, what)
                    if pos > #text then return nil end
                    pos = #text + 1
                    return text
                end,
                close = function() end,
            }
        end
        return real_io_open(path, mode)
    end
    local ok, err = pcall(fn)
    io.open = real_io_open
    if not ok then error(err) end
end

print("=== auto-detection against this device's real /proc content ===")
with_devices(REAL_KT2_DEVICES, function()
    check("picks the PMIC on-key node", keys.autodetect_device(nil), "/dev/input/event0")
end)

print("\n=== the touchscreen must never be mistaken for the power button ===")
-- zforce2 advertises KEY=6420 (BTN_TOUCH etc.) but NOT KEY_POWER. If the
-- bitmap arithmetic were wrong, this is the device it would most likely
-- pick by accident -- and the daemon would then poll the touchscreen for
-- power presses while the real button did nothing.
with_devices([[
I: Bus=0000
N: Name="zforce2"
H: Handlers=event1
B: KEY=6420 0 0 0 0 0 0 0 0 0 0

]], function()
    check("touch-only device is not selected", keys.autodetect_device(nil), nil)
end)

print("\n=== bit arithmetic: only the exact KEY_POWER bit counts ===")
-- 0x100000 is bit 20 of word 3 == key 116. Neighbouring bits are keys
-- 115 and 117 (volume keys on other hardware) and must NOT match.
for _, c in ipairs({
    { "bit 20 of word 3 (key 116) matches", "100000 0 0 0", "/dev/input/event0" },
    { "bit 19 of word 3 (key 115) does not", "80000 0 0 0", nil },
    { "bit 21 of word 3 (key 117) does not", "200000 0 0 0", nil },
    { "same bit in the WRONG word does not", "0 0 0 100000", nil },
}) do
    with_devices(string.format([[
I: Bus=0000
N: Name="something-generic"
H: Handlers=event0
B: KEY=%s

]], c[2]), function()
        check(c[1], keys.autodetect_device(nil), c[3])
    end)
end

print("\n=== a device with several keys set still matches ===")
with_devices([[
I: Bus=0000
N: Name="gpio-keys"
H: Handlers=event3
B: KEY=100000 0 0 7

]], function()
    check("KEY_POWER among other keys", keys.autodetect_device(nil), "/dev/input/event3")
end)

print("\n=== name fallback when the bitmap is missing entirely ===")
with_devices([[
I: Bus=0000
N: Name="mxc-powerkey"
H: Handlers=event2

]], function()
    check("falls back to a name match", keys.autodetect_device(nil), "/dev/input/event2")
end)

print("\n=== no candidate at all ===")
with_devices([[
I: Bus=0000
N: Name="some-accelerometer"
H: Handlers=event4
B: KEY=0 0 0 0

]], function()
    check("returns nil rather than guessing", keys.autodetect_device(nil), nil)
end)

-- ===================== event decoding =====================

local EV_KEY, EV_SYN = 0x01, 0x00

local seq = 0
local function burst(evs)
    seq = seq + 1
    local k = "b" .. seq
    fake_bursts[k] = evs
    return k
end

print("\n=== press / release decoding ===")
do
    local r = keys.open("/dev/input/event0", nil)
    -- The exact sequence captured from the real device.
    local out = r:feed(burst({
        { type = EV_KEY, code = 116, value = 1 },
        { type = EV_SYN, code = 0, value = 0 },
        { type = EV_KEY, code = 116, value = 0 },
        { type = EV_SYN, code = 0, value = 0 },
    }))
    check("one press+release yields 2 key events", #out, 2)
    check("first is a press", out[1] and out[1].value, "press")
    check("second is a release", out[2] and out[2].value, "release")
    check("code is KEY_POWER", out[1] and out[1].code, keys.KEY_POWER)
    check("KEY_POWER constant is 116", keys.KEY_POWER, 116)
end

print("\n=== key repeat is dropped ===")
-- This device doesn't emit repeats, but another might. The daemon
-- toggles the lock on every release, so a held button that repeated
-- would otherwise flip the screen on and off many times.
do
    local r = keys.open("/dev/input/event0", nil)
    local out = r:feed(burst({
        { type = EV_KEY, code = 116, value = 1 },
        { type = EV_KEY, code = 116, value = 2 },
        { type = EV_KEY, code = 116, value = 2 },
        { type = EV_KEY, code = 116, value = 2 },
        { type = EV_KEY, code = 116, value = 0 },
    }))
    check("3 repeats between press and release are ignored", #out, 2)
    check("  still a press...", out[1] and out[1].value, "press")
    check("  ...then a release", out[2] and out[2].value, "release")
end

print("\n=== non-key events are ignored ===")
do
    local r = keys.open("/dev/input/event0", nil)
    local out = r:feed(burst({
        { type = EV_SYN, code = 0, value = 0 },
        { type = 0x03, code = 0x35, value = 300 }, -- an EV_ABS, as touch sends
        { type = EV_SYN, code = 0, value = 0 },
    }))
    check("SYN and ABS produce nothing", #out, 0)
end

print("\n=== a release split into a separate read still decodes ===")
do
    local r = keys.open("/dev/input/event0", nil)
    local a = r:feed(burst({ { type = EV_KEY, code = 116, value = 1 } }))
    local b = r:feed(burst({ { type = EV_KEY, code = 116, value = 0 } }))
    check("press arrives in read 1", a[1] and a[1].value, "press")
    check("release arrives in read 2", b[1] and b[1].value, "release")
end

print("\n=== toggle semantics: releases flip the lock, presses don't ===")
-- Mirrors the daemon's rule (act on release only). Two full presses must
-- return to the original state, or the button would desync from reality.
do
    local r = keys.open("/dev/input/event0", nil)
    local locked = false
    local evs = {}
    for _ = 1, 2 do
        evs[#evs + 1] = { type = EV_KEY, code = 116, value = 1 }
        evs[#evs + 1] = { type = EV_KEY, code = 116, value = 0 }
    end
    for _, e in ipairs(r:feed(burst(evs))) do
        if e.code == keys.KEY_POWER and e.value == "release" then locked = not locked end
    end
    check("two press+release cycles return to unlocked", locked, false)

    local r2 = keys.open("/dev/input/event0", nil)
    local locked2 = false
    for _, e in ipairs(r2:feed(burst({
        { type = EV_KEY, code = 116, value = 1 },
        { type = EV_KEY, code = 116, value = 0 },
    }))) do
        if e.code == keys.KEY_POWER and e.value == "release" then locked2 = not locked2 end
    end
    check("one press+release locks exactly once", locked2, true)
end

print("")
if failures == 0 then
    print("ALL CHECKS PASSED")
else
    print(failures .. " CHECK(S) FAILED")
    os.exit(1)
end
