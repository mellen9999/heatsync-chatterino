-- gif search for /hsgif: heatsync's own first-party gif library.
--   GET /api/gifs/search?q=<q>&limit=<n>   (q of 2+ chars)
--   GET /api/gifs/top?limit=<n>            (no query, or a 1-char one)
-- public, no auth, CORS-open. the corpus lives in heatsync's own database, so a
-- search never reaches giphy or tenor; same two routes and the same record shape
-- as the extension (lib/gif-search-remote.js: normalizeGif / fetchGifs).
--
-- this module is the data layer only: normalise + cache. cmd_gifs.lua draws the
-- grid. thumbnails are the `preview` still, always loaded through heatsync's image
-- proxy (/api/img) so the gif host never sees your ip; the url a click inserts is
-- the record's direct media url, byte for byte, like the extension's picker.
local net = require("net")

local M = {}

M.LIMIT_MAX = 50  -- the server's own ceiling per request
M.QUERY_MAX = 64  -- the server's own ceiling on q
local TTL_S = 300 -- the extension's searcher ttl
local CACHE_MAX = 20

-- a record the plugin will show, or nil. the url is inserted VERBATIM into your
-- chat input on click, so it must be a plain https url: no whitespace or control
-- bytes (newline injection) and no leading "/" or "." that could become a command.
local function clean_url(s)
    if not net.is_safe_url(s) or string.find(s, "%s") then return nil end
    if string.sub(s, 1, 8) ~= "https://" then return nil end
    return s
end

function M.normalize(raw)
    if type(raw) ~= "table" then return nil end
    local url = clean_url(raw.url)
    if not url then return nil end
    -- the still the grid paints; the extension falls back to the animated url when
    -- there's no still, and so does this (a degradation, not a default)
    local preview = clean_url(raw.preview) or url
    return {
        url = url,
        preview = preview,
        label = net.safe_text(raw.label, 100) or "",
    }
end

-- response body → { gifs = {...}, state = "empty"|"building"|"ready" } or nil when
-- it isn't a gif answer at all. never throws.
function M.parse(payload)
    if type(payload) ~= "table" or type(payload.gifs) ~= "table" then return nil end
    local out = {}
    for i = 1, math.min(#payload.gifs, M.LIMIT_MAX) do
        local g = M.normalize(payload.gifs[i])
        if g then out[#out + 1] = g end
    end
    local lib = type(payload.library) == "table" and payload.library.state or nil
    if lib ~= "empty" and lib ~= "building" then lib = "ready" end
    return { gifs = out, state = lib }
end

local cache, ring, ring_pos = {}, {}, 0

local function key_of(q, limit) return q .. "\1" .. tostring(limit) end

-- cb(result, err, status): result is parse()'s table. a repeat of a recent query
-- is served from memory (nothing leaves the machine).
function M.search(q, limit, cb)
    q = net.safe_text(q, M.QUERY_MAX) or ""
    q = string.match(q, "^%s*(.-)%s*$")
    limit = math.max(1, math.min(M.LIMIT_MAX, math.floor(tonumber(limit) or 24)))
    local key = key_of(q, limit)
    local hit = cache[key]
    if hit and (net.now() - hit.ts) <= TTL_S then return cb(hit.val) end
    local url
    if q == "" then
        url = net.ORIGIN .. "/api/gifs/top?limit=" .. limit
    else
        url = net.ORIGIN .. "/api/gifs/search?q=" .. net.percent_encode(q) .. "&limit=" .. limit
    end
    net.get_json(url, 8000, function(payload, err, status)
        local val = M.parse(payload)
        if not val then return cb(nil, err or "unexpected response", status) end
        if cache[key] == nil then
            local slot = (ring_pos % CACHE_MAX) + 1
            local evicted = ring[slot]
            if evicted ~= nil then cache[evicted] = nil end
            ring[slot] = key
            ring_pos = ring_pos + 1
        end
        cache[key] = { val = val, ts = net.now() }
        cb(val)
    end)
end

function M.stats()
    local n = 0
    for _ in pairs(cache) do n = n + 1 end
    return n
end

function M.clear() cache, ring, ring_pos = {}, {}, 0 end

return M
