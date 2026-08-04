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
    "claude_usage": {"tokens_today": 0, "last_updated": ""},
    "session_usage": {"percent": 0, "resets_at": "", "resets_label": "", "last_updated": ""},
    "last_updated": "",
}

# Cheap insurance against a stray huge paste growing state.json unbounded --
# not a hard product requirement, just a sane ceiling. Applied here (not at
# each caller) so both the Telegram /add path and the Kindle WS add_task
# path get it for free.
MAX_TASK_TEXT_LEN = 500

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
                data.setdefault("claude_usage", {"tokens_today": 0, "last_updated": ""})
                data.setdefault(
                    "session_usage",
                    {"percent": 0, "resets_at": "", "resets_label": "", "last_updated": ""},
                )
                data.setdefault("last_updated", "")
                logger.info("Loaded existing state from %s (%d tasks)", self.path, len(data["tasks"]))
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
