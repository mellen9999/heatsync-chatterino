-- link previews (opt-in, /hspreviews on): a chat line whose FIRST link is not an
-- image (youtube, a twitch clip, x/twitter, an article...) gets one compact line
-- under it: a small thumbnail and `title · site`, both clicking through to the
-- ORIGINAL link. one per message, cached by url, failures remembered.
--
-- where the data comes from. heatsync resolves links server-side, anonymously:
--   GET /api/embed/resolve?url=   the extension's chat-embed resolver (feed-embed.js
--                                 _fetchFeedResolve): tenor, giphy, imgur, spotify,
--                                 soundcloud, x/twitter, kick clips, reddit
--   GET /api/link-preview?url=    open-graph / oembed title + image for everything
--                                 else (youtube, twitch clips, articles). the
--                                 extension declares it (LINK_PREVIEW_API) but its
--                                 chat path only resolves the providers above; the
--                                 plugin has to cover the rest or a youtube link
--                                 would never get a title.
-- an embed the server's scanner flagged is dropped whole, the extension's default
-- when the viewer has opted into nothing (the plugin has no viewer safety settings).
--
-- privacy: heatsync sees the link (it fetches and scans it) — that's why this is
-- opt-in. the third party never sees you: the thumbnail is only ever loaded through
-- heatsync's image proxy (/api/img, via images.lua's size probe + image_set), so no
-- image host gets your ip. budget: at most PER_MIN new urls a minute (each is a
-- server-side fetch); past that a link just stays a link. thumbnail probes draw on
-- images.lua's own budget.
local net = require("net")
local caps = require("caps")
local store = require("store")
local images = require("images")

local M = {}

-- tooltip on every element we draw: how a later rebuild recognises and passes
-- through its own preview line untouched
M.TIP = "preview via heatsync"

local PER_MIN = 10
local WINDOW_S = 60
local INFO_MAX = 300   -- remembered urls (and failures), circular
local RETRY_S = 300    -- a transient failure (timeout / 429 / 5xx) is retried after this
local THUMB_H = 56     -- compact: a small thumbnail beside the text
local THUMB_W = 100
local TITLE_MAX = 100
local SITE_MAX = 60

function M.enabled()
    return store.previews_enabled() and caps.images and caps.tier >= 2
end

-- ----- which endpoint (pure) -----

local function host_of(url)
    return string.lower(string.match(url, "^https://([^/?#:]+)") or "")
end

