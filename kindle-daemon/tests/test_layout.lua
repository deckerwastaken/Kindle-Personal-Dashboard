--[[
test_layout.lua -- offline layout checks for ui.lua.

Runs on your LAPTOP, not on the Kindle:

    cd kindle-daemon/tests
    luajit test_layout.lua

WHAT THIS DOES
--------------
ui.lua draws by shelling out to the `fbink` CLI, and every drawing
primitive funnels through one function, M.run(args), which builds the
argv. This test replaces M.run with a recorder, renders each screen, and
then inspects the exact argv list that WOULD have been sent to fbink.

That makes a whole class of bug checkable without hardware: rectangles
that fall off the screen, text that overhangs the right margin, tap
targets that overlap each other or sit outside the display, pagination
that elides the wrong pages. None of those need a real panel to detect --
they are arithmetic, and this file's history is full of arithmetic that
was carefully hand-derived and still came out wrong (see the recomputed
y-positions in ui.lua's header, and the footer/toast overlap that only
turned up on a live device).

WHAT THIS DOES NOT DO
---------------------
It cannot tell you whether anything LOOKS right: whether a 2px outline is
visible at 167ppi, whether the pixel-art arrows read as triangles, or
whether FBInk actually places a glyph where ui.lua asked. Those remain
hardware questions -- see tools/fbink_selftest.sh.

In particular it takes ui.lua's own text-metric constants at face value
(8px per size unit, both directions). If those are wrong, this test
happily confirms a wrong layout is self-consistent.
]]

local this_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local ui = dofile(this_dir .. "/../src/ui.lua")
local L = ui.LAYOUT

-- ===================== recorder =====================

