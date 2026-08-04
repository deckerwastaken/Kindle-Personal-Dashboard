# Kindle Dashboard

A personal "Today" dashboard on a jailbroken Kindle e-reader: task list,
Telegram bot integration, and Claude usage tracking, rendered directly to
the e-ink screen and controlled by touch. No cloud, no third-party
service — the backend runs on your own laptop.

## Start here

New to this repo? Read **`docs/LAUNCH_GUIDE.md`** — the single
start-to-finish setup walkthrough. It links out to more detailed guides
for each piece as needed.

Already set up? Day-to-day use is two double-clickable scripts:
`kindle-daemon/ops/Start_Dashboard.bat` and `Stop_Dashboard.bat` — see
`kindle-daemon/ops/README.md`.

## Layout

```
backend/       -- FastAPI service (runs on your laptop): Telegram bot,
                  Anthropic usage polling, WebSocket push to the Kindle.
                  See backend/README.md.
kindle-daemon/ -- standalone Lua daemon that runs directly on the Kindle
                  (not inside KOReader): renders the dashboard via FBInk,
                  reads touch via evdev, connects to the backend.
                  See kindle-daemon/README.md (architecture) and
                  kindle-daemon/INSTALL.md (on-device setup).
lockscreen/    -- optional: replaces the Kindle's stock screensaver with
                  custom text. See lockscreen/README.md.
docs/          -- setup guide, jailbreak reference, and secrets policy.
```

## Is my Kindle compatible?

This project needs a **jailbroken** Kindle (meaning its normal software
restrictions have been removed, so it can run programs Amazon didn't put
there — see `docs/JAILBREAK_REFERENCE.md`), with KUAL and KOReader
installed on top of that. It was built and tested against a Kindle 7th
Gen (2014, model WP63GW, KT2 hardware) jailbroken via WinterBreak2. Other
jailbroken Kindle models will likely also work once KUAL/KOReader are
installed, but haven't been tested — check
`kindle-daemon/README.md`'s "What is genuinely unverified" section
before investing time on a different device.

## Security

Real secrets (Telegram bot token, Anthropic API key, the Kindle's local
config) never live in this repo — see `docs/SECRETS.md` for the policy
this project follows.

## License

MIT — see `LICENSE`. Use it, fork it, adapt it for your own Kindle.
