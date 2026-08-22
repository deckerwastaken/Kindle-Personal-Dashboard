"""
Syncs each day's habit-tracker completion data to a Google Sheet the user
owns, once that day has ended, as a permanent personal history outside
this app's own `data/state.json` (which only holds the CURRENT day's habit
list -- see state.py). This lets the user look back at streaks and history
in an ordinary spreadsheet without this backend ever needing to grow its
own historical-query API or database.

Entirely optional, like every other external integration in this codebase
(Telegram, the Anthropic Admin API, claude.ai session usage -- see
config.py). Requires GOOGLE_SHEETS_CREDENTIALS_FILE and
GOOGLE_SHEETS_SPREADSHEET_ID in backend/.env; if either is missing,
sync_day() returns a "skipped" result immediately, same "disabled" pattern
as anthropic_usage.py and claude_session_usage.py. Unlike those two,
config.HAS_GOOGLE_SHEETS being True does NOT guarantee the credentials
file actually opens or that the target sheet has actually been shared
with the service account -- see config.py's comment next to
HAS_GOOGLE_SHEETS for why that's checked lazily here instead, on the
first real sync attempt, rather than at import time.

Auth is a Google **Service Account**, not an interactive OAuth login: this
backend is unattended and gets restarted by scripts (see
backend/ops/AUTOSTART_SETUP.md), so there is never a human present to
click through a browser consent screen or refresh an expired token. A
service-account key is a JSON file the user downloads once from Google
Cloud Console and shares their sheet with -- see
docs/GOOGLE_SHEETS_SETUP.md for the full, no-jargon walkthrough.

gspread is a synchronous, blocking library (plain HTTP calls under the
hood, no asyncio support). This whole backend is asyncio-native -- the
WebSocket connection to the Kindle and the Telegram long-poll loop both
live on the same event loop -- so every blocking gspread call in this
module is confined to plain (non-async) helper functions and reached ONLY
through asyncio.to_thread(), never called directly from an `async def`.
Calling gspread straight from async code would stall the whole event loop
(freezing the Kindle's live connection) for however long the Sheets API
takes to answer.
"""

import asyncio
import logging

import gspread
from google.oauth2.service_account import Credentials
from gspread.exceptions import WorksheetNotFound
from gspread.utils import rowcol_to_a1

from . import config

logger = logging.getLogger("kindle_dashboard.google_sheets")

WORKSHEET_NAME = "Daily Habits"

# Read/write access to Sheets only -- this integration never needs to
# create/delete/list spreadsheets (the user creates the sheet by hand, see
# the setup doc), so it doesn't ask for the broader Drive scope.
_SHEETS_SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]

# Lazily initialized on first real use, then reused across calls so we
# don't re-authenticate (a real network round trip) on every single sync.
# Module-level, not per-call: both are plain, synchronous gspread/
# google-auth objects with no asyncio-specific state, so it's fine for one
# to be created in whichever worker thread happens to run the first
# asyncio.to_thread() call and then get reused from a *different* worker
# thread on a later call -- gspread doesn't keep a persistent connection
# or any other thread-affine handle open between requests, each call is
# just a fresh outbound HTTP request.
#
# No lock guarding this cache: sync_day() is only ever called from one
# place in this app (a once-a-day end-of-day archive, plus an occasional
# manual "/dailysync" test trigger), never concurrently with itself. If
# that ever changes, this module needs a lock around the "is it cached
# yet" check-and-set below.
_client: gspread.Client | None = None
_spreadsheet: gspread.Spreadsheet | None = None


def _get_spreadsheet() -> gspread.Spreadsheet:
    """Blocking. Authenticates (if not already cached) and opens the
    configured spreadsheet by ID, caching both for reuse. Deliberately
    left to raise on failure rather than catching anything here -- its one
    caller (_sync_day_blocking) already wraps this in a try/except and
    turns whatever comes out into a clear (False, message) result, so
    duplicating that handling in here too would just be two places that
    can drift out of sync with each other.
    """
    global _client, _spreadsheet
    if _spreadsheet is not None:
        return _spreadsheet
    if _client is None:
        creds = Credentials.from_service_account_file(
            config.GOOGLE_SHEETS_CREDENTIALS_FILE, scopes=_SHEETS_SCOPES
        )
        _client = gspread.authorize(creds)
    _spreadsheet = _client.open_by_key(config.GOOGLE_SHEETS_SPREADSHEET_ID)
    return _spreadsheet


