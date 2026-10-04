-- opt-in moment spikes. the server broadcasts moment:spike to EVERY socket when a
-- chat spikes far above its own baseline; the plugin shows it only in a tab the
-- user already has open (twitch tab, or the twitch tab a kick/youtube source is
-- merged into, tagged [K]/[Y]) and stays silent for everything else. OFF by
-- default (/hsmoments on). at most one line per channel per 5 minutes so a
-- sustained spike doesn't stripe the tab.
local store = require("store")
local multichat = require("multichat")
local net = require("net")

local M = {}

local THROTTLE_S = 300
local MAX_TRACKED = 256
local TAG = { kick = "[K] ", yt = "[Y] " }

local last_shown = {} -- "platform/channel" -> net.now() of the last line
local tracked = 0

local function num(v)
    return type(v) == "number" and v == v and v >= 0 and v < math.huge and v or nil
end

local function tabs_for(platform, channel)
    if platform == "twitch" then
        if not string.find(channel, "^[a-z0-9_]+$") or #channel > 40 then return {} end
        return { channel }
    end
    return multichat.tabs_for(platform, channel)
end

local function add_line(ch, text, url)
    if url then
        local ok = pcall(function()
            ch:add_message(net.new_message({
                flags = c2.MessageFlag and c2.MessageFlag.System,
                message_text = text, search_text = text,
                elements = { { type = "text", text = text, color = "link",
                    link = { type = c2.LinkType.Url, value = url }, tooltip = url } },
            }))
        end)
        if ok then return end
    end
    pcall(function() ch:add_system_message(text) end)
end

-- returns true for moment:spike (shown or not) so init stops dispatching
function M.handle(msg)
    if msg.type ~= "moment:spike" then return false end
    if not store.spikes_enabled() then return true end
    pcall(function()
        local platform = msg.platform == "youtube" and "yt" or msg.platform
        if platform ~= "twitch" and platform ~= "kick" and platform ~= "yt" then return end
        if type(msg.channel) ~= "string" or msg.channel == "" or #msg.channel > 100 then return end
        local channel = string.lower(msg.channel)
        local rate, base = num(msg.rate), num(msg.baseline)
        if not rate then return end
        local key = platform .. "/" .. channel
        local now = net.now()
        if last_shown[key] and (now - last_shown[key]) < THROTTLE_S then return end

        local line = "[heatsync] " .. (TAG[platform] or "") .. "🔥 moment · " .. string.format("%d", math.floor(rate)) .. " msgs/30s"
        if base and base > 0 then line = line .. string.format(", %.1f× the usual", rate / base) end
        local game, title = net.safe_text(msg.game, 100), net.safe_text(msg.title, 140)
        if game then line = line .. " · " .. game end
        if title then line = line .. " · " .. title end
        local id = msg.id
        if type(id) == "number" then id = string.format("%d", id) end
        local url = type(id) == "string" and string.find(id, "^[A-Za-z0-9_-]+$") and #id <= 40
            and (net.ORIGIN .. "/moment/" .. id) or nil

        local shown = false
        for _, tab in ipairs(tabs_for(platform, channel)) do
            local ok, ch = pcall(c2.Channel.by_name, tab)
            if ok and ch and ch:is_valid() then
                add_line(ch, line, url)
                shown = true
            end
        end
        if shown then
            if last_shown[key] == nil then
                if tracked >= MAX_TRACKED then last_shown = {}; tracked = 0 end
                tracked = tracked + 1
            end
            last_shown[key] = now
        end
    end)
    return true
end

return M
