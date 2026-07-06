-- multichat: pull Kick + YouTube live chat from heatsync.org and inject it
-- into a chatterino (twitch) tab, tagged [K]/[Y]. chatterino has no native
-- Kick/YouTube — this makes heatsync the cross-platform chat layer inside it.
-- the data flows through heatsync's WS (which already ingests kick+yt chat),
-- so nothing here is reusable without heatsync.
--
-- model: `/hsmulti kick:<slug>` in a twitch tab LINKS that source's chat into
-- the current chatterino channel; an incoming line is injected via
-- Channel:add_message into every chatterino channel it's linked to.
--
-- WS contract (verified against server 2026-07):
--   kick sub   → channel:join {platform:kick, channel:slug}  (rides ws.join,
--                so it auto-replays on reconnect)
--   kick live  → kick-chat-message { data:{channel,username,displayName,
--                content,color,id,timestamp,...} }
--   kick hist  → kick-chat-backfill { channel, messages:[<same data>...] }
--   yt sub     → youtube:subscribe {url:<handle|url>, channelId:<routing tag>}
--                (channelId is echoed back on every youtube:chat → we route on
--                it; the channel must be LIVE or subscribe errors)
--   yt live+hist → youtube:chat { channelId, messages:[{id,user,text,emotes,
--                timestamp,color,amount,systemMsg,...}], replay? }
--   yt status  → youtube:status { videoId, status, error?, channelId }
local net = require("net")
local ws = require("ws")
local img = require("img")
local caps = require("caps")

local M = {}

local LINKS_FILE = "multichat.txt"
local KICK_COLOR = "#53fc18"
local YT_COLOR = "#ff0000"
local DEDUP_MAX = 800
-- kick emotes come embedded in the text as [emote:<id>:<name>] tokens and are
-- a fixed 70x70 png/gif at this CDN path (verified — no size variants).
local KICK_EMOTE_URL = "https://files.kick.com/emotes/%s/fullsize"

