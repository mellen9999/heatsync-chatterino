-- multichat: pull Kick + YouTube live chat from heatsync.org and inject it
-- into a chatterino (twitch) tab, tagged [K]/[Y]. chatterino has no native
-- Kick/YouTube — this makes heatsync the cross-platform chat layer inside it.
-- the data flows through heatsync's WS (which already ingests kick+yt chat),
-- so nothing here is reusable without heatsync.
--
-- model: `/hsmulti kick:<slug>` in a twitch tab LINKS that source's chat into
-- the current chatterino channel; an incoming line is injected via
-- Channel:add_message into every chatterino channel it's linked to.
--
-- WS contract (verified against server 2026-07):
--   kick sub   → channel:join {platform:kick, channel:slug}  (rides ws.join,
--                so it auto-replays on reconnect)
--   kick live  → kick-chat-message { data:{channel,username,displayName,
--                content,color,id,timestamp,hsEmotes:{word->ref},...} }
--   kick hist  → kick-chat-backfill { channel, messages:[<same data>...] }
--   yt sub     → youtube:subscribe {url:<handle|url>, channelId:<routing tag>}
--                (channelId is echoed back on every youtube:chat → we route on
--                it; the channel must be LIVE or subscribe errors)
--   yt live+hist → youtube:chat { channelId, messages:[{id,user,text,emotes,
--                timestamp,color,amount,systemMsg,hsEmotes:{word->ref},...}],
--                replay? }
--   yt status  → youtube:status { videoId, status, error?, channelId,
--                channelName?, title? } — status is one of connected|ended|
--                not-live|chat-off|no-slot|error (server/services/ws-protocol.ts
--                YouTubeLegStatus)
--
-- hsEmotes: server/services/emote-enrich.ts computes each ref
-- {url,provider,zeroWidth?,nsfw?,cw_cats?} from the SENDER's own heatsync
-- inventory (server-side, at fanout time) — never from this plugin's search/
-- catalog cache, so rendering these preserves the privacy invariant the same
-- way render.lua's sender-inventory-only rule does.
local net = require("net")
local ws = require("ws")
local img = require("img")
local caps = require("caps")
local store = require("store")

local M = {
    -- fn(routing_tag, status) — wired by init.lua to live.lua's youtube feed.
    -- NOT required directly (live.lua already requires multichat; requiring it
    -- back here would be circular) — same indirection pattern as ws.on_reconnect.
    on_youtube_status = nil,
}

local LINKS_FILE = "multichat.txt"
local KICK_COLOR = "#53fc18"
local YT_COLOR = "#ff0000"
local DEDUP_MAX = 800
-- kick emotes come embedded in the text as [emote:<id>:<name>] tokens and are
-- a png/gif at this CDN path, sized within a 70px box (width varies per
-- emote/frame; not a fixed 70x70 — animated frames differ, some are smaller).
local KICK_EMOTE_URL = "https://files.kick.com/emotes/%s/fullsize"

-- youtube delivers per-message emotes as {alt=":shortcode:", url} and embeds
-- the shortcodes in the text. render each shortcode present in the emote map
-- as an image (bumped to 48px via the ggpht size params for crispness).
-- cap emote elements built from ONE message: the batch cap bounds messages, but
-- a single hostile line could carry hundreds of thousands of emote tokens and
-- blow the element table + image-load attempts. a real message has a handful.
-- shared with hsEmotes rendering below (native platform emotes + heatsync
-- emotes come out of the same per-message image-element budget).
local MAX_EMOTE_TOKENS = 50

-- hsEmotes refs are a server-computed map word->ref for THIS message's sender
-- (see the module comment). cap how many entries we even validate: the field
-- rides on an untrusted ws frame, so a hostile/misbehaving server attaching a
-- huge map must not turn one message into an unbounded gate-check scan — a
-- real message uses a handful of distinct emotes.
local MAX_HS_REFS_SCANNED = 100

