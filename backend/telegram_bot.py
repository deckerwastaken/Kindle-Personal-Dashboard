"""
Telegram bot: polls getUpdates for commands from the single authorized
CHAT_ID and mutates the shared StateStore. Runs as an asyncio background
task inside the FastAPI app (see main.py) instead of a separate blocking
process, using httpx's async client instead of `requests`.

Commands:
    Tasks
      /add <task>            - add a new task
      /done <#>              - mark a task done
      /delete <#>            - delete a task
    Learning
      /course <name>         - add a course (you set the % by hand)
      /book <name> <pages>   - add a book (% derived from pages read)
      /percent <id> <0-100>  - set a course's progress
      /page <id> <page>      - set what page you're on in a book
      /total <id> <pages>    - correct a book's total page count
      /done, /delete         - also accept a learning id (L3)
    Lock
      /setpin <4 digits>      - set (or change) the screen-lock PIN
      /setpin off             - remove the PIN
      /lock                   - lock the Kindle's screen right now
    Both
      /list                  - show tasks and learning
      /help, /start          - show help text

WHY TELEGRAM CARRIES THE WHOLE LEARNING FEATURE
-----------------------------------------------
Every learning mutation needs a NUMBER (a percentage, a page). The
Kindle's on-screen keyboard (see kindle-daemon/src/ui.lua) is
lowercase-letters-plus-space only -- it has no digits at all. So the
device is deliberately read-only for learnings: it displays them, and
this bot is the only way to change them.

The lock-screen PIN (/setpin) is set here for the identical reason -- it
is a 4-digit number and the on-screen keyboard has no digits. UNLIKE
learnings, though, the PIN also needs to be *entered* on the device (to
unlock it), so kindle-daemon/src/ui.lua adds one small purpose-built
numeric keypad just for that -- see M.draw_pin_entry there. That keypad
is not a general-purpose input method; it exists solely because a task
name or a page count can wait for Telegram, but "unlock the screen you
are physically holding" cannot depend on your phone being nearby.

PARSING CONVENTIONS
-------------------
Two decisions worth stating once, since they shape every handler below:

1. "Trailing number wins" for commands that take a name AND a number
   (/book). The alternatives were a pipe separator ("/book Dune | 412")
   and a two-step conversational flow ("how many pages?"). The pipe
   costs three keyboard-layer switches on a phone to type a character
   nobody uses; the conversational flow would force a pending-question
   state machine into what is currently a stateless prefix matcher, and
   can be abandoned halfway. Splitting on the last whitespace reads like
   speech ("book, Atomic Habits, 320 pages"), needs no new syntax, and
   matches the shape of /percent and /page so all three feel like one
   rule.

   Its known failure is a title ENDING in a number: "/book Fahrenheit
   451" parses as the book "Fahrenheit" with 451 pages. Two mitigations,
   both deliberate: every success reply echoes the parsed split straight
   back, so the mistake is visible in the same second, and /total repairs
   it in one command. That is the entire reason /total is in v1.

2. Learning ids are shown as "L3", tasks as "#3". They are separate
   sequences, so a bare "/done 3" is genuinely ambiguous -- it resolves
   against TASKS first (the older, higher-frequency surface), then
   learnings. Writing "/done L3" is unambiguous and always means the
   learning. Every reply restates the full prefixed id, which teaches the
   namespace without anyone reading documentation.
"""

import asyncio
import logging

import httpx

from . import config
from .state import MAX_BOOK_PAGES, StateStore
from .ws_manager import ConnectionManager

logger = logging.getLogger("kindle_dashboard.telegram")

