-- other chatters' heatsync emote sets, so their emotes render for the local
-- user (extension parity: a word renders iff the SENDER's inventory has it).
--
-- three feeds:
--   1) live: emote:broadcast over the websocket (a chatter in a joined channel
--      announces the one emote they just posted, keyed by login)
--   2) cold-start: GET /api/users/emotes/batch?ids=twitch:<id>,... — one
--      batched call per flush window, same endpoint the extension uses,
--      edge-cached server-side. chatterino gives us msg.user_id (the twitch
--      numeric id) directly, so no per-login profile hop is needed.
--   3) invalidate: a global emote:added/emote:removed viewer push names the
--      changed sender's batch-endpoint keys (senderKeys) — a cached one is
--      dropped and refetched with a ?v= cache-bust (see M.invalidate).
local net = require("net")

local M = {
    own_login = nil,
    own_map_fn = nil,   -- getter: inventory swaps its map table wholesale on
                        -- refresh, so a direct reference would go stale
    on_loaded = nil,    -- fn(login) after a batch answer lands (for back-pass)
}

-- cache[login] = { map = {name -> {url,w,h,zw}} | false, ts }
-- false = looked up, user has no heatsync emotes (negative cache)
-- ts doubles as last-use time so eviction is true LRU (see evict_if_full).
local cache = {}
local cache_count = 0
local pending = {}        -- login -> twitch_id, waiting for the next flush
local pending_count = 0
local inflight = false

local CACHE_MAX = 500
local POSITIVE_TTL_S = 15 * 60
-- negative TTL is deliberately SHORT: a false entry is the window where a
-- sender's brand-new heatsync emote renders as plain text for this client if
-- the live emote:broadcast was missed (ws hiccup, busy channel). 90s bounds
-- that blind spot; positive entries stay long — they self-heal via broadcast.
local NEGATIVE_TTL_S = 90
local BATCH_MAX = 15      -- matches the extension's batch sizing (cf-safe)

-- reverse index for the viewer-push invalidation path: a `senderKeys` frame
-- carries "twitch:<id>", not a login, so cache entries loaded with a known
-- twitch id are indexed both ways. entries fed purely by emote:broadcast (no
-- id, just a username) are simply absent here — invalidate() treats that as
-- "not currently cached" and leaves them for their own TTL/broadcast feed.
local id_index = {} -- twitch id (string) -> login

-- evict the least-recently-used entry (oldest ts) when over cap. O(n) scan,
-- but only runs when inserting past CACHE_MAX — rare — so it stays cheap on
-- the hot path (which only reads/touches, never evicts).
local function evict_if_full()
    while cache_count > CACHE_MAX do
        local victim, victim_ts = nil, nil
        for login, entry in pairs(cache) do
            if victim_ts == nil or entry.ts < victim_ts then
                victim, victim_ts = login, entry.ts
            end
        end
        if not victim then break end
        if cache[victim].id then id_index[cache[victim].id] = nil end
        cache[victim] = nil
        cache_count = cache_count - 1
    end
end

-- id (twitch numeric id, string) is optional — only the batch-lookup path
-- (flush/invalidate) knows it; feed_broadcast doesn't and passes nil.
local function put(login, map, id)
    if cache[login] == nil then
        cache_count = cache_count + 1
    end
    local prev = cache[login]
    if prev and prev.id and prev.id ~= id then id_index[prev.id] = nil end
    -- carry the map's entry count so feed_broadcast can enforce the per-login cap
    -- in O(1) instead of rescanning the map on every insert. counted once here
    -- (batch load / new login only), not on the hot broadcast path.
    local n = 0
    if type(map) == "table" then for _ in pairs(map) do n = n + 1 end end
    cache[login] = { map = map, ts = net.now(), n = n, id = id }
    if id then id_index[id] = login end
    evict_if_full()
end

local function fresh(login)
    local hit = cache[login]
    if not hit then return nil end
    local ttl = (hit.map == false) and NEGATIVE_TTL_S or POSITIVE_TTL_S
    if (net.now() - hit.ts) > ttl then return nil end
    hit.ts = net.now() -- touch: a read is a use, keeps active senders resident
    return hit
end

