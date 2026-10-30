-- heat scores: a colored bar before the username of chatters who have heat on
-- heatsync, the plugin's version of the extension's left-edge heat border.
-- POST /api/users/heat {usernames:[...]} → {users:{name:{heat,op,re}}} (public,
-- no auth), batched like senders.lua and cached ~2 min like the extension's
-- HEAT_CACHE_TTL, so a busy chat costs a request per handful of new chatters,
-- never one per message. the number lives in the bar's tooltip — never an emoji
-- next to a score (the 🔥 marker is a separate thing, see render.lua).
--
-- the anonymous socket also receives the server's global user:heat_batch_update
-- push; it refreshes chatters we already hold (it never adds new ones).
local net = require("net")
local store = require("store")
local lookup = require("lookup")

local M = {}

-- ladder + thresholds mirror the extension (content.js getHeatTier/HEAT_GRADIENT):
-- no bar under 5; hue steps white → yellow → red; the glyph thickens with the
-- tier the way the border widens (3/4/5/6px → ▎▍▌▊)
local MIN_HEAT = 5
local TIERS = { -- ascending: { min heat, color, glyph }
    { 5, "#ffffff", "▎" },
    { 20, "#ffffff", "▍" },
    { 50, "#ffff00", "▍" },
    { 100, "#ffff00", "▌" },
    { 200, "#ffff00", "▌" },
    { 500, "#ffff00", "▌" },
    { 1000, "#ff0000", "▊" },
    { 5000, "#ff0000", "▊" },
}
M.GLYPHS = { ["▎"] = true, ["▍"] = true, ["▌"] = true, ["▊"] = true }

local HEAT_MAX = 1e12 -- a score past this is not a real score

local function count_of(v)
    v = tonumber(v)
    if not v or v ~= v or v < 0 or v > HEAT_MAX then return 0 end
    return math.floor(v)
end

-- {glyph, color, tip} for a score worth showing, else false. cached per chatter
-- so the render path never rebuilds it.
local function info_for(row)
    if type(row) ~= "table" then return false end
    local heat = count_of(row.heat)
    if heat < MIN_HEAT then return false end
    local tier = TIERS[1]
    for _, t in ipairs(TIERS) do
        if heat >= t[1] then tier = t end
    end
    local tip = "heat " .. tostring(heat)
    local op, re = count_of(row.op), count_of(row.re)
    if op > 0 or re > 0 then
        tip = tip .. " · " .. tostring(op) .. " posts · " .. tostring(re) .. " replies"
    end
    return { glyph = tier[3], color = tier[2], tip = tip .. " · heatsync" }
end

local BATCH_MAX = 25 -- well under the server's 100; a handful per request

local cache = lookup.new({
    ttl = 120,
    cache_max = 1000,
    pending_max = 200,
    batch_max = BATCH_MAX,
    fetch = function(logins, done)
        net.post_json(net.ORIGIN .. "/api/users/heat", { usernames = logins }, 8000, function(payload, err)
            local users = type(payload) == "table" and payload.users
            if type(users) ~= "table" then
                net.log_warn("heat lookup failed: " .. tostring(err))
                return done(nil)
            end
            local out = {}
            for _, login in ipairs(logins) do out[login] = info_for(users[login]) end
            done(out)
        end)
    end,
})

-- fn(login, info) when a lookup lands a chatter worth showing (render back-pass)
function M.set_on_loaded(fn)
    cache.on_loaded = function(login, info)
        if info then fn(login, info) end
    end
end

-- the bar for a chatter, or nil. queues a lookup for an unseen login (the
-- caller must pass a canonical lowercase twitch login).
function M.info(login)
    if not store.heat_enabled() then return nil end
    -- an unseen name becomes a request body entry: hold it to the login charset
    if cache.cache[login] == nil
        and (#login > 25 or not string.match(login, "^[a-z0-9_]+$")) then
        return nil
    end
    return cache:resolve(login) or nil
end

-- a user:heat_batch_update frame: {updates:[{username,userHeat,op,re}]}. only
-- chatters already cached are touched, and the frame is capped, so a hostile or
-- chatty push can't grow the cache or turn into a scan. returns true if handled.
local PUSH_MAX = 500
function M.handle(msg)
    if msg.type ~= "user:heat_batch_update" then return false end
    local ups = msg.updates
    if type(ups) ~= "table" then return true end
    for i = 1, math.min(#ups, PUSH_MAX) do
        local u = ups[i]
        if type(u) == "table" and type(u.username) == "string" and #u.username <= 25 then
            local login = string.lower(u.username)
            if cache.cache[login] then
                local info = info_for({ heat = u.userHeat, op = u.op, re = u.re })
                cache:put(login, info)
                if info and cache.on_loaded then pcall(cache.on_loaded, login, info) end
            end
        end
    end
    return true
end

function M.flush() cache:flush() end
function M.clear() cache:clear() end
function M.stats() return cache:stats() end

return M
