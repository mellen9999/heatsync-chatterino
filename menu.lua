-- right-click context menu (chatterino PR #6961, gated by caps.menus — a
-- feature-detected addition, not a fork; see CLAUDE.md). every action body
-- already lives in cmd_emotes.lua / cmd_archive.lua as a (channel, arg)
-- function shared with the matching /hs* command — this module is only the
-- menu wiring plus the two checks unique to a right-click: whose message is
-- this, and what element did they click.
local net = require("net")
local caps = require("caps")
local store = require("store")
local cmd_emotes = require("cmd_emotes")
local cmd_archive = require("cmd_archive")

local M = {}

-- twitch login charset, checked AFTER lowering. a message's login_name is
-- server-controlled data from chatterino's perspective — it becomes an
-- /hsinv, /hslogs, /hswhois or /hsblock argument (a URL segment or a stored
-- name), so it gets the exact same charset gate any other untrusted string
-- destined for those paths would.
local function valid_login(s)
    if type(s) ~= "string" or s == "" or #s > 25 then return nil end
    local lower = string.lower(s)
    if not string.match(lower, "^[a-z0-9_]+$") then return nil end
    return lower
end

-- a heatsync emote the plugin itself rendered is a scaling-image whose link
-- inserts "<name> " (render.lua + multichat.lua build exactly that; native
-- chatterino emotes are "emote" elements, never scaling-image). the tooltip
-- we set is dropped by the real client (reads back ""), so the link is the
-- reliable marker; the tooltip suffix stays as a fallback. el is userdata on
-- the real client, so every field read is pcall'd. the derived name is
-- re-validated with is_safe_name — it's still just a string off an element.
local SUFFIX = " · heatsync"
local function read_el(el)
    return el.type, el.link, el.tooltip
end
local function hs_emote_name(el)
    if el == nil then return nil end
    local ok, ty, link, tt = pcall(read_el, el)
    if not ok or ty ~= "scaling-image" then return nil end
    local name = nil
    local okl, is_insert = pcall(function()
        return type(link) == "table" and link.type == c2.LinkType.InsertText
    end)
    if okl and is_insert and type(link.value) == "string" then
        name = string.match(link.value, "^(%S+) $")
    end
    if not name and type(tt) == "string" and #tt > #SUFFIX and string.sub(tt, -#SUFFIX) == SUFFIX then
        name = string.sub(tt, 1, #tt - #SUFFIX)
    end
    if not name or not net.is_safe_name(name) then return nil end
    return name
end

-- the channel a menu action should post/act into: chatterino's own channel
-- (which may be virtual — a search popup or usercard) if it's still valid,
-- else the message's own channel resolved by name. neither usable → nil, and
-- the caller no-ops rather than guessing a target.
local function resolve_channel(args)
    local ok, valid = pcall(function() return args.channel ~= nil and args.channel:is_valid() end)
    if ok and valid then return args.channel end
    local ok2, name = pcall(function() return args.message.channel_name end)
    if ok2 and type(name) == "string" and name ~= "" then
        local ok3, ch = pcall(function() return c2.Channel.by_name(name) end)
        if ok3 and ch then return ch end
    end
    return nil
end

-- the whole handler runs under ONE pcall from M.register — a bad/absent field
-- anywhere here (a virtual channel with a stub message, a future chatterino
-- shape change) degrades to "no menu added", never a thrown error into
-- chatterino's native context-menu dispatch.
local function on_context_menu(args)
    -- args/message/menu are sol userdata on the real client: nil-check only,
    -- every field read below is pcall'd (the outer pcall is the backstop)
    if args == nil then return end
    local msg = args.message
    if msg == nil then return end

    -- system messages have no sender to act on. multichat-injected kick/
    -- youtube lines carry an empty channel_name (they're built with
    -- c2.Message.new and never set it — see render.lua's identical check) and
    -- are skipped the same way: those senders aren't twitch logins anyway.
    local ok_sys, is_sys = pcall(function() return (msg.flags & c2.MessageFlag.System) ~= 0 end)
    if ok_sys and is_sys then return end
    local ok_cn, cn = pcall(function() return msg.channel_name end)
    if not ok_cn or type(cn) ~= "string" or cn == "" then return end

    local ok_login, raw_login = pcall(function() return msg.login_name end)
    if not ok_login then return end
    local login = valid_login(raw_login)
    if not login then return end

    local channel = resolve_channel(args)
    if not channel then return end

    local menu = args.menu
    if menu == nil then return end
    local sub = menu:add_menu("heatsync")
    if sub == nil then return end

    sub:add_action("emotes", function() cmd_emotes.inv(channel, login, 1) end)
    sub:add_action("chat logs", function() cmd_archive.logs(channel, login, nil) end)
    sub:add_action("whois", function() cmd_archive.whois(channel, login) end)

    -- only when the click landed on a heatsync emote the plugin itself drew.
    local name = hs_emote_name(args.message_element)
    if name then
        sub:add_separator()
        if store.is_blocked(name) then
            sub:add_action("unblock " .. name, function() cmd_emotes.unblock(channel, name) end)
        else
            sub:add_action("block " .. name, function() cmd_emotes.block(channel, name) end)
        end
    end
end

-- registers once, only when the api is present (t2 nightlies with #6961;
-- absent everywhere else — t0/t1 builds and older/odd nightlies just never
-- get a menu, no error). called from init.lua after commands.register.
function M.register()
    if not caps.menus then return end
    pcall(function()
        c2.windows:on_channelview_context_menu_requested(function(args)
            pcall(on_context_menu, args)
        end)
    end)
end

return M