HELP_TEXT = (
    "Kindle Dashboard\n"
    "\n"
    "TASKS\n"
    "/add <task> - add a task\n"
    "/done <#> - mark it done\n"
    "/delete <#> - delete it\n"
    "\n"
    "LEARNING\n"
    "/course <name> - add a course\n"
    "   e.g. /course Spanish\n"
    "/book <name> <pages> - add a book\n"
    "   e.g. /book Atomic Habits 320\n"
    "/percent <id> <0-100> - course progress\n"
    "   e.g. /percent L2 40\n"
    "/page <id> <page> - book progress\n"
    "   e.g. /page L1 120\n"
    "/total <id> <pages> - fix a page count\n"
    "   e.g. /total L1 300\n"
    "\n"
    "LOCK\n"
    "/setpin <4 digits> - set/change the lock PIN\n"
    "   e.g. /setpin 1234\n"
    "/setpin off - remove the PIN\n"
    "/lock - lock the Kindle's screen now\n"
    "\n"
    "BOTH\n"
    "/list - show everything\n"
    "/help - this message\n"
    "\n"
    "Tasks are #1 #2. Learning is L1 L2.\n"
    "/done and /delete take either one.\n"
    "Books finish themselves at the last page."
)

# Registered with Telegram at startup so the app shows a tap-to-fill menu
# when the user types "/". This is the highest-usability-per-line change
# in the whole command surface: it means nobody has to remember any of
# these names or their argument order, which matters much more than
# keeping the commands short. (It's also why the names are the obvious
# full words -- /percent, not /pct.)
BOT_COMMANDS = [
    {"command": "add", "description": "Add a task"},
    {"command": "list", "description": "Show tasks and learning"},
    {"command": "done", "description": "Mark a task or learning finished"},
    {"command": "delete", "description": "Delete a task or learning"},
    {"command": "course", "description": "Add a course to track"},
    {"command": "book", "description": "Add a book: /book <name> <total pages>"},
    {"command": "percent", "description": "Set course progress: /percent L1 40"},
    {"command": "page", "description": "Set book page: /page L1 120"},
    {"command": "total", "description": "Fix a book's page count"},
    {"command": "setpin", "description": "Set/remove the screen-lock PIN: /setpin 1234"},
    {"command": "lock", "description": "Lock the Kindle's screen now"},
    {"command": "help", "description": "Show all commands"},
]


async def send_message(client: httpx.AsyncClient, text: str) -> None:
    try:
        await client.post(
            f"{config.TELEGRAM_API}/sendMessage",
            data={"chat_id": config.CHAT_ID, "text": text},
            timeout=10,
        )
    except Exception as e:
        logger.error("Error sending Telegram message: %s", e)


async def register_commands(client: httpx.AsyncClient) -> None:
    """Publish the command list to Telegram so the client shows a menu.
    Best-effort: a failure here costs autocomplete, not functionality, so
    it's logged and ignored rather than retried or raised."""
    try:
        import json as _json

        r = await client.post(
            f"{config.TELEGRAM_API}/setMyCommands",
            data={"commands": _json.dumps(BOT_COMMANDS)},
            timeout=10,
        )
        if r.json().get("ok"):
            logger.info("Registered %d bot commands with Telegram.", len(BOT_COMMANDS))
        else:
            logger.warning("setMyCommands was rejected: %s", r.text)
    except Exception as e:
        logger.error("Could not register bot commands (autocomplete only): %s", e)


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


# ---------- parsing helpers ----------


def _split_command(text: str) -> tuple:
    """('/page L1 120') -> ('/page', 'L1 120'). Returns ('', '') for
    anything that isn't a command.

    Splitting on the command TOKEN rather than matching a prefix with a
    trailing space (the original '/add ' style) is what lets a bare
    '/page' reach its own handler and reply with usage. Under prefix
    matching, '/page' with no argument matched nothing and fell through
    to the silent-ignore branch -- the user got no response at all and
    would reasonably conclude the bot was broken. Silence is the worst
    available answer to someone still learning the commands.
    """
    if not text.startswith("/"):
        return "", ""
    parts = text.split(maxsplit=1)
    cmd = parts[0].lower()
    # Telegram appends @botname when commands are used in groups.
    if "@" in cmd:
        cmd = cmd.split("@", 1)[0]
    return cmd, (parts[1].strip() if len(parts) > 1 else "")


