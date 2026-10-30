-- community mutes (opt-in, /hsmutes on): chatters that enough of a channel's
-- heatsync community muted get their line collapsed to a short placeholder, the
-- way the site applies them. GET /api/community-mutes/<channel>?threshold=N is
-- public and anonymous; the answer is a username list (the server omits how many
-- people muted each one, on purpose).
--
-- hide vs collapse: heatsync's mute strips a muted chatter's content but keeps
-- the row (timestamp + name stay, the body goes), and a community mute is just a
-- mute tagged "community" in that same manager (client/managers/community-mute-
-- manager.js, default OFF, threshold 25, re-fetched every 10 minutes). so this
-- collapses rather than hides: a plugin can't delete a message, and a visible
-- placeholder is the honest version of what the site does. render.lua does the
-- replace (its single chokepoint); this module only answers "is this chatter
-- muted here?" from a per-channel cache.
--
-- cost: one request per open channel per 10 minutes (the site's own cadence), at
-- most one per 4s tick; a failure is remembered for a minute. nothing about a
-- chatter or a message is ever sent — only the channel name.
local net = require("net")
local caps = require("caps")
local store = require("store")
local lookup = require("lookup")
local senders = require("senders")

local M = {}

M.THRESHOLD = 25 -- the site's default communityMuteThreshold
local LIMIT = 500    -- the server's own ceiling
local NAME_MAX = 100
local CHANNEL_RE = "^[a-z0-9_]+$"

-- tooltip on the placeholder we draw: how a later pass recognises its own line
M.TIP = "muted by the heatsync community"
M.TEXT = "[muted by the community]"

local PLATFORM = { twitch = "twitch", kick = "kick", youtube = "youtube", yt = "youtube" }

-- /api/community-mutes mutes[] → { any = {name=true}, twitch = {...}, kick = {...},
-- youtube = {...} }, or false when nothing usable (an empty list included). a
-- null/unknown platform means "that name on every platform", as on the site.
function M.parse(list)
    if type(list) ~= "table" then return false end
    local out = { any = {}, twitch = {}, kick = {}, youtube = {} }
    local n = 0
    for i = 1, math.min(#list, LIMIT) do
        local e = list[i]
        if type(e) == "table" and type(e.username) == "string" and e.username ~= ""
            and #e.username <= NAME_MAX and not string.find(e.username, "%c") then
            local name = string.lower(e.username)
            local bucket = type(e.platform) == "string" and PLATFORM[string.lower(e.platform)] or nil
            out[bucket or "any"][name] = true
            n = n + 1
        end
    end
    if n == 0 then return false end
    return out
end

local cache = lookup.new({
    ttl = 600,
    fail_ttl = 60,
    cache_max = 100,
    pending_max = 50,
    batch_max = 1, -- one channel per request; the flush beat spaces them out
    fetch = function(channels, done)
        local channel = channels[1]
        net.get_json(net.ORIGIN .. "/api/community-mutes/" .. net.percent_encode(channel) ..
            "?threshold=" .. M.THRESHOLD .. "&limit=" .. LIMIT, 8000, function(payload, err)
            local list = type(payload) == "table" and payload.mutes
            if type(list) ~= "table" then
                net.log_warn("community mutes lookup failed: " .. tostring(err))
                return done(nil)
            end
            done({ [channel] = M.parse(list) })
        end)
    end,
})

-- a muted-chatter list landed for a channel (render back-pass)
function M.set_on_loaded(fn)
    cache.on_loaded = function(channel, set)
        if set then fn(channel) end
    end
end

-- needs render's replace_message (t2); opt-in
function M.enabled()
    return store.mutes_enabled() and caps.tier == 2
end

-- is `login` (lowercase) on `platform` ("twitch" | "kick" | "youtube") muted in
-- `channel`? queues the channel's lookup the first time it's asked about; until
-- it lands the answer is no (nothing is hidden on a guess). never mutes you.
function M.is_muted(channel, login, platform)
    if type(channel) ~= "string" or type(login) ~= "string" then return false end
    if #channel > 25 or not string.match(channel, CHANNEL_RE) then return false end
    if login == senders.own_login then return false end
    local set = cache:resolve(channel)
    if not set then return false end
    login = string.lower(login)
    return set.any[login] == true or (set[platform] ~= nil and set[platform][login] == true)
end

function M.flush() cache:flush() end
function M.clear() cache:clear() end
function M.stats() return cache:stats() end

return M
