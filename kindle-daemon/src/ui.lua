--[[
ui.lua -- draws the dashboard by shelling out to the `fbink` CLI binary
that already ships inside your KOReader install (koreader/fbink on this
device -- see README.md for why we call the CLI instead of linking
against libfbink.so directly).

Every draw call passes -b/--norefresh so intermediate drawing doesn't
each trigger their own visible flash; a single explicit refresh happens
at the end of a redraw pass (see UI.flush()).

CONFIRMED ON HARDWARE (2026-08-02, via kindle-daemon/INSTALL.md step 4's
"fbink_selftest.sh" calibration, cross-checked with `fbink -E` which
reports the exact pixel rect actually drawn): `fbink -x 0 -y 0 -X <px>
-Y <px>` does place text with its top-left corner at pixel (px, px) from
the screen's true top-left -- origin_x/origin_y below are confirmed 0,
no shift needed.

Two things that were previously guessed are now measured exactly instead:
  - Text height is a clean 8px per -S size unit (8/16/32px for sizes
    1/2/4) -- NOT the ~15px/unit this file originally assumed (nearly
    2x off). Every LAYOUT y-position below that depends on a text height
    has been recomputed against the real 8px/unit figure.
  - At a requested -X 0, the ACTUAL left edge FBInk draws at is offset
    by 4*(size-1) px (confirmed at sizes 1/2/4: +0/+4/+12px) -- some
    scale-dependent internal margin/rounding, not a bug in this code.
    M.draw_text() below compensates for this so callers can keep
    thinking in true pixel coordinates.
]]

local M = {}

-- ===================== layout constants (600x800 screen) =====================

M.LAYOUT = {
    screen_w = 600,
    screen_h = 800,
    origin_x = 0, -- see calibration note above
    origin_y = 0,
    margin = 24,

    -- Spacing rhythm: every vertical gap below is deliberately one of
    -- three sizes rather than an arbitrary number that happened to look
    -- OK -- gap_xs between tightly related elements (also reused as
    -- task_row_gap), gap_sm between a section's own label and the
    -- content directly under it, gap_lg between one section and the
    -- next (equal to `margin`, so vertical rhythm echoes the horizontal
    -- side margins).
    gap_xs = 8,
    gap_sm = 16,
    gap_lg = 24,

    -- NOTE on the y-positions below: text height is CONFIRMED (see the
    -- big comment at the top of this file) to be a clean 8px per -S size
    -- unit -- these positions are computed against that real figure, not
    -- a guess. Previously this file assumed ~15px/unit (nearly 2x too
    -- tall), which left every gap below noticeably more sparse than
    -- intended; recomputing against the real 8px/unit figure tightens
    -- the whole layout up without changing its logical structure.
    header_y = 24, -- top of the clock; = margin, matching the side padding
    time_font_size = 4,   -- fbink -S multiplier, 1-4 -- clock is the one
                           -- thing drawn at max size, so it stays the
                           -- clear visual anchor of the whole screen
    date_font_size = 2,
    date_y = 64, -- header_y + real size-4 height (32) + gap_xs

    -- Connection status badge: shares the date's row (see draw_dashboard)
    -- rather than the clock's, so the biggest element on screen isn't
    -- competing with corner text for attention.
    status_font_size = 1,
    status_badge_w = 140, -- wide enough for "CONNECTING", the longest state
    status_badge_h = 28,
    status_badge_y = 65,  -- date_y + 1, matching the original's top-alignment style
    status_text_y = 72,   -- badge_y + 7, same relative offset as originally tuned

    divider_y = 104, -- date_y + real size-2 height (16) + gap_lg
    divider_h = 2,

    today_label_y = 122, -- divider_y + divider_h + gap_sm
    task_row_first_y = 154, -- today_label_y + real size-2 height (16) + gap_sm
    task_row_h = 56,
    task_row_gap = 8, -- = gap_xs
    task_checkbox_w = 40,
    task_checkbox_border = 6, -- ring thickness for the unchecked "outline" box
    task_delete_w = 40, -- width of the per-row "x" delete-armed zone at
                         -- the row's right edge (see draw_dashboard)

    -- CHANGED from 5 to 4 (2026-08-02) to make room for the always-
    -- visible "+ Add Task" row added below the task list -- that row now
    -- always consumes one of the row "slots" this budget was originally
    -- tuned around, so shrinking max_visible_tasks by exactly one keeps
    -- the worst-case total row count (and therefore this whole vertical
    -- layout) unchanged from before: task_row_first_y + 6*(task_row_h +
    -- task_row_gap) [4 task rows + 1 "see more" row + 1 "+ Add Task"
    -- row, the worst case that can appear at once] = 154 + 384 = 538; +
    -- usage_card_gap_above(24) + label height (real size-2: 16) +
    -- gap_sm(16) + usage_card_h(74) = 668, leaving 68px of slack before
    -- the nav bar at screen_h - nav_bar_h = 736. footer_controls_h(48) +
    -- footer_controls_gap(8) = 56px is anchored UP from the nav bar (see
    -- draw_dashboard), landing at y=680 -- comfortably clear of the 668
    -- worst case above it, with 12px to spare.
    --
    -- RECHECKED, not just re-eyeballed, on 2026-08-02 when
    -- footer_controls_h grew from 32 to 48px for tap-target size: growing
    -- it in place (without touching usage_card_h) pushes footer_y to 680
    -- while card_bottom stays at 684 -- a -4px OVERLAP, not just reduced
    -- slack. usage_card_h was trimmed from 90 to 74 (see its own comment)
    -- specifically to fund this, landing back on the exact same 12px
    -- margin the original 32px footer had. Verified by direct calculation
    -- (see this project's dev notes), not by assuming the arithmetic
    -- would still work out.
    max_visible_tasks = 4,

    usage_card_gap_above = 24, -- = gap_lg

    -- REDUCED from 90 to 74 (2026-08-02), then GROWN to 78 (2026-08-04)
    -- to fit a real boxed "Refresh" button (not just bare text) on the
    -- "Resets in..." row without cramping it -- see that row's own
    -- comment in draw_dashboard. The card is now FIXED-position (see
    -- usage_card_box_y below), anchored up from the fixed footer_y, so
    -- growing this by 4px just costs 4px off that anchor's own margin
    -- (12px -> 8px, still comfortably positive/verified, same kind of
    -- direct-calculation check as the original 90->74 trim below).
    usage_card_h = 78,

    -- Exit Dashboard / Restart SSH buttons, anchored to the bottom (see
    -- draw_dashboard) rather than placed relative to the usage card,
    -- specifically so they never collide with the variable-height task
    -- list above them.
    --
    -- GREW from 32 to 48 (2026-08-02). These are the two controls a
    -- LOCKED-OUT user relies on to recover the device (get SSH back, or
    -- bail out to reboot) -- every other tap target on this screen is
    -- bigger (checkbox 40px, task row 56px, nav tab 64px), and this is
    -- exactly the situation where an undersized target is most costly and
    -- most frustrating, especially on this device's IR touch panel, whose
    -- calibration has not been confirmed on hardware. 48px lands mid-way
    -- between the checkbox and task-row targets. Growing this required
    -- reclaiming 16px of vertical budget from usage_card_h above (see its
    -- comment) to keep the same worst-case safety margin as before -- see
    -- max_visible_tasks's comment for the recomputed arithmetic.
    footer_controls_h = 48,
    footer_controls_gap = 8, -- gap between this row and the nav bar below
                              -- it; numerically = gap_xs, but kept as a
                              -- literal here (not L.gap_xs) since this
                              -- table is still under construction at this
                              -- point in the file and can't reference its
                              -- own sibling fields yet

    nav_bar_h = 64,
    nav_tab_count = 4,
}

local L = M.LAYOUT

-- CONFIRMED ON HARDWARE (2026-08-02, live device test): M.flash_message()
-- used to compute its own y-position independently (a fixed offset from
-- nav_bar_h), which was correct when it was written but silently drifted
-- out of sync once the footer controls row was added below the task
-- list, and again when that row grew from 32 to 48px -- nothing kept the
-- two in sync, and the user found the toast visibly overlapping the Exit
-- Dashboard/Restart SSH buttons on the real device. footer_y is a fixed
-- value on every draw, so it's computed exactly ONCE here and referenced
-- by both draw_dashboard's footer section and flash_message below --
-- there is no other place in this file computing "near the bottom of the
-- screen" from scratch anymore.
L.footer_y = L.screen_h - L.nav_bar_h - L.footer_controls_h - L.footer_controls_gap
L.nav_y = L.screen_h - L.nav_bar_h -- top of the bottom nav bar strip

-- CHANGED (2026-08-04): the CLAUDE USAGE card used to be positioned
-- dynamically, directly below wherever the task list actually ended --
-- so it visibly moved up and down depending on how many tasks were
-- showing. User asked for it to sit at a FIXED position right above the
-- footer buttons instead, same "computed once, referenced everywhere"
-- treatment as footer_y/nav_y above rather than a re-derived-per-draw
-- value like the task list itself.
--
-- task_list_max_bottom_y is the same worst-case figure max_visible_tasks'
-- own comment above already derives by hand (4 task rows + 1 "see more"
-- row + 1 "+ Add Task" row = 6 total rows) -- expressed here as a real
-- formula instead of a re-typed literal so it can't silently drift out of
-- sync with max_visible_tasks/task_row_h/task_row_gap again if any of
-- those ever change. Anchoring the card to THIS (its old worst-case
-- position) rather than to some fresh smaller gap means the card now
-- always sits exactly where it used to sit only in the worst case --
-- mathematically identical to a value already proven not to collide with
-- the footer (668 card-bottom vs. 680 footer_y, the same verified 12px
-- margin as before), just no longer dependent on the actual task count.
L.task_list_max_bottom_y = L.task_row_first_y + (L.max_visible_tasks + 2) * (L.task_row_h + L.task_row_gap)
L.usage_card_label_y = L.task_list_max_bottom_y + L.usage_card_gap_above
L.usage_card_box_y = L.usage_card_label_y + 16 + L.gap_sm -- 16 = real size-2 label height

-- Glyph width in px at size=1, used to right-align the "N% used" label
-- in the CLAUDE USAGE card below against the progress bar's right edge.
-- CONFIRMED ON HARDWARE (2026-08-04, via `fbink -E`, the same technique
-- fbink_selftest.sh already used to confirm this file's other pixel
-- assumptions): "A" / "AAAAAAAA" / "Refresh" / "31% used" all measured
-- at exactly 8px per glyph at size=1 -- a plain square 8x8 cell, same
-- figure as the already-confirmed 8px/unit TEXT HEIGHT. The previous
-- value here (6, an unconfirmed guess) undercounted string width, which
-- pushed right-aligned text past its intended right edge instead of
-- landing on it -- caught via live visual feedback on the device.
local CARD_CHAR_W_S1 = 8

-- Hand-built pixel-art "refresh" icon (a circular arrow) for the CLAUDE
-- USAGE card's Refresh button -- see that button's own comment in
-- draw_dashboard for why (this FBInk build has neither image blitting
-- nor reliable Unicode glyph support, confirmed via `fbink --help`, so a
-- real ↻ glyph or icon image isn't available; flat rectangles are the
-- only primitive this file has). Each entry is {x, y, w, h}, relative to
-- the button's own top-left corner, designed for a 22x22px button (see
-- refresh_btn_size). Rows sweep top to bottom: a top arc, then the left
-- side at two heights (curving out to its widest point and back in),
-- mirrored on the right for the upper-right only -- the lower-right is
-- deliberately omitted, leaving the ring's "gap" -- and finally a small
-- shrinking wedge positioned right at that gap as the arrowhead.
local REFRESH_ICON_RECTS = {
    { 6, 3, 8, 3 },  -- top arc
    { 3, 6, 3, 3 },  -- upper-left
    { 2, 9, 3, 3 },  -- left side, widest point
    { 4, 12, 5, 3 }, -- bottom-left arc, curving toward bottom-center
    { 14, 6, 3, 3 }, -- upper-right
    { 15, 9, 3, 3 }, -- right side, widest point
    { 15, 12, 4, 2 }, -- arrowhead base
    { 16, 14, 2, 2 }, -- arrowhead tip
}

