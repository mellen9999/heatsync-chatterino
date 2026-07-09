-- shared helpers: logging, encoding, json, http, timers
local M = {}

M.ORIGIN = "https://heatsync.org"

local json = require("chatterino.json")

function M.log_info(msg)
    c2.log(c2.LogLevel.Info, "[heatsync] " .. msg)
end

function M.log_warn(msg)
    c2.log(c2.LogLevel.Warning, "[heatsync] " .. msg)
end

-- Minimal percent-encoding for URL path/query segments. Charset validators
-- upstream are the first gate; this is defense-in-depth so a stray character
-- can never corrupt the request URL or get misread server-side.
function M.percent_encode(s)
    return (string.gsub(tostring(s), "[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Monotonic clock. Chatterino's Lua sandbox exposes NO `os` library
-- (only _G/io/math/string/table/utf8 per wip-plugins.md), so os.time() is
-- unavailable — indexing it throws and aborts plugin load. Every time value
-- in this plugin is a *difference* (ttls, backoff, throttles, idle windows),
-- so a 0-based seconds counter driven by c2.later is an exact drop-in for
-- os.time(). Starts at load; if c2.later is somehow absent it stays 0, which
-- degrades (caches never expire) but never crashes.
local mono_s = 0

function M.now()
    return mono_s
end

-- second half of M.every is defined below; the clock tick is armed at the
-- bottom of this file once every() exists.

function M.safe_json_parse(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, parsed = pcall(json.parse, raw)
    if not ok then return nil end
    return parsed
end

function M.json_stringify(t)
    local ok, s = pcall(json.stringify, t)
    if not ok then return nil end
    return s
end

-- Accept multiple possible field names for forward-compat with any small
-- API renames. The first non-empty string wins.
function M.pick_first_str(obj, ...)
    for i = 1, select("#", ...) do
        local v = obj[select(i, ...)]
        if type(v) == "string" and v ~= "" then return v end
    end
    return nil
end

function M.pick_first_num(obj, ...)
    for i = 1, select("#", ...) do
        local v = tonumber(obj[select(i, ...)])
        if v and v > 0 then return v end
    end
    return nil
end

-- parse one emote row from any heatsync/provider response shape into a
-- {name, url, w, h, zw} record, or nil if it lacks a usable name+url. the ONE
-- home for this shape — inventory, senders, and the /hsinv browser all built
-- near-identical copies of this dance before (accept custom_name/name/code,
-- url/src, width/height, zero_width).
-- an emote name becomes an InsertText link value spliced into the user's chat
-- input on click (picker/render), plus a tooltip — so a name from a hostile
-- server must never carry control bytes (newline → input injection) or a giant
-- payload. legit names are short and control-char-free.
function M.is_safe_name(s)
    if type(s) ~= "string" or s == "" then return false end
    if string.find(s, "%c") then return false end -- no control bytes (newline etc.)
    -- length in CHARACTERS, not bytes, so a legit multibyte name (CJK/emoji/
    -- accented) isn't rejected at ~33 chars; fall back to bytes on invalid utf8.
    local len = (utf8 and utf8.len and utf8.len(s)) or #s
    return len <= 100
end

function M.parse_emote_row(e)
    if type(e) ~= "table" then return nil end
    local name = M.pick_first_str(e, "custom_name", "name", "code")
    local url = M.pick_first_str(e, "url", "src")
    if not name or not url or not M.is_safe_name(name) then return nil end
    return {
        name = name,
        url = url,
        w = M.pick_first_num(e, "width"),
        h = M.pick_first_num(e, "height"),
        zw = e.zero_width == true,
    }
end

-- One-shot GET expecting JSON. cb(data) on success, cb(nil, err) on any
-- failure. Never throws; the callback always fires exactly once.
function M.get_json(url, timeout_ms, cb)
    local ok, err = pcall(function()
        local req = c2.HTTPRequest.create(c2.HTTPMethod.Get, url)
        req:set_timeout(timeout_ms or 10000)
        req:set_header("Accept", "application/json")
        -- the callback runs LATER (async), outside the setup pcall below, so it
        -- must be guarded here or a bug in any handler — indexing a wrong-shaped
        -- field, a bad element table — escapes into chatterino's native dispatch.
        -- this is the single choke that makes every get_json consumer crash-safe.
        local function safe_cb(a, b)
            local ok, err = pcall(cb, a, b)
            if not ok then M.log_warn("get_json callback failed: " .. tostring(err)) end
        end
        req:on_error(function(res)
            local e = "http error"
            pcall(function() e = tostring(res:error()) end)
            safe_cb(nil, e)
        end)
        req:on_success(function(res)
            local data = M.safe_json_parse(res:data())
            if data == nil then
                safe_cb(nil, "unparseable response")
            else
                safe_cb(data)
            end
        end)
        req:execute()
    end)
    if not ok then
        cb(nil, tostring(err))
    end
end

-- Self-rearming timer on c2.later (one-shot by design). A task error is
-- logged and the loop survives. Caller must gate on caps.later. Returns a
-- cancel function.
function M.every(msec, fn)
    local cancelled = false
    local function tick()
        if cancelled then return end
        local ok, err = pcall(fn)
        if not ok then
            M.log_warn("timer task failed: " .. tostring(err))
        end
        local ok2 = pcall(c2.later, tick, msec)
        if not ok2 then cancelled = true end
    end
    local ok = pcall(c2.later, tick, msec)
    if not ok then return function() end end
    return function() cancelled = true end
end

-- ----- persistence (plugin data dir) -----
-- chatterino sandboxes io.open() to Plugins/heatsync/data/ automatically, so
-- a bare filename is all that's needed (needs FilesystemRead/Write perms in
-- info.json). every call pcall-guarded — a missing file or denied permission
-- degrades to nil/false, never throws.
function M.read_data(filename)
    local ok, content = pcall(function()
        local f = io.open(filename, "r")
        if not f then return nil end
        local data = f:read("a")
        f:close()
        return data
    end)
    if not ok then return nil end
    return content
end

function M.write_data(filename, content)
    local ok = pcall(function()
        local f = io.open(filename, "w")
        if not f then return end
        f:write(content or "")
        f:close()
    end)
    return ok
end

-- arm the monotonic clock now that every() exists. one tick per second.
M.every(1000, function() mono_s = mono_s + 1 end)

return M
