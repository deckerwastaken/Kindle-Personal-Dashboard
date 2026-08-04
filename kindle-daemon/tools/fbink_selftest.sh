#!/bin/sh
# fbink_selftest.sh -- calibration test, run this BY HAND over SSH before
# trusting src/ui.lua's pixel-coordinate assumptions (see the big comment
# at the top of ui.lua). This is step 4 of kindle-daemon/INSTALL.md.
#
# It draws four small marker labels near the four corners of the screen
# and one in the dead center, using the exact same "-x 0 -y 0 -X px -Y px"
# technique ui.lua uses everywhere. If FBInk's row/col grid origin isn't
# pixel (0,0) on this device/firmware, this is where you'll see it: a
# marker meant for the top-left corner will show up somewhere else.
#
# Usage:
#   sh fbink_selftest.sh                       # uses /mnt/us/koreader/fbink
#   sh fbink_selftest.sh /path/to/fbink         # explicit binary path

set -eu

FBINK="${1:-/mnt/us/koreader/fbink}"

if [ ! -x "$FBINK" ]; then
    echo "fbink binary not found or not executable at: $FBINK"
    echo "Pass the correct path as an argument, e.g.:"
    echo "  sh fbink_selftest.sh /mnt/us/koreader/fbink"
    exit 1
fi

echo "Using fbink at: $FBINK"
echo "Clearing screen..."
"$FBINK" -c -q

# Screen is 600x800. Labels are placed a little inset from each true
# corner so the text itself (not just its origin pixel) stays fully
# on-screen and readable.
#
# CONFIRMED ON HARDWARE (2026-08-02): these positions were originally
# guessed (without access to real hardware) and left inconsistent
# margins -- e.g. TOP-RIGHT's guessed inset left 36px from the true
# right edge vs. TOP-LEFT's 10px. `fbink -E` (which reports the exact
# pixel rect actually drawn) gave real text widths, used here to target
# a consistent 10px inset from every true edge, matching TOP-LEFT.
"$FBINK" -x 0 -y 0 -X 10  -Y 10  -S 1 -q -b "TOP-LEFT (10,10)"
"$FBINK" -x 0 -y 0 -X 446 -Y 10  -S 1 -q -b "TOP-RIGHT (446,10)"
"$FBINK" -x 0 -y 0 -X 10  -Y 782 -S 1 -q -b "BOT-LEFT (10,782)"
"$FBINK" -x 0 -y 0 -X 438 -Y 782 -S 1 -q -b "BOT-RIGHT (438,782)"
"$FBINK" -x 0 -y 0 -X 236 -Y 396 -S 1 -q -b "CENTER (236,396)"

echo "Triggering refresh..."
"$FBINK" -s -W GC16 -q

cat <<'EOF'

Now LOOK AT THE SCREEN and check:
  1. Do you see 5 short text labels, roughly one near each corner and
     one in the middle, not all bunched in one spot or off-screen?
  2. Does "TOP-LEFT (10,10)" actually appear near the physical top-left
     corner of the screen (matching whatever orientation the Kindle is
     currently in)?

If yes: the pixel-coordinate assumption in src/ui.lua's big warning
comment holds on your device. You're good to continue with INSTALL.md.

If no (e.g. everything is shifted, mirrored, or rotated 90/180 degrees):
  - Note roughly how far off and in what direction.
  - Open kindle-daemon/src/ui.lua and adjust LAYOUT.origin_x / origin_y
    (a constant pixel shift) to compensate.
  - If it looks rotated rather than just shifted, your device's
    orientation setting (native portrait vs. FBInk's own rotation
    detection) may differ from what's assumed here -- re-run this test
    after also trying `fbink -h` (run with no args) to see FBInk's
    reported rotation/dimensions in its startup banner (drop -q to see
    it), and mention that output when asking for help adjusting this.
EOF
