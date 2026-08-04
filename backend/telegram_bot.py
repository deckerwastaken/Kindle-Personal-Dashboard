"""
Telegram bot: polls getUpdates for commands from the single authorized
CHAT_ID and mutates the shared StateStore. Runs as an asyncio background
task inside the FastAPI app (see main.py) instead of a separate blocking
process, using httpx's async client instead of `requests`.

Commands (unchanged from the v1 prototype):
    /add <task>   - add a new task
    /list         - show all tasks
    /done <#>     - mark a task done
    /delete <#>   - delete a task
    /help, /start - show help text
"""

import asyncio
import logging

import httpx

from . import config
from .state import StateStore

logger = logging.getLogger("kindle_dashboard.telegram")

HELP_TEXT = (
    "Kindle Dashboard commands:\n"
    "/add <task> - add a new task\n"
    "/list - show all tasks\n"
    "/done <#> - mark a task done\n"
    "/delete <#> - delete a task"
)


async def send_message(client: httpx.AsyncClient, text: str) -> None:
    try:
        await client.post(
            f"{config.TELEGRAM_API}/sendMessage",
            data={"chat_id": config.CHAT_ID, "text": text},
            timeout=10,
        )
    except Exception as e:
        logger.error("Error sending Telegram message: %s", e)


async def get_updates(client: httpx.AsyncClient, offset: int) -> list:
    try:
        r = await client.get(
            f"{config.TELEGRAM_API}/getUpdates",
            params={"offset": offset, "timeout": config.TELEGRAM_LONG_POLL_TIMEOUT},
            timeout=config.TELEGRAM_LONG_POLL_TIMEOUT + 10,
        )
        result = r.json()
        if not result.get("ok"):
            logger.warning("Telegram API error response: %s", result)
            return []
        return result.get("result", [])
    except Exception as e:
        logger.error("Error fetching Telegram updates: %s", e)
        return []


async def process_command(state: StateStore, client: httpx.AsyncClient, text: str) -> None:
    text = text.strip()

    if text.startswith("/add "):
        task_text = text[len("/add "):].strip()
        if not task_text:
            await send_message(client, "Usage: /add <task text>")
            return
        task = await state.add_task(task_text)
        await send_message(client, f"Added task #{task['id']}: {task['text']}")

    elif text == "/list":
        tasks = await state.list_tasks()
        if not tasks:
            await send_message(client, "No tasks yet. Use /add <task> to create one.")
        else:
            lines = []
            for t in tasks:
                mark = "DONE" if t["done"] else "TODO"
                lines.append(f"[{mark}] #{t['id']}: {t['text']}")
            await send_message(client, "\n".join(lines))

    elif text.startswith("/done "):
        try:
            task_id = int(text[len("/done "):].strip())
        except ValueError:
            await send_message(client, "Usage: /done <task number>")
            return
        found = await state.mark_done(task_id)
        await send_message(client, f"Marked #{task_id} done." if found else f"No task #{task_id} found.")

    elif text.startswith("/delete "):
        try:
            task_id = int(text[len("/delete "):].strip())
        except ValueError:
            await send_message(client, "Usage: /delete <task number>")
            return
        found = await state.delete_task(task_id)
        await send_message(client, f"Deleted #{task_id}." if found else f"No task #{task_id} found.")

    elif text in ("/help", "/start"):
        await send_message(client, HELP_TEXT)

    # Unknown commands are silently ignored, same as the v1 prototype.


async def poll_loop(state: StateStore) -> None:
    """Long-running background task. Never raises -- any error during a
    single iteration is logged and the loop continues, so a bad/missing
    token just means every poll fails and gets logged, rather than
    crashing the whole app."""
    if not config.HAS_TELEGRAM:
        logger.warning(
            "Telegram bot DISABLED: TELEGRAM_TOKEN not configured in backend/.env. "
            "Skipping poll loop."
        )
        return

    if not config.CHAT_ID:
        logger.warning(
            "TELEGRAM_TOKEN is configured but CHAT_ID is blank in backend/.env -- "
            "every message will be silently ignored (no chat_id will ever match an "
            "empty string). Set CHAT_ID to your numeric Telegram chat ID."
        )

    logger.info("Starting Telegram poll loop (authorized chat_id=%s)", config.CHAT_ID)
    offset = 0
    async with httpx.AsyncClient() as client:
        while True:
            try:
                updates = await get_updates(client, offset)
                for update in updates:
                    offset = update["update_id"] + 1
                    message = update.get("message", {})
                    if str(message.get("chat", {}).get("id")) != str(config.CHAT_ID):
                        continue  # ignore anyone who isn't the authorized chat
                    text = message.get("text", "")
                    if text:
                        await process_command(state, client, text)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.error("Unexpected error in Telegram poll loop: %s", e)

            await asyncio.sleep(config.TELEGRAM_POLL_INTERVAL_SECONDS)