-- validate + content-warning-gate the raw hsEmotes map once per message,
-- rather than re-checking each field on every word-scan hit. returns nil if
-- there's nothing usable (matches the "no map" fast path everywhere else).
local function sanitize_hs_refs(raw)
    if type(raw) ~= "table" then return nil end
    local out = nil
    local n = 0
    for name, ref in pairs(raw) do
        n = n + 1
        if n > MAX_HS_REFS_SCANNED then break end
        if type(ref) == "table" and net.is_safe_name(name) and net.is_safe_url(ref.url)
            and not net.is_cw_blocked(ref) then
            out = out or {}
            out[name] = ref
        end
    end
    return out
end

-- one heatsync-emote element for an already-sanitized (name, ref) pair, or nil
-- if it's locally blocked or the image fails to build (caller falls back to
-- the plain word). dims are unknown on a ref (see HsEmoteRef) — 32 matches the
-- 1x tier height for_hs_emote already clamps every heatsync emote to.
local function build_hs_elem(word, ref)
    if store.is_blocked(word) then return nil end
    local set = caps.images and img.for_hs_emote(ref.url, 32) or nil
    if not set then return nil end
    return {
        type = "scaling-image",
        images = set,
        flags = c2.MessageElementFlag.EmoteImage,
        tooltip = word .. " · heatsync",
        -- left-click inserts the name, same as render.lua's own hs emotes
        link = { type = c2.LinkType.InsertText, value = word .. " " },
    }
end

