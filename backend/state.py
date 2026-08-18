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
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable, Optional

logger = logging.getLogger("kindle_dashboard.state")

DEFAULT_STATE = {
    "tasks": [],
    "learnings": [],
    "claude_usage": {"tokens_today": 0, "last_updated": ""},
    "session_usage": {"percent": 0, "resets_at": "", "resets_label": "", "last_updated": ""},
    "lock_pin": "",
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
        """A deep copy of the current state, safe to hand out / serialize."""
        return copy.deepcopy(self._data)

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