def _get_or_create_worksheet(spreadsheet: gspread.Spreadsheet) -> gspread.Worksheet:
    """Blocking. Finds the "Daily Habits" tab, or creates it with just a
    ["Date"] header row if this is the first sync ever for this sheet.
    Habit columns get added lazily as new habits are actually seen -- see
    _sync_day_blocking."""
    try:
        return spreadsheet.worksheet(WORKSHEET_NAME)
    except WorksheetNotFound:
        worksheet = spreadsheet.add_worksheet(title=WORKSHEET_NAME, rows=100, cols=26)
        worksheet.update(range_name="A1", values=[["Date"]])
        logger.info("Created '%s' worksheet with a fresh header row", WORKSHEET_NAME)
        return worksheet


def _header_for(item: dict) -> str:
    """The exact, deterministic column-header text for one habit item.
    Baking the id into the header (not just the topic text) means two
    habits that happen to share the same topic string never collide on
    the same column -- ids are unique, topic text isn't guaranteed to be."""
    return f"{item['topic']} [D{item['id']}]"


def _sync_day_blocking(date_str: str, items: list[dict]) -> tuple[bool, str]:
    """The actual blocking body of sync_day() -- runs inside a worker
    thread via asyncio.to_thread(), see this module's docstring for why.
    Every realistic failure mode (bad/missing credentials file, the sheet
    not being shared with the service account so a permission error comes
    back, no network, hitting Sheets API rate limits, unexpected response
    shapes) is caught here and turned into a (False, message) result --
    this function must never let an exception escape, since its caller's
    whole contract is that sync_day() never raises."""
    try:
        spreadsheet = _get_spreadsheet()
    except FileNotFoundError:
        msg = f"credentials file not found at {config.GOOGLE_SHEETS_CREDENTIALS_FILE!r}"
        logger.warning("Google Sheets sync skipped for %s: %s", date_str, msg)
        return False, msg
    except Exception as e:
        msg = f"couldn't authenticate to Google Sheets ({e})"
        logger.warning("Google Sheets sync failed for %s: %s", date_str, msg)
        return False, msg

    try:
        worksheet = _get_or_create_worksheet(spreadsheet)
    except Exception as e:
        msg = f"couldn't open/create the '{WORKSHEET_NAME}' tab ({e})"
        logger.warning("Google Sheets sync failed for %s: %s", date_str, msg)
        return False, msg

    try:
        header = worksheet.row_values(1)
        if not header:
            # Tab existed (e.g. the user created it by hand) but has no
            # header yet -- same starting point as a freshly-created tab.
            header = ["Date"]
            worksheet.update(range_name="A1", values=[header])

        # 0-based index into `header` for every column already known
        # about, keyed by its exact "<topic> [D<id>]" text.
        col_index_by_header = {name: i for i, name in enumerate(header)}

        # A single batch of {"range": ..., "values": [[...]]} writes, sent
        # as one Sheets API request at the end -- fewer round trips, and
        # keeps "extend the header" and "write this row" as one atomic-ish
        # network operation instead of two that could fail independently.
        updates: list[dict] = []

        # 1. Any item whose column doesn't exist yet gets appended to the
        # right of the current last column, in the order items appear in
        # this call. Existing columns are never touched, reordered, or
        # removed -- including for a habit that's since been deleted on
        # the app side, whose historical column and data just sit there
        # unchanged and stop receiving new values.
        new_headers = []
        for item in items:
            col_name = _header_for(item)
            if col_name not in col_index_by_header:
                col_index_by_header[col_name] = len(header) + len(new_headers)
                new_headers.append(col_name)

        if new_headers:
            start_col = len(header) + 1  # 1-based
            end_col = len(header) + len(new_headers)
            start_a1 = rowcol_to_a1(1, start_col)
            end_a1 = rowcol_to_a1(1, end_col)
            updates.append({"range": f"{start_a1}:{end_a1}", "values": [new_headers]})
            header = header + new_headers

        # 2. Idempotent upsert: find whether a row for this date already
        # exists. A plain column-A scan rather than worksheet.find() --
        # find()'s not-found behavior (raises vs. returns None) has
        # actually changed across gspread releases, and this sheet is
        # small enough (one row per day) that a scan is cheap and doesn't
        # need to lean on version-specific behavior to get right.
        date_column = worksheet.col_values(1)
        row_number = None
        for i, value in enumerate(date_column[1:], start=2):  # 1-based rows, skip header
            if value == date_str:
                row_number = i
                break
        if row_number is None:
            row_number = len(date_column) + 1

        updates.append({"range": rowcol_to_a1(row_number, 1), "values": [[date_str]]})

        # Only the columns for items in THIS call are written -- never a
        # blanket overwrite of the whole row width. That's what keeps a
        # column blank for any date before that habit existed (nothing
        # ever gets written there in the first place) and leaves a
        # since-deleted habit's column alone for this and future rows.
        for item in items:
            col = col_index_by_header[_header_for(item)] + 1  # 1-based
            # Native Sheets boolean, not the strings "TRUE"/"FALSE":
            # gspread passes Python values straight through into the
            # Sheets API request body as JSON, and a JSON true/false is
            # stored by Sheets as an actual BOOLEAN-typed cell (usable as
            # a real checkbox, COUNTIF-able, etc.) regardless of
            # valueInputOption -- this is the standard gspread idiom for
            # writing checkbox-compatible cells. If a future gspread
            # version ever changed this and stringified bools instead,
            # Sheets auto-coerces literal "TRUE"/"FALSE" strings back into
            # real booleans on ingest anyway, so this degrades safely
            # either way.
            value = bool(item.get("done"))
            updates.append({"range": rowcol_to_a1(row_number, col), "values": [[value]]})

        worksheet.batch_update(updates, value_input_option="USER_ENTERED")
    except Exception as e:
        msg = f"write to Google Sheets failed ({e})"
        logger.warning("Google Sheets sync failed for %s: %s", date_str, msg)
        return False, msg

    msg = f"synced {len(items)} habit(s) for {date_str}"
    logger.info("Google Sheets sync: %s", msg)
    return True, msg


