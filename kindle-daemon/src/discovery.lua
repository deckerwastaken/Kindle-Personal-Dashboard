--[[
discovery.lua -- listen for the backend's UDP beacons and report the
laptop's current address.

The backend broadcasts `KDASH1 <ip> <port>` every few seconds (see
backend/discovery.py). This module owns the socket and the parsing; the
decision about what to DO with a new address belongs to daemon.lua.

WHY: the daemon is told the laptop's address once, at startup. When the
router moved this laptop from .106 to .104 mid-session on 2026-08-12, the
Kindle kept talking to .106 with a half-open socket, silently discarding
every tap. Nothing on the device could recover, because nothing on the
device knew the new address. Now it does.

SECURITY, STATED PLAINLY: these beacons are unauthenticated. Anything on
your LAN can send one, and a malicious device could point this daemon at a
backend it controls -- which would then see your task list and could feed
you anything it liked. That is not a new trust model (the WebSocket itself
has no authentication and never has), but it is easier to abuse than
before, so this module refuses anything outside the private address
ranges, which at least keeps the target on your own network. If that
tradeoff isn't one you want, set `discovery_enabled = false` in
config.lua and the socket is never opened at all.
]]

local posix = require("posix")

local M = {}

M.MAGIC = "KDASH1"

--- True for addresses inside RFC 1918 private ranges (10/8, 172.16/12,
--- 192.168/16) plus link-local 169.254/16.
---
--- The point is not that a private address is trustworthy -- anything on
--- your LAN can claim one. It is that a beacon can never send the daemon
--- off to a host on the public internet, which is the difference between
--- "a device on my network can misbehave" and "anyone anywhere can be
--- named as my backend".
local function is_private_ipv4(a, b, c, d)
    if a == 10 then return true end
    if a == 172 and b >= 16 and b <= 31 then return true end
    if a == 192 and b == 168 then return true end
    if a == 169 and b == 254 then return true end
    return false
end

--- Parse one beacon payload. Returns ip, port on success, or nil plus a
--- short reason -- the reason is logged, because a beacon that arrives
--- and is rejected is a completely different problem from no beacon
--- arriving at all, and tools/discovery_probe.lua exists to tell those
--- apart from the other side.
function M.parse(payload)
    if type(payload) ~= "string" then return nil, "not a string" end

    -- Trailing whitespace/newlines tolerated; anything else must match
    -- exactly. Anchored at both ends so a longer message that merely
    -- starts with our magic is rejected rather than partly honoured.
    local ip, port = payload:match("^" .. M.MAGIC .. " (%d+%.%d+%.%d+%.%d+) (%d+)%s*$")
    if not ip then return nil, "unrecognised payload" end

    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then
        return nil, "octet out of range"
    end
    -- 0.x and 255.x are never a host we can connect to; catching them
    -- here keeps a malformed beacon from becoming a connect() error later.
    if a == 0 or a == 255 then return nil, "not a host address" end

    if not is_private_ipv4(a, b, c, d) then
        return nil, "not a private address (refusing " .. ip .. ")"
    end

    port = tonumber(port)
    if not port or port < 1 or port > 65535 then return nil, "bad port" end

    return ip, port
end

--- Open the listening socket. Returns a reader table with .fd (for the
--- caller's poll loop) and :read(), or nil plus an error string.
---
--- A failure here is deliberately NOT fatal to the daemon: discovery is a
--- convenience, and the dashboard has worked without it for months. The
--- caller logs and carries on.
function M.open(port, log)
    local fd, err = posix.udp_listen(port)
    if not fd then
        return nil, tostring(err)
    end
    if log then
        log.info("discovery: listening for backend beacons on UDP " .. tostring(port))
    end

    return setmetatable({ fd = fd }, {
        __index = {
            --- Read every datagram currently queued and return the last
            --- VALID address seen, or nil.
            ---
            --- Only the last matters: beacons repeat every few seconds, so
            --- a burst that has queued up while we were busy elsewhere all
            --- says the same thing, and if it doesn't, the newest is the
            --- one to believe. Returns the reason string for rejected
            --- payloads so the caller can log something useful.
            read = function(self)
                local ip, port_out, reject_reason
                -- Bounded rather than `while true`: a flood of datagrams
                -- must not be able to hold the main loop hostage and stall
                -- touch input. Anything left queued is read next pass.
                for _ = 1, 16 do
                    local data, rerr = posix.read_available(self.fd)
                    if data == nil then
                        return nil, nil, "read error: errno " .. tostring(rerr)
                    end
                    if data == "" then break end
                    local parsed_ip, parsed_port_or_reason = M.parse(data)
                    if parsed_ip then
                        ip, port_out = parsed_ip, parsed_port_or_reason
                    else
                        reject_reason = parsed_port_or_reason
                    end
                end
                return ip, port_out, (ip == nil) and reject_reason or nil
            end,

            close = function(self)
                posix.close(self.fd)
                self.fd = nil
            end,
        },
    })
end

return M
