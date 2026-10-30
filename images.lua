-- inline image embeds (opt-in, /hsimages on): a chat line whose FIRST link is an
-- https image shows that image below the text, the way the extension does
-- (multichat/feed-embed.js chatEmbedForUrl). the original link text stays; the
-- image is a click-through to the ORIGINAL url.
--
-- privacy: the third-party url is NEVER loaded directly. both the size probe and
-- the displayed image go through heatsync's proxy, GET /api/img?url=<enc>
-- (ssrf-guarded, moderation-scanned, https only, 302 to a hosted copy, 403 on a
-- moderation block, 413 too large), so the viewer's ip never reaches the image
-- host. every new url costs heatsync a scan, so: opt-in, dedup by url, and at
-- most PER_MIN new urls a minute — past that a link just stays a link.
--
-- sizing: chatterino loads an image lazily (only once painted) and a plugin has
-- no post-load resize hook, so an unmeasured image would land at full size. the
-- proxy always serves a re-encoded webp, whose header (first few bytes) carries
-- the dimensions: one small Range GET reads them, the message is untouched until
-- they land, then render.lua rebuilds it with an image scaled to a chat-sized box.
-- img.lua's allowlist already covers heatsync.org, so it needs no widening.
local net = require("net")
local caps = require("caps")
local store = require("store")
local img = require("img")

local M = {}

-- tooltip on the element we draw: how a later pass recognises its own image
-- (deliberately NOT the " · heatsync" suffix menu.lua reads as an emote name)
M.TIP = "image via heatsync"

local MAX_URL = 2048   -- same cap as the server route
local MAX_H = 220      -- display box, matches the extension's max-height
local MAX_W = 400
local PER_MIN = 20     -- new distinct urls per minute
local WINDOW_S = 60
local DIMS_MAX = 300   -- remembered sizes (and failures), circular
local MARK_MAX = 500
local RANGE_BYTES = 65536

local EXTS = { png = true, jpg = true, jpeg = true, gif = true, webp = true, avif = true }

-- ----- detection (pure) -----

