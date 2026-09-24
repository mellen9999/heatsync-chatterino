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

-- an emote/badge dimension. reject non-finite (a raw JSON `1e400` parses to
-- math.huge, which would sail past a bare `> 0` and mis-scale downstream) and
-- anything past a sane pixel ceiling — no real emote is 65k px.
function M.pick_first_num(obj, ...)
    for i = 1, select("#", ...) do
        local v = tonumber(obj[select(i, ...)])
        if v and v > 0 and v <= 65535 then return v end
    end
    return nil
end

-- a CDN url is short. reject a giant string outright: `url` never passes through
-- is_safe_name, and a multi-MB value repeated across the row/entry count caps is
-- a heap-exhaustion vector from a hostile server / ws frame.
local MAX_URL_LEN = 2048
function M.is_safe_url(s)
    return type(s) == "string" and s ~= "" and #s <= MAX_URL_LEN
        and not string.find(s, "%c")
end

-- clamp an untrusted display string (tooltip, stream title/game) that may hold
-- spaces — unlike is_safe_name, which is for single-token link values. strips
-- control bytes (newline injection) and truncates to `max` chars. nil in → nil.
function M.safe_text(s, max)
    if type(s) ~= "string" or s == "" then return nil end
    s = (string.gsub(s, "%c", " ")) -- neutralize control bytes
    local len = (utf8 and utf8.len and utf8.len(s)) or #s
    if type(len) == "number" and len > max then
        local cut = (utf8 and utf8.offset and utf8.offset(s, max + 1)) or (max + 1)
        s = string.sub(s, 1, (cut or (max + 1)) - 1)
    end
    return s
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
    -- an emote name is always a single token. reject ANY whitespace and a leading
    -- command prefix: the picker/tab-complete insert the name VERBATIM into chat,
    -- so a hostile name like "/ban user reason" (control-char-free, <100) would
    -- otherwise become a real command one click + Enter away. legit names can't
    -- hold spaces anyway, so this rejects nothing real.
    if string.find(s, "%s") then return false end
    local first = string.byte(s, 1)
    if first == 47 or first == 46 then return false end -- "/" or "." command prefix
    -- length in CHARACTERS, not bytes, so a legit multibyte name (CJK/emoji/
    -- accented) isn't rejected at ~33 chars; fall back to bytes on invalid utf8.
    local len = (utf8 and utf8.len and utf8.len(s)) or #s
    return len <= 100
end

-- days since the unix epoch for a proleptic-Gregorian Y-M-D, via Howard
-- Hinnant's days_from_civil (http://howardhinnant.github.io/date_algorithms.html).
-- pure arithmetic — no calendar table, no os.date (the sandbox has neither).
local function days_from_civil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era
    if y >= 0 then era = y // 400 else era = (y - 399) // 400 end
    local yoe = y - era * 400              -- [0, 399]
    local mp = (m + 9) % 12                -- Mar=0 .. Feb=11
    local doy = (153 * mp + 2) // 5 + d - 1 -- [0, 365]
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy -- [0, 146096]
    return era * 146097 + doe - 719468
end

