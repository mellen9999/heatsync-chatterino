-- /hscard <user> and the right-click "card": a chatter's heatsync card as a few
-- system-style lines (heat, posts, followers, how long they've followed this
-- channel, what the archive knows, their last few lines). the name is a
-- UserInfo link, so clicking it opens chatterino's own usercard.
--
-- one POST /api/card (public, answers without a cookie) carries all of it. if
-- that comes back unusable the same facts are gathered from the plain public
-- endpoints (/api/profile/<u>, /api/twitch/followage) instead.
local net = require("net")
local u = require("cmdutil")

local M = {}

local RECENT_MAX = 3
local ALSO_MAX = 4

local function num(v)
    v = tonumber(v)
    if v and v == v and v >= 0 and v < 1e15 then return math.floor(v) end
    return nil
end

-- "2024-03-01T…" → "2024-03-01" (anything else → nil). pure string work: no os.date.
local function day(s)
    return type(s) == "string" and string.match(s, "^(%d%d%d%d%-%d%d%-%d%d)") or nil
end

-- profile + parts → one flat model, every field shape-checked. nil when there's
-- no usable profile (the caller then falls back / reports it).
local function build_model(login, payload)
    local p = type(payload) == "table" and payload.profile
    if type(p) ~= "table" then return nil end
    local st = type(p.stats) == "table" and p.stats or {}
    local m = {
        login = login,
        id = num(p.id),
        name = net.safe_text(p.display_name, 60) or net.safe_text(p.username, 60) or login,
        shadow = p.is_shadow == true or p.is_shadow_profile == true,
        heat = num(st.user_heat),
        followers = math.max(num(st.followers) or 0, num(p.twitch_followers) or 0),
        live = p.twitch_is_live == true,
    }
    local posts = (num(st.op_count) or 0) + (num(st.re_count) or 0) + (num(st.mop_count) or 0)
    m.posts = posts > 0 and posts or num(st.total_posts)
    local fa = payload.followage
    if type(fa) == "table" and fa.degraded ~= true then
        m.follow = { since = day(fa.followedAt) }
    end
    local c = payload.corpus
    if type(c) == "table" and (num(c.messages) or 0) > 0 then
        m.corpus = { messages = num(c.messages), first_day = day(c.firstDay),
            first_channel = net.safe_text(c.firstChannel, 25), also = {} }
        if type(c.also) == "table" then
            for i = 1, math.min(#c.also, ALSO_MAX) do
                local ch = net.safe_text(c.also[i], 25)
                if ch then m.corpus.also[#m.corpus.also + 1] = ch end
            end
        end
    end
    m.recent = {}
    if type(payload.recent) == "table" then
        for i = 1, #payload.recent do
            if #m.recent >= RECENT_MAX then break end
            local r = payload.recent[i]
            local msg = type(r) == "table" and net.safe_text(r.message, 400)
            if msg then
                local ch = net.safe_text(r.channel, 25)
                local text = u.preview(msg, 90)
                local prev = m.recent[#m.recent]
                -- a pasted-again line (a streamer's link posted 5× in a row) folds into ×n
                if prev and prev.text == text and prev.channel == ch then
                    prev.n = prev.n + 1
                else
                    m.recent[#m.recent + 1] = { channel = ch, text = text, n = 1 }
                end
            end
        end
    end
    return m
end

local function post(channel, elements)
    pcall(function()
        local els = { { type = "text", text = "[heatsync]", color = "system" } }
        for _, e in ipairs(elements) do els[#els + 1] = e end
        channel:add_message(net.new_message({ elements = els }))
    end)
end

local function render(channel, chan_name, m)
    -- the name opens chatterino's usercard where the build knows the link type
    local name_el = { type = "text", text = m.name, color = "link" }
    if c2.LinkType and c2.LinkType.UserInfo ~= nil then
        name_el.link = { type = c2.LinkType.UserInfo, value = m.login }
        name_el.tooltip = "open usercard"
    end
    local bits = {}
    if m.heat and m.heat > 0 then bits[#bits + 1] = "heat " .. tostring(m.heat) end
    if m.posts then bits[#bits + 1] = tostring(m.posts) .. " posts" end
    if m.followers > 0 then bits[#bits + 1] = tostring(m.followers) .. " followers" end
    if m.live then bits[#bits + 1] = "live" end
    local tail = (m.shadow and " (not on heatsync)" or "") ..
        (#bits > 0 and (" · " .. table.concat(bits, " · ")) or "")
    post(channel, { name_el, { type = "text", text = tail } })

    if m.follow and chan_name then
        u.sysmsg({ channel = channel }, m.follow.since
            and ("following #" .. chan_name .. " since " .. m.follow.since)
            or ("not following #" .. chan_name))
    end
    if m.corpus then
        local line = tostring(m.corpus.messages) .. " msgs archived"
        if m.corpus.first_day then
            line = line .. " · first seen " .. m.corpus.first_day ..
                (m.corpus.first_channel and (" in #" .. m.corpus.first_channel) or "")
        end
        if #m.corpus.also > 0 then line = line .. " · also in #" .. table.concat(m.corpus.also, " #") end
        u.sysmsg({ channel = channel }, line)
    end
    for _, r in ipairs(m.recent) do
        u.sysmsg({ channel = channel }, (r.channel and ("#" .. r.channel .. " · ") or "") .. r.text ..
            (r.n > 1 and (" ×" .. tostring(r.n)) or ""))
    end
    u.linkmsg({ channel = channel }, "card: " .. m.name, net.ORIGIN .. "/u/" .. net.percent_encode(m.name))
end

-- the plain public endpoints, for when /api/card is unusable
local function fallback(login, chan_name, done)
    net.get_json(net.ORIGIN .. "/api/profile/" .. net.percent_encode(login) .. "?platform=twitch", 8000, function(profile_payload)
        if type(profile_payload) ~= "table" then return done(nil) end
        local payload = { profile = profile_payload.profile }
        if not chan_name or chan_name == login then return done(payload) end
        net.get_json(net.ORIGIN .. "/api/twitch/followage?user=" .. net.percent_encode(login) ..
            "&channel=" .. net.percent_encode(chan_name), 8000, function(fa)
            payload.followage = fa
            done(payload)
        end)
    end)
end

-- shared by /hscard and the right-click "card" action; `channel` is a real
-- c2.Channel either way.
function M.show(channel, user)
    local ctx = { channel = channel }
    if not u.is_valid_name(user) then
        u.sysmsg(ctx, "usage: /hscard <user> — heatsync card: heat, posts, follows, archive, last lines")
        return
    end
    local login = string.lower(user)
    local chan_name = nil
    pcall(function()
        local n = channel:get_name()
        if u.is_valid_name(n) then chan_name = string.lower(n) end
    end)
    local function finish(payload)
        local m = build_model(login, payload)
        if m then
            render(channel, chan_name, m)
            -- logged in (opt-in): your note on them + whether you follow them
            pcall(require("cmd_account").card_extras, channel, login, m.id, m.shadow)
            return
        end
        u.sysmsg(ctx, "no card for '" .. login .. "'")
    end
    net.post_json(net.ORIGIN .. "/api/card", { platform = "twitch", login = login, channel = chan_name }, 10000,
        function(payload)
            if build_model(login, payload) then return finish(payload) end
            fallback(login, chan_name, finish)
        end)
end

function M.register()
    c2.register_command("/hscard", function(ctx)
        M.show(ctx.channel, ctx.words[2])
    end)
end

return M
