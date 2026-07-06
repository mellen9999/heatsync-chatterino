-- 7tv global catalog search, popularity-ranked (TOP_ALL_TIME via the
-- heatsync.org /api/emote-search proxy — redis-cached + single-flight
-- server-side). cache-first; a fetch kicked off on one keystroke feeds the
-- next one.
local net = require("net")

local M = {}

-- cache[lowercase_query] = { ts, names, is_error } — names in upstream
-- popularity order. errors get a short ttl so a flaky upstream self-heals.
local cache = {}
local order = {} -- fifo queue for eviction
local inflight = {}

local TTL_S = 10 * 60
local ERROR_TTL_S = 30
local CACHE_MAX = 64
M.MIN_CHARS = 2
M.MAX_CHARS = 50 -- server validator

local function evict_if_full()
    while #order > CACHE_MAX do
        local oldest = table.remove(order, 1)
        if oldest then cache[oldest] = nil end
    end
end

local function put(q, names, is_error)
    if cache[q] == nil then
        table.insert(order, q)
    end
    cache[q] = { ts = net.now(), names = names or {}, is_error = is_error or false }
    evict_if_full()
end

local function get_fresh(q)
    local hit = cache[q]
    if not hit then return nil end
    local ttl = hit.is_error and ERROR_TTL_S or TTL_S
    if (net.now() - hit.ts) > ttl then return nil end
    return hit
end

function M.is_sane_query(q)
    return string.match(q, "^[a-z0-9_%-:%.]+$") ~= nil
end

local function kick_off(q)
    if inflight[q] then return end
    if get_fresh(q) then return end
    inflight[q] = true
    local url = net.ORIGIN .. "/api/emote-search?q=" .. net.percent_encode(q) .. "&p=7tv"
    net.get_json(url, 8000, function(payload, err)
        inflight[q] = nil
        if not payload then
            put(q, {}, true)
            net.log_warn("7tv search failed for '" .. q .. "': " .. tostring(err))
            return
        end
        local items = payload.results and payload.results["7tv"]
        local names = {}
        local seen = {}
        if type(items) == "table" then
            for _, e in ipairs(items) do
                local name = net.pick_first_str(e, "name", "code")
                if name and not seen[name] then
                    table.insert(names, name)
                    seen[name] = true
                end
            end
        end
        put(q, names)
    end)
end

-- append cached matches for q into values; fire a background fetch so the
-- next keystroke can include fresh results.
function M.append_matches(q, values, seen, cap)
    if #values >= cap then return end
    if string.len(q) < M.MIN_CHARS or not M.is_sane_query(q) then return end
    kick_off(q)
    local hit = get_fresh(q)
    if hit and type(hit.names) == "table" then
        for _, name in ipairs(hit.names) do
            if #values >= cap then break end
            if not seen[name] then
                table.insert(values, name)
                seen[name] = true
            end
        end
    end
end

function M.clear()
    cache = {}
    order = {}
    inflight = {}
end

function M.stats()
    return #order, CACHE_MAX
end

return M
