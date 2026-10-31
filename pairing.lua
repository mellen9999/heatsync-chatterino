-- /hslogin: the device-code pairing flow, as a small state machine.
--
--   idle ──start──▶ waiting ──poll: pending──▶ waiting (same code, next poll)
--                      │  ├─ 429 slow_down ──▶ waiting (poll interval grows)
--                      │  ├─ 410 / local deadline ──▶ idle ("code expired")
--                      │  ├─ too many failed polls ──▶ idle ("gave up")
--                      │  └─ approved + token ──▶ idle, logged in (token used once)
--
-- nothing here touches the websocket. start/poll carry no token (there is none
-- yet); the approved response is the only time a token is received, and it goes
-- straight into account.install.
local net = require("net")
local caps = require("caps")
local account = require("account")
local u = require("cmdutil")

local M = {}

local DEFAULT_URI = "https://heatsync.org/cli"
local SLOW_STEP = 5
local INTERVAL_MAX = 30
local MAX_FAILS = 5

local cur = nil  -- the live attempt, or nil when idle
local gen = 0    -- bumped on every start/cancel; a stale poll callback checks it

local function clamp(v, lo, hi, dflt)
    v = tonumber(v)
    if not v or v ~= v then return dflt end
    return math.max(lo, math.min(hi, v))
end

-- only ever offer a heatsync.org link: a server-supplied uri is checked, not trusted
local function safe_uri(uri)
    if type(uri) == "string" and #uri <= 200 and not string.find(uri, "%c")
        and string.sub(uri, 1, 21) == "https://heatsync.org/" then
        return uri
    end
    return DEFAULT_URI
end

function M.pending() return cur ~= nil end
function M.cancel() gen = gen + 1; cur = nil end

local function show_code(ctx, a)
    u.sysmsg(ctx, "log in: open the link, sign in, enter the code " .. a.user_code ..
        " and tick 'account' (chat and mod are optional), then approve")
    u.linkmsg(ctx, "open " .. string.gsub(a.uri, "^https://", ""), a.uri)
end

local function finish_login(ctx, data)
    local ok = account.install(data.token, data.expires_at, data.scopes)
    if not ok then
        u.sysmsg(ctx, "heatsync sent something unexpected: try /hslogin again")
        return
    end
    -- who is this? (cosmetic: the login works either way)
    account.request("Get", "/me", nil, function(me)
        local user = type(me) == "table" and type(me.user) == "table" and me.user or nil
        if user then
            account.set_identity(user.display_name or user.username, user.id)
        end
        local who = account.name() or "your account"
        local sc = account.scopes()
        u.sysmsg(ctx, "logged in as " .. who .. " · " .. (#sc > 0 and table.concat(sc, " ") or "no scopes"))
        if not account.has_scope("account") then
            u.sysmsg(ctx, "no 'account' permission yet: /hslogin again and tick 'account' for notes, mutes, follows and pins")
        end
    end)
    account.fire_login()
end

local function poll(ctx, my)
    if my ~= gen or not cur then return end
    local a = cur
    if net.now() >= a.deadline then
        M.cancel()
        u.sysmsg(ctx, "login code expired: /hslogin for a new one")
        return
    end
    net.post_json(net.ORIGIN .. "/api/cli/pair/poll", { device_code = a.device_code }, 10000,
        function(data, err, status, ebody)
            if my ~= gen or not cur then return end
            local body = type(data) == "table" and data or ebody
            local code = type(body) == "table" and (body.error_code or body.error) or nil
            local st = type(body) == "table" and body.status or nil
            if status == 410 or st == "expired" then
                M.cancel()
                return u.sysmsg(ctx, "login code expired: /hslogin for a new one")
            end
            if st == "denied" then
                M.cancel()
                return u.sysmsg(ctx, "login was denied on the site: /hslogin to try again")
            end
            if status == 429 or code == "slow_down" then
                a.interval = math.min(INTERVAL_MAX, a.interval + SLOW_STEP)
                a.fails = 0
            elseif type(data) == "table" and st == "approved" then
                M.cancel() -- a token is handed out once: stop polling before using it
                return finish_login(ctx, data)
            elseif type(data) == "table" and st == "pending" then
                a.fails = 0
            else
                a.fails = a.fails + 1
                if a.fails >= MAX_FAILS then
                    M.cancel()
                    return u.sysmsg(ctx, "couldn't reach heatsync to finish logging in: /hslogin to try again")
                end
            end
            pcall(c2.later, function() poll(ctx, my) end, a.interval * 1000)
        end)
end

function M.start(ctx)
    if not caps.account then
        return u.sysmsg(ctx, "this chatterino build can't log in to heatsync")
    end
    if account.logged_in() then
        return u.sysmsg(ctx, "already logged in as " .. (account.name() or "your account") ..
            " · /hslogout first to switch")
    end
    if cur and net.now() < cur.deadline then
        show_code(ctx, cur)
        return
    end
    M.cancel()
    local my = gen
    net.post_json(net.ORIGIN .. "/api/cli/pair/start", { label = "chatterino" }, 10000,
        function(data, err, status)
            if my ~= gen then return end
            if type(data) ~= "table" or type(data.device_code) ~= "string" or data.device_code == ""
                or #data.device_code > 256 or string.find(data.device_code, "%c")
                or type(data.user_code) ~= "string" or not string.match(data.user_code, "^[%w%-]+$")
                or #data.user_code > 24 then
                if status == 429 then
                    return u.sysmsg(ctx, "heatsync says slow down: try /hslogin again in a minute")
                end
                return u.sysmsg(ctx, "couldn't start logging in: check your connection and try /hslogin again")
            end
            cur = {
                device_code = data.device_code,
                user_code = data.user_code,
                uri = safe_uri(data.verification_uri),
                interval = clamp(data.interval, 2, INTERVAL_MAX, 3),
                deadline = net.now() + clamp(data.expires_in, 30, 900, 300),
                fails = 0,
            }
            show_code(ctx, cur)
            u.sysmsg(ctx, "waiting for you to approve… (the code lasts " ..
                tostring(math.floor((cur.deadline - net.now()) / 60 + 0.5)) .. " min)")
            pcall(c2.later, function() poll(ctx, my) end, cur.interval * 1000)
        end)
end

return M
