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

-- One-shot GET expecting JSON. cb(data) on success, cb(nil, err) on any
-- failure. Never throws; the callback always fires exactly once.
function M.get_json(url, timeout_ms, cb)
    local ok, err = pcall(function()
        local req = c2.HTTPRequest.create(c2.HTTPMethod.Get, url)
        req:set_timeout(timeout_ms or 10000)
        req:set_header("Accept", "application/json")
        req:on_error(function(res)
            local e = "http error"
            pcall(function() e = tostring(res:error()) end)
            cb(nil, e)
        end)
        req:on_success(function(res)
            local data = M.safe_json_parse(res:data())
            if data == nil then
                cb(nil, "unparseable response")
            else
                cb(data)
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

-- arm the monotonic clock now that every() exists. one tick per second.
M.every(1000, function() mono_s = mono_s + 1 end)

return M
