"""
Tests for the Daily habits feature: telegram_bot's time parsing and
command handlers, the StateStore CRUD + nightly reset/archive logic, and
whatever in google_sheets.py is unit-testable without real credentials.

Run from the repo root:

    python backend/tests/test_daily.py

Plain asserts and a tiny runner, matching test_learnings.py's style
exactly (see that file's own header comment for why: this stays runnable
with nothing installed beyond what the backend already needs).

WHAT'S WORTH TESTING HERE, AND WHY
-----------------------------------
Three places carry almost all of this feature's risk:

  1. Time parsing (_parse_daily_time). It accepts two different input
     shapes (12h with AM/PM, bare 24h) and always normalizes to one
     display string -- the hour/minute arithmetic for midnight and noon
     is exactly the kind of off-by-twelve mistake that silently produces
     a plausible-looking wrong time rather than an obvious crash.

  2. maybe_reset_dailies's archive logic. It runs unattended, once a day,
     with no user watching -- a bug here doesn't show up as an error, it
     shows up as a habit-tracker history that's silently wrong, possibly
     for weeks before anyone notices. The multi-day-outage edge case (an
     ABSENT daily_history key must mean "no data", never "nothing done")
     is the single most important invariant in this feature.

  3. The 3-way task/learning/daily fallback chain in /done and /delete --
     the exact same "an explicit prefix must never cross lists" risk
     test_learnings.py already covers for tasks/learnings, now with a
     third list added to the same dispatch.

google_sheets.py's sync_day() is tested two ways: the real "not
configured" skip path (deterministic in this environment, since no
backend/.env credentials exist here), and a monkeypatched fake
gspread.Worksheet (an in-memory grid) exercising the header-append/
idempotent-upsert logic that can never be exercised against a real sheet
in CI.
"""

import asyncio
import datetime as _datetime_module
import logging
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

# Every fire-and-forget live sync in an unconfigured environment (no
# backend/.env credentials here) logs a "not configured" warning by
# design (see state.py's _fire_live_daily_sync) -- expected noise in this
# test file specifically, since most tests below never configure Google
# Sheets. Silenced so real failures aren't lost in it.
logging.disable(logging.WARNING)

from backend import config  # noqa: E402
from backend import google_sheets  # noqa: E402
from backend import state as state_module  # noqa: E402
from backend import telegram_bot  # noqa: E402
from backend.state import StateStore  # noqa: E402
from backend.ws_manager import ConnectionManager  # noqa: E402
from gspread.exceptions import WorksheetNotFound  # noqa: E402
from gspread.utils import a1_to_rowcol  # noqa: E402

# ---------------------------------------------------------------- harness

_failures = []
_passes = 0


def check(name, got, want):
    global _passes
    if got == want:
        _passes += 1
        print(f"  ok   {name}")
    else:
        _failures.append(name)
        print(f"  FAIL {name}\n         got:  {got!r}\n         want: {want!r}")


def check_contains(name, haystack, needle):
    global _passes
    if needle in haystack:
        _passes += 1
        print(f"  ok   {name}")
    else:
        _failures.append(name)
        print(f"  FAIL {name}\n         {haystack!r}\n         does not contain {needle!r}")


def new_store():
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    os.unlink(path)
    return StateStore(Path(path))


# Capture replies instead of hitting the Telegram API.
_replies = []


async def _fake_send(client, text):
    _replies.append(text)


telegram_bot.send_message = _fake_send


_fake_manager = ConnectionManager()  # zero connections; nothing here uses /lock


async def say(state, text):
    """Run one command and return the reply it produced."""
    _replies.clear()
    await telegram_bot.process_command(state, None, text, _fake_manager)
    return _replies[-1] if _replies else ""


# ---------------------------------------------------------- date monkeypatch


class _FakeDate:
    """Stands in for the `date` name state.py imports, so
    maybe_reset_dailies's `date.today()` can be driven deterministically
    instead of depending on the real calendar date. Only `.today()` is
    ever called on it in state.py -- see maybe_reset_dailies."""

    _current = None

    @classmethod
    def today(cls):
        return cls._current


def _set_fake_today(y, m, d):
    _FakeDate._current = _datetime_module.date(y, m, d)


