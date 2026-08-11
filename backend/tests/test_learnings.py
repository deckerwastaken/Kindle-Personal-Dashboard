"""
Tests for the Learning tracker: the StateStore derivation rules and the
Telegram command parsing/replies.

Run from the repo root:

    python backend/tests/test_learnings.py

Plain asserts and a tiny runner rather than pytest, to keep this
runnable with nothing installed beyond what the backend already needs
(see backend/requirements.txt).

WHAT'S WORTH TESTING HERE, AND WHY
----------------------------------
Almost all of the learning feature's risk is in two places, and neither
is visible by looking at the Kindle:

  1. The derived fields (percent / detail / done). They're computed at
     WRITE time and stored, precisely so the on-device renderer never has
     to divide or branch -- which means a bug here writes a wrong number
     into state.json permanently, rather than showing a wrong number once.

  2. Argument parsing. "/book Atomic Habits 320" has to split a
     free-text name from a trailing integer, ids may or may not carry an
     "L" prefix, and several commands must REFUSE rather than guess. Each
     of those is a small string rule with an obvious failure mode that no
     type checker catches.

The Telegram tests capture the reply text and assert on it, because for
this feature the reply IS the user interface -- it's how the user
discovers a mis-parsed book title in time to fix it.
"""

import asyncio
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from backend import telegram_bot  # noqa: E402
from backend.state import StateStore  # noqa: E402

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


async def say(state, text):
    """Run one command and return the reply it produced."""
    _replies.clear()
    await telegram_bot.process_command(state, None, text)
    return _replies[-1] if _replies else ""


# ------------------------------------------------------------------ tests


async def test_course_basics():
    print("\n=== courses ===")
    s = new_store()
    item = await s.add_course("Spanish")
    check("new course starts at 0%", item["percent"], 0)
    check("new course is not done", item["done"], False)
    check("course has no detail caption", item["detail"], "")
    check("course ids start at 1", item["id"], 1)

    await s.set_learning_percent(1, 40)
    got = await s.get_learning(1)
    check("percent is stored", got["percent"], 40)
    check("40% is not done", got["done"], False)

    got = await s.set_learning_percent(1, 100)
    check("100% flips done to True", got["done"], True)
    got = await s.set_learning_percent(1, 60)
    check("dropping back below 100 clears done", got["done"], False)

    check("unknown id returns None", await s.set_learning_percent(99, 50), None)


async def test_book_derivation():
    print("\n=== books: derived percent / detail / done ===")
    s = new_store()
    await s.add_book("Atomic Habits", 320)
    got = await s.get_learning(1)
    check("new book starts at 0%", got["percent"], 0)
    check("detail caption is precomputed", got["detail"], "0/320 pages")

    got = await s.set_learning_pages(1, 120)
    check("120/320 floors to 37%", got["percent"], 37)
    check("detail updates with the page", got["detail"], "120/320 pages")

    # Floor, not round: this is the whole reason `done` can be defined as
    # `percent == 100` for both kinds with no special case.
    got = await s.set_learning_pages(1, 319)
    check("319/320 stays at 99%, not rounded to 100", got["percent"], 99)
    check("319/320 is not done", got["done"], False)

    got = await s.set_learning_pages(1, 320)
    check("320/320 is exactly 100%", got["percent"], 100)
    check("320/320 is done", got["done"], True)

    got = await s.set_learning_pages(1, 400)
    check("pages past the end clamp to the total", got["pages_read"], 320)
    check("clamped percent never exceeds 100", got["percent"], 100)

    got = await s.set_learning_pages(1, 0)
    check("page 0 is allowed (restarting)", got["percent"], 0)
    check("page 0 clears done", got["done"], False)


