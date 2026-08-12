"""
Tests for the discovery beacon's wire format and address detection.

Run from the repo root:

    python backend/tests/test_discovery.py

Same plain-assert style as test_learnings.py -- no pytest needed.

WHAT'S WORTH TESTING HERE, AND WHY
----------------------------------
The beacon is parsed by a completely separate implementation, in Lua, on
the Kindle (kindle-daemon/src/discovery.lua, covered by
kindle-daemon/tests/test_discovery.lua). Nothing connects the two but the
format itself, and a mismatch produces no error on either side -- the
daemon simply ignores every beacon and the dashboard silently loses the
ability to recover from an IP change, which is precisely the failure this
feature was built to remove.

So these tests pin the exact bytes on the wire, and mirror the Lua
parser's accepting pattern here so a drift in either shows up as a
failure rather than as silence.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from backend import discovery  # noqa: E402

_failures = []
_passes = 0


def check(name, got, want):
    global _passes
    if got == want:
        _passes += 1
        print(f"  ok   {name}")
    else:
        _failures.append(name)
        print(f"  FAIL {name}\n         got:  {got!r}\n         want: {want!r}")


def check_true(name, cond, detail=""):
    global _passes
    if cond:
        _passes += 1
        print(f"  ok   {name}")
    else:
        _failures.append(name)
        print(f"  FAIL {name} {detail}")


print("=== the exact bytes on the wire ===")
check("a beacon is MAGIC, ip, port separated by single spaces",
      discovery.build_beacon("192.168.50.7", 8000),
      b"KDASH1 192.168.50.7 8000")
check("the magic string matches the daemon's copy", discovery.MAGIC, "KDASH1")
check_true("the payload is ASCII-only (the Lua side reads raw bytes)",
           discovery.build_beacon("10.0.0.1", 8000).decode("ascii").isprintable())
check_true("a beacon is small enough to never fragment",
           len(discovery.build_beacon("192.168.100.100", 65535)) < 64)

print("\n=== the Lua parser's pattern accepts what we send ===")
# Mirrored from kindle-daemon/src/discovery.lua's M.parse. If either side
# is edited without the other, this fails instead of the two silently
# ceasing to understand each other.
LUA_EQUIVALENT = re.compile(r"^KDASH1 (\d+\.\d+\.\d+\.\d+) (\d+)\s*$")

for ip, port in [
    ("192.168.50.7", 8000),
    ("10.0.0.5", 8000),
    ("172.16.3.9", 9999),
    ("192.168.1.1", 1),
]:
    payload = discovery.build_beacon(ip, port).decode("ascii")
    m = LUA_EQUIVALENT.match(payload)
    check_true(f"{payload!r} parses", m is not None)
    if m:
        check(f"  ...ip round-trips for {ip}", m.group(1), ip)
        check(f"  ...port round-trips for {port}", int(m.group(2)), port)

print("\n=== subnet broadcast derivation ===")
check("a /24 broadcast is derived from the first three octets",
      discovery._subnet_broadcast("192.168.50.7"), "192.168.50.255")
check("works for 10.x too", discovery._subnet_broadcast("10.1.2.3"), "10.1.2.255")
check("garbage in, None out (the global broadcast still goes out)",
      discovery._subnet_broadcast("not-an-ip"), None)

print("\n=== local address detection ===")
# Can't assert a specific address -- it depends on the machine running the
# tests -- but it must return something usable, because a None here means
# no beacon is ever sent and the feature is silently dead.
ip = discovery.detect_lan_ip()
check_true("detect_lan_ip returns an address", ip is not None, f"got {ip!r}")
if ip:
    check_true(f"...that looks like IPv4 ({ip})",
               re.match(r"^\d+\.\d+\.\d+\.\d+$", ip) is not None)
    check_true("...and is not loopback (which the daemon would refuse)",
               not ip.startswith("127."), f"got {ip!r}")

print("")
if _failures:
    print(f"{len(_failures)} CHECK(S) FAILED, {_passes} passed")
    for f in _failures:
        print(f"  - {f}")
    sys.exit(1)
print(f"ALL {_passes} CHECKS PASSED")