async def _drain_pending_tasks(rounds: int = 30) -> None:
    """Lets any already-scheduled asyncio tasks run to completion before a
    test starts relying on a mocked google_sheets.sync_day or a
    deterministic call count.

    Every add/toggle/delete on a daily fires a fire-and-forget background
    task (state.py's _fire_live_daily_sync) via asyncio.create_task,
    which the event loop only actually runs once something yields with
    await. Earlier test functions in this file create plenty of these and
    never wait for them, so without a drain, a LATER test that patches
    google_sheets.sync_day and does its own `await asyncio.sleep(0)` can
    end up running a pile of leftover tasks from EARLIER tests too --
    each one calling whatever sync_day happens to be patched to at that
    moment, and each one hitting whatever fake spreadsheet/date a LATER
    test has wired up. That produced call counts in the double digits and
    stray writes into an unrelated test's fake worksheet the first time
    this file was run without this drain -- a real cross-test leakage
    bug, not a flaky-timing coincidence to shrug off.
    """
    for _ in range(rounds):
        await asyncio.sleep(0)


# ------------------------------------------------------------------ tests


async def test_time_parsing():
    print("\n=== _parse_daily_time ===")
    p = telegram_bot._parse_daily_time

    check("7:00 AM -> 420 min, normalized display", p("7:00 AM Meditate"),
          (420, "7:00 AM", "Meditate"))
    check("12:00 AM is midnight -> 0 min", p("12:00 AM Lights out"),
          (0, "12:00 AM", "Lights out"))
    check("12:00 PM is noon -> 720 min", p("12:00 PM Lunch"),
          (720, "12:00 PM", "Lunch"))
    check("bare 24h input normalizes to 12h display", p("19:00 Dinner prep"),
          (1140, "7:00 PM", "Dinner prep"))
    check("24h midnight normalizes too", p("0:00 Wake"), (0, "12:00 AM", "Wake"))
    check("24h noon normalizes too", p("12:00 Standup"), (720, "12:00 PM", "Standup"))
    check("lowercase am/pm accepted", p("7:00 am Meditate"), (420, "7:00 AM", "Meditate"))
    check("multi-word topic preserved whole", p("7:00 AM Take out the trash"),
          (420, "7:00 AM", "Take out the trash"))

    check("no time at all is rejected", p("just some text"), None)
    check("no topic is rejected", p("7:00 AM"), None)
    check("12h hour 0 is invalid (no '0 AM')", p("0:00 AM Bad"), None)
    check("12h hour 13 is invalid", p("13:00 PM Bad"), None)
    check("24h hour 24 is invalid", p("24:00 Bad"), None)
    check("24h hour 25 is invalid", p("25:00 Bad"), None)
    check("minute 60 is invalid", p("7:60 AM Bad"), None)
    check("garbage minute is not matched at all", p("7:xx AM Bad"), None)


async def test_daily_state_crud():
    print("\n=== StateStore daily CRUD ===")
    s = new_store()

    item = await s.add_daily(420, "7:00 AM", "Meditate")
    check("new daily starts not done", item["done"], False)
    check("daily ids start at 1", item["id"], 1)

    await s.add_daily(0, "12:00 AM", "Lights out")  # id 2, earlier in the day
    await s.add_daily(1140, "7:00 PM", "Dinner prep")  # id 3

    listed = await s.list_dailies()
    check("list_dailies is time-sorted, not insertion-sorted",
          [d["id"] for d in listed], [2, 1, 3])

    snap = s.snapshot()
    check("snapshot() dailies are ALSO time-sorted",
          [d["id"] for d in snap["dailies"]], [2, 1, 3])

    got = await s.get_daily(1)
    check("get_daily returns the right item", got["topic"], "Meditate")
    check("get_daily on unknown id returns None", await s.get_daily(99), None)

    new_state = await s.toggle_daily(1)
    check("toggle flips to done", new_state, True)
    new_state = await s.toggle_daily(1)
    check("toggle flips back", new_state, False)
    check("toggle on unknown id returns None", await s.toggle_daily(99), None)

    updated = await s.mark_daily_done(1)
    check("mark_daily_done always sets True", updated["done"], True)
    updated = await s.mark_daily_done(1)
    check("...even if already done", updated["done"], True)
    check("mark_daily_done on unknown id returns None", await s.mark_daily_done(99), None)

    check("delete removes it", await s.delete_daily(2), True)
    check("deleting twice reports not found", await s.delete_daily(2), False)
    check("the other two survive", len(await s.list_dailies()), 2)


