# Secrets Policy

A short set of rules this project follows from here on, written down so future
sessions (human or AI) don't have to rediscover them.

## The pattern

- **Real secrets live only in git-ignored files**: `backend/.env` and (once you fill
  in your real LAN IP) `kindle-daemon/src/config.lua`. Nothing else.
- **`.example` / `.example.lua` files are the templates.** They are tracked in git
  and must only ever contain placeholder text (`PASTE_YOUR_...`, `192.168.1.100`,
  etc.) — never a real value, even temporarily, even to "test something quickly."
- **Secrets are never pasted into chat, docs, commit messages, or issue trackers.**
  If a value needs debugging, describe the *symptom* ("the request returns 401") or
  share a redacted form (first/last few characters only), not the raw value.
- **A secret that touches chat/logs/a doc is treated as burned immediately**,
  regardless of whether anyone believes it was seen by anyone else. Rotate at the
  provider; don't just delete the text and move on.

## What's git-ignored and why

| File | Contains | Git status |
|---|---|---|
| `backend/.env` | `TELEGRAM_TOKEN`, `CHAT_ID`, `ANTHROPIC_ADMIN_KEY`, `CLAUDE_SESSION_KEY`, `CLAUDE_ORG_ID` | Ignored (`backend/.gitignore` + repo root `.gitignore`, both list `.env`) |
| `backend/.env.example` | Placeholders only | Tracked |
| `kindle-daemon/src/config.lua` | Your home LAN IP, touch calibration, local paths | Ignored (repo root `.gitignore`) |
| `kindle-daemon/config.example.lua` | Placeholder IP (`192.168.1.100`), documented defaults | Tracked |

Note on `CLAUDE_SESSION_KEY` specifically: it's your claude.ai browser session
cookie, not an API key — it grants full access to your claude.ai account, so treat
it like a password, not like a scoped/revocable API credential. See
`backend/claude_session_usage.py`'s module docstring for what it's used for and why
it's optional (the dashboard runs fine without it).

Verified directly against the actual repo (not just by reading the ignore files):

```
git check-ignore -v backend/.env
  -> backend/.gitignore:3:.env   backend/.env

git check-ignore -v kindle-daemon/src/config.lua
  -> .gitignore:<line>:kindle-daemon/src/config.lua   kindle-daemon/src/config.lua
```

Note: the home LAN IP in `config.lua` isn't itself a secret (it's not reachable or
useful outside your home network), but it's still kept out of git as a matter of
habit — same pattern as everything else, so there's only one rule to remember, not
a "this one's fine, that one isn't" exception list.

## When adding a new credential to this project

1. Add it to the relevant `.env.example` (or `.example.lua`) with a placeholder
   value and a one-line comment saying what it is and where to get it.
2. Add the loader code (see `backend/config.py`'s pattern: `load_dotenv` +
   `os.getenv(..., "")` + a `HAS_X` boolean gate so the app degrades gracefully if
   the value is left blank/placeholder).
3. Confirm the real file it lives in is covered by an existing `.gitignore` rule —
   don't assume; run `git check-ignore -v <path>` and see it print a match.
4. Never commit the real value anywhere, including in a "temporary" test commit —
   there's no such thing as a temporary commit once it's pushed, and even locally
   it's now sitting in `.git/`.

## If a secret leaks anyway

A secret that was ever pasted into a chat, doc, or commit is treated as compromised
from the moment it was pasted — not from whenever someone gets around to checking.
The order that actually fixes it:

1. **Rotate it at the provider first** (revoke the old value, generate a new one).
   This is the only step that actually stops the exposed value from working.
2. Clean up any code/docs/commits that reference the old value.
3. If it ever reached a real commit, purge it from git history too (e.g. with
   `git filter-repo` or BFG Repo-Cleaner) — deleting the file in a new commit isn't
   enough, the old value is still sitting in every earlier commit's history.

Code removal alone is never the fix — it's step 2 of several, not the whole job.