def _parse_id(token: str) -> tuple:
    """Parses an id and how explicitly the user named which list it's in.

    Returns (id, kind) where kind is "learning", "task", or None:

        "L3" / "l3"  -> (3, "learning")
        "#3"         -> (3, "task")
        "3"          -> (3, None)      -- ambiguous, resolve tasks-first
        "x" / ""     -> (None, ...)

    Both prefixes are equally explicit, and treating them that way
    matters for /done and /delete, which span both lists. /list prints
    task ids as "#1", so "#3" is the format the user is being SHOWN --
    if it were treated as ambiguous, then "/delete #3" at a moment when
    task 3 no longer exists (already deleted, or done and cleared) would
    fall through and permanently delete learning L3 instead. An explicit
    prefix means "only look in this list", in both directions.
    """
    token = token.strip()
    kind = None
    if token[:1] in ("L", "l"):
        kind = "learning"
        token = token[1:]
    elif token[:1] == "#":
        kind = "task"
        token = token[1:]
    try:
        return int(token), kind
    except ValueError:
        return None, kind


def _parse_percent(token: str) -> "int | None":
    """Accepts '40', '40%', '%40', '40.0'. Returns None if unparseable.

    Deliberately permissive about the decoration and strict about the
    VALUE (range-checked by the caller): a stray '%' is a typing artifact
    with one obvious meaning, whereas '150' is a genuine mistake worth
    reporting.
    """
    token = token.strip().strip("%").strip()
    if "." in token:
        token = token.split(".", 1)[0]  # '40.0' -> '40'
    try:
        return int(token)
    except ValueError:
        return None


def _split_trailing_number(rest: str) -> tuple:
    """('Atomic Habits 320') -> ('Atomic Habits', 320).
    Returns (rest, None) when the last token isn't an integer."""
    parts = rest.rsplit(maxsplit=1)
    if len(parts) < 2:
        return rest, None
    try:
        return parts[0].strip(), int(parts[1])
    except ValueError:
        return rest, None


def _fmt_learning(item: dict) -> str:
    """'L1 Atomic Habits: page 120/320 (37%)' -- the standard echo used
    in every success reply, so the user constantly re-reads the id, the
    name as stored, and the resulting percentage together."""
    label = f"L{item['id']} {item['name']}"
    if item["kind"] == "book":
        return f"{label}: page {item['pages_read']}/{item['total_pages']} ({item['percent']}%)"
    return f"{label}: {item['percent']}%"


def _finished_suffix(item: dict) -> str:
    """Appended when an item lands on 100%. This is the only moment the
    user is told deletion exists -- delivered exactly when it's relevant,
    rather than as another line in /help nobody reads."""
    if item.get("done"):
        return f" - finished! /delete L{item['id']} to remove it."
    return ""


def _vanished(learning_id: int) -> str:
    """Reply for the narrow case where a learning existed when we looked
    it up but not by the time we wrote to it.

    Each of the three setter commands below reads the item (to check its
    kind and phrase a good error) and then writes it, with an await
    boundary in between. If the item is deleted in that window the write
    returns None, and formatting that None would raise -- which poll_loop
    catches and logs, leaving the user with COMPLETE SILENCE and no idea
    whether their command landed. Silence is the worst possible answer,
    so this says plainly what happened instead.
    """
    return f"L{learning_id} disappeared before I could update it - was it just deleted?"


# ---------- command handlers ----------


async def _cmd_course(state: StateStore, client: httpx.AsyncClient, rest: str) -> None:
    if not rest:
        await send_message(client, "Usage: /course <name>\ne.g. /course Spanish")
        return
    item = await state.add_course(rest)
    await send_message(client, f"Added course L{item['id']}: {item['name']} (0%)")


async def _cmd_book(state: StateStore, client: httpx.AsyncClient, rest: str) -> None:
    if not rest:
        await send_message(
            client, "Usage: /book <name> <total pages>\ne.g. /book Atomic Habits 320"
        )
        return
    name, total = _split_trailing_number(rest)
    if total is None:
        await send_message(client, f"I need the page count too. e.g. /book {rest} 320")
        return
    if total < 1:
        await send_message(client, "A book needs at least 1 page.")
        return
    if total > MAX_BOOK_PAGES:
        await send_message(client, f"That page count looks wrong ({MAX_BOOK_PAGES} max).")
        return
    if not name:
        await send_message(
            client, "Usage: /book <name> <total pages>\ne.g. /book Atomic Habits 320"
        )
        return
    item = await state.add_book(name, total)
    # The echo is the safety net for the trailing-number split: if this
    # was "/book Fahrenheit 451", the user reads "Fahrenheit - 451 pages"
    # right now and fixes it with /total, instead of discovering it weeks
    # later on the Kindle.
    await send_message(
        client, f"Added book L{item['id']}: {item['name']} - {item['total_pages']} pages (0%)"
    )


