-- other chatters' heatsync emote sets, so their emotes render for the local
-- user (extension parity: a word renders iff the SENDER's inventory has it).
--
-- two feeds:
--   1) live: emote:broadcast / emotes:batch-broadcast over the websocket
--      (extension users announce emotes they post, keyed by login)
--   2) cold-start: GET /api/users/emotes/batch?ids=twitch:<id>,... — one
--      batched call per flush window, same endpoint the extension uses,
--      edge-cached server-side. chatterino gives us msg.user_id (the twitch
--      numeric id) directly, so no per-login profile hop is needed.
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
local NEGATIVE_TTL_S = 10 * 60
local BATCH_MAX = 15      -- matches the extension's batch sizing (cf-safe)

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
        cache[victim] = nil
        cache_count = cache_count - 1
    end
end

local function put(login, map)
    if cache[login] == nil then
        cache_count = cache_count + 1
    end
    cache[login] = { map = map, ts = net.now() }
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

local function rows_to_map(rows)
    local map = {}
    local any = false
    for _, e in ipairs(rows) do
        local name = net.pick_first_str(e, "custom_name", "name", "code")
        local url = net.pick_first_str(e, "url", "src")
        if name and url then
            map[name] = {
                url = url,
                w = net.pick_first_num(e, "width"),
                h = net.pick_first_num(e, "height"),
                zw = e.zero_width == true,
            }
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
            for _, b in ipairs(batch) do put(b.login, false) end
            return
        end
        for _, b in ipairs(batch) do
            local rows = payload.sets["twitch:" .. b.id]
            local map = false
            if type(rows) == "table" then
                map = rows_to_map(rows)
            end
            put(b.login, map)
            if map and M.on_loaded then
                pcall(M.on_loaded, b.login)
            end
        end
    end)
end

-- live feed from the websocket: an extension user posted an emote in a
-- channel we're joined to. partial maps are fine — the emote in hand is the
-- one that needs to render right now.
function M.feed_broadcast(username, emote_name, emote_data)
    if type(username) ~= "string" or username == "" then return end
    if type(emote_name) ~= "string" or emote_name == "" then return end
    if type(emote_data) ~= "table" then return end
    local url = net.pick_first_str(emote_data, "url", "src")
    if not url then return end
    local login = string.lower(username)
    if M.own_login and login == M.own_login then return end
    local hit = cache[login]
    local map
    if hit and type(hit.map) == "table" then
        map = hit.map
        hit.ts = net.now()
    else
        map = {}
        put(login, map)
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
    pending = {}
    pending_count = 0
end

return M