-- ===================== fbink subprocess plumbing =====================

M.fbink_path = "/mnt/us/koreader/fbink" -- overridden by config.lua at init
M.debug_log = nil -- optional log module, set by init()
M.dry_run = false -- if true, print commands instead of executing (used by
                   -- tools/fbink_selftest.sh style manual testing, and
                   -- automatically enabled if fbink_path doesn't exist)

function M.init(fbink_path, log)
    M.fbink_path = fbink_path or M.fbink_path
    M.debug_log = log

    local f = io.open(M.fbink_path, "rb")
    if f then
        f:close()
    else
        M.dry_run = true
        if log then
            log.warn("ui: fbink binary not found at " .. M.fbink_path ..
                      " -- running in DRY RUN mode (commands will be logged, not executed). " ..
                      "Fix the fbink_path setting in config.lua.")
        end
    end
end

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", [['\'']]) .. "'"
end

--- Run fbink with the given argument list (array of strings; each will
--- be shell-quoted). Returns true/false, and logs failures rather than
--- raising -- a bad draw call should never take the whole daemon down.
function M.run(args)
    local parts = { shell_quote(M.fbink_path) }
    for _, a in ipairs(args) do
        parts[#parts + 1] = shell_quote(a)
    end
    local cmd = table.concat(parts, " ") .. " >/dev/null 2>&1"

    if M.dry_run then
        if M.debug_log then M.debug_log.info("[dry-run] " .. cmd) end
        return true
    end

    local ok = os.execute(cmd)
    -- Lua 5.1/LuaJIT os.execute returns the raw exit status (platform
    -- dependent); treat "falsy" / nonzero as a failure worth a log line,
    -- but never error() -- a failed draw call is not fatal.
    local success = (ok == true or ok == 0)
    if not success and M.debug_log then
        M.debug_log.warn("ui: fbink call may have failed: " .. cmd)
    end
    return success
end

-- ===================== drawing primitives =====================

function M.clear_screen()
    M.run({ "-c", "-q" })
end

--- Fill a pixel rectangle with a solid color (also usable to erase a
--- region back to WHITE before redrawing it).
---
--- NOTE on argument style: -k/--cls takes an *optional* bracketed
--- argument (`--cls [top=NUM,...]`). Under the standard GNU getopt_long
--- rules that CLI tools like this are almost always built with, an
--- optional argument MUST be attached to its flag (`--cls=top=...` or
--- `-ktop=...`) -- passing it as a separate argv token (`-k top=...`)
--- would instead be parsed as `-k` with no argument, followed by an
--- unrelated positional argument, silently doing the wrong thing. We
--- therefore always use the fused `--cls=...`/`--refresh=...` form here,
--- never a space-separated one, for exactly this reason.
function M.fill_rect(x, y, w, h, color)
    M.run({
        string.format("--cls=top=%d,left=%d,width=%d,height=%d", y, x, w, h),
        "-B", color or "WHITE",
        "-b", "-q",
    })
end

--- Print a line of text with its top-left corner at pixel (x, y).
--- opts: { size=1..4, fg="BLACK", bg="WHITE", norefresh=true }
function M.draw_text(x, y, text, opts)
    opts = opts or {}
    local size = opts.size or 1
    -- CONFIRMED ON HARDWARE (see this file's header comment): FBInk's
    -- actual drawn left edge runs 4*(size-1)px to the right of whatever
    -- -X we pass, for reasons internal to FBInk (margin/rounding at
    -- larger scales, not something this code controls). Subtracting it
    -- here means every caller can keep specifying true pixel coordinates.
    local x_correction = 4 * (size - 1)
    local args = {
        "-x", "0", "-y", "0",
        "-X", tostring(L.origin_x + x - x_correction),
        "-Y", tostring(L.origin_y + y),
        "-S", tostring(size),
        "-C", opts.fg or "BLACK",
        "-B", opts.bg or "WHITE",
        "-q",
    }
    if opts.norefresh ~= false then
        args[#args + 1] = "-b"
    end
    args[#args + 1] = text
    M.run(args)
end

--- Trigger a single visible screen refresh. Call this once at the end of
--- a redraw pass (after N draw_text/fill_rect calls made with -b set).
--- waveform: "GC16" (default, best quality, slower/more flash -- good for
--- a full redraw), "AUTO", "A2"/"DU" (fast, lower quality -- fine for a
--- small partial update like a single checkbox).
function M.flush(waveform, rect)
    -- see M.fill_rect's note above on why this is `--refresh=...` (fused)
    -- rather than `-s VALUE` (separate token) when a region is given.
    local args = {}
    if rect then
        args[1] = string.format("--refresh=top=%d,left=%d,width=%d,height=%d", rect.y, rect.x, rect.w, rect.h)
    else
        args[1] = "-s"
    end
    args[#args + 1] = "-W"
    args[#args + 1] = waveform or "GC16"
    args[#args + 1] = "-q"
    M.run(args)
end

-- ===================== dashboard-specific drawing =====================

--- Draws the bottom nav bar (Today/Lists/Habits/Home) and returns its
--- hit_zones. Factored out of M.draw_dashboard() so M.clear_flash_message()
--- below can also call it, to restore the real nav bar after a toast
--- auto-dismisses -- see that function's doc comment for why a toast
--- overlays this exact region. Explicitly clears its own background to
--- WHITE first (draw_dashboard's caller already did a full-screen white
--- clear before calling this, so that's a no-op there, but
--- clear_flash_message() calls this WITHOUT a prior full-screen clear,
--- specifically to erase whatever the toast drew here -- this function
--- has to be safe to call standalone, not just as part of a full redraw).
local function draw_nav_bar()
    local hit_zones = {}
    local nav_y = L.nav_y
    M.fill_rect(0, nav_y, L.screen_w, L.nav_bar_h, "WHITE")
    M.fill_rect(0, nav_y, L.screen_w, 2, "BLACK")
    local tab_w = math.floor(L.screen_w / L.nav_tab_count)
    local tabs = { "Today", "Lists", "Habits", "Home" }
    for i, name in ipairs(tabs) do
        local tab_x = (i - 1) * tab_w
        if name == "Today" then
            M.fill_rect(tab_x, nav_y + 2, tab_w, L.nav_bar_h - 2, "BLACK")
            M.draw_text(tab_x + 20, nav_y + 20, name, { size = 1, fg = "WHITE", bg = "BLACK" })
        else
            -- Not implemented yet -- tapping just raises a "coming soon"
            -- toast (see daemon.lua's handle_tap). Rendered in a muted
            -- gray rather than full black so it reads as unavailable
            -- rather than as an equally-valid unselected tab; the active
            -- tab (inverted black/white) and the disabled tabs (gray) are
            -- now visually distinct from each other in both directions,
            -- not just "not currently selected".
            M.draw_text(tab_x + 20, nav_y + 20, name, { size = 1, fg = "GRAY6" })
        end
        hit_zones[#hit_zones + 1] = {
            kind = "nav_tab", name = name,
            x = tab_x, y = nav_y, w = tab_w, h = L.nav_bar_h,
        }
    end
    return hit_zones
end

--- Renders the full dashboard from the current state snapshot (the exact
--- shape documented in backend/README.md's "Backend -> Kindle" section)
--- plus connection status. Returns a `hit_zones` table describing every
--- tappable pixel rectangle and what it means, so daemon.lua can hit-test
--- raw touch coordinates against it after this draw.
---
--- state may be nil (not connected yet / no data received yet), in which
--- case a "connecting..." placeholder is drawn instead of task rows.
---
--- task_page (1-based, optional, default 1): which page of tasks to show
--- when there are more than L.max_visible_tasks. Returns a second value,
--- the page actually rendered (clamped to however many pages currently
--- exist) -- callers should store this back as their own task_page, so
--- staying on an out-of-range page after the task list shrinks doesn't
--- silently show nothing.
---
--- armed_delete_id (optional): the id of a task currently in the
--- "tap again to delete" armed state (see daemon.lua's handle_tap),
--- drawn with a distinct highlighted row + inverted delete zone so it's
--- visually unambiguous which row a second tap will delete.
function M.draw_dashboard(state, conn_status, task_page, armed_delete_id)
    local hit_zones = {}
    local page = task_page or 1

    M.fill_rect(0, 0, L.screen_w, L.screen_h, "WHITE")

    -- --- header: time (primary) + date/status row (secondary) ---
    local now = os.date("*t")
    local time_str = string.format("%02d:%02d", now.hour, now.min)
    local date_str = os.date("%A, %d %B")

    M.draw_text(L.margin, L.header_y, time_str, { size = L.time_font_size })
    M.draw_text(L.margin, L.date_y, date_str, { size = L.date_font_size })

    -- Connection status: don't give "everything is fine" the same visual
    -- weight as "something needs your attention". ONLINE is the expected,
    -- default state, so it's drawn as plain small text; CONNECTING/
    -- OFFLINE get an inverted badge (the same black-bg/white-text
    -- treatment as the active nav tab below) so the one status worth
    -- actually noticing -- your data might be stale -- stands out instead
    -- of being just another same-weight corner label every redraw.
    local badge_x = L.screen_w - L.status_badge_w - L.margin
    if conn_status == "open" then
        M.draw_text(badge_x + L.gap_xs, L.status_text_y, "ONLINE", { size = L.status_font_size })
    else
        local status_text = conn_status == "connecting" and "CONNECTING" or "OFFLINE"
        M.fill_rect(badge_x, L.status_badge_y, L.status_badge_w, L.status_badge_h, "BLACK")
        M.draw_text(badge_x + L.gap_xs, L.status_text_y, status_text,
            { size = L.status_font_size, fg = "WHITE", bg = "BLACK" })
    end

    M.fill_rect(L.margin, L.divider_y, L.screen_w - 2 * L.margin, L.divider_h, "BLACK")

    -- --- TODAY section ---
    M.draw_text(L.margin, L.today_label_y, "TODAY", { size = 2 })

    local y = L.task_row_first_y
    if not state then
        M.draw_text(L.margin, y, "Waiting for data from laptop...", { size = 1 })
    else
        local tasks = state.tasks or {}

        -- Not-done tasks first, done tasks sink to the bottom -- a manual
        -- stable partition rather than table.sort with a "not done"
        -- comparator, since Lua's table.sort is NOT guaranteed stable and
        -- could otherwise reorder same-status tasks against each other on
        -- every redraw for no reason.
        local sorted_tasks = {}
        do
            local done_tasks = {}
            for _, t in ipairs(tasks) do
                if t.done then
                    done_tasks[#done_tasks + 1] = t
                else
                    sorted_tasks[#sorted_tasks + 1] = t
                end
            end
            for _, t in ipairs(done_tasks) do
                sorted_tasks[#sorted_tasks + 1] = t
            end
        end

        local total = #sorted_tasks
        local total_pages = math.max(1, math.ceil(total / L.max_visible_tasks))
        if page > total_pages then page = total_pages end
        if page < 1 then page = 1 end
        local start_idx = (page - 1) * L.max_visible_tasks + 1
        local end_idx = math.min(start_idx + L.max_visible_tasks - 1, total)

        local shown = 0
        for idx = start_idx, end_idx do
            local task = sorted_tasks[idx]
            local row_y = y + shown * (L.task_row_h + L.task_row_gap)
            local is_armed = (armed_delete_id ~= nil and task.id == armed_delete_id)
            local row_bg = is_armed and "GRAY6" or "WHITE"

            M.fill_rect(L.margin, row_y, L.screen_w - 2 * L.margin, L.task_row_h, row_bg)

            -- Checkbox: outline simulated as a filled square with a
            -- smaller white square inset, since fbink's CLI has no
            -- generic outline-only-rect primitive. Not-done reads as a
            -- hollow ring (tap me); done reads as a solid filled square
            -- with a mark (already handled) -- the two states are
            -- visually opposite (hollow vs. solid), not just "same box,
            -- different label", which is what actually makes the
            -- checked/unchecked distinction legible at a glance. The
            -- ring is drawn a bit thicker than before (task_checkbox_border,
            -- was a flat 4px) since a thin ring is easy to lose at 167ppi.
            local box_y = row_y + L.gap_xs -- (task_row_h - task_checkbox_w) / 2, centered
            M.fill_rect(L.margin, box_y, L.task_checkbox_w, L.task_checkbox_w, "BLACK")
            if task.done then
                -- box_y + 12 vertically centers a real size-2 (16px tall)
                -- "X" within the 40px checkbox: (40-16)/2 = 12.
                M.draw_text(L.margin + 6, box_y + 12, "X", { size = 2, fg = "WHITE", bg = "BLACK" })
            else
                local inset = L.task_checkbox_border
                M.fill_rect(L.margin + inset, box_y + inset,
                    L.task_checkbox_w - 2 * inset, L.task_checkbox_w - 2 * inset, row_bg)
            end

            local label = task.text or ""
            if task.done then label = label .. "  (done)" end
            -- Rough length cap so long task text (e.g. pasted from
            -- Telegram) doesn't visually run into the delete zone at the
            -- row's right edge -- not pixel-measured against the real
            -- font, so treat 34 as an estimate to revisit once this is
            -- actually on the device (see this file's header comment for
            -- the project's convention on flagging unmeasured guesses).
            local max_label_chars = 34
            if #label > max_label_chars then
                label = label:sub(1, max_label_chars - 1) .. "..."
            end
            M.draw_text(L.margin + L.task_checkbox_w + L.gap_sm, row_y + 14, label,
                { size = 1, bg = row_bg })

            -- Delete zone ("x") at the row's right edge. First tap arms
            -- it (handled in daemon.lua's handle_tap, which passes
            -- armed_delete_id back into the next draw_dashboard call);
            -- this function only draws whichever state it's told about.
            -- Uses plain ASCII "x" rather than a "times" glyph -- same
            -- reasoning as the checkbox's plain "X" above, no assumption
            -- about which non-ASCII glyphs fbink's compiled-in font
            -- actually has.
            local del_x = L.screen_w - L.margin - L.task_delete_w
            if is_armed then
                M.fill_rect(del_x, row_y, L.task_delete_w, L.task_row_h, "BLACK")
                M.draw_text(del_x + 12, row_y + 14, "x", { size = 2, fg = "WHITE", bg = "BLACK" })
            else
                M.draw_text(del_x + 12, row_y + 14, "x", { size = 2, fg = "BLACK", bg = row_bg })
            end
            hit_zones[#hit_zones + 1] = {
                kind = "delete_task_zone",
                id = task.id,
                x = del_x, y = row_y, w = L.task_delete_w, h = L.task_row_h,
            }

            -- Toggle zone is shrunk to stop before the delete zone (with
            -- a small gap) rather than spanning the full row width, so
            -- the two hit zones never overlap and a tap unambiguously
            -- hits exactly one of them.
            local toggle_w = L.screen_w - 2 * L.margin - L.task_delete_w - L.gap_xs
            hit_zones[#hit_zones + 1] = {
                kind = "toggle_task",
                id = task.id,
                x = L.margin, y = row_y, w = toggle_w, h = L.task_row_h,
            }
            shown = shown + 1
        end
        if shown == 0 then
            M.draw_text(L.margin, y, "No tasks yet.", { size = 1 })
            shown = 1 -- treat the message as occupying one row slot, so
                      -- the "+ Add Task" row below lands under it instead
                      -- of drawing on top of it
        end

        -- "See more" row: only shown when tasks don't all fit on one
        -- page. Tapping it cycles to the next page, wrapping back to
        -- page 1 after the last one -- a single button is enough to
        -- browse the whole list without needing a separate "back".
        if total_pages > 1 then
            local more_row_y = y + shown * (L.task_row_h + L.task_row_gap)
            local next_page = (page % total_pages) + 1
            M.draw_text(L.margin, more_row_y + 14,
                string.format("See more tasks (page %d/%d)", page, total_pages), { size = 1 })
            hit_zones[#hit_zones + 1] = {
                kind = "see_more_tasks",
                next_page = next_page,
                x = L.margin, y = more_row_y, w = L.screen_w - 2 * L.margin, h = L.task_row_h,
            }
            shown = shown + 1
        end

        -- "+ Add Task": always shown once we have task state to show at
        -- all (see the doc comment above for why this doesn't appear on
        -- the very first "waiting for data" placeholder screen), as its
        -- own row directly below whatever else was just drawn (tasks,
        -- then "see more" if present). See max_visible_tasks's comment
        -- above for how the row budget was resized to always leave room
        -- for this without pushing anything off-screen.
        local add_row_y = y + shown * (L.task_row_h + L.task_row_gap)
        M.fill_rect(L.margin, add_row_y, L.screen_w - 2 * L.margin, L.task_row_h, "WHITE")
        M.draw_text(L.margin, add_row_y + 18, "+ Add Task", { size = 2 })
        hit_zones[#hit_zones + 1] = {
            kind = "add_task_button",
            x = L.margin, y = add_row_y, w = L.screen_w - 2 * L.margin, h = L.task_row_h,
        }
        shown = shown + 1
    end

    -- --- CLAUDE USAGE card ---
    -- Shows claude.ai's own "Current session" 5-hour rate-limit percentage
    -- (via the unofficial endpoint in backend/claude_session_usage.py),
    -- NOT the org-level Admin API token count that used to live in this
    -- same card slot -- see that module's docstring for why these are
    -- different data sources. Content fits within card_box_y+16..+72 of
    -- usage_card_h's 78px (see usage_card_h's own comment for why it grew
    -- from the original 74).
    --
    -- Position is FIXED (L.usage_card_label_y/box_y, computed once near
    -- the top of this file) rather than dynamic -- see that computation's
    -- own comment for why. Deliberately does NOT read `y`/`shown` from
    -- the task-list block above at all anymore.
    local card_y = L.usage_card_label_y
    M.draw_text(L.margin, card_y, "CLAUDE USAGE", { size = 2 })

    local card_box_y = L.usage_card_box_y
    M.fill_rect(L.margin, card_box_y, L.screen_w - 2 * L.margin, L.usage_card_h, "GRAY6")

    local session_percent = 0
    local resets_label = ""
    if state and state.session_usage then
        session_percent = state.session_usage.percent or 0
        resets_label = state.session_usage.resets_label or ""
    end
    if session_percent < 0 then session_percent = 0 end
    if session_percent > 100 then session_percent = 100 end

    local content_x = L.margin + L.gap_sm
    local content_w = (L.screen_w - 2 * L.margin) - 2 * L.gap_sm

    -- Row 1 (card_box_y+16): "Current session" (left) + "N% used" (right,
    -- right-aligned flush with the progress bar's right edge below using
    -- CARD_CHAR_W_S1's now-confirmed-on-hardware glyph width).
    M.draw_text(content_x, card_box_y + 16, "Current session", { size = 1, fg = "WHITE", bg = "GRAY6" })
    local percent_str = string.format("%d%% used", session_percent)
    local percent_x = content_x + content_w - (#percent_str * CARD_CHAR_W_S1)
    M.draw_text(percent_x, card_box_y + 16, percent_str, { size = 1, fg = "WHITE", bg = "GRAY6" })

    -- Row 2 (card_box_y+32, h=14): horizontal progress bar. A 1px BLACK
    -- outline around the WHITE track (2026-08-04, UI review feedback) --
    -- without it, a near-0% bar was only distinguishable from the card's
    -- own GRAY6 background by a subtle shade difference, easy to miss on
    -- e-ink's flat, non-anti-aliased rendering. BLACK fill for the used
    -- portion draws on top, unaffected.
    local bar_y = card_box_y + 32
    local bar_h = 14
    M.fill_rect(content_x - 1, bar_y - 1, content_w + 2, bar_h + 2, "BLACK")
    M.fill_rect(content_x, bar_y, content_w, bar_h, "WHITE")
    local fill_w = math.floor(content_w * session_percent / 100)
    if fill_w > 0 then
        M.fill_rect(content_x, bar_y, fill_w, bar_h, "BLACK")
    end

    -- Row 3 (card_box_y+54): "Resets in X hr Y min" (pre-formatted
    -- server-side, see claude_session_usage.py) on the left, and the
    -- Refresh button -- a square BLACK icon button, not text-in-a-box --
    -- on the right. Forces an immediate re-fetch instead of waiting up to
    -- CLAUDE_SESSION_POLL_INTERVAL_SECONDS (5 min, see backend/config.py)
    -- for the next automatic poll. The backend rate-limits this itself
    -- (see claude_session_usage.py's refresh_now) -- a rejected repeat
    -- tap comes back as a generic error action, which daemon.lua already
    -- turns into a toast (see its "ws: backend rejected an action"
    -- handling), no daemon.lua UI changes needed for that path.
    --
    -- CHANGED (2026-08-04, user feedback after seeing it live): user
    -- asked for a real "backward spiral arrow" refresh icon instead of a
    -- text label. Checked FBInk's actual capabilities on this device
    -- before attempting it (`fbink --help` banner line): this build
    -- reports `Image=No` -- bitmap/PNG blitting isn't compiled in at
    -- all, so there's no way to ship a real icon image -- and
    -- `Unifont=No`, meaning broad Unicode glyph coverage (the ↻ codepoint
    -- a TTF/symbol font might otherwise provide) isn't reliably available
    -- either. The only real drawing primitive this file has is
    -- M.fill_rect (flat rectangles). So: a small hand-built pixel-art
    -- circular-arrow icon, drawn as a fixed list of WHITE rects on the
    -- BLACK button -- an incomplete ring (the "arc") left open on the
    -- bottom-right, plus a small wedge (the "arrowhead") where the ring
    -- ends, suggesting clockwise rotation. This is a first-pass hand-
    -- placed design (no way to preview pixel art without hardware, same
    -- caveat as this file's other hand-tuned-then-hardware-checked
    -- values) -- adjust REFRESH_ICON_RECTS below if it doesn't read
    -- clearly as "refresh" on the actual screen.
    local row3_y = card_box_y + 54
    local resets_text = (resets_label ~= "" and resets_label) or "Not yet updated"
    M.draw_text(content_x, row3_y + 5, resets_text, { size = 1, fg = "WHITE", bg = "GRAY6" })

    local refresh_btn_size = 22
    local refresh_btn_x = content_x + content_w - refresh_btn_size
    M.fill_rect(refresh_btn_x, row3_y, refresh_btn_size, refresh_btn_size, "BLACK")
    -- Each entry is {x, y, w, h}, relative to the button's top-left
    -- corner. Rows 1-2 + 5-6 form the ring's left/right sides (widest
    -- near the middle, like a circle), row 0 is the top arc, row 3 is
    -- the bottom-left arc -- the bottom-RIGHT is deliberately left empty
    -- (the "gap" a refresh arrow's ring is always missing), and the last
    -- two entries are the arrowhead (a shrinking wedge) sitting right at
    -- the top of that gap, pointing into it.
    for _, r in ipairs(REFRESH_ICON_RECTS) do
        M.fill_rect(refresh_btn_x + r[1], row3_y + r[2], r[3], r[4], "WHITE")
    end
    hit_zones[#hit_zones + 1] = {
        kind = "refresh_usage_button",
        -- Padded 1px beyond the visible box in every direction -- still
        -- safely clear of the progress bar above (bar bottom is
        -- card_box_y+46, this zone's top is card_box_y+53) and the
        -- card's own bottom edge (box bottom is card_box_y+78, this
        -- zone's bottom is card_box_y+77).
        x = refresh_btn_x - 1, y = row3_y - 1, w = refresh_btn_size + 2, h = refresh_btn_size + 2,
    }

    -- --- footer controls: Exit Dashboard / Restart SSH ---
    -- Anchored to L.footer_y (a fixed value computed once, see its
    -- definition above) rather than a per-call local, specifically so
    -- M.flash_message() below can share the exact same position instead
    -- of hand-computing its own -- that drift is what caused the toast
    -- to visibly overlap these two buttons on real hardware. Anchoring
    -- from the fixed bottom edge (not down from the usage card above)
    -- also guarantees this row is always in the same place and never
    -- collides with a shorter gap on a task-heavy day.
    do
        local footer_y = L.footer_y
        local footer_btn_w = math.floor((L.screen_w - 2 * L.margin - L.gap_xs) / 2)
        -- Vertically center the size-1 (real 8px-tall) label within
        -- whatever footer_controls_h currently is, rather than a fixed
        -- offset -- keeps the text centered if this height is tuned again.
        local footer_label_y = footer_y + math.floor((L.footer_controls_h - 8) / 2)

        M.fill_rect(L.margin, footer_y, footer_btn_w, L.footer_controls_h, "GRAY6")
        M.draw_text(L.margin + L.gap_xs, footer_label_y, "Exit Dashboard",
            { size = 1, fg = "WHITE", bg = "GRAY6" })
        hit_zones[#hit_zones + 1] = {
            kind = "exit_dashboard_button",
            x = L.margin, y = footer_y, w = footer_btn_w, h = L.footer_controls_h,
        }

        local ssh_btn_x = L.margin + footer_btn_w + L.gap_xs
        M.fill_rect(ssh_btn_x, footer_y, footer_btn_w, L.footer_controls_h, "GRAY6")
        M.draw_text(ssh_btn_x + L.gap_xs, footer_label_y, "Restart SSH",
            { size = 1, fg = "WHITE", bg = "GRAY6" })
        hit_zones[#hit_zones + 1] = {
            kind = "restart_ssh_button",
            x = ssh_btn_x, y = footer_y, w = footer_btn_w, h = L.footer_controls_h,
        }
    end

    -- --- bottom nav bar ---
    for _, z in ipairs(draw_nav_bar()) do
        hit_zones[#hit_zones + 1] = z
    end

    M.flush("GC16")
    return hit_zones, page
end

--- Cheap "toast" message flashed on screen -- used for stub nav taps
--- ("Lists is coming soon"), not-connected warnings, and Restart SSH
--- results: every current caller is pure FYI with no clickable function
--- of its own, so it's safe for this to sit on top of something else
--- for a few seconds. daemon.lua auto-dismisses it after a few seconds
--- via M.clear_flash_message() below -- this function only draws it.
---
--- Design history, two rounds of real hardware feedback (2026-08-02):
--- (1) originally overlaid the Exit Dashboard/Restart SSH footer row,
--- but that meant colliding with two buttons a user might actually want
--- to tap right after reading the toast, PLUS a real rendering bug (same
--- GRAY6-on-GRAY6 tone as the buttons meant a fast "A2" partial refresh
--- never actually repainted the background, only new text glyphs, so old
--- button-label pixels stayed visible mixed in with the new toast text
--- -- not a z-order bug, a "background never actually changed" bug).
--- (2) moved to overlay the bottom nav bar instead (Today/Lists/Habits/
--- Home) per direct user request, since none of those tabs do anything
--- clickable-and-consequential either (Today is already the active tab;
--- the rest are already "coming soon" stubs) -- a toast temporarily
--- covering them costs nothing a user would miss. Uses BLACK (a real
--- tone change, not reused from any current tab styling) and "GC16"
--- (full-quality, guaranteed-complete refresh, still only a partial-rect
--- flush so it stays fast) to avoid a repeat of the same ghosting bug.
function M.flash_message(text)
    local y = L.nav_y
    local h = L.nav_bar_h
    M.fill_rect(0, y, L.screen_w, h, "BLACK")
    M.draw_text(L.margin, y + math.floor((h - 8) / 2), text, { size = 1, fg = "WHITE", bg = "BLACK" })
    M.flush("GC16", { x = 0, y = y, w = L.screen_w, h = h })
end

--- Restores the real nav bar after a toast (M.flash_message() above)
--- auto-dismisses. Deliberately does NOT redraw the whole dashboard --
--- the nav bar's own content is fully static (always the same 4 tabs,
--- "Today" always the active one in this v1), so a full dashboard redraw
--- would cost an unnecessary full-screen flash just to restore a strip
--- that never needed the rest of the screen redrawn with it. Returns
--- nothing: the nav bar's hit_zones never change (fixed position, fixed
--- tabs), so daemon.lua's existing current_hit_zones from the last full
--- M.draw_dashboard() call are still correct and don't need updating.
function M.clear_flash_message()
    draw_nav_bar()
    M.flush("GC16", { x = 0, y = L.nav_y, w = L.screen_w, h = L.nav_bar_h })
end

-- ===================== on-screen keyboard (Add Task flow) =====================
--
-- v1 deliberately supports lowercase letters + space + backspace only --
-- no shift/symbols/numbers, no autocomplete. Task text is free-form and
-- this keeps both the key layout and the code generating it simple; a v2
-- could add a shift-for-symbols row without changing the structure here.
--
-- NOTE, same spirit as this file's header comment: unlike the task rows
-- and nav bar (whose pixel positions were measured against real
-- hardware), the exact horizontal centering of each key's LABEL within
-- its key box below is an ESTIMATE (KBD_CHAR_W_ESTIMATE), not something
-- measured on the device -- there was no confirmed per-glyph width figure
-- to build on, only the confirmed 8px/unit TEXT HEIGHT this file's header
-- comment already established. If key labels look visibly off-center
-- once this is running on real hardware, adjust KBD_CHAR_W_ESTIMATE
-- rather than the per-key math below (which is otherwise computed, not
-- hand-placed, for the same "don't hand-derive pixel arithmetic that
-- can't be test-run before reaching the device" reason as the rest of
-- this section).
local KBD_CHAR_W_ESTIMATE = 12 -- approx width in px of one glyph at size=2

L.kbd_key_w = 53 -- effectively maxed out already: row 1 has 10 keys, and
                  -- (usable_w - 9*kbd_key_gap)/10 = 53.4px is the hard
                  -- ceiling for a 10-key row to fit within the screen's
                  -- side margins at all -- so any growth in tap-target
                  -- size below has to come from height, not width.
L.kbd_key_gap = 2

-- GREW from 64/10 to 76/14 (2026-08-02) for the same reason
-- footer_controls_h grew above: bigger targets and more separation
-- between rows matter most on exactly the controls a locked-out/typing
-- user is relying on, on a touch panel whose calibration is unconfirmed.
-- As built, the keyboard's content (title + preview + 4 key rows) ended
-- at y=414 on this 800px screen -- roughly half the screen unused. Filling
-- that space entirely via height alone was rejected: at key_w=53 (see
-- above, already near its ceiling), a key tall enough to consume all of
-- it would be ~150px tall -- a 1:2.8 aspect ratio that stops reading as a
-- keyboard key. 76/14 is a deliberate middle ground (+19% key height,
-- +40% row gap for extra mis-tap margin) that still leaves real but
-- smaller unused space below (326px, was 386px) -- kept at the BOTTOM
-- rather than centering the whole block, so the title/preview stay
-- top-anchored like every other screen in this app (dashboard header,
-- confirm_exit's title). That also matches the existing precedent set by
-- draw_confirm_exit below, whose Cancel/Confirm buttons are already
-- deliberately placed mid-screen with blank space above them rather than
-- packed tight under the descriptive text.
L.kbd_key_h = 76
L.kbd_row_gap = 14
-- Backspace occupies the last slot of row 3, sized as 2 letter-keys +
-- 1 gap -- this makes row 3 (7 letters + backspace) come out to exactly
-- the same total width as row 2 (9 letters), so the two rows end up
-- flush-aligned once layout_key_row() centers each of them independently.
L.kbd_backspace_w = 2 * L.kbd_key_w + L.kbd_key_gap
L.kbd_title_y = L.margin
L.kbd_preview_y = L.margin + 16 + L.gap_sm -- title height (real size-2: 16) + gap_sm
L.kbd_preview_h = 48
L.kbd_top_y = L.kbd_preview_y + L.kbd_preview_h + L.gap_lg
L.kbd_action_gap = L.gap_xs -- was a bare literal 8; L now exists at this
                             -- point in the file (unlike footer_controls_gap
                             -- above, which is set inside the M.LAYOUT table
                             -- literal itself and can't reach L yet), so
                             -- there's no reason not to reuse the named gap.
L.kbd_cancel_w = 110
L.kbd_confirm_w = 110

local KBD_ROW1 = { "q", "w", "e", "r", "t", "y", "u", "i", "o", "p" }
local KBD_ROW2 = { "a", "s", "d", "f", "g", "h", "j", "k", "l" }
-- Row 3 as laid out on screen is these 7 letters PLUS a trailing
-- backspace key -- 8 zones total, not 7, hence the extra trailing
-- placeholder entry below. Passing a plain 7-letter list into
-- layout_key_row() with a `last_w` override would instead widen the
-- LAST LETTER's ("m") own box into the backspace-sized one, silently
-- dropping "m" from the keyboard entirely rather than adding a distinct
-- 8th box next to it. The placeholder's label is never drawn --
-- draw_keyboard() special-cases the last zone in this row as the
-- backspace key instead of treating it like a normal letter.
local KBD_ROW3_WITH_BACKSPACE = { "z", "x", "c", "v", "b", "n", "m", "DEL" }

--- Lays out `#labels` equal-width key boxes (plus one optional wider
--- final box, e.g. backspace) horizontally centered within the usable
--- screen width. Centering is computed here rather than hand-placed --
--- hand-computing pixel offsets for a 10-key row without being able to
--- run this code before it reaches the device is exactly the kind of
--- arithmetic that's easy to get subtly wrong.
local function layout_key_row(labels, y, last_w)
    local usable_w = L.screen_w - 2 * L.margin
    local n = #labels
    local row_w = 0
    local widths = {}
    for i = 1, n do
        widths[i] = (last_w and i == n) and last_w or L.kbd_key_w
        row_w = row_w + widths[i]
        if i < n then row_w = row_w + L.kbd_key_gap end
    end
    local x = L.margin + math.floor((usable_w - row_w) / 2)
    local zones = {}
    for i, label in ipairs(labels) do
        zones[#zones + 1] = { label = label, x = x, y = y, w = widths[i], h = L.kbd_key_h }
        x = x + widths[i] + L.kbd_key_gap
    end
    return zones
end

--- Redraws just the preview strip (everything else on screen is left
--- alone). Shared by the full M.draw_keyboard() below and the fast
--- per-keypress M.update_keyboard_preview().
local function draw_preview_text(buffer)
    M.fill_rect(L.margin, L.kbd_preview_y, L.screen_w - 2 * L.margin, L.kbd_preview_h, "WHITE")
    local display = buffer
    local max_chars = 40 -- rough estimate, not pixel-measured -- see this
                          -- section's header note on unmeasured guesses
    if #display > max_chars then
        display = "..." .. display:sub(-(max_chars - 3))
    end
    if display == "" then
        M.draw_text(L.margin + L.gap_xs, L.kbd_preview_y + 16, "(type below)", { size = 2, fg = "GRAY6" })
    else
        M.draw_text(L.margin + L.gap_xs, L.kbd_preview_y + 16, display, { size = 2 })
    end
end

-- CONFIRMED ON HARDWARE (2026-08-02, live device test): "A2" left visible,
-- non-self-clearing ghosting of the previous preview content (most
-- noticeably the gray "(type below)" placeholder showing through the
-- first typed characters) -- A2 is tuned for fast animation-style
-- updates (page turns) and trades a lot of pixel-settling quality for
-- speed, more than this single-line text strip needs. "DU" (Direct
-- Update) is the standard fbink/e-ink recommendation for black-on-white
-- text specifically -- still fast enough for per-keystroke feedback, but
-- settles pixels more completely, so ghosting should be markedly
-- reduced. Belt-and-suspenders: every PREVIEW_DEGHOST_INTERVAL-th
-- keystroke gets a full-quality "GC16" refresh of just this strip
-- instead of "DU", to actively clear out whatever residue accumulates
-- over a longer typing session rather than letting it compound
-- indefinitely -- costs one brief visible flash every few keystrokes,
-- not a full-screen redraw, so it stays cheap.
local PREVIEW_DEGHOST_INTERVAL = 8
local _preview_update_count = 0

--- Fast partial-refresh update of ONLY the preview strip, for per-
--- keypress feedback -- mind e-ink performance (see this file's flush()
--- doc comment on GC16 vs A2/DU). Does NOT touch the keyboard layout
--- below it and does NOT return hit_zones: the caller (daemon.lua) keeps
--- using the hit_zones from the last full M.draw_keyboard() call, since
--- key positions never change while typing, only the buffer contents do.
function M.update_keyboard_preview(buffer)
    draw_preview_text(buffer)
    _preview_update_count = _preview_update_count + 1
    local waveform = "DU"
    if _preview_update_count % PREVIEW_DEGHOST_INTERVAL == 0 then
        waveform = "GC16"
    end
    M.flush(waveform, { x = L.margin, y = L.kbd_preview_y, w = L.screen_w - 2 * L.margin, h = L.kbd_preview_h })
end

--- Full redraw of the Add Task on-screen keyboard. Returns hit_zones:
--- {kind="keyboard_key", char=...}, {kind="keyboard_backspace"},
--- {kind="keyboard_space"}, {kind="keyboard_cancel"}, {kind="keyboard_confirm"}.
function M.draw_keyboard(buffer)
    local hit_zones = {}
    M.fill_rect(0, 0, L.screen_w, L.screen_h, "WHITE")

    -- Reset the deghost counter: this full-screen GC16 draw already
    -- settles every pixel at full quality, so the next few keystrokes'
    -- fast DU updates are starting from a clean baseline, not whatever
    -- count a previous Add Task session left off at.
    _preview_update_count = 0

    M.draw_text(L.margin, L.kbd_title_y, "Add Task", { size = 2 })
    draw_preview_text(buffer)

    local row1_y = L.kbd_top_y
    local row2_y = row1_y + L.kbd_key_h + L.kbd_row_gap
    local row3_y = row2_y + L.kbd_key_h + L.kbd_row_gap
    local row4_y = row3_y + L.kbd_key_h + L.kbd_row_gap

    local function draw_letter_key(zone)
        M.fill_rect(zone.x, zone.y, zone.w, zone.h, "GRAY6")
        -- Rough visual centering of a single glyph -- see this section's
        -- header note on KBD_CHAR_W_ESTIMATE.
        local tx = zone.x + math.floor((zone.w - KBD_CHAR_W_ESTIMATE) / 2)
        local ty = zone.y + math.floor((zone.h - 16) / 2) -- 16 = real size-2 text height
        M.draw_text(tx, ty, zone.label, { size = 2, fg = "WHITE", bg = "GRAY6" })
        hit_zones[#hit_zones + 1] = {
            kind = "keyboard_key", char = zone.label,
            x = zone.x, y = zone.y, w = zone.w, h = zone.h,
        }
    end

    for _, z in ipairs(layout_key_row(KBD_ROW1, row1_y)) do draw_letter_key(z) end
    for _, z in ipairs(layout_key_row(KBD_ROW2, row2_y)) do draw_letter_key(z) end

    local row3_zones = layout_key_row(KBD_ROW3_WITH_BACKSPACE, row3_y, L.kbd_backspace_w)
    for i, z in ipairs(row3_zones) do
        if i == #row3_zones then
            -- last zone in row3 is the wider backspace key, not a letter
            M.fill_rect(z.x, z.y, z.w, z.h, "GRAY6")
            M.draw_text(z.x + L.gap_sm, z.y + math.floor((z.h - 16) / 2), "DEL",
                { size = 2, fg = "WHITE", bg = "GRAY6" })
            hit_zones[#hit_zones + 1] = {
                kind = "keyboard_backspace", x = z.x, y = z.y, w = z.w, h = z.h,
            }
        else
            draw_letter_key(z)
        end
    end

    -- Bottom action row: Cancel | Space | Add. Add is drawn inverted-
    -- black like the active nav tab elsewhere in this file, so the one
    -- affirmative action on this screen reads as visually distinct from
    -- the neutral gray keys (same "opposite treatment = opposite
    -- meaning" convention as the task checkbox's hollow-vs-solid states).
    local usable_w = L.screen_w - 2 * L.margin
    local space_w = usable_w - L.kbd_cancel_w - L.kbd_confirm_w - 2 * L.kbd_action_gap
    local cancel_x = L.margin
    local space_x = cancel_x + L.kbd_cancel_w + L.kbd_action_gap
    local confirm_x = space_x + space_w + L.kbd_action_gap
    local label_y = row4_y + math.floor((L.kbd_key_h - 8) / 2) -- 8 = real size-1 text height

    M.fill_rect(cancel_x, row4_y, L.kbd_cancel_w, L.kbd_key_h, "GRAY6")
    M.draw_text(cancel_x + L.gap_sm, label_y, "Cancel", { size = 1, fg = "WHITE", bg = "GRAY6" })
    hit_zones[#hit_zones + 1] = {
        kind = "keyboard_cancel", x = cancel_x, y = row4_y, w = L.kbd_cancel_w, h = L.kbd_key_h,
    }

    M.fill_rect(space_x, row4_y, space_w, L.kbd_key_h, "GRAY6")
    M.draw_text(space_x + math.floor(space_w / 2) - 24, label_y, "SPACE", { size = 1, fg = "WHITE", bg = "GRAY6" })
    hit_zones[#hit_zones + 1] = {
        kind = "keyboard_space", x = space_x, y = row4_y, w = space_w, h = L.kbd_key_h,
    }

    M.fill_rect(confirm_x, row4_y, L.kbd_confirm_w, L.kbd_key_h, "BLACK")
    M.draw_text(confirm_x + L.gap_sm + 4, label_y, "Add", { size = 1, fg = "WHITE", bg = "BLACK" })
    hit_zones[#hit_zones + 1] = {
        kind = "keyboard_confirm", x = confirm_x, y = row4_y, w = L.kbd_confirm_w, h = L.kbd_key_h,
    }

    M.flush("GC16")
    return hit_zones
end

-- ===================== Exit Dashboard confirmation =====================
--
-- A dedicated full-screen confirm step, deliberately heavier-weight than
-- the double-tap-to-arm pattern used for task deletion above -- rebooting
-- the whole device is a bigger deal than deleting one task, so it gets a
-- harder-to-trigger-by-accident confirmation with explicit Cancel/Confirm
-- buttons rather than "tap the same small zone again".

function M.draw_confirm_exit()
    local hit_zones = {}
    M.fill_rect(0, 0, L.screen_w, L.screen_h, "WHITE")

    -- 24 below = real size-3 text height (8px/unit * 3, see this file's
    -- header comment); the two body lines are real size-1 text (8px) each
    -- stacked with gap_xs(8) of leading, i.e. gap_sm(16) = 8 + gap_xs --
    -- spelled out as +16 rather than +L.gap_xs+8 since it's leading
    -- between two lines of the SAME paragraph, not a gap between distinct
    -- elements (contrast the first +L.gap_sm below, which IS the gap
    -- between the title and the body text -- a real named-gap use).
    M.draw_text(L.margin, L.margin, "Exit Dashboard?", { size = 3 })
    M.draw_text(L.margin, L.margin + 24 + L.gap_sm,
        "This shuts down the dashboard and reboots", { size = 1 })
    M.draw_text(L.margin, L.margin + 24 + L.gap_sm + 16,
        "back to normal Kindle/KOReader reading mode.", { size = 1 })

    local btn_w = L.screen_w - 2 * L.margin
    local btn_h = 80
    local btn_y = math.floor(L.screen_h / 2)

    M.fill_rect(L.margin, btn_y, btn_w, btn_h, "GRAY6")
    M.draw_text(L.margin + L.gap_sm, btn_y + 30, "Cancel", { size = 2, fg = "WHITE", bg = "GRAY6" })
    hit_zones[#hit_zones + 1] = { kind = "confirm_exit_cancel", x = L.margin, y = btn_y, w = btn_w, h = btn_h }

    local btn2_y = btn_y + btn_h + L.gap_lg
    M.fill_rect(L.margin, btn2_y, btn_w, btn_h, "BLACK")
    M.draw_text(L.margin + L.gap_sm, btn2_y + 30, "Yes, Shut Down", { size = 2, fg = "WHITE", bg = "BLACK" })
    hit_zones[#hit_zones + 1] = { kind = "confirm_exit_yes", x = L.margin, y = btn2_y, w = btn_w, h = btn_h }

    M.flush("GC16")
    return hit_zones
end

--- One-shot terminal message drawn right before daemon.lua's actual
--- `sync; reboot` call -- NOT part of the ui_mode/hit_zones system, since
--- there is nothing left to tap once this is on screen.
function M.draw_shutdown_message()
    M.fill_rect(0, 0, L.screen_w, L.screen_h, "WHITE")
    M.draw_text(L.margin, math.floor(L.screen_h / 2) - 16, "Shutting down...", { size = 3 })
    M.flush("GC16")
end

return M
