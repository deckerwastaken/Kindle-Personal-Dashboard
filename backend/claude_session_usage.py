"""
Polls claude.ai's own (unofficial, undocumented) web-app usage endpoint
for the personal Pro/Max plan's current 5-hour "session" rate-limit
percentage, and writes it into the shared StateStore for display on the
Kindle dashboard.

This is a completely different thing from anthropic_usage.py, which
polls the official, documented Anthropic Admin API for org-level token/
dollar spend. That concept doesn't even apply to a personal Pro/Max
plan. This module instead calls the same endpoint claude.ai's own
"Usage" page in the browser calls, authenticated with the browser's own
session cookie -- not an API key. Anthropic could change or remove this
endpoint without notice at any time.

Requires CLAUDE_SESSION_KEY (the claude.ai "sessionKey" cookie value)
and CLAUDE_ORG_ID in backend/.env. If either is missing, this task logs
once and exits without polling -- same "disabled" pattern as
anthropic_usage.py.
"""

import asyncio
import datetime
import logging

import httpx

from . import config
from .state import StateStore

logger = logging.getLogger("kindle_dashboard.claude_session_usage")

USAGE_URL_TEMPLATE = "https://claude.ai/api/organizations/{org_id}/usage"

# claude.ai sits behind bot-detection that 403s a bare httpx client (its
# default "python-httpx/x.x" User-Agent, with none of the other headers a
# real browser sends, gets rejected before the cookie is even checked --
# confirmed 2026-08-04: same request succeeds with these headers, fails
# without). This isn't circumventing an auth boundary -- CLAUDE_SESSION_KEY
# is already this account's own valid session cookie -- it's just making
# an automated request look like the browser tab it's standing in for,
# same as the community browser extension this endpoint was found via.
_BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "*/*",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": "https://claude.ai/settings/usage",
    "Origin": "https://claude.ai",
}


