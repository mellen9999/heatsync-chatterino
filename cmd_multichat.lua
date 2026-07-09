-- multichat command: pull kick/youtube live chat into a chatterino tab.
local multichat = require("multichat")
local store = require("store")
local u = require("cmdutil")

local M = {}

function M.register()
    -- multichat: pull kick/youtube live chat into THIS chatterino tab
    c2.register_command("/hsmulti", function(ctx)
        local cc_name
        pcall(function() cc_name = ctx.channel:get_name() end)
        if type(cc_name) ~= "string" or cc_name == "" then
            u.sysmsg(ctx, "run /hsmulti inside a twitch channel tab")
            return
        end
        local arg = ctx.words[2]
        if not arg or arg == "" then
            local sources = multichat.list(cc_name)
            if #sources == 0 then
                u.sysmsg(ctx, "no kick/youtube chat linked here · usage: /hsmulti kick:<slug> | yt:<handle> | off")
            else
                u.sysmsg(ctx, "linked into #" .. cc_name .. ": " .. table.concat(sources, " "))
            end
            return
        end
        if arg == "off" then
            local n = multichat.unlink(cc_name)
            u.sysmsg(ctx, n > 0 and ("unlinked " .. n .. " source(s) from #" .. cc_name) or "nothing linked here")
            return
        end
        if arg == "auto" then
            local sub = ctx.words[3]
            if sub == "on" then
                store.set_auto_multichat(true)
                u.sysmsg(ctx, "auto-multichat ON — opening a twitch stream auto-merges its kick/youtube chat (when publicly linked)")
            elseif sub == "off" then
                store.set_auto_multichat(false)
                u.sysmsg(ctx, "auto-multichat OFF")
            else
                u.sysmsg(ctx, "auto-multichat is " .. (store.auto_multichat_enabled() and "on" or "off") .. " · /hsmulti auto on|off")
            end
            return
        end
        local platform, channel = string.match(arg, "^(%a+):(.+)$")
        if platform == "kick" then
            if not string.match(channel, "^[a-z0-9_-]+$") then
                u.sysmsg(ctx, "invalid kick slug")
                return
            end
            if multichat.link(cc_name, "kick", channel) then
                u.sysmsg(ctx, "🔥 kick chat from '" .. channel .. "' now merging into #" .. cc_name .. " [K]")
            else
                u.sysmsg(ctx, "kick:" .. channel .. " already linked here")
            end
        elseif platform == "yt" or platform == "youtube" then
            if #channel > 200 or string.match(channel, "%s") then
                u.sysmsg(ctx, "invalid youtube handle/url")
                return
            end
            if multichat.link(cc_name, "yt", channel) then
                u.sysmsg(ctx, "🔥 youtube chat '" .. channel .. "' linking into #" .. cc_name ..
                    " [Y] — needs the channel to be live now")
            else
                u.sysmsg(ctx, "yt:" .. channel .. " already linked here")
            end
        else
            u.sysmsg(ctx, "usage: /hsmulti kick:<slug> | yt:<handle-or-url> | off")
        end
    end)
end

return M