async def test_total_pages_correction():
    print("\n=== correcting a book's total ===")
    s = new_store()
    await s.add_book("Fahrenheit", 451)
    await s.set_learning_pages(1, 200)
    got = await s.set_learning_total_pages(1, 249)
    check("new total recomputes percent", got["percent"], 80)
    check("detail reflects the new total", got["detail"], "200/249 pages")

    got = await s.set_learning_total_pages(1, 150)
    check("a total below pages_read clamps pages down", got["pages_read"], 150)
    check("...and lands on 100%", got["percent"], 100)


async def test_mark_done_and_delete():
    print("\n=== /done and /delete semantics ===")
    s = new_store()
    await s.add_book("Deep Work", 300)
    await s.add_course("Spanish")

    got = await s.mark_learning_done(1)
    check("done on a book jumps to the last page", got["pages_read"], 300)
    check("...and reads 100%", got["percent"], 100)

    got = await s.mark_learning_done(2)
    check("done on a course sets 100%", got["percent"], 100)

    check("delete removes it", await s.delete_learning(1), True)
    check("deleting twice reports not found", await s.delete_learning(1), False)
    check("the other item survives", len(await s.list_learnings()), 1)

    # Ids come from max()+1, so deleting the highest id and adding again
    # can reuse it. Asserting the actual behavior rather than assuming
    # monotonic ids, since replies quote these back to the user.
    await s.add_course("Guitar")
    ids = sorted(i["id"] for i in await s.list_learnings())
    check("ids stay unique after a delete", len(ids), len(set(ids)))


async def test_separate_id_spaces():
    print("\n=== tasks and learnings have independent ids ===")
    s = new_store()
    t = await s.add_task("call dentist")
    lrn = await s.add_course("Spanish")
    check("first task is #1", t["id"], 1)
    check("first learning is also L1", lrn["id"], 1)

    check("bare /done 1 resolves to the TASK", await say(s, "/done 1"), "Marked #1 done.")
    check("the learning is untouched", (await s.get_learning(1))["percent"], 0)

    reply = await say(s, "/done L1")
    check_contains("explicit /done L1 hits the learning", reply, "L1 Spanish: 100%")
    check("...and it is now done", (await s.get_learning(1))["done"], True)

    # /list prints task ids as "#1", so copying that format straight back
    # is the natural thing for someone to type.
    await s.add_task("second task")
    check("/done #2 works like /done 2", await say(s, "/done #2"), "Marked #2 done.")
    await s.add_task("third task")
    check("/delete #3 works like /delete 3", await say(s, "/delete #3"), "Deleted #3.")

    # Nonsense ids must produce usage text, never a traceback.
    check_contains("non-numeric id is refused", await say(s, "/done abc"), "Usage: /done")
    check_contains("empty-ish id is refused", await say(s, "/done L"), "Usage: /done")
    check_contains("missing id is refused", await say(s, "/delete"), "Usage: /delete")


async def test_explicit_prefix_never_crosses_lists():
    """The data-loss case: an explicit '#' must never reach a learning.

    /list shows task ids as '#3', so '#3' is the format the user is being
    SHOWN. If that were treated as ambiguous, then typing '/delete #3' at
    a moment when task 3 happens to be gone -- already deleted, or done
    and cleared -- would fall through and permanently delete learning L3
    instead. For a book that also means silently discarding the page
    position, with no undo and nothing in state.json to recover from.
    """
    print("\n=== an explicit #/L prefix confines the lookup to one list ===")
    s = new_store()
    await s.add_book("Atomic Habits", 320)
    await s.set_learning_pages(1, 200)  # L1 exists, mid-book
    # No task #1 exists at all.

    reply = await say(s, "/delete #1")
    check("explicit #1 with no such task refuses", reply, "No task #1 found.")
    check("...and L1 still exists", len(await s.list_learnings()), 1)
    check("...with its page position intact", (await s.get_learning(1))["pages_read"], 200)

    reply = await say(s, "/done #1")
    check("explicit /done #1 with no such task refuses", reply, "No task #1 found.")
    check("...and did not finish the book", (await s.get_learning(1))["pages_read"], 200)

    # The mirror case: an explicit L must not reach a task.
    s2 = new_store()
    await s2.add_task("call dentist")
    reply = await say(s2, "/delete L1")
    check("explicit L1 with no such learning refuses", reply, "No learning L1 found.")
    check("...and the task survives", len(await s2.list_tasks()), 1)

    # A BARE number still resolves tasks-first, then falls through --
    # the documented, deliberate behavior, kept intact by the above.
    s3 = new_store()
    await s3.add_course("Spanish")
    reply = await say(s3, "/done 1")
    check_contains("bare id still falls through to a learning", reply, "L1 Spanish")


