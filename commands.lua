-- user-facing commands. registered once from init.
local net = require("net")
local caps = require("caps")
local inventory = require("inventory")
local seventv = require("seventv")
local senders = require("senders")
local ws = require("ws")
local render = require("render")
local store = require("store")
local multichat = require("multichat")
local img = require("img")

local M = {}

local function sysmsg(ctx, text)
    pcall(function() ctx.channel:add_system_message("[heatsync] " .. text) end)
end

-- a clickable line: chatterino system messages can't carry links, so this
-- builds a minimal message with a link element instead. works on 2.5.5+.
local function linkmsg(ctx, text, url)
    local ok = pcall(function()
        ctx.channel:add_message(c2.Message.new({
            elements = {
                { type = "text", text = "[heatsync]", color = "system" },
                {
                    type = "text",
                    text = text,
                    color = "link",
                    tooltip = url,
                    link = { type = c2.LinkType.Url, value = url },
                },
            },
        }))
    end)
    if not ok then
        -- pre-2.5.5 fallback: plain system line with the raw url
        sysmsg(ctx, text .. " → " .. url)
    end
end

-- lua patterns lack {m,n}; check length separately
local function is_valid_name(s)
    return type(s) == "string" and s ~= "" and #s <= 25
        and string.match(s, "^[a-zA-Z0-9_]+$") ~= nil
end

