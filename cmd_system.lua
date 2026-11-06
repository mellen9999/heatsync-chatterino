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
local heat = require("heat")
local flair = require("flair")
local namecolor = require("namecolor")
local images = require("images")
local mutes = require("mutes")
local gifs = require("gifs")
local previews = require("previews")
local account = require("account")
local sync = require("account_sync")
local u = require("cmdutil")
local pin = require("pin")

local M = {}

-- on/off command for an on-by-default feature: `/name on|off`, bare = status.
-- `what` is the one-line description shown when switched on and in the status.
local function flag_command(name, label, get, set, what)
    c2.register_command(name, function(ctx)
        local arg = ctx.words[2]
        if arg == "on" then
            set(true)
            u.sysmsg(ctx, label .. " ON — " .. what)
        elseif arg == "off" then
            set(false)
            u.sysmsg(ctx, label .. " OFF")
        else
            u.sysmsg(ctx, label .. " is " .. (get() and "on" or "off") .. " · " .. name .. " on|off · " .. what)
        end
    end)
end

function M.register(get_login)
    c2.register_command("/hsrefresh", function(ctx)
        local login = get_login()
        if not login then
            u.sysmsg(ctx, "no signed-in twitch account; can't refresh")
            return
        end
        -- the answer comes back on the same line the command was typed in:
        -- a refresh that failed and one that is still running used to look
        -- identical from the split (both said "refreshing…", the failure
        -- went to the log).
        local ok, started = pcall(inventory.refresh, login, nil, function(count, reason)
            if count then
                u.sysmsg(ctx, "inventory refreshed: " .. tostring(count) .. " emotes")
            else
                u.sysmsg(ctx, "refresh failed: " .. tostring(reason))
            end
        end)
        if not ok then
            net.log_warn("manual refresh failed: " .. tostring(started))
            u.sysmsg(ctx, "refresh failed: " .. tostring(started))
            return
        end
        if started == false then
            u.sysmsg(ctx, "a refresh is already running; another is queued behind it")
            return
        end
        u.sysmsg(ctx, "refreshing inventory for " .. login .. "…")
    end)

    c2.register_command("/hsclear", function(ctx)
        seventv.clear()
        senders.clear()
        heat.clear()
        flair.clear()
        namecolor.clear()
        images.clear()
        mutes.clear()
        gifs.clear()
        previews.clear()
        u.sysmsg(ctx, "search, sender, heat, flair, color, image, preview and mute caches cleared")
    end)

    -- pinned message: on|off toggles the 📌 line (view); `clear` removes the pin
    -- (needs the opt-in login + moderator rights, over the account api — the
    -- socket itself stays anonymous). pinning a message is the right-click menu.
    c2.register_command("/hspin", function(ctx)
        local arg = ctx.words[2]
        if arg == "clear" then
            require("cmd_account").pin_clear(ctx)
        elseif arg == "on" then
            store.set_pin(true)
            pcall(pin.refetch, false) -- tabs already open get their pin now
            u.sysmsg(ctx, "pinned message ON — 📌 line when a channel's heatsync pin is set or cleared")
        elseif arg == "off" then
            store.set_pin(false)
            u.sysmsg(ctx, "pinned message OFF")
        else
            u.sysmsg(ctx, "pinned message is " .. (store.pin_enabled() and "on" or "off") ..
                " · /hspin on|off · /hspin clear removes this channel's pin (log in first) · right-click a message to pin it")
        end
    end)

    flag_command("/hsheat", "heat bars", store.heat_enabled, store.set_heat,
        "a colored bar before the name of chatters with heat on heatsync (hover for the score)")
    flag_command("/hsflair", "sub flair", store.flair_enabled, store.set_flair,
        "the sub badge a heatsync user picked shows before their name")
    flag_command("/hscolors", "name colors", store.colors_enabled, store.set_colors,
        "heatsync users' picked name color on merged youtube lines")
    flag_command("/hsbackfill", "history backfill", store.backfill_enabled, store.set_backfill,
        "a linked kick/youtube source loads its last ~50 lines when merged")
    flag_command("/hsmentions", "mention highlights", store.mentions_enabled, store.set_mentions,
        "a merged kick/youtube line that mentions you gets chatterino's mention highlight")
    flag_command("/hspreviews", "link previews", store.previews_enabled, store.set_previews,
        "a link that isn't an image gets a title + small thumbnail line under it, fetched through heatsync so the site never sees your ip (off by default)")
    flag_command("/hsmutes", "community mutes", store.mutes_enabled, store.set_mutes,
        "chatters your channel's heatsync community muted collapse to a short placeholder line (off by default)")
    flag_command("/hsimages", "inline images", store.images_enabled, store.set_images,
        "an image link shows the image under the line, loaded through heatsync's proxy so the image host never sees your ip (off by default)")

    -- live-status toggle: go-live / went-offline lines for your linked kick/yt
    -- sources (chatterino shows twitch natively, so those are skipped)
    c2.register_command("/hslive", function(ctx)
        local arg = ctx.words[2]
        if arg == "on" then
            store.set_live(true)
            u.sysmsg(ctx, "live-status ON — 🔴/⚫ when a linked kick/youtube source goes live or offline, 🎮/📝 when its (or an open twitch tab's) game or title changes")
        elseif arg == "off" then
            store.set_live(false)
            u.sysmsg(ctx, "live-status OFF")
        else
            u.sysmsg(ctx, "live-status is " .. (store.live_enabled() and "on" or "off") ..
                " · /hslive on|off · 🔴/⚫ for your linked kick/youtube sources, 🎮/📝 game + title switches for those and your open twitch tabs")
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
        u.sysmsg(ctx, "ws " .. ws.status() .. " (anonymous)")
        u.sysmsg(ctx, account.status_line())
        local sum = sync.summary()
        if sum then u.sysmsg(ctx, "  synced: " .. sum) end
        local pn = account.take_notice()
        if pn then u.sysmsg(ctx, pn) end
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
        u.sysmsg(ctx, "live status: " .. (store.live_enabled() and "on" or "off") .. " (/hslive on|off)")
        u.sysmsg(ctx, "moment spikes: " .. (store.spikes_enabled() and "on" or "off") .. " (/hsmoments on|off)")
        u.sysmsg(ctx, "pinned message: " .. (store.pin_enabled() and "on" or "off") .. " (/hspin on|off)")
        local hc, hp = heat.stats()
        local fc, fp = flair.stats()
        local nc, np = namecolor.stats()
        u.sysmsg(ctx, "heat bars: " .. (store.heat_enabled() and "on" or "off") .. " (/hsheat on|off) · " ..
            tostring(hc) .. " cached, " .. tostring(hp) .. " pending")
        u.sysmsg(ctx, "sub flair: " .. (store.flair_enabled() and "on" or "off") .. " (/hsflair on|off) · " ..
            tostring(fc) .. " cached, " .. tostring(fp) .. " pending")
        u.sysmsg(ctx, "name colors: " .. (store.colors_enabled() and "on" or "off") .. " (/hscolors on|off) · " ..
            tostring(nc) .. " cached, " .. tostring(np) .. " pending")
        u.sysmsg(ctx, "history backfill: " .. (store.backfill_enabled() and "on" or "off") .. " (/hsbackfill on|off)")
        u.sysmsg(ctx, "mention highlights: " .. (store.mentions_enabled() and "on" or "off") ..
            " (/hsmentions on|off)" .. (caps.highlight and "" or " · unavailable on this build"))
        u.sysmsg(ctx, "gifs: /hsgif [query] [page] · " .. tostring(gifs.stats()) .. " searches cached")
        local pk, pp = previews.stats()
        u.sysmsg(ctx, "link previews: " .. (store.previews_enabled() and "on" or "off") .. " (/hspreviews on|off) · " ..
            tostring(pk) .. " known, " .. tostring(pp) .. " pending" ..
            (caps.tier == 2 and caps.images and "" or " · unavailable on this build"))
        local mk, mp = mutes.stats()
        u.sysmsg(ctx, "community mutes: " .. (store.mutes_enabled() and "on" or "off") .. " (/hsmutes on|off) · " ..
            tostring(mk) .. " channels cached, " .. tostring(mp) .. " pending" ..
            (caps.tier == 2 and "" or " · unavailable on this build"))
        local ik, ip = images.stats()
        u.sysmsg(ctx, "inline images: " .. (store.images_enabled() and "on" or "off") .. " (/hsimages on|off) · " ..
            tostring(ik) .. " sized, " .. tostring(ip) .. " pending")
        -- per-tab link breakdown so a merge is legible, not just a count
        local links = multichat.detail()
        for _, l in ipairs(links) do u.sysmsg(ctx, "  #" .. l.tab .. " ← " .. l.sources) end
    end)

    -- what can this build do? a single discoverable index of every command,
    -- grouped, with a tier note so it's honest about what's unavailable here.
    c2.register_command("/hshelp", function(ctx)
        u.sysmsg(ctx, "heatsync commands · build " .. caps.name())
        u.sysmsg(ctx, "emotes: :name tab-complete · /hsemotes menu · /hsfind <q> search · /hsinv <user> [page] · /hsgif [query] [page] gifs")
        u.sysmsg(ctx, "archive: /hssearch <q> posts · /hschat <q> [@user] [#chan] chat-logs · /hslogs <user> [chan] · /hsmoments [<n>h] [plat] [pg] · /hsmoments on|off live spikes · /hshot [plat] [pg] · /hswhois <user> · /hscard <user>")
        u.sysmsg(ctx, "chat: /hsmulti kick:<slug>|yt:<handle>|off|auto on|off · /hslayout <link>|share · /hslive · /hspin · /hsflame · /hsheat · /hsflair · /hscolors · /hsbackfill · /hsmentions · /hsmutes · /hsimages · /hspreviews · /hsblock <name> · /hsunblock <name> · /hsblocklist")
        u.sysmsg(ctx, "log in (optional): /hslogin · /hslogout · then /hsnote <user> [text|-] · /hsmute <user> [plat] · /hsunmute <user> · /hsmutelist · /hsfollow <user> · /hsunfollow <user> · /hspin clear · right-click a message to pin it · /hsblock and /hsunblock sync to your account")
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
            ctx.channel:add_message(net.new_message({
                -- render skips messages with no channel_name (that's how it
                -- tells multichat-injected lines apart), so the self-test must
                -- carry the tab's name or it never renders
                channel_name = ctx.channel:get_name(),
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
