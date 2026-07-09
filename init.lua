-- heatsync chatterino plugin — v0.9.0
--
-- what it does, by what your build supports (see caps.lua):
--   t2 (nightly)  inline rendering: your + other chatters' heatsync emotes
--                 as real images, >>id threadlinks clickable; plus all of t1
--   t1 (2.5.5+)   live inventory sync over websocket, tab-complete from
--                 your inventory + 7tv global, /hsmoments, /hslogs
--   t0 (older)    tab-complete only, refresh piggybacks on completions
--
-- no auth tokens ever leave chatterino: every endpoint used is public,
-- and the websocket connects anonymously.
local caps = require("caps")
local net = require("net")
local inventory = require("inventory")
local seventv = require("seventv")
local senders = require("senders")
local ws = require("ws")
local render = require("render")
local commands = require("commands")
local store = require("store")
local multichat = require("multichat")
local badges = require("badges")
local recents = require("recents")

-- tab-complete popup size (shared ceiling: own inventory fills first, then the
-- 7tv/bttv/ffz catalog appends into whatever room is left). raised 25→40 so a
-- heavy inventory surfaces more of YOUR own matching emotes before the cap
-- truncates them (the watchlist concern). it does NOT reserve catalog budget —
-- inventory-first is intended; catalog stays the secondary suggestion.
local COMPLETION_CAP = 40

-- ----- account access -----
-- every access in the chain pcall-guarded once here: the api can throw and
-- the selected account can go invalid mid-session (removed in settings).
local function current_login_safe()
    local ok_acc, acc = pcall(c2.current_account)
    if not ok_acc or not acc then return nil end
    local ok_valid, valid = pcall(function() return acc:is_valid() end)
    if not ok_valid or not valid then return nil end
    local ok_anon, anon = pcall(function() return acc:is_anon() end)
    if not ok_anon or anon then return nil end
    local ok_login, login = pcall(function() return acc:login() end)
    if not ok_login or type(login) ~= "string" or login == "" then return nil end
    return string.lower(login)
end

local last_login = nil

local function adopt_login(login)
    last_login = login
    senders.own_login = login
    inventory.refresh(login)
    if caps.tier >= 1 then ws.watch(login) end
end

-- ----- t0 fallback: completion-piggybacked refresh -----
-- pre-2.5.5 builds have neither timers nor a clock: without c2.later, net.now()
-- is frozen at 0 (see net.lua), so every elapsed-seconds throttle is dead. the
-- t0 path therefore COUNTS completion callbacks (the only thing that recurs
-- during normal use) and reconciles on a count cadence instead of wall-clock.
-- when the user never types nothing refreshes — no clock exists to drive it and
-- a busy-loop is not acceptable; /hsrefresh is the manual escape hatch.
local FULL_REFRESH_INTERVAL_S = 15 * 60
local BOOT_RETRY_BACKOFF_S = 10
local last_full_refresh_ts = 0

-- t1/t2 elapsed-seconds reconcile, armed by net.every (net.now() advances).
local function login_and_refresh_tick()
    -- one-shot boot retry after a transport failure before first load
    if inventory.boot_failed_at and not inventory.boot_retry_used
        and (net.now() - inventory.boot_failed_at) >= BOOT_RETRY_BACKOFF_S then
        inventory.boot_retry_used = true
        inventory.boot_failed_at = nil
        if last_login then
            net.log_info("retrying boot inventory fetch after backoff")
            inventory.refresh(last_login)
        end
    end

    local login = current_login_safe()
    if not login then return end
    if login ~= last_login then
        net.log_info("account switched to " .. login .. "; refreshing inventory")
        last_full_refresh_ts = net.now()
        adopt_login(login)
        return
    end
    if (net.now() - last_full_refresh_ts) >= FULL_REFRESH_INTERVAL_S then
        last_full_refresh_ts = net.now()
        inventory.refresh(login)
    end
end