async def test_telegram_daily_add():
    print("\n=== /daily add ===")
    s = new_store()

    reply = await say(s, "/daily")
    check_contains("bare /daily shows usage", reply, "Usage: /daily")

    reply = await say(s, "/daily garbage")
    check_contains("unparseable time is refused, not silently accepted",
                    reply, "Couldn't read that time")

    reply = await say(s, "/daily 7:00 AM Meditate")
    check("valid add echoes the normalized time and topic",
          reply, "Added daily D1 7:00 AM: Meditate")

    reply = await say(s, "/daily 19:00 Dinner prep")
    check("24h input is echoed back already normalized to 12h",
          reply, "Added daily D2 7:00 PM: Dinner prep")

    check("both items are stored", len(await s.list_dailies()), 2)


async def test_fallback_chain_includes_daily():
    print("\n=== /done and /delete: task -> learning -> daily fallback ===")
    s = new_store()
    t = await s.add_task("call dentist")
    lrn = await s.add_course("Spanish")
    d = await s.add_daily(420, "7:00 AM", "Meditate")
    check("all three share id 1 (independent sequences)",
          (t["id"], lrn["id"], d["id"]), (1, 1, 1))

    check("bare /done 1 still resolves to the TASK first", await say(s, "/done 1"),
          "Marked #1 done.")
    check("the learning is untouched", (await s.get_learning(1))["percent"], 0)
    check("the daily is untouched", (await s.get_daily(1))["done"], False)

    reply = await say(s, "/done L1")
    check_contains("explicit L1 hits the learning", reply, "L1 Spanish: 100%")
    check("the daily is still untouched", (await s.get_daily(1))["done"], False)

    reply = await say(s, "/done D1")
    check("explicit D1 hits the daily", reply, "Marked D1 done: Meditate")
    check("the daily is now done", (await s.get_daily(1))["done"], True)

    # A fresh store with ONLY a daily item: a bare number must still fall
    # all the way through task -> learning -> daily rather than stopping
    # early just because the first two lists are empty.
    s2 = new_store()
    await s2.add_daily(480, "8:00 AM", "Stretch")
    reply = await say(s2, "/done 1")
    check("bare id falls through all the way to a daily", reply,
          "Marked D1 done: Stretch")

    reply = await say(s2, "/delete 1")
    check("bare delete falls through to the daily too", reply, "Deleted D1.")

    # Explicit D must never cross into task/learning, mirroring
    # test_learnings.py's identical check for L and #.
    s3 = new_store()
    await s3.add_task("water the plants")
    reply = await say(s3, "/delete D1")
    check("explicit D1 with no such daily refuses",
          reply, "No daily D1 found.")
    check("...and the task survives", len(await s3.list_tasks()), 1)

    # The fully-exhausted not-found message names all three lists.
    s4 = new_store()
    reply = await say(s4, "/done 99")
    check("nothing anywhere names all three lists",
          reply, "No task #99, learning L99, or daily D99 found.")
    reply = await say(s4, "/delete 99")
    check("same for /delete", reply,
          "No task #99, learning L99, or daily D99 found.")


async def test_list_output_daily_section():
    print("\n=== /list DAILY section ===")
    s = new_store()
    reply = await say(s, "/list")
    check_contains("empty state still shows the DAILY header", reply, "DAILY")
    check_contains("empty daily section hints how to start", reply,
                    "/daily <time> <topic>")

    await s.add_daily(1140, "7:00 PM", "Dinner prep")
    await s.add_daily(420, "7:00 AM", "Meditate")
    await s.toggle_daily(2)  # Meditate (id 2) done

    reply = await say(s, "/list")
    check_contains("shows the D namespace", reply, "D1 7:00 PM: Dinner prep")
    check_contains("done daily shows [DONE]", reply, "[DONE] D2 7:00 AM: Meditate")

    # UNLIKE learnings/tasks, a done daily item must NOT sink to the
    # bottom -- it stays in its chronological time slot. Meditate
    # (7:00 AM, done) must print BEFORE Dinner prep (7:00 PM, not done).
    check("done daily item stays in time order, not sunk to the bottom",
          reply.index("D2 7:00 AM: Meditate") < reply.index("D1 7:00 PM: Dinner prep"),
          True)


