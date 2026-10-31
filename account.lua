-- the opt-in heatsync login: one place that owns the token.
--
-- the websocket stays anonymous. the token is only ever sent as
-- `Authorization: Bearer` on https requests to https://heatsync.org/api/cli/*
-- (net.cli_request refuses any other url), is never logged or printed (net.redact
-- scrubs every log line and system message), and lives in account.txt in the
-- plugin's data folder — plain text, like any chat client's token. with no token
-- every other module behaves exactly as it did before this file existed.
--
-- lifecycle: pairing.lua gets a token (install), request() uses it, a token with
-- under 7 days left is swapped for a fresh one (rotate), a 401 or /hslogout wipes
-- it. no os.* in the sandbox, so "now" for expiry maths is net.wall_ms() — a clock
-- anchored on server timestamps (see net.lua); with no anchor yet it stays nil and
-- nothing is rotated early on a guess.
local net = require("net")
local caps = require("caps")
local u = require("cmdutil")

local M = {}

local FILE = "account.txt"
local TOKEN_MAX = 256
local DAY_MS = 86400 * 1000
local TTL_MS = 30 * DAY_MS              -- a token's lifetime, per the server contract
local ROTATE_WITHIN_MS = 7 * DAY_MS     -- renew when less than this is left
local ROTATE_CAP_MS = 90 * DAY_MS       -- the server stops renewing this long after the first login
local ROTATE_GAP_S = 12 * 60 + 30       -- the server allows one rotate per 12 min
local ROTATE_FAIL_GAP_S = 3600
local SEEN_SAVE_GAP_MS = 3600 * 1000

local st = nil          -- { token, expires_at, expires_ms, first_ms, scopes, name, user_id, seen_ms }
local listeners = { login = {}, logout = {} }
local rotating = false
local next_rotate_s = 0 -- net.now() before which no rotate is attempted
local cap_told = false  -- told the user about the 90-day cap / a refused renewal
local last_saved_seen = 0
M.pending_notice = nil

-- ----- persistence: plain "key=value" lines (no json: nothing to mis-parse) -----
local function clean(v) return (string.gsub(tostring(v or ""), "[%c]", "")) end

local function serialize(s)
    local lines = {
        "token=" .. s.token,
        "expires_at=" .. clean(s.expires_at),
        "first_ms=" .. (s.first_ms and string.format("%d", math.floor(s.first_ms)) or ""),
        "seen_ms=" .. (s.seen_ms and string.format("%d", math.floor(s.seen_ms)) or ""),
        "scopes=" .. table.concat(s.scopes, ","),
        "user_id=" .. clean(s.user_id),
        "name=" .. clean(s.name),
    }
    return table.concat(lines, "\n") .. "\n"
end

local function save()
    if not st then return end
    st.seen_ms = net.wall_ms() or st.seen_ms
    if st.seen_ms then last_saved_seen = st.seen_ms end
    local ok = net.write_data(FILE, serialize(st))
    if not ok then net.log_warn("could not save the login file") end
end

local function wipe_file()
    net.write_data(FILE, "")
end

