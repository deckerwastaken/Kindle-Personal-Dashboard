"""
Configuration and secrets loading for the Kindle Dashboard backend.

All secrets come from a `.env` file placed next to this module
(`backend/.env`) -- never hardcode them. See `.env.example` for the
required keys.
"""

import os
from pathlib import Path

from dotenv import load_dotenv

# backend/ directory (this file's parent)
BASE_DIR = Path(__file__).resolve().parent

# Load backend/.env if present. Real deployments should create this file;
# it is git-ignored (see backend/.gitignore).
load_dotenv(BASE_DIR / ".env")

# ======= Secrets (from .env) =======
TELEGRAM_TOKEN = os.getenv("TELEGRAM_TOKEN", "")
CHAT_ID = os.getenv("CHAT_ID", "")
ANTHROPIC_ADMIN_KEY = os.getenv("ANTHROPIC_ADMIN_KEY", "")
# claude.ai web-app session cookie + org ID, used ONLY for the unofficial
# personal-plan "current session % used" endpoint -- see
# claude_session_usage.py's module docstring for why this is a totally
# separate thing from ANTHROPIC_ADMIN_KEY above. Treat CLAUDE_SESSION_KEY
# as an account-equivalent credential, same care as TELEGRAM_TOKEN.
CLAUDE_SESSION_KEY = os.getenv("CLAUDE_SESSION_KEY", "")
CLAUDE_ORG_ID = os.getenv("CLAUDE_ORG_ID", "")

# ======= Derived config =======
TELEGRAM_API = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}"

# Telegram bot is considered "configured" only if a token was actually
# supplied (not left as the .env.example placeholder or blank). If it's
# not configured we skip polling entirely instead of spamming 401s.
HAS_TELEGRAM = bool(TELEGRAM_TOKEN) and not TELEGRAM_TOKEN.startswith("PASTE_YOUR_")

# Anthropic Admin API keys always start with this prefix. Same gating
# behavior as the original prototype script.
HAS_ANTHROPIC_KEY = ANTHROPIC_ADMIN_KEY.startswith("sk-ant-admin")

# Session-usage tracking is considered "configured" only if both values
# were actually supplied (not left as .env.example placeholders).
HAS_CLAUDE_SESSION = (
    bool(CLAUDE_SESSION_KEY)
    and bool(CLAUDE_ORG_ID)
    and not CLAUDE_SESSION_KEY.startswith("PASTE_YOUR_")
    and not CLAUDE_ORG_ID.startswith("PASTE_YOUR_")
)

# ======= State persistence =======
STATE_FILE = BASE_DIR / "data" / "state.json"

# ======= Discovery beacon =======
# The backend announces its own address on the LAN over UDP so the Kindle
# can find it again after this laptop's IP changes -- see discovery.py.
#
# Enabled by default. The alternative is what used to happen: the daemon
# learns the laptop's address once at startup, and a DHCP lease change
# mid-session leaves it talking to an address that no longer exists, with
# no way back except restarting the dashboard by hand.
#
# Set DISCOVERY_ENABLED=0 in .env to turn it off. Worth knowing before you
# decide: the beacon is an unauthenticated UDP broadcast, so anything on
# your LAN can see it, and equally anything on your LAN could send a
# lookalike telling the Kindle to connect somewhere else. That is the same
# trust model the rest of this project already has (the WebSocket has no
# authentication either), but it is now one packet easier to abuse, so the
# choice is yours to make deliberately. The daemon does refuse beacons
# advertising anything outside the private address ranges.
DISCOVERY_ENABLED = os.getenv("DISCOVERY_ENABLED", "1") not in ("0", "false", "False", "no")
DISCOVERY_PORT = int(os.getenv("DISCOVERY_PORT", "8001"))
DISCOVERY_INTERVAL_SECONDS = 5

# ======= Polling cadence =======
TELEGRAM_POLL_INTERVAL_SECONDS = 2
TELEGRAM_LONG_POLL_TIMEOUT = 5  # Telegram long-poll "timeout" query param
ANTHROPIC_POLL_INTERVAL_SECONDS = 15 * 60  # 15 minutes
# Shorter than the Admin API poll above: this drives a "how close am I to
# my 5-hour cap" display, which is more useful fresh. Still conservative
# given this hits an undocumented endpoint, not the real API.
CLAUDE_SESSION_POLL_INTERVAL_SECONDS = 5 * 60  # 5 minutes
