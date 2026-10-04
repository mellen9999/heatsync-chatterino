-- the channel's heatsync pinned message, view-only. heatsync keeps one pin per
-- channel (twitch/kick) and fans pin:set / pin:clear out on the same
-- `<platform>/<channel>` room the plugin already joins, so showing it costs no
-- new subscription. GET /api/pin catches a pin that was set before we joined.
--
-- where it shows: a twitch room → that twitch tab; a kick room → every twitch tab
-- the kick source is merged into (tagged [K] like multichat lines).
--
-- pinning itself needs a heatsync login and the plugin socket is anonymous by
-- design, so there is deliberately no way to pin or unpin from here.
--
-- on (default) / off via /hspin. off still swallows the frames, shows nothing
-- and remembers nothing.
local store = require("store")
local multichat = require("multichat")
local net = require("net")
local ws = require("ws")

local M = {}

local MAX_CONTENT = 500
local MAX_NAME = 64
local MAX_TRACKED = 256 -- shown-pin memory is bounded; a reset only costs one repeat line

-- shown[tab .. "\1" .. room] = id of the pin last shown in that tab for that room
local shown = {}
local shown_n = 0

local function room_ok(platform, channel)
    return (platform == "twitch" or platform == "kick") and type(channel) == "string"
        and string.find(channel, "^[a-z0-9_-]+$") ~= nil and #channel <= 64
end

local function remember(key, id)
    if shown[key] == nil then
        if shown_n >= MAX_TRACKED then shown = {}; shown_n = 0 end
        shown_n = shown_n + 1
    end
    shown[key] = id
end

local function forget(key)
    if shown[key] ~= nil then shown[key] = nil; shown_n = shown_n - 1 end
end

-- tabs a room's pin belongs in
local function targets(platform, channel)
    if platform == "twitch" then return { channel } end
    return multichat.tabs_for("kick", channel)
end

local function tab_of(name)
    local ok, ch = pcall(c2.Channel.by_name, name)
    if ok and ch and ch:is_valid() then return ch end
    return nil
end

-- validate the untrusted server pin into a plain record, or nil
local function clean(pin)
    if type(pin) ~= "table" then return nil end
    local content = net.safe_text(pin.content, MAX_CONTENT)
    if not content then return nil end
    local login = net.safe_text(pin.username, MAX_NAME)
    local name = net.safe_text(pin.display_name, MAX_NAME) or login
    if not name then return nil end
    local id = pin.id
    if type(id) == "number" then id = tostring(id) end
    if type(id) ~= "string" or id == "" or #id > 80 then id = nil end
    local mid = pin.message_id
    if type(mid) ~= "string" or not string.find(mid, "^[A-Za-z0-9_-]+$") or #mid > 80 then mid = nil end
    local color = pin.color
    if type(color) ~= "string" or not string.find(color, "^#%x%x%x%x%x%x$") then color = nil end
    return { id = id or mid or content, mid = mid, name = name, login = string.lower(login or name),
        color = color, content = content }
end

-- the line: [K]? 📌 pinned · <name>: <content>. a real message so the name is a
-- username-style element and the content can jump to the original twitch line.
local function build(p, kick, mention)
    local elems = {}
    if kick then elems[#elems + 1] = { type = "text", text = "[K]", color = "#53fc18" } end
    elems[#elems + 1] = { type = "text", text = "📌 pinned", color = "#ff8700" }
    if mention then
        elems[#elems + 1] = { type = "mention", display_name = p.name .. ":", login_name = p.login,
            fallback_color = p.color or "#ffffff", user_color = p.color or "#ffffff", trailing_space = true }
    else
        elems[#elems + 1] = { type = "text", text = p.name .. ":", color = p.color,
            flags = c2.MessageElementFlag and c2.MessageElementFlag.Username }
    end
    local body = { type = "text", text = p.content }
    if not kick and p.mid and c2.LinkType and c2.LinkType.JumpToMessage then
        body.link = { type = c2.LinkType.JumpToMessage, value = p.mid }
    end
    elems[#elems + 1] = body
    local text = "📌 " .. p.name .. ": " .. p.content
    return {
        login_name = p.login, display_name = p.name, message_text = text, search_text = text,
        username_color = p.color, flags = c2.MessageFlag and c2.MessageFlag.System, elements = elems,
    }
end

local function add_line(ch, p, kick)
    -- richest shape first; each failure steps down, the last step can't be missing
    for _, mention in ipairs({ true, false }) do
        if pcall(function() ch:add_message(net.new_message(build(p, kick, mention))) end) then return end
    end
    pcall(function()
        ch:add_system_message("[heatsync] " .. (kick and "[K] " or "") .. "📌 " .. p.name .. ": " .. p.content)
    end)
end

local function show(platform, channel, pin)
    if not store.pin_enabled() or not room_ok(platform, channel) then return end
    local p = clean(pin)
    if not p then return end
    for _, tab in ipairs(targets(platform, channel)) do
        local key = tab .. "\1" .. platform .. "/" .. channel
        local ch = tab_of(tab)
        if ch and shown[key] ~= p.id then
            remember(key, p.id)
            add_line(ch, p, platform == "kick")
        end
    end
end

local function cleared(platform, channel)
    if not store.pin_enabled() or not room_ok(platform, channel) then return end
    for _, tab in ipairs(targets(platform, channel)) do
        local key = tab .. "\1" .. platform .. "/" .. channel
        local ch = tab_of(tab)
        if ch and shown[key] ~= nil then
            forget(key)
            pcall(function()
                ch:add_system_message("[heatsync] " .. (platform == "kick" and "[K] " or "") .. "📌 pin cleared")
            end)
        end
    end
end

-- pin:set / pin:clear from the ws. true = ours (init stops dispatching), shown or not.
function M.handle(msg)
    local t = msg.type
    if t ~= "pin:set" and t ~= "pin:clear" then return false end
    local ok, err = pcall(function()
        local platform = msg.platform
        local channel = type(msg.channel) == "string" and string.lower(msg.channel) or nil
        if t == "pin:set" then show(platform, channel, msg.pin) else cleared(platform, channel) end
    end)
    if not ok then net.log_warn("pin frame failed: " .. tostring(err)) end
    return true
end

-- GET /api/pin for one room; shows the pin if there is one (same dedupe as the ws)
function M.fetch(platform, channel)
    if not store.pin_enabled() then return end
    if type(channel) ~= "string" then return end
    channel = string.lower(channel)
    if not room_ok(platform, channel) then return end
    net.get_json(net.ORIGIN .. "/api/pin?platform=" .. platform .. "&channel=" .. net.percent_encode(channel), 8000,
        function(payload)
            if type(payload) == "table" and payload.pin ~= nil then show(platform, channel, payload.pin) end
        end)
end

-- re-fetch joined rooms (a long ws gap may have missed a pin:set). kick_only is the
-- first-connect case: twitch tabs fetched themselves on open, persisted kick links didn't.
function M.refetch(kick_only)
    for _, r in ipairs(ws.joined_rooms()) do
        if not kick_only or r.platform == "kick" then pcall(M.fetch, r.platform, r.channel) end
    end
end

return M
