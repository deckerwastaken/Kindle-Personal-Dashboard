--[[
discovery_probe.lua -- listen for the backend's discovery beacons and
print whatever arrives.

Run this ON THE KINDLE, over SSH:

    /mnt/us/koreader/luajit /mnt/us/kindle-daemon/tools/discovery_probe.lua

It listens for 30 seconds by default (pass a different number of seconds
as the first argument) and prints every UDP datagram that reaches the
discovery port, whether or not it looks like one of ours.

WHY THIS EXISTS
---------------
Auto-discovery only works if a broadcast sent by the laptop actually
reaches this device. Two things can silently stop that, neither of them
visible from the laptop side:

  * the Kindle's own iptables INPUT chain (its policy is DROP, though on
    the reference device a blanket ACCEPT rule further down makes that
    moot -- run `iptables -L INPUT -n` to see what yours looks like), and
  * the access point itself, if it isolates clients or drops broadcast
    traffic to wireless stations.

If the daemon never picks up an IP change, run this first. Datagrams
appearing here but the daemon not reacting is a completely different
problem (a parsing or validation failure) from nothing appearing at all
(firewall or network), and this tool is what tells the two apart.

It deliberately uses the same posix.lua helper the daemon does, so a
failure here is a real failure of the same code path, not of a lookalike.
]]

local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = script_dir .. "/../src/?.lua;" .. package.path

local posix = require("posix")

local DEFAULT_PORT = 8001
local seconds = tonumber(arg and arg[1]) or 30

-- config.lua is optional here: this tool is meant to be runnable even on
-- a device whose config hasn't been set up yet.
local ok, config = pcall(require, "config")
local port = (ok and type(config) == "table" and config.discovery_port) or DEFAULT_PORT

io.stdout:setvbuf("line")

print(string.format("listening for UDP on port %d for %d seconds...", port, seconds))
print("(start or restart the backend on your laptop -- it beacons every few seconds)")
print("")

local fd, err = posix.udp_listen(port)
if not fd then
    print("FAILED to open the listening socket: " .. tostring(err))
    print("")
    print("errno 98 is EADDRINUSE -- the dashboard daemon is probably already")
    print("running and holding this port. Stop it first, or just read its log:")
    print("    grep discovery /mnt/us/kindle-daemon/daemon.log")
    os.exit(1)
end

local deadline = os.time() + seconds
local count = 0
while os.time() < deadline do
    local results = posix.poll({ { fd = fd } }, 1000)
    local r = results[fd]
    if r and r.readable then
        local data, rerr = posix.read_available(fd)
        if data == nil then
            print("read error: errno " .. tostring(rerr))
        elseif data ~= "" then
            count = count + 1
            print(string.format("[%d] %d bytes: %q", count, #data, data))
        end
    end
end

posix.close(fd)
print("")
if count == 0 then
    print("NOTHING RECEIVED in " .. seconds .. " seconds.")
    print("Check, in this order:")
    print("  1. is the backend running on the laptop?  (Check_Status.bat)")
    print("  2. is discovery enabled?  (DISCOVERY_ENABLED in backend/.env)")
    print("  3. are both devices on the SAME wifi network right now?")
    print("  4. iptables -L INPUT -n   on this device")
    print("  5. your access point may be dropping broadcast traffic")
else
    print("received " .. count .. " datagram(s) -- the network path works.")
end
