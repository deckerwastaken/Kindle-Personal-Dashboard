"""
Background loop that checks, roughly once a minute, whether the local
calendar date has advanced -- and if so, archives the Daily habits
checklist's completion state for the day that just ended and resets every
item's `done` flag for the new day.

See StateStore.maybe_reset_dailies() in state.py for the actual reset
logic and why this is a plain polling loop rather than a precise
sleep-until-midnight timer (short version: this backend is not always
running, so a timer set to fire at an exact wall-clock moment could simply
never fire).
"""

import asyncio
import logging

from .state import StateStore

logger = logging.getLogger("kindle_dashboard.daily_reset")

# 60s: fast enough that the checklist rolls over within a minute of local
# midnight whenever the backend happens to be running then, cheap enough
# (one date-string comparison under a lock) that polling this often costs
# nothing worth tuning.
POLL_INTERVAL_SECONDS = 60


async def poll_loop(state: StateStore) -> None:
    """Never raises -- any error during a single check is logged and the
    loop continues, matching every other poll_loop in this backend
    (telegram_bot.py, anthropic_usage.py, claude_session_usage.py)."""
    logger.info("Starting Daily habits reset watcher (checks every %ds)", POLL_INTERVAL_SECONDS)
    while True:
        try:
            if await state.maybe_reset_dailies():
                logger.info("Daily habits: rolled over to a new day.")
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logger.error("Unexpected error in Daily habits reset watcher: %s", e)

        await asyncio.sleep(POLL_INTERVAL_SECONDS)