-- resolve a sender's emote map. returns the map table, false (known-empty),
-- or nil (unknown — a lookup gets queued if a twitch id was provided).
function M.resolve(login, twitch_id)
    if not login or login == "" then return false end
    if M.own_login and login == M.own_login then
        local map = M.own_map_fn and M.own_map_fn()
        if type(map) == "table" and next(map) ~= nil then return map end
        return false
    end
    local hit = fresh(login)
    if hit then return hit.map end
    if twitch_id and twitch_id ~= "" and string.match(twitch_id, "^%d+$")
        and not pending[login] and pending_count < 100 then
        pending[login] = twitch_id
        pending_count = pending_count + 1
    end
    return nil
end

-- pure membership check (no lookup queued) for the flame marker: is this login
-- a known heatsync user? true iff we already have a positive emote set for
-- them — own login with a non-empty inventory, or a cached sender with a real
-- map. an HS user we've never seen post an emote reads false until their first
-- HS emote populates the cache (progressive, no lookup storm on silent chat).
function M.is_known_hs(login)
    if not login or login == "" then return false end
    if M.own_login and login == M.own_login then
        local map = M.own_map_fn and M.own_map_fn()
        return type(map) == "table" and next(map) ~= nil
    end
    local hit = fresh(login)
    return hit ~= nil and type(hit.map) == "table"
end

-- a single chatter's emote set (from the untrusted batch endpoint or a live
-- broadcast flood) is bounded the same way the own inventory is — so a hostile
-- response can't blow memory building one sender's map.
local MAX_SET_ENTRIES = 5000

local function rows_to_map(rows)
    local map = {}
    local any = false
    for i, e in ipairs(rows) do
        if i > MAX_SET_ENTRIES then break end
        local rec = net.parse_emote_row(e)
        if rec then
            map[rec.name] = { url = rec.url, w = rec.w, h = rec.h, zw = rec.zw, a = rec.a, u = rec.u }
            any = true
        end
    end
    if any then return map end
    return false
end

-- drain up to BATCH_MAX pending lookups in one request. driven by init's
-- timer loop (every ~2s); single-flight.
function M.flush()
    if inflight or pending_count == 0 then return end
    local batch = {}   -- { {login, id} }
    local ids = {}
    for login, id in pairs(pending) do
        table.insert(batch, { login = login, id = id })
        table.insert(ids, "twitch:" .. id)
        pending[login] = nil
        pending_count = pending_count - 1
        if #batch >= BATCH_MAX then break end
    end
    if #batch == 0 then return end
    inflight = true
    local url = net.ORIGIN .. "/api/users/emotes/batch?ids=" .. table.concat(ids, ",")
    net.get_json(url, 10000, function(payload, err)
        inflight = false
        if not payload or type(payload.sets) ~= "table" then
            net.log_warn("sender batch lookup failed: " .. tostring(err))
            -- negative-cache the whole batch briefly so a flaky upstream
            -- doesn't hot-loop; ttl on false entries is the shorter one
            for _, b in ipairs(batch) do put(b.login, false, b.id) end
            return
        end
        for _, b in ipairs(batch) do
            local rows = payload.sets["twitch:" .. b.id]
            local map = false
            if type(rows) == "table" then
                map = rows_to_map(rows)
            end
            put(b.login, map, b.id)
            if map and M.on_loaded then
                pcall(M.on_loaded, b.login)
            end
        end
    end)
end

