-- the opt-in account commands: /hslogin /hslogout /hsnote /hsmute /hsunmute
-- /hsmutelist /hsfollow /hsunfollow, plus the helpers other commands call (emote
-- block sync, the card's note + following lines, pinning). every one is a thin
-- layer over account.request — the token never appears here. not logged in:
-- every command says "log in first: /hslogin" and does nothing else.
local net = require("net")
local caps = require("caps")
local account = require("account")
local pairing = require("pairing")
local sync = require("account_sync")
local inventory = require("inventory")
local senders = require("senders")
local store = require("store")
local u = require("cmdutil")

local M = {}

local NOTE_MAX = 2000 -- the extension's own cap
local USER_TTL_S = 600
local USER_CACHE_MAX = 100

local function need(ctx)
    return account.require_scope(ctx, "account")
end

-- ----- login / logout -----
local function logout(ctx)
    pairing.cancel()
    if not account.logged_in() then
        return u.sysmsg(ctx, "you're not logged in · /hslogin to log in")
    end
    account.logout(function(_, reached)
        u.sysmsg(ctx, reached and "logged out: the login was revoked on heatsync and wiped here"
            or "logged out here, but couldn't reach heatsync to revoke it: do that at heatsync.org/cli")
    end)
end

-- ----- user → heatsync id (public profile lookup) -----
local users = {}   -- login -> { id, ts }
local users_n = 0

local function resolve_user(ctx, login, cb)
    local hit = users[login]
    if hit and (net.now() - hit.ts) < USER_TTL_S then return cb(hit.id) end
    net.get_json(net.ORIGIN .. "/api/profile/" .. net.percent_encode(login) .. "?platform=twitch", 8000,
        function(payload, err, status)
            local p = type(payload) == "table" and payload.profile or nil
            local id = type(p) == "table" and tonumber(p.id) or nil
            if not id or id ~= id or id <= 0 or math.floor(id) ~= id or p.is_shadow == true
                or p.is_shadow_profile == true then
                if p == nil and status ~= 404 and err then
                    u.sysmsg(ctx, "couldn't reach heatsync: try again")
                else
                    u.sysmsg(ctx, "heatsync doesn't know '" .. login .. "' yet")
                end
                return
            end
            id = math.floor(id)
            if users_n >= USER_CACHE_MAX then users, users_n = {}, 0 end
            if users[login] == nil then users_n = users_n + 1 end
            users[login] = { id = id, ts = net.now() }
            cb(id)
        end)
end

local function valid_user(ctx, user, usage)
    if not u.is_valid_name(user) then
        u.sysmsg(ctx, usage)
        return nil
    end
    return string.lower(user)
end

-- ----- notes -----
local function show_note(ctx, login, id)
    account.request("Get", "/user-notes/" .. id, nil, function(data, err, status, ebody)
        if type(data) ~= "table" then
            return u.sysmsg(ctx, account.explain(status, ebody, err, { [404] = "heatsync doesn't know '" .. login .. "' yet" }))
        end
        local note = net.safe_text(data.note, NOTE_MAX)
        if note and note ~= "" then
            u.sysmsg(ctx, "note on " .. login .. ": " .. note)
        else
            u.sysmsg(ctx, "no note on " .. login .. " yet · /hsnote " .. login .. " <text> to add one")
        end
    end)
end

local function put_note(ctx, login, id, text)
    account.request("Put", "/user-notes/" .. id, { note = text }, function(data, err, status, ebody)
        if type(data) ~= "table" then
            return u.sysmsg(ctx, account.explain(status, ebody, err, {
                [400] = "notes are for other people, not yourself",
                [404] = "heatsync doesn't know '" .. login .. "' yet",
            }))
        end
        net.note_wall(net.iso_to_ms(data.updated_at))
        u.sysmsg(ctx, text == "" and ("note on " .. login .. " cleared") or ("note on " .. login .. " saved"))
    end)
end

local function note_command(ctx)
    local user = ctx.words[2]
    local login = valid_user(ctx, user, "usage: /hsnote <user> [text] · no text shows the note · /hsnote <user> - clears it")
    if not login then return end
    if not need(ctx) then return end
    local parts = {}
    for i = 3, #ctx.words do parts[#parts + 1] = ctx.words[i] end
    local text = table.concat(parts, " ")
    if #text > NOTE_MAX then
        return u.sysmsg(ctx, "that note is too long (max " .. NOTE_MAX .. " characters)")
    end
    if login == senders.own_login or account.name() and string.lower(account.name()) == login then
        return u.sysmsg(ctx, "notes are for other people, not yourself")
    end
    resolve_user(ctx, login, function(id)
        if text == "" then return show_note(ctx, login, id) end
        put_note(ctx, login, id, text == "-" and "" or text)
    end)
end

-- the card's extra lines when logged in: the note + whether you follow them.
-- `id` is the card's heatsync user id (nil / shadow profile → nothing to ask).
function M.card_extras(channel, login, id, shadow)
    if not account.logged_in() or not account.has_scope("account") or shadow or not id then return end
    if id == account.user_id() then return end
    local ctx = { channel = channel }
    account.request("Get", "/user-notes/" .. string.format("%d", id), nil, function(data)
        local note = type(data) == "table" and net.safe_text(data.note, NOTE_MAX) or nil
        if note and note ~= "" then u.sysmsg(ctx, "note: " .. u.preview(note, 200)) end
    end)
    sync.get_following(function(ids)
        if not ids then return end
        u.sysmsg(ctx, ids[string.format("%d", id)] and ("following " .. login)
            or ("not following " .. login .. " · /hsfollow " .. login))
    end)
end

-- ----- mutes -----
local PLAT = { twitch = "twitch", tw = "twitch", kick = "kick", youtube = "youtube", yt = "youtube", all = false }

local function parse_mute_args(ctx, usage)
    local name = ctx.words[2]
    if type(name) ~= "string" or name == "" or #name > 50 or not string.match(name, "^[%w_%-%.]+$") then
        u.sysmsg(ctx, usage)
        return nil
    end
    local plat = nil
    local p = ctx.words[3]
    if p ~= nil and p ~= "" then
        plat = PLAT[string.lower(p)]
        if plat == nil then
            u.sysmsg(ctx, usage)
            return nil
        end
    end
    return string.lower(name), plat or nil
end

local function mute_command(ctx)
    local usage = "usage: /hsmute <user> [twitch|kick|yt] · no platform mutes them everywhere"
    local name, plat = parse_mute_args(ctx, usage)
    if not name or not need(ctx) then return end
    if name == senders.own_login then return u.sysmsg(ctx, "you can't mute yourself") end
    account.request("Post", "/mutes", { username = name, platform = plat }, function(data, err, status, ebody)
        if type(data) ~= "table" then return u.sysmsg(ctx, account.explain(status, ebody, err)) end
        u.sysmsg(ctx, "muted " .. name .. (plat and (" on " .. plat) or " everywhere") ..
            " · their lines collapse · /hsunmute " .. name .. " to undo")
        sync.mute_changed()
    end)
end

local function unmute_command(ctx)
    local usage = "usage: /hsunmute <user> [twitch|kick|yt]"
    local name, plat = parse_mute_args(ctx, usage)
    if not name or not need(ctx) then return end
    local path = "/mutes/" .. net.percent_encode(name) .. (plat and ("?platform=" .. plat) or "")
    account.request("Delete", path, nil, function(data, err, status, ebody)
        if type(data) ~= "table" then
            return u.sysmsg(ctx, account.explain(status, ebody, err, { [404] = name .. " wasn't muted" }))
        end
        u.sysmsg(ctx, "unmuted " .. name .. " · new lines show normally (collapsed ones stay collapsed)")
        sync.mute_changed()
    end)
end

local function mutelist_command(ctx)
    if not need(ctx) then return end
    account.request("Get", "/mutes", nil, function(data, err, status, ebody)
        local list = type(data) == "table" and data.mutes or nil
        if type(list) ~= "table" then return u.sysmsg(ctx, account.explain(status, ebody, err)) end
        local names = {}
        for i = 1, math.min(#list, 30) do
            local e = list[i]
            if type(e) == "table" and type(e.username) == "string" then
                local nm = net.safe_text(e.username, 40)
                if nm then
                    names[#names + 1] = nm .. ((type(e.platform) == "string" and PLAT[e.platform]) and ("@" .. e.platform) or "")
                end
            end
        end
        if #names == 0 then return u.sysmsg(ctx, "nobody muted · /hsmute <user>") end
        u.sysmsg(ctx, tostring(#list) .. " muted: " .. table.concat(names, " ") ..
            (#list > #names and (" … +" .. tostring(#list - #names)) or ""))
    end)
end

-- ----- follow -----
local function follow_command(ctx, verb)
    local usage = "usage: /hs" .. (verb == "Post" and "follow" or "unfollow") .. " <user>"
    local login = valid_user(ctx, ctx.words[2], usage)
    if not login or not need(ctx) then return end
    resolve_user(ctx, login, function(id)
        local sid = string.format("%d", id)
        local path = "/follow/" .. sid
        account.request(verb, path, verb == "Post" and {} or nil, function(data, err, status, ebody)
            if type(data) ~= "table" then
                return u.sysmsg(ctx, account.explain(status, ebody, err, {
                    [409] = verb == "Post" and ("already following " .. login) or ("not following " .. login),
                    [400] = "you can't follow yourself",
                    [404] = verb == "Post" and ("heatsync doesn't know '" .. login .. "' yet")
                        or (login .. " isn't someone you follow"),
                }))
            end
            sync.set_following(id, verb == "Post")
            u.sysmsg(ctx, verb == "Post" and ("following " .. login .. " on heatsync") or ("unfollowed " .. login))
        end)
    end)
end

-- ----- emote block sync (called by /hsblock, /hsunblock, the right-click menu) -----
local function hash_for(name, login)
    local row = inventory.map and inventory.map[name]
    if row and row.hash then return row.hash end
    return senders.find_hash(name, login)
end

local function acct_ready()
    return account.logged_in() and account.has_scope("account") and caps.account
end

-- a local block just happened: also block it on the account when we can say which
-- emote it is. says what happened either way (only when logged in).
function M.sync_block(channel, name, login)
    if not acct_ready() then return end
    local ctx = { channel = channel }
    local hash = hash_for(name, login)
    if not hash then
        return u.sysmsg(ctx, "kept '" .. name .. "' local-only: heatsync hasn't told me which emote that is yet")
    end
    account.request("Post", "/emote-blocks", { emote_hash = hash }, function(data, err, status, ebody)
        if type(data) ~= "table" and status ~= 409 then
            return u.sysmsg(ctx, "'" .. name .. "' is blocked locally only: " .. account.explain(status, ebody, err))
        end
        store.add_hash_block(hash)
        u.sysmsg(ctx, "'" .. name .. "' is blocked on your account too")
    end)
end

-- returns true when the account path will do the talking (it holds a block on
-- that emote), so the caller doesn't also say "wasn't blocked".
function M.sync_unblock(channel, name, was_local, login)
    if not acct_ready() then return false end
    local hash = hash_for(name, login)
    if not hash or not store.is_hash_blocked(hash) then return false end
    local ctx = { channel = channel }
    account.request("Delete", "/emote-blocks/" .. net.percent_encode(hash), nil, function(data, err, status, ebody)
        if type(data) ~= "table" and status ~= 404 then
            return u.sysmsg(ctx, "'" .. name .. "' is still blocked on your account: " .. account.explain(status, ebody, err))
        end
        store.remove_hash_block(hash)
        u.sysmsg(ctx, was_local and ("'" .. name .. "' is unblocked on your account too")
            or ("unblocked '" .. name .. "' on your account"))
    end)
    return not was_local
end

-- ----- pin -----
local PIN_ERR = {
    [403] = "you're not a moderator here",
    [409] = "too new: try again in a few seconds",
    [404] = "heatsync can't find that channel or message",
    [503] = "pinning isn't available right now: try again soon",
}

local function chan_ok(c) return type(c) == "string" and #c >= 1 and #c <= 60 and string.match(c, "^[%w_%-]+$") ~= nil end
local function id_ok(i) return type(i) == "string" and #i >= 1 and #i <= 80 and string.match(i, "^[%w_%-]+$") ~= nil end

function M.can_pin() return acct_ready() end

function M.pin_message(channel, platform, chan, message_id)
    local ctx = { channel = channel }
    if not need(ctx) then return end
    chan = type(chan) == "string" and string.lower(chan) or nil
    if (platform ~= "twitch" and platform ~= "kick") or not chan_ok(chan) or not id_ok(message_id) then
        return u.sysmsg(ctx, "can't pin that message")
    end
    account.request("Post", "/pin", { platform = platform, channel = chan, message_id = message_id },
        function(data, err, status, ebody)
            if type(data) ~= "table" then return u.sysmsg(ctx, account.explain(status, ebody, err, PIN_ERR)) end
            u.sysmsg(ctx, "pinned that message in #" .. chan)
        end)
end

-- /hspin clear [kick:<slug>]  (this tab's twitch pin by default)
function M.pin_clear(ctx)
    if not need(ctx) then return end
    local platform, chan = "twitch", nil
    local arg = ctx.words[3]
    if type(arg) == "string" and arg ~= "" then
        local k = string.match(string.lower(arg), "^kick:([%w_%-]+)$")
        if not k then return u.sysmsg(ctx, "usage: /hspin clear · /hspin clear kick:<slug>") end
        platform, chan = "kick", k
    else
        pcall(function() chan = string.lower(ctx.channel:get_name()) end)
    end
    if not chan_ok(chan) then return u.sysmsg(ctx, "open a twitch channel first, or /hspin clear kick:<slug>") end
    account.request("Delete", "/pin?platform=" .. platform .. "&channel=" .. net.percent_encode(chan), nil,
        function(data, err, status, ebody)
            if type(data) ~= "table" then return u.sysmsg(ctx, account.explain(status, ebody, err, PIN_ERR)) end
            u.sysmsg(ctx, "pin cleared in #" .. chan)
        end)
end

-- ----- register -----
function M.register()
    c2.register_command("/hslogin", function(ctx)
        local n = account.take_notice()
        if n then u.sysmsg(ctx, n) end
        pairing.start(ctx)
    end)
    c2.register_command("/hslogout", logout)
    c2.register_command("/hsnote", note_command)
    c2.register_command("/hsmute", mute_command)
    c2.register_command("/hsunmute", unmute_command)
    c2.register_command("/hsmutelist", mutelist_command)
    c2.register_command("/hsfollow", function(ctx) follow_command(ctx, "Post") end)
    c2.register_command("/hsunfollow", function(ctx) follow_command(ctx, "Delete") end)
end

return M
