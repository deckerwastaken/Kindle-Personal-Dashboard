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

    -- --- battery indicator (header, top-right, on the CLOCK's row) ---
    -- Placed on the clock's row rather than the date/status row below it
    -- because that row is the one piece of empty space in the header:
    -- "14:30" is 5 glyphs at size 4 = 160px, ending at x=184, leaving
    -- everything from there to the right margin unused. The date row
    -- underneath is already spoken for by the connection status badge.
    --
    -- Everything here is anchored to the RIGHT margin and grows leftward,
    -- so the percent text getting one character wider ("9%" -> "85%" ->
    -- "100%") never moves the battery glyph itself.
    battery_glyph_w = 36,  -- the body, excluding the terminal nub
    battery_glyph_h = 20,
    battery_nub_w = 4,
    battery_nub_h = 8,
    battery_border = 2,    -- outline thickness of the body
    battery_font_size = 2,
    -- pct <= this reads as "low". No hysteresis band: the usual reason
    -- to add one is to stop a value oscillating across the threshold from
    -- causing repeated repaints, but daemon.lua only repaints this
    -- region when the percentage NUMBER changes -- and a value bouncing
    -- 20/21/20 has already changed the digits, so the repaint happens
    -- regardless and hysteresis would buy nothing but state.
    battery_low_threshold = 20,

    -- --- pagination control (replaces the old "See more tasks" row) ---
    -- Occupies exactly one task_row_h slot, so the whole vertical budget
    -- derived in max_visible_tasks' comment above (and
    -- L.task_list_max_bottom_y, which depends on it) stays valid without
    -- recomputation -- this control drops into the slot the plain "see
    -- more" text row already occupied.
    pager_arrow_btn_w = 56,  -- square-ish 56x56 tap targets, in the
                              -- preferred 48-64 band rather than the 40
                              -- minimum: these are the two controls that
                              -- get hit repeatedly, on an IR panel whose
                              -- calibration is still unconfirmed.
    pager_cell_w = 48,       -- visual width of one page-number cell
    pager_cell_h = 48,
    pager_cell_gap = 8,
    -- 7 number slots. 8 slots at 44px wide would consume the available
    -- band exactly, but 44 sits under the 48px preferred tap size, and
    -- the 8th slot buys nothing once windowing is in play (see
    -- build_page_slots below) -- target size wins over tidier arithmetic.
    pager_max_slots = 7,
    pager_font_size = 2,

    -- --- LEARNING screen (its own full screen, reached from the nav bar) ---
    -- Shows courses and books only: no tasks, no usage card, no footer
    -- controls. Same 56/8 row rhythm as the task list, so the two
    -- screens feel like the same app.
    learn_row_h = 56,
    learn_row_gap = 8, -- = gap_xs
    -- NOTE: learn_rows_per_page is NOT set here -- it is computed from
    -- the geometry just below the table (currently 8). See there for why.
    learn_name_font_size = 2,
    learn_bar_h = 12,   -- the card's hero bar is 14; these stack 8 deep,
                         -- and 12 keeps the page from reading as a barcode
    learn_bar_top = 33, -- offset within the row, to the bar's OUTLINE
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
-- Battery geometry, computed once from the right margin, same
-- "derive it here, reference it everywhere" treatment as footer_y above.
-- L.battery_region_* is the rectangle draw_battery() owns outright: it
-- erases exactly this before drawing, and daemon.lua partial-refreshes
-- exactly this when only the battery changed. Width is sized to the
-- widest possible content ("100%" at size 2 starting at x=456) plus a
-- little slack, NOT hand-picked -- so it can't silently become too small
-- if the font size here is ever bumped.
L.battery_right_edge = L.screen_w - L.margin -- 576
L.battery_body_x = L.battery_right_edge - L.battery_glyph_w - L.battery_nub_w
L.battery_body_y = L.header_y + math.floor((8 * L.time_font_size - L.battery_glyph_h) / 2)
L.battery_center_y = L.battery_body_y + math.floor(L.battery_glyph_h / 2)
-- Right edge of the percent text. gap_sm (not gap_xs) of clearance to
-- the glyph: at 8px, the low-battery badge below -- which extends 6px
-- past the text -- would end 2px from the glyph outline, and two black
-- shapes that close together read as one smudge on e-ink.
L.battery_text_right = L.battery_body_x - L.gap_sm
L.battery_text_y = L.battery_center_y - math.floor(8 * L.battery_font_size / 2)
L.battery_region_x = L.battery_text_right - 4 * (8 * L.battery_font_size) - L.gap_xs
L.battery_region_y = L.header_y
L.battery_region_w = L.battery_right_edge - L.battery_region_x
L.battery_region_h = 8 * L.time_font_size

-- Pager geometry, computed once from the margins for the same reason as
-- everything else in this block. The number band is whatever is left
-- between the two arrow buttons, with gap_sm of breathing room on each
-- side; the number strip is then CENTERED inside it (see draw_pager) so
-- a 2-page pager doesn't leave a 300px void reading as a render failure.
L.pager_cell_pitch = L.pager_cell_w + L.pager_cell_gap
L.pager_left_arrow_x = L.margin
L.pager_right_arrow_x = L.screen_w - L.margin - L.pager_arrow_btn_w
L.pager_band_x = L.pager_left_arrow_x + L.pager_arrow_btn_w + L.gap_sm
L.pager_band_w = L.pager_right_arrow_x - L.gap_sm - L.pager_band_x

-- Learning screen geometry. The header deliberately lands on the SAME
-- y-positions as the dashboard's -- a size-2 secondary line at L.date_y
-- and the rule at L.divider_y -- so switching tabs doesn't visually
-- jolt, and content on both screens begins at the same y.
L.learn_title_y = L.margin
L.learn_summary_y = L.date_y
L.learn_row_first_y = L.divider_y + L.divider_h + L.gap_sm -- 122, = today_label_y
L.learn_row_pitch = L.learn_row_h + L.learn_row_gap
-- Pager pinned to the bottom, anchored UP from the nav bar, exactly like
-- L.footer_y on the dashboard -- so it never moves as the item count
-- changes, and hiding it (single page) moves nothing either.
L.learn_pager_y = L.screen_h - L.nav_bar_h - L.gap_lg - L.task_row_h