async def test_telegram_book_parsing():
    print("\n=== /book trailing-number parsing ===")
    s = new_store()
    reply = await say(s, "/book Atomic Habits 320")
    check("name with spaces + trailing count", reply, "Added book L1: Atomic Habits - 320 pages (0%)")

    reply = await say(s, "/book Dune")
    check_contains("missing page count names what's missing", reply, "I need the page count too")

    reply = await say(s, "/book Dune abc")
    check_contains("non-numeric count is rejected", reply, "I need the page count too")

    reply = await say(s, "/book Nothing 0")
    check("zero pages is refused", reply, "A book needs at least 1 page.")
    reply = await say(s, "/book Nothing -5")
    check("negative pages is refused", reply, "A book needs at least 1 page.")
    reply = await say(s, "/book Huge 3200000")
    check_contains("absurd page count is refused", reply, "looks wrong")

    # The known, accepted ambiguity: a title ending in a number. The
    # reply must show the split it chose, because that echo is the only
    # thing standing between this and a silently wrong book.
    reply = await say(s, "/book Fahrenheit 451")
    check("title ending in a digit splits as documented", reply,
          "Added book L2: Fahrenheit - 451 pages (0%)")
    reply = await say(s, "/total L2 249")
    check_contains("/total repairs the mis-split in one command", reply, "total now 249 pages")


async def test_telegram_percent_rules():
    print("\n=== /percent input rules ===")
    s = new_store()
    await s.add_course("Spanish")

    check("plain number", await say(s, "/percent L1 40"), "L1 Spanish: 40%")
    check("trailing percent sign", await say(s, "/percent L1 55%"), "L1 Spanish: 55%")
    check("leading percent sign", await say(s, "/percent L1 60"), "L1 Spanish: 60%")
    check("decimal truncates", await say(s, "/percent L1 42.7"), "L1 Spanish: 42%")
    check("bare id without L works", await say(s, "/percent 1 30"), "L1 Spanish: 30%")

    # Rejected, not clamped -- silently turning 500 into 100 would mark a
    # course finished that the user is half way through.
    check("over 100 is rejected", await say(s, "/percent L1 150"),
          "Percent must be 0-100. You sent 150.")
    check("negative is rejected", await say(s, "/percent L1 -5"),
          "Percent must be 0-100. You sent -5.")
    check("the value did not change", (await s.get_learning(1))["percent"], 30)

    reply = await say(s, "/percent L1 100")
    check_contains("hitting 100% offers the exit", reply, "/delete L1 to remove it.")


async def test_telegram_wrong_kind_and_errors():
    print("\n=== wrong-command-for-the-kind, and error text ===")
    s = new_store()
    await s.add_book("Atomic Habits", 320)
    await s.add_course("Spanish")

    reply = await say(s, "/percent L1 40")
    check_contains("percent on a book points at /page", reply, "use /page L1 120 instead")
    reply = await say(s, "/page L2 100")
    check_contains("page on a course points at /percent", reply, "use /percent L2 40 instead")
    reply = await say(s, "/total L2 100")
    check_contains("total on a course explains why not", reply, "it has no page count")

    check_contains("unknown id, /page", await say(s, "/page L9 10"), "No learning L9 found")
    check_contains("unknown id, /percent", await say(s, "/percent L9 10"), "No learning L9 found")

    reply = await say(s, "/page L1 400")
    check_contains("overshooting warns and points at /total", reply, "past your total of 320")
    check("...and stores the clamped page", (await s.get_learning(1))["pages_read"], 320)

    check("page must be non-negative", await say(s, "/page L1 -3"), "Page must be 0 or more.")


