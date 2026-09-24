-- 7tv global catalog search, popularity-ranked (TOP_ALL_TIME via the
-- heatsync.org /api/emote-search proxy — redis-cached + single-flight
-- server-side). cache-first; a fetch kicked off on one keystroke feeds the
-- next one.
local net = require("net")
local caps = require("caps")

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

-- ----- render cache: name → {url,h} (for render.lua + /hsfind picker) -----
-- exact-case names (emotes are case-sensitive). per-provider: bump 1x → a
-- higher-res variant for a crisp downscale to chat height, with that
-- variant's pixel height (7tv/bttv/ffz normalize to a known-ish 1x height).
-- pat/rep bump 1x → 2x; h_hi is the 2x height, h_lo the 1x fallback used when
-- the url doesn't match the expected suffix (so we don't over-upscale a 1x url
-- as if it were 2x).
local PROVIDER = {
    ["7tv"] = { pat = "/1x%.webp$", rep = "/2x.webp", h_hi = 64, h_lo = 32 },
    bttv    = { pat = "/1x%.(%a+)$", rep = "/2x.%1", h_hi = 56, h_lo = 28 },
    ffz     = { pat = "/1$", rep = "/2", h_hi = 56, h_lo = 28 },
}

local render_cache = {}
local render_order = {}
local RENDER_MAX = 600