-- How many rows fit on one Learning page: COMPUTED from the space
-- actually available between the first row and the pinned pager row,
-- not hardcoded next to a comment claiming the arithmetic works out.
-- Currently 8.
--
-- This is deliberately a derivation rather than a constant plus an
-- assertion. An assertion here would have to live at module load, which
-- daemon.lua does NOT wrap in pcall -- so a future edit that grew
-- learn_row_h or moved the pager would stop the daemon from starting at
-- all, and since upstart is configured to respawn it, the symptom on the
-- device would be a boot loop against a blank screen with no way to read
-- the error. That is a far worse outcome than the layout bug it would be
-- catching. Computing the value instead makes the overflow impossible to
-- express, so there is nothing left to assert.
--
-- (This file's history is why the question comes up at all: see
-- max_visible_tasks' comment on the footer growing from 32 to 48px and
-- silently creating a -4px overlap that a comment had claimed was fine.)
L.learn_rows_per_page = math.floor(
    (L.learn_pager_y - L.gap_lg - L.learn_row_first_y + L.learn_row_gap) / L.learn_row_pitch)

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

-- Glyph width at any -S size, derived from the confirmed size-1 figure
-- above. FBInk scales its built-in font by whole-number multiples (the
-- same reason TEXT HEIGHT is a clean 8px per size unit, confirmed on
-- hardware), so an 8x8 cell at size 1 implies 8*size px per glyph.
--
-- PARTIALLY VERIFIED: size 1 = 8px is measured on hardware (see
-- CARD_CHAR_W_S1 above). The other sizes follow from FBInk's integer
-- scaling and are NOT separately measured -- check with
-- `fbink -E -S 2 "100%"` if any right-aligned size-2 text overhangs its
-- intended right edge, which is exactly the bug the CARD_CHAR_W_S1
-- measurement was introduced to fix on 2026-08-04.
--
-- This function is the single place the project answers "how wide is
-- this string". Every right-aligned or centered label in this file goes
-- through it, so a correction lands in one place instead of in each of
-- the (now several) call sites that need it.
local function char_w(size)
    return 8 * (size or 1)
end

local function text_w(str, size)
    return #str * char_w(size)
end

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

-- Pixel-art arrows for the pagination control, same technique and same
-- reason as REFRESH_ICON_RECTS above: this FBInk build has no image
-- support and no reliable Unicode, so there is no arrow glyph to draw
-- and flat rectangles are the only primitive available. Each entry is
-- {x, y, w, h} relative to the arrow's own top-left corner.
--
-- An 18x24 triangle approximated as six 4px-tall rows stepping 6px
-- horizontally. The two are exact mirrors: identical width sequence
-- (6, 12, 18, 18, 12, 6), with the LEFT arrow's rows right-aligned
-- inside the 18px box (apex on the left) and the RIGHT arrow's rows
-- left-aligned at x=0 (apex on the right). Both are symmetric about
-- their horizontal midline.
--
-- UNVERIFIED ON HARDWARE: at 167ppi a 6px horizontal step per 4px row is
-- roughly a 0.9mm jump, which should still read as a triangle rather
-- than a staircase -- but that's reasoning, not observation, exactly
-- like REFRESH_ICON_RECTS was shipped hand-placed and flagged for
-- adjustment. If it reads as steps, the finer version is twelve 2px rows
-- stepping 3px, at the cost of twice the fill_rect calls per arrow.
local PAGER_ARROW_LEFT = {
    { 12, 0, 6, 4 },
    { 6, 4, 12, 4 },
    { 0, 8, 18, 4 },
    { 0, 12, 18, 4 },
    { 6, 16, 12, 4 },
    { 12, 20, 6, 4 },
}
local PAGER_ARROW_RIGHT = {
    { 0, 0, 6, 4 },
    { 0, 4, 12, 4 },
    { 0, 8, 18, 4 },
    { 0, 12, 18, 4 },
    { 0, 16, 12, 4 },
    { 0, 20, 6, 4 },
}
local PAGER_ARROW_W = 18
local PAGER_ARROW_H = 24

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