local function is_leap_year(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end
local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- ISO-ish timestamp → epoch milliseconds, pure Lua (no os.date/os.time — the
-- sandbox has neither). accepts 'YYYY-MM-DDTHH:MM:SS(.fff)?(Z|+HH:MM|-HH:MM)?'
-- and a space in place of 'T' (added_at/until arrive as JSON-serialized dates,
-- which JS renders with 'T'+'Z' and millisecond precision, but this also
-- tolerates the Postgres-style space form). a number is passed through as an
-- epoch already in ms or s (auto-detected by magnitude) if it's finite and
-- falls in a plausible calendar range; anything else, or an out-of-range
-- field, returns nil rather than guessing.
function M.iso_to_ms(s)
    if type(s) == "number" then
        if s ~= s or s == math.huge or s == -math.huge then return nil end
        if s >= 1e12 and s < 1e13 then return math.floor(s) end       -- ms epoch
        if s >= 1e9 and s < 1e10 then return math.floor(s * 1000) end -- s epoch
        return nil
    end
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, sec, frac, tz = string.match(s,
        "^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)(%.?%d*)(.*)$")
    if not y then return nil end
    y, mo, d, h, mi, sec = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(sec)
    if mo < 1 or mo > 12 or h > 23 or mi > 59 or sec > 60 then return nil end
    local maxd = DAYS_IN_MONTH[mo]
    if mo == 2 and is_leap_year(y) then maxd = 29 end
    if d < 1 or d > maxd then return nil end
    local ms = 0
    if frac ~= "" then
        ms = math.floor((tonumber("0" .. frac) or 0) * 1000 + 0.5)
    end
    local off_min = 0
    if tz ~= "" and tz ~= "Z" then
        local sign, oh, om = string.match(tz, "^([%+%-])(%d%d):?(%d%d)$")
        if not sign then return nil end -- unrecognized suffix → garbage, not a guess
        oh, om = tonumber(oh), tonumber(om)
        if oh > 23 or om > 59 then return nil end -- no real UTC offset reaches this
        off_min = oh * 60 + om
        if sign == "-" then off_min = -off_min end
    end
    local days = days_from_civil(y, mo, d)
    local total_s = days * 86400 + h * 3600 + mi * 60 + sec - off_min * 60
    return total_s * 1000 + ms
end

-- content-warning categories the server default-hides from a viewer who never
-- opted in (server/moderation/emote-category-filter.ts DEFAULT_HIDE) — an
-- nsfw-flagged or sexual/gore-tagged row is skipped rather than rendered. most
-- endpoints already omit `url` on a row like this (so it would fail the check
-- below anyway), but a viewer's OWN inventory is never filtered server-side
-- (by design — you keep what you chose), so this is the one place that
-- actually changes what renders: nsfw/cw_cats own-inventory rows are hidden
-- here as an inline image the same way the server itself treats them for
-- everyone else's view of you.
--
-- shared (not just parse_emote_row): the same nsfw/cw_cats fields ride on the
-- pushed emote:broadcast emoteData AND on the server-computed hsEmotes refs
-- attached to kick-chat-message/youtube:chat (server/services/emote-enrich.ts
-- HsEmoteRef) — the server explicitly leaves per-viewer gating of those to the
-- client, so every path that renders a not-our-own-inventory emote reuses this
-- one check rather than re-deriving it.
function M.is_cw_blocked(e)
    if type(e) ~= "table" then return false end
    if e.nsfw == true then return true end
    local cats = e.cw_cats
    if type(cats) == "table" then
        for _, c in ipairs(cats) do
            if c == "sexual" or c == "gore" then return true end
        end
    end
    return false
end

function M.parse_emote_row(e)
    if type(e) ~= "table" then return nil end
    if M.is_cw_blocked(e) then return nil end
    local name = M.pick_first_str(e, "custom_name", "name", "code")
    local url = M.pick_first_str(e, "url", "src")
    if not name or not url or not M.is_safe_name(name) or not M.is_safe_url(url) then return nil end
    return {
        name = name,
        url = url,
        w = M.pick_first_num(e, "width"),
        h = M.pick_first_num(e, "height"),
        zw = e.zero_width == true,
        -- render.lua's time gate: `a` (added_at) is a lower bound, `u` (until/
        -- last_seen) an upper bound on when a message may show this emote for
        -- its sender. live rows carry added_at only; historical (name-reuse)
        -- rows carry until only — see server/routes/emotes.ts batch endpoint.
        a = M.iso_to_ms(e.added_at),
        u = M.iso_to_ms(e["until"]), -- bracket form: `until` is a Lua keyword
    }
end

-- One-shot GET expecting JSON. cb(data, nil, status) on success, cb(nil, err,
-- status, body) on any failure — status/body let a caller branch on 429/503
-- without a second request shape; both are best-effort (pcall'd: an older
-- build's HTTPResponse may not expose status()) and simply nil when
-- unavailable, so every existing 2-arg callback keeps working untouched.
-- Never throws; the callback always fires exactly once.
function M.get_json(url, timeout_ms, cb)
    local ok, err = pcall(function()
        local req = c2.HTTPRequest.create(c2.HTTPMethod.Get, url)
        req:set_timeout(timeout_ms or 10000)
        req:set_header("Accept", "application/json")
        -- the callback runs LATER (async), outside the setup pcall below, so it
        -- must be guarded here or a bug in any handler — indexing a wrong-shaped
        -- field, a bad element table — escapes into chatterino's native dispatch.
        -- this is the single choke that makes every get_json consumer crash-safe.
        local function safe_cb(a, b, c, d)
            local ok, err = pcall(cb, a, b, c, d)
            if not ok then M.log_warn("get_json callback failed: " .. tostring(err)) end
        end
        req:on_error(function(res)
            local e = "http error"
            pcall(function() e = tostring(res:error()) end)
            local status = nil
            pcall(function() status = res:status() end)
            -- a non-ok status still ships a JSON error body (rate-limit/busy
            -- payloads carry retry hints) — best-effort parse, nil on garbage.
            local body = nil
            pcall(function() body = M.safe_json_parse(res:data()) end)
            safe_cb(nil, e, status, body)
        end)
        req:on_success(function(res)
            local data = M.safe_json_parse(res:data())
            if data == nil then
                safe_cb(nil, "unparseable response")
            else
                local status = nil
                pcall(function() status = res:status() end)
                safe_cb(data, nil, status)
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
