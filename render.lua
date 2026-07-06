-- inline rendering (t2 / nightly only): heatsync emotes as real images and
-- >>id threadlinks as clickable links, via hook → rebuild → replace.
--
-- messages freeze once visible, so nothing is mutated: on_message_appended
-- (synchronous, fires before paint) prescans the raw text, and only when a
-- message actually contains a heatsync emote or threadlink is it rebuilt —
-- untouched elements (twitch emotes, badges, timestamps, reply curves) are
-- passed through as objects, which chatterino clones. the miss path is two
-- hash lookups per word and allocates nothing.
local net = require("net")
local caps = require("caps")
local inventory = require("inventory")
local senders = require("senders")
local store = require("store")

local FLAME = "🔥"

local M = {
    started = false,
    on_channel_found = nil, -- fn(platform, channel) → ws join
    on_channel_gone = nil,  -- fn(platform, channel) → ws leave (tab closed)
    boot_fn = nil,          -- fn() → one-time presence line for first channel
    boot_done = false,
    replaced_count = 0,
}

local hooked = {}   -- channel_name -> { handle, ch }
local processing = false
local fail_count = 0

local imageset_for = require("img").for_url

local function thread_id(word)
    -- byte check first: keeps the per-word miss path to hash lookups only
    if string.byte(word, 1) ~= 62 then return nil end -- '>'
    return string.match(word, "^>>([a-z0-9]+)$")
end

-- an emote entry only counts as a hit if it can actually render — unknown
-- source dims mean no scale factor, and a raw-size image is worse than text
local function renderable(emote)
    return emote ~= nil and type(emote.h) == "number" and emote.h > 0
end

-- prescan: any word this sender's inventory renders (and isn't blocked), or a
-- threadlink?
local function has_hits(text, sender_map)
    for word in string.gmatch(text, "%S+") do
        if sender_map and renderable(sender_map[word]) and not store.is_blocked(word) then return true end
        if thread_id(word) then return true end
    end
    return false
end

local function flush_run(elems, run, src)
    if #run == 0 then return end
    local init = {
        type = "text",
        text = table.concat(run, " "),
        color = src.color,
        style = src.style,
    }
    if src.flags then init.flags = src.flags end
    table.insert(elems, init)
    for i = #run, 1, -1 do run[i] = nil end
end

