-- degradation harness: strip nightly (t1) or all modern (t0) apis before
-- loading the plugin; it must boot clean and keep tab-complete working.
local host_os = os
local MODE = host_os.getenv("TIER") or "t1"
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
local PLUGIN = host_os.getenv("PLUGIN_DIR") or (here .. "/..")
package.path = PLUGIN .. "/?.lua;" .. package.path

local failures = 0
local function check(cond, label)
    if cond then print("PASS " .. label) else failures = failures + 1 print("FAIL " .. label) end
end

local parse_registry = {}
local function register_payload(t)
    local key = "@@" .. tostring(#parse_registry + 1)
    parse_registry[key] = t
    return key
end
package.preload["chatterino.json"] = function()
    return {
        parse = function(s) return parse_registry[s] or error("unregistered") end,
        stringify = function(t) return "{}" end,
    }
end

local http_queue = {}
c2 = {}
c2.LogLevel = { Debug = 1, Info = 2, Warning = 3, Critical = 4 }
c2.EventType = { CompletionRequested = "completion" }
function c2.log() end
c2.HTTPMethod = { Get = "GET" }
local HTTPRequest = {}
HTTPRequest.__index = HTTPRequest
c2.HTTPRequest = {}
function c2.HTTPRequest.create(_, url)
    return setmetatable({ url = url }, HTTPRequest)
end
function HTTPRequest:set_timeout() end
function HTTPRequest:set_header() end
-- no set_payload on the stripped api: a POST must degrade through its callback, not throw
function HTTPRequest:on_success(cb) self.success = cb end
function HTTPRequest:on_error(cb) self.err = cb end
function HTTPRequest:finally(cb) self.fin = cb end
function HTTPRequest:execute() http_queue[#http_queue + 1] = self end
local function http_answer(pattern, payload)
    for i, r in ipairs(http_queue) do
        if r.url:find(pattern, 1, true) then
            table.remove(http_queue, i)
            local key = register_payload(payload)
            r.success({ data = function() return key end, status = function() return 200 end })
            if r.fin then r.fin() end
            return true
        end
    end
    return false
end

local commands = {}
local completion_cb
function c2.register_command(n, f) commands[n] = f return true end
function c2.register_callback(_, f) completion_cb = f end

local Account = {}
Account.__index = Account
function Account:is_valid() return true end
function Account:is_anon() return false end
function Account:login() return "mellen" end
function c2.current_account() return setmetatable({}, Account) end

c2.LinkType = { Url = "url" }
c2.Message = { new = function(init) return { init = init } end }
c2.MessageFlag = { System = 1 }
c2.MessageElementFlag = { EmoteImage = 2 }
c2.FontStyle = { ChatMedium = 1 }
c2.ChannelType = { Twitch = 8 }

if MODE == "t1" then
    -- stable 2.5.5: timers + websocket, no images/windows/msg-hooks
    local timers = {}
    function c2.later(fn, ms) timers[#timers + 1] = fn end
    c2.WebSocket = {
        new = function(url, opts)
            local s = { sent = {} }
            function s:send_text(d) s.sent[#s.sent + 1] = d end
            function s:close() end
            return s
        end,
    }
    -- c2.Image, c2.ImageSet, c2.windows absent
elseif MODE == "t0" then
    -- pre-2.5.5: none of it (also no Message.new link elements — keep
    -- Message.new stub since commands fall back to sysmsg on pcall failure
    -- anyway; the true-old-build case is covered by pcall guards)
end

os = nil  -- emulate chatterino sandbox (no os library)
dofile(PLUGIN .. "/init.lua")
local caps = require("caps")
local inventory = require("inventory")

if MODE == "t1" then
    check(caps.tier == 1, "t1: tier detected as 1 (got " .. caps.tier .. ")")
else
    check(caps.tier == 0, "t0: tier detected as 0 (got " .. caps.tier .. ")")
end
-- no c2.windows at all on this stripped api → caps.menus stays false and
-- menu.register() (called unconditionally from init.lua) is a no-op; reaching
-- this line at all means boot survived it without erroring.
check(caps.menus == false, "menus: absent api → caps.menus false on " .. MODE)

check(http_answer("/api/profile/mellen", { profile = { id = 42 } }), "boot: profile fetch fired")
http_answer("/api/users/42/emotes", { emotes = {
    { custom_name = "peepoHS", url = "https://x/1.webp", width = 112, height = 112, usage_count = 5 },
} })
check(inventory.count() == 1, "inventory loaded")

local res = completion_cb({ query = "peepo" })
check(res.values[1] == "peepoHS ", "completion works (trailing space)")

local added = {}
local ctx = { words = { "/hsstatus" }, channel = {
    add_system_message = function(_, m) added[#added + 1] = m end,
    add_message = function(_, m) added[#added + 1] = m end,
    get_name = function() return "chan" end,
    last_message = function() return nil end,
} }
commands["/hsstatus"](ctx)
check(#added >= 3, "/hsstatus alive")

-- /hshelp works on every tier (pure sysmsg command index)
local hb = #added
commands["/hshelp"](ctx)
check(#added > hb, "/hshelp alive on " .. MODE)

-- /hschat is a net+sysmsg command → works on every tier; usage path fires no request
hb = #added
commands["/hschat"]({ words = { "/hschat", "a" }, channel = ctx.channel })
check(#added > hb, "/hschat alive on " .. MODE)

-- exercise the network + picker commands under the STRIPPED API. on t1/t0 there
-- is no c2.Image/windows and a narrower c2.LinkType — a nightly-only field
-- access anywhere in these handlers would throw here (invoking a command that
-- throws crashes this script), catching it off the real client. drives exactly
-- the archive/discovery commands the coverage audit found were never run degraded.
hb = #added
commands["/hshot"]({ words = { "/hshot" }, channel = ctx.channel })
http_answer("/api/live/top", { streams = { { platform = "twitch", username = "s1", displayName = "S1", viewerCount = 10, heat = 5 } } })
commands["/hswhois"]({ words = { "/hswhois", "someone" }, channel = ctx.channel })
http_answer("/api/profile/someone", { profile = { display_name = "Someone", stats = { user_heat = 1 } } })
commands["/hssearch"]({ words = { "/hssearch", "hello" }, channel = ctx.channel })
http_answer("/api/search", { results = { { base36_id = "00001o", display_name = "x", content = "hi", heat = 1 } } })
commands["/hschat"]({ words = { "/hschat", "hello", "@grace" }, channel = ctx.channel })
http_answer("/api/archive/search", { results = { { message_id = "u1", platform = "twitch", channel = "c", username = "grace", display_name = "Grace", message = "hello", timestamp = "2026-07-02T00:00:00.000Z" } } })
commands["/hsfind"]({ words = { "/hsfind", "kappa" }, channel = ctx.channel })
http_answer("/api/emote-search?q=kappa", { results = { ["7tv"] = { { name = "Kappa", url = "https://cdn.7tv.app/emote/0K/1x.webp" } } } })
commands["/hsinv"]({ words = { "/hsinv", "grace" }, channel = ctx.channel })
http_answer("/api/profile/grace", { profile = { id = 555, display_name = "Grace" } })
http_answer("/api/users/555/emotes", { emotes = { { custom_name = "e1", url = "https://cdn.7tv.app/emote/0E/1x.webp", width = 32, height = 32 } } })
commands["/hsmoments"]({ words = { "/hsmoments", "24h" }, channel = ctx.channel })
http_answer("/api/moments", { moments = { { id = "m1", platform = "twitch", channel = "c", rate = 10, baseline = "1" } } })
commands["/hsmulti"]({ words = { "/hsmulti", "kick:x" }, channel = ctx.channel })
commands["/hslive"]({ words = { "/hslive", "on" }, channel = ctx.channel })
commands["/hslive"]({ words = { "/hslive", "off" }, channel = ctx.channel })
-- v1.11 additions must degrade too: the card's POST has no set_payload/Post on
-- this api (falls back to the public GETs through its callback, never throws),
-- the toggles are plain sysmsg, and a freshly linked kick source's history
-- request goes through get_json like any other
commands["/hscard"]({ words = { "/hscard", "grace" }, channel = ctx.channel })
http_answer("/api/profile/grace?platform=twitch", { profile = { id = 555, display_name = "Grace", stats = { user_heat = 3 } } })
http_answer("/api/twitch/followage", { followedAt = "2024-01-01T00:00:00Z" })
local carded = false
for _, m in ipairs(added) do
    if type(m) == "table" and m.init then
        for _, e in ipairs(m.init.elements) do if e.text == "Grace" then carded = true end end
    end
end
check(carded, "card: POST unavailable on " .. MODE .. " → public-endpoint fallback still renders the card")
commands["/hscard"]({ words = { "/hscard" }, channel = ctx.channel })
for _, c in ipairs({ "/hsheat", "/hsflair", "/hscolors", "/hsbackfill", "/hsmentions", "/hsmutes" }) do
    commands[c]({ words = { c, "off" }, channel = ctx.channel })
    commands[c]({ words = { c, "on" }, channel = ctx.channel })
    commands[c]({ words = { c }, channel = ctx.channel })
end
commands["/hsmulti"]({ words = { "/hsmulti", "kick:histsrc" }, channel = ctx.channel })
http_answer("/api/recent/kick/histsrc", { messages = { { id = "h1", ts = "2026-10-30T20:00:01.000Z", sender = "a", text = "hello" } } })
commands["/hsmulti"]({ words = { "/hsmulti", "off" }, channel = ctx.channel })
commands["/hsemotes"]({ words = { "/hsemotes" }, channel = ctx.channel })
commands["/hsblocklist"]({ words = { "/hsblocklist" }, channel = ctx.channel })
check(#added > hb, "network + picker commands survive the stripped API on " .. MODE)

-- inline images need the images capability: without it the toggle still works
-- but the feature is silently off (nothing detected into a fetch, no request)
do
    local images = require("images")
    local qn = #http_queue
    commands["/hsimages"]({ words = { "/hsimages", "on" }, channel = ctx.channel })
    commands["/hsimages"]({ words = { "/hsimages" }, channel = ctx.channel })
    check(not images.enabled(), "images: feature silently off without the images cap on " .. MODE)
    check(images.element_for("https://i.example.com/a.png") == nil and #http_queue == qn, "images: no element, no request on " .. MODE)
    check(images.detect("https://i.example.com/a.png") ~= nil, "images: pure detection still safe on " .. MODE)
    commands["/hsimages"]({ words = { "/hsimages", "off" }, channel = ctx.channel })
end

-- mention highlights need the Highlighted message flag: absent here, the toggle
-- still works but the feature is silently off and a merged line is built as before
do
    local mention = require("mention")
    local senders = require("senders")
    senders.own_login = "mellen"
    check(caps.highlight == false, "mentions: no Highlighted flag → caps.highlight false on " .. MODE)
    check(mention.fields("hey mellen", "kk") == nil, "mentions: silently off without the flag on " .. MODE)
    check(mention.matches("hey mellen", "mellen"), "mentions: pure matching still safe on " .. MODE)
end

-- twitch game/title lines ride the same live toggle; with no c2.Channel / render
-- on this api there is no tab to put them in, and that must stay silent
do
    local live = require("live")
    commands["/hslive"]({ words = { "/hslive", "on" }, channel = ctx.channel })
    local ok, handled = pcall(live.handle, { type = "stream:update", platform = "twitch", channel = "x", game = "a", title = "b", prevGame = "c", prevTitle = "d" })
    check(ok and handled == true, "live: twitch stream:update is a clean no-op without tabs on " .. MODE)
    commands["/hslive"]({ words = { "/hslive", "off" }, channel = ctx.channel })
end

-- /hsgif without image support: still searches and shows clickable captions
-- (the tiles fall back to text), nothing throws on the stripped api
do
    local before = #added
    commands["/hsgif"]({ words = { "/hsgif", "cat" }, channel = ctx.channel })
    http_answer("/api/gifs/search", { gifs = { { url = "https://media.giphy.com/media/a/giphy.gif", preview = "https://media.giphy.com/media/a/200_s.gif", label = "Cat" } }, library = { state = "ready" } })
    local m = added[#added]
    local cap = false
    if type(m) == "table" and m.init then
        for _, e in ipairs(m.init.elements) do if e.text == "[Cat]" and e.link then cap = true end end
    end
    check(#added > before and cap, "gifs: /hsgif degrades to clickable captions on " .. MODE)
end

-- community mutes replace lines, which needs the t2 render path: below it the
-- toggle is accepted but the feature is silently off and asks the server nothing
do
    local mutes = require("mutes")
    local qn = #http_queue
    commands["/hsmutes"]({ words = { "/hsmutes", "on" }, channel = ctx.channel })
    check(not mutes.enabled(), "mutes: silently off without the render path on " .. MODE)
    check(mutes.is_muted("somechan", "someone", "twitch") == false and #http_queue == qn, "mutes: no answer, no request on " .. MODE)
    check(mutes.parse({ { username = "a" } }) ~= false, "mutes: pure parsing still safe on " .. MODE)
    commands["/hsmutes"]({ words = { "/hsmutes", "off" }, channel = ctx.channel })
end

print(failures == 0 and "ALL PASS (" .. MODE .. ")" or (failures .. " FAILURES (" .. MODE .. ")"))
host_os.exit(failures == 0 and 0 or 1)