local function cache_render(name, url1x, provider)
    if render_cache[name] then return end
    local p = PROVIDER[provider or "7tv"] or PROVIDER["7tv"]
    local hires, n = url1x:gsub(p.pat, p.rep)
    render_cache[name] = { url = hires, h = (n > 0) and p.h_hi or p.h_lo }
    render_order[#render_order + 1] = name
    while #render_order > RENDER_MAX do
        local old = table.remove(render_order, 1)
        if old then render_cache[old] = nil end
    end
end

-- returns url, height for a searched emote name (any provider), or nil
function M.resolve_render(word)
    local hit = render_cache[word]
    if hit then return hit.url, hit.h end
    return nil
end

-- one search, all providers. /api/emote-search with no `p` returns
-- {results:{7tv:[],bttv:[],ffz:[],hs:[]}, merged:[...], partial?:true}.
-- `merged` (when present) is the server's own cross-provider ranking —
-- already ordered, already includes the native `hs` directory — so it
-- replaces the old client-side 7tv→bttv→ffz concat rather than adding to it.
-- an older server without `merged` still works via the per-provider fallback.
-- seeds the render cache either way. cb(list, partial) — partial is true when
-- the live upstream leg didn't finish inside the server's budget, i.e. this
-- answer may be catalog-only and could firm up moments later.
local PROVIDER_ORDER = { "7tv", "bttv", "ffz" }
-- cap total processed: nobody scrolls 500 results, and it bounds the work +
-- render-cache churn if a response returns a pathological count. bounds RAW
-- items scanned, not just valid ones kept: a response of the same name
-- repeated (or malformed rows) never advances #out, so a `#out` cap alone
-- would iterate a pathological array in full on every keystroke.
local MAX_RESULTS = 500
function M.search_all(q, cb)
    if type(q) ~= "string" or string.len(q) < M.MIN_CHARS or not M.is_sane_query(q) then
        cb({}); return
    end
    local url = net.ORIGIN .. "/api/emote-search?q=" .. net.percent_encode(q)
    net.get_json(url, 8000, function(payload, err)
        if not payload or (type(payload.merged) ~= "table" and type(payload.results) ~= "table") then
            net.log_warn("emote search failed for '" .. q .. "': " .. tostring(err))
            cb({}); return
        end
        local out = {}
        local seen = {}
        local scanned = 0
        -- returns false once a cap is hit, so the caller can stop iterating.
        local function consider(e, provider)
            if type(e) ~= "table" or #out >= MAX_RESULTS or scanned >= MAX_RESULTS then return false end
            scanned = scanned + 1
            local name = net.pick_first_str(e, "name", "code")
            local eurl = net.pick_first_str(e, "url", "src")
            local prov = provider or e.provider
            if name and eurl and net.is_safe_name(name) and net.is_safe_url(eurl) and not seen[name] then
                seen[name] = true
                cache_render(name, eurl, prov)
                out[#out + 1] = {
                    name = name, provider = prov, url = eurl, animated = e.animated == true,
                    -- camelCase (current server shape); zero_width kept for an
                    -- older/renamed server so a zero-width flag never silently
                    -- goes missing across a field rename.
                    zw = e.zeroWidth == true or e.zero_width == true,
                }
            end
            return true
        end
        if type(payload.merged) == "table" then
            for _, e in ipairs(payload.merged) do
                if not consider(e) then break end
            end
        else
            for _, provider in ipairs(PROVIDER_ORDER) do
                local items = payload.results[provider]
                if type(items) == "table" then
                    for _, e in ipairs(items) do
                        if not consider(e, provider) then break end
                    end
                end
            end
        end
        cb(out, payload.partial == true)
    end)
end

local function kick_off(q)
    if inflight[q] then return end
    if get_fresh(q) then return end
    inflight[q] = true
    M.search_all(q, function(results, partial)
        inflight[q] = nil
        if #results == 0 then
            -- on t0 (no c2.later) net.now() is frozen at 0, so ERROR_TTL_S never
            -- elapses and an empty/failed result would blacklist this query for
            -- the whole session. only negative-cache when the clock actually ticks;
            -- on t0 just re-fetch next time (completions are infrequent).
            if caps.later then put(q, {}, true) end
            return
        end
        -- store {name, lower} so the per-keystroke prefix scan below matches
        -- against a precomputed lowercase instead of re-lowering every name each
        -- keystroke while the exact query's search is still in flight.
        local names = {}
        for _, e in ipairs(results) do names[#names + 1] = { name = e.name, lower = string.lower(e.name) } end
        -- a partial answer is catalog-only (the live upstream leg didn't land in
        -- time) and may firm up seconds later — cache it, but under the short
        -- error TTL instead of the normal one so a fresher search retries soon.
        put(q, names, partial)
    end)
end

-- append cached matches for q into values; fire a background fetch so the
-- next keystroke can include fresh results.
function M.append_matches(q, values, seen, cap)
    if #values >= cap then return end
    if string.len(q) < M.MIN_CHARS or not M.is_sane_query(q) then return end
    kick_off(q)
    local hit = get_fresh(q)
    if hit then
        -- exact query is cached (authoritative, upstream popularity order)
        if type(hit.names) == "table" then
            for _, rec in ipairs(hit.names) do
                if #values >= cap then break end
                if not seen[rec.name] then
                    table.insert(values, rec.name)
                    seen[rec.name] = true
                end
            end
        end
        return
    end
    -- exact query's search is still in flight (fired this keystroke). surface
    -- the freshest cached PREFIX — a search fired a keystroke or two earlier —
    -- filtered to names that still match the full query, so 7tv results show up
    -- as you finish typing instead of only after an extra keystroke. (chatterino
    -- tab-CYCLES a static list and never re-requests completion on tab, so this
    -- is the only way async results reach the popup for the word you just typed.)
    for n = string.len(q) - 1, M.MIN_CHARS, -1 do
        local ph = get_fresh(string.sub(q, 1, n))
        if ph and type(ph.names) == "table" then
            for _, rec in ipairs(ph.names) do
                if #values >= cap then break end
                if not seen[rec.name] and string.find(rec.lower, q, 1, true) then
                    table.insert(values, rec.name)
                    seen[rec.name] = true
                end
            end
            break -- only the single freshest (longest) prefix
        end
    end
end

function M.clear()
    cache = {}
    order = {}
    inflight = {}
end

return M
