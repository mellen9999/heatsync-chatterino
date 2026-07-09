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

-- handle a stream:online / stream:offline broadcast. returns true if it was a
-- stream event (so init can stop dispatching), regardless of whether a line was
-- shown — an event for an unlinked channel is still "handled" (ignored).
function M.handle(msg)
    local t = msg.type
    if t ~= "stream:online" and t ~= "stream:offline" then return false end
    if not store.live_enabled() then return true end

    local platform = norm_platform(tostring(msg.platform or ""))
    if platform ~= "kick" and platform ~= "yt" then return true end -- twitch = native
    local channel = msg.channel
    if type(channel) ~= "string" or channel == "" then return true end

    -- only for a source the user actually merged into a tab
    local tabs = multichat.tabs_for(platform, string.lower(channel))
    if #tabs == 0 then return true end

    -- the server/ws is untrusted: clamp every field spliced into the system line
    -- (control-byte-free + length-capped) so a flood of megabyte-scale titles
    -- can't grow scrollback allocations unbounded.
    local chan_disp = net.safe_text(channel, 100) or channel
    local live = (t == "stream:online")
    local line = (live and "🔴 " or "⚫ ") .. chan_disp .. (live and (" is live on " .. platform) or (" went offline on " .. platform))
    if live then
        local game = net.safe_text(msg.game, 100)
        local title = net.safe_text(msg.title, 140)
        line = line .. (game and (" · " .. game) or "") .. (title and (" · " .. title) or "")
    end
    for _, cc in ipairs(tabs) do
        pcall(function()
            local ch = c2.Channel.by_name(cc)
            if ch and ch:is_valid() then
                ch:add_system_message("[heatsync] " .. line)
            end
        end)
    end
    return true
end

return M
