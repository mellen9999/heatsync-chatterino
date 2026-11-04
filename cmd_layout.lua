-- /hslayout: open a heatsync.org/m/<layout> share link here, or build one for this tab.
local layout = require("layout")
local multichat = require("multichat")
local u = require("cmdutil")

local M = {}

-- kick/youtube legs of a tab as the multichat.list keys ("kick/x", "yt/y")
local function legs_of(cc_name)
    local kick, yt
    for _, key in ipairs(multichat.list(cc_name)) do
        kick = kick or string.match(key, "^kick/(.+)$")
        yt = yt or string.match(key, "^yt/(.+)$")
    end
    return kick, yt
end

-- a clickable jump to a twitch tab (host can only jump to an already-joinable channel)
local function jumpmsg(ctx, text, name)
    local ok = pcall(function()
        local net = require("net")
        ctx.channel:add_message(net.new_message({ elements = {
            { type = "text", text = "[heatsync]", color = "system" },
            { type = "text", text = text, color = "link",
              link = { type = c2.LinkType.JumpToChannel, value = name } },
        } }))
    end)
    if not ok then u.sysmsg(ctx, text) end
end

function M.register()
    c2.register_command("/hslayout", function(ctx)
        local arg = ctx.words[2]
        if not arg or arg == "" then
            u.sysmsg(ctx, "usage: /hslayout <heatsync.org/m/... link> to open one · /hslayout share to build one for this tab")
            return
        end
        if arg == "share" then
            local cc_name
            pcall(function() cc_name = ctx.channel:get_name() end)
            if type(cc_name) ~= "string" or cc_name == "" then
                u.sysmsg(ctx, "run /hslayout share inside a twitch channel tab")
                return
            end
            local kick, yt = legs_of(cc_name)
            local url = layout.url({ { twitch = string.lower(cc_name), kick = kick, youtube = yt } })
            if not url then
                u.sysmsg(ctx, "can't build a link for this tab")
                return
            end
            u.linkmsg(ctx, url, url)
            u.sysmsg(ctx, "click to open, right-click to copy (chatterino plugins can't write the clipboard)")
            return
        end
        local tabs = layout.parse(layout.extract(arg))
        if #tabs == 0 then
            u.sysmsg(ctx, "no valid tabs in that link · looks like /m/t:xqc,k:xqc+t:asmongold")
            return
        end
        u.sysmsg(ctx, "layout: " .. #tabs .. " tab(s) · click each to open it")
        for _, t in ipairs(tabs) do
            local label = layout.build({ t })
            if t.twitch then
                -- record the kick/yt legs so the merged chat works the moment the tab opens
                if t.kick then multichat.link(t.twitch, "kick", t.kick) end
                if t.youtube then multichat.link(t.twitch, "yt", t.youtube) end
                jumpmsg(ctx, "open #" .. t.twitch .. "  (" .. label .. ")", t.twitch)
            else
                -- no twitch leg: nothing to host a tab on, so point at the site view
                local url = layout.url({ t })
                u.linkmsg(ctx, "no twitch tab for " .. label .. " · view on heatsync", url)
            end
        end
    end)
end

return M