local function parse_scopes(raw)
    local out = {}
    if type(raw) == "table" then
        for i = 1, math.min(#raw, 12) do
            local s = raw[i]
            if type(s) == "string" and string.match(s, "^[%l_]+$") and #s <= 24 then out[#out + 1] = s end
        end
    elseif type(raw) == "string" then
        for s in string.gmatch(raw, "[^,]+") do
            if string.match(s, "^[%l_]+$") and #s <= 24 and #out < 12 then out[#out + 1] = s end
        end
    end
    return out
end

local function valid_token(t)
    return type(t) == "string" and #t >= 12 and #t <= TOKEN_MAX and string.match(t, "^hscli_[%w%-_]+$") ~= nil
end

local function notify(text)
    if not u.notify(text) then M.pending_notice = text end
end

-- ----- state -----
function M.logged_in() return st ~= nil end
function M.name() return st and st.name or nil end
function M.user_id() return st and tonumber(st.user_id) or nil end
function M.scopes() return st and st.scopes or {} end

function M.has_scope(scope)
    if not st then return false end
    for _, s in ipairs(st.scopes) do if s == scope then return true end end
    return false
end

function M.on_login(fn) listeners.login[#listeners.login + 1] = fn end
function M.on_logout(fn) listeners.logout[#listeners.logout + 1] = fn end

local function fire(list)
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn)
        if not ok then net.log_warn("account listener failed: " .. tostring(err)) end
    end
end

function M.fire_login() fire(listeners.login) end

-- drop the session: memory, file, secrets; tell the user once
local function drop(reason)
    if not st then return end
    st = nil
    rotating = false
    cap_told = false
    next_rotate_s = 0 -- a new session starts with a clean renew throttle
    net.clear_secrets()
    wipe_file()
    fire(listeners.logout)
    if reason then notify(reason) end
end
M.drop = drop

-- a pending "you were logged out" line that had nowhere to go (no channel yet)
function M.take_notice()
    local n = M.pending_notice
    M.pending_notice = nil
    return n
end

-- ----- install a token (pairing approved / rotated) -----
-- returns true, or false + a reason. `keep_first` carries the first-login time
-- across a rotate (the 90-day cap counts from the first approval).
function M.install(token, expires_at, scopes, keep_first, name, user_id)
    if not valid_token(token) then return false, "bad token" end
    local exp_ms = net.iso_to_ms(expires_at)
    local sc = parse_scopes(scopes)
    if exp_ms then net.note_wall(exp_ms - TTL_MS) end -- a fresh token is TTL from now
    local first = keep_first or (exp_ms and (exp_ms - TTL_MS)) or net.wall_ms()
    local old = st
    st = {
        token = token,
        expires_at = type(expires_at) == "string" and clean(expires_at) or "",
        expires_ms = exp_ms,
        first_ms = first,
        scopes = sc,
        name = name or (old and old.name) or nil,
        user_id = user_id or (old and old.user_id) or nil,
    }
    net.add_secret(token)
    rotating = false
    cap_told = false
    save()
    return true
end

function M.set_identity(name, user_id)
    if not st then return end
    name = net.safe_text(name, 60)
    if name then st.name = name end
    if type(user_id) == "number" or type(user_id) == "string" then st.user_id = clean(user_id) end
    save()
end

function M.load()
    local raw = net.read_data(FILE)
    if type(raw) ~= "string" or raw == "" then return end
    local kv = {}
    for line in string.gmatch(raw, "[^\r\n]+") do
        local k, v = string.match(line, "^([%l_]+)=(.*)$")
        if k then kv[k] = v end
    end
    if not valid_token(kv.token) then
        net.log_warn("login file unreadable; ignoring it")
        return
    end
    local seen = tonumber(kv.seen_ms)
    if seen then net.note_wall(seen) end
    local exp_ms = net.iso_to_ms(kv.expires_at)
    st = {
        token = kv.token,
        expires_at = kv.expires_at or "",
        expires_ms = exp_ms,
        first_ms = tonumber(kv.first_ms),
        seen_ms = seen,
        scopes = parse_scopes(kv.scopes),
        user_id = (kv.user_id ~= "" and kv.user_id) or nil,
        name = net.safe_text(kv.name, 60),
    }
    net.add_secret(kv.token)
    last_saved_seen = seen or 0
    -- definitely expired (the clock only ever lags, so this is never a false alarm)
    local wall = net.wall_ms()
    if wall and exp_ms and exp_ms <= wall then
        drop("your heatsync login expired: /hslogin to log in again")
        return
    end
    fire(listeners.login)
end

-- ----- requests -----
-- turn a failed account call into one plain line. `over` maps an http status to
-- a command-specific line (404 "no such user", 409 "already following").
function M.explain(status, ebody, err, over)
    local code = type(ebody) == "table" and type(ebody.error_code) == "string" and ebody.error_code or nil
    if status == 401 then return "you're logged out: /hslogin to log in again" end
    if status == 403 and code == "scope_missing" then
        local sc = type(ebody.scope) == "string" and string.match(ebody.scope, "^[%l_]+$") or "account"
        return "this login can't do that yet: run /hslogin again and tick '" .. sc .. "'"
    end
    if over and status and over[status] then return over[status] end
    if status == 429 then return "heatsync says slow down: try again in a minute" end
    if status == 400 then
        local m = type(ebody) == "table" and net.safe_text(ebody.error, 120) or nil
        return m and ("heatsync said no: " .. string.lower(m)) or "heatsync said no to that"
    end
    if status and status >= 500 then return "heatsync hit a snag: try again in a bit" end
    if status == nil then
        if err == "unsupported method" then return "this chatterino build can't do that" end
        return "couldn't reach heatsync: check your connection and try again"
    end
    return "that didn't work (http " .. tostring(status) .. ")"
end

-- the single door for token requests. `path` is under /api/cli (e.g. "/mutes").
-- cb(data, err, status, ebody) fires exactly once. a 401 drops the session.
function M.request(verb, path, body, cb)
    local tok = st and st.token
    if not tok then return cb(nil, "not logged in", nil, nil) end
    net.cli_request(verb, net.ORIGIN .. "/api/cli" .. path, body, tok, function(data, err, status, ebody)
        if status == 401 and st and st.token == tok then
            drop("your heatsync login ran out or was revoked: /hslogin to log in again")
        end
        cb(data, err, status, ebody)
    end)
end

-- gate for the account-scoped commands. says why and returns false when it can't.
function M.require_scope(ctx, scope)
    local n = M.take_notice()
    if n then u.sysmsg(ctx, n) end
    if not caps.account then
        u.sysmsg(ctx, "this chatterino build can't log in to heatsync")
        return false
    end
    if not st then
        u.sysmsg(ctx, "log in first: /hslogin")
        return false
    end
    if scope and not M.has_scope(scope) then
        u.sysmsg(ctx, "this login can't do that yet: run /hslogin again and tick '" .. scope .. "'")
        return false
    end
    return true
end

-- ----- logout -----
-- tells the server to revoke the token, and wipes it here either way.
function M.logout(cb)
    local tok = st and st.token
    if not tok then return cb(false) end
    drop(nil)
    net.cli_request("Delete", net.ORIGIN .. "/api/cli/token", nil, tok, function(_, err, status)
        cb(true, err == nil, status)
    end)
end

-- ----- rotation -----
function M.remaining_ms()
    local wall = net.wall_ms()
    if not st or not st.expires_ms or not wall then return nil end
    return st.expires_ms - wall
end

function M.rotate_due()
    local rem = M.remaining_ms()
    return rem ~= nil and rem < ROTATE_WITHIN_MS
end

local function rotate()
    if rotating or not st then return end
    rotating = true
    next_rotate_s = net.now() + ROTATE_GAP_S
    local tok = st.token
    M.request("Post", "/rotate", {}, function(data, err, status, ebody)
        rotating = false
        if not st or st.token ~= tok then return end -- logged out / replaced meanwhile
        if type(data) == "table" and valid_token(data.token) then
            M.install(data.token, data.expires_at, data.scopes or st.scopes, st.first_ms)
            net.log_info("login renewed")
            return
        end
        if status == 429 then return end -- try again after the gap
        next_rotate_s = net.now() + ROTATE_FAIL_GAP_S
        if status and status >= 400 and status < 500 and status ~= 401 and not cap_told then
            cap_told = true
            notify("your heatsync login can't renew itself any more: /hslogin again soon")
        end
        net.log_warn("login renew failed (" .. tostring(status) .. ")")
    end)
end

-- on a slow timer (and at boot): renew a token that's close to the end, within
-- the server's rules — one rotate per 12 min, and none after 90 days from the
-- first login (then the user must /hslogin again, and is told once).
function M.tick()
    if not st or not caps.account then return end
    local wall = net.wall_ms()
    if wall and (not last_saved_seen or wall - last_saved_seen >= SEEN_SAVE_GAP_MS) then save() end
    if not M.rotate_due() then return end
    local past_cap = st.first_ms and wall and (wall >= st.first_ms + ROTATE_CAP_MS)
    if past_cap then
        if not cap_told then
            cap_told = true
            notify("your heatsync login is at its limit and can't renew: /hslogin to log in again")
        end
        return
    end
    if net.now() < next_rotate_s then return end
    rotate()
end

-- ----- status (never the token) -----
function M.status_line()
    if not caps.account then return "account: unavailable on this build" end
    if not st then return "account: logged out (/hslogin to log in)" end
    local day = string.match(st.expires_at or "", "^(%d%d%d%d%-%d%d%-%d%d)")
    return "account: logged in" .. (st.name and (" as " .. st.name) or "") ..
        " · " .. (#st.scopes > 0 and table.concat(st.scopes, " ") or "no scopes") ..
        (day and (" · renews itself, expires " .. day .. " if unused") or "")
end

return M
