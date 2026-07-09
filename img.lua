-- shared image-set builder + LRU cache. used by render (hs emotes) and
-- multichat (kick/youtube emotes). scales a source image down to twitch's
-- ~28px line height using its known dimensions; without dims it returns nil
-- so the caller falls back to text (a raw image could be 1000px tall and
-- there's no post-load resize hook).
local M = {}

local sets = {}       -- key -> c2.ImageSet
local ring = {}       -- slot 1..MAX -> key (O(1) circular eviction, no shift)
local ring_pos = 0
local MAX = 400
local TARGET_H = 28   -- twitch 1x emote line height

-- CDN allowlist. an emote's backing URL is USER-influenced (a heatsync user
-- equips it), so an arbitrary host would be a tracking beacon / SSRF fetched by
-- every viewer who resolves that sender — defense in depth even if the server
-- validates on upload. these are the ONLY hosts the plugin ever legitimately
-- loads an image from: the emote providers, kick/youtube emote CDNs, heatsync's
-- own CDN, and the first-party chatterino-badge host. non-allowlisted → nil, and
-- the caller falls back to text.
local ALLOWED_HOST_SUFFIXES = {
    "7tv.app", "betterttv.net", "frankerfacez.com", -- emote providers
    "kick.com", "ggpht.com", "googleusercontent.com", -- kick + youtube emotes
    "heatsync.org", "fourtf.com",                     -- first-party cdn + cc badges
}
local function host_allowed(url)
    -- https ONLY — reject http:// (downgrade / cleartext beacon) even on an
    -- allowlisted host. every CDN we load from serves https.
    local host = string.match(url, "^https://([^/]+)")
    if not host then return false end
    host = string.lower(string.match(host, "^([^:]+)") or host) -- drop any :port
    for _, suf in ipairs(ALLOWED_HOST_SUFFIXES) do
        -- exact host OR a real subdomain of it. the `.`-prefix check rejects the
        -- classic bypass (e.g. "heatsync.org.evil.com" does NOT end in ".heatsync.org").
        if host == suf or string.sub(host, -(#suf + 1)) == "." .. suf then
            return true
        end
    end
    return false
end

-- target_h defaults to emote height (28); badges pass ~18. keyed by url+target
-- so the same image can be cached at two display sizes without collision.
function M.for_url(url, w, h, target_h)
    if type(url) ~= "string" or url == "" then return nil end
    if not host_allowed(url) then return nil end
    target_h = target_h or TARGET_H
    local key = url .. "@" .. target_h
    local set = sets[key]
    if set then return set end
    if not h or h <= 0 then return nil end
    local scale = target_h / h
    if scale > 1 then scale = 1 end
    if scale < 0.05 then scale = 0.05 end
    local ok, built = pcall(function()
        local img
        if w and w > 0 then
            img = c2.Image.from_url(url, scale, { w, h })
        else
            img = c2.Image.from_url(url, scale)
        end
        return c2.ImageSet.new(img)
    end)
    if not ok or not built then return nil end
    sets[key] = built
    -- circular eviction: overwrite the slot MAX inserts ago in O(1), instead of
    -- table.remove(order, 1) which shifts the whole array on every eviction once
    -- full (the same fix already applied to multichat's dedup buffer).
    local slot = (ring_pos % MAX) + 1
    local evicted = ring[slot]
    if evicted ~= nil then sets[evicted] = nil end
    ring[slot] = key
    ring_pos = ring_pos + 1
    return built
end

-- heatsync inventory stores an emote's NATIVE height (commonly 128) but the url
-- it references is always the provider's 1x tier, which the cdns normalize to a
-- fixed line height — 7tv/ffz serve 1x at 32px, bttv at 28px — regardless of the
-- native size. so the served image is <=32px tall no matter the stored height;
-- scaling by the stored native height shrinks tall emotes to ~7px, i.e. invisible
-- ("can't see it"). clamp the scale basis to the 1x line height so the served
-- image lands at the chat line height, and never pass the stored width (it can
-- disagree with the served 1x image and stretch it — cf. the 96x32-record /
-- 32x32-image case). searched-7tv results go through for_url directly instead:
-- seventv.lua keeps their url+height in the same tier, so they're already
-- consistent and must not be clamped.
local HS_1X_MAX_H = 32
function M.for_hs_emote(url, h, target_h)
    if type(h) ~= "number" or h <= 0 then return nil end
    if h > HS_1X_MAX_H then h = HS_1X_MAX_H end
    return M.for_url(url, nil, h, target_h)
end

return M