function M.register(get_login)
    c2.register_command("/hsrefresh", function(ctx)
        local login = get_login()
        if not login then
            sysmsg(ctx, "no signed-in twitch account; can't refresh")
            return
        end
        local ok, err = pcall(inventory.refresh, login)
        if not ok then
            net.log_warn("manual refresh failed: " .. tostring(err))
            sysmsg(ctx, "refresh failed, see log")
            return
        end
        sysmsg(ctx, "refreshing inventory for " .. login .. "…")
    end)

    c2.register_command("/hsemotes", function(ctx)
        local own = inventory.count()
        local cached, cap = seventv.stats()
        if own == 0 then
            sysmsg(ctx, "inventory not loaded — try /hsrefresh")
            return
        end
        sysmsg(ctx, tostring(own) .. " inventory emotes · " .. tostring(cached) ..
            " 7tv search queries cached (cap " .. tostring(cap) .. ")")
    end)

    c2.register_command("/hsclear", function(ctx)
        seventv.clear()
        senders.clear()
        sysmsg(ctx, "search + sender caches cleared")
    end)

    -- visual emote picker: searches your inventory + 7tv/bttv/ffz, shows the
    -- matches as clickable images — clicking inserts the name into your input.
    local FIND_CAP = 40
    c2.register_command("/hsfind", function(ctx)
        local q = ctx.words[2]
        if not q or string.len(q) < 2 then
            sysmsg(ctx, "usage: /hsfind <query> — searches your inventory + 7tv/bttv/ffz; click an emote to insert it")
            return
        end
        local ch = ctx.channel
        local results = {} -- { name, url, w, h, source }
        local seen = {}
        local ql = string.lower(q)
        -- own inventory (prefix + substring)
        for name, e in pairs(inventory.map) do
            if not seen[name] and string.find(string.lower(name), ql, 1, true) then
                results[#results + 1] = { name = name, url = e.url, w = e.w, h = e.h, source = "hs" }
                seen[name] = true
            end
        end
        seventv.search_all(q, function(list)
            for _, e in ipairs(list) do
                if #results >= FIND_CAP then break end
                if not seen[e.name] then
                    local url, h = seventv.resolve_render(e.name)
                    results[#results + 1] = { name = e.name, url = url, h = h, source = e.provider }
                    seen[e.name] = true
                end
            end
            local ok = pcall(function()
                if #results == 0 then
                    ch:add_system_message("[heatsync] no emotes found for '" .. q .. "'")
                    return
                end
                local elems = { { type = "text", text = "[heatsync] " .. #results ..
                    " emotes for '" .. q .. "' — click to insert:", color = "system" } }
                for _, r in ipairs(results) do
                    local set = caps.images and r.url and img.for_url(r.url, r.w, r.h) or nil
                    local link = { type = c2.LinkType.InsertText, value = r.name .. " " }
                    if set then
                        elems[#elems + 1] = { type = "scaling-image", images = set,
                            flags = c2.MessageElementFlag.EmoteImage,
                            tooltip = r.name .. " · " .. r.source, link = link }
                    else
                        elems[#elems + 1] = { type = "text", text = r.name,
                            color = "link", tooltip = r.name .. " · " .. r.source, link = link }
                    end
                end
                ch:add_message(c2.Message.new({ elements = elems }))
            end)
            if not ok then sysmsg(ctx, "picker render failed") end
        end)
    end)

    -- hottest live streams right now (cross-platform, heat-ranked). click a
    -- twitch one to open it in chatterino.
    c2.register_command("/hshot", function(ctx)
        net.get_json(net.ORIGIN .. "/api/live/top?limit=10", 8000, function(payload, err)
            if not payload or type(payload.streams) ~= "table" then
                sysmsg(ctx, "hot streams unavailable: " .. tostring(err))
                return
            end
            sysmsg(ctx, "🔥 hottest live now:")
            for i, s in ipairs(payload.streams) do
                if i > 10 then break end
                local plat = tostring(s.platform or "?")
                local name = tostring(s.displayName or s.username or s.channel or "?")
                local viewers = tonumber(s.viewerCount) or 0
                local cat = s.gameName or s.category or ""
                local text = string.format("%s · %s · %s viewers%s",
                    plat, name, tostring(viewers), cat ~= "" and (" · " .. cat) or "")
                -- twitch → jump to the channel in chatterino; else open on the platform
                local link
                if plat == "twitch" and type(s.channel or s.username) == "string" then
                    link = { type = c2.LinkType.JumpToChannel, value = string.lower(s.channel or s.username) }
                else
                    link = { type = c2.LinkType.Url, value = net.ORIGIN .. "/u/" .. net.percent_encode(name) }
                end
                pcall(function()
                    ctx.channel:add_message(c2.Message.new({ elements = {
                        { type = "text", text = "[heatsync]", color = "system" },
                        { type = "text", text = text, color = "link", link = link },
                    } }))
                end)
            end
        end)
    end)

    -- heatsync profile card for any streamer (works for non-hs streamers too)
    c2.register_command("/hswhois", function(ctx)
        local user = ctx.words[2]
        if not user or user == "" then
            sysmsg(ctx, "usage: /hswhois <user>")
            return
        end
        net.get_json(net.ORIGIN .. "/api/profile/" .. net.percent_encode(string.lower(user)), 8000, function(payload, err)
            local p = payload and payload.profile
            if not p then
                sysmsg(ctx, "no profile for '" .. user .. "'" .. (err and (" (" .. tostring(err) .. ")") or ""))
                return
            end
            local name = tostring(p.display_name or p.username or user)
            local st = p.stats or {}
            local bits = {}
            if tonumber(st.user_heat) then bits[#bits + 1] = "heat " .. tostring(math.floor(tonumber(st.user_heat))) end
            if tonumber(st.total_posts) then bits[#bits + 1] = tostring(st.total_posts) .. " posts" end
            if tonumber(st.followers) then bits[#bits + 1] = tostring(st.followers) .. " hs-followers" end
            if p.twitch_is_live or p.kick_is_live then bits[#bits + 1] = "LIVE" end
            if tonumber(p.twitch_followers) then bits[#bits + 1] = tostring(p.twitch_followers) .. " twitch-followers" end
            local line = name .. (p.is_shadow_profile and " (not on heatsync)" or "") ..
                (#bits > 0 and (" · " .. table.concat(bits, " · ")) or "")
            pcall(function()
                ctx.channel:add_message(c2.Message.new({ elements = {
                    { type = "text", text = "[heatsync]", color = "system" },
                    { type = "text", text = line, color = "link",
                      link = { type = c2.LinkType.Url, value = net.ORIGIN .. "/u/" .. net.percent_encode(name) } },
                } }))
            end)
        end)
    end)

    -- archive relay: mirror the public twitch chat you see into heatsync's
    -- searchable archive (the corpus moat). OFF by default + opt-in — it sends
    -- public PRIVMSGs you already see to heatsync (first-party, no whispers).
    c2.register_command("/hsarchive", function(ctx)
        local arg = ctx.words[2]
        if arg == "on" then
            store.set_archive(true)
            sysmsg(ctx, "archive relay ON — public twitch chat you view now feeds heatsync's searchable archive (first-party, PRIVMSG only, dedup'd)")
        elseif arg == "off" then
            store.set_archive(false)
            sysmsg(ctx, "archive relay OFF")
        else
            sysmsg(ctx, "archive relay is " .. (store.archive_enabled() and "on" or "off") ..
                " · /hsarchive on|off · relays only public twitch chat you're already viewing")
        end
    end)

    -- local emote block: hides an emote from rendering + tab-complete. LOCAL
    -- ONLY — the plugin is anonymous so it can't sync a block to your heatsync
    -- account; use the website/extension for an account-wide block.
    c2.register_command("/hsblock", function(ctx)
        local name = ctx.words[2]
        if not name or name == "" then
            sysmsg(ctx, "usage: /hsblock <emote name> — hides it locally in chatterino")
            return
        end
        if store.block(name) then
            sysmsg(ctx, "blocked '" .. name .. "' locally (won't render or tab-complete)")
        else
            sysmsg(ctx, "'" .. name .. "' already blocked")
        end
    end)

    c2.register_command("/hsunblock", function(ctx)
        local name = ctx.words[2]
        if not name or name == "" then
            sysmsg(ctx, "usage: /hsunblock <emote name>")
            return
        end
        if store.unblock(name) then
            sysmsg(ctx, "unblocked '" .. name .. "'")
        else
            sysmsg(ctx, "'" .. name .. "' wasn't blocked")
        end
    end)

    c2.register_command("/hsblocklist", function(ctx)
        local names = store.blocklist()
        if #names == 0 then
            sysmsg(ctx, "no locally-blocked emotes")
            return
        end
        sysmsg(ctx, #names .. " blocked: " .. table.concat(names, " "))
    end)

    -- multichat: pull kick/youtube live chat into THIS chatterino tab
    c2.register_command("/hsmulti", function(ctx)
        local cc_name
        pcall(function() cc_name = ctx.channel:get_name() end)
        if type(cc_name) ~= "string" or cc_name == "" then
            sysmsg(ctx, "run /hsmulti inside a twitch channel tab")
            return
        end
        local arg = ctx.words[2]
        if not arg or arg == "" then
            local sources = multichat.list(cc_name)
            if #sources == 0 then
                sysmsg(ctx, "no kick/youtube chat linked here · usage: /hsmulti kick:<slug> | yt:<handle> | off")
            else
                sysmsg(ctx, "linked into #" .. cc_name .. ": " .. table.concat(sources, " "))
            end
            return
        end
        if arg == "off" then
            local n = multichat.unlink(cc_name)
            sysmsg(ctx, n > 0 and ("unlinked " .. n .. " source(s) from #" .. cc_name) or "nothing linked here")
            return
        end
        if arg == "auto" then
            local sub = ctx.words[3]
            if sub == "on" then
                store.set_auto_multichat(true)
                sysmsg(ctx, "auto-multichat ON — opening a twitch stream auto-merges its kick/youtube chat (when publicly linked)")
            elseif sub == "off" then
                store.set_auto_multichat(false)
                sysmsg(ctx, "auto-multichat OFF")
            else
                sysmsg(ctx, "auto-multichat is " .. (store.auto_multichat_enabled() and "on" or "off") .. " · /hsmulti auto on|off")
            end
            return
        end
        local platform, channel = string.match(arg, "^(%a+):(.+)$")
        if platform == "kick" then
            if not string.match(channel, "^[a-z0-9_-]+$") then
                sysmsg(ctx, "invalid kick slug")
                return
            end
            if multichat.link(cc_name, "kick", channel) then
                sysmsg(ctx, "🔥 kick chat from '" .. channel .. "' now merging into #" .. cc_name .. " [K]")
            else
                sysmsg(ctx, "kick:" .. channel .. " already linked here")
            end
        elseif platform == "yt" or platform == "youtube" then
            if #channel > 200 or string.match(channel, "%s") then
                sysmsg(ctx, "invalid youtube handle/url")
                return
            end
            if multichat.link(cc_name, "yt", channel) then
                sysmsg(ctx, "🔥 youtube chat '" .. channel .. "' linking into #" .. cc_name ..
                    " [Y] — needs the channel to be live now")
            else
                sysmsg(ctx, "yt:" .. channel .. " already linked here")
            end
        else
            sysmsg(ctx, "usage: /hsmulti kick:<slug> | yt:<handle-or-url> | off")
        end
    end)

    -- chatterino badges toggle (shows chatterino global badges on chatters)
    c2.register_command("/hsbadges", function(ctx)
        local arg = ctx.words[2]
        if arg == "on" then
            store.set_badges(true)
            sysmsg(ctx, "chatterino badges ON — special badges shown before chatters' names")
        elseif arg == "off" then
            store.set_badges(false)
            sysmsg(ctx, "chatterino badges OFF")
        else
            sysmsg(ctx, "chatterino badges are " .. (store.badges_enabled() and "on" or "off") .. " · /hsbadges on|off")
        end
    end)

    -- flame marker toggle (the 🔥 tag on heatsync users' messages)
    c2.register_command("/hsflame", function(ctx)
        local arg = ctx.words[2]
        if arg == "on" then
            store.set_flame(true)
            sysmsg(ctx, "🔥 marker on — heatsync users tagged in chat")
        elseif arg == "off" then
            store.set_flame(false)
            sysmsg(ctx, "🔥 marker off")
        else
            sysmsg(ctx, "🔥 marker is " .. (store.flame_enabled() and "on" or "off") ..
                " · usage: /hsflame on|off")
        end
    end)

    c2.register_command("/hsstatus", function(ctx)
        local sc, pend = senders.stats()
        local lines = caps.name() ..
            " · timers:" .. tostring(caps.later) ..
            " ws-api:" .. tostring(caps.websocket) ..
            " images:" .. tostring(caps.images) ..
            " windows:" .. tostring(caps.windows)
        sysmsg(ctx, lines)
        sysmsg(ctx, "ws " .. ws.status())
        local inv = tostring(inventory.count()) .. " emotes" ..
            (inventory.login and (" (" .. inventory.login .. ")") or " (no login)")
        sysmsg(ctx, inv .. " · " .. tostring(sc) .. " sender sets cached, " ..
            tostring(pend) .. " pending")
        if caps.tier == 2 then
            local hooks, replaced = render.stats()
            sysmsg(ctx, "rendering: " .. tostring(hooks) .. " channels hooked · " ..
                tostring(replaced) .. " messages enriched")
        else
            sysmsg(ctx, "rendering: unavailable on this build (needs nightly)")
        end
        sysmsg(ctx, "multichat: " .. tostring(multichat.stats()) .. " kick/youtube source(s) linked")
    end)

    -- dev aid: dump the last message's element types + flags to the log —
    -- the empirical probe for future element work (badges etc.)
    c2.register_command("/hsdump", function(ctx)
        local ok, err = pcall(function()
            local msg = ctx.channel:last_message()
            if not msg then
                sysmsg(ctx, "no messages in this channel")
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
            sysmsg(ctx, "last message dumped to log (" .. tostring(#msg:elements()) .. " elements)")
        end)
        if not ok then
            sysmsg(ctx, "dump failed: " .. tostring(err))
        end
    end)

    -- end-to-end self-test: posts a synthetic client-side message from the
    -- own login containing an inventory emote + a threadlink. add_message
    -- fires the append hook synchronously, so on t2 this exercises the full
    -- prescan → rebuild → replace pipeline and the result is visible in chat.
    c2.register_command("/hstest", function(ctx)
        local login = get_login() or inventory.login
        if not login then
            sysmsg(ctx, "no account; sign in first")
            return
        end
        local first = inventory.index[1]
        if not first then
            sysmsg(ctx, "inventory empty — /hsrefresh first")
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
            sysmsg(ctx, "self-test add failed: " .. tostring(err))
            return
        end
        if caps.tier == 2 then
            local _, replaced = render.stats()
            sysmsg(ctx, "self-test posted — emote should render as an image (replacements so far: " ..
                tostring(replaced) .. ")")
        else
            sysmsg(ctx, "self-test posted as text — rendering needs a nightly build (" .. caps.name() .. ")")
        end
    end)

    c2.register_command("/hsmoments", function(ctx)
        local hours = 24
        if ctx.words[2] then
            local h = tonumber(ctx.words[2])
            if h and h >= 1 and h <= 168 then hours = math.floor(h) end
        end
        local url = net.ORIGIN .. "/api/moments?limit=5&hours=" .. tostring(hours)
        net.get_json(url, 8000, function(payload, err)
            if not payload then
                sysmsg(ctx, "moments fetch failed: " .. tostring(err))
                return
            end
            local rows = payload.moments or payload.data or payload
            if type(rows) ~= "table" or #rows == 0 then
                sysmsg(ctx, "no moments in the last " .. tostring(hours) .. "h")
                return
            end
            sysmsg(ctx, "top moments · last " .. tostring(hours) .. "h")
            for i, m in ipairs(rows) do
                if i > 5 then break end
                if type(m) == "table" and m.id then
                    local chan = tostring(m.channel or "?")
                    local mult = ""
                    local rate = tonumber(m.rate)
                    local base = tonumber(m.baseline)
                    if rate and base and base > 0 then
                        mult = string.format(" · %.0fx", rate / base)
                    end
                    local title = net.pick_first_str(m, "title", "game") or ""
                    if title ~= "" then title = " · " .. title end
                    linkmsg(ctx, "#" .. chan .. mult .. title,
                        net.ORIGIN .. "/moment/" .. net.percent_encode(tostring(m.id)))
                end
            end
        end)
    end)

    c2.register_command("/hslogs", function(ctx)
        local user = ctx.words[2]
        if not is_valid_name(user) then
            sysmsg(ctx, "usage: /hslogs <user> [channel] — chat history + archive link")
            return
        end
        local chan = ctx.words[3]
        if chan and not is_valid_name(chan) then chan = nil end
        if not chan then
            pcall(function()
                local n = ctx.channel:get_name()
                if is_valid_name(n) then chan = n end
            end)
        end
        local luser = string.lower(user)
        local url = net.ORIGIN .. "/logs/search?username=" .. net.percent_encode(luser) .. "&platform=twitch"
        if chan then url = url .. "&channel=" .. net.percent_encode(string.lower(chan)) end
        -- fetch cross-platform chat stats for a summary line; the archive link
        -- is always shown even if stats are opted-out / unavailable.
        net.get_json(net.ORIGIN .. "/api/chatter/twitch/" .. net.percent_encode(luser) .. "/stats", 8000, function(payload)
            local t = payload and payload.totals
            if t then
                local bits = {}
                if tonumber(t.messages) then bits[#bits + 1] = tostring(t.messages) .. " msgs" end
                if tonumber(t.channels) then bits[#bits + 1] = "across " .. tostring(t.channels) .. " channels" end
                if tonumber(t.activeDays) then bits[#bits + 1] = tostring(t.activeDays) .. " active days" end
                local top = payload.topChannels and payload.topChannels[1]
                if top and top.channel then bits[#bits + 1] = "most in #" .. tostring(top.channel) end
                if #bits > 0 then sysmsg(ctx, luser .. ": " .. table.concat(bits, " · ")) end
            end
            linkmsg(ctx, "archive: " .. luser .. (chan and (" in #" .. string.lower(chan)) or ""), url)
        end)
    end)
end

return M
