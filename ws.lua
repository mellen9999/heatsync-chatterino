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
    on_event = nil, -- fn(data) for parsed server messages
}

local enabled = false
local sock = nil
local reconnect_scheduled = false
local joined = {}       -- "platform/channel" -> {platform, channel}
local watch_login = nil

local BACKOFF_CAP_S = 60
local HEARTBEAT_S = 25
local WATCHDOG_IDLE_S = 90

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
end

local function schedule_reconnect()
    if not enabled or reconnect_scheduled then return end
    reconnect_scheduled = true
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
    M.last_rx = os.time()
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
    if not enabled or M.connected then return end
    local ok, err = pcall(function()
        sock = c2.WebSocket.new(net.ORIGIN:gsub("^https", "wss") .. "/ws", {
            on_open = function()
                M.connected = true
                M.attempts = 0
                M.last_rx = os.time()
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
    if not M.connected then return end
    if os.time() - M.last_rx > WATCHDOG_IDLE_S then
        net.log_warn("ws stale (no rx for " .. tostring(WATCHDOG_IDLE_S) .. "s), recycling")
        local s = sock
        pcall(function() s:close() end)
        -- on_close drives the reconnect; belt-and-suspenders in case close
        -- never fires on a wedged socket:
        M.connected = false
        sock = nil
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
    -- seed jitter; os.time granularity is fine for spreading reconnects
    pcall(math.randomseed, os.time())
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
            tostring(os.time() - M.last_rx) .. "s ago"
    end
    return "reconnecting (attempt " .. tostring(M.attempts) .. ")"
end

return M
