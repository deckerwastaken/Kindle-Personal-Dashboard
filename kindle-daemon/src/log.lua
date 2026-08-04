--[[
log.lua -- tiny append-only file logger with a size cap, so a runaway
loop can't slowly fill up the Kindle's limited internal storage.

Deliberately simple: one file, truncated back to a small tail once it
crosses max_bytes. Good enough for "why did my daemon stop drawing"
debugging over SSH; not a real rotating-log system.
]]

local M = {}
local fh = nil
local path = nil
local max_bytes = 512 * 1024 -- 512KB cap

local function file_size(p)
    local f = io.open(p, "r")
    if not f then return 0 end
    local size = f:seek("end")
    f:close()
    return size or 0
end

--- Keep the last third, drop the rest, so the file doesn't grow forever
--- if the daemon runs for weeks unattended. Reopens fh in append mode
--- afterward so subsequent writes land after the truncated content.
local function truncate_and_reopen()
    local f = io.open(path, "r")
    if not f then return end
    local data = f:read("*a")
    f:close()
    local keep_from = #data - math.floor(max_bytes / 3)
    if keep_from > 1 then
        local trimmed = data:sub(keep_from)
        local wf = io.open(path, "w")
        if wf then
            wf:write("--- log truncated (was over ", max_bytes, " bytes) ---\n")
            wf:write(trimmed)
            wf:close()
        end
    end
    if fh then fh:close() end
    fh = io.open(path, "a")
end

function M.init(log_path, max_bytes_override)
    path = log_path
    if max_bytes_override then max_bytes = max_bytes_override end
    if file_size(path) > max_bytes then
        truncate_and_reopen() -- opens fh itself
    else
        fh = io.open(path, "a")
    end
    if not fh then
        io.stderr:write("log.lua: could not open ", path, " for writing -- logging to stdout only\n")
    end
end

local function timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function write_line(level, ...)
    local parts = { timestamp(), " [", level, "] " }
    local n = select("#", ...)
    for i = 1, n do
        parts[#parts + 1] = tostring((select(i, ...)))
        if i < n then parts[#parts + 1] = " " end
    end
    parts[#parts + 1] = "\n"
    local line = table.concat(parts)
    if fh then
        fh:write(line)
        fh:flush() -- flush every line: this daemon logs rarely enough
                    -- (state changes, taps, reconnects) that fflush cost
                    -- is irrelevant, and it means `tail -f` and
                    -- post-crash logs are never missing the last lines

        -- CONFIRMED bug, fixed 2026-08-02: the size cap was previously
        -- only checked once, in M.init() at process startup. daemon.lua
        -- is meant to run for weeks between crashes/restarts (per its own
        -- header comment) -- that's exactly the case where a
        -- startup-only check never re-fires, defeating this module's
        -- whole stated purpose ("a runaway loop can't slowly fill up the
        -- Kindle's limited storage"). fh:seek("cur") reads the current
        -- write position from the already-open handle -- cheap, no extra
        -- file open -- so this is safe to check on every line given how
        -- infrequently this daemon logs.
        local pos = fh:seek("cur")
        if pos and pos > max_bytes then
            truncate_and_reopen()
        end
    end
    io.write(line)
end

function M.info(...) write_line("INFO", ...) end
function M.warn(...) write_line("WARN", ...) end
function M.error(...) write_line("ERROR", ...) end

return M
