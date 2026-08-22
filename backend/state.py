"""
Shared state store for the Kindle Dashboard backend.

Holds the single source of truth for tasks + Claude usage data. All
mutations (from the Telegram bot, the Anthropic usage poller, or a
connected Kindle client over the WebSocket) go through this class so
that:

  1. Every change is persisted to disk atomically (write to a temp
     file, then os.replace over the real file) so a crash/power-loss
     mid-write can never corrupt state.json or leave a half-written file.
  2. Every change is broadcast to all connected WebSocket clients via a
     callback, so Telegram edits show up on the Kindle and vice versa.

Concurrency: a single asyncio.Lock serializes mutations. This is a
personal single-user project with a handful of tasks, so a simple lock
is more than sufficient -- no need for anything fancier.
"""

import asyncio
import copy
import json
import logging
import os
import tempfile
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable, Optional

from . import google_sheets

logger = logging.getLogger("kindle_dashboard.state")

DEFAULT_STATE = {
    "tasks": [],
    "learnings": [],
    "claude_usage": {"tokens_today": 0, "last_updated": ""},
    "session_usage": {"percent": 0, "resets_at": "", "resets_label": "", "last_updated": ""},
    "lock_pin": "",
    "dailies": [],
    "daily_history": {},
    "daily_last_reset": "",
    "last_updated": "",
}

# Cheap insurance against a stray huge paste growing state.json unbounded --
# not a hard product requirement, just a sane ceiling. Applied here (not at
# each caller) so both the Telegram /add path and the Kindle WS add_task
# path get it for free.
MAX_TASK_TEXT_LEN = 500

# Guard against a fat-fingered page count ("3200000" for "320"). Books
# longer than this don't exist, and an absurd total makes the derived
# percentage useless rather than merely wrong.
MAX_BOOK_PAGES = 99999