async def test_dailyhistory():
    print("\n=== /dailyhistory ===")
    s = new_store()
    reply = await say(s, "/dailyhistory")
    check_contains("no habits yet points at /daily", reply, "/daily <time> <topic>")

    await s.add_daily(420, "7:00 AM", "Meditate")
    _set_fake_today(2026, 1, 10)
    # telegram_bot.py imports `date` SEPARATELY from state.py (its own
    # `from datetime import date, timedelta`), so this test's own
    # rendering check has to patch telegram_bot's copy of the name, not
    # state_module's -- patching the wrong one would silently use the
    # real calendar date instead of the fixture below.
    orig_date = telegram_bot.date
    telegram_bot.date = _FakeDate
    try:
        # Directly write history entries rather than driving the reset
        # loop here -- that loop gets its own dedicated test below; this
        # one only checks /dailyhistory's own rendering rules.
        snap = s._data  # test-only reach-in, see test_maybe_reset_dailies
        snap["daily_history"] = {
            "2026-01-08": {"1": True},
            "2026-01-09": {"1": False},
            # 2026-01-07 deliberately absent: "no data", not "missed".
        }
        reply = await say(s, "/dailyhistory")
    finally:
        telegram_bot.date = orig_date

    check_contains("legend explains the markers", reply, "done")
    check_contains("legend explains the markers", reply, "no data")
    # 7 days ending today (01-10): 01-04 .. 01-10. 01-08 -> done (v),
    # 01-09 -> missed (x), 01-07 and earlier -> no data (-), today -> "...".
    check_contains("day with a True entry shows the done marker",
                    reply, "D1 Meditate: - - - - v x ...")


async def test_dailysync_unconfigured():
    print("\n=== /dailysync when Google Sheets isn't configured ===")
    s = new_store()
    orig = config.HAS_GOOGLE_SHEETS
    config.HAS_GOOGLE_SHEETS = False
    try:
        reply = await say(s, "/dailysync")
        check_contains("clear message pointing at the setup doc", reply,
                        "GOOGLE_SHEETS_SETUP.md")
    finally:
        config.HAS_GOOGLE_SHEETS = orig


async def test_live_sync_fires_on_mutation():
    print("\n=== live (fire-and-forget) sync triggers on add/toggle/delete ===")
    await _drain_pending_tasks()  # flush stray background tasks from earlier tests first
    s = new_store()
    calls = []

    async def fake_sync_day(date_str, items):
        calls.append((date_str, items))
        return True, "ok"

    orig = state_module.google_sheets.sync_day
    state_module.google_sheets.sync_day = fake_sync_day
    try:
        await s.add_daily(420, "7:00 AM", "Meditate")
        await asyncio.sleep(0)  # let the fire-and-forget task run
        check("add_daily fires a live sync", len(calls), 1)

        await s.toggle_daily(1)
        await asyncio.sleep(0)
        check("toggle_daily fires a live sync too", len(calls), 2)

        await s.delete_daily(1)
        await asyncio.sleep(0)
        check("delete_daily fires a live sync too", len(calls), 3)
    finally:
        state_module.google_sheets.sync_day = orig


