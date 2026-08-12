--[[
posix.lua -- minimal LuaJIT FFI bindings onto glibc/musl for the two things
this daemon needs that plain Lua cannot do:

  1. Raw TCP sockets (so we can speak WebSocket to the laptop backend
     without depending on koreader's bundled LuaSocket being on the Lua
     package path when we run as a *standalone* script -- see kindle-daemon
     /README.md for why we deliberately don't touch koreader's internals).
  2. Reading raw `struct input_event` records from /dev/input/eventX (touch).

Both of these rely on POSIX/Linux kernel ABIs that have been stable for
decades on 32-bit ARM (which is what the Kindle 7 / KT2's CPU is), so this
is much lower-risk than trying to FFI-bind against libfbink.so's own
structs, which change shape between FBInk versions. We never link against
libfbink -- all drawing goes through the `fbink` CLI binary as a
subprocess (see ui.lua). This file is the *only* place that talks to the
kernel directly.

UNVERIFIED ON HARDWARE (see kindle-daemon/INSTALL.md step 3):
  - struct input_event's `struct timeval` is assumed to be two `long`
    fields (4 bytes each on 32-bit ARM => 16 bytes total per event). This
    is correct for every mainline 32-bit ARM kernel old enough to run on a
    2014 Kindle, but if a future firmware update changed this, event
    parsing would read garbage (not crash -- just wrong numbers). The
    `tools/evtest.lua` script exists specifically to let you sanity-check
    this by tapping the screen and eyeballing the printed values before
    the real daemon ever relies on them.
]]

local ffi = require("ffi")

ffi.cdef[[
typedef int ssize_t_compat; /* unused, kept for readability */

int open(const char *pathname, int flags);
int close(int fd);
long read(int fd, void *buf, unsigned long count);
long write(int fd, const void *buf, unsigned long count);
int fcntl(int fd, int cmd, ...);

/* --- sockets --- */
int socket(int domain, int type, int protocol);
int connect(int sockfd, const void *addr, unsigned int addrlen);
int bind(int sockfd, const void *addr, unsigned int addrlen);
int setsockopt(int sockfd, int level, int optname, const void *optval, unsigned int optlen);
long send(int sockfd, const void *buf, unsigned long len, int flags);
long recv(int sockfd, void *buf, unsigned long len, int flags);
unsigned short htons(unsigned short hostshort);
int inet_pton(int af, const char *src, void *dst);

struct sockaddr_in {
    short          sin_family;
    unsigned short sin_port;
    unsigned char  sin_addr[4]; /* in_addr_t, network byte order */
    char           sin_zero[8];
};

/* --- poll() --- */
struct pollfd {
    int   fd;
    short events;
    short revents;
};
int poll(struct pollfd *fds, unsigned long nfds, int timeout);

/* --- Linux input_event, 32-bit ARM layout ---
 * struct timeval { long tv_sec; long tv_usec; };  (4+4 bytes on 32-bit)
 * struct input_event {
 *     struct timeval time;
 *     unsigned short type;
 *     unsigned short code;
 *     int value;
 * };
 * => 16 bytes total. See the big warning above.
 */
struct input_event_32 {
    long tv_sec;
    long tv_usec;
    unsigned short type;
    unsigned short code;
    int value;
};
]]

local C = ffi.C
local M = {}

-- Flags / constants we need (values are fixed Linux ABI constants, not
-- guesses -- these do not change between kernel versions).
M.O_RDONLY   = 0x0000
M.O_NONBLOCK = 0x0800
M.F_GETFL    = 3
M.F_SETFL    = 4
M.AF_INET    = 2
M.SOCK_STREAM = 1
M.SOCK_DGRAM = 2
-- Linux-specific flag OR'd into socket()'s type argument, so the socket
-- is non-blocking from the moment it exists. Available since Linux
-- 2.6.27; this device runs 3.0.35. This is the ONLY reliable way to get
-- a non-blocking socket here -- see set_nonblocking's comment below.
M.SOCK_NONBLOCK = 0x800
M.SOL_SOCKET = 1  -- Linux value (differs on other Unixes; this daemon is
                   -- Linux-only by construction -- see this file's header)
M.SO_REUSEADDR = 2
M.POLLIN     = 0x0001
M.POLLERR    = 0x0008
M.POLLHUP    = 0x0010

local input_event_size = ffi.sizeof("struct input_event_32")
M.INPUT_EVENT_SIZE = input_event_size

-- bit ops via LuaJIT's built-in `bit` library (always available, no
-- external dependency)
local bit = require("bit")

function M.open_ro_nonblock(path)
    local fd = C.open(path, bit.bor(M.O_RDONLY, M.O_NONBLOCK))
    if fd < 0 then
        return nil, ffi.errno()
    end
    return fd
end

--- CONFIRMED BROKEN ON HARDWARE (2026-08-12) -- kept only because
--- M.ensure_nonblocking below still tries it as a fallback, and it may
--- work on other platforms. Do NOT trust its return value alone.
---
--- `fcntl(fd, F_SETFL, flags)` passes its third argument VARIADICALLY,
--- and that marshalling does not work through this FFI binding on this
--- device: the call reports success and the flag is not set. F_GETFL is
--- unaffected, because it ignores the third argument entirely -- which is
--- what makes the verification in ensure_nonblocking reliable.
---
--- The symptom was ugly and took a while to pin down: sockets stayed
--- BLOCKING, so a read on an empty socket waited for data instead of
--- returning EAGAIN, and a connect() to an unreachable host blocked the
--- entire main loop -- touch included -- until the kernel gave up.
function M.set_nonblocking(fd)
    local flags = C.fcntl(fd, M.F_GETFL, 0)
    if flags < 0 then return false, ffi.errno() end
    local rc = C.fcntl(fd, M.F_SETFL, bit.bor(flags, M.O_NONBLOCK))
    if rc < 0 then return false, ffi.errno() end
    return true
end

--- Is O_NONBLOCK actually set on this fd? Read with F_GETFL, which takes
--- no third argument and is therefore not affected by the variadic
--- problem described above.
function M.is_nonblocking(fd)
    local flags = C.fcntl(fd, M.F_GETFL, 0)
    if flags < 0 then return nil end
    return bit.band(flags, M.O_NONBLOCK) ~= 0
end

--- Guarantee a socket is non-blocking, or say so.
---
--- Sockets are created with SOCK_NONBLOCK (Linux 2.6.27+; this device
--- runs 3.0.35) so the flag is set atomically at creation and no fcntl is
--- needed at all. This function VERIFIES that actually happened, falls
--- back to fcntl if it didn't, and verifies again -- because a socket
--- that is silently still blocking is the worst outcome here: it doesn't
--- fail, it hangs the daemon's whole event loop.
function M.ensure_nonblocking(fd)
    if M.is_nonblocking(fd) then return true end
    M.set_nonblocking(fd)
    if M.is_nonblocking(fd) then return true end
    return false, "could not put fd " .. tostring(fd) .. " into non-blocking mode"
end

function M.close(fd)
    if fd and fd >= 0 then C.close(fd) end
end

--- Read raw bytes from fd into a Lua string. Returns str (possibly ""),
--- or nil+errno on hard error. A read of 0 bytes (EOF/would-block) comes
--- back as "" so callers can treat "no data yet" and "nothing new" the
--- same way in a poll()-driven loop.
local read_buf_size = 4096
local read_buf = ffi.new("char[?]", read_buf_size)
function M.read_available(fd)
    local n = C.read(fd, read_buf, read_buf_size)
    if n < 0 then
        local errno = ffi.errno()
        if errno == 11 or errno == 35 then -- EAGAIN / EWOULDBLOCK
            return ""
        end
        return nil, errno
    end
    return ffi.string(read_buf, n)
end

--- Parse a buffer of raw bytes into zero or more decoded input_event
--- tables, plus leftover unparsed bytes (in case a read landed mid-event).
--- Returns events (array of {type=,code=,value=}), leftover (string).
function M.parse_input_events(buf)
    local events = {}
    local n = #buf
    local whole = n - (n % input_event_size)
    local ptr = ffi.cast("const char *", buf)
    local i = 0
    while i < whole do
        local ev = ffi.cast("struct input_event_32 *", ptr + i)
        events[#events + 1] = {
            type = tonumber(ev.type),
            code = tonumber(ev.code),
            value = tonumber(ev.value),
        }
        i = i + input_event_size
    end
    local leftover = buf:sub(whole + 1)
    return events, leftover
end

--- Create a non-blocking TCP socket connected (or connecting) to host:port.
--- host must be a literal IPv4 address (e.g. "192.168.1.42") -- there is
--- no DNS resolver here on purpose, keep it simple; config.lua asks for
--- the laptop's LAN IP directly.
function M.tcp_connect_nonblock(host, port)
    -- SOCK_NONBLOCK at creation, not fcntl afterwards. This function has
    -- claimed to be non-blocking since it was written, and on this device
    -- it never was (see set_nonblocking's comment): connect() to an
    -- unreachable address blocked the daemon's whole main loop -- touch,
    -- the power button, everything -- until the kernel timed out. Which
    -- is precisely when the dashboard most needs to stay responsive.
    local fd = C.socket(M.AF_INET, bit.bor(M.SOCK_STREAM, M.SOCK_NONBLOCK), 0)
    if fd < 0 then return nil, "socket() failed: errno " .. ffi.errno() end

    local ok, nberr = M.ensure_nonblocking(fd)
    if not ok then
        C.close(fd)
        return nil, nberr
    end

    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = M.AF_INET
    addr.sin_port = C.htons(port)
    local pton_rc = C.inet_pton(M.AF_INET, host, addr.sin_addr)
    if pton_rc ~= 1 then
        C.close(fd)
        return nil, "invalid IPv4 address: " .. tostring(host)
    end

    local rc = C.connect(fd, addr, ffi.sizeof(addr))
    if rc < 0 then
        local errno = ffi.errno()
        if errno ~= 115 and errno ~= 36 then -- EINPROGRESS / EALREADY
            C.close(fd)
            return nil, "connect() failed: errno " .. errno
        end
        -- EINPROGRESS is expected for a non-blocking connect; caller
        -- should poll() for POLLOUT to know when it's actually up. We
        -- keep this simple and instead poll for POLLIN/POLLOUT together
        -- in the daemon's main loop and just try a zero-byte send to
        -- confirm connectivity before treating the socket as "connected".
    end
    return fd
end

--- Open a non-blocking UDP socket bound to 0.0.0.0:port, for receiving
--- the backend's discovery beacons (see src/discovery.lua).
---
--- Bound to INADDR_ANY rather than to a specific address on purpose: a
--- broadcast datagram is delivered to the wildcard address, and the
--- Kindle's own IP changes with DHCP anyway, so binding to a particular
--- one would be both wrong and fragile.
---
--- SO_REUSEADDR is set so a daemon restart can rebind immediately rather
--- than tripping over the previous socket -- the same reason every
--- server sets it. It does NOT make two daemons able to share the port
--- (that would need SO_REUSEPORT), so a second instance still fails
--- loudly with EADDRINUSE, which is the behaviour we want.
---
--- Datagrams are read with plain read() via M.read_available: each read
--- returns exactly one datagram, and the sender's address is deliberately
--- not needed -- the beacon carries the address to use in its payload, so
--- there is no recvfrom() and no sockaddr parsing here.
function M.udp_listen(port)
    local fd = C.socket(M.AF_INET, bit.bor(M.SOCK_DGRAM, M.SOCK_NONBLOCK), 0)
    if fd < 0 then return nil, "socket() failed: errno " .. ffi.errno() end

    local one = ffi.new("int[1]", 1)
    -- Non-fatal if it fails: it only affects rebinding speed.
    C.setsockopt(fd, M.SOL_SOCKET, M.SO_REUSEADDR, one, ffi.sizeof("int"))

    -- Load-bearing, not defensive. A blocking socket here does not fail,
    -- it HANGS: the reader drains until EAGAIN, and without O_NONBLOCK
    -- that last read waits for a datagram that may be seconds away,
    -- stalling the daemon's entire loop. That is exactly what happened
    -- before this was verified rather than assumed.
    local ok, nberr = M.ensure_nonblocking(fd)
    if not ok then
        C.close(fd)
        return nil, nberr
    end

    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = M.AF_INET
    addr.sin_port = C.htons(port)
    -- sin_addr left zeroed = INADDR_ANY (ffi.new zero-fills)

    if C.bind(fd, addr, ffi.sizeof(addr)) < 0 then
        local errno = ffi.errno()
        C.close(fd)
        return nil, "bind() failed: errno " .. errno
    end
    return fd
end

function M.send(fd, data)
    if #data == 0 then return 0 end
    local n = C.send(fd, data, #data, 0)
    if n < 0 then
        local errno = ffi.errno()
        if errno == 11 or errno == 35 then return 0 end -- EAGAIN
        return nil, errno
    end
    return n
end

--- poll() a list of {fd=, want_write=bool} entries for timeout_ms.
--- Returns a table fd -> {readable=bool, writable=bool, err=bool}.
local pollfds_cache = {}
function M.poll(entries, timeout_ms)
    local nfds = #entries
    if not pollfds_cache[nfds] then
        pollfds_cache[nfds] = ffi.new("struct pollfd[?]", nfds)
    end
    local pfds = pollfds_cache[nfds]
    for i, e in ipairs(entries) do
        pfds[i - 1].fd = e.fd
        local ev = M.POLLIN
        if e.want_write then ev = bit.bor(ev, 0x0004) end -- POLLOUT
        pfds[i - 1].events = ev
        pfds[i - 1].revents = 0
    end
    local rc = C.poll(pfds, nfds, timeout_ms)
    local result = {}
    if rc <= 0 then return result end
    for i, e in ipairs(entries) do
        local rev = pfds[i - 1].revents
        if rev ~= 0 then
            result[e.fd] = {
                readable = bit.band(rev, M.POLLIN) ~= 0,
                writable = bit.band(rev, 0x0004) ~= 0,
                err = bit.band(rev, bit.bor(M.POLLERR, M.POLLHUP)) ~= 0,
            }
        end
    end
    return result
end

return M
