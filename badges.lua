-- chatterino global badges on chatters (the ext shows these too). fetches the
-- public /api/chatterino-badges list once, maps twitch-user-id → badge, and
-- render.lua prepends the badge image before the username. OFF by default —
-- opt in with /hsbadges on.
local net = require("net")
local store = require("store")
local img = require("img")

local M = {}

-- map[twitch_user_id] = { url, tooltip }
local map = {}
local BADGE_H = 18 -- badges render smaller than emotes

function M.load()
    net.get_json(net.ORIGIN .. "/api/chatterino-badges", 10000, function(payload)
        if not payload or type(payload.badges) ~= "table" then return end
        local m = {}
        local groups = 0
        for _, b in ipairs(payload.badges) do
            local url = net.pick_first_str(b, "image1", "image2")
            local tip = net.pick_first_str(b, "tooltip") or "chatterino"
            if url and type(b.users) == "table" then
                groups = groups + 1
                for _, uid in ipairs(b.users) do
                    m[tostring(uid)] = { url = url, tooltip = tip }
                end
            end
        end
        map = m
        net.log_info("chatterino badges: " .. tostring(groups) .. " groups loaded")
    end)
end

-- cheap membership check for the render trigger (no image built)
function M.has(user_id)
    if not store.badges_enabled() then return false end
    return type(user_id) == "string" and user_id ~= "" and map[user_id] ~= nil
end

-- build the badge element for a twitch user id, or nil. image1 is ~18x26; the
-- 26 is a safe height assumption for these small badge PNGs.
function M.element_for(user_id)
    if not M.has(user_id) then return nil end
    local b = map[user_id]
    local set = img.for_url(b.url, nil, 26, BADGE_H)
    if not set then return nil end
    return {
        type = "scaling-image",
        images = set,
        flags = c2.MessageElementFlag.BadgeChatterino or c2.MessageElementFlag.Badges,
        tooltip = b.tooltip,
    }
end

return M
