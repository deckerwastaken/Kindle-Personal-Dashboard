#!/bin/sh
# run.sh -- wrapper that launches the dashboard daemon.
#
# This is the ONE file that both a manual SSH test run and the upstart
# boot job (install/kindle-dashboard.conf) both call, so "testing it
# manually first" (required by INSTALL.md before wiring anything into
# boot) is testing the exact same code path that boot will use later.
#
# IMPORTANT: this file must have Unix (LF) line endings, not Windows
# (CRLF) -- if you edit it on Windows, save it as LF or the Kindle's
# shell will fail to run it with a cryptic error. If you only ever edit
# it through this repo / a text editor set to LF, you don't need to
# think about this again.

set -eu

# Absolute path to this script's own directory, so this works no matter
# what directory it's launched from (upstart jobs run with an unhelpful
# working directory by default).
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
DAEMON_DIR="$SCRIPT_DIR/../src"

# Where your KOReader install lives. Adjust this if you installed
# KOReader somewhere other than the Kindle's root -- see
# docs/JAILBREAK_REFERENCE.md for how it was installed on the reference
# device (root > koreader).
KOREADER_DIR="/mnt/us/koreader"
LUAJIT_BIN="$KOREADER_DIR/luajit"

LOG_DIR="/mnt/us/kindle-daemon"
CRASH_LOG="$LOG_DIR/crash.log"

mkdir -p "$LOG_DIR"

# Stop the Kindle's own stock power management from putting the device to
# sleep (which turns off Wi-Fi) after a period of no taps -- this has
# nothing to do with which app is on screen; it's a system-level timer that
# fires even while this dashboard is the active app. When it fires, Wi-Fi
# drops, the WebSocket connection to the backend dies, and the dashboard
# shows "OFFLINE" until you tap the screen to wake the device back up (this
# is why the dashboard was reported going offline after sitting idle).
#
# UNVERIFIED ON HARDWARE: `preventScreenSaver` is the standard lipc
# property name used across Kindle jailbreak tooling for exactly this
# purpose, but it has not yet been confirmed against this specific device
# (Kindle 7 WP63GW, firmware 5.12.2.2). Check it worked by leaving the
# dashboard idle for longer than it previously took to go offline, and by
# running `lipc-get-prop com.lab126.powerd preventScreenSaver` over SSH
# (should read back "1"). `|| true` so a missing/renamed property on this
# firmware can't stop the daemon from starting -- worst case here is just
# "sleep still happens, no worse off than before this change".
#
# Not undone anywhere in this script: both ways of stopping the dashboard
# (the on-screen "Exit Dashboard" button and Stop_Dashboard.bat) end in
# `reboot`, which clears this back to the stock default on its own -- there
# is no code path where the daemon stops WITHOUT a reboot, so nothing here
# needs to explicitly set it back to 0.
lipc-set-prop com.lab126.powerd preventScreenSaver 1 >>"$CRASH_LOG" 2>&1 || true

# Disable Wi-Fi radio power-save mode. CONFIRMED ON HARDWARE (2026-08-03):
# `iw wlan0 get power_save` read back "on" by default, and with it on the
# radio periodically dropped its own connection (wpa_supplicant logged
# CTRL-EVENT-DISCONNECTED with reason=3 locally_generated=1 -- i.e. the
# Kindle itself was voluntarily disconnecting, not the router kicking it
# off), which repeatedly dropped the dashboard's WebSocket a few seconds
# after connecting and in some cases triggered the stock reboot-safety-net
# via the resulting Xorg/lab126_gui churn. Turning this off resolved it:
# verified stable (WS connected, zero drops) for 60+ seconds afterward,
# vs. dropping within ~3-8 seconds every time before. This is a per-boot
# radio setting, reset to "on" by every reboot, hence set here every run
# rather than once. `|| true` since a missing `iw` binary or renamed
# interface on a different device shouldn't block the daemon from starting.
iw wlan0 set power_save off >>"$CRASH_LOG" 2>&1 || true

