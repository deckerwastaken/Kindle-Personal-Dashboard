--[[
test_gestures.lua -- offline unit test for touch.lua's gesture
classification (tap vs. swipe vs. inert drag).

Runs on your LAPTOP, not on the Kindle:

    cd kindle-daemon/tests
    luajit test_gestures.lua

Exits non-zero if anything fails, so it can be wired into a pre-commit
check later if that's ever wanted.

WHY THIS EXISTS, and what it does and does NOT prove
----------------------------------------------------
Everything else in kindle-daemon/tools/ is an ON-DEVICE diagnostic: you
run it over SSH and eyeball real hardware behaviour. Those are the right
tool for the questions this project's comments repeatedly flag as
genuinely unverifiable off-device (does the panel really report these
event codes, is struct input_event really 16 bytes here, where does FBInk
actually put a glyph).

Gesture classification is a different kind of question. Given a stream of
already-decoded events, "is this a tap or a leftward swipe" is pure
arithmetic with no hardware in it -- so it can be tested properly, and a
bug in it is otherwise only discoverable by standing in front of the
device swiping and squinting at a log.

This test stubs out posix.parse_input_events and feeds touch.lua
synthetic event bursts shaped the way this device's panel really behaves
(hybrid type-A BTN_TOUCH *and* type-B ABS_MT_TRACKING_ID for the same
physical touch, per touch.lua's header comment).

So: this proves the classification logic given correctly-decoded events.
It CANNOT prove that SWIPE_MIN_PX/SWIPE_AXIS_RATIO are comfortable values
for a real thumb on a real infrared panel -- use tools/tap_test.lua on the
device for that.
]]

-- Resolve src/ relative to this file, so the test runs from any cwd.
local this_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local src_dir = this_dir .. "/../src/"

-- ===================== fake posix =====================
-- touch.lua only uses posix for open/close/parse_input_events. We hand it
-- a stub so no /dev/input node (or Linux) is needed. Our "raw bytes" are
-- just a string key into a table of pre-decoded event lists.
local fake_bursts = {}
package.loaded["posix"] = {
    open_ro_nonblock = function() return 7 end,
    close = function() end,
    parse_input_events = function(buf)
        return fake_bursts[buf] or {}, ""
    end,
}

local touch = dofile(src_dir .. "touch.lua")

local EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
local SYN_REPORT = 0
local BTN_TOUCH = 0x14a
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
local ABS_MT_TRACKING_ID = 0x39

local burst_seq = 0
local function burst(events)
    burst_seq = burst_seq + 1
    local key = "burst" .. burst_seq
    fake_bursts[key] = events
    return key
end

--- One complete down -> (optional movement) -> up gesture, in the hybrid
--- type-A + type-B style this panel actually emits.
local function gesture_bytes(x1, y1, x2, y2)
    local evs = {}
    local function e(t, c, v) evs[#evs + 1] = { type = t, code = c, value = v } end
    e(EV_ABS, ABS_MT_TRACKING_ID, 100)
    e(EV_KEY, BTN_TOUCH, 1)
    e(EV_ABS, ABS_MT_POSITION_X, x1)
    e(EV_ABS, ABS_MT_POSITION_Y, y1)
    e(EV_SYN, SYN_REPORT, 0)
    for i = 1, 3 do -- intermediate movement samples
        e(EV_ABS, ABS_MT_POSITION_X, math.floor(x1 + (x2 - x1) * i / 4))
        e(EV_ABS, ABS_MT_POSITION_Y, math.floor(y1 + (y2 - y1) * i / 4))
        e(EV_SYN, SYN_REPORT, 0)
    end
    e(EV_ABS, ABS_MT_POSITION_X, x2)
    e(EV_ABS, ABS_MT_POSITION_Y, y2)
    e(EV_ABS, ABS_MT_TRACKING_ID, -1)
    e(EV_KEY, BTN_TOUCH, 0)
    e(EV_SYN, SYN_REPORT, 0)
    return burst(evs)
end

-- ===================== tiny test harness =====================
local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("  FAIL %-46s got=%-14s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("  ok   %-46s %s", name, tostring(got)))
    end
end

local function one(x1, y1, x2, y2, transform)
    local reader = touch.open("/dev/input/event0", nil, transform)
    return reader:feed(gesture_bytes(x1, y1, x2, y2))
end

-- ===================== the tests =====================

print("=== exactly one gesture per physical touch ===")
-- Guards the bug touch.lua's header documents: this panel signals every
-- release TWICE (BTN_TOUCH and ABS_MT_TRACKING_ID), which used to
-- double-count as two taps.
do
    local gs = one(300, 400, 300, 400)
    check("tap emits 1 gesture, not 2", #gs, 1)
    check("  kind", gs[1] and gs[1].kind, "tap")
end

print("\n=== small movement stays a tap ===")
for _, c in ipairs({
    { "dead-still tap", 300, 400, 300, 400 },
    { "5px panel jitter", 300, 400, 305, 402 },
    { "40px finger slop", 300, 400, 340, 400 },
    { "59px, just under threshold", 300, 400, 359, 400 },
}) do
    check(c[1], one(c[2], c[3], c[4], c[5])[1].kind, "tap")
end

print("\n=== horizontal swipes ===")
for _, c in ipairs({
    { "swipe left 200px", 450, 400, 250, 400, "left" },
    { "swipe right 200px", 150, 400, 350, 400, "right" },
    { "swipe left exactly at threshold", 300, 400, 240, 400, "left" },
    { "swipe right w/ 30px vertical drift", 150, 400, 350, 430, "right" },
}) do
    local g = one(c[2], c[3], c[4], c[5])[1]
    check(c[1] .. " kind", g and g.kind, "swipe")
    check(c[1] .. " dir", g and g.dir, c[6])
end

print("\n=== vertical swipes are classified, not mistaken for taps ===")
-- The regression this prevents: a vertical drag across the task list used
-- to land as a tap wherever the finger came up, silently toggling or
-- arming deletion on whatever row that was.
for _, c in ipairs({
    { "swipe up 150px", 300, 500, 300, 350, "up" },
    { "swipe down 150px", 300, 300, 300, 450, "down" },
}) do
    local g = one(c[2], c[3], c[4], c[5])[1]
    check(c[1] .. " kind", g and g.kind, "swipe")
    check(c[1] .. " dir", g and g.dir, c[6])
end

print("\n=== ambiguous diagonal -> inert 'drag' ===")
check("45-degree 150px smear", one(200, 300, 350, 450)[1].kind, "drag")

print("\n=== start/end coordinates ===")
do
    local g = one(450, 300, 250, 310)[1]
    check("start_x is the press point", g.start_x, 450)
    check("start_y is the press point", g.start_y, 300)
    check("x is the release point", g.x, 250)
    check("y is the release point", g.y, 310)
end

print("\n=== direction is computed AFTER the screen transform ===")
-- config.lua's swap_xy/invert_x/invert_y exist because this panel's axes
-- may not match the screen's. A swipe classified in raw panel space would
-- report a direction mirrored or rotated from the one the user's finger
-- actually traced.
do
    local g = one(150, 400, 350, 400, { invert_x = true, screen_w = 600, screen_h = 800 })[1]
    check("physical right + invert_x reads as left", g.dir, "left")
    local g2 = one(400, 150, 400, 350, { swap_xy = true, screen_w = 600, screen_h = 800 })[1]
    check("vertical travel + swap_xy reads horizontal", g2.dir, "right")
end

print("\n=== consecutive gestures on one reader ===")
-- Guards against a stale press point leaking from one gesture into the
-- next, which would collapse every gesture after the first into a tap.
do
    local reader = touch.open("/dev/input/event0", nil, nil)
    local a = reader:feed(gesture_bytes(450, 400, 250, 400))
    local b = reader:feed(gesture_bytes(300, 400, 300, 400))
    local c = reader:feed(gesture_bytes(150, 400, 350, 400))
    check("1st is swipe left", a[1].kind .. " " .. tostring(a[1].dir), "swipe left")
    check("2nd is a tap, start point not stale", b[1].kind, "tap")
    check("3rd is swipe right", c[1].kind .. " " .. tostring(c[1].dir), "swipe right")
end

print("\n=== gesture split across two feed() calls ===")
-- touch.lua's header notes a gesture's bursts can land in separate
-- read()s under scheduling jitter; the press point must survive that.
do
    local reader = touch.open("/dev/input/event0", nil, nil)
    local press = burst({
        { type = EV_ABS, code = ABS_MT_TRACKING_ID, value = 100 },
        { type = EV_KEY, code = BTN_TOUCH, value = 1 },
        { type = EV_ABS, code = ABS_MT_POSITION_X, value = 450 },
        { type = EV_ABS, code = ABS_MT_POSITION_Y, value = 400 },
        { type = EV_SYN, code = SYN_REPORT, value = 0 },
    })
    local release = burst({
        { type = EV_ABS, code = ABS_MT_POSITION_X, value = 250 },
        { type = EV_ABS, code = ABS_MT_POSITION_Y, value = 400 },
        { type = EV_ABS, code = ABS_MT_TRACKING_ID, value = -1 },
        { type = EV_KEY, code = BTN_TOUCH, value = 0 },
        { type = EV_SYN, code = SYN_REPORT, value = 0 },
    })
    check("press burst alone emits nothing", #reader:feed(press), 0)
    local g = reader:feed(release)[1]
    check("release burst completes the swipe", g.kind .. " " .. tostring(g.dir), "swipe left")
end

print("")
if failures == 0 then
    print("ALL CHECKS PASSED")
else
    print(failures .. " CHECK(S) FAILED")
    os.exit(1)
end
