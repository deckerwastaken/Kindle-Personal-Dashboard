#!/bin/sh
# setup_autostart.sh -- Step 6 of kindle-daemon/INSTALL.md, bundled into
# one script so you only have to run one command instead of typing each
# step by hand. Read INSTALL.md's Step 6 section for the full context on
# why each part matters before running this.
#
# This script only CHECKS things and copies ONE new file into
# /etc/upstart/ -- it does not edit or touch any existing file, and does
# NOT reboot the device itself. That's a separate, deliberate action you
# take yourself after reviewing this script's output (see the
# instructions it prints at the end).

set -eu

echo "=== Step 6a: confirming the boot-UI job name assumption ==="
echo "kindle-dashboard.conf assumes 'start on started lab126_gui'."
echo "Checking that a lab126_gui job actually exists on this firmware:"
if grep -l "lab126_gui" /etc/upstart/*.conf >/dev/null 2>&1; then
    echo "OK: found job(s) referencing lab126_gui:"
    grep -l "lab126_gui" /etc/upstart/*.conf
else
    echo "WARNING: no /etc/upstart/*.conf file mentions lab126_gui on this"
    echo "device. The dashboard job would likely just never trigger (a"
    echo "silent no-op, not a boot failure) -- but STOP and ask for help"
    echo "before continuing if you see this warning, rather than proceeding blind."
    exit 1
fi
echo

echo "=== Step 6b: confirming run.sh is ready (sanity check) ==="
RUN_SCRIPT="/mnt/us/kindle-daemon/bin/run.sh"
if [ ! -x "$RUN_SCRIPT" ]; then
    echo "ERROR: $RUN_SCRIPT not found or not executable. Do not continue --"
    echo "this must already work when run by hand (INSTALL.md Step 5) before"
    echo "wiring it into boot."
    exit 1
fi
echo "OK: $RUN_SCRIPT exists and is executable."
echo

echo "=== Step 6c: copying the upstart job file into place ==="
SRC="/mnt/us/kindle-daemon/install/kindle-dashboard.conf"
DEST="/etc/upstart/kindle-dashboard.conf"
if [ ! -f "$SRC" ]; then
    echo "ERROR: $SRC not found. Was the whole kindle-daemon folder copied"
    echo "to the device correctly back in INSTALL.md Step 1?"
    exit 1
fi
cp "$SRC" "$DEST"
echo "Copied $SRC -> $DEST"
echo

echo "=== Step 6d: verifying the copy ==="
if [ -f "$DEST" ]; then
    echo "OK: $DEST exists. Contents:"
    cat "$DEST"
else
    echo "ERROR: copy appears to have failed -- $DEST does not exist."
    exit 1
fi
echo

cat <<'EOF'
=== Done. Next steps (do these yourself -- this script does NOT reboot) ===

1. Reboot the Kindle now (hold the power slider, or your usual restart
   method for this device).
2. Watch it boot. The dashboard should appear automatically once the
   native UI would normally have finished loading.
3. Once booted, reconnect over SSH (get the fresh IP from the router or
   KOReader's SSH screen -- it may have changed again) and check:
     tail -30 /mnt/us/kindle-daemon/daemon.log
     cat /mnt/us/kindle-daemon/crash.log
   crash.log should be empty or near-empty. daemon.log should show it
   connecting to the backend, same as your manual run.sh test.

If something goes wrong and you want to roll this back:
     rm /etc/upstart/kindle-dashboard.conf
   then reboot again. This removes ONLY the auto-start behavior -- nothing
   else on the device was touched by this script.
EOF
