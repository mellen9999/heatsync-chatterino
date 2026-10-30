-- heatsync name colors: the flat color a chatter picked on heatsync, applied to
-- their name in merged youtube lines. GET /api/paints?ids= (public, no auth)
-- carries it in `colors`; the same response lists paints.
--
-- precedence mirrors the extension (name-style.js hsNameColour): a picked color
-- is for platforms with no native color model of their own — never a twitch
-- name (twitch's custom color is its paid perk, and its native color stays
-- put). and a heatsync PAINT wins over a picked color; a plugin can't draw a
-- paint, and a flat stand-in would be a fake, so a painted chatter is left
-- with the line's default color instead. kick lines carry no chatter id, so
-- only youtube (yt_<UC…>, from the message's authorChannelId) qualifies.
local net = require("net")
local store = require("store")
local lookup = require("lookup")

local M = {}

local BATCH_MAX = 50 -- the server uses at most 50 ids per request

local function valid_hex(s)
    return type(s) == "string" and string.match(s, "^#%x%x%x%x%x%x$") ~= nil
end

local cache = lookup.new({
    ttl = 10 * 60,
    cache_max = 1000,
    pending_max = 200,
    batch_max = BATCH_MAX,
    fetch = function(ids, done)
        net.get_json(net.ORIGIN .. "/api/paints?ids=" .. table.concat(ids, ","), 8000, function(payload, err)
            local colors = type(payload) == "table" and payload.colors
            if type(colors) ~= "table" then
                net.log_warn("name color lookup failed: " .. tostring(err))
                return done(nil)
            end
            local paints = type(payload.paints) == "table" and payload.paints or {}
            local out = {}
            for _, id in ipairs(ids) do
                local c = colors[id]
                out[id] = paints[id] == nil and valid_hex(c) and c or false
            end
            done(out)
        end)
    end,
})

-- the picked #rrggbb for a youtube chatter, or nil (none picked, painted, not
-- looked up yet — the first line from an unseen chatter queues the lookup and
-- keeps the default color; later lines pick the color up).
function M.for_youtube(author_channel_id)
    if not store.colors_enabled() then return nil end
    local id = author_channel_id
    if type(id) ~= "string" or #id ~= 24 or not string.match(id, "^UC[%w_%-]+$") then return nil end
    return cache:resolve("yt_" .. id) or nil
end

function M.flush() cache:flush() end
function M.clear() cache:clear() end
function M.stats() return cache:stats() end

return M
