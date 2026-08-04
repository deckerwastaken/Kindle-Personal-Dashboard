--[[
tap_test.lua -- exercises src/touch.lua's actual tap-detection logic
(the same code path daemon.lua uses), as opposed to evtest.lua's raw
(type, code, value) dump. Use this specifically to confirm "one physical
tap produces exactly one detected tap" -- useful after any change to
touch.lua's feed() logic, or when bringing up a new touch panel that
mixes type-A/type-B signals (see touch.lua's header comment for the
2026-08-02 finding on this device that made this tool worth having).

Reads swap_xy/invert_x/invert_y/touch_device_path from config.lua if
present, same as the real daemon would.

Usage:
    /mnt/us/koreader/luajit tap_test.lua
]]

package.path = package.path .. ";" .. (arg[0]:match("(.*/)") or "./") .. "../src/?.lua"

io.stdout:setvbuf("line")

local posix = require("posix")
local touch = require("touch")

print("Stopping KOReader/Xorg so this test matches what the real daemon sees...")
os.execute("killall -q -s KILL reader.lua 2>/dev/null")
os.execute("killall -q -s KILL Xorg 2>/dev/null")

local ok, config = pcall(require, "config")
if not ok then config = {} end

local device_path = config.touch_device_path
if not device_path then
    local best = touch.autodetect_device(nil)
    if not best then
        print("Could not auto-detect a touch device. Set touch_device_path in config.lua.")
        os.exit(1)
    end
    device_path = best
end

local reader, err = touch.open(device_path, nil, {
    swap_xy = config.touch_swap_xy,
    invert_x = config.touch_invert_x,
    invert_y = config.touch_invert_y,
    screen_w = config.screen_w,
    screen_h = config.screen_h,
})
if not reader then
    print("Could not open touch reader: " .. tostring(err))
    os.exit(1)
end

print("Using: " .. device_path)
print("Reading via touch.lua's tap detection. Tap the screen. Ctrl-C to stop.")

local tap_count = 0
while true do
    local bytes = posix.read_available(reader.fd)
    if bytes == nil then
        print("read error, exiting")
        break
    elseif bytes ~= "" then
        local taps = reader:feed(bytes)
        for _, t in ipairs(taps) do
            tap_count = tap_count + 1
            print(string.format("TAP #%d at (x=%d, y=%d)", tap_count, t.x, t.y))
        end
    else
        os.execute("sleep 0.05")
    end
end