BroadcastCallback = Callable[[dict], Awaitable[None]]


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class StateStore:
    def __init__(self, path: Path):
        self.path = path
        self._lock = asyncio.Lock()
        self._data: dict = self._load()
        self._broadcast_cb: Optional[BroadcastCallback] = None
        # Fire-and-forget Google Sheets sync tasks (see _fire_live_daily_sync
        # below) -- held here only so asyncio doesn't garbage-collect a task
        # while it's still in flight, a well-known asyncio.create_task()
        # footgun. Discarded via the task's own done-callback, so this never
        # grows unbounded.
        self._background_sync_tasks: set = set()

    def set_broadcast_callback(self, cb: BroadcastCallback) -> None:
        self._broadcast_cb = cb

    # ---------- persistence ----------

    def _load(self) -> dict:
        if self.path.exists():
            try:
                with open(self.path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                data.setdefault("tasks", [])
                # Existing state.json files predate learnings; setdefault
                # migrates them for free, which is why this store has no
                # schema version field to bump.
                data.setdefault("learnings", [])
                data.setdefault("claude_usage", {"tokens_today": 0, "last_updated": ""})
                data.setdefault(
                    "session_usage",
                    {"percent": 0, "resets_at": "", "resets_label": "", "last_updated": ""},
                )
                # Existing state.json files predate the PIN lock feature too.
                data.setdefault("lock_pin", "")
                # ...and the Daily habits feature.
                data.setdefault("dailies", [])
                data.setdefault("daily_history", {})
                data.setdefault("daily_last_reset", "")
                data.setdefault("last_updated", "")
                logger.info(
                    "Loaded existing state from %s (%d tasks, %d learnings)",
                    self.path, len(data["tasks"]), len(data["learnings"]),
                )
                return data
            except Exception as e:
                logger.error("Could not read state file %s, starting fresh: %s", self.path, e)
                # Preserve the unreadable file instead of just discarding
                # it -- a bad edit or freak corruption otherwise silently
                # wipes the whole task list with only a log line as a
                # trace. Best-effort: if even this fails, still fall
                # through to starting fresh rather than crashing startup.
                try:
                    backup_path = self.path.with_name(
                        f"{self.path.stem}.corrupt-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}{self.path.suffix}"
                    )
                    self.path.rename(backup_path)
                    logger.error("Unreadable state file preserved at %s for inspection.", backup_path)
                except OSError as backup_err:
                    logger.error("Could not preserve unreadable state file: %s", backup_err)
        else:
            logger.info("No existing state file at %s, starting fresh.", self.path)
        return copy.deepcopy(DEFAULT_STATE)

    def _persist(self) -> None:
        """Atomic write: write to a temp file in the same directory, then
        rename over the real file. On POSIX and Windows, os.replace() is
        atomic as long as source and destination are on the same volume,
        which they are here since the temp file is created alongside."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(
            dir=str(self.path.parent), prefix=".state_", suffix=".tmp"
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(self._data, f, indent=2)
            os.replace(tmp_path, self.path)
        except Exception:
            try:
                os.remove(tmp_path)
            except OSError:
                pass
            raise

    def snapshot(self) -> dict:
        """A deep copy of the current state, safe to hand out / serialize.

        `dailies` is sorted by time-of-day here, at the wire boundary,
        rather than at storage time -- internal storage stays in insertion
        (creation) order, which keeps add_daily/toggle_daily/delete_daily
        simple, while every consumer of a snapshot (the Kindle, `/state`,
        Telegram's /list and /dailyhistory) gets a day laid out in
        chronological order for free, matching the "Google Calendar day
        view" the Daily tab is modeled on. Python's sort is stable, so two
        items at the identical minute keep their relative creation order
        rather than shuffling on every redraw.
        """
        data = copy.deepcopy(self._data)
        data["dailies"] = sorted(data["dailies"], key=lambda d: d["minutes"])
        return data

    async def _commit_locked(self) -> None:
        """Must be called while holding self._lock. Stamps last_updated
        and persists to disk."""
        self._data["last_updated"] = _utcnow_iso()
        self._persist()

    async def _broadcast(self) -> None:
        if self._broadcast_cb is None:
            return
        try:
            await self._broadcast_cb(self.snapshot())
        except Exception as e:
            logger.error("Broadcast to WebSocket clients failed: %s", e)

    # ---------- task operations (used by both Telegram bot and Kindle WS) ----------

    async def add_task(self, text: str) -> dict:
        text = text[:MAX_TASK_TEXT_LEN]
        async with self._lock:
            existing_ids = [t["id"] for t in self._data["tasks"]]
            new_id = (max(existing_ids) if existing_ids else 0) + 1
            task = {"id": new_id, "text": text, "done": False}
            self._data["tasks"].append(task)
            await self._commit_locked()
        await self._broadcast()
        return task

    async def list_tasks(self) -> list:
        async with self._lock:
            return copy.deepcopy(self._data["tasks"])

    async def mark_done(self, task_id: int) -> bool:
        """Sets a task's done flag to True (Telegram /done semantics).
        Returns True if the task existed."""
        found = False
        async with self._lock:
            for t in self._data["tasks"]:
                if t["id"] == task_id:
                    t["done"] = True
                    found = True
                    break
            if found:
                await self._commit_locked()
        if found:
            await self._broadcast()
        return found

    async def toggle_task(self, task_id: int) -> Optional[bool]:
        """Flips a task's done flag (Kindle checkbox-tap semantics).
        Returns the new done state, or None if the task doesn't exist."""
        new_state = None
        async with self._lock:
            for t in self._data["tasks"]:
                if t["id"] == task_id:
                    t["done"] = not t["done"]
                    new_state = t["done"]
                    break
            if new_state is not None:
                await self._commit_locked()
        if new_state is not None:
            await self._broadcast()
        return new_state

    async def delete_task(self, task_id: int) -> bool:
        found = False
        async with self._lock:
            before = len(self._data["tasks"])
            self._data["tasks"] = [t for t in self._data["tasks"] if t["id"] != task_id]
            found = len(self._data["tasks"]) < before
            if found:
                await self._commit_locked()
        if found:
            await self._broadcast()
        return found

    # ---------- learning operations (courses + books) ----------
    #
    # A "learning" is one thing you're working through. Two kinds:
    #
    #   course -- you set the completion percentage by hand
    #   book   -- you record what page you're on; percent is derived
    #
    # Both render identically on the Kindle: a name, a progress bar, and
    # a percent number. That is the whole point of the shape below -- see
    # _recompute() for why the renderer never has to branch on "kind".
    #
    # Learnings have their own id sequence, independent of tasks. They're
    # displayed everywhere as "L3" while tasks stay "#3", so the two
    # namespaces are visibly distinct in every reply and on-screen label;
    # the "L" is a rendering convention, never part of the stored id.

    @staticmethod
    def _recompute(item: dict) -> None:
        """Derives percent/detail/done from an item's raw fields, in place.

        Every learning mutator calls this immediately before committing,
        which is what keeps the three derived fields from ever drifting
        out of sync with pages_read/total_pages. Same reasoning as
        MAX_TASK_TEXT_LEN being applied inside add_task rather than at
        each caller: put the invariant in one place that callers can't
        route around.

        Why derive at WRITE time and store the result, rather than
        deriving when the Kindle draws:

          - The renderer then reads four fields that mean the same thing
            for every row (name, percent, detail, done) with no
            conditional on kind, no division, and no zero-check. That
            code runs on the device, in Lua, where a divide-by-zero from
            one bad JSON edit surfaces as a dead screen with no traceback.
          - Telegram replies and the Kindle then quote the same numbers
            by construction, instead of via two implementations that have
            to be kept agreeing.
        """
        if item.get("kind") == "book":
            # MAX_BOOK_PAGES is enforced HERE as well as at the command
            # layer, for the same reason MAX_TASK_TEXT_LEN is applied
            # inside add_task rather than at each caller: the invariant
            # belongs where no caller can route around it. The command
            # layer still checks it separately so it can tell the user
            # their page count looked wrong, instead of silently storing
            # a different number than they typed.
            total = max(0, min(int(item.get("total_pages") or 0), MAX_BOOK_PAGES))
            read = int(item.get("pages_read") or 0)
            read = max(0, min(read, total))
            item["pages_read"] = read
            item["total_pages"] = total
            # Integer FLOOR, deliberately not rounding: floor makes
            # `percent == 100` true if and only if pages_read ==
            # total_pages. With rounding, page 319 of 320 displays as
            # "100%" while done stays False -- a bar that says finished
            # next to an item that isn't, and the single rule
            # `done = (percent == 100)` would stop holding for books.
            item["percent"] = (read * 100) // total if total > 0 else 0
            item["detail"] = f"{read}/{total} pages"
        else:
            pct = int(item.get("percent") or 0)
            item["percent"] = max(0, min(100, pct))
            item["pages_read"] = 0
            item["total_pages"] = 0
            item["detail"] = ""

        item["done"] = item["percent"] == 100

    def _find_learning(self, learning_id: int) -> Optional[dict]:
        """Caller must hold self._lock."""
        for item in self._data["learnings"]:
            if item["id"] == learning_id:
                return item
        return None

    async def _apply_learning_change(self, learning_id: int, mutate) -> Optional[dict]:
        """Find, mutate, recompute, persist, broadcast -- as ONE unit.

        `mutate(item)` sets whatever raw field the caller is changing
        (percent, pages_read, total_pages); this method owns everything
        around it. Returns a copy of the updated item, or None if no such
        learning exists.

        The whole find-mutate-recompute-persist sequence runs inside a
        SINGLE hold of the lock. An earlier version split it in two --
        writing the raw field under the lock, releasing, then recomputing
        under a second acquisition -- which opened an await boundary in
        the middle of one logical mutation. Two things could slip through
        it:

          - A snapshot() taken in that window saw a half-updated item:
            pages_read already changed but percent/detail/done still
            stale, so the Kindle could render "37%" beside "200/320
            pages". That is exactly the drift _recompute() exists to make
            impossible, reintroduced by the plumbing around it.
          - If the item were deleted in that window, the recompute would
            operate on an orphaned dict and the reply would confirm a
            change to something that no longer exists.

        Neither is reachable today (the Telegram poll loop handles
        commands strictly one at a time, and the Kindle can't mutate
        learnings at all), but both become live the moment anything else
        can write. Keeping it to one critical section costs nothing.

        Note the lock is NOT re-entrant, so nothing called from inside the
        block below may acquire it: _recompute is a pure staticmethod and
        _commit_locked documents that it must be called while held. The
        broadcast deliberately happens after release, matching every
        other mutator in this class.
        """
        async with self._lock:
            item = self._find_learning(learning_id)
            if item is None:
                return None
            mutate(item)
            self._recompute(item)
            await self._commit_locked()
            result = copy.deepcopy(item)
        await self._broadcast()
        return result

    async def add_course(self, name: str) -> dict:
        name = name[:MAX_TASK_TEXT_LEN]
        async with self._lock:
            existing_ids = [item["id"] for item in self._data["learnings"]]
            new_id = (max(existing_ids) if existing_ids else 0) + 1
            item = {
                "id": new_id, "kind": "course", "name": name,
                "percent": 0, "detail": "", "done": False,
                "pages_read": 0, "total_pages": 0,
            }
            self._recompute(item)
            self._data["learnings"].append(item)
            await self._commit_locked()
        await self._broadcast()
        return item

    async def add_book(self, name: str, total_pages: int) -> dict:
        name = name[:MAX_TASK_TEXT_LEN]
        async with self._lock:
            existing_ids = [item["id"] for item in self._data["learnings"]]
            new_id = (max(existing_ids) if existing_ids else 0) + 1
            item = {
                "id": new_id, "kind": "book", "name": name,
                "percent": 0, "detail": "", "done": False,
                "pages_read": 0, "total_pages": int(total_pages),
            }
            self._recompute(item)
            self._data["learnings"].append(item)
            await self._commit_locked()
        await self._broadcast()
        return item

    async def list_learnings(self) -> list:
        async with self._lock:
            return copy.deepcopy(self._data["learnings"])

    async def get_learning(self, learning_id: int) -> Optional[dict]:
        """A copy of one learning, or None. Used by the bot to decide
        which command applies (a course rejects /page, a book rejects
        /percent) and to phrase the error naming the right one."""
        async with self._lock:
            item = self._find_learning(learning_id)
            return copy.deepcopy(item) if item else None

    async def set_learning_percent(self, learning_id: int, percent: int) -> Optional[dict]:
        """Course progress. Returns the updated item, or None if no such
        learning. Range validation lives in the caller so it can report
        the out-of-range value back to the user rather than silently
        clamping -- see telegram_bot.py."""

        def mutate(item):
            item["percent"] = int(percent)

        return await self._apply_learning_change(learning_id, mutate)

    async def set_learning_pages(self, learning_id: int, pages_read: int) -> Optional[dict]:
        """Book progress, as an absolute page number ('I'm on page 120'),
        not a delta. _recompute clamps it to the total, so this can never
        persist a page count past the end of the book."""

        def mutate(item):
            item["pages_read"] = int(pages_read)

        return await self._apply_learning_change(learning_id, mutate)

    async def set_learning_total_pages(self, learning_id: int, total_pages: int) -> Optional[dict]:
        """Corrects a book's page count. Exists because the /book command
        parses the total as a trailing number, which mis-splits on a
        title that itself ends in a digit -- this is the one-command
        repair for that, so the mis-parse costs a correction rather than
        a delete and re-add."""

        def mutate(item):
            item["total_pages"] = int(total_pages)

        return await self._apply_learning_change(learning_id, mutate)

    async def mark_learning_done(self, learning_id: int) -> Optional[dict]:
        """'I finished this' without typing the exact page. Books jump to
        the last page, courses to 100% -- both then land on done=True
        through the same _recompute path as any other write, so there is
        no second definition of what finished means."""

        def mutate(item):
            if item.get("kind") == "book":
                item["pages_read"] = int(item.get("total_pages") or 0)
            else:
                item["percent"] = 100

        return await self._apply_learning_change(learning_id, mutate)

    async def delete_learning(self, learning_id: int) -> bool:
        found = False
        async with self._lock:
            before = len(self._data["learnings"])
            self._data["learnings"] = [
                item for item in self._data["learnings"] if item["id"] != learning_id
            ]
            found = len(self._data["learnings"]) < before
            if found:
                await self._commit_locked()
        if found:
            await self._broadcast()
        return found

    # ---------- daily habits ----------
    #
    # A recurring checklist, modeled on a calendar day view rather than a
    # to-do list: each item has a time-of-day and a topic, and the LIST of
    # items persists forever -- only each item's `done` flag resets, once a
    # day, at local midnight (see maybe_reset_dailies below). Telegram is
    # the only way to ADD an item (a time is a number, and the Kindle's
    # on-screen keyboard has no digits -- same reasoning as Learning), but
    # unlike Learning, toggling done and deleting an item both happen ON
    # the Kindle, reusing the exact tap/double-tap-to-delete interactions
    # the Today task list already has, since neither needs a digit.
    #
    # `minutes` (0-1439, minutes since local midnight) is the sort key;
    # `time` is a precomputed display string ("7:00 AM") computed ONCE by
    # the Telegram command parser at add-time (see telegram_bot.py's
    # _parse_time_of_day) and then just displayed verbatim everywhere --
    # the Kindle draws it as plain text with zero time-formatting logic of
    # its own, and Telegram's own replies reuse the same stored string, so
    # there is exactly one place time-formatting rules live.

    async def add_daily(self, minutes: int, time_display: str, topic: str) -> dict:
        topic = topic[:MAX_TASK_TEXT_LEN]
        async with self._lock:
            existing_ids = [d["id"] for d in self._data["dailies"]]
            new_id = (max(existing_ids) if existing_ids else 0) + 1
            item = {
                "id": new_id, "minutes": minutes, "time": time_display,
                "topic": topic, "done": False,
            }
            self._data["dailies"].append(item)
            await self._commit_locked()
        await self._broadcast()
        self._fire_live_daily_sync()
        return item

    async def list_dailies(self) -> list:
        """Time-sorted, matching snapshot()'s wire-format ordering -- see
        its doc comment for why sorting happens at the read boundary
        rather than in storage."""
        async with self._lock:
            items = copy.deepcopy(self._data["dailies"])
        return sorted(items, key=lambda d: d["minutes"])

    async def get_daily(self, daily_id: int) -> Optional[dict]:
        async with self._lock:
            for d in self._data["dailies"]:
                if d["id"] == daily_id:
                    return copy.deepcopy(d)
        return None

    async def toggle_daily(self, daily_id: int) -> Optional[bool]:
        """Flips a daily item's done flag (the Kindle checkbox-tap case,
        mirrors toggle_task). Returns the new done state, or None if no
        such item exists."""
        new_state = None
        async with self._lock:
            for d in self._data["dailies"]:
                if d["id"] == daily_id:
                    d["done"] = not d["done"]
                    new_state = d["done"]
                    break
            if new_state is not None:
                await self._commit_locked()
        if new_state is not None:
            await self._broadcast()
            self._fire_live_daily_sync()
        return new_state

    async def mark_daily_done(self, daily_id: int) -> Optional[dict]:
        """Telegram's /done Dn -- always sets done=True (mirrors mark_done
        for tasks), as opposed to the Kindle's checkbox tap, which toggles.
        Returns the updated item, or None if no such item exists."""
        found_item = None
        async with self._lock:
            for d in self._data["dailies"]:
                if d["id"] == daily_id:
                    d["done"] = True
                    found_item = d
                    break
            if found_item is not None:
                await self._commit_locked()
        if found_item is not None:
            await self._broadcast()
            self._fire_live_daily_sync()
        return copy.deepcopy(found_item) if found_item is not None else None

    async def delete_daily(self, daily_id: int) -> bool:
        found = False
        async with self._lock:
            before = len(self._data["dailies"])
            self._data["dailies"] = [d for d in self._data["dailies"] if d["id"] != daily_id]
            found = len(self._data["dailies"]) < before
            if found:
                await self._commit_locked()
        if found:
            await self._broadcast()
            self._fire_live_daily_sync()
        return found

    def _fire_live_daily_sync(self) -> None:
        """Best-effort, fire-and-forget push of TODAY's current daily-habit
        state to Google Sheets, kicked off after every add/toggle/delete so
        the sheet reflects same-day progress instead of only appearing a
        full day late -- see maybe_reset_dailies below for the separate,
        AUTHORITATIVE end-of-day write this doesn't replace.

        Deliberately NOT awaited by any caller: an on-device checkbox tap
        (or a Telegram reply) must never wait on a network round-trip to
        Google, and must succeed identically whether or not Sheets sync is
        even configured -- google_sheets.sync_day() already no-ops
        instantly when it isn't, but this function doesn't even need to
        know that; it just fires the task and returns.

        Reads self._data directly without re-acquiring self._lock. Every
        caller has ALREADY released the lock by the time it calls this (it
        runs after their own `async with self._lock` block, alongside
        their existing _broadcast() call) -- re-entering a non-reentrant
        asyncio.Lock here would deadlock. The tiny theoretical race (another
        mutation landing between release and this read) only affects a
        best-effort mirror one sync-cycle early or late, never the local
        source of truth, which is why it's an acceptable tradeoff here in a
        way it wouldn't be for _commit_locked/_broadcast themselves.
        """
        today = date.today().isoformat()
        items = [
            {"id": d["id"], "time": d["time"], "topic": d["topic"], "done": d["done"]}
            for d in self._data["dailies"]
        ]

        async def _run():
            try:
                ok, message = await google_sheets.sync_day(today, items)
                if not ok:
                    logger.warning("Daily habits: live Google Sheets sync skipped/failed: %s", message)
            except Exception as e:
                # google_sheets.sync_day is documented to never raise, but
                # a background task's exception otherwise vanishes into
                # asyncio's own "exception was never retrieved" log line
                # instead of this module's own clearer one -- cheap
                # insurance, not a sign the contract above is untrusted.
                logger.error("Daily habits: unexpected error during live Google Sheets sync: %s", e)

        task = asyncio.create_task(_run())
        self._background_sync_tasks.add(task)
        task.add_done_callback(self._background_sync_tasks.discard)

    async def maybe_reset_dailies(self) -> bool:
        """Checks whether the LOCAL calendar date has advanced past the
        last recorded reset, and if so archives the outgoing day's
        completion state (locally, and a best-effort authoritative push to
        Google Sheets) and clears every daily item's `done` flag for the
        new day. Returns True if a reset actually happened.

        Deliberately keyed off the LOCAL date (date.today(), no tzinfo)
        rather than UTC, unlike every timestamp elsewhere in this file --
        "resets at midnight" means the user's own midnight, not UTC's.
        Most US timezones sit 4-8 hours behind UTC, so using UTC here
        would roll the checklist over mid-afternoon or mid-evening instead
        of overnight.

        Deliberately polled on a plain interval (see daily_reset.py)
        rather than a precise sleep-until-midnight timer: this backend is
        NOT always running -- the user starts/stops it by hand via the
        ops/ scripts, and the laptop sleeps -- so a timer set to fire at
        an exact wall-clock moment would simply never fire if the process
        wasn't alive then. Comparing "is today different from the last
        recorded reset date" self-heals regardless of how long the gap
        was, at the cost of only ever being accurate to within one polling
        interval.

        If the backend was off across MORE than one midnight (the laptop
        was closed for several days), only the single most recent prior
        day gets archived under daily_history -- the days in between get
        no entry at all, deliberately: there is no way to know what would
        have been checked on a day nothing was running, and fabricating a
        false "nothing done" record would be actively wrong, not just
        incomplete. An ABSENT key in daily_history is therefore meaningful
        on its own -- it means "no data for this date" -- and is distinct
        from a PRESENT key mapping every item to False (a real day where
        nothing was completed). Any code that reads daily_history (see
        telegram_bot.py's /dailyhistory) must preserve that distinction
        rather than treating a missing date as an all-False day.
        """
        today = date.today().isoformat()
        async with self._lock:
            if self._data["daily_last_reset"] == today:
                return False

            previous = self._data["daily_last_reset"]
            outgoing_snapshot = None
            if previous:
                # Not the very first run ever (daily_last_reset starts as
                # "" and every item starts at done=False, so there is
                # nothing meaningful to archive the first time this runs).
                self._data["daily_history"][previous] = {
                    str(d["id"]): d["done"] for d in self._data["dailies"]
                }
                outgoing_snapshot = [
                    {"id": d["id"], "time": d["time"], "topic": d["topic"], "done": d["done"]}
                    for d in self._data["dailies"]
                ]

            for d in self._data["dailies"]:
                d["done"] = False
            self._data["daily_last_reset"] = today
            await self._commit_locked()
        await self._broadcast()

        if outgoing_snapshot is not None:
            try:
                ok, message = await google_sheets.sync_day(previous, outgoing_snapshot)
                log = logger.info if ok else logger.warning
                log("Daily habits: end-of-day Google Sheets sync for %s -- %s", previous, message)
            except Exception as e:
                # As in _fire_live_daily_sync: sync_day is documented not
                # to raise, but the local reset above has ALREADY
                # committed and broadcast by this point regardless -- a
                # Sheets failure here costs a log line, never a stuck
                # checklist.
                logger.error("Daily habits: unexpected error calling google_sheets.sync_day: %s", e)
        return True

    # ---------- Claude usage ----------

    async def set_usage(self, tokens_today: int) -> None:
        async with self._lock:
            self._data["claude_usage"] = {
                "tokens_today": tokens_today,
                "last_updated": _utcnow_iso(),
            }
            await self._commit_locked()
        await self._broadcast()

    # ---------- Claude session usage (personal plan 5-hour rate limit) ----------

    async def set_session_usage(self, percent: int, resets_at: str, resets_label: str) -> None:
        async with self._lock:
            self._data["session_usage"] = {
                "percent": percent,
                "resets_at": resets_at,
                "resets_label": resets_label,
                "last_updated": _utcnow_iso(),
            }
            await self._commit_locked()
        await self._broadcast()

    # ---------- screen-lock PIN ----------
    #
    # Verified entirely on the Kindle itself (see kindle-daemon/src/daemon.lua),
    # not round-tripped to this backend on every unlock attempt -- the device
    # must still be unlockable during a WiFi/backend outage, same reasoning as
    # why the WebSocket is left connected but never required for the lock
    # itself to function. That means the PIN has to live in the state blob
    # broadcast to the Kindle like everything else here, in plain text: this
    # project has no authentication or transport encryption on ANY of its
    # WebSocket traffic (see backend/README.md's "no authentication on these
    # endpoints" note), so a 4-digit PIN sitting in that same broadcast is not
    # a new trust boundary, just an existing one applied to one more field.
    # `""` means "no PIN configured" -- the Kindle's power button unlocks
    # instantly in that case, exactly like before this feature existed.

    async def set_lock_pin(self, pin: str) -> None:
        async with self._lock:
            self._data["lock_pin"] = pin
            await self._commit_locked()
        await self._broadcast()

    # ---------- daily habits: history + manual sync ----------

    async def get_daily_history(self) -> dict:
        """A copy of the full local daily_history archive, keyed by ISO
        date string. Callers (currently only Telegram's /dailyhistory)
        must treat an ABSENT date key as "no data recorded", distinct
        from a PRESENT key mapping every item to False -- see
        maybe_reset_dailies's doc comment for why that distinction
        exists and must be preserved rather than collapsed."""
        async with self._lock:
            return copy.deepcopy(self._data["daily_history"])

    async def force_daily_sync(self) -> tuple:
        """Telegram's /dailysync -- an AWAITED push of today's current
        daily-habit state to Google Sheets, unlike the silent
        fire-and-forget _fire_live_daily_sync used after every
        add/toggle/delete. Exists so a user setting up Sheets for the
        first time gets a real success/failure message back instead of
        having to guess whether a background task worked. Returns
        google_sheets.sync_day's own (ok, message) tuple unchanged."""
        today = date.today().isoformat()
        async with self._lock:
            items = [
                {"id": d["id"], "time": d["time"], "topic": d["topic"], "done": d["done"]}
                for d in self._data["dailies"]
            ]
        return await google_sheets.sync_day(today, items)
