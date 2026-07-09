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
        local total_uids = 0
        -- this fetch runs at boot regardless of the /hsbadges opt-in, so bound it
        -- against a hostile /api/chatterino-badges response: cap groups + total
        -- mapped user ids so a giant users[] array can't blow the map.
        for gi, b in ipairs(payload.badges) do
            if gi > 200 or total_uids >= 20000 then break end
            local url = net.pick_first_str(b, "image1", "image2")
            local tip = net.safe_text(net.pick_first_str(b, "tooltip"), 100) or "chatterino"
            if net.is_safe_url(url) and type(b.users) == "table" then
                groups = groups + 1
                for _, uid in ipairs(b.users) do
                    if total_uids >= 20000 then break end
                    m[tostring(uid)] = { url = url, tooltip = tip }
                    total_uids = total_uids + 1
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