-- The bottom nav bar's tabs, and which of them actually go somewhere.
-- "Today" and "Learning" are real screens; the rest still raise a
-- "coming soon" toast (see daemon.lua's handle_dashboard_tap).
--
-- "Learning" replaced "Lists" rather than being added as a fifth tab: a
-- fifth tab would shrink tab_w from 150 to 120px and re-flow a bar that
-- currently never moves, to make room for a stub nobody was using. At
-- size 1, "Learning" is 8 glyphs * 8px = 64px drawn at tab_x + 20, so it
-- ends 84px into a 150px tab -- comfortably inside it.
M.NAV_TABS = { "Today", "Learning", "Habits", "Home" }
M.NAV_TAB_IMPLEMENTED = { Today = true, Learning = true }

--- Draws the bottom nav bar and returns its hit_zones.
---
--- `active_tab` is the name of the tab to render as selected. It is a
--- REQUIRED argument in spirit: this used to hardcode "Today" as active,
--- which was correct when Today was the only screen and silently wrong
--- the moment a second one existed. Defaulting here (rather than erroring)
--- keeps a missed call site from blanking the bar, but every caller
--- passes it explicitly.
---
--- Factored out of M.draw_dashboard() so M.clear_flash_message() below
--- can also call it, to restore the real nav bar after a toast
--- auto-dismisses -- see that function's doc comment for why a toast
--- overlays this exact region. Explicitly clears its own background to
--- WHITE first (draw_dashboard's caller already did a full-screen white
--- clear before calling this, so that's a no-op there, but
--- clear_flash_message() calls this WITHOUT a prior full-screen clear,
--- specifically to erase whatever the toast drew here -- this function
--- has to be safe to call standalone, not just as part of a full redraw).
local function draw_nav_bar(active_tab)
    active_tab = active_tab or M.NAV_TABS[1]
    local hit_zones = {}
    local nav_y = L.nav_y
    M.fill_rect(0, nav_y, L.screen_w, L.nav_bar_h, "WHITE")
    M.fill_rect(0, nav_y, L.screen_w, 2, "BLACK")
    local tab_w = math.floor(L.screen_w / L.nav_tab_count)
    for i, name in ipairs(M.NAV_TABS) do
        local tab_x = (i - 1) * tab_w
        if name == active_tab then
            M.fill_rect(tab_x, nav_y + 2, tab_w, L.nav_bar_h - 2, "BLACK")
            M.draw_text(tab_x + 20, nav_y + 20, name, { size = 1, fg = "WHITE", bg = "BLACK" })
        elseif M.NAV_TAB_IMPLEMENTED[name] then
            -- A real, reachable screen that just isn't the current one:
            -- plain black text. Previously every non-active tab was gray,
            -- which was accurate when they were all stubs but would now
            -- tell the user that a working screen is unavailable.
            M.draw_text(tab_x + 20, nav_y + 20, name, { size = 1 })
        else
            -- Not implemented yet -- tapping just raises a "coming soon"
            -- toast. Rendered in a muted gray rather than full black so
            -- it reads as unavailable rather than as an equally-valid
            -- unselected tab. With the middle case above, the bar now
            -- distinguishes three real states: active (inverted),
            -- available (black), unavailable (gray).
            M.draw_text(tab_x + 20, nav_y + 20, name, { size = 1, fg = "GRAY6" })
        end
        hit_zones[#hit_zones + 1] = {
            kind = "nav_tab", name = name,
            x = tab_x, y = nav_y, w = tab_w, h = L.nav_bar_h,
        }
    end
    return hit_zones
end

--- Works out which page numbers to show in the pager's 7 slots.
--- Returns an array whose entries are either a page number, or the
--- string "gap" for an elided run.
---
--- The rules, for N total pages and current page p:
---   N <= 7            [1, 2, ..., N]                    (everything fits)
---   N >  7, p <= 4    [1, 2, 3, 4, 5, gap, N]
---   N >  7, p >= N-3  [1, gap, N-4, N-3, N-2, N-1, N]
---   N >  7, otherwise [1, gap, p-1, p, p+1, gap, N]
---
--- Two properties this is built around:
---
--- (1) Page 1 and page N are ALWAYS present, and always in the first and
---     last slot -- so the two jumps a user actually needs from anywhere
---     in a long list ("back to the start", "straight to the end") never
---     move as p changes. Targets that stay put are much easier to hit
---     on a touch panel than ones that shuffle.
---
--- (2) A "gap" never hides just one page. In every branch above, each
---     gap elides at least two pages -- verified at the boundaries: the
---     head case needs N >= 8 for slot 5 not to collide with slot 7, and
---     the middle case only runs for p in 5..N-4, which forces p-1 >= 4
---     and p+1 <= N-3. Showing a "..." that stands in for a single
---     number would be strictly worse than just showing the number.
local function build_page_slots(page, total_pages)
    local slots = {}
    if total_pages <= L.pager_max_slots then
        for i = 1, total_pages do slots[i] = i end
        return slots
    end
    if page <= 4 then
        return { 1, 2, 3, 4, 5, "gap", total_pages }
    elseif page >= total_pages - 3 then
        return { 1, "gap", total_pages - 4, total_pages - 3,
                 total_pages - 2, total_pages - 1, total_pages }
    end
    return { 1, "gap", page - 1, page, page + 1, "gap", total_pages }
end

--- Draws a pagination row: [<] 1 2 3 ... N [>], and appends its tap
--- zones to `hit_zones`.
---
--- `target` is carried on every zone this emits ("tasks", "learning",
--- ...) so the same control can drive more than one paged list without
--- the daemon having to guess which one a tap belongs to.
---
--- Arrows are DISABLED (drawn gray, no hit zone registered) at the ends
--- rather than wrapping around. The old single "See more tasks" button
--- wrapped because it had no other way to get back to page 1 -- but once
--- there's an explicit "previous" plus directly tappable numbers, a
--- "previous" that jumps to the last page is a trap. Gray-and-inert is
--- already this file's vocabulary for unavailable (the "coming soon" nav
--- tabs).
local function draw_pager(row_y, page, total_pages, target, hit_zones)
    local center_y = row_y + math.floor(L.task_row_h / 2)

    -- --- arrows ---
    local function draw_arrow(rects, btn_x, enabled, kind, dest_page)
        local gx = btn_x + math.floor((L.pager_arrow_btn_w - PAGER_ARROW_W) / 2)
        local gy = center_y - math.floor(PAGER_ARROW_H / 2)
        local color = enabled and "BLACK" or "GRAY6"
        for _, r in ipairs(rects) do
            M.fill_rect(gx + r[1], gy + r[2], r[3], r[4], color)
        end
        if enabled then
            hit_zones[#hit_zones + 1] = {
                kind = kind, target = target, page = dest_page,
                x = btn_x, y = row_y, w = L.pager_arrow_btn_w, h = L.task_row_h,
            }
        end
    end

    draw_arrow(PAGER_ARROW_LEFT, L.pager_left_arrow_x, page > 1, "page_prev", page - 1)
    draw_arrow(PAGER_ARROW_RIGHT, L.pager_right_arrow_x, page < total_pages, "page_next", page + 1)

    -- --- number cells ---
    local slots = build_page_slots(page, total_pages)
    local k = #slots
    local strip_w = k * L.pager_cell_pitch - L.pager_cell_gap
    local strip_x = L.pager_band_x + math.floor((L.pager_band_w - strip_w) / 2)
    local cell_y = row_y + math.floor((L.task_row_h - L.pager_cell_h) / 2)

    for i, slot in ipairs(slots) do
        local cell_x = strip_x + (i - 1) * L.pager_cell_pitch

        if slot == "gap" then
            -- Three small squares, not a "..." string: at size 1 a period
            -- is a single dot on the baseline of an 8px cell, which on
            -- flat non-anti-aliased e-ink is close to invisible.
            -- Rectangles are the one primitive with guaranteed output.
            -- GRAY6 and no hit zone -- it is not a target.
            local dot_y = center_y - 2
            for d = 0, 2 do
                M.fill_rect(cell_x + 14 + d * 8, dot_y, 4, 4, "GRAY6")
            end
        else
            local label = tostring(slot)
            -- Three-digit page numbers can't occur at the current
            -- max_visible_tasks (100 pages would need 400 tasks), but a
            -- 3-glyph size-2 label would exactly fill the cell with zero
            -- padding if that ever changed, so it steps down a size
            -- instead of silently overflowing.
            local size = (#label >= 3) and 1 or L.pager_font_size
            local label_x = cell_x + math.floor((L.pager_cell_w - text_w(label, size)) / 2)
            local label_y = center_y - math.floor(8 * size / 2)

            if slot == page then
                -- Inverted, matching the active nav tab and the
                -- keyboard's "Add" key -- this file's established
                -- treatment for "the active/affirmative one".
                M.fill_rect(cell_x, cell_y, L.pager_cell_w, L.pager_cell_h, "BLACK")
                M.draw_text(label_x, label_y, label, { size = size, fg = "WHITE", bg = "BLACK" })
                -- No hit zone: tapping the page you're already on would
                -- cost a full-screen refresh to redraw an identical
                -- screen. A pure flash for nothing.
            else
                M.draw_text(label_x, label_y, label, { size = size })
                -- A 2px underline as a tappability affordance. A bare
                -- digit is a ~16px-wide mark sitting inside a 56px hit
                -- zone, and on an IR panel a user who can't see the
                -- target won't aim at it. One fill_rect is the cheapest
                -- possible fix for that.
                local ul_w = text_w(label, size) + 8
                M.fill_rect(cell_x + math.floor((L.pager_cell_w - ul_w) / 2),
                    cell_y + L.pager_cell_h - 10, ul_w, 2, "BLACK")
                -- The zone is widened to eat the inter-cell gaps so
                -- adjacent cells abut exactly and no tap lands in a dead
                -- strip between two numbers.
                hit_zones[#hit_zones + 1] = {
                    kind = "page_goto", target = target, page = slot,
                    x = cell_x - math.floor(L.pager_cell_gap / 2), y = row_y,
                    w = L.pager_cell_pitch, h = L.task_row_h,
                }
            end
        end
    end
end

--- Draws the header battery indicator: a battery glyph built from flat
--- rectangles (this FBInk build has no image support and no reliable
--- Unicode, same constraint documented for REFRESH_ICON_RECTS above),
--- plus the percentage as text to its left.
---
--- `percent` may be nil, meaning "not known" -- either the battery
--- source hasn't been probed yet or every source failed (see
--- src/battery.lua). That state is drawn EXPLICITLY, as a gray-filled
--- battery with "--%", rather than hidden or defaulted to a number:
---   - Drawing nothing leaves a hole in the corner that reads as "the
---     dashboard is broken".
---   - Drawing a stale or default number never looks broken, so a
---     genuinely failed battery read would go unnoticed indefinitely.
--- GRAY6 is already this file's established vocabulary for
--- "unavailable" (disabled nav tabs, the keyboard's placeholder text),
--- so the gray fill says "no reading" in a word the UI already uses --
--- unlike a "?" glyph, which would be a novel symbol to decode at 8px.
---
--- Erases and redraws its whole region (L.battery_region_*) every time,
--- so it is safe to call both as part of a full dashboard redraw and on
--- its own for a battery-only partial update.
local function draw_battery(percent)
    local known = (percent ~= nil)
    if known then
        if percent < 0 then percent = 0 end
        if percent > 100 then percent = 100 end
    end
    local is_low = known and percent <= L.battery_low_threshold

    M.fill_rect(L.battery_region_x, L.battery_region_y,
        L.battery_region_w, L.battery_region_h, "WHITE")

    -- Body: drawn as a filled black rect with a smaller inner rect
    -- knocked out of it, the same way this file already fakes an
    -- outline-only box for the task checkbox (fbink's CLI has no
    -- outline-rect primitive).
    local b = L.battery_border
    local interior_color = known and "WHITE" or "GRAY6"
    M.fill_rect(L.battery_body_x, L.battery_body_y,
        L.battery_glyph_w, L.battery_glyph_h, "BLACK")
    M.fill_rect(L.battery_body_x + b, L.battery_body_y + b,
        L.battery_glyph_w - 2 * b, L.battery_glyph_h - 2 * b, interior_color)

    -- Terminal nub on the right, vertically centered on the body. Its
    -- right edge lands exactly on the screen's right margin.
    M.fill_rect(L.battery_body_x + L.battery_glyph_w,
        L.battery_body_y + math.floor((L.battery_glyph_h - L.battery_nub_h) / 2),
        L.battery_nub_w, L.battery_nub_h, "BLACK")

    if known then
        local track_w = L.battery_glyph_w - 2 * b
        local fill_w = math.floor(track_w * percent / 100)
        -- A non-empty battery must never render identically to an empty
        -- one: at 32px of track, each percent is only 0.32px, so
        -- everything below ~4% floors to zero. Same reasoning as the
        -- usage card's `if fill_w > 0` guard, one step further.
        if percent >= 1 and fill_w < 2 then fill_w = 2 end
        if fill_w > 0 then
            M.fill_rect(L.battery_body_x + b, L.battery_body_y + b,
                fill_w, L.battery_glyph_h - 2 * b, "BLACK")
        end
    end

    local label = known and string.format("%d%%", percent) or "--%"
    local size = L.battery_font_size
    local text_x = L.battery_text_right - text_w(label, size)

    if is_low then
        -- Inverted badge for a low battery. In THIS file inversion means
        -- different things in different places, and the header's local
        -- meaning is already established one row below by the
        -- CONNECTING/OFFLINE badge: "this is the one thing up here worth
        -- noticing". Reusing it costs the user no new vocabulary.
        --
        -- The GLYPH deliberately stays in normal polarity. Inverting it
        -- too would be both louder and semantically backwards -- a
        -- filled-in battery reads as MORE charged, not less -- so the
        -- badge carries "pay attention" while the glyph keeps carrying
        -- "here's the actual level".
        local pad_x, pad_y = 6, 4
        M.fill_rect(text_x - pad_x, L.battery_text_y - pad_y,
            text_w(label, size) + 2 * pad_x, 8 * size + 2 * pad_y, "BLACK")
        M.draw_text(text_x, L.battery_text_y, label, { size = size, fg = "WHITE", bg = "BLACK" })
    else
        M.draw_text(text_x, L.battery_text_y, label,
            { size = size, fg = known and "BLACK" or "GRAY6" })
    end
end

--- Repaints ONLY the battery corner and flushes just that rectangle --
--- for the periodic battery poll, which would otherwise cost a full
--- GC16 dashboard redraw (a whole-screen flash) to update two digits.
--- Same partial-refresh pattern as M.clear_flash_message().
---
--- Uses GC16 rather than A2: this is a small text region, and A2 is
--- confirmed on this hardware to leave non-self-clearing ghosting on
--- exactly that (see M.update_keyboard_preview's comment) -- old digits
--- showing through new ones is the identical failure mode. The region is
--- tiny, so full quality is cheap here.
function M.draw_battery_only(percent)
    draw_battery(percent)
    M.flush("GC16", {
        x = L.battery_region_x, y = L.battery_region_y,
        w = L.battery_region_w, h = L.battery_region_h,
    })
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
---
--- battery_percent (optional): 0-100, or nil for "unknown" -- see
--- draw_battery() above for why nil is drawn explicitly rather than
--- hidden or defaulted.
function M.draw_dashboard(state, conn_status, task_page, armed_delete_id, battery_percent)
    local hit_zones = {}
    local page = task_page or 1

    M.fill_rect(0, 0, L.screen_w, L.screen_h, "WHITE")

    -- --- header: time (primary) + date/status row (secondary) ---
    local now = os.date("*t")
    local time_str = string.format("%02d:%02d", now.hour, now.min)
    local date_str = os.date("%A, %d %B")

    M.draw_text(L.margin, L.header_y, time_str, { size = L.time_font_size })
    M.draw_text(L.margin, L.date_y, date_str, { size = L.date_font_size })

    -- Battery shares the clock's row, hard against the right margin.
    -- No collision risk with the clock: "14:30" at size 4 is 5 glyphs *
    -- 32px = 160px wide, ending at x=184, while this region starts at
    -- L.battery_region_x (448 at the current font sizes).
    draw_battery(battery_percent)

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

        -- Swipe-to-page-turn region, covering the whole task list block.
        --
        -- This zone CONTAINS every task row, delete zone, pager control
        -- and the "+ Add Task" row. It is not a tap target and must never
        -- be resolved as one: daemon.lua's hit_test() skips it by kind
        -- (see GESTURE_ZONE_KINDS there) and reaches it only through
        -- find_zone_by_kind() when handling a swipe. Its position in this
        -- table is therefore irrelevant -- deliberately so, because an
        -- earlier version of this comment claimed the opposite and the
        -- resulting tap-swallowing made the whole task area inert.
        --
        -- Full screen width (x=0, not L.margin) on purpose: a page-turn
        -- swipe naturally starts at the very edge of the screen, and there
        -- is nothing else in this horizontal band to conflict with.
        -- total_pages travels WITH the zone so the daemon can clamp a
        -- swipe at the first/last page without re-deriving the page count
        -- from a task list it deliberately doesn't own.
        hit_zones[#hit_zones + 1] = {
            kind = "task_swipe_area",
            total_pages = total_pages,
            x = 0, y = L.task_row_first_y,
            w = L.screen_w,
            h = L.task_list_max_bottom_y - L.task_row_first_y,
        }

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

        -- Pagination row, in the same slot the old "See more tasks (page
        -- 2/5)" text row used to occupy. That row could only step
        -- forward one page at a time and wrapped at the end, so reaching
        -- page 4 of 5 meant tapping three times and watching three
        -- full-screen refreshes; the numbers here are direct jumps.
        --
        -- Hidden entirely at a single page: every arrow would be
        -- disabled and the only number would be the untappable current
        -- one, i.e. inert furniture occupying a whole row.
        if total_pages > 1 then
            local pager_row_y = y + shown * (L.task_row_h + L.task_row_gap)
            draw_pager(pager_row_y, page, total_pages, "tasks", hit_zones)
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
    -- CHANGED (2026-08-12, user request): the tap target is now the WHOLE
    -- card -- its "CLAUDE USAGE" label, the percentage, the bar, the
    -- resets line and the icon -- not just the icon itself.
    --
    -- The icon's own zone was 24x24 (22px button padded 1px), the single
    -- target in this file under the 40px floor everything else meets, and
    -- it was recorded as a known exception in tests/test_layout.lua
    -- rather than fixed. Widening the icon alone would have cost vertical
    -- budget this card does not have (see usage_card_h's comment: it has
    -- already been trimmed twice to fund the footer). Making the card
    -- itself the target costs no layout at all and gives a 552x110
    -- region, which on an IR panel whose calibration is still unconfirmed
    -- is the difference between "usually works" and "always works".
    --
    -- The icon stays drawn: it is the only thing on the card that says
    -- the card DOES anything, and losing it would leave a tappable
    -- region with no affordance at all.
    --
    -- Spans from the label down to the bottom of the box. Nothing else is
    -- registered in this band -- the task list's worst case ends at
    -- L.task_list_max_bottom_y, which is where this card's own position
    -- is anchored from, and the footer starts at L.footer_y below it --
    -- so this cannot swallow another control the way the task swipe area
    -- once did (see tests/test_hit_resolution.lua). The kind is unchanged
    -- so daemon.lua's handler needs no edit; only the geometry moved.
    hit_zones[#hit_zones + 1] = {
        kind = "refresh_usage_button",
        x = L.margin,
        y = card_y,
        w = L.screen_w - 2 * L.margin,
        h = (card_box_y + L.usage_card_h) - card_y,
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
    for _, z in ipairs(draw_nav_bar("Today")) do
        hit_zones[#hit_zones + 1] = z
    end

    M.flush("GC16")
    return hit_zones, page
end

-- ===================== LEARNING screen =====================
--
-- A dedicated full screen listing courses and books, reached from the
-- "Learning" nav tab. It shows ONLY learning items -- no tasks, no
-- Claude usage card, no Exit Dashboard / Restart SSH footer. Those all
-- stay on the Today screen where they already live.
--
-- Every row draws from four fields the backend has already derived
-- (name, percent, detail, done -- see backend/state.py's _recompute),
-- so nothing here branches on whether an item is a course or a book, and
-- nothing here divides. A book is simply a row whose `detail` is
-- non-empty; that string doubles as the type signal, which is why there
-- is no separate badge or icon distinguishing the two kinds.

--- Draws one learning row. Layout, all relative to row_y:
---
---   +8   name (size 2, left)        detail (size 1, right)   pct (size 2, right)
---   +33  [=================================              ]  progress bar
---
--- The bar spans the full content width for BOTH kinds. That's the one
--- rule worth protecting on this screen: the whole point of the list is
--- comparing how far along several things are, and that comparison only
--- works if every bar shares a denominator width.
local function draw_learning_row(item, row_y)
    local right = L.screen_w - L.margin
    local percent = item.percent or 0
    if percent < 0 then percent = 0 end
    if percent > 100 then percent = 100 end

    -- Percent, right-aligned to the margin in its own fixed slot.
    local pct_str = string.format("%d%%", percent)
    local pct_size = L.learn_name_font_size
    local pct_x = right - text_w(pct_str, pct_size)
    M.draw_text(pct_x, row_y + 8, pct_str, { size = pct_size })

    -- Book detail ("120/320 pages"), right-aligned to the left of the
    -- percent. Drawn in BLACK at size 1, not GRAY6: the size step from
    -- 16px to 8px already establishes that this is secondary, and in
    -- this file gray specifically means unavailable/disabled -- which a
    -- real page count emphatically is not. Reusing gray for "secondary
    -- but real" would blunt the one meaning it currently carries.
    local detail = item.detail
    if detail == "" then detail = nil end
    local name_right = pct_x - L.gap_sm
    if detail then
        local detail_x = pct_x - L.gap_sm - text_w(detail, 1)
        -- +4 optically centers 8px-tall text against the 16px name
        M.draw_text(detail_x, row_y + 12, detail, { size = 1 })
        name_right = detail_x - L.gap_sm
    end

    -- Name, truncated to whatever room is left after the two
    -- right-aligned elements above have taken theirs.
    local name = item.name or ""
    if item.done then name = name .. " (done)" end
    local name_size = L.learn_name_font_size
    local max_chars = math.floor((name_right - L.margin) / char_w(name_size))
    if max_chars < 1 then max_chars = 1 end
    if #name > max_chars then
        -- Note this is deliberately not the `sub(1, max - 1) .. "..."`
        -- form used for task rows above, which actually yields a string
        -- two characters LONGER than the cap it's given.
        name = name:sub(1, math.max(1, max_chars - 3)) .. "..."
    end
    M.draw_text(L.margin, row_y + 8, name, { size = name_size })

    -- Progress bar: the CLAUDE USAGE card's treatment, unchanged -- a
    -- 1px BLACK outline around a WHITE track, BLACK fill on top. The
    -- outline matters MORE here than it does on the card: there the
    -- track sat on GRAY6, so an empty bar was merely low-contrast, while
    -- here the background is plain WHITE and an un-outlined 0% bar would
    -- be literally invisible -- a row with nothing where its bar should
    -- be, which reads as a rendering fault rather than as "not started".
    local bar_y = row_y + L.learn_bar_top
    local bar_w = L.screen_w - 2 * L.margin
    M.fill_rect(L.margin - 1, bar_y, bar_w + 2, L.learn_bar_h + 2, "BLACK")
    M.fill_rect(L.margin, bar_y + 1, bar_w, L.learn_bar_h, "WHITE")
    local fill_w = math.floor(bar_w * percent / 100)
    if fill_w > 0 then
        M.fill_rect(L.margin, bar_y + 1, fill_w, L.learn_bar_h, "BLACK")
    end
end

--- Renders the Learning screen. Same contract as M.draw_dashboard:
--- returns (hit_zones, effective_page), with the page clamped to however
--- many pages currently exist so a shrinking list can't strand the user
--- on a page that no longer has anything on it.
---
--- state may be nil (not connected / nothing received yet), which is
--- drawn as an explicit "waiting" message and kept DISTINCT from "you
--- have no learnings yet" -- collapsing the two would render a comms
--- failure as the confident claim that the user's list is empty.
function M.draw_learning(state, conn_status, page, battery_percent)
    local hit_zones = {}
    page = page or 1

    M.fill_rect(0, 0, L.screen_w, L.screen_h, "WHITE")

    -- --- header ---
    -- Size 3, not 4: the clock is deliberately the only size-4 element
    -- in this app (see time_font_size), and a screen title competing
    -- with it would break that hierarchy. Matches draw_confirm_exit's
    -- existing precedent for a screen title.
    M.draw_text(L.margin, L.learn_title_y, "LEARNING", { size = 3 })

    -- nil means "no state received yet"; an empty table means "connected,
    -- and you genuinely have nothing tracked". A state snapshot that
    -- somehow arrives WITHOUT a learnings key (an older backend) counts
    -- as the latter, not the former -- we did hear from the laptop, so
    -- claiming to still be waiting for it would be the wrong message.
    local items = nil
    if state then items = state.learnings or {} end

    -- Summary line, occupying the same slot as the dashboard's date.
    if items then
        local courses, books = 0, 0
        for _, it in ipairs(items) do
            if it.kind == "book" then books = books + 1 else courses = courses + 1 end
        end
        local parts = {}
        if courses > 0 then
            parts[#parts + 1] = courses .. (courses == 1 and " course" or " courses")
        end
        if books > 0 then
            parts[#parts + 1] = books .. (books == 1 and " book" or " books")
        end
        local summary = (#parts > 0) and table.concat(parts, "  ") or "Nothing tracked yet"
        M.draw_text(L.margin, L.learn_summary_y, summary, { size = L.date_font_size })
    end

    -- Connection status, reusing the dashboard's badge geometry exactly.
    -- Only drawn when something is wrong: on this screen every number is
    -- a progress figure, and silently presenting stale progress as
    -- current is the specific failure worth warning about. Same
    -- reasoning (and same pixels) as the dashboard's badge.
    if conn_status ~= "open" then
        local badge_x = L.screen_w - L.status_badge_w - L.margin
        local status_text = conn_status == "connecting" and "CONNECTING" or "OFFLINE"
        M.fill_rect(badge_x, L.status_badge_y, L.status_badge_w, L.status_badge_h, "BLACK")
        M.draw_text(badge_x + L.gap_xs, L.status_text_y, status_text,
            { size = L.status_font_size, fg = "WHITE", bg = "BLACK" })
    end

    -- Battery sits on the title's row, same fixed corner as on the
    -- dashboard. "LEARNING" at size 3 is 8 glyphs * 24px = 192px ending
    -- at x=216, so it is nowhere near this region.
    draw_battery(battery_percent)

    M.fill_rect(L.margin, L.divider_y, L.screen_w - 2 * L.margin, L.divider_h, "BLACK")

    -- --- list ---
    if not items then
        M.draw_text(L.margin, L.learn_row_first_y, "Waiting for data from laptop...", { size = 1 })
    elseif #items == 0 then
        M.draw_text(L.margin, L.learn_row_first_y, "Nothing here yet.", { size = 2 })
        M.draw_text(L.margin, L.learn_row_first_y + 16 + L.gap_sm,
            "Add courses and books from Telegram.", { size = 1 })
        M.draw_text(L.margin, L.learn_row_first_y + 16 + L.gap_sm + 8 + L.gap_xs,
            "/course Spanish   or   /book Atomic Habits 320", { size = 1 })
    else
        -- Finished items sink to the bottom, matching how the task list
        -- already orders done tasks -- and, as there, done via a manual
        -- stable partition rather than table.sort, which Lua does not
        -- guarantee to be stable and which could therefore shuffle
        -- same-status rows against each other on every redraw.
        local sorted = {}
        do
            local finished = {}
            for _, it in ipairs(items) do
                if it.done then finished[#finished + 1] = it else sorted[#sorted + 1] = it end
            end
            for _, it in ipairs(finished) do sorted[#sorted + 1] = it end
        end

        local total = #sorted
        local total_pages = math.max(1, math.ceil(total / L.learn_rows_per_page))
        if page > total_pages then page = total_pages end
        if page < 1 then page = 1 end

        local start_idx = (page - 1) * L.learn_rows_per_page + 1
        local end_idx = math.min(start_idx + L.learn_rows_per_page - 1, total)
        for idx = start_idx, end_idx do
            local row_y = L.learn_row_first_y + (idx - start_idx) * L.learn_row_pitch
            draw_learning_row(sorted[idx], row_y)
        end

        -- Swipe region, registered before the pager for the same reason
        -- the task list's is: it spans the rows above, and daemon.lua
        -- resolves it through its own kind-specific lookup rather than
        -- through hit_test().
        hit_zones[#hit_zones + 1] = {
            kind = "learning_swipe_area",
            total_pages = total_pages,
            x = 0, y = L.learn_row_first_y,
            w = L.screen_w,
            h = L.learn_pager_y - L.learn_row_first_y,
        }

        if total_pages > 1 then
            draw_pager(L.learn_pager_y, page, total_pages, "learning", hit_zones)
        end
    end

    for _, z in ipairs(draw_nav_bar("Learning")) do
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
--- auto-dismisses. Deliberately does NOT redraw the whole screen -- the
--- nav bar's position and tab list are fixed, so a full redraw would
--- cost an unnecessary full-screen flash just to restore one strip.
--- Returns nothing: the nav bar's hit_zones never change (fixed
--- position, fixed tabs), so daemon.lua's existing current_hit_zones
--- from the last full draw are still correct.
---
--- `active_tab` MUST be passed. This function's original doc comment
--- said the nav bar's content was "fully static (always the same 4 tabs,
--- 'Today' always the active one in this v1)" -- true when written, and
--- false the moment a second real screen existed. Without this argument,
--- dismissing a toast on the Learning screen would restore a nav bar
--- highlighting Today, leaving the UI claiming to be on a screen it
--- isn't. That is precisely the silent-drift failure this file's
--- footer_y comment was written about, so it gets the same fix: one
--- caller-supplied source of truth instead of a value re-derived (here,
--- re-assumed) in a second place.
function M.clear_flash_message(active_tab)
    draw_nav_bar(active_tab)
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
-- its key box depends on the per-glyph width at size 2, which is
-- extrapolated rather than directly measured -- see char_w() near the
-- top of this file. If key labels look visibly off-center once this is
-- running on real hardware, adjust char_w() rather than the per-key math
-- below (which is otherwise computed, not hand-placed, for the same
-- "don't hand-derive pixel arithmetic that can't be test-run before
-- reaching the device" reason as the rest of this section).
-- SUPERSEDED (kept as a note, not a value): this section originally
-- defined its own `KBD_CHAR_W_ESTIMATE = 12` for the width of one size-2
-- glyph. That number predates the 2026-08-04 hardware measurement that
-- established 8px per glyph at size 1 (CARD_CHAR_W_S1) alongside the
-- already-confirmed 8px-per-size-unit text HEIGHT -- together implying
-- 16px, not 12, at size 2. Two different constants for the same physical
-- quantity in one file is exactly the drift this file's other comments
-- keep warning about, so key centering now goes through char_w() like
-- every other measured-width call site.
--
-- Practical effect: key labels shift 2px left, i.e. onto true center if
-- char_w is right. If they instead look visibly off-center on hardware,
-- fix char_w() near the top of this file (which corrects every screen at
-- once), not this call site.

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
        -- Centered via the file-wide glyph-width helper -- see the note
        -- above this section's layout constants on why this no longer
        -- uses a local estimate of its own.
        local tx = zone.x + math.floor((zone.w - text_w(zone.label, 2)) / 2)
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

-- ===================== PIN entry (screen lock) =====================
--
-- Shown instead of an immediate unlock when a lock_pin is configured (see
-- backend/README.md's "Backend -> Kindle (state pushes)" section) -- a
-- purpose-built numeric keypad, because the Add Task keyboard above is
-- deliberately letters-and-space only (see its own header comment) and
-- has no digits to reuse. daemon.lua owns entering/leaving this screen
-- (a `pin_entry_active` flag, orthogonal to both `ui_mode` and
-- `screen_locked`, the same "state that overlays everything else rather
-- than becoming a new ui_mode" treatment the lock itself already gets --
-- see daemon.lua's `screen_locked` doc comment for why); this file only
-- draws whatever buffer/error state it's told about.
--
-- Deliberately NO on-screen cancel button: the power button already
-- means "go back" everywhere else in the lock flow (locked -> pressing
-- it either unlocks or, with a PIN configured, enters this screen), so
-- pressing it again here to bail back out to the blank Locked screen
-- reuses a control the user has already found, rather than adding a
-- second, screen-specific way to do the same thing.

L.pin_title_y = L.margin
L.pin_dot_w = 28
L.pin_dot_gap = 20
L.pin_dot_count = 4
L.pin_dots_y = L.pin_title_y + 24 + L.gap_lg -- 24 = real size-3 title height
L.pin_error_y = L.pin_dots_y + L.pin_dot_w + L.gap_sm
L.pin_error_h = 16 -- real size-2 text height; reserved whether or not an
                    -- error is currently showing, so the keypad below
                    -- never shifts position depending on error state
L.pin_keypad_top_y = L.pin_error_y + L.pin_error_h + L.gap_lg

-- 3 columns exactly fill the usable width with no leftover pixels
-- (173*3 + 16*2 = 552 = 600 - 2*24), which is what fixes col_w and
-- col_gap here rather than leaving them independently tunable.
L.pin_col_w = 173
L.pin_col_gap = 16
L.pin_row_h = 96
L.pin_row_gap = 16
L.pin_col_pitch = L.pin_col_w + L.pin_col_gap
L.pin_row_pitch = L.pin_row_h + L.pin_row_gap

-- Total dot-row width, used to center it: pin_dot_count dots plus
-- (pin_dot_count - 1) gaps between them.
local PIN_DOTS_TOTAL_W = L.pin_dot_count * L.pin_dot_w + (L.pin_dot_count - 1) * L.pin_dot_gap
L.pin_dots_x = math.floor((L.screen_w - PIN_DOTS_TOTAL_W) / 2)

-- "" is a blank spacer (no key, no hit zone) -- keeps 0 in its
-- conventional bottom-center phone-keypad position instead of sliding it
-- next to 7/8/9.
local PIN_KEYPAD_ROWS = {
    { "1", "2", "3" },
    { "4", "5", "6" },
    { "7", "8", "9" },
    { "", "0", "DEL" },
}

--- Redraws just the dot row (how many of the 4 PIN digits have been
--- entered so far -- never the digits themselves, so a glance from
--- across the room reveals nothing about the PIN). Filled black =
--- entered, hollow = not yet -- the same opposite-treatment-means-
--- opposite-state convention as the task checkbox.
local function draw_pin_dots(buffer)
    M.fill_rect(0, L.pin_dots_y, L.screen_w, L.pin_dot_w, "WHITE")
    local entered = #buffer
    for i = 0, L.pin_dot_count - 1 do
        local dx = L.pin_dots_x + i * (L.pin_dot_w + L.pin_dot_gap)
        M.fill_rect(dx, L.pin_dots_y, L.pin_dot_w, L.pin_dot_w, "BLACK")
        if i >= entered then
            local inset = 5
            M.fill_rect(dx + inset, L.pin_dots_y + inset,
                L.pin_dot_w - 2 * inset, L.pin_dot_w - 2 * inset, "WHITE")
        end
    end
end

-- Same de-ghosting treatment as the Add Task preview strip (see
-- M.update_keyboard_preview's comment for the hardware-confirmed reason
-- DU is used per-keystroke with a periodic full GC16 settle) -- a
-- separate counter from the keyboard's own, since the two screens are
-- never active at the same time but shouldn't share unrelated state.
local PIN_DEGHOST_INTERVAL = 8
local _pin_dot_update_count = 0

--- Fast partial-refresh update of ONLY the dot row, for per-digit
--- feedback while a PIN is still being entered (fewer than 4 digits so
--- far -- the 4th digit always triggers a full M.draw_pin_entry redraw
--- instead, from daemon.lua, since that's the moment right/wrong is
--- decided and the error line may need to change). Does not return
--- hit_zones: the keypad's positions never move while typing.
function M.update_pin_dots(buffer)
    draw_pin_dots(buffer)
    _pin_dot_update_count = _pin_dot_update_count + 1
    local waveform = "DU"
    if _pin_dot_update_count % PIN_DEGHOST_INTERVAL == 0 then
        waveform = "GC16"
    end
    M.flush(waveform, { x = 0, y = L.pin_dots_y, w = L.screen_w, h = L.pin_dot_w })
end

--- Full redraw of the PIN entry keypad. `buffer` is the PIN digits typed
--- so far (usually "" -- daemon.lua clears it before every full redraw
--- here, whether entering fresh or after a wrong attempt) and `show_error`
--- draws "Wrong PIN" above the keypad when true. Returns hit_zones:
--- {kind="pin_digit", digit="0".."9"}, {kind="pin_backspace"}.
function M.draw_pin_entry(buffer, show_error)
    local hit_zones = {}
    M.fill_rect(0, 0, L.screen_w, L.screen_h, "WHITE")
    _pin_dot_update_count = 0 -- see M.update_pin_dots's comment: this
                               -- full-quality draw is a clean baseline

    M.draw_text(L.margin, L.pin_title_y, "Enter PIN", { size = 3 })
    draw_pin_dots(buffer)

    M.fill_rect(0, L.pin_error_y, L.screen_w, L.pin_error_h, "WHITE")
    if show_error then
        local label = "Wrong PIN -- try again"
        M.draw_text(math.floor((L.screen_w - text_w(label, 2)) / 2), L.pin_error_y,
            label, { size = 2 })
    end

    for row_i, row in ipairs(PIN_KEYPAD_ROWS) do
        local row_y = L.pin_keypad_top_y + (row_i - 1) * L.pin_row_pitch
        for col_i, label in ipairs(row) do
            if label ~= "" then
                local col_x = L.margin + (col_i - 1) * L.pin_col_pitch
                local is_del = (label == "DEL")
                M.fill_rect(col_x, row_y, L.pin_col_w, L.pin_row_h, "GRAY6")
                local size = is_del and 2 or 3
                local tx = col_x + math.floor((L.pin_col_w - text_w(label, size)) / 2)
                local ty = row_y + math.floor((L.pin_row_h - 8 * size) / 2)
                M.draw_text(tx, ty, label, { size = size, fg = "WHITE", bg = "GRAY6" })
                hit_zones[#hit_zones + 1] = {
                    kind = is_del and "pin_backspace" or "pin_digit",
                    digit = (not is_del) and label or nil,
                    x = col_x, y = row_y, w = L.pin_col_w, h = L.pin_row_h,
                }
            end
        end
    end

    M.flush("GC16")
    return hit_zones
end

--- Draws the locked screen (power button or the idle auto-lock, both in
--- daemon.lua): a blank WHITE page with a single centered "Locked".
---
--- WHITE rather than BLACK for two reasons. E-ink holds either state
--- with zero power, so there is no power argument between them, but a
--- full-black fill left standing for hours is the classic way to build
--- up persistent ghosting that a later screen has to fight; and a black
--- rectangle on a Kindle reads as "broken/asleep mid-refresh" whereas a
--- blank white page reads as "off", which is what the state actually is.
---
--- CHANGED (2026-08-12, user request): this screen was originally
--- COMPLETELY blank, which was the right first cut but had one real
--- problem -- an empty white page is visually indistinguishable from a
--- daemon that has silently died, and this device has a documented
--- history of exactly that (see ops/README.md's notes on the luajit
--- process vanishing from `ps` with no crash trace). The word is the
--- whole fix: it says the state is deliberate and recoverable, i.e.
--- "press the power button again", rather than leaving the user to
--- guess whether the dashboard needs restarting from the laptop.
---
--- Centered by computation (text_w/char_w and the confirmed 8px-per-size
--- -unit glyph box), not by a hand-placed pixel offset -- so it stays
--- centered if char_w() is ever corrected, exactly like every other
--- centered label in this file.
---
--- Uses GC16 (full-quality) deliberately, and this is the one place in
--- this file where the slowest waveform is the RIGHT choice: it fully
--- settles every pixel, so the locked screen is genuinely clean rather
--- than a faint after-image of the dashboard. It also runs at most twice
--- per lock/unlock cycle, so its cost is irrelevant.
---
--- Returns no hit_zones: locking deliberately takes touch out of play
--- entirely (see daemon.lua's handle_gesture), so there is nothing on
--- this screen to hit-test against. That is the point -- a locked
--- dashboard in a bag should not be tappable.
function M.draw_blank_screen()
    M.fill_rect(0, 0, L.screen_w, L.screen_h, "WHITE")
    -- Size 3, matching draw_shutdown_message's terminal notice below --
    -- both are "the dashboard is not currently a dashboard" states, and
    -- reading them from across a desk matters more than subtlety. Size 4
    -- is reserved for the clock, which is the one deliberate visual
    -- anchor of the normal screen.
    local label = "Locked"
    local size = 3
    M.draw_text(
        math.floor((L.screen_w - text_w(label, size)) / 2),
        math.floor((L.screen_h - 8 * size) / 2),
        label, { size = size })
    M.flush("GC16")
    return {}
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
