--[[
json.lua -- small, self-contained JSON encoder/decoder.

We hand-roll this instead of requiring koreader's bundled JSON module
because this daemon is deliberately standalone (see README.md's "why not
run inside KOReader" section) -- it should keep working even if a future
KOReader update rearranges its internal Lua package paths. It only needs
to handle what backend/README.md's protocol actually uses: objects,
arrays, strings, numbers, booleans, and null. It is not a general-purpose
JSON library and doesn't try to be.
]]

local M = {}

-- Sentinel for a JSON `null` that appears INSIDE AN ARRAY. Plain Lua `nil`
-- can't be stored at an array index (assigning arr[n] = nil is a no-op,
-- not a "hole"), so without this, decoding `[1, null, 3]` would silently
-- compact into a 2-element array {1, 3} instead of preserving the null's
-- position -- confirmed bug, fixed 2026-08-02. Object-level null (a null
-- *value* on a key) is unaffected by this and still decodes to the key
-- being absent, which is an accepted/documented Lua limitation, not a bug.
M.null = setmetatable({}, { __tostring = function() return "null" end })

-- ===================== encode =====================

local escape_map = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
    ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
}

local function encode_string(s)
    local out = s:gsub('[%c"\\]', function(c)
        return escape_map[c] or string.format('\\u%04x', c:byte())
    end)
    return '"' .. out .. '"'
end

local encode_value -- forward decl

local function is_array(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n == 0 then return true end -- treat empty table as [] (fine for our use)
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

function encode_value(v)
    if v == M.null then return "null" end
    local vt = type(v)
    if vt == "string" then
        return encode_string(v)
    elseif vt == "number" then
        if v ~= v then return "null" end -- NaN
        if math.floor(v) == v and math.abs(v) < 1e15 then
            return string.format("%d", v)
        end
        return string.format("%.14g", v)
    elseif vt == "boolean" then
        return v and "true" or "false"
    elseif vt == "nil" then
        return "null"
    elseif vt == "table" then
        if is_array(v) then
            local parts = {}
            for i = 1, #v do parts[i] = encode_value(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, val in pairs(v) do
                parts[#parts + 1] = encode_string(tostring(k)) .. ":" .. encode_value(val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        error("json.encode: cannot encode value of type " .. vt)
    end
end

function M.encode(v)
    return encode_value(v)
end

-- ===================== decode =====================

local function skip_ws(s, i)
    local _, e = s:find("^[ \t\n\r]*", i)
    return e + 1
end

local decode_value -- forward decl

local function decode_string(s, i)
    -- assumes s:sub(i,i) == '"'
    local j = i + 1
    local out = {}
    while true do
        local c = s:sub(j, j)
        if c == "" then error("json.decode: unterminated string") end
        if c == '"' then
            return table.concat(out), j + 1
        elseif c == "\\" then
            local nc = s:sub(j + 1, j + 1)
            if nc == "n" then out[#out + 1] = "\n"
            elseif nc == "t" then out[#out + 1] = "\t"
            elseif nc == "r" then out[#out + 1] = "\r"
            elseif nc == "b" then out[#out + 1] = "\b"
            elseif nc == "f" then out[#out + 1] = "\f"
            elseif nc == '"' then out[#out + 1] = '"'
            elseif nc == "\\" then out[#out + 1] = "\\"
            elseif nc == "/" then out[#out + 1] = "/"
            elseif nc == "u" then
                local hex = s:sub(j + 2, j + 5)
                local code = tonumber(hex, 16) or 63 -- '?' fallback
                if code < 128 then
                    out[#out + 1] = string.char(code)
                else
                    -- minimal UTF-8 encode for BMP codepoints; surrogate
                    -- pairs (emoji etc.) are not needed for task text /
                    -- usage numbers in this protocol, so we don't handle
                    -- them -- falls back to '?' rather than crashing.
                    if code < 0x800 then
                        out[#out + 1] = string.char(0xC0 + math.floor(code / 0x40),
                                                     0x80 + (code % 0x40))
                    else
                        out[#out + 1] = string.char(
                            0xE0 + math.floor(code / 0x1000),
                            0x80 + (math.floor(code / 0x40) % 0x40),
                            0x80 + (code % 0x40))
                    end
                end
                j = j + 4
            else
                out[#out + 1] = nc
            end
            j = j + 2
        else
            out[#out + 1] = c
            j = j + 1
        end
    end
end

local function decode_number(s, i)
    local _, e, num = s:find("^(%-?%d+%.?%d*[eE]?[%+%-]?%d*)", i)
    if not num then error("json.decode: bad number at " .. i) end
    -- CONFIRMED bug, fixed 2026-08-02: the pattern above allows a bare
    -- "e"/"E" with zero following digits (e.g. "5e"), which tonumber()
    -- rejects (returns nil). The old code only checked whether the REGEX
    -- matched, not whether the resulting NUMBER was valid -- a malformed
    -- exponent silently became a nil value, which (at the object level)
    -- silently deleted the key entirely rather than raising the error
    -- daemon.lua's pcall(json.decode, ...) is specifically there to catch
    -- and log.
    local n = tonumber(num)
    if not n then error("json.decode: malformed number '" .. num .. "' at " .. i) end
    return n, e + 1
end

function decode_value(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then
        return decode_string(s, i)
    elseif c == "{" then
        local obj = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            i = skip_ws(s, i)
            local key
            key, i = decode_string(s, i)
            i = skip_ws(s, i)
            if s:sub(i, i) ~= ":" then error("json.decode: expected ':' at " .. i) end
            local val
            val, i = decode_value(s, i + 1)
            obj[key] = val
            i = skip_ws(s, i)
            local nc = s:sub(i, i)
            if nc == "," then i = i + 1
            elseif nc == "}" then return obj, i + 1
            else error("json.decode: expected ',' or '}' at " .. i) end
        end
    elseif c == "[" then
        local arr = {}
        local n = 0
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local val
            val, i = decode_value(s, i)
            -- see M.null's comment: arr[n+1] = nil would silently drop
            -- this slot and shift everything after it left, rather than
            -- preserving the null's position.
            n = n + 1
            arr[n] = (val == nil) and M.null or val
            i = skip_ws(s, i)
            local nc = s:sub(i, i)
            if nc == "," then i = i + 1
            elseif nc == "]" then return arr, i + 1
            else error("json.decode: expected ',' or ']' at " .. i) end
        end
    elseif c == "t" and s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif c == "f" and s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif c == "n" and s:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        return decode_number(s, i)
    end
end

--- Decode a JSON text into a Lua value. Raises a Lua error on malformed
--- input -- callers (websocket message handler) should pcall() this.
function M.decode(s)
    local v = decode_value(s, 1)
    return v
end

return M