-- t0 count-based reconcile: rides the completion callback since no clock ticks.
local COMPLETIONS_PER_CHECK = 20     -- account-switch cadence
local COMPLETIONS_PER_REFRESH = 400  -- periodic re-fetch (t0 has no ws deltas)
local piggyback_ticks = 0

local function piggyback_tick()
    piggyback_ticks = piggyback_ticks + 1
    -- recover a failed first load quickly, without waiting a full check cycle
    if inventory.boot_failed_at and not inventory.boot_retry_used
        and (piggyback_ticks % 3) == 0 then
        inventory.boot_retry_used = true
        inventory.boot_failed_at = nil
        if last_login then
            net.log_info("retrying boot inventory fetch after backoff")
            inventory.refresh(last_login)
        end
    end
    if (piggyback_ticks % COMPLETIONS_PER_CHECK) ~= 0 then return end
    local login = current_login_safe()
    if not login then return end
    if login ~= last_login then
        net.log_info("account switched to " .. login .. "; refreshing inventory")
        adopt_login(login)
        return
    end
    if piggyback_ticks >= COMPLETIONS_PER_REFRESH then
        piggyback_ticks = 0
        inventory.refresh(login)
    end
end

-- ----- completion hook -----
local function strip_leading_colon(query)
    if string.sub(query, 1, 1) == ":" then
        return string.sub(query, 2)
    end
    return query
end

local function build_completions(event)
    -- best-effort; must never take down completions
    if not caps.later then
        pcall(piggyback_tick)
    end

    local query = event.query or ""
    if query == "" then return {} end
    local raw = strip_leading_colon(query)
    local q = string.lower(raw)
    local qlen = string.len(q)
    if qlen < 1 then return {} end
    if qlen > seventv.MAX_CHARS then
        q = string.sub(q, 1, seventv.MAX_CHARS)
        qlen = seventv.MAX_CHARS
    end

    local values = {}
    local seen = {}
    -- seed `seen` with locally-blocked names so neither the inventory nor
    -- 7tv pass will surface them (both skip anything already in `seen`)
    for name in pairs(store.blocked_set()) do seen[name] = true end
    -- own inventory first (usage-weighted), then 7tv by popularity
    local ok1, err1 = pcall(inventory.match_prefix, q, qlen, values, seen, COMPLETION_CAP)
    if not ok1 then net.log_warn("inventory completion failed: " .. tostring(err1)) end
    local ok2, err2 = pcall(seventv.append_matches, q, values, seen, COMPLETION_CAP)
    if not ok2 then net.log_warn("7tv completion failed: " .. tostring(err2)) end
    return values
end

c2.register_callback(
    c2.EventType.CompletionRequested,
    function(event)
        -- whole body guarded so a bug here can never take down completions
        local ok, values = pcall(build_completions, event)
        if not ok then
            net.log_warn("completion handler failed: " .. tostring(values))
            values = {}
        end
        return { hide_others = false, values = values }
    end
)

-- ----- websocket event dispatch -----
local function on_ws_event(msg)
    -- multichat (kick/yt live chat injection) claims its own message types
    if multichat.dispatch(msg) then return end
    local t = msg.type
    if t == "emote:added" or t == "emote:removed" or t == "emotes:refresh" then
        -- own-inventory delta (emote:watch room): one debounced re-fetch
        -- covers add/remove/rename/undo/set-swap identically
        inventory.refresh_soon()
    elseif t == "emote:broadcast" then
        senders.feed_broadcast(msg.username, msg.emoteName, msg.emoteData)
    elseif t == "emotes:batch-broadcast" then
        if type(msg.data) == "table" then
            -- cap: the socket is anonymous, so bound how many sender entries one
            -- broadcast can push into the cache (a real batch is small)
            for i, b in ipairs(msg.data) do
                if i > 500 then break end
                if type(b) == "table" then
                    senders.feed_broadcast(b.username, b.emoteName, b.emoteData)
                end
            end
        end
    end
    -- everything else on joined rooms (heat updates, stream events, typing)
    -- is deliberately ignored
