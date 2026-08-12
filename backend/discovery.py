"""
Discovery beacon: tells the Kindle where this laptop is.

WHY THIS EXISTS
---------------
The Kindle daemon learns this laptop's IP address exactly once, when the
dashboard is started (ops/start_dashboard.ps1 detects it and passes it in
as LAPTOP_IP). That is fine until the router hands this machine a
different address while the dashboard is running -- which happened on
2026-08-12, moving it from .106 to .104. The Kindle went on talking to
.106, its socket stayed half-open, and every tap the user made sat in a
send buffer addressed to nobody. Nothing on the device could recover from
that, because the daemon had no way of learning the new address.

So this broadcasts a tiny UDP datagram on the LAN every few seconds:

    KDASH1 <ip> <port>

The Kindle listens for it (src/discovery.lua) and, if the address differs
from the one it is using, reconnects to the new one. An address change now
heals itself within seconds instead of needing a manual restart.

WHY UDP BROADCAST, AND NOT SOMETHING SMARTER
--------------------------------------------
mDNS/Bonjour would be the "proper" answer, but it means a dependency and a
much larger protocol surface on a device where the Lua side is hand-rolled
FFI against libc. This is ~20 lines on each end and needs no libraries.

CONFIRMED ON HARDWARE (2026-08-12, this LAN, Kindle 7/KT2):
  * Unicast, 255.255.255.255, and subnet-directed broadcast ALL reach the
    device. We send the latter two -- some access points treat them
    differently, and a duplicate beacon costs nothing because the daemon
    ignores a beacon naming the address it already uses.
  * The Kindle's iptables INPUT policy is DROP, and the rule that looks
    like a blanket ACCEPT is scoped to `usb0`. An explicit ACCEPT for this
    port on wlan0 IS required, and kindle-daemon/bin/run.sh adds it at
    startup. Verified in both directions: with the rule every datagram
    arrives; without it the policy's drop counter rises by exactly the
    number sent and nothing is delivered.
"""

import asyncio
import logging
import socket

from . import config

logger = logging.getLogger("kindle_dashboard.discovery")

# Bumping this is how a future format change stays safe: the daemon
# matches on the literal prefix and ignores anything it doesn't recognise,
# so an old daemon and a new backend simply don't see each other rather
# than misparsing.
MAGIC = "KDASH1"


def build_beacon(ip: str, port: int) -> bytes:
    """The exact payload sent on the wire. Separated out so tests can
    assert the format the Lua side parses without opening a socket."""
    return f"{MAGIC} {ip} {port}".encode("ascii")


def detect_lan_ip() -> str | None:
    """This machine's LAN IP on the interface that holds the default route.

    Uses the standard UDP-connect trick: connecting a datagram socket sends
    no packets, it just asks the kernel to pick the source address it would
    use to reach that destination. That is exactly the address the Kindle
    needs, and it stays correct on a machine with several interfaces --
    this laptop has both wifi and ethernet on different subnets, and the
    wrong choice would advertise an address the Kindle cannot reach.

    Re-detected on every beacon rather than cached at startup, so a DHCP
    change is picked up automatically -- which is the entire point.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # 8.8.8.8 is a routing hint only; nothing is transmitted and it
        # works with no internet connection at all.
        s.connect(("8.8.8.8", 53))
        return s.getsockname()[0]
    except OSError as e:
        logger.warning("Could not determine this machine's LAN IP: %s", e)
        return None
    finally:
        s.close()


def _subnet_broadcast(ip: str) -> str | None:
    """Subnet-directed broadcast address, assuming the /24 that home
    networks essentially always use. Returns None if the address doesn't
    look like it has three dotted parts to reuse.

    A /24 guess is safe here BECAUSE it is only ever an addition: the
    global 255.255.255.255 broadcast is sent regardless, so a wrong guess
    costs one ignored packet, never delivery.
    """
    parts = ip.split(".")
    if len(parts) != 4:
        return None
    return ".".join(parts[:3] + ["255"])


async def beacon_loop(port: int = 8000) -> None:
    """Broadcast this machine's address every DISCOVERY_INTERVAL_SECONDS.

    `port` is the port the Kindle should connect BACK to (the backend's own
    HTTP/WebSocket port), not the port the beacon is sent on.
    """
    if not config.DISCOVERY_ENABLED:
        logger.info("Discovery beacon DISABLED (DISCOVERY_ENABLED=0)")
        return

    logger.info(
        "Discovery beacon starting: announcing port %d on UDP %d every %ds",
        port, config.DISCOVERY_PORT, config.DISCOVERY_INTERVAL_SECONDS,
    )

    last_logged_ip = None
    while True:
        try:
            ip = detect_lan_ip()
            if ip:
                payload = build_beacon(ip, port)
                targets = ["255.255.255.255"]
                subnet = _subnet_broadcast(ip)
                if subnet:
                    targets.append(subnet)

                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                try:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                    # Bind to the detected address so the broadcast leaves
                    # via that interface. Without this, a machine with more
                    # than one network can send it out of the wrong one and
                    # the Kindle never sees it.
                    sock.bind((ip, 0))
                    for target in targets:
                        try:
                            sock.sendto(payload, (target, config.DISCOVERY_PORT))
                        except OSError as e:
                            # One unreachable broadcast address must not
                            # stop the other from being tried.
                            logger.debug("Beacon to %s failed: %s", target, e)
                finally:
                    sock.close()

                # Logged only when it CHANGES: at one beacon every 5
                # seconds, logging each would bury everything else in the
                # file, but an address change is exactly the event worth
                # having a record of when something goes wrong later.
                if ip != last_logged_ip:
                    logger.info("Discovery beacon now announcing %s:%d", ip, port)
                    last_logged_ip = ip

        except asyncio.CancelledError:
            raise
        except Exception as e:
            # Never let a beacon failure take down the backend: it is a
            # convenience, and the dashboard works without it as long as
            # the address doesn't change.
            logger.error("Discovery beacon error: %s", e)

        await asyncio.sleep(config.DISCOVERY_INTERVAL_SECONDS)
