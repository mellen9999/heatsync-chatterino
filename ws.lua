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
    on_resync = nil,    -- fn() when a reconnect follows a >60s rx gap (senders.expire_all)
}

local enabled = false
local sock = nil
local reconnect_scheduled = false
local connect_started = 0
-- monotonic connect generation. every socket's callbacks capture the gen at
-- connect time; a superseded socket (watchdog-recycled, or whose async close
-- arrives after a new socket is already live) has a stale gen and its late
-- on_open/on_text/on_close all bail — so it can't clobber `sock`/`connected`
-- or double-process frames. bumped on connect AND whenever we abandon a socket.
local gen = 0
local joined = {}       -- "platform/channel" -> {platform, channel}
local watch_login = nil

local BACKOFF_CAP_S = 60
local WATCHDOG_IDLE_S = 90
local HANDSHAKE_TIMEOUT_S = 30
local STABLE_S = 30 -- a session must stay open this long before its backoff resets
local RESYNC_GAP_S = 60 -- rx gap past this on a fresh connect means missed pushes
local BATCH_MAX = 256 -- matches the server's own coalesce cap (ws-coalesce.ts COALESCE_MAX)
local SHUTDOWN_SPREAD_MIN_MS = 1000
local SHUTDOWN_SPREAD_MAX_MS = 60000