# Let the backend's discovery beacons reach us (see src/discovery.lua).
#
# CONFIRMED ON HARDWARE (2026-08-12), and it is NOT optional: this
# device's iptables INPUT chain has policy DROP, and the rule that looks
# like a blanket "ACCEPT all" in `iptables -L INPUT -n` is actually scoped
# to the usb0 interface -- you only see that with `-v`, which is what made
# the first reading of it wrong. Inbound UDP on wlan0 is otherwise
# accepted only for ESTABLISHED flows and a handful of stock ports.
# Verified in both directions: with this rule, every beacon arrives; with
# it removed, the chain's own drop counter rises by exactly the number
# sent and nothing is delivered.
#
# Check-then-add (-C then -A), the same idiom as the SSH restart command
# in config.example.lua, so repeated dashboard starts within one boot
# don't stack up duplicate rules. iptables rules are not persistent, so
# this has to run every start, exactly like the power_save line above.
DISCOVERY_PORT="$(awk -F'[ =,]+' '/^[^-]*discovery_port/ {print $3; exit}' "$DAEMON_DIR/config.lua" 2>/dev/null)"
[ -n "$DISCOVERY_PORT" ] || DISCOVERY_PORT=8001
iptables -C INPUT -i wlan0 -p udp --dport "$DISCOVERY_PORT" -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -i wlan0 -p udp --dport "$DISCOVERY_PORT" -j ACCEPT \
       >>"$CRASH_LOG" 2>&1 || true

if [ ! -x "$LUAJIT_BIN" ]; then
    echo "run.sh: $LUAJIT_BIN not found or not executable." >>"$CRASH_LOG"
    echo "Is KOReader installed at $KOREADER_DIR ? Edit KOREADER_DIR in this" >>"$CRASH_LOG"
    echo "script if it lives somewhere else." >>"$CRASH_LOG"
    exit 1
fi

if [ ! -f "$DAEMON_DIR/config.lua" ]; then
    echo "run.sh: $DAEMON_DIR/config.lua is missing." >>"$CRASH_LOG"
    echo "Copy config.example.lua to config.lua and edit it first -- see INSTALL.md." >>"$CRASH_LOG"
    exit 1
fi