local calls = {}
ui.dry_run = false
ui.run = function(args)
    calls[#calls + 1] = args
    return true
end

--- Turn the captured argv lists back into structured draw operations.
local function decode(argv)
    local joined = table.concat(argv, " ")
    local top, left, w, h = joined:match("%-%-cls=top=(%-?%d+),left=(%-?%d+),width=(%-?%d+),height=(%-?%d+)")
    if top then
        return { op = "rect", x = tonumber(left), y = tonumber(top),
                 w = tonumber(w), h = tonumber(h) }
    end
    if argv[1] == "-x" then
        local o = { op = "text" }
        local i = 1
        while i <= #argv do
            local a = argv[i]
            if a == "-X" then o.x = tonumber(argv[i + 1]); i = i + 2
            elseif a == "-Y" then o.y = tonumber(argv[i + 1]); i = i + 2
            elseif a == "-S" then o.size = tonumber(argv[i + 1]); i = i + 2
            elseif a == "-C" or a == "-B" then i = i + 2
            else
                if a ~= "-x" and a ~= "-y" and a ~= "-q" and a ~= "-b" and a ~= "0" then
                    o.text = a
                end
                i = i + 1
            end
        end
        -- ui.lua compensates for FBInk's scale-dependent left inset by
        -- subtracting 4*(size-1) from the -X it passes. Add it back so
        -- the bounds check below runs against the TRUE drawn position,
        -- which is what the callers reason in.
        if o.x and o.size then o.x = o.x + 4 * (o.size - 1) end
        return o
    end
    return { op = "other" }
end

local function render(fn, ...)
    calls = {}
    local zones, extra = fn(...)
    local ops = {}
    for _, argv in ipairs(calls) do
        local d = decode(argv)
        if d.op ~= "other" then ops[#ops + 1] = d end
    end
    return ops, zones or {}, extra
end

-- ===================== harness =====================

local failures = 0
local function fail(fmt, ...)
    failures = failures + 1
    print("  FAIL " .. string.format(fmt, ...))
end
local function pass(msg)
    print("  ok   " .. msg)
end
local function check(name, cond, detail)
    if cond then pass(name) else fail("%s%s", name, detail and (" -- " .. detail) or "") end
end

--- Asserts an actual value EQUALS an expected one.
---
--- Distinct from check() above, which takes a boolean and an optional
--- failure message. Passing an expected value as check()'s third
--- argument silently turns the assertion into "is this non-nil?" --
--- which is how six checks in this file came to pass unconditionally,
--- including one that would still have passed if the nav tab had never
--- been renamed at all. Use check_eq whenever comparing two values.
local function check_eq(name, got, want)
    if got == want then
        pass(string.format("%s (%s)", name, tostring(got)))
    else
        fail("%s -- got %s, want %s", name, tostring(got), tostring(want))
    end
end

-- ===================== reusable assertions =====================

local function check_in_bounds(label, ops)
    local bad = {}
    for _, o in ipairs(ops) do
        if o.op == "rect" then
            if o.x < 0 or o.y < 0 or o.w < 0 or o.h < 0
                or o.x + o.w > L.screen_w or o.y + o.h > L.screen_h then
                bad[#bad + 1] = string.format("rect(%d,%d,%d,%d)", o.x, o.y, o.w, o.h)
            end
        elseif o.op == "text" and o.x and o.y and o.text then
            local right = o.x + #o.text * 8 * (o.size or 1)
            local bottom = o.y + 8 * (o.size or 1)
            if o.x < 0 or o.y < 0 or right > L.screen_w or bottom > L.screen_h then
                bad[#bad + 1] = string.format("text %q at (%d,%d) size %d -> right=%d bottom=%d",
                    o.text, o.x, o.y, o.size or 1, right, bottom)
            end
        end
    end
    if #bad == 0 then
        pass(label .. ": all draws inside 600x800")
    else
        fail("%s: %d draw(s) out of bounds", label, #bad)
        for i = 1, math.min(#bad, 5) do print("         " .. bad[i]) end
    end
end

--- Tap targets below 40px, knowingly tolerated.
---
--- Currently EMPTY, and that is the point -- every hit zone ui.lua emits
--- now meets the 40px floor.
---
--- It used to hold refresh_usage_button: the CLAUDE USAGE card's Refresh
--- control was a 22x22 icon button with its zone padded 1px each way,
--- i.e. 24x24, the one target under the floor every other control meets
--- (checkbox 40, task row 56, nav tab 64, footer buttons grown 32 -> 48
--- specifically for this reason). It was listed rather than fixed
--- because widening it was a real UI change to a shipped control. That
--- change has since been made -- the whole card is the tap target now
--- (see ui.lua) -- so the exception is gone rather than kept as dead
--- tolerance. The table itself stays: the check reads better with a
--- named place to record a deliberate exception, and an empty one
--- documents that there are none.
local KNOWN_SMALL_ZONES = {}

local function check_zones_sane(label, zones)
    local bad = {}
    for _, z in ipairs(zones) do
        if z.x < 0 or z.y < 0 or z.x + z.w > L.screen_w or z.y + z.h > L.screen_h then
            bad[#bad + 1] = string.format("%s at (%d,%d,%d,%d)", z.kind, z.x, z.y, z.w, z.h)
        end
        if (z.w < 40 or z.h < 40) and not KNOWN_SMALL_ZONES[z.kind] then
            bad[#bad + 1] = string.format("%s is %dx%d, under the 40px tap minimum", z.kind, z.w, z.h)
        end
    end
    if #bad == 0 then
        pass(label .. ": all hit zones on-screen and >=40px")
    else
        fail("%s: %d bad hit zone(s)", label, #bad)
        for i = 1, math.min(#bad, 5) do print("         " .. bad[i]) end
    end
end

--- Tap zones must not overlap each other, or a tap resolves to whichever
--- happened to be registered first. Gesture REGIONS are excluded: they
--- deliberately span the tap targets inside them, which is exactly why
--- daemon.lua looks them up separately instead of through hit_test().
local GESTURE_KINDS = { task_swipe_area = true, learning_swipe_area = true }

local function check_no_overlap(label, zones)
    local tap = {}
    for _, z in ipairs(zones) do
        if not GESTURE_KINDS[z.kind] then tap[#tap + 1] = z end
    end
    local bad = {}
    for i = 1, #tap do
        for j = i + 1, #tap do
            local a, b = tap[i], tap[j]
            if a.x < b.x + b.w and b.x < a.x + a.w
                and a.y < b.y + b.h and b.y < a.y + a.h then
                bad[#bad + 1] = string.format("%s(%d,%d,%d,%d) overlaps %s(%d,%d,%d,%d)",
                    a.kind, a.x, a.y, a.w, a.h, b.kind, b.x, b.y, b.w, b.h)
            end
        end
    end
    if #bad == 0 then
        pass(label .. ": no overlapping tap zones")
    else
        fail("%s: %d overlapping pair(s)", label, #bad)
        for i = 1, math.min(#bad, 5) do print("         " .. bad[i]) end
    end
end

-- ===================== fixtures =====================

local function make_state(n_tasks)
    local tasks = {}
    for i = 1, n_tasks do
        tasks[i] = { id = i, text = "task number " .. i, done = (i % 3 == 0) }
    end
    return {
        tasks = tasks,
        session_usage = { percent = 42, resets_label = "Resets in 2 hr 15 min" },
    }
end

-- ===================== tests =====================

print("=== battery indicator ===")
for _, pct in ipairs({ 100, 85, 42, 20, 9, 1, 0 }) do
    local ops = render(ui.draw_dashboard, make_state(3), "open", 1, nil, pct)
    check_in_bounds("battery " .. pct .. "%", ops)
end
do
    local ops = render(ui.draw_dashboard, make_state(3), "open", 1, nil, nil)
    check_in_bounds("battery unknown (nil)", ops)

    -- The unknown state must still draw something in the corner, rather
    -- than leaving a hole the user reads as a broken dashboard.
    local found = false
    for _, o in ipairs(ops) do
        if o.op == "text" and o.text == "--%" then found = true end
    end
    check("unknown battery draws \"--%\"", found)
end
do
    -- The widest possible label must not collide with the glyph, and the
    -- region erased for a battery-only repaint must contain it.
    local ops = render(ui.draw_battery_only, 100)
    local text
    for _, o in ipairs(ops) do if o.op == "text" then text = o end end
    check("100% text clears the glyph",
        text and (text.x + #text.text * 8 * text.size) <= L.battery_body_x,
        text and string.format("text ends at %d, glyph starts at %d",
            text.x + #text.text * 8 * text.size, L.battery_body_x))
    check("100% text starts inside the erased region",
        text and text.x >= L.battery_region_x,
        text and string.format("text x=%d, region x=%d", text.x, L.battery_region_x))
end
do
    -- Low battery draws an inverted badge; it must not touch the glyph.
    local ops = render(ui.draw_battery_only, 15)
    local badge
    for _, o in ipairs(ops) do
        if o.op == "rect" and o.y < L.battery_body_y and o.w < 100 and o.w > 40 then badge = o end
    end
    check("low-battery badge clears the glyph",
        badge and (badge.x + badge.w) < L.battery_body_x,
        badge and string.format("badge ends at %d, glyph starts at %d",
            badge.x + badge.w, L.battery_body_x))
end

print("\n=== dashboard at every task count that changes the layout ===")
for _, n in ipairs({ 0, 1, 4, 5, 8, 9, 20, 40, 100 }) do
    local ops, zones = render(ui.draw_dashboard, make_state(n), "open", 1, nil, 76)
    check_in_bounds(string.format("%3d tasks", n), ops)
    check_zones_sane(string.format("%3d tasks", n), zones)
    check_no_overlap(string.format("%3d tasks", n), zones)
end

print("\n=== connection states + armed delete ===")
for _, status in ipairs({ "open", "connecting", "offline" }) do
    local ops = render(ui.draw_dashboard, make_state(6), status, 1, nil, 55)
    check_in_bounds("status=" .. status, ops)
end
do
    local ops, zones = render(ui.draw_dashboard, make_state(6), "open", 1, 2, 55)
    check_in_bounds("armed delete", ops)
    check_no_overlap("armed delete", zones)
end
do
    local ops = render(ui.draw_dashboard, nil, "connecting", 1, nil, nil)
    check_in_bounds("no state yet (waiting for laptop)", ops)
end

print("\n=== pager: every page of a long list ===")
do
    local n_tasks = 100 -- 25 pages
    local total_pages = math.ceil(n_tasks / L.max_visible_tasks)
    local worst = 0
    for p = 1, total_pages do
        local ops, zones = render(ui.draw_dashboard, make_state(n_tasks), "open", p, nil, 76)
        local bad = false
        for _, o in ipairs(ops) do
            if o.op == "rect" and (o.x < 0 or o.x + o.w > L.screen_w) then bad = true end
            if o.op == "text" and o.x and o.text
                and (o.x < 0 or o.x + #o.text * 8 * (o.size or 1) > L.screen_w) then bad = true end
        end
        if bad then fail("page %d of %d draws outside the screen", p, total_pages) end
        local n_page_zones = 0
        for _, z in ipairs(zones) do
            if z.kind == "page_goto" or z.kind == "page_prev" or z.kind == "page_next" then
                n_page_zones = n_page_zones + 1
            end
        end
        if n_page_zones > worst then worst = n_page_zones end
        check_no_overlap(string.format("page %2d/%d", p, total_pages), zones)
    end
    check("pager never exceeds its slot budget", worst <= L.pager_max_slots + 2,
        "max zones seen: " .. worst)
end

print("\n=== pager windowing rules ===")
do
    local function slots_for(page, n_tasks)
        local _, zones = render(ui.draw_dashboard, make_state(n_tasks), "open", page, nil, 76)
        local pages, prev, next_ = {}, false, false
        for _, z in ipairs(zones) do
            if z.kind == "page_goto" then pages[#pages + 1] = z.page
            elseif z.kind == "page_prev" then prev = true
            elseif z.kind == "page_next" then next_ = true end
        end
        table.sort(pages)
        return pages, prev, next_
    end

    -- 4 tasks/page. 8 tasks = 2 pages, 100 tasks = 25 pages.
    local pages, prev, next_ = slots_for(1, 8)
    check("2 pages, on page 1: prev arrow hidden", prev == false)
    check("2 pages, on page 1: next arrow shown", next_ == true)
    check("2 pages, on page 1: page 2 is tappable", pages[1] == 2 and #pages == 1)

    pages, prev, next_ = slots_for(2, 8)
    check("2 pages, on page 2: prev shown, next hidden", prev == true and next_ == false)

    -- Page 1 and the last page must always be reachable in one tap from
    -- anywhere in a long list.
    local total = 25
    local missing_first, missing_last = {}, {}
    for p = 1, total do
        local ps = slots_for(p, 100)
        local has_first, has_last = (p == 1), (p == total)
        for _, v in ipairs(ps) do
            if v == 1 then has_first = true end
            if v == total then has_last = true end
        end
        if not has_first then missing_first[#missing_first + 1] = p end
        if not has_last then missing_last[#missing_last + 1] = p end
    end
    check("page 1 reachable from every page of 25", #missing_first == 0,
        "missing on pages: " .. table.concat(missing_first, ","))
    check("last page reachable from every page of 25", #missing_last == 0,
        "missing on pages: " .. table.concat(missing_last, ","))

    -- A "gap" that elides only a single page would be worse than just
    -- showing that page, so every elided run must cover at least 2.
    local thin_gaps = {}
    for p = 1, total do
        local ps = slots_for(p, 100)
        local shown = {}
        for _, v in ipairs(ps) do shown[v] = true end
        shown[p] = true -- the current page is drawn but has no hit zone
        local sorted = {}
        for v in pairs(shown) do sorted[#sorted + 1] = v end
        table.sort(sorted)
        for i = 2, #sorted do
            if sorted[i] - sorted[i - 1] == 2 then
                thin_gaps[#thin_gaps + 1] = string.format("p%d hides only page %d", p, sorted[i] - 1)
            end
        end
    end
    check("no gap elides exactly one page", #thin_gaps == 0,
        table.concat(thin_gaps, "; "))

    -- The current page must never be tappable (it would cost a
    -- full-screen refresh to redraw an identical screen).
    local self_tappable = {}
    for p = 1, total do
        local ps = slots_for(p, 100)
        for _, v in ipairs(ps) do
            if v == p then self_tappable[#self_tappable + 1] = p end
        end
    end
    check("current page is never its own tap target", #self_tappable == 0,
        table.concat(self_tappable, ","))
end

print("\n=== swipe region ===")
do
    local _, zones = render(ui.draw_dashboard, make_state(20), "open", 2, nil, 76)
    local swipe
    for _, z in ipairs(zones) do if z.kind == "task_swipe_area" then swipe = z end end
    check("task swipe area exists", swipe ~= nil)
    check_eq("swipe area carries the page count", swipe and swipe.total_pages, 5)
    check("swipe area spans the full width", swipe and swipe.x == 0 and swipe.w == L.screen_w)
    check("swipe area stays clear of the footer buttons",
        swipe and (swipe.y + swipe.h) <= L.footer_y,
        swipe and string.format("swipe bottom %d vs footer %d", swipe.y + swipe.h, L.footer_y))
end

print("\n=== LEARNING screen ===")

--- Mirrors what backend/state.py's _recompute() guarantees the renderer
--- will receive: percent/detail/done already derived, so the Kindle
--- never divides or branches on kind. Building fixtures this way means
--- the test fails if ui.lua ever starts reading a raw field
--- (pages_read/total_pages) it isn't supposed to touch.
local function course(id, name, percent)
    return { id = id, kind = "course", name = name, percent = percent,
             detail = "", done = percent == 100, pages_read = 0, total_pages = 0 }
end
local function book(id, name, read, total)
    local pct = math.floor(read * 100 / total)
    return { id = id, kind = "book", name = name, percent = pct,
             detail = string.format("%d/%d pages", read, total),
             done = pct == 100, pages_read = read, total_pages = total }
end

local function learning_state(items)
    return { tasks = {}, learnings = items,
             session_usage = { percent = 0, resets_label = "" } }
end

do
    local items = {
        book(1, "Atomic Habits", 120, 320),
        course(2, "Spanish", 40),
        book(3, "Designing Data-Intensive Applications", 12, 616),
        course(4, "Linear Algebra", 100),
        book(5, "Deep Work", 0, 300),
        book(6, "The Pragmatic Programmer", 352, 352),
    }
    local ops, zones = render(ui.draw_learning, learning_state(items), "open", 1, 78)
    check_in_bounds("mixed courses and books", ops)
    check_zones_sane("mixed courses and books", zones)
    check_no_overlap("mixed courses and books", zones)

    -- The screen must show learnings and nothing borrowed from the
    -- dashboard: no task rows, no usage card, no Exit/Restart footer.
    local text_blob = {}
    for _, o in ipairs(ops) do
        if o.op == "text" and o.text then text_blob[#text_blob + 1] = o.text end
    end
    local joined = table.concat(text_blob, "|")
    check("shows the LEARNING title", joined:find("LEARNING", 1, true) ~= nil)
    for _, forbidden in ipairs({ "TODAY", "CLAUDE USAGE", "Exit Dashboard",
                                 "Restart SSH", "+ Add Task" }) do
        check("does not show \"" .. forbidden .. "\"",
            joined:find(forbidden, 1, true) == nil)
    end

    local kinds = {}
    for _, z in ipairs(zones) do kinds[z.kind] = (kinds[z.kind] or 0) + 1 end
    check("no per-item tap zones (screen is read-only)",
        kinds.toggle_task == nil and kinds.delete_task_zone == nil)
    check("nav bar is present", kinds.nav_tab == 4)
end

do
    -- Every row count from empty to a full page and beyond.
    for _, n in ipairs({ 0, 1, 2, 7, 8, 9, 16, 17, 40 }) do
        local items = {}
        for i = 1, n do
            if i % 2 == 0 then
                items[i] = book(i, "Book number " .. i, i * 3, 400)
            else
                items[i] = course(i, "Course number " .. i, (i * 7) % 101)
            end
        end
        local ops, zones = render(ui.draw_learning, learning_state(items), "open", 1, 78)
        check_in_bounds(string.format("%2d learnings", n), ops)
        check_zones_sane(string.format("%2d learnings", n), zones)
        check_no_overlap(string.format("%2d learnings", n), zones)
    end
end

do
    -- Long names must truncate rather than run into the right-aligned
    -- detail/percent, and must do so differently for books (which have
    -- less room, because the detail text takes some).
    local items = {
        book(1, string.rep("VeryLongBookTitle", 8), 120, 320),
        course(2, string.rep("VeryLongCourseName", 8), 40),
    }
    local ops = render(ui.draw_learning, learning_state(items), "open", 1, 78)
    check_in_bounds("very long names truncate in bounds", ops)
end

do
    -- Percent extremes: 0% must still show a visible (outlined) empty
    -- bar, 100% a full one, and neither may overflow the content width.
    for _, pct in ipairs({ 0, 1, 50, 99, 100 }) do
        local ops = render(ui.draw_learning, learning_state({ course(1, "X", pct) }), "open", 1, 78)
        check_in_bounds(string.format("course at %3d%%", pct), ops)
        local widest = 0
        for _, o in ipairs(ops) do
            if o.op == "rect" and o.h == L.learn_bar_h and o.w > widest then widest = o.w end
        end
        check(string.format("%3d%% bar fill never exceeds the track", pct),
            widest <= L.screen_w - 2 * L.margin, "widest fill " .. widest)
    end
end

do
    local ops = render(ui.draw_learning, learning_state({}), "open", 1, 78)
    check_in_bounds("empty state", ops)
    local joined = {}
    for _, o in ipairs(ops) do
        if o.op == "text" and o.text then joined[#joined + 1] = o.text end
    end
    joined = table.concat(joined, "|")
    check("empty state names the real add path (Telegram)",
        joined:find("Telegram", 1, true) ~= nil)

    -- "no data yet" must stay distinct from "you have no learnings":
    -- collapsing them would render a comms failure as a confident claim
    -- that the user's list is empty.
    local ops2 = render(ui.draw_learning, nil, "connecting", 1, nil)
    check_in_bounds("no state yet", ops2)
    local joined2 = {}
    for _, o in ipairs(ops2) do
        if o.op == "text" and o.text then joined2[#joined2 + 1] = o.text end
    end
    joined2 = table.concat(joined2, "|")
    check("waiting state says it is waiting", joined2:find("Waiting", 1, true) ~= nil)
    check("waiting state is not the empty state",
        joined2:find("Nothing here yet", 1, true) == nil)

    -- A snapshot from an older backend that has no learnings key at all
    -- counts as "empty", not "still waiting" -- we did hear from the
    -- laptop, so claiming otherwise would be the wrong message.
    local ops3 = render(ui.draw_learning, { tasks = {} }, "open", 1, 78)
    local joined3 = {}
    for _, o in ipairs(ops3) do
        if o.op == "text" and o.text then joined3[#joined3 + 1] = o.text end
    end
    joined3 = table.concat(joined3, "|")
    check("state without a learnings key renders the empty state",
        joined3:find("Nothing here yet", 1, true) ~= nil)
    check("...and does not claim to be waiting",
        joined3:find("Waiting", 1, true) == nil)
end

do
    -- Paging through a long learning list.
    local items = {}
    for i = 1, 40 do items[i] = course(i, "Course " .. i, i * 2) end
    local total_pages = math.ceil(40 / L.learn_rows_per_page)
    for p = 1, total_pages do
        local ops, zones = render(ui.draw_learning, learning_state(items), "open", p, 78)
        check_in_bounds(string.format("learning page %d/%d", p, total_pages), ops)
        check_no_overlap(string.format("learning page %d/%d", p, total_pages), zones)
        local swipe
        for _, z in ipairs(zones) do
            if z.kind == "learning_swipe_area" then swipe = z end
        end
        check(string.format("page %d has a swipe area with the page count", p),
            swipe and swipe.total_pages == total_pages)
    end

    -- Clamping: asking for a page past the end must come back clamped,
    -- so a list that shrank can't strand the user on a blank page.
    local _, _, effective = render(ui.draw_learning, learning_state(items), "open", 99, 78)
    check_eq("out-of-range page clamps to the last one", effective, total_pages)
end

do
    -- Rows must never collide with the pinned pager row or the nav bar.
    local items = {}
    for i = 1, 40 do items[i] = book(i, "Book " .. i, i, 100) end
    local ops = render(ui.draw_learning, learning_state(items), "open", 2, 78)
    local lowest = 0
    for _, o in ipairs(ops) do
        -- ignore the full-screen clear and the nav bar's own strip
        if o.op == "rect" and o.h < 200 and o.y < L.nav_y then
            if o.y + o.h > lowest then lowest = o.y + o.h end
        end
    end
    check("nothing drawn between the pager and the nav bar",
        lowest <= L.nav_y, "lowest content bottom " .. lowest .. ", nav bar at " .. L.nav_y)
end

print("\n=== nav bar reflects the active screen ===")
do
    local function active_tab_of(ops)
        -- The active tab is the one drawn on a filled black strip; find
        -- the inverted fill and match it to a tab index.
        local tab_w = math.floor(L.screen_w / L.nav_tab_count)
        for _, o in ipairs(ops) do
            if o.op == "rect" and o.y == L.nav_y + 2 and o.w == tab_w then
                return ui.NAV_TABS[math.floor(o.x / tab_w) + 1]
            end
        end
        return nil
    end

    local dash_ops = render(ui.draw_dashboard, make_state(3), "open", 1, nil, 78)
    check_eq("dashboard highlights Today", active_tab_of(dash_ops), "Today")

    local learn_ops = render(ui.draw_learning,
        learning_state({ course(1, "Spanish", 40) }), "open", 1, 78)
    check_eq("learning screen highlights Learning", active_tab_of(learn_ops), "Learning")

    check_eq("the Lists tab is gone", ui.NAV_TABS[2], "Learning")

    -- Restoring the nav bar after a toast must preserve which tab is
    -- active. Passing no tab used to be safe because Today was always
    -- active; now it would silently mislabel the Learning screen.
    local restored = render(ui.clear_flash_message, "Learning")
    check_eq("toast dismissal restores the Learning tab as active",
        active_tab_of(restored), "Learning")
    local restored2 = render(ui.clear_flash_message, "Today")
    check_eq("toast dismissal restores the Today tab as active",
        active_tab_of(restored2), "Today")
end

print("\n=== locked screen ===")
do
    local ops, zones = render(ui.draw_blank_screen)
    check_in_bounds("locked screen", ops)
    check("locked screen registers NO hit zones", #zones == 0, #zones .. " zones")

    -- It must actually cover the whole display: a blank that missed a
    -- strip would leave a band of the old dashboard visible.
    local covers = false
    for _, o in ipairs(ops) do
        if o.op == "rect" and o.x == 0 and o.y == 0
            and o.w == L.screen_w and o.h == L.screen_h then covers = true end
    end
    check("blanks the entire 600x800 screen", covers)

    -- Exactly one thing survives the blank: the word itself. More than
    -- one text draw here would mean something else leaked onto a screen
    -- whose whole job is to show nothing else.
    local texts = {}
    for _, o in ipairs(ops) do if o.op == "text" then texts[#texts + 1] = o end end
    check_eq("draws exactly one label", #texts, 1)
    if #texts == 1 then
        local t = texts[1]
        check_eq("the label reads 'Locked'", t.text, "Locked")

        -- Centered by computation in ui.lua, so verify against the same
        -- geometry rather than against a copied literal: a hand-typed
        -- expected pixel would keep passing if char_w() were corrected
        -- and the label silently went off-center.
        local w = #t.text * 8 * t.size
        check_eq("horizontally centered", t.x, math.floor((L.screen_w - w) / 2))
        check_eq("vertically centered", t.y, math.floor((L.screen_h - 8 * t.size) / 2))
    end
end

print("\n=== PIN entry keypad ===")
do
    local ops, zones = render(ui.draw_pin_entry, "", false)
    check_in_bounds("pin entry, empty buffer", ops)
    check_zones_sane("pin entry, empty buffer", zones)
    check_no_overlap("pin entry, empty buffer", zones)

    -- Exactly 11 tap targets: digits 0-9 plus backspace. The row-4 blank
    -- spacer (see PIN_KEYPAD_ROWS in ui.lua) must register no zone at all.
    check_eq("11 hit zones (10 digits + backspace)", #zones, 11)

    local digits_seen = {}
    local backspace_count = 0
    for _, z in ipairs(zones) do
        if z.kind == "pin_digit" then
            digits_seen[z.digit] = (digits_seen[z.digit] or 0) + 1
        elseif z.kind == "pin_backspace" then
            backspace_count = backspace_count + 1
        else
            fail("unexpected zone kind on the PIN screen: %s", tostring(z.kind))
        end
    end
    local all_digits_once = true
    for d = 0, 9 do
        if digits_seen[tostring(d)] ~= 1 then all_digits_once = false end
    end
    check("every digit 0-9 appears exactly once", all_digits_once)
    check_eq("exactly one backspace key", backspace_count, 1)

    -- Never leaks which digits were typed: no digit character may appear
    -- as drawn TEXT anywhere except as a key's own label (10 key labels
    -- total: "0".."9" -- a stray extra digit glyph would mean something
    -- is echoing the buffer in plain text). Expected count is 9, not 10:
    -- this test file's own decode() (see its header comment) drops any
    -- token that is literally "0", since that string ALSO appears as the
    -- value of the unrelated "-x 0"/"-y 0" flags every draw_text call
    -- emits -- so the "0" key's own label is invisible to this specific
    -- check by construction, not because it isn't drawn. The hit-zone
    -- checks above (which read draw_pin_entry's real return value, not
    -- this decoded text) already prove the "0" key exists and works.
    local digit_glyphs = 0
    for _, o in ipairs(ops) do
        if o.op == "text" and o.text and #o.text == 1 and o.text:match("^%d$") then
            digit_glyphs = digit_glyphs + 1
        end
    end
    check_eq("only the 9 non-'0' key labels are single-digit text draws", digit_glyphs, 9)
end
do
    -- A wrong-attempt redraw: empty buffer (daemon.lua clears it before
    -- this call) but the error line now showing.
    local ops, zones = render(ui.draw_pin_entry, "", true)
    check_in_bounds("pin entry, wrong-PIN error shown", ops)
    check_no_overlap("pin entry, wrong-PIN error shown", zones)
    local found_error_text = false
    for _, o in ipairs(ops) do
        if o.op == "text" and o.text and o.text:find("Wrong PIN") then found_error_text = true end
    end
    check("error state draws the 'Wrong PIN' message", found_error_text)
end
do
    -- Partial entry (2 of 4 digits) must still render in-bounds -- this
    -- is the buffer state M.update_pin_dots() partial-refreshes between
    -- full redraws, so draw_pin_entry itself only needs to be sane at
    -- every buffer length, not exercise the partial-refresh path.
    for _, buf in ipairs({ "1", "12", "123", "1234" }) do
        local ops = render(ui.draw_pin_entry, buf, false)
        check_in_bounds("pin entry, buffer length " .. #buf, ops)
    end
end

print("\n=== other screens still render cleanly ===")
do
    local ops, zones = render(ui.draw_keyboard, "hello world")
    check_in_bounds("keyboard", ops)
    check_no_overlap("keyboard", zones)
    local ops2, zones2 = render(ui.draw_confirm_exit)
    check_in_bounds("confirm exit", ops2)
    check_no_overlap("confirm exit", zones2)
end

print("")
if failures == 0 then
    print("ALL CHECKS PASSED")
else
    print(failures .. " CHECK(S) FAILED")
    os.exit(1)
end