async def _cmd_percent(state: StateStore, client: httpx.AsyncClient, rest: str) -> None:
    parts = rest.split()
    if len(parts) < 2:
        await send_message(client, "Usage: /percent <id> <0-100>\ne.g. /percent L2 40")
        return
    learning_id, _ = _parse_id(parts[0])
    value = _parse_percent(parts[1])
    if learning_id is None or value is None:
        await send_message(client, "Usage: /percent <id> <0-100>\ne.g. /percent L2 40")
        return

    item = await state.get_learning(learning_id)
    if item is None:
        await send_message(client, f"No learning L{learning_id} found. Use /list to see them.")
        return
    if item["kind"] == "book":
        await send_message(
            client,
            f"L{learning_id} {item['name']} is a book - "
            f"use /page L{learning_id} 120 instead.",
        )
        return
    # Rejected, not clamped. A percentage has a universally known range,
    # so an out-of-range value is always a typo ("500" for "50"), never
    # an intent -- and silently clamping 500 to 100 would mark a course
    # finished that the user is half way through, a wrong write that
    # looks like a success. Note this is deliberately different from the
    # pages-past-the-end rule below, where the overflow expresses
    # something real (a wrong total) and so gets clamped with a warning.
    if value < 0 or value > 100:
        await send_message(client, f"Percent must be 0-100. You sent {value}.")
        return

    updated = await state.set_learning_percent(learning_id, value)
    if updated is None:
        await send_message(client, _vanished(learning_id))
        return
    await send_message(client, _fmt_learning(updated) + _finished_suffix(updated))


async def _cmd_page(state: StateStore, client: httpx.AsyncClient, rest: str) -> None:
    parts = rest.split()
    if len(parts) < 2:
        await send_message(client, "Usage: /page <id> <page you're on>\ne.g. /page L1 120")
        return
    learning_id, _ = _parse_id(parts[0])
    try:
        page = int(parts[1])
    except ValueError:
        page = None
    if learning_id is None or page is None:
        await send_message(client, "Usage: /page <id> <page you're on>\ne.g. /page L1 120")
        return

    item = await state.get_learning(learning_id)
    if item is None:
        await send_message(client, f"No learning L{learning_id} found. Use /list to see them.")
        return
    if item["kind"] != "book":
        await send_message(
            client,
            f"L{learning_id} {item['name']} is a course - "
            f"use /percent L{learning_id} 40 instead.",
        )
        return
    if page < 0:
        await send_message(client, "Page must be 0 or more.")
        return

    overshot = page > item["total_pages"]
    updated = await state.set_learning_pages(learning_id, page)
    if updated is None:
        await send_message(client, _vanished(learning_id))
        return
    msg = _fmt_learning(updated)
    if overshot:
        # Accepted and clamped rather than rejected: a page past the end
        # usually means the TOTAL is wrong (wrong edition, appendices, a
        # guessed page count), not that the user mistyped the page. So
        # take the progress at face value, say plainly what was stored,
        # and point at the command that fixes the real problem.
        msg += (
            f" - that's past your total of {updated['total_pages']}, "
            f"treating it as finished. /total L{learning_id} <pages> to fix the total."
        )
    else:
        msg += _finished_suffix(updated)
    await send_message(client, msg)


