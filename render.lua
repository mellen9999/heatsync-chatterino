-- inline rendering (t2 / nightly only): heatsync emotes as real images and
-- >>id threadlinks as clickable links, via hook → rebuild → replace.
--
-- messages freeze once visible, so nothing is mutated: on_message_appended
-- (synchronous, fires before paint) prescans the raw text, and only when a
-- message actually contains a heatsync emote or threadlink is it rebuilt —
-- untouched elements (twitch emotes, badges, timestamps, reply curves) are
-- passed through as objects, which chatterino clones. the render DECISION on a
-- miss is two hash lookups per word and allocates nothing (the archive relay's
-- own per-message allocation is separate — see maybe_relay).
local net = require("net")
local caps = require("caps")
local inventory = require("inventory")
local senders = require("senders")
local store = require("store")
local ws = require("ws")
local badges = require("badges")
local recents = require("recents")
-- NOTE: render no longer requires `seventv` — it renders only the sender's
-- heatsync inventory; native chatterino handles 7tv/bttv/ffz. see has_hits.

local FLAME = "🔥"

-- archive relay throttle (server accepts 60/s per socket, drops the rest)
local relay_sec = 0
local relay_count = 0

-- relay a native twitch PRIVMSG into heatsync's archive (default on, opt-out). only
-- native messages (real twitch id) — injected kick/yt messages have no id.
local function maybe_relay(msg)
    if not store.archive_enabled() then return end
    local id = msg.id
    if type(id) ~= "string" or id == "" then return end -- injected/synthetic
    local channel = msg.channel_name
    local login = msg.login_name
    local text = msg.message_text
    if type(channel) ~= "string" or channel == "" then return end
    if type(login) ~= "string" or login == "" then return end
    if type(text) ~= "string" or text == "" then return end
    local now = net.now()
    if now ~= relay_sec then relay_sec = now; relay_count = 0 end
    if relay_count >= 60 then return end
    relay_count = relay_count + 1
    ws.send({
        type = "twitch:chat:relay",
        channel = string.lower(channel),
        username = string.lower(login),
        message = text,
        message_id = id,
        display_name = msg.display_name,
        timestamp = msg.server_received_time,
    })
end

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
local ok_streak = 0
-- clean processes needed to re-arm error logging after suppression. must be a
-- RUN, not a single success: the miss path (no HS content) is the common case
-- and returns cleanly, so resetting on any one success let a flapping fault
-- (throws on hit-messages, clean on the misses between) reset the counter every
-- other message and log forever. a sustained clean streak means the fault is
-- actually gone; a genuinely NEW, unrelated fault then still surfaces.
local RESET_STREAK = 50

-- sender emotes come from the heatsync inventory: native-height dims but a 1x
-- url, so they render through for_hs_emote (clamps the scale basis to the served
-- 1x line height — see img.lua) rather than the raw for_url.
local hs_imageset = require("img").for_hs_emote

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

-- prescan: any word this sender's heatsync inventory renders, or a threadlink?
-- (skips blocked names). NB: we deliberately do NOT match the global 7tv/bttv/
-- ffz search cache here — see rebuild_text_element for why.
local function has_hits(text, sender_map)
    for word in string.gmatch(text, "%S+") do
        if not store.is_blocked(word) and sender_map and renderable(sender_map[word]) then
            return true
        end
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

-- one crafted line ("x x x ...") could otherwise carry hundreds of emote/thread
-- elements, and the backpass re-runs this across up to BACKPASS_DEPTH messages on
-- every inventory change — bound the images we inject per rebuilt MESSAGE. matches
-- multichat's MAX_EMOTE_TOKENS. over budget → the word stays plain text.
local MAX_RENDER_TOKENS = 50