async def test_bare_commands_answer():
    print("\n=== a bare known command always answers ===")
    # Previously '/add' with no argument matched nothing (the parser
    # looked for '/add ' with a trailing space) and fell through to the
    # silent-ignore branch, so the user got no reply at all.
    s = new_store()
    for cmd, expect in [
        ("/add", "Usage: /add"),
        ("/done", "Usage: /done"),
        ("/delete", "Usage: /delete"),
        ("/course", "Usage: /course"),
        ("/book", "Usage: /book"),
        ("/percent", "Usage: /percent"),
        ("/page", "Usage: /page"),
        ("/total", "Usage: /total"),
    ]:
        check_contains(f"bare {cmd} replies with usage", await say(s, cmd), expect)

    # Ordinary chat and unknown commands must stay silent, so the bot
    # never talks over a normal conversation.
    _replies.clear()
    await telegram_bot.process_command(s, None, "just some text")
    check("plain text is ignored", len(_replies), 0)
    await telegram_bot.process_command(s, None, "/nonsense")
    check("unknown command is ignored", len(_replies), 0)


async def test_list_output():
    print("\n=== /list ===")
    s = new_store()
    reply = await say(s, "/list")
    check_contains("empty state still shows the TASKS header", reply, "TASKS")
    check_contains("empty state still shows the LEARNING header", reply, "LEARNING")
    check_contains("empty learning section hints how to start", reply, "/course or /book")

    await s.add_task("call dentist")
    await s.add_book("Atomic Habits", 320)
    await s.set_learning_pages(1, 120)
    await s.add_course("Spanish")
    await s.mark_learning_done(2)

    reply = await say(s, "/list")
    check_contains("tasks use the # namespace", reply, "#1: call dentist")
    check_contains("learnings use the L namespace", reply, "L1: Atomic Habits")
    check_contains("book shows its page detail", reply, "(120/320 pages)")
    check_contains("finished learning is marked DONE", reply, "[DONE] L2: Spanish")
    # Finished items sink below unfinished ones.
    check("finished learning sorts last",
          reply.index("L2: Spanish") > reply.index("L1: Atomic Habits"), True)


async def test_persistence_roundtrip():
    print("\n=== state survives a reload ===")
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    os.unlink(path)
    p = Path(path)

    s1 = StateStore(p)
    await s1.add_book("Atomic Habits", 320)
    await s1.set_learning_pages(1, 160)

    s2 = StateStore(p)
    items = await s2.list_learnings()
    check("learning reloaded from disk", len(items), 1)
    check("derived percent survived", items[0]["percent"], 50)
    check("detail caption survived", items[0]["detail"], "160/320 pages")

    # An older state.json predating this feature must load, not crash.
    p.write_text('{"tasks": [{"id": 1, "text": "old", "done": false}]}', encoding="utf-8")
    s3 = StateStore(p)
    check("pre-learnings state.json migrates", await s3.list_learnings(), [])
    check("...without losing the tasks", len(await s3.list_tasks()), 1)
    p.unlink(missing_ok=True)


async def main():
    for t in (
        test_course_basics,
        test_book_derivation,
        test_total_pages_correction,
        test_mark_done_and_delete,
        test_separate_id_spaces,
        test_explicit_prefix_never_crosses_lists,
        test_telegram_book_parsing,
        test_telegram_percent_rules,
        test_telegram_wrong_kind_and_errors,
        test_bare_commands_answer,
        test_list_output,
        test_persistence_roundtrip,
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
