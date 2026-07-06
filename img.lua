-- shared image-set builder + LRU cache. used by render (hs emotes) and
-- multichat (kick/youtube emotes). scales a source image down to twitch's
-- ~28px line height using its known dimensions; without dims it returns nil
-- so the caller falls back to text (a raw image could be 1000px tall and
-- there's no post-load resize hook).
local M = {}

local sets = {}       -- key -> c2.ImageSet
local order = {}      -- fifo for eviction
local MAX = 400
local TARGET_H = 28   -- twitch 1x emote line height

-- target_h defaults to emote height (28); badges pass ~18. keyed by url+target
-- so the same image can be cached at two display sizes without collision.
function M.for_url(url, w, h, target_h)
    if type(url) ~= "string" or url == "" then return nil end
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
    order[#order + 1] = key
    while #order > MAX do
        local oldest = table.remove(order, 1)
        if oldest then sets[oldest] = nil end
    end
    return built
end

return M
