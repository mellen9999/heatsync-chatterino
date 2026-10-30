-- sub-flair badges: the twitch sub badge a heatsync user picked to show off,
-- drawn before their name. GET /api/users/flair?ids=<twitch ids> (public, no
-- auth) answers a whole batch of chatters at once; ids with no flair are simply
-- absent. the badge is a static-cdn.jtvnw.net image — a host img.lua already
-- allowlists — and the tooltip names the broadcaster it came from.
local net = require("net")
local store = require("store")
local lookup = require("lookup")
local img = require("img")

local M = {}

local BADGE_H = 18 -- badges render smaller than emotes (same as badges.lua)
local FLAIR_PX = 72 -- badge_url_4x is twitch's 72px tier; 1x is 18px
local BATCH_MAX = 50 -- the server reads at most 100 ids

-- one flair row → { url, h, tip } or false. shape-validated: this is a remote
-- response, and the url is only ever fetched through img.for_url's allowlist.
local function parse_row(row)
    if type(row) ~= "table" or row.flair_type ~= "twitch_sub" then return false end
    local url, h = row.badge_url_4x, FLAIR_PX
    if not net.is_safe_url(url) then url, h = row.badge_url, BADGE_H end
    if not net.is_safe_url(url) then return false end
    local who = net.safe_text(row.broadcaster_login, 25)
    return { url = url, h = h, tip = (who and (who .. " subscriber") or "subscriber") .. " · heatsync" }
end

local who = {} -- twitch id -> login awaiting a lookup (for the render back-pass)
local who_n = 0

local cache = lookup.new({
    ttl = 10 * 60, -- a flair changes rarely; the picker is a settings action
    cache_max = 1000,
    pending_max = 200,
    batch_max = BATCH_MAX,
    fetch = function(ids, done)
        net.get_json(net.ORIGIN .. "/api/users/flair?ids=" .. table.concat(ids, ","), 8000, function(payload, err)
            local flairs = type(payload) == "table" and payload.flairs
            if type(flairs) ~= "table" then
                net.log_warn("flair lookup failed: " .. tostring(err))
                return done(nil)
            end
            local out = {}
            for _, id in ipairs(ids) do out[id] = parse_row(flairs[id]) end
            done(out)
        end)
    end,
})

-- fn(login) when a chatter turns out to have a flair (render back-pass)
function M.set_on_loaded(fn)
    cache.on_loaded = function(id, v)
        local login = who[id]
        if login then who[id] = nil; who_n = who_n - 1 end
        if v and login then fn(login) end
    end
end

-- does this chatter have a flair? queues a lookup for an unseen id. `login` is
-- remembered only until the answer lands, so the back-pass can find their lines.
function M.has(user_id, login)
    if not store.flair_enabled() then return false end
    if type(user_id) ~= "string" or not string.match(user_id, "^%d+$") or #user_id > 20 then return false end
    local v = cache:resolve(user_id)
    if v == nil and type(login) == "string" and not who[user_id] and who_n < 200 then
        who[user_id] = login
        who_n = who_n + 1
    end
    -- a flair whose image can't be drawn (host off the allowlist) is no
    -- content: it must not force a rebuild. for_url caches, so this is a lookup.
    return v and img.for_url(v.url, nil, v.h, BADGE_H) ~= nil or false
end

-- the badge element for a chatter with a flair (has() already vouched for
-- them), or nil — also nil when the image won't build (host not allowlisted).
function M.element_for(user_id)
    local v = cache:resolve(user_id)
    if not v then return nil end
    local set = img.for_url(v.url, nil, v.h, BADGE_H)
    if not set then return nil end
    return {
        type = "scaling-image",
        images = set,
        flags = c2.MessageElementFlag.BadgeSubscription or c2.MessageElementFlag.Badges,
        tooltip = v.tip,
    }
end

function M.flush() cache:flush() end
function M.clear() cache:clear(); who = {}; who_n = 0 end
function M.stats() return cache:stats() end

return M
