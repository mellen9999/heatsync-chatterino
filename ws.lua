-- websocket client for wss://heatsync.org/ws — live inventory sync +
-- sender-emote broadcasts. anonymous (no auth token ever sent); the server
-- admits native no-Origin clients and channel:join is anonymous-allowed.
--
-- lifecycle: connect → on_open replays desired state (joins + watch) →
-- heartbeat every 25s (server answers pong; also feeds the server's 90s
-- idle timeout and cf's 100s idle kill) → watchdog closes a socket that has
-- received nothing for 90s → on_close schedules reconnect with jittered
-- exponential backoff, 1s..60s. on_close also fires for failed connects,
-- so the backoff path covers both.
local net = require("net")

local M = {
    connected = false,
    attempts = 0,
    last_rx = 0,
    on_event = nil,     -- fn(data) for parsed server messages
    on_reconnect = nil, -- fn() after desired-state replay (multichat re-subs)
}

local enabled = false
local sock = nil
local reconnect_scheduled = false
local connect_started = 0
local joined = {}       -- "platform/channel" -> {platform, channel}
local watch_login = nil

local BACKOFF_CAP_S = 60
local WATCHDOG_IDLE_S = 90
local HANDSHAKE_TIMEOUT_S = 30
local STABLE_S = 30 -- a session must stay open this long before its backoff resets

local function send(tbl)
    if not sock or not M.connected then return false end
    local s = net.json_stringify(tbl)
    if not s then return false end
    local ok = pcall(function() sock:send_text(s) end)
    return ok
end

local function replay_state()
    for _, j in pairs(joined) do
        send({ type = "channel:join", platform = j.platform, channel = j.channel })
    end
    if watch_login then
        send({ type = "emote:watch", login = watch_login })
    end
    -- multichat re-subscribes its YouTube pollers (kick rides channel:join above)
    if M.on_reconnect then pcall(M.on_reconnect) end
end

-- public raw send for multichat (youtube:subscribe etc). returns bool sent.
function M.send(tbl)
    return send(tbl)
end

local function schedule_reconnect()
    if not enabled or reconnect_scheduled then return end
    reconnect_scheduled = true
    -- reset the backoff ONLY after a session that stayed open past STABLE_S. a
    -- hostile/flapping peer that accepts then instantly drops leaves connected_at
    -- too recent, so attempts keeps climbing (up to the cap) instead of pinning us
    -- in a ~2s reconnect hot-loop.
    if M.connected_at and (net.now() - M.connected_at) >= STABLE_S then
        M.attempts = 0
    end
    M.connected_at = nil
    M.attempts = M.attempts + 1
    local base = math.min(BACKOFF_CAP_S, 2 ^ math.min(M.attempts, 6))
    local jitter = 0.8 + 0.4 * math.random()
    local delay_ms = math.floor(base * jitter * 1000)
    net.log_info("ws reconnect in " .. tostring(math.floor(delay_ms / 1000)) .. "s (attempt " .. tostring(M.attempts) .. ")")
    -- never reconnect synchronously inside on_close
    pcall(c2.later, function()
        reconnect_scheduled = false
        if enabled then M.connect() end
    end, delay_ms)
end

local function handle_text(data)
    M.last_rx = net.now()
    local msg = net.safe_json_parse(data)
    if type(msg) ~= "table" or type(msg.type) ~= "string" then return end
    if M.on_event then
        local ok, err = pcall(M.on_event, msg)
        if not ok then
            net.log_warn("ws event handler failed: " .. tostring(err))
        end
    end
end

function M.connect()
    if not enabled or M.connected or sock then return end
    connect_started = net.now()
    local ok, err = pcall(function()
        sock = c2.WebSocket.new(net.ORIGIN:gsub("^https", "wss") .. "/ws", {
            on_open = function()
                M.connected = true
                M.connected_at = net.now() -- backoff resets only if this survives STABLE_S
                M.last_rx = net.now()
                net.log_info("ws connected")
                replay_state()
            end,
            on_text = handle_text,
            on_close = function()
                local was = M.connected
                M.connected = false
                sock = nil
                if was then net.log_info("ws closed") end
                schedule_reconnect()
            end,
        })
    end)
    if not ok then
        net.log_warn("ws connect failed: " .. tostring(err))
        sock = nil
        M.connected = false
        schedule_reconnect()
    end
end

-- heartbeat + watchdog, driven by init's timer loops
function M.heartbeat()
    if not M.connected then return end
    send({ type = "presence:heartbeat" })
end

function M.watchdog()
    if not enabled then return end
    -- a socket wedged mid-handshake never fires on_close on some stacks, so
    -- the idle check alone would leave it stuck forever — recycle it too
    if not M.connected then
        if sock and (net.now() - connect_started) > HANDSHAKE_TIMEOUT_S then
            net.log_warn("ws handshake stalled, recycling")
            local s = sock
            sock = nil
            pcall(function() s:close() end)
            schedule_reconnect()
        elseif not sock and not reconnect_scheduled then
            -- dead state that should be unreachable; self-heal anyway
            schedule_reconnect()
        end
        return
    end
    if net.now() - M.last_rx > WATCHDOG_IDLE_S then
        net.log_warn("ws stale (no rx for " .. tostring(WATCHDOG_IDLE_S) .. "s), recycling")
        local s = sock
        -- clear BEFORE close: on_close sees sock==nil and just schedules
        M.connected = false
        sock = nil
        pcall(function() s:close() end)
        schedule_reconnect()
    end
end

function M.join(platform, channel)
    if type(channel) ~= "string" or channel == "" then return end
    local key = platform .. "/" .. string.lower(channel)
    if joined[key] then return end
    joined[key] = { platform = platform, channel = string.lower(channel) }
    send({ type = "channel:join", platform = platform, channel = string.lower(channel) })
end

-- the server has no channel:leave requirement for us (rooms are cleaned on
-- disconnect) but dropping it from desired state stops rejoin-on-reconnect.
function M.leave(platform, channel)
    if type(channel) ~= "string" then return end
    local key = platform .. "/" .. string.lower(channel)
    if not joined[key] then return end
    joined[key] = nil
    send({ type = "channel:leave", platform = platform, channel = string.lower(channel) })
end

-- live inventory deltas for our own login (server topic emote:watch; on
-- servers that predate it the message is ignored and the 15-min rest
-- reconciliation still applies).
function M.watch(login)
    if type(login) ~= "string" or login == "" then return end
    login = string.lower(login)
    if watch_login == login then return end
    watch_login = login
    send({ type = "emote:watch", login = login })
end

function M.start()
    if enabled then return end
    enabled = true
    -- jitter uses math.random unseeded (default seed) — spreading reconnects
    -- across a few hundred ms doesn't need a strong seed, and the sandbox has
    -- no os.time to seed from anyway
    M.connect()
end

function M.joined_count()
    local n = 0
    for _ in pairs(joined) do n = n + 1 end
    return n
end

function M.status()
    if not enabled then return "off" end
    if M.connected then
        return "connected · " .. tostring(M.joined_count()) .. " channels · rx " ..
            tostring(net.now() - M.last_rx) .. "s ago"
    end
    return "reconnecting (attempt " .. tostring(M.attempts) .. ")"
end

return M
