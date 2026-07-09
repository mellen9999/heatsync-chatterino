-- archive + discovery commands: post/chat search, logs, whois, hot streams,
-- moments, archive relay toggle.
local net = require("net")
local store = require("store")
local u = require("cmdutil")

local M = {}

function M.register()
    -- hottest live streams right now (cross-platform, heat-ranked). click a
    -- twitch one to open it in chatterino. `/hshot` top page · `/hshot 2` next
    -- page · `/hshot kick` filter to a platform · `/hshot kick 2` both.
    -- we over-fetch once and filter+page CLIENT-SIDE — no unverified server
    -- params — so a platform filter and paging cost nothing extra.
    local HOT_PER_PAGE = 10
    c2.register_command("/hshot", function(ctx)
        local plat_filter, page, bad = u.parse_plat_page(ctx.words, 2)
        if bad then u.sysmsg(ctx, "ignoring unrecognized filter '" .. bad .. "' (use twitch/kick/youtube)") end
        net.get_json(net.ORIGIN .. "/api/live/top?limit=50", 8000, function(payload, err)
            if not payload or type(payload.streams) ~= "table" then
                u.sysmsg(ctx, "hot streams unavailable: " .. tostring(err))
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
                u.sysmsg(ctx, plat_filter
                    and ("no " .. plat_filter .. " streams in the current top 50 by heat")
                    or "no live streams right now")
                return
            end
            local pages, from, to
            pages, page, from, to = u.paginate(total, page, HOT_PER_PAGE)
            local nav = pages > 1 and (" · page " .. page .. "/" .. pages ..
                " · /hshot " .. (plat_filter and (plat_filter .. " ") or "") .. (page < pages and page + 1 or 1) .. " for more") or ""
            u.sysmsg(ctx, "🔥 hottest live now" .. (plat_filter and (" · " .. plat_filter) or "") .. nav .. ":")
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
            u.sysmsg(ctx, "usage: /hswhois <user> — heatsync profile card (heat, followers, live, posts)")
            return
        end
        net.get_json(net.ORIGIN .. "/api/profile/" .. net.percent_encode(string.lower(user)), 8000, function(payload, err)
            local p = payload and payload.profile
            if not p then
                u.sysmsg(ctx, "no profile for '" .. user .. "'" .. (err and (" (" .. tostring(err) .. ")") or ""))
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
    c2.register_command("/hssearch", function(ctx)
        local q = u.join_args(ctx.words)
        if string.len(q) < 2 then
            u.sysmsg(ctx, "usage: /hssearch <query> — searches heatsync posts; click a result to open the thread")
            return
        end
        local url = net.ORIGIN .. "/api/search?q=" .. net.percent_encode(q) .. "&limit=" .. tostring(SEARCH_LIMIT)
        net.get_json(url, 8000, function(payload, err)
            local rows = payload and payload.results
            if type(rows) ~= "table" then
                u.sysmsg(ctx, "search failed: " .. tostring(err))
                return
            end
            if #rows == 0 then
                u.sysmsg(ctx, "no heatsync posts for '" .. q .. "'")
                return
            end
            -- header matches the rows actually listed (loop caps at SEARCH_LIMIT),
            -- and is honest when the cap was hit and there may be more
            local more = (#rows >= SEARCH_LIMIT) and (" (top " .. SEARCH_LIMIT .. " — refine to narrow)") or ""
            u.sysmsg(ctx, math.min(#rows, SEARCH_LIMIT) .. " heatsync post(s) for '" .. q .. "'" .. more .. ":")
            for i, r in ipairs(rows) do
                if i > SEARCH_LIMIT then break end
                local id = type(r) == "table" and net.pick_first_str(r, "base36_id", "id")
                if id then
                    local who = tostring(r.display_name or r.username or "?")
                    local heat = tonumber(r.heat)
                    local suffix = (heat and heat > 0) and (" · heat " .. tostring(math.floor(heat))) or ""
                    u.linkmsg(ctx, who .. ": " .. u.preview(r.content, 80) .. suffix,
                        net.ORIGIN .. "/thread/" .. net.percent_encode(id))
                end
            end
        end)
    end)

    -- archive relay: mirror the public twitch chat you see into heatsync's
    -- searchable archive (the corpus moat). ON by default, opt-out — it sends
    -- public PRIVMSGs you already see to heatsync (first-party, no whispers).
    c2.register_command("/hsarchive", function(ctx)
        local arg = ctx.words[2]
        if arg == "on" then
            store.set_archive(true)
            u.sysmsg(ctx, "archive relay ON — public twitch chat you view now feeds heatsync's searchable archive (first-party, PRIVMSG only, dedup'd)")
        elseif arg == "off" then
            store.set_archive(false)
            u.sysmsg(ctx, "archive relay OFF")
        else
            u.sysmsg(ctx, "archive relay is " .. (store.archive_enabled() and "on (default)" or "off") ..
                " · /hsarchive on|off · relays only public twitch chat you're already viewing into heatsync's archive")
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
            u.sysmsg(ctx, "usage: /hschat <query> [@user] [#channel] — search the chat archive; narrow with @user or #channel (broad terms may time out)")
            return
        end
        if user and not u.is_valid_name(user) then u.sysmsg(ctx, "invalid @user"); return end
        if chan and not u.is_valid_name(chan) then u.sysmsg(ctx, "invalid #channel"); return end
        -- unnarrowed bare query → scope to the current tab so it stays fast +
        -- relevant instead of scanning the whole corpus (a broad common term
        -- across every channel is exactly what times out server-side).
        if not chan and not user then
            pcall(function()
                local n = ctx.channel:get_name()
                if u.is_valid_name(n) then chan = string.lower(n) end
            end)
        end
        local url = net.ORIGIN .. "/api/archive/search?limit=8&q=" .. net.percent_encode(q)
        if user then url = url .. "&username=" .. net.percent_encode(user) end
        if chan then url = url .. "&channel=" .. net.percent_encode(chan) end
        -- immediate ack: this can take up to 12s (the server's 10s FTS ceiling),
        -- so tell the user it's working instead of a silent gap that reads as a
        -- swallowed command.
        u.sysmsg(ctx, "searching the chat archive…")
        net.get_json(url, 12000, function(payload, err)
            -- a 10s statement-timeout 503 also lands here (get_json only sees
            -- success/failure); the narrow-it advice is the right answer for both.
            if not payload or type(payload.results) ~= "table" then
                u.sysmsg(ctx, "archive search failed or timed out — narrow it with @user or #channel (" .. tostring(err) .. ")")
                return
            end
            local rows = payload.results
            local scope = (user and (" @" .. user) or "") .. (chan and (" #" .. chan) or "")
            if #rows == 0 then
                u.sysmsg(ctx, "no archived lines for '" .. q .. "'" .. scope)
                return
            end
            -- recency_windowed → the server floored a broad/channel search to its
            -- recent window; next_cursor → the page was capped and more exist.
            -- (forward-compatible: both fields are simply absent on older servers.)
            local hint = ""
            if payload.recency_windowed then
                hint = " (recent window — add @user or a date range for older)"
            elseif payload.next_cursor then
                hint = " (more exist — narrow further)"
            end
            u.sysmsg(ctx, #rows .. " archived line(s) for '" .. q .. "'" .. scope .. hint .. ":")
            for _, r in ipairs(rows) do
                if type(r) == "table" and type(r.message_id) == "string" then
                    local plat = tostring(r.platform or "twitch")
                    local rchan = tostring(r.channel or "?")
                    local who = tostring(r.display_name or r.username or "?")
                    local body = who .. " · #" .. rchan .. ": " .. u.preview(r.message, 80)
                    -- timestamp is ISO ("2026-07-02T04:42:00.775Z") → the SSR log
                    -- page path wants the UTC date (first 10 chars), ?m=<id> anchors
                    -- the exact message. no os.date needed (sandbox has no os).
                    local date = type(r.timestamp) == "string" and r.timestamp:sub(1, 10) or nil
                    if date and date:match("^%d%d%d%d%-%d%d%-%d%d$") then
                        u.linkmsg(ctx, body, net.ORIGIN .. "/logs/" .. net.percent_encode(plat) ..
                            "/" .. net.percent_encode(rchan) .. "/" .. date ..
                            "?m=" .. net.percent_encode(r.message_id))
                    else
                        u.sysmsg(ctx, body)
                    end
                end
            end
        end)
    end)

    -- top live-chat moments. `/hsmoments [<n>h] [platform] [page]` — `48h` sets
    -- the lookback window (1-168h, default 24h), a platform token filters, a bare
    -- number pages (so bare numbers mean the same thing here as in /hshot — no
    -- collision with the window). over-fetch once, filter+page client-side.
    local MOM_PER_PAGE = 5
    c2.register_command("/hsmoments", function(ctx)
        local hours, page, plat_filter, bad = 24, 1, nil, nil
        for i = 2, #ctx.words do
            local w = ctx.words[i]
            if type(w) == "string" and w ~= "" then
                local lw = string.lower(w)
                local hr = tonumber(string.match(lw, "^(%d+)h$")) -- "48h" → hours
                local n = tonumber(w)
                if hr then
                    if hr >= 1 and hr <= 168 then hours = hr end
                elseif n and n >= 1 and math.floor(n) == n then
                    page = math.floor(n)
                elseif u.PLAT_ALIAS[lw] then
                    plat_filter = u.PLAT_ALIAS[lw]
                else
                    bad = bad or w
                end
            end
        end
        if bad then u.sysmsg(ctx, "ignoring unrecognized arg '" .. bad .. "' (use <hours>h, a platform, or a page number)") end
        local url = net.ORIGIN .. "/api/moments?limit=30&hours=" .. tostring(hours)
        net.get_json(url, 8000, function(payload, err)
            if not payload then
                u.sysmsg(ctx, "moments fetch failed: " .. tostring(err))
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
                u.sysmsg(ctx, plat_filter
                    and ("no " .. plat_filter .. " moments in the top 30 for the last " .. tostring(hours) .. "h")
                    or ("no moments in the last " .. tostring(hours) .. "h"))
                return
            end
            local pages, from, to
            pages, page, from, to = u.paginate(total, page, MOM_PER_PAGE)
            local nav = pages > 1 and (" · page " .. page .. "/" .. pages ..
                " · /hsmoments " .. hours .. "h" .. (plat_filter and (" " .. plat_filter) or "") ..
                " " .. (page < pages and page + 1 or 1) .. " for more") or ""
            u.sysmsg(ctx, "top moments · last " .. tostring(hours) .. "h" ..
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
                u.linkmsg(ctx, plat .. "#" .. chan .. mult .. title,
                    net.ORIGIN .. "/moment/" .. net.percent_encode(tostring(m.id)))
            end
        end)
    end)

    c2.register_command("/hslogs", function(ctx)
        local user = ctx.words[2]
        if not u.is_valid_name(user) then
            u.sysmsg(ctx, "usage: /hslogs <user> [channel] — chat history + archive link")
            return
        end
        local chan = ctx.words[3]
        if chan and not u.is_valid_name(chan) then chan = nil end
        if not chan then
            pcall(function()
                local n = ctx.channel:get_name()
                if u.is_valid_name(n) then chan = n end
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
                if #bits > 0 then u.sysmsg(ctx, luser .. ": " .. table.concat(bits, " · ")) end
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
                if #parts > 0 then u.sysmsg(ctx, "top channels: " .. table.concat(parts, " ")) end
            end
            u.linkmsg(ctx, "archive: " .. luser .. (chan and (" in #" .. string.lower(chan)) or ""), url)
        end)
    end)
end

return M
