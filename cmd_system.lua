-- system/utility commands: refresh, cache clear, toggles, status, help, dev aids.
local net = require("net")
local caps = require("caps")
local inventory = require("inventory")
local seventv = require("seventv")
local senders = require("senders")
local ws = require("ws")
local render = require("render")
local store = require("store")
local multichat = require("multichat")
local u = require("cmdutil")

local M = {}

function M.register(get_login)
    c2.register_command("/hsrefresh", function(ctx)
        local login = get_login()
        if not login then
            u.sysmsg(ctx, "no signed-in twitch account; can't refresh")
            return
        end
        local ok, err = pcall(inventory.refresh, login)
        if not ok then
            net.log_warn("manual refresh failed: " .. tostring(err))
            u.sysmsg(ctx, "refresh failed, see log")
            return
        end
        u.sysmsg(ctx, "refreshing inventory for " .. login .. "…")
    end)

    c2.register_command("/hsclear", function(ctx)
        seventv.clear()
        senders.clear()
        u.sysmsg(ctx, "search + sender caches cleared")
    end)

    -- chatterino badges toggle (shows chatterino global badges on chatters)
    c2.register_command("/hsbadges", function(ctx)
        local arg = ctx.words[2]
        if arg == "on" then
            store.set_badges(true)
            u.sysmsg(ctx, "chatterino badges ON — special badges shown before chatters' names")
        elseif arg == "off" then
            store.set_badges(false)
            u.sysmsg(ctx, "chatterino badges OFF")
        else
            u.sysmsg(ctx, "chatterino badges are " .. (store.badges_enabled() and "on" or "off") .. " · /hsbadges on|off")
        end
    end)

    -- flame marker toggle (the 🔥 tag on heatsync users' messages)
    c2.register_command("/hsflame", function(ctx)
        local arg = ctx.words[2]
        if arg == "on" then
            store.set_flame(true)
            u.sysmsg(ctx, "🔥 marker on — heatsync users tagged in chat")
        elseif arg == "off" then
            store.set_flame(false)
            u.sysmsg(ctx, "🔥 marker off")
        else
            u.sysmsg(ctx, "🔥 marker is " .. (store.flame_enabled() and "on" or "off") ..
                " · /hsflame on|off")
        end
    end)

    c2.register_command("/hsstatus", function(ctx)
        local sc, pend = senders.stats()
        local lines = caps.name() ..
            " · timers:" .. tostring(caps.later) ..
            " ws-api:" .. tostring(caps.websocket) ..
            " images:" .. tostring(caps.images) ..
            " windows:" .. tostring(caps.windows)
        u.sysmsg(ctx, lines)
        u.sysmsg(ctx, "ws " .. ws.status())
        local inv = tostring(inventory.count()) .. " emotes" ..
            (inventory.login and (" (" .. inventory.login .. ")") or " (no login)")
        u.sysmsg(ctx, inv .. " · " .. tostring(sc) .. " sender sets cached, " ..
            tostring(pend) .. " pending")
        if caps.tier == 2 then
            local hooks, replaced = render.stats()
            u.sysmsg(ctx, "rendering: " .. tostring(hooks) .. " channels hooked · " ..
                tostring(replaced) .. " messages enriched")
        else
            u.sysmsg(ctx, "rendering: unavailable on this build (needs nightly)")
        end
        u.sysmsg(ctx, "multichat: " .. multichat.summary())
        -- per-tab link breakdown so a merge is legible, not just a count
        local links = multichat.detail()
        for _, l in ipairs(links) do u.sysmsg(ctx, "  #" .. l.tab .. " ← " .. l.sources) end
    end)

    -- what can this build do? a single discoverable index of every command,
    -- grouped, with a tier note so it's honest about what's unavailable here.
    c2.register_command("/hshelp", function(ctx)
        u.sysmsg(ctx, "heatsync commands · build " .. caps.name())
        u.sysmsg(ctx, "emotes: :name tab-complete · /hsemotes menu · /hsfind <q> search · /hsinv <user> [page]")
        u.sysmsg(ctx, "archive: /hssearch <q> posts · /hschat <q> [@user] [#chan] chat-logs · /hslogs <user> [chan] · /hsmoments [<n>h] [plat] [pg] · /hshot [plat] [pg] · /hswhois <user>")
        u.sysmsg(ctx, "chat: /hsmulti kick:<slug>|yt:<handle>|off|auto on|off · /hsflame · /hsbadges · /hsblock <name> · /hsunblock <name> · /hsblocklist")
        u.sysmsg(ctx, "system: /hsstatus · /hsrefresh · /hsarchive on|off · /hsclear")
        u.sysmsg(ctx, "syntax: @user #channel narrow a search · plat:value links a multichat source · <n>h = hours")
        if caps.tier < 2 then
            u.sysmsg(ctx, "note: inline emote rendering + the /hsemotes/hsfind image menus need a nightly build — this is " .. caps.name() .. " (tab-complete + commands work)")
        end
    end)

    -- dev aid: dump the last message's element types + flags to the log —
    -- the empirical probe for future element work (badges etc.)
    c2.register_command("/hsdump", function(ctx)
        local ok, err = pcall(function()
            local msg = ctx.channel:last_message()
            if not msg then
                u.sysmsg(ctx, "no messages in this channel")
                return
            end
            net.log_info("dump: id=" .. tostring(msg.id) .. " login=" .. tostring(msg.login_name) ..
                " flags=" .. tostring(msg.flags) .. " frozen=" .. tostring(msg.frozen))
            net.log_info("dump: text=" .. tostring(msg.message_text))
            for i, el in ipairs(msg:elements()) do
                local ty, fl, ts = "?", "?", "?"
                pcall(function() ty = tostring(el.type) end)
                pcall(function() fl = tostring(el.flags) end)
                pcall(function() ts = tostring(el.trailing_space) end)
                local extra = ""
                pcall(function()
                    if el.type == "text" then
                        extra = " words=[" .. table.concat(el.words, "|") .. "] color=" .. tostring(el.color)
                    end
                end)
                net.log_info("dump: [" .. i .. "] type=" .. ty .. " flags=" .. fl ..
                    " trailing_space=" .. ts .. extra)
            end
            u.sysmsg(ctx, "last message dumped to log (" .. tostring(#msg:elements()) .. " elements)")
        end)
        if not ok then
            u.sysmsg(ctx, "dump failed: " .. tostring(err))
        end
    end)

    -- end-to-end self-test: posts a synthetic client-side message from the
    -- own login containing an inventory emote + a threadlink. add_message
    -- fires the append hook synchronously, so on t2 this exercises the full
    -- prescan → rebuild → replace pipeline and the result is visible in chat.
    c2.register_command("/hstest", function(ctx)
        local login = get_login() or inventory.login
        if not login then
            u.sysmsg(ctx, "no account; sign in first")
            return
        end
        local first = inventory.index[1]
        if not first then
            u.sysmsg(ctx, "inventory empty — /hsrefresh first")
            return
        end
        local text = "self-test: " .. first.name .. " >>selftest ok"
        local ok, err = pcall(function()
            ctx.channel:add_message(c2.Message.new({
                login_name = login,
                display_name = login,
                message_text = text,
                search_text = text,
                username_color = "#ff8700",
                elements = {
                    { type = "text", text = login .. ":", color = "#ff8700" },
                    { type = "text", text = text },
                },
            }))
        end)
        if not ok then
            u.sysmsg(ctx, "self-test add failed: " .. tostring(err))
            return
        end
        if caps.tier == 2 then
            local _, replaced = render.stats()
            u.sysmsg(ctx, "self-test posted — emote should render as an image (replacements so far: " ..
                tostring(replaced) .. ")")
        else
            u.sysmsg(ctx, "self-test posted as text — rendering needs a nightly build (" .. caps.name() .. ")")
        end
    end)
end

return M
