#!/bin/sh
#
# battery_probe.sh -- discover which battery interfaces this Kindle
# actually exposes.
#
# Run this over SSH ON THE KINDLE and paste the whole output back:
#
#     sh /mnt/us/kindle-dashboard/tools/battery_probe.sh
#
# WHY: src/battery.lua probes a ranked list of known battery paths at
# startup and caches whichever one works. That list is built from what
# this device's platform ("wario", i.MX6SL -- see battery.lua's header
# for why that word matters) is documented to expose, but which paths are
# really present on YOUR firmware build has not been confirmed on
# hardware. If the dashboard shows "--%" instead of a battery level, this
# script tells you why, and its output tells you exactly which path to
# add to SOURCES in src/battery.lua.
#
# Plain POSIX sh with no bash-isms, since this runs against the Kindle's
# busybox userland.

echo "=== DEVICE ==="
echo "usid: $(cat /proc/usid 2>/dev/null)"
cat /proc/version 2>/dev/null

echo
echo "=== power_supply class (the single most informative line here) ==="
ls /sys/class/power_supply/ 2>/dev/null || echo "(no power_supply class at all)"

echo
echo "=== CAPACITY CANDIDATES ==="
echo "(battery.lua tries these in this order; the first FOUND with a"
echo " plain 0-100 integer is the one it will use)"
for f in \
  /sys/devices/system/wario_battery/wario_battery0/battery_capacity \
  /sys/class/power_supply/max77696-battery/capacity \
  /sys/devices/system/yoshi_battery/yoshi_battery0/battery_capacity \
  /sys/class/power_supply/bd7181x_bat/capacity
do
  if [ -r "$f" ]; then
    printf 'FOUND  %s -> [%s]\n' "$f" "$(cat "$f" 2>&1)"
  else
    printf 'absent %s\n' "$f"
  fi
done

echo
echo "=== every capacity file the kernel exposes (battery.lua's"
echo "    last-resort auto-discovery looks here) ==="
for d in /sys/class/power_supply/*; do
  [ -d "$d" ] || continue
  if [ -r "$d/capacity" ]; then
    printf 'FOUND  %s/capacity -> [%s]\n' "$d" "$(cat "$d/capacity" 2>&1)"
  else
    printf 'no capacity attr: %s\n' "$d"
  fi
done

echo
echo "=== full dump of the wario battery dir (shows attributes that may"
echo "    not be in any list above) ==="
d=/sys/devices/system/wario_battery/wario_battery0
if [ -d "$d" ]; then
  for a in "$d"/*; do
    [ -f "$a" ] && printf '   %-26s = [%s]\n' "${a##*/}" "$(cat "$a" 2>&1)"
  done
else
  echo "   $d (absent)"
fi

echo
echo "=== shell-based fallbacks (slower: these fork a process per read,"
echo "    which is why battery.lua ranks them last) ==="
if command -v gasgauge-info >/dev/null 2>&1; then
  echo "gasgauge-info -c : [$(gasgauge-info -c 2>/dev/null)]"
  echo "gasgauge-info -c, including stderr:"
  gasgauge-info -c
else
  echo "gasgauge-info: not installed"
fi

echo
for p in battLevel isCharging; do
  v=$(lipc-get-prop com.lab126.powerd $p 2>&1); rc=$?
  printf 'lipc %-11s rc=%s [%s]\n' "$p" "$rc" "$v"
done

echo
echo "=== is powerd running? (the lipc fallback needs it; run.sh stops"
echo "    framework/kb/x but deliberately leaves powerd alone) ==="
ps | grep -i '[p]owerd' || echo "powerd NOT running"

echo
echo "=== done -- paste everything above this line ==="