local function rebuild_text_element(elems, el, sender_map)
    local run = {}
    local src = {}
    pcall(function()
        src.color = el.color
        src.style = el.style
        src.flags = el.flags
        src.trailing_space = el.trailing_space
    end)
    -- deliberately do NOT copy el.link: a link-less chatterino text element
    -- returns a Link{type=None} (not nil), which is a non-exposed type — re-
    -- applying it to a rebuilt run throws "Invalid link type". real per-word
    -- links (urls, mentions) are their own element types (link/mention), not
    -- text elements, and pass through untouched, so nothing is lost here.
    for _, word in ipairs(el.words) do
        local emote = sender_map and sender_map[word]
        -- store.is_blocked → treat a blocked emote as plain text (local block)
        local set = renderable(emote) and not store.is_blocked(word)
            and imageset_for(emote.url, emote.w, emote.h) or nil
        if set then
            flush_run(elems, run, src)
            table.insert(elems, {
                type = "scaling-image",
                images = set,
                flags = c2.MessageElementFlag.EmoteImage,
                tooltip = word .. " · heatsync",
                link = { type = c2.LinkType.Url, value = net.ORIGIN .. "/emote-search?q=" .. net.percent_encode(word) },
            })
        else
            local tid = thread_id(word)
            if tid then
                flush_run(elems, run, src)
                table.insert(elems, {
                    type = "text",
                    text = word,
                    color = "link",
                    style = src.style,
                    tooltip = "heatsync thread " .. tid,
                    link = { type = c2.LinkType.Url, value = net.ORIGIN .. "/thread/" .. tid },
                })
            else
                table.insert(run, word)
            end
        end
    end
    flush_run(elems, run, src)
    -- preserve the source element's spacing edge on our last emitted element
    if src.trailing_space == false and #elems > 0 then
        local last = elems[#elems]
        if type(last) == "table" and last.type then
            last.trailing_space = false
        end
    end
end

-- is this element the username? (bit-test the Username flag defensively)
local function is_username_el(el)
    local ok, has = pcall(function()
        return (el.flags & c2.MessageElementFlag.Username) ~= 0
    end)
    return ok and has
end

local function build_replacement(msg, sender_map, want_flame)
    local elems = {}
    local flame_done = not want_flame
    for _, el in ipairs(msg:elements()) do
        -- drop the 🔥 marker before the username so HS users are tagged like a
        -- badge. inserted once, right before the username element.
        if not flame_done and is_username_el(el) then
            table.insert(elems, { type = "text", text = FLAME, trailing_space = true })
            flame_done = true
        end
        local ok, ty = pcall(function() return el.type end)
        if ok and ty == "text" then
            rebuild_text_element(elems, el, sender_map)
        else
            -- pass the object through; chatterino clones it (twitch emotes,
            -- badges, timestamps, mentions, reply curves stay verbatim)
            table.insert(elems, el)
        end
    end
    -- fallback: no username element detected → prepend the flame at the start
    if not flame_done then
        table.insert(elems, 1, { type = "text", text = FLAME, trailing_space = true })
    end
    local highlight = msg.highlight_color
    if highlight == "" then highlight = nil end
    return c2.Message.new({
        flags = msg.flags,
        id = msg.id,
        parse_time = msg.parse_time,
        search_text = msg.search_text,
        message_text = msg.message_text,
        login_name = msg.login_name,
        display_name = msg.display_name,
        localized_name = msg.localized_name,
        user_id = msg.user_id,
        channel_name = msg.channel_name,
        username_color = msg.username_color,
        server_received_time = msg.server_received_time,
        highlight_color = highlight,
        elements = elems,
    })
end

-- the per-message body, factored out so `process` can pcall it by reference
-- instead of allocating a fresh closure on every appended message (hot path).
local function do_process(ch, msg, hint)
    local login = msg.login_name
    if type(login) ~= "string" or login == "" then return end
    if (msg.flags & c2.MessageFlag.System) ~= 0 then return end
    local text = msg.message_text
    if type(text) ~= "string" or text == "" then return end

    -- twitch login_name is already canonical-lowercase; no string.lower alloc
    local sender_map = senders.resolve(login, msg.user_id)
    if sender_map == false then sender_map = nil end

    -- rebuild if the message has renderable HS content OR the sender is a known
    -- HS user and the flame marker is on (tags them even on text-only lines).
    local want_flame = store.flame_enabled() and senders.is_known_hs(login)
    if not has_hits(text, sender_map) and not want_flame then return end

    local repl = build_replacement(msg, sender_map, want_flame)
    if hint then
        ch:replace_message(msg, repl, hint)
    else
        ch:replace_message(msg, repl)
    end
    M.replaced_count = M.replaced_count + 1
end

-- shared by the live hook and the back-pass. hint is the 1-based index when
-- known (live: the just-appended message is last).
local function process(ch, msg, hint)
    if processing then return end
    processing = true
    local ok, err = pcall(do_process, ch, msg, hint)
    processing = false
    if not ok then
        -- a systemic failure (api drift) would fire per-message; log the
        -- first few, then go quiet instead of flooding the log
        fail_count = fail_count + 1
        if fail_count <= 3 then
            net.log_warn("render failed: " .. tostring(err))
            if fail_count == 3 then
                net.log_warn("render errors continue; suppressing further logs")
            end
        end
    end
end

local function hook(ch, name)
    local handle = ch:on_message_appended(function(msg, _)
        process(ch, msg, ch:count_messages())
    end)
    hooked[name] = { handle = handle, ch = ch }
    net.log_info("rendering hooked for #" .. name)
    -- one-time presence line in the first hooked channel (discoverability)
    if M.boot_fn and not M.boot_done then
        M.boot_done = true
        local ok, line = pcall(M.boot_fn)
        if ok and type(line) == "string" and line ~= "" then
            pcall(function() ch:add_system_message(line) end)
        end
    end
    if M.on_channel_found then
        pcall(M.on_channel_found, "twitch", name)
    end
end

-- walk all windows → tabs → splits and hook any twitch channel we haven't
-- seen; unhook channels whose objects expired (tab closed). a close+reopen
-- yields a fresh channel object, picked up on the next sweep.
function M.discover()
    if not M.started then return end
    -- prune first so a reopened channel can rehook under the same name
    for name, h in pairs(hooked) do
        local ok, valid = pcall(function() return h.ch:is_valid() end)
        if not ok or not valid then
            pcall(function() h.handle:disconnect() end)
            hooked[name] = nil
            -- drop from ws desired-state too, else reconnect rejoins a room
            -- for a channel that's no longer open (joined{} would grow forever)
            if M.on_channel_gone then pcall(M.on_channel_gone, "twitch", name) end
            net.log_info("rendering unhooked for #" .. name)
        end
    end
    local ok, err = pcall(function()
        for _, win in ipairs(c2.windows:all()) do
            local nb = win.notebook
            if nb then
                for i = 0, nb.page_count - 1 do
                    local page = nb:page_at(i)
                    if page then
                        for _, split in ipairs(page:splits()) do
                            local ch = split.channel
                            -- is_twitch_channel() is the robust predicate;
                            -- get_type() == c2.ChannelType.Twitch is NOT — the
                            -- ChannelType enum values aren't exposed as the
                            -- typings imply (c2.ChannelType.Twitch reads nil at
                            -- runtime), so that comparison never matched.
                            local is_tw = false
                            if ch and ch:is_valid() then
                                pcall(function() is_tw = ch:is_twitch_channel() end)
                            end
                            if is_tw then
                                if not caps.confirm_msg_hooks(ch) then return end
                                local name = ch:get_name()
                                if name ~= "" and not hooked[name] then
                                    hook(ch, name)
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    if not ok then
        net.log_warn("channel discovery failed: " .. tostring(err))
    end
end

-- a sender's emote set just arrived: re-render their recent messages in
-- every hooked channel (messages are frozen, so this is replace, not mutate)
local BACKPASS_DEPTH = 50
function M.backpass(login)
    if not M.started then return end
    for _, h in pairs(hooked) do
        local ok = pcall(function()
            if not h.ch:is_valid() then return end
            for _, msg in ipairs(h.ch:message_snapshot(BACKPASS_DEPTH)) do
                if string.lower(msg.login_name or "") == login then
                    process(h.ch, msg, nil)
                end
            end
        end)
        if not ok then return end
    end
end

function M.start()
    if M.started then return end
    M.started = true
    senders.on_loaded = function(login) M.backpass(login) end
    inventory.on_change = function()
        if inventory.login then M.backpass(inventory.login) end
    end
    M.discover()
end

-- reload safety: chatterino tears down the lua state on reload, but
-- connection handles don't gc-disconnect — drop them explicitly
function M.stop()
    for name, h in pairs(hooked) do
        pcall(function() h.handle:disconnect() end)
        hooked[name] = nil
    end
    M.started = false
end

function M.stats()
    local n = 0
    for _ in pairs(hooked) do n = n + 1 end
    return n, M.replaced_count
end

return M
