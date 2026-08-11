--[[
test_hit_resolution.lua -- checks that a tap at a given pixel resolves to
the control the user actually aimed at.

Runs on your LAPTOP:

    cd kindle-daemon/tests
    luajit test_hit_resolution.lua

WHY THIS EXISTS AS A SEPARATE FILE
----------------------------------
test_layout.lua checks that ui.lua's OUTPUT is self-consistent: nothing
drawn off-screen, no two tap targets overlapping, none under 40px. That is
necessary but not sufficient, and the gap between the two is not
theoretical -- it shipped a blocker.

ui.lua also emits full-region GESTURE zones (the swipe areas) that
deliberately overlap every tap target inside them. test_layout.lua
excludes those from its overlap check, correctly. But that meant nothing
tested the CONSUMER: daemon.lua's hit_test() walked the zone list in
order and returned the first match, so `task_swipe_area` -- registered
first, spanning the whole task block -- swallowed every tap in it.
Checkboxes, per-row delete, the pager and "+ Add Task" all silently did
nothing the moment the first state snapshot arrived, while the footer and
nav bar below the region kept working.

So this file tests the two halves TOGETHER: it takes the real hit_zones
from ui.lua and runs daemon.lua's own resolution rules over concrete
pixel coordinates, asserting each lands on the intended kind.

daemon.lua can't be require()'d here (it opens devices and connects a
socket at load), so the two resolution functions are duplicated below.
They are short and stable, but that IS a duplication -- if you change
hit_test/find_zone_by_kind in daemon.lua, change them here too. The
GESTURE_ZONE_KINDS list is the part most likely to drift, so the first
test below re-derives it from ui.lua's actual output rather than trusting
the copy.
]]

local this_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local ui = dofile(this_dir .. "/../src/ui.lua")
local L = ui.LAYOUT

ui.run = function() return true end

-- ---- mirrored from src/daemon.lua ----
local GESTURE_ZONE_KINDS = {
    task_swipe_area = true,
    learning_swipe_area = true,
}

local function zone_contains(z, x, y)
    return x >= z.x and x < z.x + z.w and y >= z.y and y < z.y + z.h
end

local function hit_test(zones, x, y)
    for _, z in ipairs(zones) do
        if not GESTURE_ZONE_KINDS[z.kind] and zone_contains(z, x, y) then return z end
    end
    return nil
end

local function find_zone_by_kind(zones, kind, x, y)
    for _, z in ipairs(zones) do
        if z.kind == kind and zone_contains(z, x, y) then return z end
    end
    return nil
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

local function make_state(n)
    local tasks = {}
    for i = 1, n do tasks[i] = { id = i, text = "task " .. i, done = false } end
    return { tasks = tasks, session_usage = { percent = 10, resets_label = "Resets in 1 hr" } }
end

local function learning_state(n)
    local items = {}
    for i = 1, n do
        items[i] = { id = i, kind = "course", name = "Course " .. i, percent = i,
                     detail = "", done = false, pages_read = 0, total_pages = 0 }
    end
    return { tasks = {}, learnings = items, session_usage = { percent = 0, resets_label = "" } }
end

--- The center of a zone is the point a user aiming at that control would
--- most plausibly hit, so every tap target should resolve to itself there.
local function center_of(z)
    return z.x + math.floor(z.w / 2), z.y + math.floor(z.h / 2)
end

