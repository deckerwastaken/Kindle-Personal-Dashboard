--[[
sha1.lua -- pure-Lua SHA-1, used only for the WebSocket opening handshake
(RFC 6455 requires SHA-1("Sec-WebSocket-Key" .. magic GUID), then base64).

This is NOT used for anything security-sensitive (there's no auth on this
backend at all -- see backend/README.md, "Do not expose this port to the
public internet"). It exists purely so the client can compute the one
handshake value the server checks. Written from the public specification,
using LuaJIT's built-in `bit` library for the 32-bit ops.
]]

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol = bit.lshift, bit.rshift, bit.rol

local function sha1(msg)
    local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0

    local msg_len_bits = #msg * 8
    msg = msg .. "\128"
    while (#msg % 64) ~= 56 do
        msg = msg .. "\0"
    end
    -- append 64-bit big-endian length
    for i = 7, 0, -1 do
        local shift = i * 8
        local byte
        if shift >= 32 then
            byte = 0 -- message lengths here never exceed 32 bits' worth
        else
            byte = band(rshift(msg_len_bits, shift), 0xFF)
        end
        msg = msg .. string.char(byte)
    end

    local w = {}
    for chunk_start = 1, #msg, 64 do
        for t = 0, 15 do
            local o = chunk_start + t * 4
            local b1, b2, b3, b4 = msg:byte(o, o + 3)
            w[t] = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
        end
        for t = 16, 79 do
            w[t] = rol(bxor(w[t - 3], w[t - 8], w[t - 14], w[t - 16]), 1)
        end

        local a, b, c, d, e = h0, h1, h2, h3, h4
        for t = 0, 79 do
            local f, k
            if t <= 19 then
                f = bor(band(b, c), band(bnot(b), d))
                k = 0x5A827999
            elseif t <= 39 then
                f = bxor(b, c, d)
                k = 0x6ED9EBA1
            elseif t <= 59 then
                f = bor(band(b, c), band(b, d), band(c, d))
                k = 0x8F1BBCDC
            else
                f = bxor(b, c, d)
                k = 0xCA62C1D6
            end
            local temp = (rol(a, 5) + f + e + k + w[t])
            -- keep to 32 bits
            temp = band(temp, 0xFFFFFFFF)
            e, d, c, b, a = d, c, rol(b, 30), a, temp
        end

        h0 = band(h0 + a, 0xFFFFFFFF)
        h1 = band(h1 + b, 0xFFFFFFFF)
        h2 = band(h2 + c, 0xFFFFFFFF)
        h3 = band(h3 + d, 0xFFFFFFFF)
        h4 = band(h4 + e, 0xFFFFFFFF)
    end

    local function to_bytes(n)
        return string.char(band(rshift(n, 24), 0xFF), band(rshift(n, 16), 0xFF),
                            band(rshift(n, 8), 0xFF), band(n, 0xFF))
    end

    return to_bytes(h0) .. to_bytes(h1) .. to_bytes(h2) .. to_bytes(h3) .. to_bytes(h4)
end

-- returns the raw 20-byte digest (not hex) -- callers that need the
-- WebSocket handshake value feed this straight into base64 encoding.
return sha1