async def test_maybe_reset_dailies():
    print("\n=== maybe_reset_dailies: nightly archive + reset ===")
    s = new_store()
    await s.add_daily(420, "7:00 AM", "Meditate")
    await s.add_daily(480, "8:00 AM", "Stretch")
    await _drain_pending_tasks()  # flush this test's + earlier tests' stray syncs first

    sync_calls = []

    async def fake_sync_day(date_str, items):
        sync_calls.append((date_str, items))
        return True, "ok"

    orig_sync = state_module.google_sheets.sync_day
    orig_date = state_module.date
    state_module.google_sheets.sync_day = fake_sync_day
    state_module.date = _FakeDate
    try:
        # First run ever: daily_last_reset starts at "", so there is
        # nothing to archive yet -- see maybe_reset_dailies's own doc
        # comment for why. Still returns True (a reset "happened": the
        # date got recorded) but writes no history entry.
        _set_fake_today(2026, 1, 1)
        did_reset = await s.maybe_reset_dailies()
        check("first-ever run returns True (date recorded)", did_reset, True)
        check("...but archives nothing", (await s.get_daily_history()), {})
        check("...and does not call Sheets sync", len(sync_calls), 0)

        # Same day again: no-op.
        did_reset = await s.maybe_reset_dailies()
        check("same-day re-check is a no-op", did_reset, False)

        # Mark one item done, advance to the next day: this DOES archive.
        await s.toggle_daily(1)
        _set_fake_today(2026, 1, 2)
        did_reset = await s.maybe_reset_dailies()
        check("day-2 run returns True", did_reset, True)

        history = await s.get_daily_history()
        check("2026-01-01 is now archived", "2026-01-01" in history, True)
        check("archived state reflects what was checked", history["2026-01-01"],
              {"1": True, "2": False})
        check("Sheets sync was called for the OUTGOING day", sync_calls[-1][0], "2026-01-01")

        dailies = await s.list_dailies()
        check("done flags reset for the new day",
              all(not d["done"] for d in dailies), True)

        # Multi-day outage: skip straight from day 2 to day 6 with no
        # calls in between (backend was off). Only day 2 (the single
        # most recent PRIOR day) gets archived; days 3-5 get NO entry at
        # all -- a fabricated "nothing done" record for days nothing ran
        # would be actively wrong, not just incomplete.
        _set_fake_today(2026, 1, 6)
        did_reset = await s.maybe_reset_dailies()
        check("multi-day-gap run returns True", did_reset, True)

        history = await s.get_daily_history()
        check("exactly 2 archived days exist (not 5)", len(history), 2)
        check("day 2 (the prior day) got archived", "2026-01-02" in history, True)
        for missing_day in ("2026-01-03", "2026-01-04", "2026-01-05"):
            check(f"the skipped-over day {missing_day} has NO entry (absent, not False)",
                  missing_day in history, False)
    finally:
        state_module.google_sheets.sync_day = orig_sync
        state_module.date = orig_date


async def test_force_daily_sync():
    print("\n=== /dailysync (force_daily_sync) ===")
    s = new_store()
    await s.add_daily(420, "7:00 AM", "Meditate")

    # Not configured in this environment (no backend/.env credentials),
    # so this exercises the REAL, un-mocked skip path end to end.
    ok, message = await s.force_daily_sync()
    check("unconfigured force_daily_sync reports failure, doesn't raise", ok, False)
    check_contains("...with the same message sync_day itself returns",
                    message, "not configured")


# --------------------------------------------------- google_sheets.py tests


class _FakeWorksheet:
    """An in-memory stand-in for gspread.Worksheet, just enough surface
    for google_sheets.py's own calls (row_values, col_values, update,
    batch_update) -- same technique the module's own author used for its
    pre-ship self-test (see this project's memory), rebuilt here as a
    committed test rather than a discarded scratch script."""

    def __init__(self):
        self.grid = {}  # (row, col) 1-based -> value
        self.max_row = 0
        self.max_col = 0

    def _set(self, row, col, value):
        self.grid[(row, col)] = value
        self.max_row = max(self.max_row, row)
        self.max_col = max(self.max_col, col)

    def row_values(self, row):
        return [self.grid.get((row, c), "") for c in range(1, self.max_col + 1)]

    def col_values(self, col):
        return [self.grid.get((r, col), "") for r in range(1, self.max_row + 1)]

    def update(self, range_name, values):
        row, col = a1_to_rowcol(range_name)
        for j, v in enumerate(values[0]):
            self._set(row, col + j, v)

    def batch_update(self, updates, value_input_option=None):
        for u in updates:
            rng = u["range"]
            vals = u["values"]
            if ":" in rng:
                start, _end = rng.split(":")
                srow, scol = a1_to_rowcol(start)
                for j, v in enumerate(vals[0]):
                    self._set(srow, scol + j, v)
            else:
                row, col = a1_to_rowcol(rng)
                self._set(row, col, vals[0][0])


class _FakeSpreadsheet:
    def __init__(self):
        self._worksheets = {}

    def worksheet(self, name):
        if name not in self._worksheets:
            raise WorksheetNotFound(name)
        return self._worksheets[name]

    def add_worksheet(self, title, rows, cols):
        ws = _FakeWorksheet()
        self._worksheets[title] = ws
        return ws