async def _cmd_total(state: StateStore, client: httpx.AsyncClient, rest: str) -> None:
    parts = rest.split()
    if len(parts) < 2:
        await send_message(client, "Usage: /total <id> <pages>\ne.g. /total L1 300")
        return
    learning_id, _ = _parse_id(parts[0])
    try:
        total = int(parts[1])
    except ValueError:
        total = None
    if learning_id is None or total is None:
        await send_message(client, "Usage: /total <id> <pages>\ne.g. /total L1 300")
        return

    item = await state.get_learning(learning_id)
    if item is None:
        await send_message(client, f"No learning L{learning_id} found. Use /list to see them.")
        return
    if item["kind"] != "book":
        await send_message(
            client, f"L{learning_id} {item['name']} is a course - it has no page count."
        )
        return
    if total < 1:
        await send_message(client, "A book needs at least 1 page.")
        return
    if total > MAX_BOOK_PAGES:
        await send_message(client, f"That page count looks wrong ({MAX_BOOK_PAGES} max).")
        return

    was_past = item["pages_read"] > total
    updated = await state.set_learning_total_pages(learning_id, total)
    if updated is None:
        await send_message(client, _vanished(learning_id))
        return
    if was_past:
        await send_message(
            client,
            f"L{learning_id} {updated['name']}: total now {total} pages - you were "
            f"past that, so you're at {updated['pages_read']}/{total} "
            f"({updated['percent']}%).",
        )
    else:
        await send_message(
            client,
            f"L{learning_id} {updated['name']}: total now {total} pages "
            f"({updated['percent']}%).",
        )


async def _cmd_done(state: StateStore, client: httpx.AsyncClient, rest: str) -> None:
    if not rest:
        await send_message(client, "Usage: /done <#>\ne.g. /done 3, or /done L1 for learning")
        return
    item_id, kind = _parse_id(rest.split()[0])
    if item_id is None:
        await send_message(client, "Usage: /done <#>\ne.g. /done 3, or /done L1 for learning")
        return

    # A bare number resolves against tasks first: that's the surface the
    # user has been typing "/done 3" at for months, so it should keep
    # meaning what it always meant. An explicit prefix ("L3" or "#3")
    # confines the lookup to that one list -- so a mistyped or
    # already-gone id reports "not found" instead of quietly acting on
    # the same number in the OTHER list.
    if kind != "learning":
        if await state.mark_done(item_id):
            await send_message(client, f"Marked #{item_id} done.")
            return
    if kind == "task":
        await send_message(client, f"No task #{item_id} found.")
        return

    updated = await state.mark_learning_done(item_id)
    if updated is None:
        if kind == "learning":
            await send_message(client, f"No learning L{item_id} found.")
        else:
            await send_message(client, f"No task #{item_id} or learning L{item_id} found.")
        return
    await send_message(client, f"Finished {_fmt_learning(updated)}. /delete L{item_id} to remove it.")


async def _cmd_delete(state: StateStore, client: httpx.AsyncClient, rest: str) -> None:
    if not rest:
        await send_message(client, "Usage: /delete <#>\ne.g. /delete 3, or /delete L1")
        return
    item_id, kind = _parse_id(rest.split()[0])
    if item_id is None:
        await send_message(client, "Usage: /delete <#>\ne.g. /delete 3, or /delete L1")
        return

    # Same explicit-prefix rule as /done above, and it matters most here:
    # deletion is the one irreversible action in this bot, so "#3" must
    # never be able to reach a learning.
    if kind != "learning":
        if await state.delete_task(item_id):
            await send_message(client, f"Deleted #{item_id}.")
            return
    if kind == "task":
        await send_message(client, f"No task #{item_id} found.")
        return

    if await state.delete_learning(item_id):
        await send_message(client, f"Deleted L{item_id}.")
        return

    if kind == "learning":
        await send_message(client, f"No learning L{item_id} found.")
    else:
        await send_message(client, f"No task #{item_id} or learning L{item_id} found.")


async def _cmd_setpin(state: StateStore, client: httpx.AsyncClient, rest: str) -> None:
    pin = rest.strip()
    if pin.lower() in ("off", "none", "clear", "remove"):
        await state.set_lock_pin("")
        await send_message(client, "PIN removed -- the power button unlocks instantly again.")
        return
    if not (len(pin) == 4 and pin.isdigit()):
        await send_message(
            client,
            "Usage: /setpin <4 digits>\ne.g. /setpin 1234\nOr /setpin off to remove it.",
        )
        return
    await state.set_lock_pin(pin)
    await send_message(
        client, "PIN set. The Kindle will ask for it after the screen locks."
    )


