-- shared image-set builder + LRU cache. used by render (hs emotes) and
-- multichat (kick/youtube emotes). scales a source image down to twitch's
-- ~28px line height using its known dimensions; without dims it returns nil
-- so the caller falls back to text (a raw image could be 1000px tall and
-- there's no post-load resize hook).
local M = {}

local sets = {}       -- url -> c2.ImageSet
local order = {}      -- fifo for eviction
local MAX = 400
local TARGET_H = 28

function M.for_url(url, w, h)
    if type(url) ~= "string" or url == "" then return nil end
    local set = sets[url]
    if set then return set end
    if not h or h <= 0 then return nil end
    local scale = TARGET_H / h
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
    sets[url] = built
    order[#order + 1] = url
    while #order > MAX do
        local oldest = table.remove(order, 1)
        if oldest then sets[oldest] = nil end
    end
    return built
end

return M