-- emit `text` as elements, splitting on words that match a sanitized hs-refs
-- map (nil hs → the whole span is one text element, the common/fast path).
-- shares `budget` (a {n=} table) with the caller's native-emote token count.
-- returns true iff at least one hs emote actually rendered (so the caller
-- knows the message was worth rebuilding even with no native emote tokens).
local function emit_text_with_hs(elems, text, hs, budget)
    if text == "" then return false end
    if not hs then
        elems[#elems + 1] = { type = "text", text = text }
        return false
    end
    local run = {}
    local found = false
    for word in text:gmatch("%S+") do
        local ref = budget.n < MAX_EMOTE_TOKENS and hs[word]
        local el = ref and build_hs_elem(word, ref)
        if el then
            if #run > 0 then
                elems[#elems + 1] = { type = "text", text = table.concat(run, " ") }
                for i = #run, 1, -1 do run[i] = nil end
            end
            elems[#elems + 1] = el
            budget.n = budget.n + 1
            found = true
        else
            run[#run + 1] = word
        end
    end
    if #run > 0 then elems[#elems + 1] = { type = "text", text = table.concat(run, " ") } end
    return found
end

local function build_yt_body(text, emotes, hs_raw)
    if type(text) ~= "string" or text == "" then return nil end
    local hs = sanitize_hs_refs(hs_raw)
    local map = {}
    if type(emotes) == "table" then
        for i, em in ipairs(emotes) do
            if i > MAX_EMOTE_TOKENS then break end
            -- em.url + em.alt are raw ws-payload fields (untrusted, MITM-able) that
            -- reach img.for_url / become map keys — bound them like every other
            -- emote path does, else 250×50 arbitrary-size urls per frame is an OOM knob.
            if type(em) == "table" and net.is_safe_name(em.alt) and net.is_safe_url(em.url) then
                map[em.alt] = em.url
            end
        end
    end
    local has_yt_map = next(map) ~= nil
    if not has_yt_map and not hs then return nil end
    local elems = {}
    local last = 1
    local found = false
    local budget = { n = 0 }
    if has_yt_map then
        for s, tok, e in text:gmatch("()(:[%w_+%-]+:)()") do
            if budget.n >= MAX_EMOTE_TOKENS then break end
            local url = map[tok]
            if url then
                found = true
                if s > last and emit_text_with_hs(elems, text:sub(last, s - 1), hs, budget) then found = true end
                -- bump the ggpht size param to 48px for a crisp downscale. only
                -- assert {48,48} dims when the bump actually applied (we then know
                -- the image is 48px); otherwise w=nil so chatterino scales the
                -- real image to height — asserting a wrong size renders it huge
                -- (the bug that hit kick's variable-size emotes).
                local big, bumped = url:gsub("=w%d+%-h%d+", "=w48-h48")
                local set = caps.images and img.for_url(big, bumped > 0 and 48 or nil, 48) or nil
                if set then
                    elems[#elems + 1] = { type = "scaling-image", images = set,
                        flags = c2.MessageElementFlag.EmoteImage, tooltip = tok .. " · youtube" }
                else
                    elems[#elems + 1] = { type = "text", text = tok }
                end
                last = e
                budget.n = budget.n + 1
            end
        end
    end
    if emit_text_with_hs(elems, text:sub(last), hs, budget) then found = true end
    if not found then return nil end
    return elems
end

-- split a kick message body on [emote:id:name] tokens (and, separately, any
-- word matching an hsEmotes ref) into text runs + scaling-image emotes.
-- returns nil if nothing rendered (caller uses a single plain-text element) —
-- keeps the common path allocation-free.
local function build_kick_body(content, hs_raw)
    if type(content) ~= "string" or content == "" then return nil end
    local hs = sanitize_hs_refs(hs_raw)
    local has_bracket = content:find("[emote:", 1, true) ~= nil
    if not has_bracket and not hs then return nil end
    local elems = {}
    local last = 1
    local found = false
    local budget = { n = 0 }
    if has_bracket then
        for s, id, name, e in content:gmatch("()%[emote:(%d+):([^%]]+)%]()") do
            if budget.n >= MAX_EMOTE_TOKENS then break end
            found = true
            if s > last and emit_text_with_hs(elems, content:sub(last, s - 1), hs, budget) then found = true end
            -- w=nil so chatterino scales the ACTUAL loaded image to line height
            -- (like the 7tv path). kick emotes aren't a fixed 70x70 — widths vary
            -- per frame and some are smaller — so passing explicit {70,70} forced a
            -- literal 70px (huge/stretched) render. h=70 = the emote box max height.
            local set = caps.images and img.for_url(string.format(KICK_EMOTE_URL, id), nil, 70) or nil
            if set then
                elems[#elems + 1] = { type = "scaling-image", images = set,
                    flags = c2.MessageElementFlag.EmoteImage, tooltip = name .. " · kick" }
            else
                elems[#elems + 1] = { type = "text", text = name }
            end
            last = e
            budget.n = budget.n + 1
        end
    end
    if emit_text_with_hs(elems, content:sub(last), hs, budget) then found = true end
    if not found then return nil end
    return elems
end

-- links[cc_name] = { [source_key] = { platform=, channel= } }
-- source_key = "kick/<slug>" | "yt/<routing-tag>"
local links = {}
-- routes[source_key] = { [cc_name]=true }  (O(1) inject routing)
local routes = {}
-- yt_video[routing_tag] = videoId  (learned from youtube:status, for unsub)
local yt_video = {}
-- yt_status[routing_tag] = last known status string — dedupes the status line
-- (and the live.lua feed) to fire only on an actual CHANGE, not every poll.
local yt_status = {}
-- dedup seen ids: a fixed-size circular buffer instead of a fifo array. the old
-- table.remove(order, 1) was an O(n) shift on EVERY message once full (800-wide
-- at scale) — the ring evicts in O(1) by overwriting the oldest slot.
local seen = {}          -- id -> true (membership)
local ring = {}          -- slot(1..DEDUP_MAX) -> id currently occupying it
local ring_pos = 0       -- monotonic write cursor; slot = (pos % DEDUP_MAX) + 1
-- lines dropped before injection (no routing tag, or target tab gone/volatile).
-- surfaced in /hsstatus so a silently-vanishing multichat is legible, not a
-- mystery (multichat.lua injection used to drop with no signal at all).
M.dropped = 0

local function source_key(platform, channel)
    return platform .. "/" .. string.lower(channel)
end

local function add_route(key, cc_name)
    routes[key] = routes[key] or {}
    routes[key][cc_name] = true
end

local function drop_route(key, cc_name)
    if routes[key] then
        routes[key][cc_name] = nil
        if next(routes[key]) == nil then routes[key] = nil end
    end
end

-- ----- WS subscribe/unsubscribe -----
local function subscribe(platform, channel)
    if platform == "kick" then
        ws.join("kick", channel) -- reuses channel:join + reconnect replay
    elseif platform == "yt" then
        -- channelId is an opaque routing tag echoed back on youtube:chat
        ws.send({ type = "youtube:subscribe", url = channel, channelId = string.lower(channel) })
    end
end

local function unsubscribe(platform, channel)
    if platform == "kick" then
        ws.leave("kick", channel)
    elseif platform == "yt" then
        local key = string.lower(channel)
        local vid = yt_video[key]
        if vid then ws.send({ type = "youtube:unsubscribe", videoId = vid }) end
        -- no videoId yet → the server poller ref-counts + reaps on drop anyway.
        -- prune the entry either way so the map can't grow one string per distinct
        -- youtube channel ever linked over days of channel-hopping uptime.
        yt_video[key] = nil
        yt_status[key] = nil
    end
end

-- ----- persistence -----
local function persist()
    local lines = {}
    for cc_name, srcs in pairs(links) do
        for _, s in pairs(srcs) do
            lines[#lines + 1] = cc_name .. "\t" .. s.platform .. "\t" .. s.channel
        end
    end
    net.write_data(LINKS_FILE, table.concat(lines, "\n"))
end

-- ----- dedup -----
local function is_dup(id)
    if type(id) ~= "string" or id == "" then return false end
    if seen[id] then return true end
    seen[id] = true
    local slot = (ring_pos % DEDUP_MAX) + 1
    local evicted = ring[slot]
    if evicted ~= nil then seen[evicted] = nil end
    ring[slot] = id
    ring_pos = ring_pos + 1
    return false
end

-- ----- linking -----
-- auto=true marks an ephemeral auto-multichat link (re-derived when the twitch
-- tab opens, reaped when it closes); it is never written to disk. a manual
-- /hsmulti link (auto nil) is persistent.
function M.link(cc_name, platform, channel, auto)
    if type(cc_name) ~= "string" or cc_name == "" then return false end
    if type(channel) ~= "string" or channel == "" then return false end
    local key = source_key(platform, channel)
    links[cc_name] = links[cc_name] or {}
    local existing = links[cc_name][key]
    if existing then
        -- manual intent promotes an existing ephemeral link to persistent
        if existing.auto and not auto then existing.auto = nil; persist() end
        return false
    end
    links[cc_name][key] = { platform = platform, channel = string.lower(channel), auto = auto or nil }
    add_route(key, cc_name)
    if not auto then persist() end
    subscribe(platform, string.lower(channel))
    return true
end

-- reap the ephemeral auto-multichat links for a twitch tab that just closed.
-- manual (/hsmulti) links are persistent and left intact — this only prevents
-- auto links + their ws subscriptions growing unbounded across a long session
-- of opening and closing channels.
function M.unlink_auto(cc_name)
    local srcs = links[cc_name]
    if not srcs then return end
    for key, s in pairs(srcs) do
        if s.auto then
            srcs[key] = nil
            drop_route(key, cc_name)
            if not routes[key] then unsubscribe(s.platform, s.channel) end
        end
    end
    if next(srcs) == nil then links[cc_name] = nil end
end

-- unlink one source, or ALL sources for a tab if platform is nil
function M.unlink(cc_name, platform, channel)
    if not links[cc_name] then return 0 end
    local removed = 0
    local function drop(key, s)
        drop_route(key, cc_name)
        if not routes[key] then unsubscribe(s.platform, s.channel) end
        removed = removed + 1
    end
    if platform then
        local key = source_key(platform, channel)
        local s = links[cc_name][key]
        if s then links[cc_name][key] = nil; drop(key, s) end
    else
        for key, s in pairs(links[cc_name]) do
            links[cc_name][key] = nil
            drop(key, s)
        end
    end
    if links[cc_name] and next(links[cc_name]) == nil then links[cc_name] = nil end
    persist()
    return removed
end

-- reverse lookup for the live-status feature: which chatterino (twitch) tabs is
-- this (platform, channel) source linked into? empty if none — so a stream event
-- only surfaces for a source the user actually merged.
function M.tabs_for(platform, channel)
    local out = {}
    local targets = routes[source_key(platform, channel)]
    if targets then for cc in pairs(targets) do out[#out + 1] = cc end end
    return out
end

function M.list(cc_name)
    local out = {}
    if links[cc_name] then
        for key in pairs(links[cc_name]) do out[#out + 1] = key end
        table.sort(out)
    end
    return out
end

-- called whenever the ws comes up (first connect after disk-load AND every
-- reconnect, via ws.on_reconnect). subscribes every linked source. kick joins
-- are idempotent (ws.join no-ops if already in the replayed set); yt always
-- needs an explicit re-subscribe (pollers are per-video, not replayed).
function M.on_ws_up()
    for _, srcs in pairs(links) do
        for _, s in pairs(srcs) do subscribe(s.platform, s.channel) end
    end
end

-- ----- injection -----
-- built ONCE at load, not re-created as a closure per target per message (a
-- 250-line flood × N tabs would otherwise allocate a closure + upvalues each
-- line). returns true on success, false if the target tab was gone (a drop);
-- raises on a build failure, which the caller pcall-catches.
local function inject_one(cc_name, line, tag, tag_color, display, uname_color, body, text)
    local ch = c2.Channel.by_name(cc_name)
    if not ch or not ch:is_valid() then return false end
    local elems = {}
    if type(line.time_ms) == "number" and line.time_ms > 0 then
        elems[#elems + 1] = { type = "timestamp", time = line.time_ms }
    end
    elems[#elems + 1] = { type = "text", text = tag, color = tag_color }
    elems[#elems + 1] = {
        type = "text",
        text = display .. ":",
        color = uname_color,
        flags = c2.MessageElementFlag.Username,
    }
    if body then
        for _, be in ipairs(body) do elems[#elems + 1] = be end
    else
        elems[#elems + 1] = { type = "text", text = text }
    end
    local uname = type(line.username) == "string" and line.username or display
    if #uname > 100 then uname = uname:sub(1, 100) end
    ch:add_message(net.new_message({
        login_name = string.lower(uname),
        display_name = display,
        message_text = text,
        search_text = text,
        username_color = uname_color,
        elements = elems,
    }))
    return true
end

-- a systemic build failure (e.g. a missing element-type on an older build) fires
-- per message; during a flood that would compound log+concat cost exactly when
-- load is highest. log once, then at most once per 30s.
local last_inject_warn_s = nil
local function warn_inject_fail(err)
    local now = net.now()
    if last_inject_warn_s == nil or (now - last_inject_warn_s) >= 30 then
        last_inject_warn_s = now
        net.log_warn("multichat inject failed: " .. tostring(err))
    end
end

local function inject(line)
    -- a partial server message (missing channel/routing tag) must drop quietly,
    -- not throw in source_key's string.lower — every other field below is
    -- type-checked, so this is the one gap. both handlers funnel through here.
    if type(line.channel) ~= "string" or line.channel == "" then M.dropped = M.dropped + 1; return end
    local key = source_key(line.platform, line.channel)
    local targets = routes[key]
    if not targets then return end
    -- dedup scoped BY SOURCE: two sources linked to the same tab that happen to
    -- share a message id can't shadow each other. a nil/blank id means "can't
    -- dedup" and injects (is_dup handles the non-string case for the raw path).
    if type(line.id) == "string" and line.id ~= "" and is_dup(key .. "\1" .. line.id) then return end
    local text = line.text
    if type(text) ~= "string" or text == "" then return end
    -- bound field lengths from the untrusted ws payload: a multi-MB username or
    -- text would otherwise be built straight into a chat element (cheap DoS knob)
    if #text > 2000 then text = text:sub(1, 2000) end
    local display = line.display
    if type(display) ~= "string" or display == "" then display = line.username or "?" end
    if #display > 100 then display = display:sub(1, 100) end
    local tag = line.platform == "kick" and "[K]" or "[Y]"
    local tag_color = line.platform == "kick" and KICK_COLOR or YT_COLOR
    -- accept the chatter's own color only if it's a real #rrggbb hex — this is
    -- the one field taken from a remote chatter unvalidated; a garbage value
    -- would either break the element or paint an unreadable name.
    local uname_color = tag_color
    if type(line.color) == "string" and string.match(line.color, "^#%x%x%x%x%x%x$") then
        uname_color = line.color
    end
    -- render platform emotes as images: kick's [emote:id:name] tokens,
    -- youtube's per-message shortcode+url list
    local body
    if line.platform == "kick" then
        body = build_kick_body(text, line.hsEmotes)
    elseif line.platform == "yt" then
        body = build_yt_body(text, line.emotes, line.hsEmotes)
    end

    for cc_name in pairs(targets) do
        local ok, res = pcall(inject_one, cc_name, line, tag, tag_color, display, uname_color, body, text)
        -- res==false: target tab closed/volatile (a drop). not ok: a systemic
        -- build failure. both bump the dropped counter so /hsstatus shows
        -- multichat isn't delivering rather than failing invisibly.
        if not ok then
            M.dropped = M.dropped + 1
            warn_inject_fail(res)
        elseif res == false then
            M.dropped = M.dropped + 1
        end
    end
end

-- ----- WS dispatch (called from init's event handler) -----
local function handle_kick(d)
    if type(d) ~= "table" then return end
    inject({
        platform = "kick",
        channel = d.channel,
        id = d.id,
        username = d.username,
        display = d.displayName,
        text = d.content,
        color = d.color,
        time_ms = tonumber(d.timestamp),
        hsEmotes = d.hsEmotes,
    })
end

local function handle_yt(m, routing_tag)
    if type(m) ~= "table" then return end
    -- superchat: prefix the amount; membership/gift: fall back to systemMsg
    local text = m.text
    if type(m.amount) == "string" and m.amount ~= "" then
        text = m.amount .. " " .. (text or "")
    elseif (not text or text == "") and type(m.systemMsg) == "string" then
        text = m.systemMsg
    end
    inject({
        platform = "yt",
        channel = routing_tag,
        id = m.id,
        username = m.user,
        display = m.user,
        text = text,
        color = m.color,
        time_ms = tonumber(m.timestamp),
        emotes = m.emotes,
        hsEmotes = m.hsEmotes,
    })
end

-- cap per-batch injection: the socket is anonymous, so a compromised/hostile
-- server (or a MITM) could push a backfill of a million lines to freeze the
-- client with add_message calls. a real backfill is a few dozen.
local MAX_BATCH = 250

-- keep the LAST MAX_BATCH of an oversized batch: backfills arrive oldest-first,
-- and a viewer wants the most-recent lines, not the oldest (dedup means the
-- newest are what's missing from their view). returns the start index.
local function batch_start(msgs)
    return math.max(1, #msgs - MAX_BATCH + 1)
end

-- terse lowercase status lines for a linked yt source that isn't chatting.
-- "connected" and "error" aren't here: connected is silent (the chat just
-- starts flowing) and error already gets its own log_warn below.
local STATUS_LINE = {
    ["not-live"] = "youtube: not live",
    ["ended"] = "youtube: stream ended",
    ["chat-off"] = "youtube: chat is off for this stream",
    ["no-slot"] = "youtube: no free youtube slot right now (retrying)",
}

-- returns true if the message was a multichat message (handled)
function M.dispatch(msg)
    local t = msg.type
    if t == "kick-chat-message" then
        handle_kick(msg.data)
        return true
    elseif t == "kick-chat-backfill" then
        if type(msg.messages) == "table" then
            for i = batch_start(msg.messages), #msg.messages do
                handle_kick(msg.messages[i])
            end
        end
        return true
    elseif t == "youtube:chat" then
        local tag = msg.channelId
        if type(tag) ~= "string" or tag == "" then return true end
        -- skip the history replay batch the server sends on subscribe / poller
        -- restart (replay=true) — the user wants the link line + only NEW
        -- messages, not a dump of the whole youtube backlog. live messages come
        -- as youtube:chat with no replay flag.
        if msg.replay == true then return true end
        if type(msg.messages) == "table" then
            for i = batch_start(msg.messages), #msg.messages do
                handle_yt(msg.messages[i], tag)
            end
        end
        return true
    elseif t == "youtube:status" then
        local tag = type(msg.channelId) == "string" and string.lower(msg.channelId) or nil
        local status = msg.status
        if tag and type(status) == "string" and yt_status[tag] ~= status then
            yt_status[tag] = status
            local line = STATUS_LINE[status]
            if line then
                for _, cc in ipairs(M.tabs_for("yt", tag)) do
                    pcall(function()
                        local ch = c2.Channel.by_name(cc)
                        if ch and ch:is_valid() then ch:add_system_message("[heatsync] " .. line) end
                    end)
                end
            end
            -- youtube never emits stream:online/offline (that taxonomy is kick/
            -- twitch's) — feed live.lua's go-live/offline line straight off this
            -- status change instead. no-op if live.lua's hook isn't wired (t0/t1
            -- boot order, or the toggle is off — live.lua checks that itself).
            if M.on_youtube_status then pcall(M.on_youtube_status, tag, status) end
        end
        if status == "connected" and tag and type(msg.videoId) == "string" then
            yt_video[tag] = msg.videoId
        elseif status == "error" then
            net.log_warn("multichat youtube: " .. tostring(msg.error))
        end
        return true
    end
    return false
end

-- driven by init's existing 60s reconcile tick (no new timer): a linked yt
-- source that isn't connected re-subscribes every OTHER call (~120s), well
-- under the server's 5-subs/60s-per-socket cap even with several linked yt
-- sources. stops on its own once the source reports connected, or once it's
-- unlinked (links[] no longer has it, so the loop below never sees it again).
local yt_retry_ticks = 0
function M.retry_yt_tick()
    yt_retry_ticks = yt_retry_ticks + 1
    if yt_retry_ticks % 2 ~= 0 then return end
    for _, srcs in pairs(links) do
        for _, s in pairs(srcs) do
            if s.platform == "yt" and yt_status[string.lower(s.channel)] ~= "connected" then
                subscribe("yt", s.channel)
            end
        end
    end
end

-- load persisted links at boot; re-subscribe on ws connect
function M.load()
    local raw = net.read_data(LINKS_FILE)
    if type(raw) ~= "string" then return end
    for cc_name, platform, channel in string.gmatch(raw, "([^\t\r\n]+)\t([^\t\r\n]+)\t([^\t\r\n]+)") do
        local key = source_key(platform, channel)
        links[cc_name] = links[cc_name] or {}
        links[cc_name][key] = { platform = platform, channel = string.lower(channel) }
        add_route(key, cc_name)
    end
end

function M.stats()
    local n = 0
    for _, srcs in pairs(links) do
        for _ in pairs(srcs) do n = n + 1 end
    end
    return n
end

-- a one-line legibility summary for /hsstatus: how many sources across how many
-- tabs, and how many lines have been dropped (target tab gone / malformed).
function M.summary()
    local sources, tabs = 0, 0
    for _, srcs in pairs(links) do
        tabs = tabs + 1
        for _ in pairs(srcs) do sources = sources + 1 end
    end
    local s = tostring(sources) .. " source(s) across " .. tostring(tabs) .. " tab(s)"
    -- counted per failed delivery (a line fanned to N gone tabs is N drops), so
    -- "drop(s)" not "line(s)" — the number is deliveries lost, not distinct lines
    if M.dropped > 0 then s = s .. " · " .. tostring(M.dropped) .. " drop(s) (tab gone/malformed)" end
    return s
end

-- per-tab link breakdown for /hsstatus: [{ tab = "#chan", sources = "kick/x yt/y" }]
function M.detail()
    local out = {}
    for tab, srcs in pairs(links) do
        local keys = {}
        for key in pairs(srcs) do keys[#keys + 1] = key end
        table.sort(keys)
        out[#out + 1] = { tab = tab, sources = table.concat(keys, " ") }
    end
    table.sort(out, function(a, b) return a.tab < b.tab end)
    return out
end

return M
