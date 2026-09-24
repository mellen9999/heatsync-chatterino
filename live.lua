-- opt-in live-status. the ws already broadcasts stream:online / stream:offline
-- (kick's are room-scoped to channels you've joined, i.e. multichat-linked), so
-- surface a go-live / went-offline system line in the twitch tab a kick/youtube
-- source is merged into. OFF by default (opt-in — it's a new surfaced signal).
--
-- twitch stream events are deliberately skipped: chatterino already shows twitch
-- live status natively, so echoing it would just be noise. the value here is
-- kick/youtube, which chatterino has no native status for.
local store = require("store")
local multichat = require("multichat")
local net = require("net")

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
    local line = (live and "🔴 " or "⚫ ") .. chan_disp .. (live and (" is live on " .. platform) or (" went offline on " .. platform))
    if live then
        local g = net.safe_text(game, 100)
        local t = net.safe_text(title, 140)
        line = line .. (g and (" · " .. g) or "") .. (t and (" · " .. t) or "")
    end
    for _, cc in ipairs(tabs) do
        pcall(function()
            local ch = c2.Channel.by_name(cc)
            if ch and ch:is_valid() then
                ch:add_system_message("[heatsync] " .. line)
            end
        end)
    end
end

-- handle a stream:online / stream:offline broadcast. returns true if it was a
-- stream event (so init can stop dispatching), regardless of whether a line was
-- shown — an event for an unlinked channel is still "handled" (ignored).
function M.handle(msg)
    local t = msg.type
    if t ~= "stream:online" and t ~= "stream:offline" then return false end

    local platform = norm_platform(tostring(msg.platform or ""))
    if platform ~= "kick" and platform ~= "yt" then return true end -- twitch = native
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