def _format_resets_label(resets_at: str) -> str:
    """Turns an ISO-8601 timestamp into 'Resets in X hr Y min', computed
    at fetch time (the Kindle just displays the string as-is -- no date
    parsing on the device). Returns "" if resets_at is missing/unparsable."""
    if not resets_at:
        return ""
    try:
        reset_dt = datetime.datetime.fromisoformat(resets_at.replace("Z", "+00:00"))
        now = datetime.datetime.now(datetime.timezone.utc)
        total_minutes = max(0, int((reset_dt - now).total_seconds() // 60))
        hours, minutes = divmod(total_minutes, 60)
        if hours > 0:
            return f"Resets in {hours} hr {minutes} min"
        return f"Resets in {minutes} min"
    except (ValueError, TypeError):
        return ""


async def fetch_session_usage(client: httpx.AsyncClient) -> dict | None:
    """Returns {"percent": int, "resets_at": str} for the "session" (5-hour
    window) limit, or None on any failure. Handles both the current
    `limits`-array response shape and the older top-level `five_hour`
    shape, since this undocumented endpoint has changed format before."""
    url = USAGE_URL_TEMPLATE.format(org_id=config.CLAUDE_ORG_ID)
    headers = {**_BROWSER_HEADERS, "Cookie": f"sessionKey={config.CLAUDE_SESSION_KEY}"}
    try:
        r = await client.get(url, headers=headers, timeout=15)
        r.raise_for_status()
        result = r.json()

        limits = result.get("limits")
        if isinstance(limits, list):
            for entry in limits:
                if entry.get("kind") == "session":
                    return {
                        "percent": entry.get("percent", 0),
                        "resets_at": entry.get("resets_at", ""),
                    }
            logger.warning("Claude session usage 'limits' array had no 'session' entry: %r", limits)
            return None

        five_hour = result.get("five_hour")
        if isinstance(five_hour, dict):
            return {
                "percent": five_hour.get("utilization", 0),
                "resets_at": five_hour.get("resets_at", ""),
            }

        logger.warning("Claude session usage response had neither 'limits' nor 'five_hour': %r", result)
        return None
    except Exception as e:
        logger.error("Error fetching Claude session usage: %s", e)
        return None


async def _apply_usage(state: StateStore, usage: dict) -> tuple[int, str]:
    """Shared by poll_loop and refresh_now so the clamp/round/label-format
    logic can't drift between the two call sites."""
    percent = round(max(0, min(100, usage["percent"])))
    resets_at = usage["resets_at"]
    await state.set_session_usage(percent, resets_at, _format_resets_label(resets_at))
    return percent, resets_at


async def poll_loop(state: StateStore) -> None:
    if not config.HAS_CLAUDE_SESSION:
        logger.warning(
            "Claude session usage tracking DISABLED: CLAUDE_SESSION_KEY and/or "
            "CLAUDE_ORG_ID not configured in backend/.env. Skipping poll loop."
        )
        return

    logger.info(
        "Starting Claude session usage poll loop (every %d s)",
        config.CLAUDE_SESSION_POLL_INTERVAL_SECONDS,
    )
    async with httpx.AsyncClient() as client:
        while True:
            try:
                usage = await fetch_session_usage(client)
                if usage is not None:
                    percent, resets_at = await _apply_usage(state, usage)
                    logger.info("Updated Claude session usage: %d%% (resets_at=%s)", percent, resets_at)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.error("Unexpected error in Claude session usage poll loop: %s", e)

            await asyncio.sleep(config.CLAUDE_SESSION_POLL_INTERVAL_SECONDS)


# Module-level, not per-connection: the Kindle is a single device with one
# active WS client at a time, and the point of these limits is to protect
# the upstream (unofficial, bot-detection-sensitive) endpoint from being
# hammered, not to track per-client fairness.
_last_manual_refresh_at: datetime.datetime | None = None
MIN_MANUAL_REFRESH_INTERVAL_SECONDS = 10

# Defense-in-depth beyond the per-tap cooldown above: caps sustained abuse
# (e.g. a compromised/malicious LAN device scripting one refresh every 10s
# indefinitely -- the cooldown alone wouldn't stop that) at a ceiling well
# above any plausible human tap cadence. Tracked as a simple rolling list
# of recent timestamps, pruned to the last hour on each call -- resets on
# backend restart, which is fine here: this is abuse protection for the
# user's own claude.ai account on a trusted home LAN, not a hard security
# boundary.
_manual_refresh_history: list[datetime.datetime] = []
MAX_MANUAL_REFRESHES_PER_HOUR = 20


async def refresh_now(state: StateStore) -> tuple[bool, str]:
    """Handles an on-demand 'refresh_usage' WS action from the Kindle --
    same fetch/apply logic as one poll_loop iteration, but triggered
    immediately instead of waiting for the next scheduled poll. Returns
    (ok, message); the caller (main.py) reports a failure message back to
    the Kindle as a rejected-action error, which daemon.lua already
    surfaces as a toast."""
    global _last_manual_refresh_at

    if not config.HAS_CLAUDE_SESSION:
        return False, "Session usage tracking isn't configured"

    now = datetime.datetime.now(datetime.timezone.utc)
    if _last_manual_refresh_at is not None:
        elapsed = (now - _last_manual_refresh_at).total_seconds()
        if elapsed < MIN_MANUAL_REFRESH_INTERVAL_SECONDS:
            wait = int(MIN_MANUAL_REFRESH_INTERVAL_SECONDS - elapsed) + 1
            return False, f"Please wait {wait}s before refreshing again"

    one_hour_ago = now - datetime.timedelta(hours=1)
    _manual_refresh_history[:] = [t for t in _manual_refresh_history if t > one_hour_ago]
    if len(_manual_refresh_history) >= MAX_MANUAL_REFRESHES_PER_HOUR:
        return False, "Hit the hourly refresh limit -- try again later"

    _last_manual_refresh_at = now
    _manual_refresh_history.append(now)

    async with httpx.AsyncClient() as client:
        usage = await fetch_session_usage(client)
    if usage is None:
        return False, "Couldn't reach claude.ai -- try again shortly"

    percent, resets_at = await _apply_usage(state, usage)
    logger.info("Manual refresh: Claude session usage now %d%% (resets_at=%s)", percent, resets_at)
    return True, ""