end

-- ----- boot -----
caps.detect()
net.log_info("boot: " .. caps.name() ..
    " (timers=" .. tostring(caps.later) ..
    " ws=" .. tostring(caps.websocket) ..
    " images=" .. tostring(caps.images) ..
    " windows=" .. tostring(caps.windows) .. ")")

commands.register(current_login_safe)
senders.own_map_fn = function() return inventory.map end
recents.load() -- restore recently-used emotes for the /hsemotes menu

if caps.tier >= 1 then
    ws.on_event = on_ws_event
    -- multichat needs only stable APIs (add_message + by_name), so it rides
    -- tier>=1 alongside ws. re-subscribe its sources whenever the ws (re)connects.
    multichat.load()
    ws.on_reconnect = multichat.on_ws_up
    ws.start()
end

-- auto-multichat: when a twitch channel is hooked, look up its heatsync
-- profile and link the streamer's kick/youtube chat if they're publicly known
-- (the profile endpoint only reveals cross-platform links for opted-in or
-- shadow streamers to anonymous callers).
local function try_auto_multichat(channel)
    if not store.auto_multichat_enabled() then return end
    net.get_json(net.ORIGIN .. "/api/profile/" .. net.percent_encode(channel) .. "?platform=twitch", 8000, function(payload)
        local p = payload and payload.profile
        if not p then return end
        if type(p.kick_username) == "string" and p.kick_username ~= "" then
            if multichat.link(channel, "kick", p.kick_username, true) then
                net.log_info("auto-multichat: linked kick:" .. p.kick_username .. " → #" .. channel)
            end
        end
        if type(p.youtube_username) == "string" and p.youtube_username ~= "" then
            multichat.link(channel, "yt", p.youtube_username, true)
        end
    end)
end

if caps.tier == 2 then
    render.on_channel_found = function(platform, channel)
        ws.join(platform, channel)
        if platform == "twitch" then try_auto_multichat(channel) end
    end
    render.on_channel_gone = function(platform, channel)
        ws.leave(platform, channel)
        -- twitch tab closed → drop its ephemeral auto-multichat subscriptions
        if platform == "twitch" then multichat.unlink_auto(channel) end
    end
    badges.load() -- fetch the chatterino badge list (rendered only if /hsbadges on)
    render.boot_fn = function()
        local n = inventory.count()
        local who = inventory.login and (" as " .. inventory.login) or ""
        local arch = store.archive_enabled() and " · archiving public chat to heatsync (/hsarchive off to opt out)" or ""
        local am = store.auto_multichat_enabled() and " · auto-merging linked kick/yt chat (/hsmulti auto off)" or ""
        return "🔥 heatsync active" .. who .. " · " .. tostring(n) ..
            " emotes · /hsemotes menu · :name tab-complete · /hssearch the archive · /hshelp for all commands" .. arch .. am
    end
    render.start()
end

do
    local login = current_login_safe()
    if login then
        last_full_refresh_ts = net.now()
        adopt_login(login)
    else
        net.log_warn("no signed-in twitch account at boot; will pick it up when you sign in")
    end
end

if caps.later then
    -- account switch + boot retry (60s), full-refresh reconcile vs missed ws
    -- events (15min via the same tick), queued-refresh drain (5s),
    -- sender batch flush (2s), ws heartbeat (25s) + stale watchdog (30s),
    -- channel discovery sweep (5s, t2)
    net.every(60 * 1000, login_and_refresh_tick)
    net.every(5 * 1000, function()
        inventory.drain_queued()
        -- boot retry shouldn't wait for the 60s tick
        if inventory.boot_failed_at then login_and_refresh_tick() end
    end)
    net.every(2 * 1000, senders.flush)
    if caps.tier >= 1 then
        net.every(25 * 1000, ws.heartbeat)
        net.every(30 * 1000, ws.watchdog)
    end
    if caps.tier == 2 then
        net.every(5 * 1000, render.discover)
    end
end