local function rebuild_text_element(elems, el, sender_map, budget)
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
        local blocked = store.is_blocked(word)
        local emote = sender_map and sender_map[word]
        -- render a word ONLY if the SENDER's heatsync inventory has it (extension
        -- parity). we deliberately do NOT render words that merely match the
        -- global 7tv/bttv/ffz search cache: common english words are also emote
        -- names (e.g. "lost" is a 7tv cat), so that turned plain sentences into
        -- random emotes. native chatterino already renders the real 7tv/bttv/ffz
        -- emotes a sender actually uses — the plugin's job is the heatsync layer.
        -- for_hs_emote scales the ACTUAL 1x image by height: the stored dims are
        -- the emote's NATIVE size (e.g. 128x128) but the url is the cdn's 1x tier
        -- (served <=32px tall), so both the stored width AND a stored height above
        -- the 1x line height would mis-scale it — a 128-tall record rendered a 32px
        -- image at ~7px, i.e. invisible. renderable() guarantees emote.h > 0.
        local over_budget = budget.n >= MAX_RENDER_TOKENS
        local set = not over_budget and renderable(emote) and not blocked
            and hs_imageset(emote.url, emote.h) or nil
        if set then
            budget.n = budget.n + 1
            flush_run(elems, run, src)
            table.insert(elems, {
                type = "scaling-image",
                images = set,
                flags = c2.MessageElementFlag.EmoteImage,
                tooltip = word .. " · heatsync",
                -- left-click any emote WE render → paste it into your input (like
                -- the /hsfind picker + how 7tv/bttv work in-browser). only emotes
                -- the plugin draws get this; chatterino owns clicks on emotes it
                -- renders natively (the plugin API can't override those).
                link = { type = c2.LinkType.InsertText, value = word .. " " },
            })
        else
            local tid = not over_budget and thread_id(word)
            if tid then
                budget.n = budget.n + 1
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

-- the marker row prepended before the username: chatterino badge (if opted in
-- and the user has one) then the 🔥 heatsync marker.
local function insert_markers(elems, msg, want_flame)
    local badge = badges.element_for(msg.user_id)
    if badge then table.insert(elems, badge) end
    if want_flame then
        table.insert(elems, { type = "text", text = FLAME, trailing_space = true })
    end
end

-- is this element our own previously-inserted 🔥 flame text? (single word)
local function is_flame_el(el)
    local ok, w = pcall(function() return el.words end)
    return ok and type(w) == "table" and #w == 1 and w[1] == FLAME
end

local function build_replacement(msg, sender_map, want_flame)
    local elems = {}
    local markers_done = false
    local budget = { n = 0 } -- emote/thread elements injected across THIS message
    for _, el in ipairs(msg:elements()) do
        local ok, ty = pcall(function() return el.type end)
        -- BEFORE the username, strip our own markers from a prior render so
        -- re-processing (backpass) is idempotent — no stacked flames/badges.
        -- our badge is the only scaling-image that can precede the username
        -- (sender emotes live in the body); our flame is a lone-🔥 text run.
        -- native twitch badges are badge-type elements, so they pass through.
        if not markers_done then
            if ty == "scaling-image" or (ty == "text" and is_flame_el(el)) then
                goto continue
            end
            if is_username_el(el) then
                insert_markers(elems, msg, want_flame)
                markers_done = true
            end
        end
        if ty == "text" then
            rebuild_text_element(elems, el, sender_map, budget)
        else
            -- pass the object through; chatterino clones it (twitch emotes,
            -- badges, timestamps, mentions, reply curves stay verbatim)
            table.insert(elems, el)
        end
        ::continue::
    end
    -- fallback: no username element detected → markers at the very start
    if not markers_done then
        local pre = {}
        insert_markers(pre, msg, want_flame)
        for i = #pre, 1, -1 do table.insert(elems, 1, pre[i]) end
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
    -- skip multichat-injected kick/youtube messages: they have an empty
    -- channel_name (native twitch messages always carry it — same fact
    -- maybe_relay relies on). running them through here would redundantly
    -- rebuild them and, worse, a kick/yt username colliding with a cached
    -- twitch HS login would false-flag them. multichat does its own emote
    -- rendering, so there's nothing to gain here anyway.
    if type(msg.channel_name) ~= "string" or msg.channel_name == "" then return end
    if (msg.flags & c2.MessageFlag.System) ~= 0 then return end
    local text = msg.message_text
    if type(text) ~= "string" or text == "" then return end

    -- archive relay (default on, opt-out; before render rebuild, independent of it)
    maybe_relay(msg)

    -- learn recently-used emotes from your OWN outgoing messages — the only
    -- usage signal the plugin can observe (click-to-insert has no callback).
    -- feeds the recents row at the top of the /hsemotes menu.
    if login == senders.own_login then recents.note(text) end

    -- twitch login_name is already canonical-lowercase; no string.lower alloc
    local sender_map = senders.resolve(login, msg.user_id)
    if sender_map == false then sender_map = nil end

    -- rebuild if the message has renderable HS content, OR the sender is a
    -- known HS user with the flame on, OR the sender has a chatterino badge.
    -- the flame tags OTHER heatsync users so you can spot them — it's pointless
    -- on your own messages, and skipping them avoids a needless rebuild that
    -- would drop your native channel badges (e.g. your sub badge).
    local want_flame = store.flame_enabled() and login ~= senders.own_login
        and senders.is_known_hs(login)
    -- O(1) checks first; only pay the O(words) has_hits scan when neither the
    -- flame nor a badge already forces the rebuild (Lua `or` short-circuits).
    if not (want_flame or badges.has(msg.user_id) or has_hits(text, sender_map)) then return end

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
        ok_streak = 0
        fail_count = fail_count + 1
        if fail_count <= 3 then
            net.log_warn("render failed: " .. tostring(err))
            if fail_count == 3 then
                net.log_warn("render errors continue; suppressing further logs")
            end
        end
    elseif fail_count > 0 then
        -- re-arm logging only after a SUSTAINED clean run (see RESET_STREAK) —
        -- a single clean miss can't unmute a flapping fault mid-episode, but a
        -- resolved fault eventually clears so a future, unrelated fault logs again.
        ok_streak = ok_streak + 1
        if ok_streak >= RESET_STREAK then
            fail_count = 0
            ok_streak = 0
        end
    end
end

local function hook(ch, name)
    local handle = ch:on_message_appended(function(msg, _)
        -- count_messages() is evaluated as an argument, BEFORE process()'s inner
        -- pcall — guard it so a torn-down channel mid-tick can't escape raw into
        -- chatterino's native dispatch. nil hint just makes replace_message
        -- resolve the index itself.
        local ok, n = pcall(function() return ch:count_messages() end)
        process(ch, msg, ok and n or nil)
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
                                -- hooks missing → skip THIS channel, not the whole
                                -- sweep (a bare `return` aborted every other open
                                -- tab too). the verdict is build-wide + memoized,
                                -- so this just cleanly no-ops each split.
                                if caps.confirm_msg_hooks(ch) then
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
