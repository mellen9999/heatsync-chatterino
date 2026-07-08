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
function c2.Message.new(init) return { init = init, is_plugin_msg = true } end

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
check(res.values[1] == "peepoHS", "completion: own emote matched")
local res2 = completion_cb({ query = ":omega" })
check(res2.values[1] == "OMEGALUL2", "completion: colon-stripped case-insensitive prefix")

-- 7tv search kicked off + cached on second keystroke
completion_cb({ query = "xar" })
http_answer("/api/emote-search?q=xar", { results = { ["7tv"] = { { name = "xar2EDM", url = "https://cdn.7tv.app/emote/01X/1x.webp" } } } })
local res3 = completion_cb({ query = "xar" })
local found7tv = false
for _, v in ipairs(res3.values) do if v == "xar2EDM" then found7tv = true end end
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

-- ws emote:added → debounced refresh fires new profile fetch
sockets[1].opts.on_text(register_payload({ type = "emote:added", name = "newEmote" }))
advance(6000)
local refetched = http_answer("/api/profile/mellen", { profile = { id = 42 } })
check(refetched ~= nil, "ws: inventory delta triggers re-fetch")
http_answer("/api/users/42/emotes", { emotes = {
    { custom_name = "peepoHS", url = "https://cdn.heatsync.org/e/1.webp", width = 112, height = 112, usage_count = 9 },
    { custom_name = "newEmote", url = "https://cdn.heatsync.org/e/3.webp", width = 64, height = 64, usage_count = 0 },
} })
check(inventory.resolve("newEmote") ~= nil, "ws: new emote in inventory after delta")

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
for _, v in ipairs(cres.values) do if v == "peepoHS" then sawblocked = true end end
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

-- youtube:status connected → learns videoId (for later unsubscribe)
sock.opts.on_text(register_payload({
    type = "youtube:status", channelId = "@somestreamer", videoId = "vid123", status = "connected", channelName = "x",
}))

commands["/hsmulti"]({ words = { "/hsmulti", "off" }, channel = chan })
ba = #chan.added -- after off's confirmation sysmsg (add_system_message also lands in .added)
sock.opts.on_text(register_payload({
    type = "kick-chat-message", data = { platform = "kick", channel = "xqc", id = "k9", username = "x", content = "after off" },
}))
check(#chan.added == ba, "multichat: no injection after /hsmulti off")

-- ===== v1.4 features: archive relay, whois, hot, find, auto-multichat =====
-- archive relay: opt-in; native twitch messages (real id) relayed, injected not
commands["/hsarchive"]({ words = { "/hsarchive", "on" }, channel = chan })
local function count_sent(needle)
    local n = 0
    for _, s in ipairs(sock.sent) do if s:find(needle, 1, true) then n = n + 1 end end
    return n
end
local rb = count_sent("twitch:chat:relay")
local am = fake_msg("archuser", "111", "archive me")
chan.msgs[#chan.msgs + 1] = am
chan.appended_cb(am, nil)
check(count_sent("twitch:chat:relay") == rb + 1, "archive: native twitch message relayed when on")

commands["/hsmulti"]({ words = { "/hsmulti", "kick:zzz" }, channel = chan })
local rb2 = count_sent("twitch:chat:relay")
sock.opts.on_text(register_payload({
    type = "kick-chat-message", data = { platform = "kick", channel = "zzz", id = "ki", username = "k", content = "kick msg" },
}))
check(count_sent("twitch:chat:relay") == rb2, "archive: injected kick message NOT relayed")
commands["/hsarchive"]({ words = { "/hsarchive", "off" }, channel = chan })

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
        if v == "FrierenPog" then found = true end
        if v == "NotAMatch" then leaked = true end
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
    { tooltip = "Chatterino Donator", image1 = "https://x/badge.png", users = { "7007", "1001" } },
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

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURES"))
host_os.exit(failures == 0 and 0 or 1)
