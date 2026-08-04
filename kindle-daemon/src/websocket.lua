--[[
websocket.lua -- minimal RFC 6455 WebSocket client, text-frames only.

Built against backend/README.md's documented protocol: single-line JSON
text frames in both directions, no binary frames, no subprotocols, no
compression extension. That's a small enough subset of WebSocket that
hand-rolling it on top of posix.lua's raw TCP sockets is realistic and
keeps this daemon free of any dependency beyond the `luajit` binary
itself (no LuaSocket, no koreader internals -- see README.md).

Usage (see daemon.lua for the real integration into a poll() loop):

    local ws = require("websocket")
    local conn = ws.connect("192.168.1.42", 8000, "/ws")
    ...
    local res = posix.poll({ {fd = conn.fd, want_write = conn:wants_write()} }, 1000)
    local events = conn:step(res[conn.fd])
    for _, ev in ipairs(events) do
        if ev.type == "text" then ... end
        if ev.type == "closed" then ... end
    end
    conn:send_text(json.encode{action="toggle_task", id=3})

UNVERIFIED ON HARDWARE: none of this depends on Kindle-specific behavior
(it's plain TCP + a standard protocol), so this is the lowest-risk part
of the whole daemon. What *is* worth double-checking on first run is that
outbound TCP to your laptop's LAN IP:8000 isn't blocked by anything (it
shouldn't be, on a home WiFi network with no client isolation).
]]

local bit = require("bit")
local posix = require("posix")
local sha1 = require("sha1")
local base64 = require("base64")

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local M = {}
local Conn = {}
Conn.__index = Conn

local function random_bytes(n)
    local out = {}
    for i = 1, n do
        out[i] = string.char(math.random(0, 255))
    end
    return table.concat(out)
end

function M.connect(host, port, path)
    math.randomseed(os.time() + (os.clock() * 1000000))
    local fd, err = posix.tcp_connect_nonblock(host, port)
    if not fd then
        return nil, err
    end

    local key = base64.encode(random_bytes(16))
    local expected_accept = base64.encode(sha1(key .. WS_GUID))

    local self = setmetatable({
        fd = fd,
        host = host,
        port = port,
        path = path,
        state = "connecting", -- connecting -> handshake_sent -> open -> closed
        key = key,
        expected_accept = expected_accept,
        read_buf = "",
        write_buf = "",
        frag_opcode = nil,
        frag_payload = nil,
    }, Conn)
    return self
end

--- Whether the caller's poll() should also watch this fd for
--- writability (true while connecting or while we have buffered bytes
--- still waiting to go out).
function Conn:wants_write()
    return self.state == "connecting" or #self.write_buf > 0
end

local function build_request(host, port, path, key)
    return table.concat({
        "GET " .. path .. " HTTP/1.1\r\n",
        "Host: " .. host .. ":" .. port .. "\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: " .. key .. "\r\n",
        "Sec-WebSocket-Version: 13\r\n",
        "\r\n",
    })
end

local function try_flush_write(self)
    if #self.write_buf == 0 then return true end
    local n, err = posix.send(self.fd, self.write_buf)
    if n == nil then
        return false, err
    end
    if n > 0 then
        self.write_buf = self.write_buf:sub(n + 1)
    end
    return true
end

-- ---- frame encode (client -> server; MUST be masked per RFC 6455) ----

local function encode_frame(opcode, payload)
    local parts = {}
    parts[#parts + 1] = string.char(0x80 + opcode) -- FIN=1, RSV=0, opcode

    local len = #payload
    local mask = random_bytes(4)

    if len <= 125 then
        parts[#parts + 1] = string.char(0x80 + len) -- MASK=1, len
    elseif len <= 65535 then
        parts[#parts + 1] = string.char(0x80 + 126)
        parts[#parts + 1] = string.char(math.floor(len / 256) % 256, len % 256)
    else
        -- our JSON payloads are never this big in this project, but
        -- handle it correctly anyway rather than truncating silently.
        parts[#parts + 1] = string.char(0x80 + 127)
        local hi = 0
        local lo = len
        parts[#parts + 1] = string.char(0, 0, 0, 0,
            math.floor(lo / 16777216) % 256,
            math.floor(lo / 65536) % 256,
            math.floor(lo / 256) % 256,
            lo % 256)
    end
    parts[#parts + 1] = mask

    local masked = {}
    for i = 1, len do
        local b = payload:byte(i)
        local m = mask:byte(((i - 1) % 4) + 1)
        masked[i] = string.char(bit.bxor(b, m))
    end
    parts[#parts + 1] = table.concat(masked)

    return table.concat(parts)
end

function Conn:send_text(str)
    if self.state ~= "open" then
        return false, "not connected"
    end
    self.write_buf = self.write_buf .. encode_frame(0x1, str)
    local ok, err = try_flush_write(self)
    return ok, err
end

function Conn:close()
    if self.fd then posix.close(self.fd) end
    self.state = "closed"
end

-- ---- frame decode (server -> client; server frames are NOT masked) ----

--- Try to pull one complete frame out of self.read_buf. Returns a table
--- {fin=bool, opcode=, payload=, consumed=bytes_consumed}, or nil if not
--- enough data has arrived yet to parse a full frame. NOTE: `fin=false`
--- is a perfectly valid *complete* parse result (a non-final fragment of
--- a multi-frame message) -- it must NOT be confused with "insufficient
--- data", which is why this returns nil (not a table with fin=false) in
--- the not-enough-bytes-yet case. An earlier version of this function
--- conflated the two by returning `fin` as a bare boolean, which would
--- have stalled message processing forever the first time a real
--- fragmented frame arrived -- worth calling out since it's exactly the
--- kind of latent bug that only shows up under conditions this project
--- couldn't exercise without the real backend and real hardware talking
--- to each other.
local function try_parse_frame(buf)
    if #buf < 2 then return nil end
    local b0, b1 = buf:byte(1, 2)
    local fin = bit.band(b0, 0x80) ~= 0
    local opcode = bit.band(b0, 0x0F)
    local masked = bit.band(b1, 0x80) ~= 0
    local len = bit.band(b1, 0x7F)
    local pos = 3

    if len == 126 then
        if #buf < pos + 1 then return nil end
        local b2, b3 = buf:byte(pos, pos + 1)
        len = b2 * 256 + b3
        pos = pos + 2
    elseif len == 127 then
        if #buf < pos + 7 then return nil end
        -- only the low 32 bits are used -- see encode_frame comment
        local bytes = { buf:byte(pos, pos + 7) }
        len = bytes[5] * 16777216 + bytes[6] * 65536 + bytes[7] * 256 + bytes[8]
        pos = pos + 8
    end

    local mask_key
    if masked then
        if #buf < pos + 3 then return nil end
        mask_key = buf:sub(pos, pos + 3)
        pos = pos + 4
    end

    if #buf < pos + len - 1 then return nil end
    local payload = buf:sub(pos, pos + len - 1)
    if masked then
        local out = {}
        for i = 1, #payload do
            out[i] = string.char(bit.bxor(payload:byte(i), mask_key:byte(((i - 1) % 4) + 1)))
        end
        payload = table.concat(out)
    end

    return { fin = fin, opcode = opcode, payload = payload, consumed = pos + len - 1 }
end

--- Advance the connection's state machine. `poll_result` is the entry
--- posix.poll() returned for this conn's fd (or nil if it wasn't
--- signalled this round -- still fine to call, e.g. to flush pending
--- writes). Returns an array of events: {type="text", data=...},
--- {type="closed", reason=...}, {type="error", detail=...}.
function Conn:step(poll_result)
    local events = {}

    if poll_result and poll_result.err and self.state ~= "closed" then
        self:close()
        events[#events + 1] = { type = "closed", reason = "socket error" }
        return events
    end

    if self.state == "connecting" then
        -- Non-blocking connect(): becoming writable means the TCP
        -- handshake finished (successfully or not -- a real check would
        -- use getsockopt(SO_ERROR); we keep this simple and just attempt
        -- the HTTP request, which will fail loudly enough on read() if
        -- the connection didn't actually come up).
        if poll_result and poll_result.writable then
            self.write_buf = build_request(self.host, self.port, self.path, self.key)
            local ok, err = try_flush_write(self)
            if not ok then
                self:close()
                events[#events + 1] = { type = "closed", reason = err or "connect failed" }
                return events
            end
            self.state = "handshake_sent"
        end
        return events
    end

    if #self.write_buf > 0 and poll_result and poll_result.writable then
        try_flush_write(self)
    end

    if not (poll_result and poll_result.readable) then
        return events
    end

    local chunk, err = posix.read_available(self.fd)
    if chunk == nil then
        self:close()
        events[#events + 1] = { type = "closed", reason = "read error " .. tostring(err) }
        return events
    end
    if chunk == "" then
        return events -- nothing new this round
    end
    self.read_buf = self.read_buf .. chunk

    if self.state == "handshake_sent" then
        local header_end = self.read_buf:find("\r\n\r\n", 1, true)
        if not header_end then
            return events -- headers not fully arrived yet
        end
        local header_text = self.read_buf:sub(1, header_end + 1)
        self.read_buf = self.read_buf:sub(header_end + 4)

        local status = header_text:match("^HTTP/1%.1 (%d+)")
        local accept = header_text:match("[Ss]ec%-[Ww]eb[Ss]ocket%-[Aa]ccept:%s*([^\r\n]+)")

        if status ~= "101" or accept ~= self.expected_accept then
            self:close()
            events[#events + 1] = {
                type = "closed",
                reason = "handshake failed (status=" .. tostring(status) .. ")",
            }
            return events
        end
        self.state = "open"
        events[#events + 1] = { type = "open" }
        -- fall through in case the buffer also already contains frame data
    end

    if self.state ~= "open" then
        return events
    end

    while true do
        local frame = try_parse_frame(self.read_buf)
        if not frame then break end
        self.read_buf = self.read_buf:sub(frame.consumed + 1)
        local opcode, payload = frame.opcode, frame.payload

        if opcode == 0x1 or opcode == 0x0 then
            -- text frame, or a continuation of one
            if opcode == 0x1 then
                self.frag_opcode = 0x1
                self.frag_payload = payload
            else
                self.frag_payload = (self.frag_payload or "") .. payload
            end
            if frame.fin then
                events[#events + 1] = { type = "text", data = self.frag_payload }
                self.frag_payload = nil
            end
        elseif opcode == 0x8 then
            -- close
            self.write_buf = self.write_buf .. encode_frame(0x8, "")
            try_flush_write(self)
            self:close()
            events[#events + 1] = { type = "closed", reason = "server closed" }
            break
        elseif opcode == 0x9 then
            -- ping -> pong
            self.write_buf = self.write_buf .. encode_frame(0xA, payload)
            try_flush_write(self)
        end
        -- opcode 0xA (pong) needs no action
    end

    return events
end

return M
