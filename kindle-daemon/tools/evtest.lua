--[[
evtest.lua -- standalone raw touch-event dumper for manual testing.

Run this BY HAND over SSH/USB before ever trusting src/touch.lua's
interpretation of your touchscreen. It does the minimum possible: finds
(or lets you specify) a /dev/input/eventN device, and prints every raw
(type, code, value) tuple it reads, forever, until you Ctrl-C it.

This is step 3 of kindle-daemon/INSTALL.md. What you're looking for:
  - Tap the screen once, firmly, in one spot. You should see a burst of
    lines print.
  - If you see EV_ABS with code 0 (ABS_X) and code 1 (ABS_Y), plus EV_KEY
    code 330 (BTN_TOUCH) going 1 then 0 -- that's the "type A" protocol,
    and src/touch.lua's ABS_X/ABS_Y + BTN_TOUCH path applies.
  - If instead you see EV_ABS with code 53 (ABS_MT_POSITION_X), code 54
    (ABS_MT_POSITION_Y), and code 57 (ABS_MT_TRACKING_ID) going from some
    number to -1 -- that's "type B" multitouch, and src/touch.lua's
    ABS_MT_* path applies.
  - If you see neither, or different codes entirely, copy the raw output
    here and treat src/touch.lua as needing adjustment before relying on
    it -- don't guess further, the numbers don't lie.
  - SEPARATELY, also check orientation: tap each of the four corners of
    the screen in turn and note the X/Y values printed for each. If
    tapping the top-left corner gives you a LOW X and LOW Y (and
    top-right gives HIGH X, LOW Y, etc, matching a normal 600x800
    portrait layout), you're fine. If X and Y look swapped, or either
    axis counts down instead of up as you move right/down, set
    touch_swap_xy / touch_invert_x / touch_invert_y in config.lua
    accordingly -- see src/touch.lua's M.open() doc comment.

Usage:
    /mnt/us/koreader/luajit evtest.lua                # auto-detect
    /mnt/us/koreader/luajit evtest.lua /dev/input/event2   # explicit

CONFIRMED ON HARDWARE (2026-08-02): Xorg holds an exclusive grab on the
touch device the entire time it (and KOReader, running as its X client)
is running -- open() on /dev/input/eventN succeeds either way, but reads
silently never return a single byte while X is up, which looks identical
to "the panel isn't sending events at all" if you don't know to check for
this. See INSTALL.md step 3's troubleshooting note for how this was
diagnosed. This script kills reader.lua/Xorg itself before opening the
device (same thing run.sh does for the real daemon) so this test actually
matches what you'll see once the daemon is running -- expect KOReader's
UI to disappear from the screen the moment you run this. A normal reboot
brings it back; nothing here is persisted.
]]

package.path = package.path .. ";" .. (arg[0]:match("(.*/)") or "./") .. "../src/?.lua"

-- Force line buffering: when stdout isn't a TTY (redirected to a file or
-- piped), C stdio defaults to full block buffering, so print() output
-- can sit invisibly in userspace memory and be lost entirely if the
-- process is later killed with a signal that gives it no chance to flush
-- (e.g. SIGKILL). Line buffering makes every print() land on disk/pipe
-- immediately, regardless of how this script is invoked or stopped.
io.stdout:setvbuf("line")

local posix = require("posix")
local touch = require("touch")

print("Stopping KOReader/Xorg so this test matches what the real daemon sees...")
os.execute("killall -q -s KILL reader.lua 2>/dev/null")
os.execute("killall -q -s KILL Xorg 2>/dev/null")

local device_path = arg[1]

if not device_path then
    print("No device given -- scanning /proc/bus/input/devices ...")
    local best, candidates = touch.autodetect_device(nil)
    print(string.format("Found %d input device(s):", #candidates))
    for _, c in ipairs(candidates) do
        print(string.format('  /dev/input/event%s  name="%s"%s',
            c.event, c.name, ("/dev/input/event" .. c.event == best) and "  <-- guessed touchscreen" or ""))
    end
    if not best then
        print("Could not guess which one is the touchscreen. Re-run this")
        print("script with an explicit path, e.g.:")
        print("  luajit evtest.lua /dev/input/event1")
        os.exit(1)
    end
    device_path = best
    print("Using: " .. device_path .. "  (pass a path as an argument to override)")
end

local fd, err = posix.open_ro_nonblock(device_path)
if not fd then
    print("Could not open " .. device_path .. ": errno " .. tostring(err))
    print("(Common cause: wrong path, or not running as a user with permission --")
    print(" on a jailbroken Kindle over SSH you're normally root, which is fine.)")
    os.exit(1)
end

print("Reading from " .. device_path .. ". Tap the screen. Ctrl-C to stop.")
print(string.format("%-8s %-10s %-10s %-10s", "type", "code", "value", "(hex type/code)"))

local EVENT_NAMES = {
    [0x00] = "EV_SYN", [0x01] = "EV_KEY", [0x03] = "EV_ABS",
}

while true do
    local bytes = posix.read_available(fd)
    if bytes == nil then
        print("read error, exiting")
        break
    elseif bytes ~= "" then
        local events = posix.parse_input_events(bytes)
        for _, ev in ipairs(events) do
            local tname = EVENT_NAMES[ev.type] or ("type_" .. ev.type)
            print(string.format("%-8s %-10d %-10d (0x%02x / 0x%02x)",
                tname, ev.code, ev.value, ev.type, ev.code))
        end
    else
        os.execute("sleep 0.05")
    end
end
