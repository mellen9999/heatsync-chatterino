-- headless smoke harness for the heatsync chatterino plugin.
-- stubs the c2 api surface + chatterino.json, loads the real modules, and
-- drives: caps detection, completion, sender batch flush, ws dispatch +
-- reconnect/backoff, render hook → rebuild → replace.
-- capture the real os for the DRIVER, then strip it from the global env
-- before loading the plugin — chatterino's Lua sandbox exposes no `os`
-- library (only _G/io/math/string/table/utf8), so this catches any os.*
-- usage that would abort plugin load on the real client.
local host_os = os
-- plugin dir: env override, else derive from this script's own path (test/ →
-- parent), else cwd. keeps the suite runnable from a fresh checkout anywhere.
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
local PLUGIN = host_os.getenv("PLUGIN_DIR") or (here .. "/..")
package.path = PLUGIN .. "/?.lua;" .. package.path

local failures = 0
local function check(cond, label)
    if cond then
        print("PASS " .. label)
    else
        failures = failures + 1
        print("FAIL " .. label)
    end
end

-- ---- minimal json (flat-ish, enough for plugin wire messages) ----
local function encode(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v)
    elseif t == "number" or t == "boolean" then return tostring(v)
    elseif t == "table" then
        if #v > 0 then
            local parts = {}
            for _, x in ipairs(v) do parts[#parts + 1] = encode(x) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, x in pairs(v) do parts[#parts + 1] = string.format("%q", k) .. ":" .. encode(x) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

-- parse: harness only ever feeds tables through a side channel, so parse
-- decodes via a registry of pre-registered payloads keyed by marker string.
local parse_registry = {}
local function register_payload(t)
    local key = "@@" .. tostring(#parse_registry + 1)
    parse_registry[key] = t
    return key
end
local function decode(s)
    if parse_registry[s] then return parse_registry[s] end
    error("harness parse: unregistered payload " .. tostring(s))
end

package.preload["chatterino.json"] = function()
    return { parse = decode, stringify = encode }
end

-- ---- c2 stub ----
local timers = {}       -- {fn, at_ms}
local now_ms = 0
local http_queue = {}   -- pending requests: {url, on_success, on_error}
local commands = {}
local completion_cb = nil
local menu_cb = nil -- registered handler for on_channelview_context_menu_requested
local log_lines = {}

c2 = {}
c2.LogLevel = { Debug = 1, Info = 2, Warning = 3, Critical = 4 }
c2.EventType = { CompletionRequested = "completion" }
c2.ChannelType = { None = 0, Twitch = 8, Misc = 9 }
c2.LinkType = { Url = "url", InsertText = "insert", JumpToChannel = "jump", UserInfo = "userinfo", CopyToClipboard = "copy" }
c2.FontStyle = { ChatMedium = "chat-medium" }
c2.MessageElementFlag = { None = 0, Text = 1, EmoteImage = 2, Username = 4 }
c2.MessageFlag = { None = 0, System = 1, Highlighted = 2 }

function c2.log(level, ...)
    local parts = {}
    for _, v in ipairs({ ... }) do parts[#parts + 1] = tostring(v) end
    log_lines[#log_lines + 1] = table.concat(parts, " ")
end

function c2.later(fn, ms)
    timers[#timers + 1] = { fn = fn, at = now_ms + ms }
end

-- pump the timer wheel forward; runs due timers (which may schedule more)
local function advance(ms)
    local target = now_ms + ms
    while true do
        local best, bi = nil, nil
        for i, t in ipairs(timers) do
            if t.at <= target and (not best or t.at < best.at) then best, bi = t, i end
        end
        if not best then break end
        table.remove(timers, bi)
        now_ms = best.at
        best.fn()
    end
    now_ms = target
end

c2.HTTPMethod = { Get = "GET", Post = "POST" }
local HTTPRequest = {}
HTTPRequest.__index = HTTPRequest
c2.HTTPRequest = {}
function c2.HTTPRequest.create(method, url)
    local r = setmetatable({ url = url, headers = {} }, HTTPRequest)
    return r
end
function HTTPRequest:set_timeout(t) self.timeout = t end
function HTTPRequest:set_header(k, v) self.headers[k] = v end
function HTTPRequest:on_success(cb) self.success = cb end
function HTTPRequest:on_error(cb) self.err = cb end
function HTTPRequest:finally(cb) self.fin = cb end
function HTTPRequest:execute() http_queue[#http_queue + 1] = self end

-- answer the oldest pending request matching pattern with a payload table
local function http_answer(pattern, payload_table)
    for i, r in ipairs(http_queue) do
        if string.find(r.url, pattern, 1, true) then
            table.remove(http_queue, i)
            local key = register_payload(payload_table)
            r.success({ data = function() return key end, status = function() return 200 end })
            if r.fin then r.fin() end
            return r.url
        end
    end
    return nil
end
local function http_fail(pattern)
    for i, r in ipairs(http_queue) do
        if string.find(r.url, pattern, 1, true) then
            table.remove(http_queue, i)
            r.err({ error = function() return "boom" end, data = function() return "" end, status = function() return 500 end })
            if r.fin then r.fin() end
            return true
        end
    end
    return false
end
-- simulates a non-ok HTTP status with a JSON error body (429/503/404 etc) —
-- real chatterino routes any non-ok status through on_error (see
-- HTTPRequest:on_error doc: "fails or returns a non-ok status"), still
-- carrying a readable body via res:data().
local function http_error(pattern, status, payload_table)
    for i, r in ipairs(http_queue) do
        if string.find(r.url, pattern, 1, true) then
            table.remove(http_queue, i)
            local key = payload_table and register_payload(payload_table) or ""
            r.err({ error = function() return "http " .. tostring(status) end,
                    data = function() return key end,
                    status = function() return status end })
            if r.fin then r.fin() end
            return true
        end
    end
    return false
end

function c2.register_command(name, fn) commands[name] = fn return true end
function c2.register_callback(_, fn) completion_cb = fn end

local account = { valid = true, anon = false, name = "mellen" }
local Account = {}
Account.__index = Account
function Account:is_valid() return account.valid end
function Account:is_anon() return account.anon end
function Account:login() return account.name end
function c2.current_account() return setmetatable({}, Account) end

-- websocket stub
local sockets = {}
c2.WebSocket = {}
function c2.WebSocket.new(url, opts)
    local s = { url = url, sent = {}, opts = opts, closed = false }
    function s:send_text(d) s.sent[#s.sent + 1] = d end
    function s:close()
        s.closed = true
        if s.opts.on_close then s.opts.on_close() end
    end
    sockets[#sockets + 1] = s
    return s
end

-- images
c2.Image = {}
function c2.Image.from_url(url, scale, expected)
    return { url = url, scale = scale or 1, expected = expected }
end
c2.ImageSet = {}
function c2.ImageSet.new(i1, i2, i3) return { i1 = i1, i2 = i2, i3 = i3 } end

-- message + channel
c2.Message = {}
-- when true, Message.new throws — lets a test drive render's do_process into its
-- pcall failure path (build_replacement calls Message.new) without any real API.
local MSG_NEW_THROWS = false
function c2.Message.new(init)
    if MSG_NEW_THROWS then error("synthetic message build failure") end
    return { init = init, is_plugin_msg = true }
end

local function fake_channel(name)
    local ch = {
        name = name,
        valid = true,
        appended_cb = nil,
        replaced = {},
        added = {},
        msgs = {},
    }
    function ch:is_valid() return ch.valid end
    function ch:get_name() return ch.name end
    function ch:get_type() return c2.ChannelType.Twitch end
    function ch:is_twitch_channel() return true end
    function ch:on_message_appended(cb)
        ch.appended_cb = cb
        return { disconnect = function() ch.appended_cb = nil end }
    end
    function ch:count_messages() return #ch.msgs end
    function ch:replace_message(msg, repl, hint)
        ch.replaced[#ch.replaced + 1] = { old = msg, new = repl, hint = hint }
    end
    function ch:message_snapshot(n)
        local out = {}
        for i = math.max(1, #ch.msgs - n + 1), #ch.msgs do out[#out + 1] = ch.msgs[i] end
        return out
    end
    function ch:add_message(m) ch.added[#ch.added + 1] = m end
    function ch:add_system_message(m) ch.added[#ch.added + 1] = m end
    function ch:last_message() return ch.msgs[#ch.msgs] end
    return ch
end

local channels = {}
c2.Channel = {
    by_name = function(name)
        for _, ch in ipairs(channels) do
            if ch.name == name then return ch end
        end
        return nil
    end,
}
c2.windows = {
    all = function(self)
        local splits = {}
        for _, ch in ipairs(channels) do splits[#splits + 1] = { channel = ch } end
        local page = { splits = function() return splits end }
        return { {
            notebook = {
                page_count = 1,
                page_at = function(self2, i) if i == 0 then return page end end,
            },
        } }
    end,
    on_channelview_context_menu_requested = function(self, cb)
        menu_cb = cb
        return { disconnect = function() menu_cb = nil end }
    end,
}

local function fake_text_el(words)
    return {
        type = "text",
        words = words,
        color = "#ffffff",
        style = c2.FontStyle.ChatMedium,
        flags = c2.MessageElementFlag.Text,
        trailing_space = true,
    }
end

local function fake_msg(login, uid, text)
    local words = {}
    for w in text:gmatch("%S+") do words[#words + 1] = w end
    local els = {
        { type = "timestamp", flags = 0 },
        { type = "text", words = { login .. ":" }, color = "#ff0000", flags = c2.MessageElementFlag.Username, trailing_space = true, style = c2.FontStyle.ChatMedium },
        fake_text_el(words),
    }
    return {
        flags = 0,
        id = "id-" .. tostring(math.random(99999)),
        parse_time = 1,
        search_text = text,
        message_text = text,
        login_name = login,
        display_name = login,
        localized_name = "",
        user_id = uid,
        channel_name = "somechannel",
        username_color = "#ff0000",
        server_received_time = 1,
        highlight_color = "",
        frozen = true,
        elements = function() return els end,
    }
end

-- =====================================================================
-- load the plugin  (os stripped: emulate chatterino's sandbox)
-- =====================================================================
os = nil
dofile(PLUGIN .. "/init.lua")

local caps = require("caps")
local inventory = require("inventory")
local senders = require("senders")
local ws = require("ws")
local render = require("render")

check(caps.tier == 2, "caps: full stub detects t2")
check(caps.menus == true, "caps: menus detected when c2.windows exposes the hook")
check(menu_cb ~= nil, "menu: registered against c2.windows at boot (t2)")

-- core render tests below isolate emote rendering; the flame marker (on by
-- default, and correctly shown on own/known-HS messages) is tested in its own
-- section further down, so switch it off here.
require("store").set_flame(false)

-- boot fired profile fetch for "mellen"
local answered = http_answer("/api/profile/mellen", { profile = { id = 42 } })
check(answered ~= nil, "boot: profile fetch fired for signed-in account")
http_answer("/api/users/42/emotes", { emotes = {
    { custom_name = "peepoHS", url = "https://cdn.heatsync.org/e/1.webp", width = 112, height = 112, usage_count = 9, zero_width = false },
    { custom_name = "OMEGALUL2", url = "https://cdn.heatsync.org/e/2.webp", width = 56, height = 56, usage_count = 3 },
} })
check(inventory.count() == 2, "inventory: 2 emotes loaded")
check(inventory.login == "mellen", "inventory: login adopted")

-- ws connected + replayed watch
check(#sockets == 1, "ws: socket opened at boot")
sockets[1].opts.on_open()
check(ws.connected, "ws: connected flag")
local saw_watch = false
for _, s in ipairs(sockets[1].sent) do
    if s:find("emote:watch", 1, true) and s:find("mellen", 1, true) then saw_watch = true end
end
check(saw_watch, "ws: emote:watch sent for own login")

-- completion: own inventory prefix + ordering (usage desc)
local res = completion_cb({ query = "peepo" })
check(res.values[1] == "peepoHS ", "completion: own emote matched (trailing space)")
local res2 = completion_cb({ query = ":omega" })
check(res2.values[1] == "OMEGALUL2 ", "completion: colon-stripped case-insensitive prefix (trailing space)")

-- 7tv search kicked off + cached on second keystroke
completion_cb({ query = "xar" })
http_answer("/api/emote-search?q=xar", { results = { ["7tv"] = { { name = "xar2EDM", url = "https://cdn.7tv.app/emote/01X/1x.webp" } } } })
local res3 = completion_cb({ query = "xar" })
local found7tv = false
for _, v in ipairs(res3.values) do if v == "xar2EDM " then found7tv = true end end
check(found7tv, "completion: 7tv cache hit on next keystroke")

-- render: discover hooks the fake channel
local chan = fake_channel("somechannel")
channels[1] = chan
advance(6000) -- discovery sweep
check(chan.appended_cb ~= nil, "render: channel hooked by discovery")

-- own message with own emote → replaced with scaling-image
local m1 = fake_msg("mellen", "1001", "hello peepoHS world")
chan.msgs[#chan.msgs + 1] = m1
chan.appended_cb(m1, nil)
check(#chan.replaced == 1, "render: own emote message replaced")
local elems = chan.replaced[1].new.init.elements
local kinds = {}
for _, e in ipairs(elems) do
    kinds[#kinds + 1] = (e.is_plugin_msg and "?" or (e.type or "obj"))
end
-- timestamp obj, username obj, text "hello", scaling-image, text "world"
check(#elems == 5, "render: rebuilt into 5 elements (got " .. #elems .. ": " .. table.concat(kinds, ",") .. ")")
check(elems[4] ~= nil and elems[4].type == "scaling-image", "render: emote became scaling-image")
-- inventory stores NATIVE dims (peepoHS = 112) but the url is a 1x tier served
-- at <=32px, so the scale basis is clamped to the 1x line height: 28/32 = 0.875,
-- not the naive 28/112 = 0.25 that would render the 32px image at ~7px (invisible).
check(elems[4].images.i1.scale == 0.875, "render: native-height record clamped to 1x line height (0.875)")
check(elems[3].type == "text" and elems[3].text == "hello", "render: leading text run preserved")

-- threadlink in a message from a non-hs user (unknown sender, no emotes)
local m2 = fake_msg("randomguy", "2002", "check >>a1b2c3 out")
chan.msgs[#chan.msgs + 1] = m2
chan.appended_cb(m2, nil)
check(#chan.replaced == 2, "render: threadlink message replaced")
local tl = nil
for _, e in ipairs(chan.replaced[2].new.init.elements) do
    if type(e) == "table" and e.link and type(e.link) == "table" and tostring(e.link.value):find("/thread/a1b2c3", 1, true) then tl = e end
end
check(tl ~= nil, "render: >>a1b2c3 got a clickable /thread link")
check(tl.color == "link", "render: threadlink uses link color")

-- message with no hits → NOT replaced (miss path)
local m3 = fake_msg("randomguy", "2002", "just words no hits")
chan.msgs[#chan.msgs + 1] = m3
chan.appended_cb(m3, nil)
check(#chan.replaced == 2, "render: miss path does not replace")

-- unknown sender queued → batch flush resolves → back-pass renders their emote
local m4 = fake_msg("emily", "3003", "emilyDance party")
chan.msgs[#chan.msgs + 1] = m4
chan.appended_cb(m4, nil)
check(#chan.replaced == 2, "senders: unknown sender not rendered yet")
advance(2500) -- senders.flush tick
local burl = http_answer("/api/users/emotes/batch", { sets = { ["twitch:3003"] = {
    { custom_name = "emilyDance", url = "https://cdn.heatsync.org/e/9.webp", width = 64, height = 64 },
} } })
check(burl ~= nil and burl:find("twitch:3003", 1, true) ~= nil, "senders: batch lookup fired with twitch id")
advance(200) -- backpass is coalesced onto a ~120ms timer now; pump it
check(#chan.replaced == 3, "senders: back-pass rendered the sender's recent message")

-- ws broadcast feeds sender cache immediately
sockets[1].opts.on_text(register_payload({
    type = "emote:broadcast", username = "walter", emoteName = "walterPog",
    emoteData = { url = "https://cdn.heatsync.org/e/7.webp", width = 96, height = 96 },
}))
local m5 = fake_msg("walter", "4004", "walterPog")
chan.msgs[#chan.msgs + 1] = m5
chan.appended_cb(m5, nil)
check(#chan.replaced >= 4, "ws: broadcast-fed emote renders on next message")

-- ws emote:added on OUR own emote:watch room ("emotes/<id>", _seq set) →
-- debounced refresh fires a new profile fetch, cache-busted with ?v=<seq>
sockets[1].opts.on_text(register_payload({ type = "emote:added", name = "newEmote", _ch = "emotes/42", _seq = 7 }))
advance(6000)
local refetched = http_answer("/api/profile/mellen", { profile = { id = 42 } })
check(refetched ~= nil, "ws: own-inventory delta (_ch=emotes/<id>) triggers re-fetch")
local emurl = http_answer("/api/users/42/emotes?v=7", { emotes = {
    { custom_name = "peepoHS", url = "https://cdn.heatsync.org/e/1.webp", width = 112, height = 112, usage_count = 9 },
    { custom_name = "newEmote", url = "https://cdn.heatsync.org/e/3.webp", width = 64, height = 64, usage_count = 0 },
} })
check(emurl ~= nil, "ws: own-inventory refetch carries ?v=<seq> cache-bust")
check(inventory.resolve("newEmote") ~= nil, "ws: new emote in inventory after delta")

-- a flood of OTHER users' viewer pushes (no _ch → global broadcast, not ours)
-- must never touch our own inventory: zero additional profile/emote fetches
do
    local before_fetches = #http_queue
    for i = 1, 100 do
        sockets[1].opts.on_text(register_payload({
            type = "emote:added", username = "otheruser" .. i, emoteName = "x", ver = i,
        }))
    end
    check(#http_queue == before_fetches, "ws: 100 other-user viewer pushes fire zero inventory fetches")
end

-- senderKeys invalidation: a real cached key refetches with &v=; anything
-- else in the frame (unmatched/uncached) is ignored. emily (twitch id 3003)
-- was cached by the earlier "senders: unknown sender" batch-lookup test.
do
    check(senders.is_known_hs("emily"), "senders: precondition — emily is cached before invalidate")
    local before = #http_queue
    sockets[1].opts.on_text(register_payload({
        type = "emote:removed", username = "someoneelse", emoteName = "notEmily",
        senderKeys = { "twitch:3003", "kick:999", "twitch:99999999" }, ver = 55,
    }))
    check(#http_queue == before + 1, "senders: invalidate refetches exactly the one cached twitch key")
    local iurl = http_answer("/api/users/emotes/batch?ids=twitch:3003", { sets = { ["twitch:3003"] = {
        { custom_name = "emilyDance", url = "https://cdn.heatsync.org/e/9.webp", width = 64, height = 64 },
    } } })
    check(iurl ~= nil and iurl:find("twitch:3003", 1, true) ~= nil and iurl:find("&v=55", 1, true) ~= nil,
        "senders: invalidate refetch carries &v=<ver>")
    check(senders.is_known_hs("emily"), "senders: emily re-cached after invalidate refetch")
end

-- hostile senderKeys: non-strings, 1000 entries, injection-flavored strings —
-- capped at 50 scanned, nothing matches/is cached → no crash, no refetch
do
    local before = #http_queue
    local hostile = {}
    for i = 1, 1000 do hostile[i] = i end -- non-string garbage
    hostile[1] = "twitch:3003\n; rm -rf /" -- looks close but fails the exact-match pattern
    local ok = pcall(function()
        sockets[1].opts.on_text(register_payload({
            type = "emote:added", username = "z", senderKeys = hostile, ver = "not-a-number",
        }))
    end)
    check(ok, "senders: 1000-entry hostile senderKeys frame doesn't crash the dispatch")
    check(#http_queue == before, "senders: hostile/non-matching senderKeys trigger no refetch")
end

-- emote:removed with username+emoteName scrubs the cached name immediately,
-- independent of the (slower) invalidate round trip above
do
    sockets[1].opts.on_text(register_payload({
        type = "emote:broadcast", username = "scrubme", emoteName = "goingAway",
        emoteData = { url = "https://cdn.heatsync.org/e/8.webp", width = 32, height = 32 },
    }))
    check(senders.resolve("scrubme", "424242") ~= nil, "senders: scrubme cached via broadcast before removal")
    sockets[1].opts.on_text(register_payload({
        type = "emote:removed", username = "scrubme", emoteName = "goingAway",
    }))
    local map = senders.resolve("scrubme", "424242")
    check(type(map) == "table" and map["goingAway"] == nil, "senders: emote:removed scrubs the name immediately")
end

-- content-warning gate on emote:broadcast: the pushed emoteData is NOT filtered
-- per-viewer server-side (unlike a fetched batch row), so feed_broadcast must
-- gate nsfw/cw_cats itself the same way parse_emote_row does for fetched rows.
do
    sockets[1].opts.on_text(register_payload({
        type = "emote:broadcast", username = "nsfwsender", emoteName = "nsfwEmote",
        emoteData = { url = "https://cdn.heatsync.org/e/nsfw.webp", width = 32, height = 32, nsfw = true },
    }))
    check(senders.resolve("nsfwsender", "313131") == nil, "senders: cw-gate — nsfw emote:broadcast is never cached")
    sockets[1].opts.on_text(register_payload({
        type = "emote:broadcast", username = "goresender", emoteName = "goreEmote",
        emoteData = { url = "https://cdn.heatsync.org/e/gore.webp", width = 32, height = 32, cw_cats = { "gore" } },
    }))
    check(senders.resolve("goresender", "313132") == nil, "senders: cw-gate — gore-cat emote:broadcast is never cached")
    -- a clean broadcast from the same shape still caches normally (gate isn't over-firing)
    sockets[1].opts.on_text(register_payload({
        type = "emote:broadcast", username = "cleansender", emoteName = "cleanEmote",
        emoteData = { url = "https://cdn.heatsync.org/e/clean.webp", width = 32, height = 32, cw_cats = { "weapons" } },
    }))
    check(senders.resolve("cleansender", "313133") ~= nil, "senders: cw-gate — a non-sexual/gore category still caches")
end

-- reconnect with backoff after close
local sock_count = #sockets
sockets[1]:close()
check(not ws.connected, "ws: close clears connected")
advance(3000)
check(#sockets == sock_count + 1, "ws: reconnected after backoff")
sockets[#sockets].opts.on_open()
local rejoined = false
for _, s in ipairs(sockets[#sockets].sent) do
    if s:find("channel:join", 1, true) and s:find("somechannel", 1, true) then rejoined = true end
end
check(rejoined, "ws: channel:join replayed on reconnect")

-- watchdog recycles a stale socket (no rx for >90s wall-clock is faked by
-- rewinding last_rx; the 30s watchdog tick then closes it)
local net = require("net")
ws.last_rx = net.now() - 120
local before = #sockets
advance(31000)
check(#sockets > before or not ws.connected, "ws: watchdog recycled stale socket")

-- zero-height emote (unknown dims) falls back to text
sockets[#sockets].opts.on_open()
sockets[#sockets].opts.on_text(register_payload({
    type = "emote:broadcast", username = "nodims", emoteName = "mysteryEmote",
    emoteData = { url = "https://cdn.heatsync.org/e/x.webp" },
}))
local m6 = fake_msg("nodims", "5005", "mysteryEmote hi")
chan.msgs[#chan.msgs + 1] = m6
local rc = #chan.replaced
chan.appended_cb(m6, nil)
check(#chan.replaced == rc, "render: dimension-less emote stays text (no giant images)")

-- ===== ws batch unwrap (`/ws?b=1` coalescing, ws-coalesce.ts) =====
do
    local s = sockets[#sockets]
    check(not senders.is_known_hs("batchuser1"), "ws batch: precondition — batchuser1 unknown before the batch")
    s.opts.on_text(register_payload({
        type = "batch",
        messages = {
            { type = "emote:broadcast", username = "batchuser1", emoteName = "batchEmote1",
                emoteData = { url = "https://cdn.heatsync.org/e/b1.webp", width = 32, height = 32 } },
            { type = "emote:broadcast", username = "batchuser2", emoteName = "batchEmote2",
                emoteData = { url = "https://cdn.heatsync.org/e/b2.webp", width = 32, height = 32 } },
        },
    }))
    check(senders.is_known_hs("batchuser1"), "ws batch: first message in a batch frame is dispatched")
    check(senders.is_known_hs("batchuser2"), "ws batch: second message in a batch frame is dispatched")

    -- cap: only the first 256 entries in an oversized batch are dispatched
    local msgs = {}
    for i = 1, 300 do
        msgs[i] = { type = "emote:broadcast", username = "batchcap" .. i, emoteName = "e",
            emoteData = { url = "https://cdn.heatsync.org/e/cap.webp", width = 32, height = 32 } }
    end
    s.opts.on_text(register_payload({ type = "batch", messages = msgs }))
    check(senders.is_known_hs("batchcap1"), "ws batch cap: an entry within the 256 cap is dispatched")
    check(not senders.is_known_hs("batchcap300"), "ws batch cap: an entry past the 256 cap is not dispatched")

    -- non-table entries, and a nested "batch" entry, are ignored rather than
    -- crashing the unwrap (the server never nests batches — this is a
    -- hostile-frame guard, so a nested one is just passed through inert)
    local ok = pcall(function()
        s.opts.on_text(register_payload({
            type = "batch",
            messages = { "not a table", 42, true, { type = "batch", messages = { { type = "emote:broadcast" } } } },
        }))
    end)
    check(ok, "ws batch: non-table entries and a nested batch don't crash the unwrap")
end

-- ===== ws server:shutdown: spread reconnect, no backoff penalty =====
do
    local s = sockets[#sockets]
    local attempts_before = ws.attempts
    local sock_count = #sockets
    s.opts.on_text(register_payload({ type = "server:shutdown", reconnectSpreadMs = 5000, signal = "SIGTERM" }))
    check(not ws.connected, "ws shutdown: the connection closes immediately")
    check(ws.attempts == attempts_before, "ws shutdown: does not increment the backoff attempt counter")
    advance(6000) -- past the clamped [1000,60000] spread window (5000 here)
    check(#sockets == sock_count + 1, "ws shutdown: reconnects on its own schedule within the spread window")
    check(ws.attempts == attempts_before, "ws shutdown: attempt counter is still unchanged once reconnected")
end

-- ===== resume: ack:channels replays a kick room's last-seen _seq on reconnect =====
-- "reconnect" here is simulated the same way the resync test at the end of this
-- suite does it — on_open firing again on the same socket — rather than a real
-- close+backoff cycle, whose delay depends on how many attempts have already
-- accumulated elsewhere in this run. replay_state() runs identically either way.
do
    local s = sockets[#sockets]
    commands["/hsmulti"]({ words = { "/hsmulti", "kick:phase5chan" }, channel = chan })

    local a0 = #chan.added
    s.opts.on_text(register_payload({
        type = "kick-chat-message", _ch = "kick/phase5chan", _seq = 77,
        data = { platform = "kick", channel = "phase5chan", id = "resume1", username = "u", content = "before reconnect" },
    }))
    check(#chan.added == a0 + 1, "resume: precondition — the kick message injects once")

    s.sent = {} -- isolate this on_open's sends from everything sent so far
    s.opts.on_open()
    local saw_ack = false
    for _, sent in ipairs(s.sent) do
        if sent:find("ack:channels", 1, true) and sent:find("kick/phase5chan", 1, true) and sent:find("77", 1, true) then
            saw_ack = true
        end
    end
    check(saw_ack, "resume: reconnect sends ack:channels with the tracked _ch and lastSeq")

    -- the server "replays" the same message (same id) after reconnect — the
    -- multichat dedup ring (scoped by source+id) must not show it twice
    local a1 = #chan.added
    s.opts.on_text(register_payload({
        type = "kick-chat-message", _ch = "kick/phase5chan", _seq = 77,
        data = { platform = "kick", channel = "phase5chan", id = "resume1", username = "u", content = "before reconnect" },
    }))
    check(#chan.added == a1, "resume: a replayed kick message (same id) is deduped, not shown twice")

    -- unlinking drops the tracked seq: a later reconnect carries no ack for it
    commands["/hsmulti"]({ words = { "/hsmulti", "off" }, channel = chan })
    s.sent = {}
    s.opts.on_open()
    local saw_stale = false
    for _, sent in ipairs(s.sent) do
        if sent:find("phase5chan", 1, true) then saw_stale = true end
    end
    check(not saw_stale, "resume: unlinking a kick source drops its tracked seq (no stale ack afterward)")
end

-- commands smoke: /hsstatus, /hsmoments (with fetch), /hslogs
local cctx = { words = { "/hsstatus" }, channel = chan }
commands["/hsstatus"](cctx)
check(#chan.added >= 4, "commands: /hsstatus prints status lines")

local before_added = #chan.added
commands["/hsmoments"]({ words = { "/hsmoments", "12" }, channel = chan })
http_answer("/api/moments", { moments = {
    { id = "m1", channel = "forsen", rate = 120, baseline = 10, title = "big play" },
} })
check(#chan.added >= before_added + 2, "commands: /hsmoments emits header + link line")

before_added = #chan.added
commands["/hslogs"]({ words = { "/hslogs", "Emily" }, channel = chan })
-- now async: fetches chatter stats, then emits a stats line + the archive link
http_answer("/api/chatter/twitch/emily/stats", { totals = { messages = 500, channels = 3, activeDays = 12 },
    topChannels = { { channel = "forsen", messages = 200 } } })
check(#chan.added >= before_added + 1, "commands: /hslogs emits stats + link line")

-- system messages never recurse into render (flag check)
local sysm = fake_msg("", "", "system text")
sysm.flags = c2.MessageFlag.System
rc = #chan.replaced
chan.appended_cb(sysm, nil)
check(#chan.replaced == rc, "render: system messages skipped")

-- ===== flame marker (v1.0) =====
local store = require("store")
store.set_flame(true) -- re-enable (core tests above switched it off)
-- feed a known-HS sender, then a TEXT-ONLY message from them → gets flamed
sockets[#sockets].opts.on_text(register_payload({
    type = "emote:broadcast", username = "flameuser", emoteName = "peepoHS",
    emoteData = { url = "https://cdn.heatsync.org/e/1.webp", width = 112, height = 112 },
}))
check(senders.is_known_hs("flameuser"), "flame: sender known-HS after broadcast")
local fm = fake_msg("flameuser", "7007", "just plain text no emotes")
chan.msgs[#chan.msgs + 1] = fm
rc = #chan.replaced
chan.appended_cb(fm, nil)
check(#chan.replaced == rc + 1, "flame: known-HS text-only message rebuilt")
local function has_flame(elems)
    for _, e in ipairs(elems) do
        if type(e) == "table" and e.type == "text" and e.text and e.text:find("🔥", 1, true) then return true end
    end
    return false
end
check(has_flame(chan.replaced[#chan.replaced].new.init.elements), "flame: 🔥 inserted on known-HS message")

-- non-HS sender text-only → not flamed, not rebuilt
local nm = fake_msg("randolph", "8008", "i am not heatsync")
chan.msgs[#chan.msgs + 1] = nm
rc = #chan.replaced
chan.appended_cb(nm, nil)
check(#chan.replaced == rc, "flame: non-HS text-only message untouched")

-- /hsflame off → known-HS text-only no longer rebuilt
commands["/hsflame"]({ words = { "/hsflame", "off" }, channel = chan })
check(not store.flame_enabled(), "flame: /hsflame off flips flag")
local fm2 = fake_msg("flameuser", "7007", "more plain text")
chan.msgs[#chan.msgs + 1] = fm2
rc = #chan.replaced
chan.appended_cb(fm2, nil)
check(#chan.replaced == rc, "flame: off → known-HS text-only not rebuilt")
commands["/hsflame"]({ words = { "/hsflame", "on" }, channel = chan })

-- ===== local block (v1.0) =====
local bm = fake_msg("flameuser", "7007", "look peepoHS here")
chan.msgs[#chan.msgs + 1] = bm
chan.appended_cb(bm, nil)
local function has_image(elems)
    for _, e in ipairs(elems) do
        if type(e) == "table" and e.type == "scaling-image" then return true end
    end
    return false
end
check(has_image(chan.replaced[#chan.replaced].new.init.elements), "block: peepoHS renders before block")
commands["/hsblock"]({ words = { "/hsblock", "peepoHS" }, channel = chan })
check(store.is_blocked("peepoHS"), "block: /hsblock records the block")
local bm2 = fake_msg("flameuser", "7007", "look peepoHS here")
chan.msgs[#chan.msgs + 1] = bm2
chan.appended_cb(bm2, nil)
check(not has_image(chan.replaced[#chan.replaced].new.init.elements), "block: peepoHS no longer an image after block")
local cres = completion_cb({ query = "peepo" })
local sawblocked = false
for _, v in ipairs(cres.values) do if v == "peepoHS " then sawblocked = true end end
check(not sawblocked, "block: peepoHS filtered from tab-complete")
commands["/hsunblock"]({ words = { "/hsunblock", "peepoHS" }, channel = chan })
check(not store.is_blocked("peepoHS"), "block: /hsunblock clears it")

-- ===== global-catalog words do NOT inline-render ('lost' false-positive fix) =====
-- a search caches name→url for the /hsfind picker, but a word that merely
-- matches that cache must NOT render inline in a message — common english words
-- are also emote names (e.g. 'lost' is a 7tv cat), and rendering them turned
-- plain sentences into random emotes. only the SENDER's heatsync inventory
-- renders inline (extension parity); native chatterino handles real 7tv/bttv/ffz.
completion_cb({ query = "nichEmote" }) -- populates the search/render cache
http_answer("/api/emote-search?q=nichemote", { results = { ["7tv"] = {
    { name = "nichEmote", url = "https://cdn.7tv.app/emote/01ABC/1x.webp", animated = false },
    { name = "lost", url = "https://cdn.7tv.app/emote/01LOST/1x.webp", animated = true },
} } })
local seventv = require("seventv")
check(select(1, seventv.resolve_render("nichEmote")) ~= nil, "search: emote still cached for the /hsfind picker")

-- merged ranking: the server's cross-provider list (includes hs) replaces the
-- old per-provider 7tv→bttv→ffz concat when present
do
    local got
    seventv.search_all("mergedq", function(list) got = list end)
    http_answer("/api/emote-search?q=mergedq", {
        results = { ["7tv"] = { { name = "shouldnotappear", url = "https://cdn.7tv.app/emote/0X/1x.webp" } } },
        merged = {
            { name = "hsOne", url = "https://cdn.heatsync.org/e/1.webp", provider = "hs", animated = false, zeroWidth = true },
            { name = "sevenTwo", url = "https://cdn.7tv.app/emote/0Y/1x.webp", provider = "7tv", animated = true },
        },
    })
    check(got ~= nil and #got == 2, "seventv: merged list used when present, not the per-provider concat")
    local byname = {}
    for _, e in ipairs(got) do byname[e.name] = e end
    check(byname.shouldnotappear == nil, "seventv: merged present → results{} is not also concatenated")
    check(byname.hsOne ~= nil and byname.hsOne.provider == "hs" and byname.hsOne.zw == true,
        "seventv: merged 'hs' item kept, camelCase zeroWidth read into zw")
end

-- a merged row still goes through is_safe_name/is_safe_url like any other
do
    local got
    seventv.search_all("hostilemq", function(list) got = list end)
    http_answer("/api/emote-search?q=hostilemq", { merged = {
        { name = "bad\tname", url = "https://cdn.7tv.app/emote/0Z/1x.webp", provider = "7tv" }, -- unsafe name
        { name = "okname2", url = "https://cdn.7tv.app/emote/0Z\n/1x.webp", provider = "7tv" }, -- unsafe url
        { name = "fine", url = "https://cdn.7tv.app/emote/0Z/1x.webp", provider = "7tv" },
    } })
    check(got ~= nil and #got == 1 and got[1].name == "fine",
        "seventv: a merged row still passes is_safe_name/is_safe_url")
end

-- partial:true is reported to the caller (kick_off then short-TTLs it instead
-- of discarding it — see the 7tv completion negative-cache tests elsewhere)
do
    local partial_seen = "unset"
    seventv.search_all("partialq", function(_, partial) partial_seen = partial end)
    http_answer("/api/emote-search?q=partialq", { merged = {
        { name = "partialHit", url = "https://cdn.7tv.app/emote/0P/1x.webp", provider = "7tv" },
    }, partial = true })
    check(partial_seen == true, "seventv: partial:true is surfaced to the caller")
end
-- a non-HS sender posts words that are ONLY in the global search cache → the
-- message must NOT be rebuilt (no false-positive inline render).
local sm = fake_msg("rando", "9999", "i totally lost the game nichEmote")
chan.msgs[#chan.msgs + 1] = sm
rc = #chan.replaced
chan.appended_cb(sm, nil)
check(#chan.replaced == rc, "no-false-positive: global-cache-only words don't trigger an inline render")

-- personal-emote dims: heatsync's stored width can disagree with the served 1x
-- image (real case: wollip = 96x32 record, 32x32 image). the render must NOT
-- hand chatterino an expected width or it stretches the emote — height-only
-- scale (from_url gets no expected-size, so the actual image drives aspect).
senders.feed_broadcast("wideuser", "wideMote",
    { url = "https://cdn.7tv.app/emote/WIDE/1x.webp", width = 96, height = 32 })
do
    local wm = fake_msg("wideuser", "8008", "look wideMote here")
    chan.msgs[#chan.msgs + 1] = wm
    chan.appended_cb(wm, nil)
    local rendered, no_stretch, click_ok = false, false, false
    for _, e in ipairs(chan.replaced[#chan.replaced].new.init.elements) do
        if type(e) == "table" and e.type == "scaling-image" and type(e.images) == "table"
            and type(e.images.i1) == "table" then
            rendered = true
            no_stretch = (e.images.i1.expected == nil)
            click_ok = type(e.link) == "table" and e.link.type == c2.LinkType.InsertText
                and e.link.value == "wideMote "
        end
    end
    check(rendered and no_stretch,
        "personal-emote dims: mismatched-width emote renders by height, no stretched expected-width")
    check(click_ok, "click-to-insert: a rendered sender emote carries an InsertText link with its name")
end

-- tall-emote invisibility (real case: 42% of an inventory stored native 128 on a
-- 1x url served at ~32px). scaling by the stored height renders the 32px image at
-- 28/128 ≈ 0.219 → ~7px, invisible ("posted frierenfernComfy, wollip can't see
-- it"). the scale basis must clamp to the 1x line height → 28/32 = 0.875.
senders.feed_broadcast("talluser", "frierenfernComfy",
    { url = "https://cdn.frankerfacez.com/emote/773952/1", width = 128, height = 128 })
do
    local tm = fake_msg("talluser", "9090", "look frierenfernComfy here")
    chan.msgs[#chan.msgs + 1] = tm
    chan.appended_cb(tm, nil)
    local scale = nil
    for _, e in ipairs(chan.replaced[#chan.replaced].new.init.elements) do
        if type(e) == "table" and e.type == "scaling-image" and type(e.images) == "table"
            and type(e.images.i1) == "table" then
            scale = e.images.i1.scale
        end
    end
    check(scale == 0.875,
        "tall-emote: native-128 record on a 1x url clamps to 0.875, not 0.219 (invisible)")
end

-- ===== multichat (v1.1) — kick/youtube injection =====
local sock = sockets[#sockets]
local function last_sent_has(...)
    local needles = { ... }
    for _, s in ipairs(sock.sent) do
        local all = true
        for _, n in ipairs(needles) do if not s:find(n, 1, true) then all = false break end end
        if all then return true end
    end
    return false
end
local function elem_has_text(m, want)
    if type(m) ~= "table" or not m.init or not m.init.elements then return false end
    for _, e in ipairs(m.init.elements) do
        if type(e) == "table" and e.type == "text" and e.text == want then return true end
    end
    return false
end

commands["/hsmulti"]({ words = { "/hsmulti", "kick:xqc" }, channel = chan })
check(last_sent_has("channel:join", "kick", "xqc"), "multichat: /hsmulti kick sends channel:join kick")

local ba = #chan.added
sock.opts.on_text(register_payload({
    type = "kick-chat-message",
    data = { platform = "kick", channel = "xqc", id = "k1", username = "viewer1",
        displayName = "Viewer1", content = "hello from kick", color = "#53fc18", timestamp = 1730000000000 },
}))
check(#chan.added == ba + 1, "multichat: kick live message injected")
check(elem_has_text(chan.added[#chan.added], "[K]"), "multichat: kick message tagged [K]")

ba = #chan.added
sock.opts.on_text(register_payload({
    type = "kick-chat-message",
    data = { platform = "kick", channel = "xqc", id = "k1", username = "viewer1", content = "dup" },
}))
check(#chan.added == ba, "multichat: duplicate kick id deduped")

-- kick emote token [emote:id:name] → scaling-image
ba = #chan.added
sock.opts.on_text(register_payload({
    type = "kick-chat-message",
    data = { platform = "kick", channel = "xqc", id = "kem", username = "u", content = "nice [emote:37226:KEKW] play" },
}))
check(#chan.added == ba + 1, "multichat: kick emote message injected")
do
    local msg = chan.added[#chan.added]
    local has_img = false
    if msg.init and msg.init.elements then
        for _, e in ipairs(msg.init.elements) do
            if type(e) == "table" and e.type == "scaling-image" then has_img = true end
        end
    end
    check(has_img, "multichat: kick [emote:] token rendered as image")
end

ba = #chan.added
sock.opts.on_text(register_payload({
    type = "kick-chat-backfill", channel = "xqc", replay = true,
    messages = {
        { platform = "kick", channel = "xqc", id = "k2", username = "a", content = "one" },
        { platform = "kick", channel = "xqc", id = "k3", username = "b", content = "two" },
    },
}))
check(#chan.added == ba + 2, "multichat: kick backfill injects each")

commands["/hsmulti"]({ words = { "/hsmulti", "yt:@somestreamer" }, channel = chan })
check(last_sent_has("youtube:subscribe", "somestreamer"), "multichat: /hsmulti yt sends youtube:subscribe")

ba = #chan.added
sock.opts.on_text(register_payload({
    type = "youtube:chat", channelId = "@somestreamer",
    messages = { { type = "text", id = "y1", user = "YTuser", text = "hi from yt", timestamp = 1730000000001 } },
}))
check(#chan.added == ba + 1, "multichat: youtube message injected")
check(elem_has_text(chan.added[#chan.added], "[Y]"), "multichat: youtube message tagged [Y]")

-- youtube history replay (server sends replay=true on subscribe/restart) must NOT
-- dump into the tab — only the link line + new messages. this was the bug.
ba = #chan.added
sock.opts.on_text(register_payload({
    type = "youtube:chat", channelId = "@somestreamer", replay = true,
    messages = {
        { type = "text", id = "yr1", user = "old1", text = "ancient history 1", timestamp = 1 },
        { type = "text", id = "yr2", user = "old2", text = "ancient history 2", timestamp = 2 },
    },
}))
check(#chan.added == ba, "multichat: youtube replay (history) batch is NOT injected")
-- a subsequent live (non-replay) batch still injects
sock.opts.on_text(register_payload({
    type = "youtube:chat", channelId = "@somestreamer",
    messages = { { type = "text", id = "ylive", user = "YTuser", text = "new live msg", timestamp = 1730000000009 } },
}))
check(#chan.added == ba + 1, "multichat: live youtube message after replay still injects")

-- youtube emote shortcode → image
ba = #chan.added
sock.opts.on_text(register_payload({
    type = "youtube:chat", channelId = "@somestreamer",
    messages = { { type = "text", id = "y2", user = "YTuser",
        text = "nice :wave: play",
        emotes = { { type = "emoji", url = "https://yt3.ggpht.com/abc=w24-h24-c-k-nd", alt = ":wave:" } },
        timestamp = 1730000000002 } },
}))
do
    local msg = chan.added[#chan.added]
    local has_img = false
    if msg.init and msg.init.elements then
        for _, e in ipairs(msg.init.elements) do
            if type(e) == "table" and e.type == "scaling-image" then has_img = true end
        end
    end
    check(has_img, "multichat: youtube :shortcode: rendered as image")
end

-- yt emote url safety: a hostile/oversized url in the untrusted youtube:chat
-- payload must NOT reach img.for_url — it falls back to the plain shortcode text
ba = #chan.added
sock.opts.on_text(register_payload({
    type = "youtube:chat", channelId = "@somestreamer",
    messages = { { type = "text", id = "y3", user = "YTuser",
        text = "evil :bad: here",
        emotes = { { type = "emoji", url = "https://yt3.ggpht.com/" .. string.rep("a", 5000), alt = ":bad:" } },
        timestamp = 1730000000003 } },
}))
do
    local msg = chan.added[#chan.added]
    local has_img = false
    if msg.init and msg.init.elements then
        for _, e in ipairs(msg.init.elements) do
            if type(e) == "table" and e.type == "scaling-image" then has_img = true end
        end
    end
    -- rejected url → no image built from it; the line still injects (as plain text)
    check(#chan.added == ba + 1 and not has_img,
        "yt url-safety: an oversized emote url builds no image, line still delivered")
end

-- youtube:status connected → learns videoId (for later unsubscribe)
sock.opts.on_text(register_payload({
    type = "youtube:status", channelId = "@somestreamer", videoId = "vid123", status = "connected", channelName = "x",
}))

-- hsEmotes: server-computed sender-inventory refs on kick/youtube live frames
-- (server/services/emote-enrich.ts) render as heatsync-emote images, sharing
-- MAX_EMOTE_TOKENS with each platform's own native emote tokens. this is the
-- sender's own inventory, resolved server-side — the privacy invariant holds.
local function has_scaling_image(m)
    if type(m) ~= "table" or not m.init or not m.init.elements then return false, nil end
    for _, e in ipairs(m.init.elements) do
        if type(e) == "table" and e.type == "scaling-image" then return true, e.tooltip end
    end
    return false, nil
end

ba = #chan.added
sock.opts.on_text(register_payload({
    type = "kick-chat-message",
    data = { platform = "kick", channel = "xqc", id = "hs1", username = "hsuser", content = "gg peepoHS well played",
        hsEmotes = { peepoHS = { url = "https://cdn.heatsync.org/e/hs1.webp", provider = "heatsync" } } },
}))
check(#chan.added == ba + 1, "multichat: kick hsEmotes message injected")
do
    local has_img, tip = has_scaling_image(chan.added[#chan.added])
    check(has_img, "multichat: kick hsEmotes word rendered as image")
    check(tip == "peepoHS · heatsync", "multichat: kick hsEmotes tooltip is '<word> · heatsync'")
end

-- content-warning gate on an hsEmotes ref: nsfw=true must never render (falls
-- back to the plain word, same as parse_emote_row's gate for fetched rows)
ba = #chan.added
sock.opts.on_text(register_payload({
    type = "kick-chat-message",
    data = { platform = "kick", channel = "xqc", id = "hs2", username = "hsuser", content = "nsfwEmote here",
        hsEmotes = { nsfwEmote = { url = "https://cdn.heatsync.org/e/hs2.webp", provider = "heatsync", nsfw = true } } },
}))
do
    local has_img = has_scaling_image(chan.added[#chan.added])
    check(#chan.added == ba + 1 and not has_img, "multichat: nsfw hsEmotes ref is gated (falls back to text)")
end

-- hostile hsEmotes ref: an over-length name (fails is_safe_name) is dropped by
-- the sanitize pass even though it's a real word in the message
ba = #chan.added
local longname = string.rep("x", 150)
sock.opts.on_text(register_payload({
    type = "kick-chat-message",
    data = { platform = "kick", channel = "xqc", id = "hs3", username = "hsuser",
        content = "check " .. longname .. " out",
        hsEmotes = { [longname] = { url = "https://cdn.heatsync.org/e/hs3.webp" } } },
}))
do
    local has_img = has_scaling_image(chan.added[#chan.added])
    check(#chan.added == ba + 1 and not has_img, "multichat: an over-length hsEmotes name never reaches an image")
end

-- hostile hsEmotes ref: a non-https url is rejected by img.lua's host_allowed
-- the same as every other emote path (is_safe_url alone doesn't gate scheme)
ba = #chan.added
sock.opts.on_text(register_payload({
    type = "kick-chat-message",
    data = { platform = "kick", channel = "xqc", id = "hs4", username = "hsuser", content = "insecureWord shown",
        hsEmotes = { insecureWord = { url = "http://cdn.heatsync.org/e/hs4.webp" } } },
}))
do
    local has_img = has_scaling_image(chan.added[#chan.added])
    check(#chan.added == ba + 1 and not has_img, "multichat: a non-https hsEmotes url never renders")
end

-- youtube messages[].hsEmotes renders the same way as kick's data.hsEmotes
ba = #chan.added
sock.opts.on_text(register_payload({
    type = "youtube:chat", channelId = "@somestreamer",
    messages = { { type = "text", id = "yhs1", user = "ytuser", text = "peepoHS nice",
        hsEmotes = { peepoHS = { url = "https://cdn.heatsync.org/e/hs5.webp", provider = "heatsync" } },
        timestamp = 1730000000010 } },
}))
do
    local has_img = has_scaling_image(chan.added[#chan.added])
    check(#chan.added == ba + 1 and has_img, "multichat: youtube hsEmotes word rendered as image")
end

-- a locally-blocked emote name still gets blocked when it arrives via hsEmotes
require("store").block("blockedHS")
ba = #chan.added
sock.opts.on_text(register_payload({
    type = "kick-chat-message",
    data = { platform = "kick", channel = "xqc", id = "hs6", username = "hsuser", content = "blockedHS here",
        hsEmotes = { blockedHS = { url = "https://cdn.heatsync.org/e/hs6.webp" } } },
}))
do
    local has_img = has_scaling_image(chan.added[#chan.added])
    check(#chan.added == ba + 1 and not has_img, "multichat: a locally-blocked name doesn't render via hsEmotes")
end
require("store").unblock("blockedHS")

-- a hostile/huge hsEmotes map (500 entries) doesn't crash the sanitize pass and
-- still renders the one legit word within it (MAX_HS_REFS_SCANNED caps the scan,
-- not correctness for a map under the cap)
do
    local huge = {}
    for i = 1, 500 do huge["junk" .. i] = { url = "https://cdn.heatsync.org/e/junk" .. i .. ".webp" } end
    huge.peepoHS = { url = "https://cdn.heatsync.org/e/hs1.webp", provider = "heatsync" }
    local ok = pcall(function()
        sock.opts.on_text(register_payload({
            type = "kick-chat-message",
            data = { platform = "kick", channel = "xqc", id = "hs7", username = "hsuser", content = "peepoHS spam",
                hsEmotes = huge },
        }))
    end)
    check(ok, "multichat: a 500-entry hsEmotes map doesn't crash the sanitize pass")
end

commands["/hsmulti"]({ words = { "/hsmulti", "off" }, channel = chan })
ba = #chan.added -- after off's confirmation sysmsg (add_system_message also lands in .added)
sock.opts.on_text(register_payload({
    type = "kick-chat-message", data = { platform = "kick", channel = "xqc", id = "k9", username = "x", content = "after off" },
}))
check(#chan.added == ba, "multichat: no injection after /hsmulti off")

-- ===== v1.4 features: archive relay, whois, hot, find, auto-multichat =====
local function count_sent(needle)
    local n = 0
    for _, s in ipairs(sock.sent) do if s:find(needle, 1, true) then n = n + 1 end end
    return n
end

-- archive channel-signal (v1.9): on by default, fires once per newly hooked
-- channel, carries ONLY type+channel, and never fires per-message. counts are
-- scoped to "relaychan" specifically — #somechannel is ALSO hooked this whole
-- time and re-signals on its own 5-min cadence in the background, so a bare
-- "twitch:chat:relay" count would be polluted by its unrelated resignals.
do
    local function relay_count_for(name)
        local n = 0
        for _, s in ipairs(sock.sent) do
            if s:find("twitch:chat:relay", 1, true) and s:find(name, 1, true) then n = n + 1 end
        end
        return n
    end
    local rchan = fake_channel("relaychan")
    channels[#channels + 1] = rchan
    local before = #sock.sent
    advance(6000) -- discovery sweep hooks the new channel + signals it
    local hit = nil
    for i = before + 1, #sock.sent do
        if sock.sent[i]:find("twitch:chat:relay", 1, true) and sock.sent[i]:find("relaychan", 1, true) then
            hit = sock.sent[i]
        end
    end
    check(hit ~= nil, "archive: channel-found signal sent for a newly hooked channel")
    check(hit ~= nil and not hit:find("message", 1, true) and not hit:find("username", 1, true)
        and not hit:find("display_name", 1, true) and not hit:find("timestamp", 1, true),
        "archive: signal carries no message content, username, or timestamp")

    -- posting chat in that channel does not itself trigger a relay anymore
    local rb = relay_count_for("relaychan")
    local am = fake_msg("archuser", "111", "archive me")
    rchan.msgs[#rchan.msgs + 1] = am
    rchan.appended_cb(am, nil)
    check(relay_count_for("relaychan") == rb, "archive: posting a message does not relay it")

    -- throttled to once per channel per 5 min: another sweep inside the window
    -- re-signals nothing
    advance(6000)
    check(relay_count_for("relaychan") == rb, "archive: re-signal throttled inside the 5-min window")

    -- past the window, the next sweep re-signals the still-open channel. feed a
    -- keepalive frame every 75s of simulated idle so the 90s ws watchdog doesn't
    -- recycle the socket mid-advance (which would orphan this test's `sock`).
    for _ = 1, 4 do
        advance(75000)
        sock.opts.on_text(register_payload({ type = "presence:heartbeat" }))
    end
    check(relay_count_for("relaychan") == rb + 1, "archive: re-signals after 5 minutes while the tab stays open")

    -- off → a fresh channel hook sends no signal at all
    require("store").set_archive(false)
    local offchan = fake_channel("archoffchan")
    channels[#channels + 1] = offchan
    local rb2 = relay_count_for("archoffchan")
    advance(6000)
    check(relay_count_for("archoffchan") == rb2, "archive: off suppresses the channel-found signal")
    require("store").set_archive(true)
end

-- /whispers + /mentions are twitch-typed virtual channels: hooked for render,
-- but never joined, relayed, or looked up for auto-multichat
do
    local vchan = fake_channel("/mentions")
    channels[#channels + 1] = vchan
    local before = #sock.sent
    advance(6000)
    local leaked = false
    for i = before + 1, #sock.sent do
        if sock.sent[i]:find("/mentions", 1, true) then leaked = true end
    end
    check(not leaked, "virtual channel: no ws join/relay frame for /mentions")
    local looked_up = false
    for _, r in ipairs(http_queue) do
        if r.url:find("%2Fmentions", 1, true) then looked_up = true end
    end
    check(not looked_up, "virtual channel: no auto-multichat profile lookup for /mentions")
end

commands["/hsmulti"]({ words = { "/hsmulti", "kick:zzz" }, channel = chan })
local rb2 = count_sent("twitch:chat:relay")
sock.opts.on_text(register_payload({
    type = "kick-chat-message", data = { platform = "kick", channel = "zzz", id = "ki", username = "k", content = "kick msg" },
}))
check(count_sent("twitch:chat:relay") == rb2, "archive: injected kick message NOT relayed")

-- /hswhois profile card
local wa = #chan.added
commands["/hswhois"]({ words = { "/hswhois", "someone" }, channel = chan })
http_answer("/api/profile/someone", { profile = { display_name = "Someone",
    stats = { user_heat = 1234, total_posts = 5, followers = 10 } } })
check(#chan.added > wa, "whois: profile card added")

-- /hshot hot streams
wa = #chan.added
commands["/hshot"]({ words = { "/hshot" }, channel = chan })
http_answer("/api/live/top", { streams = { { platform = "twitch", username = "streamerx",
    displayName = "StreamerX", viewerCount = 5000, gameName = "Just Chatting" } } })
check(#chan.added > wa, "hshot: hot streams listed")

-- /hsfind picker (unique query to avoid colliding with earlier stale searches)
wa = #chan.added
commands["/hsfind"]({ words = { "/hsfind", "findme" }, channel = chan })
http_answer("/api/emote-search?q=findme", { results = { ["7tv"] = {
    { name = "FindMe7", url = "https://cdn.7tv.app/emote/01Y/1x.webp" } } } })
check(#chan.added > wa, "hsfind: picker message added")

-- ===== /hsemotes visual menu + recents (v1.6) =====
local recents = require("recents")
local function picker_links(m)
    local out = {}
    if type(m) ~= "table" or type(m.init) ~= "table" then return out end
    for _, e in ipairs(m.init.elements) do
        if type(e) == "table" and e.type == "scaling-image" and type(e.link) == "table"
            and e.link.type == c2.LinkType.InsertText then
            out[#out + 1] = e.link.value
        end
    end
    return out
end
-- full inventory grid: both emotes, each a click-to-insert image
local em0 = #chan.added
commands["/hsemotes"]({ words = { "/hsemotes" }, channel = chan })
check(#chan.added == em0 + 1, "hsemotes: menu message emitted")
check(#picker_links(chan.added[#chan.added]) == 2, "hsemotes: both inventory emotes are click-to-insert images")
-- recents: an emote used in your OWN message jumps to the front — newEmote has
-- usage 0 (sorts LAST by usage), so seeing it first proves recents ordering.
senders.own_login = "mellen"
local ownuse = fake_msg("mellen", "42", "gg newEmote nice")
chan.msgs[#chan.msgs + 1] = ownuse
chan.appended_cb(ownuse, nil)
check(recents.names()[1] == "newEmote", "recents: own-message emote recorded most-recent")
-- persisted to the data dir so it survives a restart
do
    local raw = require("net").read_data("recents.txt")
    check(type(raw) == "string" and raw:find("newEmote", 1, true) ~= nil,
        "recents: persisted to disk for next session")
end
commands["/hsemotes"]({ words = { "/hsemotes" }, channel = chan })
check(picker_links(chan.added[#chan.added])[1] == "newEmote ", "hsemotes: recently-used emote sorts first (ahead of higher-usage)")
-- query filter: only matching names
commands["/hsemotes"]({ words = { "/hsemotes", "peepo" }, channel = chan })
do
    local links = picker_links(chan.added[#chan.added])
    check(#links == 1 and links[1] == "peepoHS ", "hsemotes: query filters inventory to matches")
end
-- unknown filter → honest empty, no crash
em0 = #chan.added
commands["/hsemotes"]({ words = { "/hsemotes", "zzznotanemote" }, channel = chan })
check(#chan.added == em0 + 1, "hsemotes: no-match query emits one honest line")

-- /hsmulti auto toggle
commands["/hsmulti"]({ words = { "/hsmulti", "auto", "on" }, channel = chan })
check(require("store").auto_multichat_enabled(), "automulti: /hsmulti auto on flips flag")
commands["/hsmulti"]({ words = { "/hsmulti", "auto", "off" }, channel = chan })

-- bttv/ffz fold into one search (all providers in results)
completion_cb({ query = "kekw" })
http_answer("/api/emote-search?q=kekw", { results = {
    ["7tv"] = { { name = "KEKW7", url = "https://cdn.7tv.app/emote/0A/1x.webp" } },
    bttv = { { name = "KEKWbttv", url = "https://cdn.betterttv.net/emote/0B/1x.webp" } },
    ffz = { { name = "KEKWffz", url = "https://cdn.frankerfacez.com/emote/0C/1" } },
} })
local seventv2 = require("seventv")
check(select(1, seventv2.resolve_render("KEKWbttv")) ~= nil and select(1, seventv2.resolve_render("KEKWffz")) ~= nil,
    "search: bttv + ffz results cached for render alongside 7tv")

-- 7tv completion prefix-surfacing: a search fired on an earlier keystroke
-- ("friere") surfaces its matches when completing the full word ("frieren"),
-- whose own search hasn't returned yet — filtered to names matching the query.
completion_cb({ query = "friere" })
http_answer("/api/emote-search?q=friere", { results = {
    ["7tv"] = { { name = "FrierenPog", url = "https://cdn.7tv.app/emote/0F/1x.webp" },
                { name = "NotAMatch", url = "https://cdn.7tv.app/emote/0G/1x.webp" } },
} })
do
    local fr = completion_cb({ query = "frieren" })
    local found, leaked = false, false
    for _, v in ipairs((fr and fr.values) or {}) do
        if v == "FrierenPog " then found = true end
        if v == "NotAMatch " then leaked = true end
    end
    check(found, "7tv completion: full query surfaces prefix-cached match (frieren←friere)")
    check(not leaked, "7tv completion: prefix names not matching the full query are filtered out")
end

-- ===== idempotent markers (double-flame bug) =====
require("store").set_flame(true)
-- flameuser is a known-HS sender (cached earlier). simulate a re-processed
-- message that ALREADY carries our flame before the username → must not stack.
local reproc = fake_msg("flameuser", "7007", "hello again")
do
    local els = reproc.elements()
    table.insert(els, 2, { type = "text", words = { "🔥" }, flags = 0, trailing_space = true })
end
rc = #chan.replaced
chan.appended_cb(reproc, nil)
do
    local flames = 0
    for _, e in ipairs(chan.replaced[#chan.replaced].new.init.elements) do
        if type(e) == "table" and e.type == "text" and e.text == "🔥" then flames = flames + 1 end
    end
    check(flames == 1, "idempotent: re-processed message has exactly one flame (not stacked)")
end
-- own messages are never flamed (redundant + avoids dropping native badges)
senders.own_login = "mellen"
local ownmsg = fake_msg("mellen", "73266147", "my own message peepoHS")
chan.msgs[#chan.msgs + 1] = ownmsg
chan.appended_cb(ownmsg, nil)
do
    local flames = 0
    for _, e in ipairs(chan.replaced[#chan.replaced].new.init.elements) do
        if type(e) == "table" and e.type == "text" and e.text == "🔥" then flames = flames + 1 end
    end
    check(flames == 0, "own messages get no flame")
end

-- ===== review fixes =====
-- fix 1: /hsfind with a CAPITALIZED query still searches providers (lowercased)
require("store").set_flame(false)
wa = #chan.added
commands["/hsfind"]({ words = { "/hsfind", "Kappa" }, channel = chan })
http_answer("/api/emote-search?q=kappa", { results = { ["7tv"] = {
    { name = "Kappa", url = "https://cdn.7tv.app/emote/0K/1x.webp" } } } })
check(#chan.added > wa, "fix: /hsfind Kappa (capitalized) returns provider results")

-- fix 2: a message with empty channel_name (injected-style) is NOT rebuilt,
-- even if it contains a renderable emote (would otherwise false-flame/rebuild)
local inj = fake_msg("mellen", "1001", "peepoHS should not render here")
inj.channel_name = ""
chan.msgs[#chan.msgs + 1] = inj
rc = #chan.replaced
chan.appended_cb(inj, nil)
check(#chan.replaced == rc, "fix: channel_name-less (injected) message skipped by render")

-- ===== chatterino badges (v1.5) =====
local badges = require("badges")
badges.load()
http_answer("/api/chatterino-badges", { badges = {
    { tooltip = "Chatterino Donator", image1 = "https://fourtf.com/chatterino/badge.png", users = { "7007", "1001" } },
} })
-- off by default → no badge even for a listed user
require("store").set_badges(false)
check(not badges.has("7007"), "badges: off by default")
require("store").set_badges(true)
check(badges.has("7007"), "badges: listed user recognized when on")
check(not badges.has("999999"), "badges: unlisted user not matched")
-- a listed user's text-only message now rebuilds to insert the badge
require("store").set_flame(false)
local bmsg = fake_msg("flameuser", "7007", "plain text with badge")
chan.msgs[#chan.msgs + 1] = bmsg
rc = #chan.replaced
chan.appended_cb(bmsg, nil)
check(#chan.replaced == rc + 1, "badges: listed user's message rebuilt to add badge")
do
    local imgs = 0
    for _, e in ipairs(chan.replaced[#chan.replaced].new.init.elements) do
        if type(e) == "table" and e.type == "scaling-image" then imgs = imgs + 1 end
    end
    check(imgs >= 1, "badges: badge image inserted")
end
require("store").set_badges(false)

-- http failure on boot path leaves plugin alive
account.name = "otheruser"
advance(61000) -- login tick sees account switch
http_fail("/api/profile/otheruser")
check(inventory.boot_failed_at == nil or type(inventory.boot_failed_at) == "number", "inventory: transport failure recorded without crash")
local res4 = completion_cb({ query = "peepo" })
check(type(res4) == "table", "completion: still alive after http failure")

-- ===== v1.7 features =====
local multichat = require("multichat")
-- chan.added holds strings (from add_system_message) OR message tables (from
-- add_message); this scans the last n entries of either kind for a substring.
local function added_text_has(frag, n)
    for i = math.max(1, #chan.added - n + 1), #chan.added do
        local m = chan.added[i]
        if type(m) == "string" then
            if m:find(frag, 1, true) then return true end
        elseif type(m) == "table" and m.init and m.init.elements then
            for _, e in ipairs(m.init.elements) do
                if type(e) == "table" and e.type == "text" and type(e.text) == "string"
                    and e.text:find(frag, 1, true) then return true end
            end
        end
    end
    return false
end
local function added_link_has(urlfrag, n)
    for i = math.max(1, #chan.added - n + 1), #chan.added do
        local m = chan.added[i]
        if type(m) == "table" and m.init and m.init.elements then
            for _, e in ipairs(m.init.elements) do
                if type(e) == "table" and type(e.link) == "table"
                    and tostring(e.link.value):find(urlfrag, 1, true) then return true end
            end
        end
    end
    return false
end

-- /hssearch: heatsync posts → clickable /thread/ links + preview + heat
local sb = #chan.added
commands["/hssearch"]({ words = { "/hssearch", "clip" }, channel = chan })
http_answer("/api/search?q=clip", { results = {
    { base36_id = "00001o", display_name = "mellen", content = "embedtest clip here", heat = 3 },
    { base36_id = "00002x", username = "someone", content = "another one", heat = 0 },
} })
check(#chan.added >= sb + 3, "hssearch: header + 2 result lines added")
check(added_link_has("/thread/00001o", 3), "hssearch: result carries a /thread/ permalink")
check(added_text_has("heat 3", 3), "hssearch: heat surfaced (no fire emoji)")
sb = #chan.added
commands["/hssearch"]({ words = { "/hssearch", "voidquery" }, channel = chan })
http_answer("/api/search?q=voidquery", { results = {} })
check(added_text_has("no heatsync posts", #chan.added - sb), "hssearch: empty result is an honest line")

-- /hschat: search the chat archive → deep-permalinked lines, narrow via @user
sb = #chan.added
commands["/hschat"]({ words = { "/hschat", "kappa", "@someviewer" }, channel = chan })
http_answer("/api/archive/search", { results = {
    { message_id = "uuid-1", platform = "twitch", channel = "forsen", username = "someviewer",
      display_name = "SomeViewer", message = "kappa kappa kappa", timestamp = "2026-07-02T04:42:00.775Z" },
} })
check(#chan.added >= sb + 2, "hschat: header + result line added")
check(added_link_has("/logs/twitch/forsen/2026-07-02?m=uuid-1", 3), "hschat: deep permalink with ?m= message anchor")
-- bare query defaults to the current tab (fast, relevant) not a global scan
sb = #chan.added
commands["/hschat"]({ words = { "/hschat", "voidterm" }, channel = chan })
local hschat_url = http_answer("/api/archive/search", { results = {} })
check(hschat_url ~= nil and hschat_url:find("channel=somechannel", 1, true) ~= nil,
    "hschat: bare query scopes to the current channel")
check(added_text_has("no archived lines", #chan.added - sb), "hschat: empty result is an honest line")
-- coverage.hint (replaces the old recency_windowed flag) → the header hints
-- that a scoped, all-time search was available but this scope didn't reach it
sb = #chan.added
commands["/hschat"]({ words = { "/hschat", "windowed", "#bigchan" }, channel = chan })
http_answer("/api/archive/search", { results = {
    { message_id = "w1", platform = "twitch", channel = "bigchan", username = "u", display_name = "U", message = "windowed hit", timestamp = "2026-07-08T00:00:00.000Z" },
}, coverage = { mode = "hot", via = "fts", hint = "scope with from:<user> or in:<channel> to search the permanent archive" } })
check(added_text_has("scope with from:", #chan.added - sb), "hschat: coverage.hint surfaces the scope-further hint")
-- coverage present but hint absent/non-string → no hint text, no crash
sb = #chan.added
commands["/hschat"]({ words = { "/hschat", "plain", "#bigchan" }, channel = chan })
http_answer("/api/archive/search", { results = {
    { message_id = "p1", platform = "twitch", channel = "bigchan", username = "u", display_name = "U", message = "plain hit", timestamp = "2026-07-08T00:00:00.000Z" },
}, coverage = { mode = "permanent", via = "channel" } })
-- "searching…" ack + header + 1 result row = 3; no extra hint line
check(#chan.added == sb + 3, "hschat: coverage without a hint adds no extra line")
-- query_errors: surfaced (capped at 3), each line safe_text-clamped
sb = #chan.added
commands["/hschat"]({ words = { "/hschat", "bad", "#bigchan" }, channel = chan })
http_answer("/api/archive/search", { results = {}, query_errors = { "unknown operator 'foo:'", "bad date 'never'", "e3", "e4" } })
check(added_text_has("query warning: unknown operator", #chan.added - sb), "hschat: query_errors surfaced")
check(not added_text_has("e4", #chan.added - sb), "hschat: query_errors capped at 3")
-- message_id:null (arrives as a missing/non-string field, same as JSON null
-- decoded through this harness's table-based payloads) → still shown, day-
-- page link with no ?m= anchor
sb = #chan.added
commands["/hschat"]({ words = { "/hschat", "nullid", "#bigchan" }, channel = chan })
http_answer("/api/archive/search", { results = {
    { platform = "twitch", channel = "bigchan", username = "u", display_name = "U", message = "no id here", timestamp = "2026-07-08T00:00:00.000Z" },
} })
check(added_link_has("/logs/twitch/bigchan/2026-07-08", #chan.added - sb), "hschat: null message_id still links to the day page")
check(not added_link_has("?m=", #chan.added - sb), "hschat: null message_id → no ?m= anchor")
-- short query → usage, mentions the query operators
commands["/hschat"]({ words = { "/hschat", "a" }, channel = chan })
check(added_text_has("usage:", 1), "hschat: sub-2-char query shows usage")
check(added_text_has("from:", 1) and added_text_has("has:", 1), "hschat: usage mentions the query operators")
-- 503 / failure path advises narrowing
sb = #chan.added
commands["/hschat"]({ words = { "/hschat", "broadterm", "#bigchan" }, channel = chan })
http_fail("/api/archive/search")
check(added_text_has("narrow it", #chan.added - sb), "hschat: generic failure suggests narrowing")
-- 503 with a real server error body → that message surfaces, not the generic one
sb = #chan.added
commands["/hschat"]({ words = { "/hschat", "toobroad", "#bigchan" }, channel = chan })
http_error("/api/archive/search", 503, { error = "search took too long — narrow the query (channel/username/date range)" })
check(added_text_has("search took too long", #chan.added - sb), "hschat: 503 body message surfaces verbatim")
-- 429 with retry_after_seconds → terse rate-limit line naming the wait
sb = #chan.added
commands["/hschat"]({ words = { "/hschat", "ratelimited", "#bigchan" }, channel = chan })
http_error("/api/archive/search", 429, { error = "Rate limit exceeded", retry_after_seconds = 7 })
check(added_text_has("rate limited", #chan.added - sb) and added_text_has("7s", #chan.added - sb),
    "hschat: 429 surfaces retry_after_seconds")

-- /hsinv: browse anyone's inventory → click-to-insert grid
sb = #chan.added
commands["/hsinv"]({ words = { "/hsinv", "grace" }, channel = chan })
http_answer("/api/profile/grace", { profile = { id = 555, display_name = "Grace" } })
http_answer("/api/users/555/emotes", { emotes = {
    { custom_name = "graceEmote", url = "https://cdn.heatsync.org/e/g.webp", width = 64, height = 64 },
} })
check(#chan.added > sb, "hsinv: emote grid emitted")
check(#picker_links(chan.added[#chan.added]) == 1, "hsinv: emote is click-to-insert")
sb = #chan.added
commands["/hsinv"]({ words = { "/hsinv", "nobody" }, channel = chan })
http_answer("/api/profile/nobody", { profile = { id = "u_nobody" } }) -- shadow id, not numeric
check(added_text_has("no heatsync profile", #chan.added - sb), "hsinv: shadow/non-numeric id → honest line, no crash")

-- /hshot: platform filter + heat, twitch excluded
sb = #chan.added
commands["/hshot"]({ words = { "/hshot", "kick" }, channel = chan })
http_answer("/api/live/top?limit=50", { streams = {
    { platform = "twitch", username = "tw1", displayName = "TW1", viewerCount = 100, category = "Chat", heat = 50 },
    { platform = "kick", username = "kk1", displayName = "KK1", viewerCount = 200, category = "Slots", heat = 80 },
    { platform = "kick", username = "kk2", displayName = "KK2", viewerCount = 50, heat = 10 },
} })
check(#chan.added == sb + 3, "hshot: kick filter → header + 2 kick lines")
check(added_text_has("heat 80", 3), "hshot: heat surfaced")
check(not added_text_has("TW1", 3), "hshot: platform filter excludes twitch")

-- /hswhois: youtube_is_live alone (no twitch/kick) still surfaces LIVE
wa = #chan.added
commands["/hswhois"]({ words = { "/hswhois", "ytonly" }, channel = chan })
http_answer("/api/profile/ytonly", { profile = { display_name = "YtOnly", youtube_is_live = true,
    stats = { user_heat = 1 } } })
check(added_text_has("LIVE", #chan.added - wa), "whois: youtube_is_live surfaces LIVE")

-- /hshot: a kick filter must also match a simulcast card whose primary leg is
-- twitch but whose platforms[] includes kick (merged card, server/platform-
-- api.ts collapseSimulcast)
sb = #chan.added
commands["/hshot"]({ words = { "/hshot", "kick" }, channel = chan })
http_answer("/api/live/top?limit=50", { streams = {
    { platform = "twitch", username = "primaryname", displayName = "Primary", viewerCount = 300,
      platforms = { "twitch", "kick" }, platformUsernames = { twitch = "primaryname", kick = "primarykick" } },
    { platform = "youtube", username = "yt1", displayName = "YT1", viewerCount = 40 },
} })
check(#chan.added == sb + 2, "hshot: kick filter matches a twitch-primary simulcast card via platforms[]")
-- the merged card's twitch leg still gets a native JumpToChannel, keyed off
-- platformUsernames.twitch rather than the row's own username/channel
check(added_link_has("primaryname", #chan.added - sb), "hshot: merged card jumps via platformUsernames.twitch")

-- /hshot: platformUsernames.twitch wins the jump link even when the row's own
-- platform/username is NOT twitch (a kick-primary card with a twitch leg)
sb = #chan.added
commands["/hshot"]({ words = { "/hshot" }, channel = chan })
http_answer("/api/live/top?limit=50", { streams = {
    { platform = "kick", username = "kickprimary", displayName = "KickPrimary", viewerCount = 90,
      platforms = { "kick", "twitch" }, platformUsernames = { twitch = "thetwitchleg", kick = "kickprimary" } },
} })
check(added_link_has("thetwitchleg", #chan.added - sb), "hshot: kick-primary card still jumps to its twitch leg")

-- /hsmoments: hours + platform filter + platform prefix
sb = #chan.added
commands["/hsmoments"]({ words = { "/hsmoments", "48h", "kick" }, channel = chan })
http_answer("/api/moments?limit=30&hours=48", { moments = {
    { id = "ma", platform = "kick", channel = "cageero", rate = 28, baseline = "0.4" },
    { id = "mb", platform = "twitch", channel = "forsen", rate = 10, baseline = "1" },
    { id = "mc", platform = "kick", channel = "trainwreck", rate = 5, baseline = "1" },
} })
check(#chan.added == sb + 3, "hsmoments: 48h kick filter → header + 2 kick moments")
check(added_text_has("kick:#cageero", 3), "hsmoments: platform prefix shown")
check(not added_text_has("#forsen", 3), "hsmoments: platform filter excludes twitch moment")

-- /hslogs: top-channels breakdown (up to 3)
sb = #chan.added
commands["/hslogs"]({ words = { "/hslogs", "topuser" }, channel = chan })
http_answer("/api/chatter/twitch/topuser/stats", { totals = { messages = 1000, channels = 5, activeDays = 20 },
    topChannels = { { channel = "a", messages = 500 }, { channel = "b", messages = 300 },
                    { channel = "c", messages = 100 }, { channel = "d", messages = 50 } } })
check(added_text_has("top channels:", #chan.added - sb), "hslogs: top-channels line emitted")
check(added_text_has("#a (500)", #chan.added - sb), "hslogs: top channel with message count")
check(not added_text_has("#d", #chan.added - sb), "hslogs: capped at 3 channels")

-- /hslogs: 404 opted_out → honest "opted out" line; archive link still shown
sb = #chan.added
commands["/hslogs"]({ words = { "/hslogs", "hiddenuser" }, channel = chan })
http_error("/api/chatter/twitch/hiddenuser/stats", 404, { error = "opted_out", error_code = "opted_out" })
check(added_text_has("opted out of logs", #chan.added - sb), "hslogs: opted_out surfaces an honest line")
check(added_link_has("/logs/search", #chan.added - sb), "hslogs: archive link still shown when opted out")

-- /hslogs: 503 busy → terse retry line; archive link still shown
sb = #chan.added
commands["/hslogs"]({ words = { "/hslogs", "busyuser" }, channel = chan })
http_error("/api/chatter/twitch/busyuser/stats", 503, { error = "busy" })
check(added_text_has("busy", #chan.added - sb), "hslogs: 503 busy surfaces a retry line")
check(added_link_has("/logs/search", #chan.added - sb), "hslogs: archive link still shown when busy")

-- /hshelp: tier-gated command index
sb = #chan.added
commands["/hshelp"]({ words = { "/hshelp" }, channel = chan })
check(#chan.added >= sb + 5, "hshelp: lists command groups")
check(added_text_has("/hssearch", #chan.added - sb), "hshelp: mentions /hssearch")
check(added_text_has("/hsinv", #chan.added - sb), "hshelp: mentions /hsinv")

-- multichat dedup ring buffer: >DEDUP_MAX unique ids evict the oldest in O(1);
-- an evicted id re-injects, a still-resident recent id stays deduped.
local msock = sockets[#sockets]
commands["/hsmulti"]({ words = { "/hsmulti", "kick:ring" }, channel = chan })
for i = 1, 900 do
    msock.opts.on_text(register_payload({ type = "kick-chat-message",
        data = { platform = "kick", channel = "ring", id = "r" .. i, username = "u", content = "m" .. i } }))
end
local a = #chan.added
msock.opts.on_text(register_payload({ type = "kick-chat-message",
    data = { platform = "kick", channel = "ring", id = "r1", username = "u", content = "evicted replay" } }))
check(#chan.added == a + 1, "dedup ring: id evicted past DEDUP_MAX re-injects")
local b = #chan.added
msock.opts.on_text(register_payload({ type = "kick-chat-message",
    data = { platform = "kick", channel = "ring", id = "r900", username = "u", content = "recent dup" } }))
check(#chan.added == b, "dedup ring: still-resident recent id stays deduped")

-- multichat dropped counter: line to a gone tab, and a malformed (channel-less) line
local ghost = { get_name = function() return "closedtab" end }
commands["/hsmulti"]({ words = { "/hsmulti", "kick:gone" }, channel = ghost })
local d0 = multichat.dropped
msock.opts.on_text(register_payload({ type = "kick-chat-message",
    data = { platform = "kick", channel = "gone", id = "g1", username = "u", content = "to nowhere" } }))
check(multichat.dropped == d0 + 1, "dropped: inject to a gone tab is counted")
d0 = multichat.dropped
msock.opts.on_text(register_payload({ type = "kick-chat-message",
    data = { platform = "kick", id = "nochan", username = "u", content = "x" } }))
check(multichat.dropped == d0 + 1, "dropped: malformed channel-less line is counted")

-- /hsstatus: multichat summary + per-tab detail legible
sb = #chan.added
commands["/hsstatus"]({ words = { "/hsstatus" }, channel = chan })
check(added_text_has("source(s) across", #chan.added - sb), "status: multichat summary line")
check(added_text_has("drop(s)", #chan.added - sb), "status: drop count surfaced when > 0")
check(added_text_has("kick/ring", #chan.added - sb), "status: per-tab source breakdown shown")

-- render error-log flood guard: a flapping fault (throws on hit-messages, clean
-- on the misses between) must still suppress after 3 logs — not reset the counter
-- on every no-op miss and log forever (regression: reset fired on all successes).
do
    local function count_fail_logs()
        local n = 0
        for _, l in ipairs(log_lines) do if l:find("render failed", 1, true) then n = n + 1 end end
        return n
    end
    require("store").set_flame(false)
    local base = count_fail_logs()
    MSG_NEW_THROWS = true
    -- flameuser/peepoHS is a cached known-HS sender → hit → reaches build_replacement
    -- → Message.new throws. interleave plain-text misses from fresh non-HS users.
    for i = 1, 20 do
        local hit = fake_msg("flameuser", "7007", "peepoHS spam " .. i)
        chan.msgs[#chan.msgs + 1] = hit
        chan.appended_cb(hit, nil)
        local miss = fake_msg("rando" .. i, "600" .. i, "just plain words here nothing")
        chan.msgs[#chan.msgs + 1] = miss
        chan.appended_cb(miss, nil)
    end
    MSG_NEW_THROWS = false
    local logged = count_fail_logs() - base
    check(logged == 3, "render flood-guard: flapping fault logs exactly 3× then stays suppressed (got " .. logged .. ")")
end

-- CDN allowlist (beacon defense): an emote whose backing URL is on a
-- non-allowlisted host must NOT be loaded — it falls back to text. the host here
-- is the classic suffix-bypass ("heatsync.org.evil.com" is NOT ".heatsync.org").
require("store").set_flame(false)
senders.feed_broadcast("evilhost", "beaconMote",
    { url = "https://heatsync.org.evil.com/e/x.webp", width = 32, height = 32 })
do
    local em = fake_msg("evilhost", "13337", "look beaconMote here")
    chan.msgs[#chan.msgs + 1] = em
    local rc0 = #chan.replaced
    chan.appended_cb(em, nil)
    local imaged = false
    if #chan.replaced > rc0 then
        for _, e in ipairs(chan.replaced[#chan.replaced].new.init.elements) do
            if type(e) == "table" and e.type == "scaling-image" then imaged = true end
        end
    end
    check(not imaged, "allowlist: emote on a non-allowlisted host renders as text, never an image")
end
-- and an allowlisted host still images (sanity that the gate isn't over-broad)
senders.feed_broadcast("gooduser2", "goodMote2",
    { url = "https://cdn.7tv.app/emote/GOOD/1x.webp", width = 32, height = 32 })
do
    local em = fake_msg("gooduser2", "13338", "look goodMote2 here")
    chan.msgs[#chan.msgs + 1] = em
    chan.appended_cb(em, nil)
    local imaged = false
    for _, e in ipairs(chan.replaced[#chan.replaced].new.init.elements) do
        if type(e) == "table" and e.type == "scaling-image" then imaged = true end
    end
    check(imaged, "allowlist: emote on an allowlisted CDN still renders as an image")
end

-- ===== end-to-end with REAL production data =====
-- drives the actual render/senders/seventv/inventory/img pipeline with real
-- heatsync.org responses (test/fixtures/real.lua), proving the three things a
-- user cares about, against production data shapes + real CDN URLs + real dims:
--   1. seeing OTHER heatsync users' emotes   2. your OWN emotes rendering when
--   you post   3. deep 7tv search results staying insert-only (privacy).
require("store").set_flame(false)
local FX = dofile(PLUGIN .. "/test/fixtures/real.lua")
local function has_image_in(m)
    for _, e in ipairs(m.new.init.elements) do
        if type(e) == "table" and e.type == "scaling-image" then return true end
    end
    return false
end

-- (1) another heatsync user's REAL emote renders for you
local se = FX.inventory[1] -- real ffz emote, 128x128
senders.feed_broadcast("realsender", se.name, { url = se.url, width = se.width, height = se.height })
do
    local m = fake_msg("realsender", "550001", "gg " .. se.name .. " nice")
    chan.msgs[#chan.msgs + 1] = m
    chan.appended_cb(m, nil)
    check(has_image_in(chan.replaced[#chan.replaced]),
        "e2e/real: another user's real heatsync emote (" .. se.name .. ") renders as an image")
end

-- (2) your OWN real inventory renders when you post it (real 7tv 96x32 record —
-- the wide/short case that must scale by height without stretch)
do
    local invp = { emotes = {} }
    for _, e in ipairs(FX.inventory) do
        invp.emotes[#invp.emotes + 1] = { custom_name = e.name, url = e.url, width = e.width, height = e.height, usage_count = 1 }
    end
    inventory.refresh("realmellen")
    http_answer("/api/profile/realmellen", { profile = { id = 999 } })
    http_answer("/api/users/999/emotes", invp)
    check(inventory.count() == #FX.inventory, "e2e/real: real inventory loaded (" .. #FX.inventory .. " emotes)")
    senders.own_login = "realmellen"
    local own = FX.inventory[4].name -- BirdgeHmm, real 7tv 96x32
    local m = fake_msg("realmellen", "999", "using " .. own .. " right now")
    chan.msgs[#chan.msgs + 1] = m
    chan.appended_cb(m, nil)
    check(has_image_in(chan.replaced[#chan.replaced]),
        "e2e/real: your own real heatsync emote (" .. own .. ") renders when you post it")
end

-- (3) deep 7tv search: real results are searchable/insertable but NEVER inline-render
do
    local sevp = { results = { ["7tv"] = {} } }
    for _, e in ipairs(FX.sevtv_7tv) do sevp.results["7tv"][#sevp.results["7tv"] + 1] = { name = e.name, url = e.url } end
    completion_cb({ query = "peepo" })
    http_answer("/api/emote-search?q=peepo", sevp)
    local seventv_m = require("seventv")
    local deep = FX.sevtv_7tv[1].name -- real 7tv "Peepo", not in the inventory
    check(select(1, seventv_m.resolve_render(deep)) ~= nil,
        "e2e/real: deep 7tv search result (" .. deep .. ") is cached for /hsfind + tab-complete")
    -- a chatter with no heatsync inventory posts that exact 7tv word → must stay text
    local m = fake_msg("randomchatter", "550003", "haha " .. deep .. " lol that was funny")
    chan.msgs[#chan.msgs + 1] = m
    local rc = #chan.replaced
    chan.appended_cb(m, nil)
    check(#chan.replaced == rc,
        "e2e/real: deep 7tv word (" .. deep .. ") does NOT inline-render from a non-owner (privacy invariant)")
end

-- recents dead-name filtering: an emote recorded as recently-used must vanish
-- from /hsemotes once it leaves the inventory (a stale recents.txt must never
-- surface a dead name — the exact case recents.lua's comment warns about).
do
    local recents = require("recents")
    recents.note("using BirdgeHmm now") -- BirdgeHmm is in the current real inventory → recorded
    local function in_recents(n)
        for _, x in ipairs(recents.names()) do if x == n then return true end end
        return false
    end
    check(in_recents("BirdgeHmm"), "recents: a used inventory emote is recorded")
    inventory.refresh("realmellen")
    http_answer("/api/profile/realmellen", { profile = { id = 999 } })
    http_answer("/api/users/999/emotes", { emotes = { { custom_name = "OnlyThis", url = "https://cdn.7tv.app/emote/0Z/1x.webp", width = 32, height = 32 } } })
    check(not in_recents("BirdgeHmm"), "recents: an emote gone from inventory is filtered out (no dead name)")
end

-- multichat ephemeral auto-link reaping: an auto-link (from auto-multichat) must
-- be reaped when its twitch tab closes; a manual link would persist.
do
    local before = multichat.stats()
    multichat.link("autotab", "kick", "autochan", true) -- auto=true → ephemeral
    check(multichat.stats() == before + 1, "multichat: ephemeral auto-link added")
    multichat.unlink_auto("autotab")
    check(multichat.stats() == before, "multichat: unlink_auto reaps the ephemeral auto-link on tab close")
end

-- ===== Fort-Knox hardening =====
local ssock = sockets[#sockets]
-- https-only: an http:// URL even on an ALLOWLISTED host must be rejected
senders.feed_broadcast("httpuser", "httpMote", { url = "http://cdn.7tv.app/emote/X/1x.webp", width = 32, height = 32 })
do
    local m = fake_msg("httpuser", "770001", "look httpMote here")
    chan.msgs[#chan.msgs + 1] = m
    chan.appended_cb(m, nil)
    local imaged = false
    for _, e in ipairs(chan.replaced[#chan.replaced].new.init.elements) do
        if type(e) == "table" and e.type == "scaling-image" then imaged = true end
    end
    check(not imaged, "https-only: an http:// emote URL is rejected even on an allowlisted host")
end
-- source-scoped dedup: two sources sharing a message id both inject (no shadow)
commands["/hsmulti"]({ words = { "/hsmulti", "kick:srca" }, channel = chan })
commands["/hsmulti"]({ words = { "/hsmulti", "kick:srcb" }, channel = chan })
do
    local a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "kick-chat-message", data = { platform = "kick", channel = "srca", id = "shared1", username = "u", content = "from A" } }))
    ssock.opts.on_text(register_payload({ type = "kick-chat-message", data = { platform = "kick", channel = "srcb", id = "shared1", username = "u", content = "from B" } }))
    check(#chan.added == a0 + 2, "dedup scope: same id from two distinct sources both inject")
    local a1 = #chan.added
    ssock.opts.on_text(register_payload({ type = "kick-chat-message", data = { platform = "kick", channel = "srca", id = "shared1", username = "u", content = "A dup" } }))
    check(#chan.added == a1, "dedup scope: a repeat id from the same source is still deduped")
end
-- backfill cap: a hostile flood of >250 lines injects at most 250
do
    commands["/hsmulti"]({ words = { "/hsmulti", "kick:flood" }, channel = chan })
    local msgs = {}
    for i = 1, 400 do msgs[i] = { platform = "kick", channel = "flood", id = "f" .. i, username = "u", content = "x" } end
    local a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "kick-chat-backfill", channel = "flood", messages = msgs }))
    check(#chan.added - a0 <= 250, "backfill cap: a 400-line flood injects at most 250 (got " .. (#chan.added - a0) .. ")")
end
-- emote-name safety: a hostile name (newline → InsertText input injection, or
-- absurd length) must be rejected before it can become a link value/tooltip
do
    local n = require("net")
    check(n.is_safe_name("peepoHappy"), "name-safety: a clean emote name is allowed")
    check(not n.is_safe_name("hi\n/w victim secret"), "name-safety: a newline-injection name is rejected")
    check(not n.is_safe_name(string.rep("x", 101)), "name-safety: an absurdly long name is rejected")
    check(n.is_safe_name("Ｐｅｅｐｏ３"), "name-safety: a legit multibyte unicode name is allowed (char count, not bytes)")
    check(n.parse_emote_row({ name = "bad\nname", url = "https://cdn.7tv.app/e/1.webp" }) == nil,
        "name-safety: parse_emote_row drops a control-char name")
    -- a name is inserted VERBATIM into chat on click (picker/tab-complete): a
    -- space-bearing or command-prefixed name would become a runnable command
    check(not n.is_safe_name("/ban victim reason"), "name-safety: a leading-/ command name is rejected")
    check(not n.is_safe_name("two words"), "name-safety: a name with a space is rejected")
    check(not n.is_safe_name(".timeout victim"), "name-safety: a leading-. command name is rejected")
end
-- url safety: a CDN url never passes is_safe_name, so it's the one unbounded
-- string field — a multi-MB value repeated across the row caps is a heap-DoS
do
    local n = require("net")
    check(n.is_safe_url("https://cdn.7tv.app/emote/X/1x.webp"), "url-safety: a normal cdn url is allowed")
    check(not n.is_safe_url("https://cdn.7tv.app/" .. string.rep("a", 3000)), "url-safety: a >2KB url is rejected")
    check(not n.is_safe_url("https://x/\n1.webp"), "url-safety: a control-byte url is rejected")
    check(n.parse_emote_row({ name = "ok", url = "https://x/" .. string.rep("a", 4000) }) == nil,
        "url-safety: parse_emote_row drops an over-long url")
end
-- dimension safety: a raw JSON 1e400 parses to math.huge and would sail past a
-- bare `> 0`, mis-scaling downstream — reject non-finite + absurd pixel sizes
do
    local n = require("net")
    check(n.pick_first_num({ width = 32 }, "width") == 32, "dim-safety: a normal dimension passes")
    check(n.pick_first_num({ width = math.huge }, "width") == nil, "dim-safety: math.huge (1e400) is rejected")
    check(n.pick_first_num({ width = 999999 }, "width") == nil, "dim-safety: an absurd pixel size is rejected")
end
-- render time gate: an emote with `a` (added_at) only renders once the message
-- time is within 120s of it; with `u` (until) it stops rendering once the
-- message time is 120s past it. exercised end-to-end through OWN inventory
-- (own_map_fn; the current own login is "realmellen" — the e2e/real fixture
-- above adopted it and never reverted) rather than the sender batch path — the sender
-- cache's flush() is single-flight and best-effort (a request an earlier test
-- left unanswered would wedge it for the rest of the suite; own inventory's
-- refresh() is a separate, always-fresh request this test fully controls).
do
    local n = require("net")
    local inv = require("inventory")
    local added_iso = "2026-01-01T00:00:00Z"
    local added_ms = n.iso_to_ms(added_iso)
    inv.refresh("realmellen")
    http_answer("/api/profile/realmellen", { profile = { id = 999 } })
    http_answer("/api/users/999/emotes", { emotes = {
        { custom_name = "gateEmoteA", url = "https://cdn.heatsync.org/e/ga.webp", width = 32, height = 32, added_at = added_iso },
    } })
    check(inv.resolve("gateEmoteA") ~= nil and inv.resolve("gateEmoteA").a == added_ms,
        "render gate: precondition — own inventory carries the parsed added_at")

    local function post(text, t)
        local m = fake_msg("realmellen", "999", text)
        m.server_received_time = t
        chan.msgs[#chan.msgs + 1] = m
        local before = #chan.replaced
        chan.appended_cb(m, nil)
        return #chan.replaced > before
    end

    check(not post("gateEmoteA before", added_ms - 200000),
        "render gate: a message well before added_at does not render the emote")
    check(post("gateEmoteA within slack", added_ms - 100000),
        "render gate: a message within the 120s slack before added_at DOES render")
    check(post("gateEmoteA long after", added_ms + 999999999),
        "render gate: a message long after added_at (no until bound) still renders")
end
do
    local n = require("net")
    local inv = require("inventory")
    local until_iso = "2026-01-01T00:00:00Z"
    local until_ms = n.iso_to_ms(until_iso)
    inv.refresh("realmellen")
    http_answer("/api/profile/realmellen", { profile = { id = 999 } })
    http_answer("/api/users/999/emotes", { emotes = {
        { custom_name = "gateEmoteU", url = "https://cdn.heatsync.org/e/gu.webp", width = 32, height = 32, ["until"] = until_iso },
    } })
    check(inv.resolve("gateEmoteU") ~= nil and inv.resolve("gateEmoteU").u == until_ms,
        "render gate: precondition — own inventory carries the parsed until")

    local function post(text, t)
        local m = fake_msg("realmellen", "999", text)
        m.server_received_time = t
        chan.msgs[#chan.msgs + 1] = m
        local before = #chan.replaced
        chan.appended_cb(m, nil)
        return #chan.replaced > before
    end

    check(post("gateEmoteU before until", until_ms - 999999999),
        "render gate: a message long before until DOES render")
    check(post("gateEmoteU within slack", until_ms + 100000),
        "render gate: a message within the 120s slack after until still renders")
    check(not post("gateEmoteU long after", until_ms + 200000),
        "render gate: a message well past until (+120s slack) does not render")
end
-- iso_to_ms: pure-Lua days-from-civil parser (no os.date/os.time available).
-- edge cases: leap day, a fractional-second + Z suffix (JS Date.toJSON shape),
-- a numeric +/- offset, epoch-number passthrough (both ms and s magnitudes),
-- and garbage that must fail closed (nil), never a wrong-but-plausible guess.
do
    local n = require("net")
    check(n.iso_to_ms("2024-02-29T00:00:00.000Z") == n.iso_to_ms("2024-02-29T00:00:00Z"),
        "iso_to_ms: fractional .000 and bare-seconds agree")
    check(n.iso_to_ms("2024-02-29T12:00:00Z") - n.iso_to_ms("2024-02-28T12:00:00Z") == 86400000,
        "iso_to_ms: leap day (2024-02-29) is exactly one day after 02-28")
    check(n.iso_to_ms("2023-02-29T00:00:00Z") == nil, "iso_to_ms: Feb 29 in a non-leap year is rejected")
    check(n.iso_to_ms("2026-01-01T00:00:00.500Z") - n.iso_to_ms("2026-01-01T00:00:00Z") == 500,
        "iso_to_ms: fractional seconds are honored")
    check(n.iso_to_ms("2026-01-01T00:00:00+02:00") == n.iso_to_ms("2026-01-01T00:00:00Z") - 2 * 3600 * 1000,
        "iso_to_ms: a positive offset shifts back toward UTC")
    check(n.iso_to_ms("2026-01-01T00:00:00-05:00") == n.iso_to_ms("2026-01-01T00:00:00Z") + 5 * 3600 * 1000,
        "iso_to_ms: a negative offset shifts forward toward UTC")
    check(n.iso_to_ms("2026-01-01 00:00:00") == n.iso_to_ms("2026-01-01T00:00:00Z"),
        "iso_to_ms: a space separator is accepted the same as 'T'")
    check(n.iso_to_ms(1774000000000) == 1774000000000, "iso_to_ms: a plausible ms-epoch number passes through")
    check(n.iso_to_ms(1774000000) == 1774000000000, "iso_to_ms: a plausible s-epoch number is scaled to ms")
    check(n.iso_to_ms("not a date") == nil, "iso_to_ms: garbage text is rejected")
    check(n.iso_to_ms("2026-13-01T00:00:00Z") == nil, "iso_to_ms: an out-of-range month is rejected")
    check(n.iso_to_ms("2026-01-01T00:00:00+99:99") == nil, "iso_to_ms: a garbage offset is rejected")
    check(n.iso_to_ms(math.huge) == nil, "iso_to_ms: non-finite numbers are rejected")
    check(n.iso_to_ms(nil) == nil, "iso_to_ms: nil is rejected")
    check(n.iso_to_ms({}) == nil, "iso_to_ms: a table is rejected")
end
-- content-warning gate: parse_emote_row skips nsfw/sexual/gore rows (matches
-- the server's default-hide categories) but leaves an ungated row unchanged
do
    local n = require("net")
    local clean = { custom_name = "clean", url = "https://cdn.heatsync.org/e/c.webp", width = 32, height = 32 }
    check(n.parse_emote_row(clean) ~= nil, "cw-gate: an unflagged row parses normally")
    local nsfw = { custom_name = "nsfw1", url = "https://cdn.heatsync.org/e/n.webp", width = 32, height = 32, nsfw = true }
    check(n.parse_emote_row(nsfw) == nil, "cw-gate: nsfw=true is skipped")
    local sexual = { custom_name = "sex1", url = "https://cdn.heatsync.org/e/s.webp", width = 32, height = 32, cw_cats = { "sexual" } }
    check(n.parse_emote_row(sexual) == nil, "cw-gate: cw_cats containing 'sexual' is skipped")
    local gore = { custom_name = "gore1", url = "https://cdn.heatsync.org/e/g.webp", width = 32, height = 32, cw_cats = { "gore" } }
    check(n.parse_emote_row(gore) == nil, "cw-gate: cw_cats containing 'gore' is skipped")
    local weapons = { custom_name = "wep1", url = "https://cdn.heatsync.org/e/w.webp", width = 32, height = 32, cw_cats = { "weapons" } }
    check(n.parse_emote_row(weapons) ~= nil, "cw-gate: a non-sexual/gore category (weapons) is NOT skipped")
end
-- parse_emote_row a/u fields: present when the row carries them, absent (nil)
-- when it doesn't — a row with no dates renders exactly as before the gate
do
    local n = require("net")
    local live = { custom_name = "live1", url = "https://cdn.heatsync.org/e/l.webp", width = 32, height = 32,
        added_at = "2026-01-01T00:00:00Z" }
    local rec = n.parse_emote_row(live)
    check(rec ~= nil and rec.a == n.iso_to_ms("2026-01-01T00:00:00Z") and rec.u == nil,
        "parse_emote_row: added_at → rec.a, no until → rec.u is nil")
    local hist = { custom_name = "hist1", url = "https://cdn.heatsync.org/e/h.webp", width = 32, height = 32,
        ["until"] = "2026-01-01T00:00:00Z" }
    local rec2 = n.parse_emote_row(hist)
    check(rec2 ~= nil and rec2.u == n.iso_to_ms("2026-01-01T00:00:00Z") and rec2.a == nil,
        "parse_emote_row: until → rec.u, no added_at → rec.a is nil")
    local plain = { custom_name = "plain1", url = "https://cdn.heatsync.org/e/p.webp", width = 32, height = 32 }
    local rec3 = n.parse_emote_row(plain)
    check(rec3 ~= nil and rec3.a == nil and rec3.u == nil, "parse_emote_row: a row without dates is unchanged")
end
-- image allowlist: the userinfo (user:pass@host) trick must NOT bypass the host
-- allowlist — the real fetch host is after the '@', so "kick.com:@evil.com" is evil
do
    local img = require("img")
    check(img.for_url("https://kick.com:@evil.com/beacon.png", 32, 32) == nil,
        "allowlist: userinfo-colon bypass (kick.com:@evil.com) is rejected")
    check(img.for_url("https://heatsync.org.evil.com/x.png", 32, 32) == nil,
        "allowlist: suffix-append bypass (heatsync.org.evil.com) is rejected")
    check(img.for_url("https://evil.com/x.png", 32, 32) == nil,
        "allowlist: a non-allowlisted host is rejected")
end
-- image allowlist: static-cdn.jtvnw.net (twitch-hosted inventory emotes) is
-- allowed exactly, and neither a subdomain-prefix nor a suffix-append trick
-- rides in on it
do
    local img = require("img")
    check(img.for_url("https://static-cdn.jtvnw.net/emoticons/v2/1/default/dark/3.0", 32, 32) ~= nil,
        "allowlist: static-cdn.jtvnw.net is allowed")
    check(img.for_url("https://static-cdn.jtvnw.net.evil.com/x.png", 32, 32) == nil,
        "allowlist: suffix-append bypass (static-cdn.jtvnw.net.evil.com) is rejected")
    check(img.for_url("https://evil-jtvnw.net/x.png", 32, 32) == nil,
        "allowlist: unrelated host sharing a substring (evil-jtvnw.net) is rejected")
end
-- per-message emote-token cap: one hostile kick line with 100 [emote:] tokens
-- builds at most MAX_EMOTE_TOKENS(50) image elements, not 100
do
    commands["/hsmulti"]({ words = { "/hsmulti", "kick:tokcap" }, channel = chan })
    ssock.opts.on_text(register_payload({ type = "kick-chat-message",
        data = { platform = "kick", channel = "tokcap", id = "tok1", username = "u", content = string.rep("[emote:1:x]", 100) } }))
    local imgs, m = 0, chan.added[#chan.added]
    if type(m) == "table" and m.init and m.init.elements then
        for _, e in ipairs(m.init.elements) do if type(e) == "table" and e.type == "scaling-image" then imgs = imgs + 1 end end
    end
    check(imgs <= 50, "token cap: a 100-emote kick message builds at most 50 image elements (got " .. imgs .. ")")
end


-- senders negative-cache: a failed batch lookup briefly caches "no HS emotes" so
-- a flaky upstream doesn't hot-loop re-querying the same login
do
    senders.clear()
    senders.resolve("ghostuser", "990099") -- queues a lookup
    advance(2500)                          -- senders.flush drains the queue
    local failed = http_fail("/api/users/emotes/batch")
    check(failed, "senders: batch lookup fired for the queued sender")
    check(not senders.is_known_hs("ghostuser"), "senders: a failed lookup negative-caches (not known-HS)")
end

-- multichat: unlink a SINGLE platform leaves other sources on the tab linked
-- (only the unlink-ALL path was covered before)
do
    multichat.link("uttab", "kick", "kk", nil)
    multichat.link("uttab", "yt", "yy", nil)
    local before = multichat.stats()
    local removed = multichat.unlink("uttab", "kick", "kk")
    check(removed == 1 and multichat.stats() == before - 1,
        "multichat: unlink one platform leaves the tab's other source linked")
end

-- ===== live-status (opt-in): go-live/offline lines for linked kick/yt =====
require("store").set_live(true)
commands["/hsmulti"]({ words = { "/hsmulti", "kick:livechan" }, channel = chan })
do
    local a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "stream:online", platform = "kick",
        channel = "livechan", game = "Slots", title = "big win" }))
    check(added_text_has("is live on kick", #chan.added - a0), "live: a linked kick source going live shows a 🔴 line")
    check(added_text_has("Slots", #chan.added - a0), "live: the go-live line carries the game/title")
    a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "stream:offline", platform = "kick", channel = "livechan" }))
    check(added_text_has("went offline on kick", #chan.added - a0), "live: a linked kick source going offline shows a ⚫ line")
end
do -- an UNlinked channel's event must be ignored
    local a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "stream:online", platform = "kick", channel = "unlinkedchan" }))
    check(#chan.added == a0, "live: an unlinked channel's go-live is ignored")
end
do -- twitch is skipped (native chatterino already shows it)
    local a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "stream:online", platform = "twitch", channel = "livechan" }))
    check(#chan.added == a0, "live: twitch go-live is skipped (shown natively)")
end
require("store").set_live(false)
do -- toggled off → no line even for a linked source
    local a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "stream:online", platform = "kick", channel = "livechan" }))
    check(#chan.added == a0, "live: /hslive off suppresses go-live lines")
end

-- ===== youtube:status: dedup'd status lines + live.lua feed + slow retry =====
-- (youtube has no stream:online/offline of its own — see live.lua M.youtube_status)
do
    local multichat = require("multichat")
    require("store").set_live(true)
    commands["/hsmulti"]({ words = { "/hsmulti", "yt:@statusyt" }, channel = chan })

    local a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "youtube:status", channelId = "@statusyt", status = "not-live" }))
    check(added_text_has("youtube: not live", #chan.added - a0), "youtube:status: not-live shows a status line")
    local after_first = #chan.added
    ssock.opts.on_text(register_payload({ type = "youtube:status", channelId = "@statusyt", status = "not-live" }))
    check(#chan.added == after_first, "youtube:status: repeating the same status doesn't re-show the line (dedupe)")

    a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "youtube:status", channelId = "@statusyt", status = "chat-off" }))
    check(added_text_has("chat is off", #chan.added - a0), "youtube:status: chat-off shows a status line")
    a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "youtube:status", channelId = "@statusyt", status = "no-slot" }))
    check(added_text_has("no free youtube slot", #chan.added - a0), "youtube:status: no-slot shows a status line")

    -- connected/ended feed live.lua's go-live/offline line (youtube never
    -- emits stream:online/offline itself)
    a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "youtube:status", channelId = "@statusyt", status = "connected", videoId = "v1" }))
    check(added_text_has("is live on yt", #chan.added - a0), "youtube:status: connected feeds live.lua a go-live line")
    a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "youtube:status", channelId = "@statusyt", status = "ended" }))
    check(added_text_has("went offline on yt", #chan.added - a0), "youtube:status: ended feeds live.lua a went-offline line")

    -- /hslive off suppresses only the live.lua feed, not the plain status lines
    require("store").set_live(false)
    a0 = #chan.added
    ssock.opts.on_text(register_payload({ type = "youtube:status", channelId = "@statusyt", status = "not-live" }))
    ssock.opts.on_text(register_payload({ type = "youtube:status", channelId = "@statusyt", status = "connected", videoId = "v2" }))
    check(not added_text_has("is live on yt", #chan.added - a0), "youtube:status: /hslive off suppresses the connected go-live line")
    require("store").set_live(true)

    -- slow retry: driven by init's 60s tick, but retry_yt_tick halves that to
    -- ~120s itself — fires on every OTHER call, only while not connected. the
    -- module-level tick counter has already advanced from earlier advance()
    -- calls elsewhere in this suite (the real net.every(60s,...) loop has been
    -- running the whole time), so its current parity is unknown here — assert
    -- on two CONSECUTIVE calls instead of a specific "1st skip, 2nd fires" order.
    ssock.opts.on_text(register_payload({ type = "youtube:status", channelId = "@statusyt", status = "not-live" }))
    -- scoped to THIS source specifically: other yt sources may already be
    -- linked-and-non-connected from earlier in the suite (e.g. "uttab"/yy,
    -- Fort-Knox section) and retry_yt_tick legitimately re-subscribes those
    -- too — that's correct behavior, just not what this test is asserting on.
    local function subs_sent()
        local n = 0
        for _, s in ipairs(ssock.sent) do
            if s:find("youtube:subscribe", 1, true) and s:find("statusyt", 1, true) then n = n + 1 end
        end
        return n
    end
    local before_subs = subs_sent()
    multichat.retry_yt_tick()
    multichat.retry_yt_tick()
    check(subs_sent() == before_subs + 1,
        "youtube retry: exactly one of two consecutive ticks re-subscribes a non-connected linked yt source")

    -- once connected, the retry loop stops touching this source regardless of tick parity
    ssock.opts.on_text(register_payload({ type = "youtube:status", channelId = "@statusyt", status = "connected", videoId = "v3" }))
    before_subs = subs_sent()
    multichat.retry_yt_tick()
    multichat.retry_yt_tick()
    check(subs_sent() == before_subs, "youtube retry: a connected source is not retried")

    commands["/hsmulti"]({ words = { "/hsmulti", "off" }, channel = chan })
end

-- ===== fuzz: throw garbage at every entry point, assert nothing escapes =====
-- the plugin's pcall guards + type checks should survive ANY malformed ws frame
-- or command args. seeded so a failure is reproducible.
math.randomseed(1)
do
    local function garb()
        local pool = {
            function() return nil end, function() return true end, function() return false end,
            function() return 0 end, function() return -1 end, function() return math.random(2 ^ 31) end,
            function() return "" end, function() return "x" end, function() return "\0\1\2\n\r\t" end,
            function() return string.rep("A", 5000) end, function() return {} end,
            function() return { math.random(), math.random() } end,
            function() return { type = "garbage", data = {}, messages = {} } end,
        }
        return pool[math.random(#pool)]()
    end
    local function rand_ws()
        local types = { "kick-chat-message", "kick-chat-backfill", "youtube:chat", "youtube:status",
            "emote:added", "emote:removed", "emotes:refresh", "emote:broadcast", "emotes:batch-broadcast",
            "stream:online", "heat:update", "presence:count", "", "unknown-type-xyz",
            "batch", "server:shutdown", "ack:channels" }
        local msg = { type = types[math.random(#types)] }
        for _, k in ipairs({ "data", "messages", "channelId", "username", "emoteName", "emoteData",
            "channel", "id", "content", "videoId", "status", "color", "timestamp", "emotes", "displayName",
            "_ch", "_seq", "ver", "senderKeys", "reconnectSpreadMs", "signal", "channels" }) do
            if math.random() < 0.5 then msg[k] = garb() end
        end
        -- senderKeys is specifically an ARRAY of strings on the wire; fuzz that
        -- shape too (not just garb()'s generic tables) so a hostile-but-array-
        -- shaped frame gets exercised, not only scalar garbage in that slot.
        if math.random() < 0.3 then
            local keys = {}
            for i = 1, math.random(0, 60) do keys[i] = garb() end
            msg.senderKeys = keys
        end
        -- hsEmotes is a map word->ref (kick: on `data`, youtube: on each of
        -- `messages[]`) — fuzz that shape too, not just scalar garbage.
        if math.random() < 0.3 then
            msg.data = type(msg.data) == "table" and msg.data or {}
            local hs = {}
            for i = 1, math.random(0, 20) do hs["k" .. i] = garb() end
            msg.data.hsEmotes = hs
        end
        if math.random() < 0.3 then
            local msgs = {}
            for i = 1, math.random(0, 5) do
                local hs = {}
                for j = 1, math.random(0, 10) do hs["w" .. j] = garb() end
                msgs[i] = { text = "fuzz", hsEmotes = hs, user = "fuzzer" }
            end
            msg.messages = msgs
        end
        -- batch: a whole-frame wrapper, sometimes carrying more of the above
        -- shapes as its inner messages (nested batch is a garb() scalar/table,
        -- deliberately never a real batch — handle_text must not recurse into it)
        if math.random() < 0.2 then
            local inner = {}
            for i = 1, math.random(0, 10) do inner[i] = garb() end
            msg.messages = inner
        end
        -- ack:channels' own array-of-{channel,lastSeq} shape
        if math.random() < 0.2 then
            local chans = {}
            for i = 1, math.random(0, 10) do
                chans[i] = { channel = garb(), lastSeq = garb() }
            end
            msg.channels = chans
        end
        return msg
    end
    local rsock = sockets[#sockets]
    local names = {}
    for n in pairs(commands) do names[#names + 1] = n end
    local ws_escapes, cmd_escapes, first_crash = 0, 0, nil
    -- several seeds so robustness isn't a single-seed fluke
    for _, seed in ipairs({ 1, 7, 42, 1337 }) do
        math.randomseed(seed)
        -- malformed ws frames → ws.handle_text pcalls the whole dispatch chain
        for _ = 1, 250 do
            local ok = pcall(function() rsock.opts.on_text(register_payload(rand_ws())) end)
            if not ok then ws_escapes = ws_escapes + 1 end
        end
        -- every command with random string args (command input is always IRC text),
        -- answering any resulting fetch with garbage to fuzz the callback path too
        for _ = 1, 250 do
            local name = names[math.random(#names)]
            local words = { name }
            for j = 2, math.random(1, 6) do words[j] = tostring(garb()) end
            local ok, err = pcall(commands[name], { words = words, channel = chan })
            if not ok then cmd_escapes = cmd_escapes + 1; first_crash = first_crash or (name .. ": " .. tostring(err)) end
            if #http_queue > 0 then pcall(http_answer, "", garb()) end
        end
    end
    check(ws_escapes == 0, "fuzz: 1000 malformed ws frames (4 seeds) — nothing escaped the dispatch guards")
    check(cmd_escapes == 0, "fuzz: 1000 command calls with random args (4 seeds) — no uncaught error" ..
        (first_crash and (" (" .. first_crash .. ")") or ""))
    -- a fuzzed "server:shutdown" may have genuinely abandoned rsock (gen bump,
    -- same as the real client) and queued a reconnect up to 60s out — settle
    -- that before any later test assumes sockets[#sockets] is the live socket.
    advance(61000)
end

-- account-switch guard (LAST — mutates global inventory state): a slow refresh
-- for account A, still in flight when the user switches to B, must NOT apply A's
-- inventory under B's identity when it finally lands.
do
    local inv = require("inventory")
    inv.refresh("acctA")  -- profile fetch for A fires; refreshing=true
    inv.refresh("acctB")  -- switch mid-flight: M.login=B, this one queues
    -- A's profile lands, but M.login is now B → the guard abandons it, so A's
    -- emotes fetch never even fires and "ghostA" never enters the map
    http_answer("/api/profile/acctA", { profile = { id = 111 } })
    check(inv.resolve("ghostA") == nil, "account-switch: stale refresh for A does not apply under B")
end

-- ===== phase 7: right-click context menu =====
do
    local function new_fake_menu()
        local m = { actions = {}, submenus = {} }
        function m:add_action(text, cb) self.actions[text] = cb end
        function m:add_menu(title)
            local sub = new_fake_menu()
            self.submenus[title] = sub
            return sub
        end
        function m:add_separator() end
        return m
    end
    local function fire(msg, opts)
        opts = opts or {}
        local top = new_fake_menu()
        menu_cb({ message = msg, message_element = opts.message_element, channel = opts.channel, menu = top })
        return top
    end
    local function has_action_matching(actions, frag)
        for k in pairs(actions) do if k:find(frag, 1, true) then return true end end
        return false
    end

    -- plain twitch message → a "heatsync" submenu with the three lookups
    local top1 = fire(fake_msg("menuuser123", "9001", "hey"))
    local sub1 = top1.submenus["heatsync"]
    check(sub1 ~= nil, "menu: heatsync submenu added for a real chat message")
    check(type(sub1.actions["emotes"]) == "function" and type(sub1.actions["chat logs"]) == "function"
        and type(sub1.actions["whois"]) == "function", "menu: emotes/chat logs/whois actions present")
    check(not has_action_matching(sub1.actions, "block"), "menu: no block action without a heatsync emote element")

    -- "emotes" action runs the /hsinv fetch flow for that login
    sub1.actions["emotes"]()
    check(http_answer("/api/profile/menuuser123", { profile = { id = 7001 } }) ~= nil,
        "menu: emotes action fired the profile lookup")
    http_answer("/api/users/7001/emotes", { emotes = {} })

    -- "chat logs" action runs the /hslogs fetch flow
    sub1.actions["chat logs"]()
    check(http_answer("/api/chatter/twitch/menuuser123/stats", { totals = { messages = 1 } }) ~= nil,
        "menu: chat logs action fired the stats lookup")

    -- "whois" action runs the /hswhois fetch flow
    sub1.actions["whois"]()
    check(http_answer("/api/profile/menuuser123", { profile = { display_name = "MenuUser" } }) ~= nil,
        "menu: whois action fired the profile lookup")

    -- system message → no menu at all (no sender to act on)
    local sysm2 = fake_msg("menuuser123", "9001", "system-ish")
    sysm2.flags = c2.MessageFlag.System
    check(fire(sysm2).submenus["heatsync"] == nil, "menu: system messages get no heatsync submenu")

    -- multichat-injected line (empty channel_name, same signal render.lua
    -- uses) → no menu
    local injected = fake_msg("kickperson", "1", "hi from kick")
    injected.channel_name = ""
    check(fire(injected).submenus["heatsync"] == nil, "menu: empty channel_name (multichat-injected) gets no submenu")

    -- hostile logins (space, punctuation, over-length) → no submenu
    check(fire(fake_msg("bad name", "2", "x")).submenus["heatsync"] == nil, "menu: a login with a space is rejected")
    check(fire(fake_msg("weird$name", "3", "x")).submenus["heatsync"] == nil, "menu: a login with punctuation is rejected")
    check(fire(fake_msg(string.rep("a", 30), "4", "x")).submenus["heatsync"] == nil, "menu: an over-length login is rejected")

    -- a throwing message field (login_name) doesn't escape the handler
    local throwmsg = setmetatable({}, { __index = function(_, k)
        if k == "flags" then return 0 end
        if k == "channel_name" then return "somechannel" end
        if k == "login_name" then error("synthetic field-access failure") end
        return nil
    end })
    check(pcall(fire, throwmsg), "menu: a throwing message field doesn't escape the handler")

    -- clicked element is a heatsync emote we rendered → block/unblock toggle
    local hsElem = { tooltip = "menuTestEmote · heatsync" }
    local sub2 = fire(fake_msg("menuuser123", "9001", "look menuTestEmote"), { message_element = hsElem }).submenus["heatsync"]
    check(type(sub2.actions["block menuTestEmote"]) == "function", "menu: block action offered for a heatsync emote element")
    check(store.is_blocked("menuTestEmote") == false, "menu: precondition — not blocked yet")
    sub2.actions["block menuTestEmote"]()
    check(store.is_blocked("menuTestEmote") == true, "menu: block action actually blocks the emote")
    local sub3 = fire(fake_msg("menuuser123", "9001", "look menuTestEmote"), { message_element = hsElem }).submenus["heatsync"]
    check(type(sub3.actions["unblock menuTestEmote"]) == "function" and sub3.actions["block menuTestEmote"] == nil,
        "menu: already-blocked emote offers unblock instead of block")
    sub3.actions["unblock menuTestEmote"]()
    check(store.is_blocked("menuTestEmote") == false, "menu: unblock action actually unblocks the emote")

    -- a hostile emote-name tooltip (space in the derived name) never yields a
    -- block/unblock action
    local subH1 = fire(fake_msg("menuuser123", "9001", "x"), { message_element = { tooltip = "bad name · heatsync" } }).submenus["heatsync"]
    check(not has_action_matching(subH1.actions, "block"), "menu: a hostile emote-name tooltip yields no block action")

    -- a tooltip suffix that ISN'T " · heatsync" (kick/youtube emotes, or any
    -- other element) never yields a block/unblock action either
    local subH2 = fire(fake_msg("menuuser123", "9001", "x"), { message_element = { tooltip = "shroud · kick" } }).submenus["heatsync"]
    check(not has_action_matching(subH2.actions, "block"), "menu: a non-heatsync tooltip suffix yields no block action")
end

-- ws resync (LAST — senders.expire_all() marks EVERY cached sender stale, so
-- this must not run before any earlier test that assumes a sender it cached
-- stays "known"): a reconnect that follows a >60s rx gap resyncs, so a
-- previously-known sender reads unknown again until its next lazy refetch.
-- net.now() is huge by this point in the suite, so rewinding last_rx by 65s
-- stays positive — a negative value would misread as "never received
-- anything yet" and skip the resync (see ws.lua on_open).
do
    local rsock = sockets[#sockets]
    rsock.opts.on_open()
    rsock.opts.on_text(register_payload({
        type = "emote:broadcast", username = "resyncuser", emoteName = "beforeResync",
        emoteData = { url = "https://cdn.heatsync.org/e/r.webp", width = 32, height = 32 },
    }))
    check(senders.is_known_hs("resyncuser"), "senders: resyncuser known before the reconnect")
    ws.last_rx = net.now() - 65
    rsock.opts.on_open() -- simulates the reconnect's on_open firing
    check(not senders.is_known_hs("resyncuser"), "senders: reconnect after a >60s rx gap resyncs (marks senders stale)")
end

-- /hstest must post a message render actually processes: render skips any
-- message without a channel_name (the multichat-injected marker), so a
-- self-test missing it could never show its emote
do
    local tchan = fake_channel("hstestchan")
    local before = #tchan.added
    commands["/hstest"]({ words = { "/hstest" }, channel = tchan })
    local posted = nil
    for i = before + 1, #tchan.added do
        local m = tchan.added[i]
        if type(m) == "table" and m.init and m.init.login_name then posted = m.init end
    end
    check(posted ~= nil and posted.channel_name == "hstestchan", "/hstest: self-test message carries the tab's channel_name")
end

-- 7tv .avif urls (what heatsync ships now) must load as .webp — chatterino's
-- qt has no avif decoder, so an avif image lays out but draws blank
do
    local img = require("img")
    local set = img.for_hs_emote("https://cdn.7tv.app/emote/01F7736F6R0005BGS0Y3MAFMV6/1x.avif", 128)
    check(set ~= nil and set.i1.url == "https://cdn.7tv.app/emote/01F7736F6R0005BGS0Y3MAFMV6/1x.webp",
        "img: 7tv .avif loads as .webp")
    check(img.decodable("https://cdn.betterttv.net/emote/abc/1x.avif") == "https://cdn.betterttv.net/emote/abc/1x.avif",
        "img: non-7tv urls untouched by the avif swap")
    check(img.decodable("https://cdn.7tv.app.evil.com/emote/abc/1x.avif") == "https://cdn.7tv.app.evil.com/emote/abc/1x.avif",
        "img: avif swap is anchored to the real 7tv cdn")
end

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURES"))
host_os.exit(failures == 0 and 0 or 1)
