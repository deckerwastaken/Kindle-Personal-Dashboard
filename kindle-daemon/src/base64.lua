--[[
base64.lua -- minimal base64 encoder (encoding only; we never need to
decode base64 in this project). Used for:
  - the Sec-WebSocket-Key request header (16 random bytes -> base64)
  - checking the server's Sec-WebSocket-Accept response
]]

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local M = {}

function M.encode(data)
    local out = {}
    local len = #data
    local i = 1
    while i <= len do
        local b1 = data:byte(i) or 0
        local b2 = data:byte(i + 1)
        local b3 = data:byte(i + 2)

        local n = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)

        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64

        out[#out + 1] = ALPHABET:sub(c1 + 1, c1 + 1)
        out[#out + 1] = ALPHABET:sub(c2 + 1, c2 + 1)
        out[#out + 1] = b2 and ALPHABET:sub(c3 + 1, c3 + 1) or "="
        out[#out + 1] = b3 and ALPHABET:sub(c4 + 1, c4 + 1) or "="

        i = i + 3
    end
    return table.concat(out)
end

return M
