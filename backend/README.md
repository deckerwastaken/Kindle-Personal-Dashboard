# Kindle Dashboard Backend (v2)

Always-on local service that runs on your Windows laptop. It:

1. Runs the Telegram bot (`/add`, `/list`, `/done`, `/delete`, `/help`) from a single
   authorized chat, same as the v1 prototype.
2. Polls the Anthropic Admin API every 15 minutes for today's total token usage.
3. Persists all state (tasks + Claude usage) to a local JSON file, atomically.
4. Pushes state to the Kindle daemon over a persistent **WebSocket** (`/ws`) instead of
   the Kindle polling a third party (jsonbin) -- this replaces jsonbin.io entirely.
5. Accepts actions **from** the Kindle over that same WebSocket (e.g. tapping a
   checkbox toggles a task) so both Telegram and the Kindle manipulate the same
   shared state.

This document is the contract for whoever builds the Kindle-side daemon -- read the
**WebSocket protocol** section carefully; that's what you build against.

---

## Setup

1. Install Python 3.11+ (tested on 3.14) and the dependencies:

   ```
   cd "<path to the folder you downloaded this project into>"
   python -m pip install -r backend/requirements.txt
   ```

2. Create your secrets file:

   ```
   copy backend\.env.example backend\.env
   ```

   Then edit `backend/.env` and fill in:

   | Variable              | Required? | Notes                                                            |
   |------------------------|-----------|-------------------------------------------------------------------|
   | `TELEGRAM_TOKEN`       | Yes (for bot) | From @BotFather. If left as the placeholder, the Telegram bot is disabled and the rest of the app still runs normally. |
   | `CHAT_ID`              | Yes (for bot) | Your numeric Telegram chat ID -- the only chat the bot accepts commands from. |
   | `ANTHROPIC_ADMIN_KEY`  | Optional  | Must start with `sk-ant-admin`. If absent/placeholder, org-level Claude usage tracking is disabled and everything else still runs. |
   | `CLAUDE_SESSION_KEY`   | Optional  | Your claude.ai `sessionKey` browser cookie. If absent/placeholder, the session-usage (5-hour rate limit) card is disabled and everything else still runs. Treat like a password -- see `claude_session_usage.py`. |
   | `CLAUDE_ORG_ID`        | Optional  | Your claude.ai organization ID, needed alongside `CLAUDE_SESSION_KEY`. |

   `backend/.env` is git-ignored (both by the repo root `.gitignore` and
   `backend/.gitignore`) -- never commit real secrets.

   **Getting `CLAUDE_SESSION_KEY` and `CLAUDE_ORG_ID` (optional, advanced -- skip
   this if you don't want the session-usage card; everything else works fine
   without it):**
   1. In a browser, log into [claude.ai](https://claude.ai) normally.
   2. Open Developer Tools (press `F12`, or right-click the page and choose
      "Inspect").
   3. Go to the **Application** tab (Chrome/Edge) or **Storage** tab (Firefox).
   4. In the left sidebar, find **Cookies** → `https://claude.ai`.
   5. Find the row named `sessionKey`. Copy its **Value** column (a long string
      starting with `sk-ant-sid01-...`) -- that's `CLAUDE_SESSION_KEY`.
   6. For `CLAUDE_ORG_ID`: switch to the **Network** tab, refresh the page, and
      click any request whose URL contains `/organizations/`. The long ID in
      that URL (a UUID like `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) is your
      `CLAUDE_ORG_ID`.
   7. Paste both into `backend/.env`. Treat `CLAUDE_SESSION_KEY` like a
      password, not an API key -- it's your actual login session, not a
      scoped/revocable credential (see `claude_session_usage.py`'s module
      docstring for more on what it's used for).

3. Run the server:

   ```
   uvicorn backend.main:app --host 0.0.0.0 --port 8000
   ```

   Run this from the repo root (the folder you downloaded this project into), since
   `backend` needs to be importable as a package. Binding `0.0.0.0` (not
   `127.0.0.1`) is what lets the Kindle reach it over the home WiFi network at
   `http://<laptop-lan-ip>:8000`.

   Logs go to stdout. Leave the window open, or -- to have it start
   automatically at login, restart itself on crash, and log to a file
   instead -- see `backend/ops/AUTOSTART_SETUP.md` for a beginner-friendly,
   double-click setup using Windows Task Scheduler.

4. State is stored at `backend/data/state.json`, written atomically (temp file +
   rename) so a crash or power loss mid-write can't corrupt it. Delete this file to
   reset to a blank task list.

---

## Endpoints

| Method | Path      | Description                                                         |
|--------|-----------|----------------------------------------------------------------------|
| GET    | `/health` | Liveness check. Returns `{"status": "ok"}`.                          |
| GET    | `/state`  | Read-only snapshot of current state (same shape as the WS push). Handy for debugging with `curl` without opening a WebSocket. |
| WS     | `/ws`     | The main integration point for the Kindle daemon. See protocol below. |

There is no authentication on these endpoints -- this is a personal project running
only on the home LAN, matching the "one user, one Kindle" scope. Do not expose this
port to the public internet.

---

## WebSocket protocol (`/ws`)

Connect once and keep the connection open (e.g. reconnect with backoff on drop). All
messages in both directions are single-line JSON text frames (`websocket.send_text` /
`ws.recv()` -- not binary frames).

### Backend -> Kindle (state pushes)

**On connect**, the backend immediately sends one full-state message. **After that**,
every time state changes for *any* reason -- a Telegram command, the 15-minute Claude
usage poll, the 5-minute Claude session-usage poll, or an action the Kindle itself
just sent -- the backend broadcasts the
same full-state shape to *every* connected client (including the one that triggered
the change). The Kindle daemon should simply replace its in-memory view with whatever
it last received; there is no incremental diffing.

**Shape:**

```json
{
  "tasks": [
    {"id": 1, "text": "Buy milk", "done": false},
    {"id": 2, "text": "Write handoff doc", "done": true}
  ],
  "claude_usage": {
    "tokens_today": 128340,
    "last_updated": "2026-07-30T14:32:10.482193+00:00"
  },
  "session_usage": {
    "percent": 6,
    "resets_at": "2026-08-04T15:20:00+00:00",
    "resets_label": "Resets in 4 hr 41 min",
    "last_updated": "2026-08-04T10:39:12.001482+00:00"
  },
  "last_updated": "2026-07-30T14:32:10.482201+00:00"
}
```

Field notes:
- `tasks`: array, order = insertion order (not sorted by done-state or id).
- `tasks[].id`: integer, stable, unique. Never reused after a delete -- new tasks get
  `max(existing_ids) + 1` (or `1` if the list is empty).
- `tasks[].done`: boolean.
- `claude_usage.tokens_today`: integer, total input+output tokens for the current UTC
  day. `0` until the first successful poll, or if usage tracking is disabled (no
  admin key configured).
- `claude_usage.last_updated`: ISO-8601 UTC timestamp of the last successful Anthropic
  usage fetch, or `""` if it has never succeeded.
- `session_usage`: the personal Pro/Max plan's 5-hour rate-limit window (what claude.ai's
  own web-app "Usage" page shows), via an unofficial endpoint -- see
  `claude_session_usage.py` for details. A completely different data source from
  `claude_usage` above.
- `session_usage.percent`: integer 0-100, how much of the current 5-hour session limit
  has been used. `0` until the first successful poll, or if session-usage tracking is
  disabled (no `CLAUDE_SESSION_KEY`/`CLAUDE_ORG_ID` configured).
- `session_usage.resets_at`: ISO-8601 UTC timestamp of when the session window resets,
  straight from the API, or `""` if unavailable.
- `session_usage.resets_label`: pre-formatted human string (e.g. `"Resets in 4 hr 41
  min"`), computed server-side at poll time so the Kindle daemon doesn't need to parse
  ISO-8601 timestamps. `""` if unavailable.
- `session_usage.last_updated`: ISO-8601 UTC timestamp of the last successful session-
  usage fetch, or `""` if it has never succeeded.
- top-level `last_updated`: ISO-8601 UTC timestamp of the last state mutation of any
  kind (bump this is what changed, not `claude_usage.last_updated`, if you need "is
  this fresh" logic for the whole payload).

### Kindle -> Backend (actions)

Send a JSON object with an `"action"` field. Every action triggers a mutation (if
valid) followed by the standard broadcast above to all clients -- **the action itself
gets no separate "success" reply**, you just see the new state arrive. If the action
is invalid, you get an `{"error": ...}` reply instead (see below) and the connection
stays open.

| Action        | Required fields          | Effect                                      |
|---------------|---------------------------|----------------------------------------------|
| `add_task`      | `text` (non-empty string) | Appends a new task with `done: false`.        |
| `toggle_task`   | `id` (integer)            | Flips that task's `done` flag (the checkbox-tap case). |
| `delete_task`   | `id` (integer)            | Removes that task entirely.                   |
| `refresh_usage` | none                      | Forces an immediate `session_usage` re-fetch instead of waiting for the next scheduled poll. Rate-limited server-side: one real fetch per `MIN_MANUAL_REFRESH_INTERVAL_SECONDS` (10s) and at most `MAX_MANUAL_REFRESHES_PER_HOUR` (20) -- see `claude_session_usage.py`. Either limit rejects with a `refresh_failed` error instead of hitting claude.ai again. |

**Examples:**

```json
{"action": "add_task", "text": "Pick up dry cleaning"}
```

```json
{"action": "toggle_task", "id": 3}
```

```json
{"action": "delete_task", "id": 3}
```

There is intentionally no `mark_done` action mirroring Telegram's `/done` (which
always sets `done: true`) -- for a UI checkbox, toggling is the natural gesture. If
you need "mark done" specifically, send `toggle_task` only when the current state
(from the last broadcast you received) is `false`.

### Error replies

Sent only to the client whose message caused the problem (not broadcast). The
connection is **not** closed after an error -- keep using it normally.

```json
{"error": "invalid_json", "detail": "Message was not valid JSON"}
{"error": "invalid_message", "detail": "Message must be a JSON object"}
{"error": "bad_request", "detail": "add_task requires non-empty 'text'"}
{"error": "bad_request", "detail": "toggle_task requires integer 'id'"}
{"error": "not_found", "detail": "No task #999"}
{"error": "refresh_failed", "detail": "Please wait 7s before refreshing again"}
{"error": "unknown_action", "detail": "Unrecognized action: 'bogus'"}
{"error": "internal_error", "detail": "<exception message>"}
```

`error` is a stable machine-readable code; `detail` is a human-readable string that
may change wording -- don't parse it, just log/display it.

### Practical notes for the Kindle daemon implementer

- **Reconnect logic is your responsibility.** If the WebSocket drops (laptop sleep,
  WiFi blip, backend restart), reconnect with backoff. On reconnect you'll get a fresh
  full-state push immediately, so no special "resync" handshake is needed.
- **Idempotent UI updates**: since every action (including your own) comes back to
  you via the broadcast, the simplest correct client just re-renders from whatever
  full-state payload arrives, rather than optimistically updating local state before
  the broadcast confirms it. This avoids drift if two things touch a task's state
  around the same time (e.g. you tap a checkbox right as a Telegram `/done` lands).
- **Task IDs are ints, not strings** -- send `{"id": 3}`, not `{"id": "3"}`, or you'll
  get a `bad_request` error.
- `GET /state` (plain HTTP, not WS) returns the exact same JSON shape if you ever want
  to sanity-check from a browser or `curl` without touching the WebSocket.

---

## Architecture notes

- Single FastAPI/uvicorn process (`backend/main.py`). No database -- state is one
  small JSON file (personal task list, not meant to scale past a few dozen items).
- `backend/state.py` (`StateStore`) is the single source of truth for all mutations.
  Both the Telegram bot and the Kindle WebSocket handler call the same methods
  (`add_task`, `toggle_task`, `mark_done`, `delete_task`, `set_usage`), so there's one
  code path for "change a task" no matter who asked for it, and it always: acquires an
  `asyncio.Lock` -> mutates -> persists atomically -> broadcasts to all WS clients.
- `backend/ws_manager.py` (`ConnectionManager`) tracks connected WebSocket clients and
  broadcasts to all of them; dead connections are pruned automatically on send
  failure.
- `backend/telegram_bot.py` and `backend/anthropic_usage.py` are asyncio background
  tasks started in `main.py`'s FastAPI `lifespan`, using `httpx.AsyncClient` (not
  blocking `requests`). Each polling loop wraps its body in try/except so a bad
  token/key or a transient network error is logged and skipped, never crashes the
  loop or the app.
- Auto-start, auto-restart-on-crash, and file logging are handled by
  `backend/ops/` (a Task Scheduler-based wrapper, chosen over a raw manual
  `uvicorn` command or a third-party service tool like NSSM for the best
  reliability-to-friction ratio on a single personal Windows laptop). See
  `backend/ops/AUTOSTART_SETUP.md` for setup and day-to-day use.
