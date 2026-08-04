#!/bin/sh
# draw_lockscreen.sh -- draws the custom "My Dashboard" screensaver text,
# centered, on a blank screen. That's the whole feature -- this was
# explicitly requested as simple, so it stays simple: one fbink call.
#
# This script does the SAME thing regardless of which tier from
# INSTALL.md invokes it (KOReader's "custom message" screensaver setting,
# or the experimental system-level upstart hook) -- it's just "clear the
# screen, print centered text, refresh." Reused rather than duplicated so
# there's exactly one place that defines what the lock screen looks like.
#
# Usage:
#   sh draw_lockscreen.sh                          # uses default fbink path/text
#   sh draw_lockscreen.sh /path/to/fbink            # explicit fbink path
#   sh draw_lockscreen.sh /path/to/fbink "Some Text" # explicit text too

set -eu

FBINK="${1:-/mnt/us/koreader/fbink}"
TEXT="${2:-My Dashboard}"

if [ ! -x "$FBINK" ]; then
    # Deliberately fail silently-ish here rather than error loudly: if
    # this is invoked from a boot-time hook (Tier 2 in INSTALL.md) and
    # fbink isn't where expected, the very last thing we want is this
    # script itself causing a boot problem. A missing screensaver text is
    # a cosmetic issue; anything touching boot should degrade quietly.
    exit 0
fi

"$FBINK" -c -q
"$FBINK" -m -M -S 3 -q -b "$TEXT"
"$FBINK" -s -W GC16 -q