-- split a kick message body on [emote:id:name] tokens into text runs +
-- scaling-image emotes. returns nil if there are no emote tokens (caller uses
-- a single plain-text element) — keeps the common path allocation-free.
local function build_kick_body(content)
    if type(content) ~= "string" or not content:find("[emote:", 1, true) then return nil end
    local elems = {}
    local last = 1
    local found = false
    for s, id, name, e in content:gmatch("()%[emote:(%d+):([^%]]+)%]()") do
        found = true
        if s > last then
            local pre = content:sub(last, s - 1)
            if pre ~= "" then elems[#elems + 1] = { type = "text", text = pre } end
        end
        local set = caps.images and img.for_url(string.format(KICK_EMOTE_URL, id), 70, 70) or nil
        if set then
            elems[#elems + 1] = { type = "scaling-image", images = set,
                flags = c2.MessageElementFlag.EmoteImage, tooltip = name .. " · kick" }
        else
            elems[#elems + 1] = { type = "text", text = name }
        end
        last = e
    end
    if not found then return nil end
    local tail = content:sub(last)
    if tail ~= "" then elems[#elems + 1] = { type = "text", text = tail } end
    return elems
end

-- links[cc_name] = { [source_key] = { platform=, channel= } }
-- source_key = "kick/<slug>" | "yt/<routing-tag>"
local links = {}
-- routes[source_key] = { [cc_name]=true }  (O(1) inject routing)
local routes = {}
-- yt_video[routing_tag] = videoId  (learned from youtube:status, for unsub)
local yt_video = {}
-- dedup seen ids (fifo)
local seen = {}
local seen_order = {}

local function source_key(platform, channel)
    return platform .. "/" .. string.lower(channel)
end

local function add_route(key, cc_name)
    routes[key] = routes[key] or {}
    routes[key][cc_name] = true
end

local function drop_route(key, cc_name)
    if routes[key] then
        routes[key][cc_name] = nil
        if next(routes[key]) == nil then routes[key] = nil end
    end
end

-- ----- WS subscribe/unsubscribe -----
local function subscribe(platform, channel)
    if platform == "kick" then
        ws.join("kick", channel) -- reuses channel:join + reconnect replay
    elseif platform == "yt" then
        -- channelId is an opaque routing tag echoed back on youtube:chat
        ws.send({ type = "youtube:subscribe", url = channel, channelId = string.lower(channel) })
    end
end

local function unsubscribe(platform, channel)
    if platform == "kick" then
        ws.leave("kick", channel)
    elseif platform == "yt" then
        local vid = yt_video[string.lower(channel)]
        if vid then ws.send({ type = "youtube:unsubscribe", videoId = vid }) end
        -- no videoId yet → the server poller ref-counts + reaps on drop anyway
    end
end

-- ----- persistence -----
local function persist()
    local lines = {}
    for cc_name, srcs in pairs(links) do
        for _, s in pairs(srcs) do
            lines[#lines + 1] = cc_name .. "\t" .. s.platform .. "\t" .. s.channel
        end
    end
    net.write_data(LINKS_FILE, table.concat(lines, "\n"))
end

-- ----- dedup -----
local function is_dup(id)
    if type(id) ~= "string" or id == "" then return false end
    if seen[id] then return true end
    seen[id] = true
    seen_order[#seen_order + 1] = id
    while #seen_order > DEDUP_MAX do
        local old = table.remove(seen_order, 1)
        if old then seen[old] = nil end
    end
    return false
end

-- ----- linking -----
function M.link(cc_name, platform, channel)
    if type(cc_name) ~= "string" or cc_name == "" then return false end
    if type(channel) ~= "string" or channel == "" then return false end
    local key = source_key(platform, channel)
    links[cc_name] = links[cc_name] or {}
    if links[cc_name][key] then return false end
    links[cc_name][key] = { platform = platform, channel = string.lower(channel) }
    add_route(key, cc_name)
    persist()
    subscribe(platform, string.lower(channel))
    return true
end

-- unlink one source, or ALL sources for a tab if platform is nil
function M.unlink(cc_name, platform, channel)
    if not links[cc_name] then return 0 end
    local removed = 0
    local function drop(key, s)
        drop_route(key, cc_name)
        if not routes[key] then unsubscribe(s.platform, s.channel) end
        removed = removed + 1
    end
    if platform then
        local key = source_key(platform, channel)
        local s = links[cc_name][key]
        if s then links[cc_name][key] = nil; drop(key, s) end
    else
        for key, s in pairs(links[cc_name]) do
            links[cc_name][key] = nil
            drop(key, s)
        end
    end
    if links[cc_name] and next(links[cc_name]) == nil then links[cc_name] = nil end
    persist()
    return removed
end

function M.list(cc_name)
    local out = {}
    if links[cc_name] then
        for key in pairs(links[cc_name]) do out[#out + 1] = key end
        table.sort(out)
    end
    return out
end

-- called whenever the ws comes up (first connect after disk-load AND every
-- reconnect, via ws.on_reconnect). subscribes every linked source. kick joins
-- are idempotent (ws.join no-ops if already in the replayed set); yt always
-- needs an explicit re-subscribe (pollers are per-video, not replayed).
function M.on_ws_up()
    for _, srcs in pairs(links) do
        for _, s in pairs(srcs) do subscribe(s.platform, s.channel) end
    end
end

-- ----- injection -----
local function inject(line)
    local key = source_key(line.platform, line.channel)
    local targets = routes[key]
    if not targets then return end
    if is_dup(line.id) then return end
    local text = line.text
    if type(text) ~= "string" or text == "" then return end
    local display = line.display
    if type(display) ~= "string" or display == "" then display = line.username or "?" end
    local tag = line.platform == "kick" and "[K]" or "[Y]"
    local tag_color = line.platform == "kick" and KICK_COLOR or YT_COLOR
    local uname_color = (type(line.color) == "string" and line.color ~= "") and line.color or tag_color
    -- render kick's [emote:id:name] tokens as images (70x70 → chat height)
    local body = line.platform == "kick" and build_kick_body(text) or nil

    for cc_name in pairs(targets) do
        pcall(function()
            local ch = c2.Channel.by_name(cc_name)
            if not ch or not ch:is_valid() then return end
            local elems = {}
            if type(line.time_ms) == "number" and line.time_ms > 0 then
                elems[#elems + 1] = { type = "timestamp", time = line.time_ms }
            end
            elems[#elems + 1] = { type = "text", text = tag, color = tag_color }
            elems[#elems + 1] = {
                type = "text",
                text = display .. ":",
                color = uname_color,
                flags = c2.MessageElementFlag.Username,
            }
            if body then
                for _, be in ipairs(body) do elems[#elems + 1] = be end
            else
                elems[#elems + 1] = { type = "text", text = text }
            end
            ch:add_message(c2.Message.new({
                login_name = string.lower(line.username or display),
                display_name = display,
                message_text = text,
                search_text = text,
                username_color = uname_color,
                elements = elems,
            }))
        end)
    end
end

-- ----- WS dispatch (called from init's event handler) -----
local function handle_kick(d)
    if type(d) ~= "table" then return end
    inject({
        platform = "kick",
        channel = d.channel,
        id = d.id,
        username = d.username,
        display = d.displayName,
        text = d.content,
        color = d.color,
        time_ms = tonumber(d.timestamp),
    })
end

local function handle_yt(m, routing_tag)
    if type(m) ~= "table" then return end
    -- superchat: prefix the amount; membership/gift: fall back to systemMsg
    local text = m.text
    if type(m.amount) == "string" and m.amount ~= "" then
        text = m.amount .. " " .. (text or "")
    elseif (not text or text == "") and type(m.systemMsg) == "string" then
        text = m.systemMsg
    end
    inject({
        platform = "yt",
        channel = routing_tag,
        id = m.id,
        username = m.user,
        display = m.user,
        text = text,
        color = m.color,
        time_ms = tonumber(m.timestamp),
    })
end

-- returns true if the message was a multichat message (handled)
function M.dispatch(msg)
    local t = msg.type
    if t == "kick-chat-message" then
        handle_kick(msg.data)
        return true
    elseif t == "kick-chat-backfill" then
        if type(msg.messages) == "table" then
            for _, d in ipairs(msg.messages) do handle_kick(d) end
        end
        return true
    elseif t == "youtube:chat" then
        local tag = msg.channelId
        if type(tag) ~= "string" or tag == "" then return true end
        if type(msg.messages) == "table" then
            for _, m in ipairs(msg.messages) do handle_yt(m, tag) end
        end
        return true
    elseif t == "youtube:status" then
        local tag = type(msg.channelId) == "string" and string.lower(msg.channelId) or nil
        if msg.status == "connected" and tag and type(msg.videoId) == "string" then
            yt_video[tag] = msg.videoId
        elseif msg.status == "error" then
            net.log_warn("multichat youtube: " .. tostring(msg.error))
        end
        return true
    end
    return false
end

-- load persisted links at boot; re-subscribe on ws connect
function M.load()
    local raw = net.read_data(LINKS_FILE)
    if type(raw) ~= "string" then return end
    for cc_name, platform, channel in string.gmatch(raw, "([^\t\r\n]+)\t([^\t\r\n]+)\t([^\t\r\n]+)") do
        local key = source_key(platform, channel)
        links[cc_name] = links[cc_name] or {}
        links[cc_name][key] = { platform = platform, channel = string.lower(channel) }
        add_route(key, cc_name)
    end
end

function M.stats()
    local n = 0
    for _, srcs in pairs(links) do
        for _ in pairs(srcs) do n = n + 1 end
    end
    return n
end

return M