-- sentence punctuation off the end, but a trailing ) or ] only when it's
-- unbalanced, so .../Foo_(bar).png keeps its paren (the extension's rule)
local function trim_url(u)
    u = string.gsub(u, "[%.,;!?]+$", "")
    while true do
        local last = string.sub(u, -1)
        if last ~= ")" and last ~= "]" then break end
        local _, opens = string.gsub(u, "[%(%[]", "")
        local _, closes = string.gsub(u, "[%)%]]", "")
        if closes <= opens then break end
        u = string.gsub(string.sub(u, 1, -2), "[%.,;!?]+$", "")
    end
    return u
end

local function own_origin(host)
    return host == "heatsync.org" or host == "localhost"
        or string.sub(host, -13) == ".heatsync.org"
end

-- the first link in a message as a vetted https url, or nil: it must be https,
-- not heatsync's own origin, no userinfo / ip literal / dotless host, within the
-- length cap, trailing sentence punctuation trimmed. shared with previews.lua
-- (which previews the first link when it is NOT an image).
function M.first_link(text)
    if type(text) ~= "string" or #text < 12 then return nil end
    if not string.find(text, "://", 1, true) then return nil end
    local start = string.find(string.lower(text), "https?://")
    if not start then return nil end
    local raw = string.match(text, "^[^%s<>\"']+", start)
    if not raw or #raw > MAX_URL + 64 then return nil end
    local rest = string.match(raw, "^%a+://(.*)$")
    if not rest or string.lower(string.sub(raw, 1, 5)) ~= "https" then return nil end
    local url = "https://" .. trim_url(rest)
    if #url > MAX_URL or string.find(url, "%c") then return nil end
    local authority = string.match(url, "^https://([^/?#]*)")
    -- userinfo is the classic host-confusion trick; a real link never has it
    if not authority or authority == "" or string.find(authority, "@", 1, true) then return nil end
    local host = string.lower(string.match(authority, "^([^:]+)") or "")
    if not string.match(host, "^[%w%.%-]+$") or not string.find(host, ".", 1, true)
        or string.match(host, "^%d+%.%d+%.%d+%.%d+$") or own_origin(host) then
        return nil
    end
    return url
end

-- the image url a message would embed, or nil. only the FIRST link counts (the
-- extension's rule): it must be a direct image by extension (query and fragment
-- ignored) on top of everything first_link checks.
function M.detect(text)
    local url = M.first_link(text)
    if not url then return nil end
    local authority = string.match(url, "^https://([^/?#]*)")
    local path = string.match(string.sub(url, 9 + #authority), "^[^?#]*")
    local ext = string.match(path, "%.(%w+)$")
    if not ext or not EXTS[string.lower(ext)] then return nil end
    return url
end

function M.proxy_url(url)
    return net.ORIGIN .. "/api/img?url=" .. net.percent_encode(url)
end

-- width,height from a webp header (VP8 / VP8L / VP8X, which covers animated
-- too — the proxy always re-encodes to webp), or nil. never throws.
function M.webp_size(b)
    if type(b) ~= "string" or #b < 30 then return nil end
    if string.sub(b, 1, 4) ~= "RIFF" or string.sub(b, 9, 12) ~= "WEBP" then return nil end
    local kind = string.sub(b, 13, 16)
    local w, h
    if kind == "VP8X" then
        w = string.unpack("<I3", b, 25) + 1
        h = string.unpack("<I3", b, 28) + 1
    elseif kind == "VP8 " then
        if string.sub(b, 24, 26) ~= "\157\1\42" then return nil end
        w = string.unpack("<I2", b, 27) & 0x3fff
        h = string.unpack("<I2", b, 29) & 0x3fff
    elseif kind == "VP8L" then
        if string.byte(b, 21) ~= 0x2f then return nil end
        local bits = string.unpack("<I4", b, 22)
        w = (bits & 0x3fff) + 1
        h = ((bits >> 14) & 0x3fff) + 1
    else
        return nil
    end
    if w < 1 or h < 1 or w > 16384 or h > 16384 then return nil end
    return w, h
end

-- ----- state -----

local dims = {}      -- url -> { w, h } | false (unusable: blocked, too large, not an image)
local dims_ring = {}
local dims_pos = 0
local inflight = {}  -- url -> true while its size probe is out
local win_start, win_n = nil, 0
local marks, mark_ring, mark_pos = {}, {}, 0

local function remember(url, v)
    dims[url] = v
    local slot = (dims_pos % DIMS_MAX) + 1
    local evicted = dims_ring[slot]
    if evicted ~= nil then dims[evicted] = nil end
    dims_ring[slot] = url
    dims_pos = dims_pos + 1
end

-- messages already given an image (by id), so a back-pass can't stack a second
function M.mark(id)
    if type(id) ~= "string" or id == "" or marks[id] then return end
    marks[id] = true
    local slot = (mark_pos % MARK_MAX) + 1
    local evicted = mark_ring[slot]
    if evicted ~= nil then marks[evicted] = nil end
    mark_ring[slot] = id
    mark_pos = mark_pos + 1
end

function M.marked(id)
    return type(id) == "string" and marks[id] == true
end

function M.enabled()
    return store.images_enabled() and caps.images and caps.tier >= 2
end

local function take_budget()
    local now = net.now()
    if not win_start or now - win_start >= WINDOW_S then win_start, win_n = now, 0 end
    if win_n >= PER_MIN then return false end
    win_n = win_n + 1
    return true
end

-- fired (url) when a size lands; render.lua rebuilds the lines carrying it
M.on_loaded = nil

-- fired (url) when a probe ends for good — a size landed OR the image is
-- unusable — so previews.lua can draw its line either way
M.on_settled = nil

local function settle(url)
    if M.on_settled then pcall(M.on_settled, url) end
end

-- starts a size probe unless one is out or the per-minute budget is spent.
-- returns false only when the budget refused it.
local function probe(url)
    if inflight[url] then return true end
    if not take_budget() then return false end
    inflight[url] = true
    net.get_raw(M.proxy_url(url), { Range = "bytes=0-" .. (RANGE_BYTES - 1) }, 12000, function(body, err, status)
        inflight[url] = nil
        local w, h = M.webp_size(body)
        if w then
            remember(url, { w, h })
            if M.on_loaded then pcall(M.on_loaded, url) end
            settle(url)
            return
        end
        -- a timeout / 429 / 5xx says nothing about the image: forget, a later
        -- line may try again (still inside the per-minute cap). everything else
        -- (403 moderation block, 413, 4xx, a non-webp body) is final.
        if status == nil or status == 429 or status >= 500 then
            net.log_info("image probe failed: " .. tostring(err))
            return
        end
        remember(url, false)
        settle(url)
    end)
    return true
end

-- display height for an image of w x h inside a max_w x max_h box (never enlarged)
local function display_height(w, h, max_h, max_w)
    local th = math.min(h, max_h or MAX_H)
    if w * th / h > (max_w or MAX_W) then th = (max_w or MAX_W) * h / w end
    return th
end

-- the remembered size of an image url, starting its probe when unseen:
--   {w, h}  known            false  unusable (blocked, too large, not an image)
--   nil, false  probe is out / just started       nil, true  budget refused it
-- no toggle check here: callers (inline images, previews) gate themselves.
function M.size_of(url)
    local d = dims[url]
    if d ~= nil then return d end
    return nil, not probe(url)
end

-- the ImageSet for a sized url through the proxy, scaled into a max_w x max_h box
function M.image_set(url, d, max_h, max_w)
    return img.for_url(M.proxy_url(url), d[1], d[2], display_height(d[1], d[2], max_h, max_w))
end

-- the image element for a detected url, or nil. nil also means "not yet": an
-- unseen url starts its size probe here and gets its image on the back-pass.
function M.element_for(url)
    if not M.enabled() or type(url) ~= "string" then return nil end
    local d = M.size_of(url)
    if not d then return nil end
    local set = M.image_set(url, d)
    if not set then return nil end
    return {
        type = "scaling-image",
        images = set,
        flags = c2.MessageElementFlag.EmoteImage,
        tooltip = M.TIP,
        link = { type = c2.LinkType.Url, value = url },
    }
end

function M.stats()
    local known, out = 0, 0
    for _ in pairs(dims) do known = known + 1 end
    for _ in pairs(inflight) do out = out + 1 end
    return known, out
end

function M.clear()
    dims, dims_ring, dims_pos = {}, {}, 0
    win_start, win_n = nil, 0
end

return M