-- ver must be a finite non-negative integer to ride as a cache-bust query
-- param (the edge only partitions on the exact string, so any other shape is
-- just noise) — invalid/missing ver still refetches, just without busting.
local function valid_ver(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    if v < 0 or math.floor(v) ~= v then return nil end
    return v
end

-- a viewer-push frame named the exact sender keys its change resolves to
-- (senderKeys). Only "twitch:<id>" keys are ours to act on (kick/yt keys don't
-- correspond to anything in this login-keyed cache); only ones we're CURRENTLY
-- caching are worth a refetch — an id we've never queued was never stale to
-- begin with. capped at 50 keys scanned (matches the batch endpoint's own
-- token cap), so a hostile 1000-entry array can't turn one push into a scan
-- or a refetch storm.
local INVALIDATE_MAX = 50
function M.invalidate(keys, ver)
    if type(keys) ~= "table" then return end
    local ver_ok = valid_ver(ver)
    local targets = {}
    for i = 1, math.min(#keys, INVALIDATE_MAX) do
        local key = keys[i]
        if type(key) == "string" then
            local id = string.match(key, "^twitch:(%d+)$")
            if id then
                local login = id_index[id]
                if login and cache[login] then
                    table.insert(targets, { id = id, login = login })
                end
            end
        end
    end
    if #targets == 0 then return end
    -- drop now so a render miss during the refetch shows plain text rather
    -- than the stale (possibly just-removed) emote
    for _, t in ipairs(targets) do
        cache[t.login] = nil
        cache_count = cache_count - 1
        id_index[t.id] = nil
    end
    local ids = {}
    for _, t in ipairs(targets) do table.insert(ids, "twitch:" .. t.id) end
    local url = net.ORIGIN .. "/api/users/emotes/batch?ids=" .. table.concat(ids, ",")
    if ver_ok then url = url .. "&v=" .. tostring(ver_ok) end
    net.get_json(url, 10000, function(payload, err)
        if not payload or type(payload.sets) ~= "table" then
            net.log_warn("sender invalidate refetch failed: " .. tostring(err))
            return
        end
        for _, t in ipairs(targets) do
            local rows = payload.sets["twitch:" .. t.id]
            local map = false
            if type(rows) == "table" then map = rows_to_map(rows) end
            put(t.login, map, t.id)
            if map and M.on_loaded then pcall(M.on_loaded, t.login) end
        end
    end)
end

-- an emote:removed viewer push names the sender + the exact name that's gone —
-- scrub it from the cached map immediately instead of waiting on invalidate()'s
-- round trip (which also fires, from the same frame's senderKeys, and will
-- confirm this — but a removed emote shouldn't keep rendering for the ~10s a
-- fetch takes).
function M.forget(username, emote_name)
    if not net.is_safe_name(username) then return end
    if not net.is_safe_name(emote_name) then return end
    local login = string.lower(username)
    if M.own_login and login == M.own_login then return end
    local entry = cache[login]
    if entry and type(entry.map) == "table" and entry.map[emote_name] ~= nil then
        entry.map[emote_name] = nil
        if entry.n and entry.n > 0 then entry.n = entry.n - 1 end
    end
end

-- a reconnect after a long gap may have missed invalidations while it was
-- down — mark every cached entry stale (rather than nuking the cache outright)
-- so the NEXT time each sender posts, resolve() treats it as expired and
-- queues a fresh lookup. lazy: a quiet sender pays nothing.
function M.expire_all()
    for _, entry in pairs(cache) do
        entry.ts = -1/0
    end
end

-- live feed from the websocket: an extension user posted an emote in a
-- channel we're joined to. partial maps are fine — the emote in hand is the
-- one that needs to render right now.
function M.feed_broadcast(username, emote_name, emote_data)
    if type(emote_data) ~= "table" then return end
    -- the server does not filter this push per viewer (unlike a fetched batch
    -- response, which already excludes cw rows) — emoteData carries the same
    -- nsfw/cw_cats fields as any other row, so gate it here the same way.
    if net.is_cw_blocked(emote_data) then return end
    -- username becomes an unbounded cache KEY, so it needs the same single-token
    -- safety as an emote name (a login can't hold spaces/control bytes anyway).
    -- emote_name → InsertText/tooltip; url must be bounded (never gated elsewhere).
    if not net.is_safe_name(username) then return end
    if not net.is_safe_name(emote_name) then return end
    local url = net.pick_first_str(emote_data, "url", "src")
    if not net.is_safe_url(url) then return end
    local login = string.lower(username)
    if M.own_login and login == M.own_login then return end
    local entry = cache[login]
    if entry and type(entry.map) == "table" then
        entry.ts = net.now()
    else
        put(login, {})
        entry = cache[login]
    end
    local map = entry.map
    -- cap distinct emotes per login so a broadcast flood can't grow one map
    -- unbounded — O(1) via the maintained count, not a per-insert rescan
    if map[emote_name] == nil then
        if (entry.n or 0) >= MAX_SET_ENTRIES then return end
        entry.n = (entry.n or 0) + 1
    end
    map[emote_name] = {
        url = url,
        w = net.pick_first_num(emote_data, "width"),
        h = net.pick_first_num(emote_data, "height"),
        zw = emote_data.zero_width == true,
    }
    if M.on_loaded then pcall(M.on_loaded, login) end
end

function M.stats()
    return cache_count, pending_count
end

function M.clear()
    cache = {}
    cache_count = 0
    id_index = {}
    pending = {}
    pending_count = 0
end

return M