async def _cmd_lock(client: httpx.AsyncClient, manager: ConnectionManager) -> None:
    # Fire-and-forget over the WebSocket -- there is no queue, so this only
    # does anything if the Kindle is connected RIGHT NOW. Checking the count
    # first means the reply is honest about whether anything actually
    # happened, rather than always claiming success like a normal state
    # mutation would (a state broadcast is safe to claim -- the next
    # reconnect delivers it anyway; a lock command sent to nobody is simply
    # lost).
    if manager.connection_count() == 0:
        await send_message(client, "No Kindle is currently connected -- nothing to lock.")
        return
    await manager.broadcast({"type": "command", "command": "lock"})
    await send_message(client, "Locked the dashboard.")


async def _cmd_list(state: StateStore, client: httpx.AsyncClient) -> None:
    """Shows BOTH lists. /list means 'show me my stuff', not 'show me the
    tasks collection' -- and a separate /learnlist would be one more name
    to remember for no extra information. Empty sections print a hint
    rather than disappearing: hiding a section hides the feature."""
    tasks = await state.list_tasks()
    learnings = await state.list_learnings()

    lines = ["TASKS"]
    if not tasks:
        lines.append("(nothing yet - /add <task> to start)")
    else:
        for t in tasks:
            mark = "DONE" if t["done"] else "TODO"
            lines.append(f"[{mark}] #{t['id']}: {t['text']}")

    lines.append("")
    lines.append("LEARNING")
    if not learnings:
        lines.append("(nothing yet - /course or /book to start)")
    else:
        # Finished items sink to the bottom, same convention the Kindle
        # task list already uses for done tasks.
        ordered = [x for x in learnings if not x["done"]] + [x for x in learnings if x["done"]]
        for item in ordered:
            mark = "DONE" if item["done"] else f"{item['percent']:3d}%"
            suffix = f" ({item['detail']})" if item["detail"] else ""
            lines.append(f"[{mark}] L{item['id']}: {item['name']}{suffix}")

    await send_message(client, "\n".join(lines))


async def process_command(
    state: StateStore, client: httpx.AsyncClient, text: str, manager: ConnectionManager
) -> None:
    cmd, rest = _split_command(text.strip())

    if cmd == "/add":
        if not rest:
            await send_message(client, "Usage: /add <task text>\ne.g. /add call the dentist")
            return
        task = await state.add_task(rest)
        await send_message(client, f"Added task #{task['id']}: {task['text']}")

    elif cmd == "/list":
        await _cmd_list(state, client)

    elif cmd == "/done":
        await _cmd_done(state, client, rest)

    elif cmd == "/delete":
        await _cmd_delete(state, client, rest)

    elif cmd == "/course":
        await _cmd_course(state, client, rest)

    elif cmd == "/book":
        await _cmd_book(state, client, rest)

    elif cmd == "/percent":
        await _cmd_percent(state, client, rest)

    elif cmd == "/page":
        await _cmd_page(state, client, rest)

    elif cmd == "/total":
        await _cmd_total(state, client, rest)

    elif cmd == "/setpin":
        await _cmd_setpin(state, client, rest)

    elif cmd == "/lock":
        await _cmd_lock(client, manager)

    elif cmd in ("/help", "/start"):
        await send_message(client, HELP_TEXT)

    # Unknown commands stay silently ignored, same as the v1 prototype --
    # that branch exists so ordinary chat text never produces noise. Note
    # this is NOT the same as the bare-known-command case, which now
    # always answers with usage; see _split_command's comment.


async def poll_loop(state: StateStore, manager: ConnectionManager) -> None:
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
        await register_commands(client)
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
                        await process_command(state, client, text, manager)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.error("Unexpected error in Telegram poll loop: %s", e)

            await asyncio.sleep(config.TELEGRAM_POLL_INTERVAL_SECONDS)
