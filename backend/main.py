"""
Kindle Dashboard Backend (v2)
------------------------------
Single FastAPI/uvicorn process that:

  1. Serves a persistent WebSocket at /ws that the Kindle daemon connects
     to. On connect it immediately receives the full current state, and
     after that receives a fresh broadcast every time state changes (from
     Telegram, the Claude usage poller, or the Kindle itself).
  2. Runs the Telegram bot (same commands/security model as v1) as an
     asyncio background task.
  3. Runs the Anthropic Admin API usage poller (same 15-min cadence) as
     another asyncio background task.
  4. Runs the claude.ai session-usage poller (5-min cadence, unofficial
     endpoint -- see claude_session_usage.py) as another background task.
  5. Watches for the local calendar date changing and resets the Daily
     habits checklist at midnight, archiving the outgoing day (locally,
     and to Google Sheets if configured -- see daily_reset.py).
  6. Persists all state to backend/data/state.json with atomic writes.

Run with:
    uvicorn backend.main:app --host 0.0.0.0 --port 8000

See backend/README.md for the full WebSocket message protocol.
"""

import asyncio
import contextlib
import json
import logging
from typing import List

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from . import anthropic_usage, claude_session_usage, config, daily_reset, discovery, telegram_bot
from .state import StateStore
from .ws_manager import ConnectionManager

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
# httpx logs the full request URL at INFO, and TELEGRAM_API embeds the bot
# token in the URL path (that's how Telegram's API works) -- left at the
# default level, every poll would write the live token to this log file in
# plaintext. WARNING still surfaces real HTTP failures, just not routine
# request URLs.
logging.getLogger("httpx").setLevel(logging.WARNING)
logger = logging.getLogger("kindle_dashboard.main")

# ---- Shared singletons ----
state = StateStore(config.STATE_FILE)
manager = ConnectionManager()
state.set_broadcast_callback(manager.broadcast)

_background_tasks: List[asyncio.Task] = []


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Starting Kindle Dashboard backend...")
    logger.info("Telegram bot: %s", "ENABLED" if config.HAS_TELEGRAM else "DISABLED (no token configured)")
    logger.info(
        "Anthropic usage tracking: %s",
        "ENABLED" if config.HAS_ANTHROPIC_KEY else "DISABLED (no admin key set)",
    )
    logger.info(
        "Claude session usage tracking: %s",
        "ENABLED" if config.HAS_CLAUDE_SESSION else "DISABLED (no session key/org id set)",
    )

    logger.info(
        "Discovery beacon: %s",
        "ENABLED" if config.DISCOVERY_ENABLED else "DISABLED (DISCOVERY_ENABLED=0)",
    )
    logger.info(
        "Daily habits -> Google Sheets sync: %s",
        "ENABLED" if config.HAS_GOOGLE_SHEETS else "DISABLED (no spreadsheet configured -- "
        "the Daily tab still works fully locally, see docs/GOOGLE_SHEETS_SETUP.md)",
    )

    _background_tasks.append(asyncio.create_task(discovery.beacon_loop(), name="discovery-beacon"))
    _background_tasks.append(asyncio.create_task(telegram_bot.poll_loop(state, manager), name="telegram-poll"))
    _background_tasks.append(asyncio.create_task(anthropic_usage.poll_loop(state), name="anthropic-poll"))
    _background_tasks.append(asyncio.create_task(claude_session_usage.poll_loop(state), name="claude-session-poll"))
    _background_tasks.append(asyncio.create_task(daily_reset.poll_loop(state), name="daily-reset"))

    try:
        yield
    finally:
        logger.info("Shutting down background tasks...")
        for task in _background_tasks:
            task.cancel()
        for task in _background_tasks:
            with contextlib.suppress(asyncio.CancelledError):
                await task
        logger.info("Shutdown complete.")


app = FastAPI(title="Kindle Dashboard Backend", lifespan=lifespan)


@app.get("/health")
async def health():
    """Basic liveness check."""
    return {"status": "ok"}


@app.get("/state")
async def get_state():
    """Read-only REST snapshot of current state (tasks + claude_usage).
    Mainly useful for debugging without opening a WebSocket connection."""
    return state.snapshot()


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        # Push full current state immediately on connect.
        await websocket.send_text(json.dumps(state.snapshot()))

        while True:
            raw = await websocket.receive_text()
            await _handle_client_message(websocket, raw)

    except WebSocketDisconnect:
        pass
    except Exception as e:
        logger.error("WebSocket error: %s", e)
    finally:
        await manager.disconnect(websocket)