# Stop the stock reading UI (KOReader running as an Xorg client) so this
# daemon can own the touchscreen and e-ink framebuffer itself. Confirmed
# on-device (2026-08-02): Xorg holds an exclusive grab on /dev/input/eventN
# the entire time it's running, which silently blocks src/touch.lua from
# ever seeing a single event, even though open() succeeds -- see
# INSTALL.md step 3's troubleshooting note.
#
# CONFIRMED ON HARDWARE, twice now (2026-08-02 original bring-up, and
# again in a later session on this same date): a raw `killall -s KILL
# Xorg` looks like a CRASH to upstart's own respawn monitor, not a
# deliberate stop -- lab126_gui.conf's own pre-start script increments a
# session RESTARTS counter every time this happens and reboots the
# device outright once MAX_RESTARTS (3) is hit within the current boot.
# The first fix attempt (cutting the retry from 30x/1s down to 2 gentle
# attempts a few seconds apart) reduced but did NOT eliminate this risk
# -- it fired again in a later session, most likely because the session
# counter isn't necessarily starting fresh at 0 (e.g. some other
# background hiccup on this device already contributed to it -- see this
# project's broader notes on a "swarm" of unrelated stock daemons
# occasionally crashing on this specific device).
#
# FIX (from that session): use upstart's own `stop x` instead of a raw
# `killall -9 Xorg`. CONFIRMED ON HARDWARE: /sbin/stop (a symlink to
# initctl) is available on this device, "x" is the actual upstart job
# name governing Xorg (`initctl list` shows "x start/running"), and
# `/sbin/stop x` cleanly stops it with NO reboot and NO effect on
# lab126_gui's own RESTARTS counter. lab126_gui.conf's own "stop on
# stopping x" clause means lab126_gui cascades to a stop for free.
#
# SECOND, SEPARATE REBOOT PATH FOUND AND FIXED (2026-08-03 late
# session): even with the `stop x` fix above in place, the dashboard
# kept rebooting a few seconds after starting -- confirmed via
# /var/log/messages (persists across a reboot via the kernel's own
# printk ring-buffer replay) that this was always a genuine, deliberate
# `reboot()` call (`Restarting system.` in the kernel log), not a crash.
#
# ROOT CAUSE (the real one, found after two earlier partial theories
# that each reduced but didn't eliminate the reboot -- see below): the
# INSTALLED KOReader launcher, `/var/tmp/koreader.sh` (a copy of
# koreader.sh from the KOReader release itself, not part of this
# project), runs `./reader.lua` as a plain BLOCKING foreground command
# inside a loop and stays alive the whole time reader.lua runs. When
# reader.lua exits for ANY reason -- including this script forcibly
# killing it -- koreader.sh's own cleanup code runs next, and
# (confirmed by reading koreader.sh directly on-device) UNCONDITIONALLY
# does `start "${job}"` for a whole list of stock services it stopped
# to save RAM when it originally launched (`TOGGLED_SERVICES="stored
# webreader kfxreader kfxview todo tmd rcm archive scanner otav3
# otaupd"`) -- this is completely independent of whatever this project's
# own code (`STOP_FRAMEWORK`, framework/kb/x) does. Every one of those
# services needs a display (they're mesquite/Xorg-based apps), so if X
# is already down when koreader.sh tries to restart them (which it will
# be, since this daemon needs X down to own the touchscreen), each one
# fails instantly with "Cannot open display", and upstart's own
# respawn logic retries it in a tight loop -- confirmed live via `tail
# -f /var/log/messages` during an actual reboot, seeing `stored`
# specifically hit its own separate RESTART_LIMIT=5 within about 3
# seconds of "Resuming volumd . . ." (koreader.sh's own log line)
# appearing, immediately followed by the device rebooting. WHICH
# specific service's monitor trips the reboot first varies between runs
# (a race), which is why earlier live tests pointed at different-looking
# culprits (`framework`/`lab126_gui_monitor.conf` one time, `stored`
# another) -- they're all downstream symptoms of the same koreader.sh
# cleanup step, not separate root causes in their own right.
#
# Two earlier, narrower theories were tried and each genuinely helped
# but didn't fully fix it, which is worth keeping here so a future
# session doesn't re-try them expecting a full fix:
#   1. `stop x` instead of `killall -9 Xorg` (still correct, keeps this
#      script from tripping lab126_gui.conf's own crash-loop reboot).
#   2. Explicitly `/sbin/stop`-ing `framework` and `kb` before killing
#      reader.lua (still harmless, but doesn't address koreader.sh's
#      unconditional TOGGLED_SERVICES restart, which happens regardless
#      of framework/kb's state).
#
# REAL FIX: prevent koreader.sh's cleanup code from running at all when
# THIS script is the one taking down reader.lua, by also killing
# koreader.sh's own wrapper shell process (reader.lua's direct parent)
# in the same breath, before it gets a chance to notice reader.lua died
# and start restarting things. Found reader.lua's parent PID via
# /proc/<pid>/status's PPid field (NOT via `pkill -f koreader.sh`, which
# was tried first and instantly killed the CURRENT shell running that
# very pkill command, since the command line you pass to `pkill -f`
# itself contains the string "koreader.sh" as text -- a classic
# self-matching footgun; confirmed on hardware when a test SSH session
# died immediately, before its own next command could even run).
# Guarded with `[ "$WRAPPER_PID" != "1" ]` because a reader.lua process
# that's already been orphaned (parent = init, PID 1) has no wrapper
# left to kill -- observed on-device that this can happen even under
# normal operation, and `kill -9 1` would be catastrophic.
#
# Order: find and kill the wrapper, then reader.lua, THEN the
# framework/kb/x stops (still kept, as defense in depth against the
# earlier, separate lab126_gui_monitor.conf path -- doesn't hurt to keep
# both fixes layered).
echo "run.sh: stopping KOReader's launcher script (if still alive) and reader.lua, then cleanly stopping the framework/kb/x upstart jobs" >>"$CRASH_LOG"
READER_PID="$(ps | awk '/reader\.lua/ && !/awk/ {print $1; exit}')"
if [ -n "$READER_PID" ]; then
    WRAPPER_PID="$(awk '/^PPid:/{print $2}' "/proc/$READER_PID/status" 2>/dev/null)"
    if [ -n "$WRAPPER_PID" ] && [ "$WRAPPER_PID" != "1" ]; then
        echo "run.sh: killing koreader.sh wrapper (pid $WRAPPER_PID, parent of reader.lua pid $READER_PID)" >>"$CRASH_LOG"
        kill -9 "$WRAPPER_PID" 2>/dev/null || true
    fi
fi
killall -q -s KILL reader.lua 2>/dev/null || true
rm -f /var/run/upstart/lab126_gui.restarts 2>/dev/null || true
/sbin/stop framework >>"$CRASH_LOG" 2>&1 || true
/sbin/stop kb >>"$CRASH_LOG" 2>&1 || true
/sbin/stop x >>"$CRASH_LOG" 2>&1 || true

cd "$DAEMON_DIR"

# Explicitly set LUA_PATH so daemon.lua's require("config")/require("ui")/
# etc. resolve to the sibling .lua files in this same directory, even if
# this particular luajit build's compiled-in default package.path doesn't
# include "./?.lua" for some reason. Costs nothing, removes a possible
# silent "module not found" failure mode.
export LUA_PATH="./?.lua;./?/init.lua;;"

# luajit's own #!/./luajit shebang in daemon.lua only works if it's
# invoked as ./daemon.lua from within this directory with luajit
# reachable at ./luajit -- we don't rely on that; we invoke luajit
# directly and pass daemon.lua as the script argument, which sidesteps
# needing a copy of/symlink to luajit inside this folder.
exec "$LUAJIT_BIN" "$DAEMON_DIR/daemon.lua" >>"$CRASH_LOG" 2>&1