-- resume: highest `_seq` seen per `_ch`, kick/* rooms only (ws-connections.ts
-- stamps EVERY channel-routed frame with _seq/_ch, but only kick chat has a
-- server-side replay ring — see replayMissed/ack:channel in ws-handlers.ts).
-- bounded the same as `joined` effectively is (one entry per joined kick room);
-- capped defensively since `_ch`/`_seq` ride on an untrusted frame and a
-- hostile/MITM server could otherwise claim arbitrary "kick/*" rooms we never
-- joined to grow this map without limit.
local MAX_ACK_CHANNELS = 200
local last_seq_by_ch = {}
local tracked_ch_count = 0

local function track_seq(msg)
    local ch = msg._ch
    if type(ch) ~= "string" or string.sub(ch, 1, 5) ~= "kick/" then return end
    local seq = msg._seq
    if type(seq) ~= "number" or seq ~= seq or seq == math.huge or seq == -math.huge or seq < 0 then return end
    local prev = last_seq_by_ch[ch]
    if prev == nil then
        if tracked_ch_count >= MAX_ACK_CHANNELS then return end
        tracked_ch_count = tracked_ch_count + 1
        last_seq_by_ch[ch] = seq
    elseif seq > prev then
        last_seq_by_ch[ch] = seq
    end
end

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
    -- resume: ask the server to replay anything missed on a kick room while we
    -- were down (up to its ring's horizon). sent AFTER channel:join — the
    -- server's ack handler doesn't require join first (replayMissed just reads
    -- the ring by channel name), but joining first means a message that arrives
    -- between join and this ack still lands through the normal live path rather
    -- than only via replay. field names verified against handleAckChannels
    -- (server/services/ws-handlers.ts): `channel` (the exact `_ch` string) and
    -- camelCase `lastSeq`.
    if next(last_seq_by_ch) ~= nil then
        local acks, n = {}, 0
        for ch, seq in pairs(last_seq_by_ch) do
            n = n + 1
            if n > MAX_ACK_CHANNELS then break end
            acks[#acks + 1] = { channel = ch, lastSeq = seq }
        end
        send({ type = "ack:channels", channels = acks })
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

-- server:shutdown {reconnectSpreadMs, signal}: a deploy is draining connections
-- and asked everyone to spread their reconnects over a window, rather than
-- every client reconnecting the instant it's kicked (thundering herd on the
-- fresh instance). NOT a failure, so it must not cost a backoff attempt — this
-- abandons the socket the same way the watchdog recycles a stale one (bump gen
-- BEFORE close, so the old socket's on_close sees a stale gen and no-ops), then
-- reconnects after its own one-shot delay instead of calling schedule_reconnect.
local function handle_server_shutdown(msg)
    local spread = tonumber(msg.reconnectSpreadMs)
    if not spread or spread ~= spread or spread == math.huge or spread == -math.huge then
        spread = SHUTDOWN_SPREAD_MAX_MS
    end
    spread = math.max(SHUTDOWN_SPREAD_MIN_MS, math.min(SHUTDOWN_SPREAD_MAX_MS, spread))
    local delay_ms = math.floor(math.random() * spread)
    net.log_info("ws server:shutdown (" .. tostring(msg.signal or "?") ..
        "), reconnecting in " .. tostring(delay_ms) .. "ms (spread " .. tostring(spread) .. "ms)")
    local s = sock
    M.connected = false
    sock = nil
    gen = gen + 1
    if s then pcall(function() s:close() end) end
    -- suppress the watchdog's own self-heal reconnect while we wait out the
    -- spread delay — up to 60s, longer than the 30s watchdog tick, so without
    -- this it could fire its own (backoff-penalized) reconnect first.
    reconnect_scheduled = true
    pcall(c2.later, function()
        reconnect_scheduled = false
        if enabled then M.connect() end
    end, delay_ms)
end

local function handle_one(msg)
    if type(msg) ~= "table" or type(msg.type) ~= "string" then return end
    track_seq(msg)
    if msg.type == "server:shutdown" then
        local ok, err = pcall(handle_server_shutdown, msg)
        if not ok then net.log_warn("ws shutdown handler failed: " .. tostring(err)) end
        return
    end
    if M.on_event then
        local ok, err = pcall(M.on_event, msg)
        if not ok then
            net.log_warn("ws event handler failed: " .. tostring(err))
        end
    end
end

-- `/ws?b=1` opts into server-side coalescing: a socket under load may get one
-- {type:"batch", messages:[...]} frame instead of one frame per message
-- (ws-coalesce.ts). unwrap it here and dispatch each entry through the same
-- path a bare frame takes — capped, and a nested "batch" entry is passed
-- through as an ordinary (unhandled) message rather than unwrapped again; the
-- server never nests these, so this is a hostile-frame guard, not a real shape.
local function handle_text(data)
    M.last_rx = net.now()
    local msg = net.safe_json_parse(data)
    if type(msg) ~= "table" or type(msg.type) ~= "string" then return end
    if msg.type == "batch" then
        if type(msg.messages) == "table" then
            for i = 1, math.min(#msg.messages, BATCH_MAX) do
                local item = msg.messages[i]
                if type(item) == "table" then handle_one(item) end
            end
        end
        return
    end
    handle_one(msg)
end

function M.connect()
    if not enabled or M.connected or sock then return end
    connect_started = net.now()
    gen = gen + 1
    local my_id = gen
    local ok, err = pcall(function()
        -- ?b=1 opts into server-side coalescing (ws-coalesce.ts) — see handle_text.
        sock = c2.WebSocket.new(net.ORIGIN:gsub("^https", "wss") .. "/ws?b=1", {
            on_open = function()
                if my_id ~= gen then return end -- superseded socket: ignore late open
                M.connected = true
                M.connected_at = net.now() -- backoff resets only if this survives STABLE_S
                -- a rx gap this big (idle watchdog fired, laptop slept, etc) means
                -- invalidations could have been missed while we were down — resync
                -- before folding last_rx forward below erases the gap. last_rx == 0
                -- means never-received-anything (fresh boot), nothing to resync.
                local had_rx = M.last_rx > 0
                local gap = net.now() - M.last_rx
                M.last_rx = net.now()
                net.log_info("ws connected")
                if had_rx and gap > RESYNC_GAP_S and M.on_resync then
                    pcall(M.on_resync)
                end
                replay_state()
            end,
            on_text = function(data)
                if my_id ~= gen then return end -- superseded socket: don't process its frames
                handle_text(data)
            end,
            on_close = function()
                if my_id ~= gen then return end -- superseded socket: its close is stale
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
            gen = gen + 1 -- invalidate the abandoned socket's late callbacks
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
        -- clear BEFORE close + bump gen so the abandoned socket's late on_close
        -- can't clobber a socket the reconnect brings up in the meantime
        M.connected = false
        sock = nil
        gen = gen + 1
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
    -- key is already the exact "kick/<slug>" _ch shape (source_key uses the
    -- same "platform/lower(channel)" format) — drop it so a stale watermark
    -- for a room we're no longer in never rides a future ack:channels.
    if last_seq_by_ch[key] ~= nil then
        last_seq_by_ch[key] = nil
        tracked_ch_count = tracked_ch_count - 1
    end
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