async def test_sync_day_not_configured():
    print("\n=== google_sheets.sync_day: not configured (real, unmocked path) ===")
    orig = config.HAS_GOOGLE_SHEETS
    config.HAS_GOOGLE_SHEETS = False
    try:
        ok, message = await google_sheets.sync_day("2026-01-01", [])
        check("returns False without touching gspread at all", ok, False)
        check_contains("message says why", message, "not configured")
    finally:
        config.HAS_GOOGLE_SHEETS = orig


async def test_sync_day_upsert_logic():
    print("\n=== google_sheets.sync_day: header append + idempotent upsert ===")
    await _drain_pending_tasks()  # flush stray background tasks before wiring up the fake spreadsheet
    fake_spreadsheet = _FakeSpreadsheet()
    orig_get_spreadsheet = google_sheets._get_spreadsheet
    orig_has_sheets = config.HAS_GOOGLE_SHEETS
    google_sheets._get_spreadsheet = lambda: fake_spreadsheet
    config.HAS_GOOGLE_SHEETS = True
    try:
        items_day1 = [{"id": 1, "time": "7:00 AM", "topic": "Meditate", "done": True}]
        ok, msg = await google_sheets.sync_day("2026-01-01", items_day1)
        check("first-ever sync succeeds", ok, True)

        ws = fake_spreadsheet.worksheet(google_sheets.WORKSHEET_NAME)
        check("header row was created", ws.row_values(1), ["Date", "Meditate [D1]"])
        check("row 2 has the date + the habit's value", ws.row_values(2),
              ["2026-01-01", True])

        # Day 2: a NEW habit appears mid-stream -- must append a column,
        # not disturb the existing one.
        items_day2 = [
            {"id": 1, "time": "7:00 AM", "topic": "Meditate", "done": False},
            {"id": 2, "time": "8:00 AM", "topic": "Stretch", "done": True},
        ]
        ok, msg = await google_sheets.sync_day("2026-01-02", items_day2)
        check("second sync (new habit) succeeds", ok, True)
        check("header grew by exactly one column", ws.row_values(1),
              ["Date", "Meditate [D1]", "Stretch [D2]"])
        check("day 1's row is untouched by day 2's sync", ws.row_values(2),
              ["2026-01-01", True, ""])
        check("day 2's row has both habits", ws.row_values(3),
              ["2026-01-02", False, True])

        # Day 3: habit 1 gets "deleted" (simulated by simply not passing
        # it any more) -- its column must be left alone, not reused or
        # blanked retroactively, and the new row must leave that column
        # blank rather than writing a False into it.
        items_day3 = [{"id": 2, "time": "8:00 AM", "topic": "Stretch", "done": False}]
        ok, msg = await google_sheets.sync_day("2026-01-03", items_day3)
        check("third sync (habit 1 gone) succeeds", ok, True)
        check("no new column was added for a habit that vanished",
              ws.row_values(1), ["Date", "Meditate [D1]", "Stretch [D2]"])
        check("deleted habit's cell for the new row stays blank, not False",
              ws.row_values(4), ["2026-01-03", "", False])

        # Idempotent resync: calling sync_day again for day 1 (e.g. the
        # live fire-and-forget path firing again on the same day) must
        # UPDATE that row in place, never duplicate it.
        items_day1_later = [{"id": 1, "time": "7:00 AM", "topic": "Meditate", "done": True}]
        await google_sheets.sync_day("2026-01-01", items_day1_later)
        check("resyncing day 1 does not add a new row", ws.max_row, 4)
        check("...and updates the existing row's value", ws.row_values(2),
              ["2026-01-01", True, ""])
    finally:
        google_sheets._get_spreadsheet = orig_get_spreadsheet
        config.HAS_GOOGLE_SHEETS = orig_has_sheets


async def main():
    for t in (
        test_time_parsing,
        test_daily_state_crud,
        test_telegram_daily_add,
        test_fallback_chain_includes_daily,
        test_list_output_daily_section,
        test_dailyhistory,
        test_dailysync_unconfigured,
        test_live_sync_fires_on_mutation,
        test_maybe_reset_dailies,
        test_force_daily_sync,
        test_sync_day_not_configured,
        test_sync_day_upsert_logic,
    ):
        await t()

    print()
    if _failures:
        print(f"{len(_failures)} CHECK(S) FAILED ({_passes} passed)")
        for f in _failures:
            print(f"  - {f}")
        sys.exit(1)
    print(f"ALL {_passes} CHECKS PASSED")


if __name__ == "__main__":
    asyncio.run(main())