local function is_host(host, base)
    return host == base or string.sub(host, -(#base + 1)) == "." .. base
end

-- "resolve" for the providers /api/embed/resolve handles (mirrors the server's
-- resolveOne), else "preview" for /api/link-preview
function M.kind(url)
    local host = host_of(url)
    local path = string.lower(string.match(url, "^https://[^/?#]*(.*)$") or "")
    if is_host(host, "tenor.com") and string.find(path, "/view/", 1, true) then return "resolve" end
    if is_host(host, "giphy.com") and string.find(path, "/gifs/", 1, true) then return "resolve" end
    if is_host(host, "imgur.com") or host == "open.spotify.com" or host == "spotify.link" then return "resolve" end
    if is_host(host, "soundcloud.com") or is_host(host, "twitter.com") or is_host(host, "x.com") then return "resolve" end
    if is_host(host, "kick.com") and string.find(path, "/clips/", 1, true) then return "resolve" end
    if is_host(host, "reddit.com") and string.find(path, "/r/[%w_%-]+/comments/[a-z0-9]+") then return "resolve" end
    return "preview"
end

-- the link a message would preview, or nil: its first link, when that is a vetted
-- https url and NOT a direct image (those are inline images' job)
function M.detect(text)
    local url = images.first_link(text)
    if not url or images.detect(text) then return nil end
    return url
end

-- ----- response → info (pure) -----

local function clean_thumb(raw)
    if type(raw) ~= "string" then return nil end
    local ok = images.first_link(raw)
    if ok and ok == raw then return ok end
    return nil
end

-- {title, site, thumb} or false when there is nothing to show. never throws.
function M.parse(kind, payload, url)
    if type(payload) ~= "table" or payload.error ~= nil then return false end
    local title, site, thumb
    if kind == "resolve" then
        -- scanner-flagged media (any category, scan_failed included): dropped whole
        if type(payload.flagged) == "table" and #payload.flagged > 0 then return false end
        title = net.safe_text(payload.title, TITLE_MAX)
        site = net.safe_text(payload.author, SITE_MAX)
        thumb = clean_thumb(payload.thumbnail) or (payload.type == "image" and clean_thumb(payload.mediaUrl) or nil)
    else
        title = net.safe_text(payload.title, TITLE_MAX)
        site = net.safe_text(payload.siteName, SITE_MAX)
        thumb = clean_thumb(payload.image)
    end
    if not title and not thumb then return false end
    return { title = title, site = site or host_of(url), thumb = thumb }
end

-- ----- state -----

local infos = {}      -- url -> info table | false (final) | { retry_at } (transient)
local ring, ring_pos = {}, 0
local owners = {}     -- thumbnail url -> the message url it belongs to
local owners_n = 0
local inflight = {}
local win_start, win_n = nil, 0

local function remember(url, v)
    if infos[url] == nil then
        local slot = (ring_pos % INFO_MAX) + 1
        local evicted = ring[slot]
        if evicted ~= nil then infos[evicted] = nil end
        ring[slot] = url
        ring_pos = ring_pos + 1
    end
    infos[url] = v
end

local function take_budget()
    local now = net.now()
    if not win_start or now - win_start >= WINDOW_S then win_start, win_n = now, 0 end
    if win_n >= PER_MIN then return false end
    win_n = win_n + 1
    return true
end

-- fired (url) when a url's preview data (and its thumbnail's size) is ready to
-- draw; render.lua rebuilds the lines carrying it
M.on_ready = nil

local function ready(url)
    if M.on_ready then pcall(M.on_ready, url) end
end

local function request(url)
    if inflight[url] or not take_budget() then return end
    inflight[url] = true
    local kind = M.kind(url)
    local endpoint = kind == "resolve" and "/api/embed/resolve?url=" or "/api/link-preview?url="
    net.get_json(net.ORIGIN .. endpoint .. net.percent_encode(url), 10000, function(payload, err, status)
        inflight[url] = nil
        if type(payload) ~= "table" then
            -- a timeout / 429 / 5xx says nothing about the link: retry later. any
            -- other status (404 unsupported, 400, 403 blocked) is final.
            if status == nil or status == 429 or status >= 500 then
                net.log_info("link preview failed: " .. tostring(err))
                remember(url, { retry_at = net.now() + RETRY_S })
            else
                remember(url, false)
            end
            return
        end
        local info = M.parse(kind, payload, url)
        remember(url, info)
        if info and info.thumb then
            if owners_n >= INFO_MAX then owners, owners_n = {}, 0 end
            if owners[info.thumb] == nil then owners_n = owners_n + 1 end
            owners[info.thumb] = url
        end
        if info then ready(url) end
    end)
end

-- images.lua says a thumbnail's probe ended (sized, or unusable)
function M.thumb_settled(thumb)
    local url = owners[thumb]
    if url then ready(url) end
end

-- ----- the line -----

-- the elements to put under a line whose first link is `url`, or nil. nil also
-- means "not yet": an unseen url starts its fetch here, a known one with a
-- thumbnail waits for the thumbnail's size, and the back-pass redraws the line.
function M.elements_for(url)
    if not M.enabled() or type(url) ~= "string" then return nil end
    local info = infos[url]
    if info == nil then
        request(url)
        return nil
    end
    if info == false then return nil end
    if info.retry_at then
        if net.now() >= info.retry_at then
            infos[url] = nil
            request(url)
        end
        return nil
    end
    local link = { type = c2.LinkType.Url, value = url }
    local out = {}
    if info.thumb then
        local d, refused = images.size_of(info.thumb)
        if d == nil and not refused then return nil end -- size probe still out
        if d then
            local set = images.image_set(info.thumb, d, THUMB_H, THUMB_W)
            if set then
                out[#out + 1] = {
                    type = "scaling-image",
                    images = set,
                    flags = c2.MessageElementFlag.EmoteImage,
                    tooltip = M.TIP,
                    link = link,
                }
            end
        end
    end
    local label = info.title and (info.title .. " · " .. info.site) or info.site
    out[#out + 1] = { type = "text", text = label, color = "link", tooltip = M.TIP, link = link }
    return out
end

function M.stats()
    local known, out = 0, 0
    for _ in pairs(infos) do known = known + 1 end
    for _ in pairs(inflight) do out = out + 1 end
    return known, out
end

function M.clear()
    infos, ring, ring_pos, owners, owners_n = {}, {}, 0, {}, 0
    win_start, win_n = nil, 0
end

return M
