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
local picker = require("picker")
local recents = require("recents")

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

-- arg parse for /hshot: any recognized platform token sets a filter, any
-- positive integer sets the page. order-free, so `/hshot kick 2` and
-- `/hshot 2 kick` both work. (/hsmoments parses its own args — it has a leading
-- hours value, so its number handling differs and can't share this.)
local PLAT_ALIAS = { twitch = "twitch", kick = "kick", youtube = "youtube", yt = "youtube" }
local function parse_plat_page(words, start)
    local plat, page = nil, 1
    for i = start, #words do
        local w = words[i]
        if type(w) == "string" and w ~= "" then
            local n = tonumber(w)
            if n and n >= 1 and math.floor(n) == n then
                page = math.floor(n)
            elseif PLAT_ALIAS[string.lower(w)] then
                plat = PLAT_ALIAS[string.lower(w)]
            end
        end
    end
    return plat, page
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

    -- your emote menu: a clickable grid of YOUR inventory, recents-first then
    -- usage-ordered, paginated. `/hsemotes` page 1 · `/hsemotes 2` next page ·
    -- `/hsemotes <query>` filter to matching names. click any emote to insert.
    local HSEMOTES_PER_PAGE = 50
    c2.register_command("/hsemotes", function(ctx)
        local own = inventory.count()
        if own == 0 then
            sysmsg(ctx, "inventory not loaded — sign in at heatsync.org once, then /hsrefresh")
            return
        end
        local arg = ctx.words[2]
        local page, query = 1, nil
        if arg and arg ~= "" then
            local p = tonumber(arg)
            if p and p >= 1 and math.floor(p) == p then page = p else query = string.lower(arg) end
        end

        -- ordered name list
        local names, seen = {}, {}
        if query then
            for _, item in ipairs(inventory.index) do
                if string.find(item.lower, query, 1, true) and not seen[item.name] then
                    names[#names + 1] = item.name; seen[item.name] = true
                end
            end
            if #names == 0 then sysmsg(ctx, "no inventory emotes matching '" .. arg .. "'"); return end
        else
            for _, n in ipairs(recents.names()) do
                if not seen[n] then names[#names + 1] = n; seen[n] = true end
            end
            for _, item in ipairs(inventory.index) do
                if not seen[item.name] then names[#names + 1] = item.name; seen[item.name] = true end
            end
        end

        local total = #names
        local pages = math.max(1, math.ceil(total / HSEMOTES_PER_PAGE))
        if page > pages then page = pages end
        local from = (page - 1) * HSEMOTES_PER_PAGE + 1
        local to = math.min(total, from + HSEMOTES_PER_PAGE - 1)

        local recent_set = {}
        for _, n in ipairs(recents.names()) do recent_set[n] = true end
        local items = {}
        for i = from, to do
            local n = names[i]
            local e = inventory.resolve(n)
            if e then
                items[#items + 1] = { name = n, url = e.url, w = e.w, h = e.h, hs = true,
                    label = n .. (recent_set[n] and " · recent" or " · heatsync") }
            end
        end

        local header
        if query then
            header = "[heatsync] " .. total .. " of your emotes matching '" .. arg .. "' — click to insert:"
        else
            local nav = pages > 1 and (" · page " .. page .. "/" .. pages ..
                " · /hsemotes " .. (page < pages and page + 1 or 1) .. " for more") or ""
            header = "[heatsync] your emotes (" .. own .. ")" .. nav ..
                " · /hsemotes <query> to filter — click to insert:"
        end
        if not picker.render(ctx.channel, header, items) then sysmsg(ctx, "emote menu render failed") end
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
        -- search with the lowercased query — search_all's sanity gate requires
        -- lowercase, and the server matches case-insensitively (returns proper-
        -- case names). passing raw `q` silently returned 0 for any capital.
        seventv.search_all(ql, function(list)
            for _, e in ipairs(list) do
                if #results >= FIND_CAP then break end
                if not seen[e.name] then
                    local url, h = seventv.resolve_render(e.name)
                    results[#results + 1] = { name = e.name, url = url, h = h, source = e.provider }
                    seen[e.name] = true
                end
            end
            if #results == 0 then
                pcall(function() ch:add_system_message("[heatsync] no emotes found for '" .. q .. "'") end)
                return
            end
            local items = {}
            for _, r in ipairs(results) do
                items[#items + 1] = { name = r.name, url = r.url, w = r.w, h = r.h,
                    hs = r.source == "hs", label = r.name .. " · " .. r.source }
            end
            if not picker.render(ch, "[heatsync] " .. #results ..
                " emotes for '" .. q .. "' — click to insert:", items) then
                sysmsg(ctx, "picker render failed")
            end
        end)
    end)

    -- hottest live streams right now (cross-platform, heat-ranked). click a
    -- twitch one to open it in chatterino. `/hshot` top page · `/hshot 2` next
    -- page · `/hshot kick` filter to a platform · `/hshot kick 2` both.
    -- we over-fetch once and filter+page CLIENT-SIDE — no unverified server
    -- params — so a platform filter and paging cost nothing extra.
    local HOT_PER_PAGE = 10
    c2.register_command("/hshot", function(ctx)
        local plat_filter, page = parse_plat_page(ctx.words, 2)
        net.get_json(net.ORIGIN .. "/api/live/top?limit=50", 8000, function(payload, err)
            if not payload or type(payload.streams) ~= "table" then
                sysmsg(ctx, "hot streams unavailable: " .. tostring(err))
                return
            end
            local rows = {}
            for _, s in ipairs(payload.streams) do
                if type(s) == "table" and (not plat_filter or tostring(s.platform) == plat_filter) then
                    rows[#rows + 1] = s
                end
            end
            local total = #rows
            if total == 0 then
                -- we only over-fetch the global top 50 by heat, so a platform
                -- filter can legitimately miss lower-ranked streams — say so
                -- rather than claim the platform has nothing live.
                sysmsg(ctx, plat_filter
                    and ("no " .. plat_filter .. " streams in the current top 50 by heat")
                    or "no live streams right now")
                return
            end
            local pages = math.max(1, math.ceil(total / HOT_PER_PAGE))
            if page > pages then page = pages end
            local from = (page - 1) * HOT_PER_PAGE + 1
            local to = math.min(total, from + HOT_PER_PAGE - 1)
            local nav = pages > 1 and (" · page " .. page .. "/" .. pages ..
                " · /hshot " .. (plat_filter and (plat_filter .. " ") or "") .. (page < pages and page + 1 or 1) .. " for more") or ""
            sysmsg(ctx, "🔥 hottest live now" .. (plat_filter and (" · " .. plat_filter) or "") .. nav .. ":")
            for i = from, to do
                local s = rows[i]
                local plat = tostring(s.platform or "?")
                local name = tostring(s.displayName or s.username or s.channel or "?")
                local viewers = tonumber(s.viewerCount) or 0
                local cat = s.gameName or s.category or ""
                local heat = tonumber(s.heat)
                local text = string.format("%s · %s · %s viewers%s%s",
                    plat, name, tostring(viewers),
                    cat ~= "" and (" · " .. cat) or "",
                    (heat and heat > 0) and (" · heat " .. tostring(math.floor(heat))) or "")
                -- build the link INSIDE the pcall: c2.LinkType.* may be absent on
                -- an older build, and this runs in an async callback that the
                -- outer setup pcall no longer covers — one bad row must not abort
                -- the rest of the list.
                pcall(function()
                    local link
                    if plat == "twitch" and type(s.channel or s.username) == "string" then
                        link = { type = c2.LinkType.JumpToChannel, value = string.lower(s.channel or s.username) }
                    else
                        link = { type = c2.LinkType.Url, value = net.ORIGIN .. "/u/" .. net.percent_encode(name) }
                    end
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

    -- read the archive back: search heatsync's public post corpus from chatterino
    -- and get clickable thread permalinks + an inline preview. this closes the
    -- flywheel — the archive relay writes chat in, /hssearch reads posts back out.
    -- (note: this searches heatsync POSTS via /api/search; the relayed twitch-chat
    -- log corpus is a separate, web-only surface with no fast json api yet.)
    local SEARCH_LIMIT = 8
    local function join_args(words)
        local parts = {}
        for i = 2, #words do parts[#parts + 1] = words[i] end
        return table.concat(parts, " ")
    end
    local function preview(s, n)
        s = tostring(s or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if utf8 and utf8.len then
            local len = utf8.len(s)
            if len and len > n then
                local cut = utf8.offset(s, n + 1)
                if cut then return s:sub(1, cut - 1) .. "…" end
            end
            return s
        end
        if #s > n then return s:sub(1, n - 1) .. "…" end
        return s
    end
    c2.register_command("/hssearch", function(ctx)
        local q = join_args(ctx.words)
        if string.len(q) < 2 then
            sysmsg(ctx, "usage: /hssearch <query> — searches heatsync posts; click a result to open the thread")
            return
        end
        local url = net.ORIGIN .. "/api/search?q=" .. net.percent_encode(q) .. "&limit=" .. tostring(SEARCH_LIMIT)
        net.get_json(url, 8000, function(payload, err)
            local rows = payload and payload.results
            if type(rows) ~= "table" then
                sysmsg(ctx, "search failed: " .. tostring(err))
                return
            end
            if #rows == 0 then
                sysmsg(ctx, "no heatsync posts for '" .. q .. "'")
                return
            end
            -- header must match the rows actually listed, not the server's raw
            -- count (the loop caps at SEARCH_LIMIT)
            sysmsg(ctx, math.min(#rows, SEARCH_LIMIT) .. " heatsync post(s) for '" .. q .. "':")
            for i, r in ipairs(rows) do
                if i > SEARCH_LIMIT then break end
                local id = type(r) == "table" and net.pick_first_str(r, "base36_id", "id")
                if id then
                    local who = tostring(r.display_name or r.username or "?")
                    local heat = tonumber(r.heat)
                    local suffix = (heat and heat > 0) and (" · heat " .. tostring(math.floor(heat))) or ""
                    linkmsg(ctx, who .. ": " .. preview(r.content, 80) .. suffix,
                        net.ORIGIN .. "/thread/" .. net.percent_encode(id))
                end
            end
        end)
    end)

    -- browse anyone's heatsync inventory (whois, for emotes): resolve the login
    -- to its heatsync id, fetch that user's emote set, show it as a click-to-
    -- insert grid. uses the same public endpoints the sender-emote path already
    -- reads (see senders.lua) — nothing private, and it never feeds the render
    -- path (privacy invariant: only the SENDER's own inventory renders inline).
    c2.register_command("/hsinv", function(ctx)
        local user = ctx.words[2]
        if not is_valid_name(user) then
            sysmsg(ctx, "usage: /hsinv <user> — shows a user's heatsync emotes; click to insert")
            return
        end
        local luser = string.lower(user)
        net.get_json(net.ORIGIN .. "/api/profile/" .. net.percent_encode(luser), 8000, function(payload, err)
            local p = type(payload) == "table" and type(payload.profile) == "table" and payload.profile or nil
            local uid = p and p.id
            local ok_id = (type(uid) == "number" and uid > 0)
                or (type(uid) == "string" and string.match(uid, "^%d+$") ~= nil)
            if not p or not ok_id then
                sysmsg(ctx, "no heatsync profile for '" .. user .. "'" .. (err and (" (" .. tostring(err) .. ")") or ""))
                return
            end
            local who = tostring(p.display_name or p.username or luser)
            net.get_json(net.ORIGIN .. "/api/users/" .. tostring(uid) .. "/emotes", 10000, function(pl, err2)
                local rows = pl and (pl.emotes or pl.data or pl.items)
                if type(rows) ~= "table" then
                    sysmsg(ctx, "couldn't load " .. who .. "'s emotes" .. (err2 and (" (" .. tostring(err2) .. ")") or ""))
                    return
                end
                local items = {}
                for _, e in ipairs(rows) do
                    local rec = net.parse_emote_row(e)
                    if rec then
                        items[#items + 1] = { name = rec.name, url = rec.url, w = rec.w, h = rec.h,
                            hs = true, label = rec.name .. " · " .. who }
                    end
                end
                if #items == 0 then
                    sysmsg(ctx, who .. " has no heatsync emotes")
                    return
                end
                local header = "[heatsync] " .. who .. "'s emotes (" .. #items .. ") — click to insert:"
                if not picker.render(ctx.channel, header, items) then sysmsg(ctx, "inventory render failed") end
            end)
        end)
    end)

    -- archive relay: mirror the public twitch chat you see into heatsync's
    -- searchable archive (the corpus moat). ON by default, opt-out — it sends
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
            sysmsg(ctx, "archive relay is " .. (store.archive_enabled() and "on (default)" or "off") ..
                " · /hsarchive on|off · relays only public twitch chat you're already viewing into heatsync's archive")
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

    -- search the twitch-chat archive (the relay corpus) from chat — the other
    -- half of the flywheel: the relay writes chat in, /hschat reads it back.
    -- filters: @user #channel, everything else is the query text. the server's
    -- /api/archive/search is instant when narrowed to a user or a rare term; a
    -- broad common word across the ~40M-row corpus can hit the 10s ceiling and
    -- 503 — so a bare query defaults to the current channel, and the failure
    -- path tells you to narrow. results deep-link to the exact archived line.
    c2.register_command("/hschat", function(ctx)
        local qparts, user, chan = {}, nil, nil
        for i = 2, #ctx.words do
            local w = ctx.words[i]
            if type(w) == "string" and w ~= "" then
                local at = string.match(w, "^@(.+)$")
                local hash = string.match(w, "^#(.+)$")
                if at then user = string.lower(at)
                elseif hash then chan = string.lower(hash)
                else qparts[#qparts + 1] = w end
            end
        end
        local q = table.concat(qparts, " ")
        if string.len(q) < 2 then
            sysmsg(ctx, "usage: /hschat <query> [@user] [#channel] — search the chat archive; narrow with @user or #channel (broad terms may time out)")
            return
        end
        if user and not is_valid_name(user) then sysmsg(ctx, "invalid @user"); return end
        if chan and not is_valid_name(chan) then sysmsg(ctx, "invalid #channel"); return end
        -- unnarrowed bare query → scope to the current tab so it stays fast +
        -- relevant instead of scanning the whole corpus (a broad common term
        -- across every channel is exactly what times out server-side).
        if not chan and not user then
            pcall(function()
                local n = ctx.channel:get_name()
                if is_valid_name(n) then chan = string.lower(n) end
            end)
        end
        local url = net.ORIGIN .. "/api/archive/search?limit=8&q=" .. net.percent_encode(q)
        if user then url = url .. "&username=" .. net.percent_encode(user) end
        if chan then url = url .. "&channel=" .. net.percent_encode(chan) end
        net.get_json(url, 12000, function(payload, err)
            -- a 10s statement-timeout 503 also lands here (get_json only sees
            -- success/failure); the narrow-it advice is the right answer for both.
            if not payload or type(payload.results) ~= "table" then
                sysmsg(ctx, "archive search failed or timed out — narrow it with @user or #channel (" .. tostring(err) .. ")")
                return
            end
            local rows = payload.results
            local scope = (user and (" @" .. user) or "") .. (chan and (" #" .. chan) or "")
            if #rows == 0 then
                sysmsg(ctx, "no archived lines for '" .. q .. "'" .. scope)
                return
            end
            sysmsg(ctx, #rows .. " archived line(s) for '" .. q .. "'" .. scope .. ":")
            for _, r in ipairs(rows) do
                if type(r) == "table" and type(r.message_id) == "string" then
                    local plat = tostring(r.platform or "twitch")
                    local rchan = tostring(r.channel or "?")
                    local who = tostring(r.display_name or r.username or "?")
                    local body = who .. " · #" .. rchan .. ": " .. preview(r.message, 80)
                    -- timestamp is ISO ("2026-07-02T04:42:00.775Z") → the SSR log
                    -- page path wants the UTC date (first 10 chars), ?m=<id> anchors
                    -- the exact message. no os.date needed (sandbox has no os).
                    local date = type(r.timestamp) == "string" and r.timestamp:sub(1, 10) or nil
                    if date and date:match("^%d%d%d%d%-%d%d%-%d%d$") then
                        linkmsg(ctx, body, net.ORIGIN .. "/logs/" .. net.percent_encode(plat) ..
                            "/" .. net.percent_encode(rchan) .. "/" .. date ..
                            "?m=" .. net.percent_encode(r.message_id))
                    else
                        sysmsg(ctx, body)
                    end
                end
            end
        end)
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
        sysmsg(ctx, "multichat: " .. multichat.summary())
        -- per-tab link breakdown so a merge is legible, not just a count
        local links = multichat.detail()
        for _, l in ipairs(links) do sysmsg(ctx, "  #" .. l.tab .. " ← " .. l.sources) end
    end)

    -- what can this build do? a single discoverable index of every command,
    -- grouped, with a tier note so it's honest about what's unavailable here.
    c2.register_command("/hshelp", function(ctx)
        sysmsg(ctx, "heatsync commands · build " .. caps.name())
        sysmsg(ctx, "emotes: :name tab-complete · /hsemotes menu · /hsfind <q> search · /hsinv <user>")
        sysmsg(ctx, "archive: /hssearch <q> posts · /hschat <q> [@user] [#chan] chat-logs · /hslogs <user> [chan] · /hsmoments [h] [plat] [pg] · /hshot [plat] [pg] · /hswhois <user>")
        sysmsg(ctx, "chat: /hsmulti kick:<slug>|yt:<handle>|off|auto on|off · /hsflame · /hsbadges · /hsblock <name>")
        sysmsg(ctx, "system: /hsstatus · /hsrefresh · /hsarchive on|off · /hsclear")
        if caps.tier < 2 then
            sysmsg(ctx, "note: inline emote rendering + the /hsemotes/hsfind image menus need a nightly build — this is " .. caps.name() .. " (tab-complete + commands work)")
        end
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

    -- top live-chat moments. `/hsmoments [hours] [platform] [page]` — first
    -- number is the lookback window (1-168h, default 24), a platform token
    -- filters, a second number pages. over-fetch once, filter+page client-side.
    local MOM_PER_PAGE = 5
    c2.register_command("/hsmoments", function(ctx)
        local hours, page, plat_filter = 24, 1, nil
        local nums = {}
        for i = 2, #ctx.words do
            local w = ctx.words[i]
            if type(w) == "string" and w ~= "" then
                local n = tonumber(w)
                if n then nums[#nums + 1] = n
                elseif PLAT_ALIAS[string.lower(w)] then plat_filter = PLAT_ALIAS[string.lower(w)] end
            end
        end
        if nums[1] and nums[1] >= 1 and nums[1] <= 168 then hours = math.floor(nums[1]) end
        if nums[2] and nums[2] >= 1 then page = math.floor(nums[2]) end
        local url = net.ORIGIN .. "/api/moments?limit=30&hours=" .. tostring(hours)
        net.get_json(url, 8000, function(payload, err)
            if not payload then
                sysmsg(ctx, "moments fetch failed: " .. tostring(err))
                return
            end
            local raw = payload.moments or payload.data or payload
            local rows = {}
            if type(raw) == "table" then
                for _, m in ipairs(raw) do
                    if type(m) == "table" and m.id and (not plat_filter or tostring(m.platform) == plat_filter) then
                        rows[#rows + 1] = m
                    end
                end
            end
            local total = #rows
            if total == 0 then
                -- over-fetch is the top 30 by rate, so a platform filter can miss
                -- lower-ranked moments — be honest about the window
                sysmsg(ctx, plat_filter
                    and ("no " .. plat_filter .. " moments in the top 30 for the last " .. tostring(hours) .. "h")
                    or ("no moments in the last " .. tostring(hours) .. "h"))
                return
            end
            local pages = math.max(1, math.ceil(total / MOM_PER_PAGE))
            if page > pages then page = pages end
            local from = (page - 1) * MOM_PER_PAGE + 1
            local to = math.min(total, from + MOM_PER_PAGE - 1)
            local nav = pages > 1 and (" · page " .. page .. "/" .. pages ..
                " · /hsmoments " .. hours .. (plat_filter and (" " .. plat_filter) or "") ..
                " " .. (page < pages and page + 1 or 1) .. " for more") or ""
            sysmsg(ctx, "top moments · last " .. tostring(hours) .. "h" ..
                (plat_filter and (" · " .. plat_filter) or "") .. nav)
            for i = from, to do
                local m = rows[i]
                local chan = tostring(m.channel or "?")
                local plat = m.platform and (tostring(m.platform) .. ":") or ""
                local mult = ""
                local rate = tonumber(m.rate)
                local base = tonumber(m.baseline)
                if rate and base and base > 0 then
                    mult = string.format(" · %.0fx", rate / base)
                end
                local title = net.pick_first_str(m, "title", "game") or ""
                if title ~= "" then title = " · " .. title end
                linkmsg(ctx, plat .. "#" .. chan .. mult .. title,
                    net.ORIGIN .. "/moment/" .. net.percent_encode(tostring(m.id)))
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
                if #bits > 0 then sysmsg(ctx, luser .. ": " .. table.concat(bits, " · ")) end
            end
            -- top-channels breakdown: the stats payload already carries it — surface
            -- up to 3 inline instead of flattening to a single "most in #x".
            local tops = payload and payload.topChannels
            if type(tops) == "table" and #tops > 0 then
                local parts = {}
                for i = 1, math.min(3, #tops) do
                    local c = tops[i]
                    if type(c) == "table" and c.channel then
                        local n = tonumber(c.messages or c.count)
                        parts[#parts + 1] = "#" .. tostring(c.channel) .. (n and (" (" .. tostring(n) .. ")") or "")
                    end
                end
                if #parts > 0 then sysmsg(ctx, "top channels: " .. table.concat(parts, " ")) end
            end
            linkmsg(ctx, "archive: " .. luser .. (chan and (" in #" .. string.lower(chan)) or ""), url)
        end)
    end)
end

return M