async def sync_day(date_str: str, items: list[dict]) -> tuple[bool, str]:
    """
    Archives one day's final habit-completion state to the "Daily Habits"
    tab of the configured Google Sheet (creating the tab, and any new
    habit columns, as needed). Safe to call more than once for the same
    date -- e.g. a manual "sync now" test before the real end-of-day sync
    fires for that same date -- the row for that date is updated in place
    rather than duplicated.

    date_str: an ISO date, e.g. "2026-08-19" -- the day being archived
        (already ended).
    items: the daily habit list as it stood at the moment the day ended,
        each with its final done/not-done state for that day, e.g.
        [{"id": 1, "time": "7:00 AM", "topic": "Meditate", "done": True}, ...]

    Returns (ok, message) -- message is a short human-readable string
    suitable for logging either way. Never raises: any failure (Google
    Sheets not configured, bad credentials, sheet not shared with the
    service account, network trouble, hitting API rate limits) comes back
    as (False, message) instead of an exception, so a Google Sheets outage
    can never crash whatever background task called this.
    """
    if not config.HAS_GOOGLE_SHEETS:
        # Expected, normal state for most installs (this feature is
        # entirely optional) -- not warning/error-worthy on its own.
        logger.debug("Google Sheets sync skipped for %s: not configured", date_str)
        return False, "Google Sheets not configured (skipped)"

    try:
        return await asyncio.to_thread(_sync_day_blocking, date_str, items)
    except asyncio.CancelledError:
        raise
    except Exception as e:
        # Belt-and-suspenders: _sync_day_blocking already catches every
        # realistic failure itself and returns (False, message) instead of
        # raising. This outer catch exists only so that a bug in THIS
        # module (not the Sheets API) still can't escape sync_day() and
        # crash whatever background task called it -- matching this
        # codebase's rule that no external integration is ever allowed to
        # take the app down with it.
        msg = f"unexpected error syncing to Google Sheets ({e})"
        logger.warning("Google Sheets sync failed for %s: %s", date_str, msg)
        return False, msg