async def _safe_send(websocket: WebSocket, payload: dict) -> None:
    try:
        await websocket.send_text(json.dumps(payload))
    except Exception:
        pass  # client is likely already gone; disconnect will clean it up


async def _handle_client_message(websocket: WebSocket, raw: str) -> None:
    """Dispatches an incoming Kindle -> backend action message. See
    backend/README.md for the full protocol. Any malformed message or
    per-action error is reported back to the sender as
    {"error": "<code>", "detail": "..."} rather than closing the
    connection or crashing the server."""
    try:
        msg = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        await _safe_send(websocket, {"error": "invalid_json", "detail": "Message was not valid JSON"})
        return

    if not isinstance(msg, dict):
        await _safe_send(websocket, {"error": "invalid_message", "detail": "Message must be a JSON object"})
        return

    action = msg.get("action")

    try:
        if action == "add_task":
            raw_text = msg.get("text", "")
            if not isinstance(raw_text, str):
                await _safe_send(websocket, {"error": "bad_request", "detail": "add_task requires a string 'text'"})
                return
            text = raw_text.strip()  # length capped centrally in StateStore.add_task
            if not text:
                await _safe_send(websocket, {"error": "bad_request", "detail": "add_task requires non-empty 'text'"})
                return
            await state.add_task(text)

        elif action == "toggle_task":
            task_id = msg.get("id")
            # bool is a subclass of int in Python, so isinstance(True, int)
            # is True -- explicitly excluded so {"id": true} can't resolve
            # to task id 1.
            if not isinstance(task_id, int) or isinstance(task_id, bool):
                await _safe_send(websocket, {"error": "bad_request", "detail": "toggle_task requires integer 'id'"})
                return
            new_state = await state.toggle_task(task_id)
            if new_state is None:
                await _safe_send(websocket, {"error": "not_found", "detail": f"No task #{task_id}"})

        elif action == "delete_task":
            task_id = msg.get("id")
            if not isinstance(task_id, int) or isinstance(task_id, bool):
                await _safe_send(websocket, {"error": "bad_request", "detail": "delete_task requires integer 'id'"})
                return
            found = await state.delete_task(task_id)
            if not found:
                await _safe_send(websocket, {"error": "not_found", "detail": f"No task #{task_id}"})

        elif action == "toggle_daily":
            # Mirrors toggle_task exactly -- see backend/README.md for why
            # dailies allow toggle/delete from the Kindle but not add
            # (adding needs a time, which is a number the on-screen
            # keyboard can't type).
            daily_id = msg.get("id")
            if not isinstance(daily_id, int) or isinstance(daily_id, bool):
                await _safe_send(websocket, {"error": "bad_request", "detail": "toggle_daily requires integer 'id'"})
                return
            new_state = await state.toggle_daily(daily_id)
            if new_state is None:
                await _safe_send(websocket, {"error": "not_found", "detail": f"No daily habit D{daily_id}"})

        elif action == "delete_daily":
            daily_id = msg.get("id")
            if not isinstance(daily_id, int) or isinstance(daily_id, bool):
                await _safe_send(websocket, {"error": "bad_request", "detail": "delete_daily requires integer 'id'"})
                return
            found = await state.delete_daily(daily_id)
            if not found:
                await _safe_send(websocket, {"error": "not_found", "detail": f"No daily habit D{daily_id}"})

        elif action == "refresh_usage":
            # On success this doesn't need to reply directly -- set_session_usage()
            # already broadcasts the fresh state to every connected client
            # (including this one), same as every other mutation.
            ok, message = await claude_session_usage.refresh_now(state)
            if not ok:
                await _safe_send(websocket, {"error": "refresh_failed", "detail": message})

        else:
            await _safe_send(websocket, {"error": "unknown_action", "detail": f"Unrecognized action: {action!r}"})

    except Exception as e:
        logger.error("Error handling client message %r: %s", msg, e)
        # Log the real exception server-side but never echo internal
        # exception text back over the wire -- generic message only.
        await _safe_send(websocket, {"error": "internal_error", "detail": "Something went wrong handling that action"})