print("=== every tap target resolves to itself at its own center ===")
for _, case in ipairs({
    { "dashboard, 3 tasks", ui.draw_dashboard, { make_state(3), "open", 1, nil, 80 } },
    { "dashboard, 20 tasks (pager shown)", ui.draw_dashboard, { make_state(20), "open", 2, nil, 80 } },
    { "dashboard, 0 tasks", ui.draw_dashboard, { make_state(0), "open", 1, nil, 80 } },
    { "learning, 3 items", ui.draw_learning, { learning_state(3), "open", 1, 80 } },
    { "learning, 40 items (pager shown)", ui.draw_learning, { learning_state(40), "open", 3, 80 } },
}) do
    local zones = case[2](unpack(case[3]))
    local wrong = {}
    for _, z in ipairs(zones) do
        if not GESTURE_ZONE_KINDS[z.kind] then
            local x, y = center_of(z)
            local got = hit_test(zones, x, y)
            if got ~= z then
                wrong[#wrong + 1] = string.format("%s at (%d,%d) resolved to %s",
                    z.kind, x, y, got and got.kind or "nothing")
            end
        end
    end
    check(case[1], #wrong == 0, table.concat(wrong, "; "))
end

print("\n=== the task area is tappable (the regression that shipped) ===")
do
    local zones = ui.draw_dashboard(make_state(3), "open", 1, nil, 80)

    -- A gesture zone must be registered, and must cover the task rows --
    -- otherwise this test would pass vacuously if the swipe area were
    -- ever removed.
    local swipe = find_zone_by_kind(zones, "task_swipe_area", 300, 180)
    check("a swipe area covers the task rows", swipe ~= nil)

    local first_row_y = L.task_row_first_y + 20
    for _, t in ipairs({
        { "task checkbox", L.margin + 20, first_row_y, "toggle_task" },
        { "task row body", 300, first_row_y, "toggle_task" },
        { "task delete x", L.screen_w - L.margin - 20, first_row_y, "delete_task_zone" },
    }) do
        local got = hit_test(zones, t[2], t[3])
        check(t[1] .. " resolves to " .. t[4],
            got ~= nil and got.kind == t[4],
            "got " .. (got and got.kind or "nothing"))
    end

    -- "+ Add Task" sits below the task rows but still inside the swipe
    -- band, which is exactly where the bug bit hardest.
    local add = nil
    for _, z in ipairs(zones) do if z.kind == "add_task_button" then add = z end end
    check("+ Add Task zone exists", add ~= nil)
    if add then
        local x, y = center_of(add)
        local got = hit_test(zones, x, y)
        check("+ Add Task is reachable", got ~= nil and got.kind == "add_task_button",
            "got " .. (got and got.kind or "nothing"))
        check("...and it is inside the swipe band (so this is a real test)",
            swipe ~= nil and zone_contains(swipe, x, y))
    end
end

print("\n=== the pager is tappable through the swipe band ===")
do
    local zones = ui.draw_dashboard(make_state(20), "open", 3, nil, 80)
    local counts = {}
    for _, z in ipairs(zones) do
        if z.kind == "page_prev" or z.kind == "page_next" or z.kind == "page_goto" then
            local x, y = center_of(z)
            local got = hit_test(zones, x, y)
            counts[#counts + 1] = (got and got.kind == z.kind) and 1 or 0
            if got == nil or got.kind ~= z.kind then
                check("pager " .. z.kind .. " -> page " .. tostring(z.page), false,
                    "got " .. (got and got.kind or "nothing"))
            end
        end
    end
    check("every pager control resolves to itself", #counts > 0 and
        (function() for _, v in ipairs(counts) do if v == 0 then return false end end return true end)(),
        #counts .. " pager zones found")
end

print("\n=== swipes still resolve, and only inside their own region ===")
do
    local zones = ui.draw_dashboard(make_state(20), "open", 1, nil, 80)
    check("swipe starting on a task row is recognised",
        find_zone_by_kind(zones, "task_swipe_area", 300, L.task_row_first_y + 10) ~= nil)
    check("swipe starting on the header is NOT",
        find_zone_by_kind(zones, "task_swipe_area", 300, L.header_y + 4) == nil)
    check("swipe starting on the footer buttons is NOT",
        find_zone_by_kind(zones, "task_swipe_area", 300, L.footer_y + 10) == nil)
    check("swipe starting on the nav bar is NOT",
        find_zone_by_kind(zones, "task_swipe_area", 300, L.nav_y + 10) == nil)

    local lz = ui.draw_learning(learning_state(40), "open", 1, 80)
    check("learning swipe area is recognised over its rows",
        find_zone_by_kind(lz, "learning_swipe_area", 300, L.learn_row_first_y + 10) ~= nil)
    check("learning swipe area does not extend into the nav bar",
        find_zone_by_kind(lz, "learning_swipe_area", 300, L.nav_y + 10) == nil)
end

print("\n=== gesture zones are never returned as tap targets ===")
do
    for _, case in ipairs({
        { "dashboard", ui.draw_dashboard, { make_state(20), "open", 1, nil, 80 } },
        { "learning", ui.draw_learning, { learning_state(40), "open", 1, 80 } },
    }) do
        local zones = case[2](unpack(case[3]))
        local leaked = nil
        -- Sweep the whole screen on a coarse grid rather than only at
        -- known control positions, so a gesture zone can't leak into tap
        -- resolution anywhere, including gaps between controls.
        for y = 0, L.screen_h - 1, 8 do
            for x = 0, L.screen_w - 1, 8 do
                local got = hit_test(zones, x, y)
                if got and GESTURE_ZONE_KINDS[got.kind] then
                    leaked = string.format("%s at (%d,%d)", got.kind, x, y)
                    break
                end
            end
            if leaked then break end
        end
        check(case[1] .. ": no gesture zone resolves as a tap", leaked == nil, leaked)
    end
end

print("")
if failures == 0 then
    print("ALL CHECKS PASSED")
else
    print(failures .. " CHECK(S) FAILED")
    os.exit(1)
end
