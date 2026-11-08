-- opt-in live-status. the ws already broadcasts stream:online / stream:offline /
-- stream:update (game or title switch)
-- (kick's are room-scoped to channels you've joined, i.e. multichat-linked), so
-- surface a go-live / went-offline system line in the twitch tab a kick/youtube
-- source is merged into. OFF by default (opt-in — it's a new surfaced signal).
--
-- twitch go-live / offline events are deliberately skipped: chatterino already
-- shows twitch live status natively, so echoing it would just be noise. what
-- chatterino does NOT show natively is a twitch game or title change, so a twitch
-- stream:update is surfaced as the same 🎮 / 📝 line in that channel's own open
-- tab. it needs nothing extra: every open twitch tab is already joined to its
-- anonymous twitch/<login> room (render.on_channel_found), which is where the
-- server sends these. one toggle (/hslive) covers every stream-state line.
local store = require("store")
local multichat = require("multichat")
local net = require("net")
local rows = require("rows")
local brand = require("brand")

local M = {}

-- the server tags youtube events as "youtube"; multichat keys them as "yt"
local function norm_platform(p)
    if p == "youtube" then return "yt" end
    return p
end

-- shared line-builder: a go-live/offline system line in every tab a
-- (platform, channel) source is merged into. gated on the opt-in toggle here
-- so every caller (stream:* and youtube:status) gets it for free.
local function emit(platform, channel, live, game, title)
    if not store.live_enabled() then return end
    if type(channel) ~= "string" or channel == "" then return end

    -- only for a source the user actually merged into a tab
    local tabs = multichat.tabs_for(platform, string.lower(channel))
    if #tabs == 0 then return end

    -- the server/ws is untrusted: clamp every field spliced into the system line
    -- (control-byte-free + length-capped) so a flood of megabyte-scale titles
    -- can't grow scrollback allocations unbounded.
    local chan_disp = net.safe_text(channel, 100) or channel
    local label = live and "🔴" or "⚫"
    local lcolor = live and brand.palette.yellow or brand.palette.white
    local line = chan_disp .. (live and (" is live on " .. platform) or (" went offline on " .. platform))
    if live then
        local g = net.safe_text(game, 100)
        local t = net.safe_text(title, 140)
        line = line .. (g and (" · " .. g) or "") .. (t and (" · " .. t) or "")
    end
    for _, cc in ipairs(tabs) do
        pcall(function()
            local ch = c2.Channel.by_name(cc)
            if ch and ch:is_valid() then
                rows.add(ch, "olive", label, lcolor, line)
            end
        end)
    end
end

-- the tabs a (platform, channel) update belongs in: a merged source's linked
-- tabs, or for twitch the channel's own tab (named by its login). only a tab that
-- is really a twitch channel counts, so a same-named other split never gets it.
local function tabs_for(platform, channel)
    if platform ~= "twitch" then return multichat.tabs_for(platform, channel) end
    if not string.match(channel, "^[a-z0-9_]+$") then return {} end
    local ok, is_tw = pcall(function()
        local ch = c2.Channel.by_name(channel)
        if not (ch and ch:is_valid()) then return false end
        return ch:is_twitch_channel() ~= false
    end)
    return (ok and is_tw) and { channel } or {}
end

-- last game/title shown per source, so a re-emit of the same update (the server
-- reconciles) doesn't repeat the line. bounded; a reset costs one repeat.
local last_update = {}
local last_update_n = 0
local MAX_TRACKED = 256

-- stream:update for a linked source: 🎮 on a game change (title appended when it
-- changed too), 📝 on a title-only change. same opt-in + linked-tab gating as emit().
local function emit_update(platform, msg)
    if not store.live_enabled() then return end
    local channel = msg.channel
    if type(channel) ~= "string" or channel == "" or #channel > 100 then return end
    local game, title = net.safe_text(msg.game, 100), net.safe_text(msg.title, 140)
    local game_changed = game ~= nil and msg.game ~= msg.prevGame
    local title_changed = title ~= nil and msg.title ~= msg.prevTitle
    if not game_changed and not title_changed then return end
    local tabs = tabs_for(platform, string.lower(channel))
    if #tabs == 0 then return end
    local key = platform .. "/" .. string.lower(channel)
    local sig = tostring(game) .. "\1" .. tostring(title)
    if last_update[key] == sig then return end
    if last_update[key] == nil then
        if last_update_n >= MAX_TRACKED then last_update = {}; last_update_n = 0 end
        last_update_n = last_update_n + 1
    end
    last_update[key] = sig
    local chan_disp = net.safe_text(channel, 100) or channel
    local label, line = "📝", nil
    if game_changed then
        label = "🎮"
        line = chan_disp .. " switched to " .. game .. (title_changed and (" · " .. title) or "")
    else
        line = chan_disp .. " · " .. title
    end
    for _, cc in ipairs(tabs) do
        pcall(function()
            local ch = c2.Channel.by_name(cc)
            if ch and ch:is_valid() then rows.add(ch, "olive", label, brand.palette.yellow, line) end
        end)
    end
end

-- handle a stream:online / stream:offline / stream:update broadcast. returns true if it was a
-- stream event (so init can stop dispatching), regardless of whether a line was
-- shown — an event for an unlinked channel is still "handled" (ignored).
function M.handle(msg)
    local t = msg.type
    if t ~= "stream:online" and t ~= "stream:offline" and t ~= "stream:update" then return false end

    local platform = norm_platform(tostring(msg.platform or ""))
    if platform == "twitch" then
        -- go-live / offline = native; only a game/title change adds anything
        if t == "stream:update" then pcall(emit_update, platform, msg) end
        return true
    end
    if platform ~= "kick" and platform ~= "yt" then return true end
    if t == "stream:update" then
        pcall(emit_update, platform, msg)
        return true
    end
    emit(platform, msg.channel, t == "stream:online", msg.game, msg.title)
    return true
end

-- youtube never emits stream:online/offline — its own status taxonomy
-- (connected/ended/not-live/chat-off/no-slot, ws-protocol.ts YouTubeLegStatus)
-- is multichat's to surface as a status line; this is only the two statuses
-- that map onto the same go-live/offline signal stream:* gives kick/twitch.
-- called directly by multichat.lua (M.on_youtube_status, wired in init.lua) on
-- every status CHANGE for a linked source — never required back from
-- multichat.lua, which would be circular (it already requires this module).
function M.youtube_status(tag, status)
    if status ~= "connected" and status ~= "ended" then return end
    emit("yt", tag, status == "connected")
end

return M
