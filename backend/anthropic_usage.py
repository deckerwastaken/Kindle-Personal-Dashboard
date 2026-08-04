"""
Polls Anthropic's Admin API every 15 minutes for today's total token
usage (input + output) and writes it into the shared StateStore, which
in turn broadcasts it to connected Kindle clients. Same cadence and
totaling logic as the v1 prototype, just async (httpx) and running as a
background task inside the FastAPI app.

Requires ANTHROPIC_ADMIN_KEY (a key starting with "sk-ant-admin") in
backend/.env. If absent, this task logs once and exits without polling
-- same "usage tracking disabled" behavior as the original script.
"""

import asyncio
import datetime
import logging

import httpx

from . import config
from .state import StateStore

logger = logging.getLogger("kindle_dashboard.anthropic_usage")

USAGE_URL = "https://api.anthropic.com/v1/organizations/usage_report/messages"


async def fetch_today_usage(client: httpx.AsyncClient) -> int | None:
    today = datetime.datetime.now(datetime.timezone.utc).date()
    start = today.isoformat() + "T00:00:00Z"
    end = (today + datetime.timedelta(days=1)).isoformat() + "T00:00:00Z"
    try:
        r = await client.get(
            USAGE_URL,
            params={"starting_at": start, "ending_at": end, "bucket_width": "1d"},
            headers={
                "anthropic-version": "2023-06-01",
                "x-api-key": config.ANTHROPIC_ADMIN_KEY,
            },
            timeout=15,
        )
        r.raise_for_status()
        result = r.json()
        total_tokens = 0
        for bucket in result.get("data", []):
            for item in bucket.get("results", []):
                total_tokens += item.get("input_tokens", 0) + item.get("output_tokens", 0)
        return total_tokens
    except Exception as e:
        logger.error("Error fetching Claude usage: %s", e)
        return None


async def poll_loop(state: StateStore) -> None:
    if not config.HAS_ANTHROPIC_KEY:
        logger.warning(
            "Anthropic usage tracking DISABLED: no ANTHROPIC_ADMIN_KEY (must start "
            "with sk-ant-admin) configured in backend/.env. Skipping poll loop."
        )
        return

    logger.info(
        "Starting Anthropic usage poll loop (every %d s)",
        config.ANTHROPIC_POLL_INTERVAL_SECONDS,
    )
    async with httpx.AsyncClient() as client:
        while True:
            try:
                tokens = await fetch_today_usage(client)
                if tokens is not None:
                    await state.set_usage(tokens)
                    logger.info("Updated Claude usage: %d tokens today", tokens)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.error("Unexpected error in Anthropic usage poll loop: %s", e)

            await asyncio.sleep(config.ANTHROPIC_POLL_INTERVAL_SECONDS)
