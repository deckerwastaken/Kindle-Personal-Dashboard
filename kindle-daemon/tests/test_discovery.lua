--[[
test_discovery.lua -- checks the parsing and validation of the backend's
discovery beacons.

Runs on your LAPTOP:

    cd kindle-daemon/tests
    luajit test_discovery.lua

WHY THIS MATTERS MORE THAN MOST PARSING
---------------------------------------
A beacon tells the daemon where to connect. Anything on the LAN can send
one, so this parser is the only thing standing between "a stray broadcast"
and "the dashboard connects somewhere else and shows that host's idea of
your task list". The rejection cases below are the feature, not edge-case
housekeeping -- particularly the private-address check, which is what
stops a beacon naming a host on the public internet.

discovery.lua requires posix.lua, which is LuaJIT FFI against libc and
loads fine on a laptop, but M.open() would try to bind a real socket. Only
M.parse is exercised here; the socket path is covered on the device by
tools/discovery_probe.lua.
]]

local this_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = this_dir .. "/../src/?.lua;" .. package.path

local discovery = require("discovery")

local failures = 0
local function pass(msg) print("  ok   " .. msg) end
local function fail(msg)
    failures = failures + 1
    print("  FAIL " .. msg)
end

local function accepts(payload, want_ip, want_port)
    local ip, port = discovery.parse(payload)
    if ip == want_ip and port == want_port then
        pass(string.format("%q -> %s:%d", payload, ip, port))
    else
        fail(string.format("%q -> got %s:%s, want %s:%d",
            payload, tostring(ip), tostring(port), want_ip, want_port))
    end
end

local function rejects(label, payload)
    local ip, reason = discovery.parse(payload)
    if ip == nil then
        pass(string.format("%s (%s)", label, tostring(reason)))
    else
        fail(string.format("%s -- ACCEPTED %q as %s", label, tostring(payload), ip))
    end
end

print("=== well-formed beacons ===")
accepts("KDASH1 192.168.50.7 8000", "192.168.50.7", 8000)
accepts("KDASH1 10.0.0.5 8000", "10.0.0.5", 8000)
accepts("KDASH1 172.16.3.9 9999", "172.16.3.9", 9999)
accepts("KDASH1 172.31.255.254 1", "172.31.255.254", 1)
-- A trailing newline is what you get if anyone ever sends this with a
-- shell tool rather than the backend, and rejecting that would be a
-- baffling failure to debug.
accepts("KDASH1 192.168.1.2 8000\n", "192.168.1.2", 8000)

print("\n=== addresses outside private ranges are refused ===")
rejects("public address", "KDASH1 8.8.8.8 8000")
rejects("public address that looks local-ish", "KDASH1 172.32.0.1 8000")
rejects("just below the 172.16/12 range", "KDASH1 172.15.255.255 8000")
rejects("192.169.x is NOT 192.168.x", "KDASH1 192.169.1.1 8000")
rejects("loopback is not a laptop", "KDASH1 127.0.0.1 8000")

print("\n=== malformed payloads ===")
rejects("empty string", "")
rejects("wrong magic", "KDASH2 192.168.1.2 8000")
rejects("no magic at all", "192.168.1.2 8000")
rejects("magic only", "KDASH1")
rejects("missing port", "KDASH1 192.168.1.2")
rejects("octet over 255", "KDASH1 192.168.1.999 8000")
rejects("octet over 255, first position", "KDASH1 300.1.1.1 8000")
rejects("three octets", "KDASH1 192.168.1 8000")
rejects("port zero", "KDASH1 192.168.1.2 0")
rejects("port over 65535", "KDASH1 192.168.1.2 70000")
rejects("non-numeric port", "KDASH1 192.168.1.2 eighty")
rejects("nil", nil)
rejects("a number", 42)

print("\n=== anchoring: a longer message must not be partly honoured ===")
-- Without the end anchor, a payload starting with a valid beacon would
-- have its prefix accepted and the rest silently ignored -- which is
-- exactly how injected trailing content gets overlooked.
rejects("trailing junk", "KDASH1 192.168.1.2 8000 EXTRA")
rejects("second beacon appended", "KDASH1 192.168.1.2 8000 KDASH1 8.8.8.8 80")
rejects("leading junk", "X KDASH1 192.168.1.2 8000")
rejects("embedded newline then junk", "KDASH1 192.168.1.2 8000\nrm -rf /")

print("\n=== the magic string is what the backend actually sends ===")
-- Both ends hardcode this independently; if either changes, they stop
-- seeing each other with no error anywhere. Pin it here so that shows up
-- as a failing test rather than as a dashboard that never reconnects.
if discovery.MAGIC == "KDASH1" then
    pass("MAGIC is KDASH1 (must match backend/discovery.py)")
else
    fail("MAGIC is " .. tostring(discovery.MAGIC) .. ", expected KDASH1")
end

print("")
if failures == 0 then
    print("ALL CHECKS PASSED")
else
    print(failures .. " CHECK(S) FAILED")
    os.exit(1)
end
