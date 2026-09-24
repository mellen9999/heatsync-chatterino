-- inline rendering (t2 / nightly only): heatsync emotes as real images and
-- >>id threadlinks as clickable links, via hook → rebuild → replace.
--
-- messages freeze once visible, so nothing is mutated: on_message_appended
-- (synchronous, fires before paint) prescans the raw text, and only when a
-- message actually contains a heatsync emote or threadlink is it rebuilt —
-- untouched elements (twitch emotes, badges, timestamps, reply curves) are
-- passed through as objects, which chatterino clones. the render DECISION on a
-- miss is two hash lookups per word and allocates nothing.
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

-- archive relay: a DEMAND SIGNAL, not a content feed — tells heatsync WHICH
-- public twitch channel you're watching so its reader pool/EventSub can
-- archive it server-side. the server keeps only `channel` and rate-limits to
-- 1 per socket per channel per 5 min (ws-handlers.ts handleTwitchChatRelay),
-- so message text, username, message id and timestamp never leave the plugin
-- at all — there's nothing left to throttle per-message, only per-channel.
local RELAY_RESIGNAL_S = 300
local relay_sent = {} -- lowercase channel -> net.now() of the last signal sent

local function signal_relay(channel)
    if not store.archive_enabled() then return end
    local last = relay_sent[channel]
    local now = net.now()
    if last and (now - last) < RELAY_RESIGNAL_S then return end
    -- record only a frame that actually went out: while the socket is down
    -- the next 5s sweep retries, so a reconnect re-signals within seconds
    -- instead of waiting out a window that was never used
    if ws.send({ type = "twitch:chat:relay", channel = channel }) then
        relay_sent[channel] = now
    end
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

-- extension-parity time gate: a message can only show an emote its sender
-- actually held at send time. `a` (added_at) is a lower bound, `u` (until /
-- last_seen, for a reused name) an upper bound — both ms, both optional. the
-- 120s slack absorbs clock skew between chatterino's local clock and the
-- server's timestamps. unknown message time (t == nil) never gates, matching
-- pre-gate behaviour for a build/tier without a usable time field.
local GATE_SLACK_MS = 120000

-- an emote entry only counts as a hit if it can actually render (unknown
-- source dims mean no scale factor, and a raw-size image is worse than text)
-- AND, when it carries add/remove bounds, the message time falls inside them.
local function renderable(emote, t)
    if emote == nil or type(emote.h) ~= "number" or emote.h <= 0 then return false end
    if type(t) ~= "number" then return true end
    if emote.a and t < emote.a - GATE_SLACK_MS then return false end
    if emote.u and t >= emote.u + GATE_SLACK_MS then return false end
    return true
end

-- prescan: any word this sender's heatsync inventory renders, or a threadlink?
-- (skips blocked names). NB: we deliberately do NOT match the global 7tv/bttv/
-- ffz search cache here — see rebuild_text_element for why.
local function has_hits(text, sender_map, t)
    for word in string.gmatch(text, "%S+") do
        -- sender_map first: for a sender with no HS inventory (the common case)
        -- this skips a needless is_blocked call + hash lookup on every word.
        if sender_map and not store.is_blocked(word) and renderable(sender_map[word], t) then
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

local function rebuild_text_element(elems, el, sender_map, budget, t)
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
        -- is_blocked only when the word is actually a renderable emote — a plain
        -- word (the majority) skips the lookup via short-circuit.
        local set = not over_budget and renderable(emote, t) and not store.is_blocked(word)
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

-- defensive field reads for pcall(fn, el) — named + module-level so the rebuild
-- loop doesn't allocate a fresh closure per element/call just to guard a field.
local function read_type(el) return el.type end
local function read_words(el) return el.words end
local function read_username_flag(el)
    return (el.flags & c2.MessageElementFlag.Username) ~= 0
end

-- is this element the username? (bit-test the Username flag defensively)
local function is_username_el(el)
    local ok, has = pcall(read_username_flag, el)
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
    local ok, w = pcall(read_words, el)
    return ok and type(w) == "table" and #w == 1 and w[1] == FLAME
end

local function build_replacement(msg, sender_map, want_flame, t)
    local elems = {}
    local markers_done = false
    local budget = { n = 0 } -- emote/thread elements injected across THIS message
    for _, el in ipairs(msg:elements()) do
        local ok, ty = pcall(read_type, el)
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
            rebuild_text_element(elems, el, sender_map, budget, t)
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

-- best-effort message time for the gate above. server_received_time is a
-- stable field read directly elsewhere in this file (build_replacement);
-- timestamp is pcall-guarded since it's a newer/alternate field (hedges a
-- possible future rename) that may not exist on every build. nil (unknown,
-- including chatterino's zero-value placeholder) means renderable() never gates.
local function msg_time(msg)
    local t = msg.server_received_time
    if type(t) == "number" and t == t and t ~= math.huge and t > 0 then return t end
    local ok, t2 = pcall(function() return msg.timestamp end)
    if ok and type(t2) == "number" and t2 == t2 and t2 ~= math.huge and t2 > 0 then return t2 end
    return nil
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
    local t = msg_time(msg)
    -- O(1) checks first; only pay the O(words) has_hits scan when neither the
    -- flame nor a badge already forces the rebuild (Lua `or` short-circuits).
    if not (want_flame or badges.has(msg.user_id) or has_hits(text, sender_map, t)) then return end

    local repl = build_replacement(msg, sender_map, want_flame, t)
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
    -- a channel just got hooked → heatsync should archive it. name is already
    -- twitch's canonical-lowercase login (same fact do_process relies on).
    signal_relay(name)
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
            relay_sent[name] = nil -- keep the throttle map bounded to open tabs
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
    -- re-signal every hooked channel; signal_relay's own 5-min throttle means
    -- this 5s sweep is a no-op for a channel until its window is actually up —
    -- piggybacking here avoids a second timer just for the relay.
    for name in pairs(hooked) do
        signal_relay(name)
    end
end

-- a sender's emote set just arrived: re-render their recent messages in
-- every hooked channel (messages are frozen, so this is replace, not mutate)
local BACKPASS_DEPTH = 50
local function run_backpass(login)
    if not M.started then return end
    for _, h in pairs(hooked) do
        -- isolate per channel: one channel throwing (e.g. it went stale between
        -- the is_valid check and use) must not skip the backpass for the others.
        pcall(function()
            if not h.ch:is_valid() then return end
            for _, msg in ipairs(h.ch:message_snapshot(BACKPASS_DEPTH)) do
                if string.lower(msg.login_name or "") == login then
                    process(h.ch, msg, nil)
                end
            end
        end)
    end
end

-- coalesce backpasses: senders.on_loaded fires once per resolved sender, and a
-- senderKeys invalidate (up to 50 targets) or a batch flush (up to 15) can land
-- several in one tick — without this each would run the O(channels × 50-msg
-- snapshot) scan back-to-back. collect the distinct logins touched in a tick
-- and run each once, ~1 frame later. no timers (t0/t1) → run immediately, unchanged.
local backpass_pending = {}
local backpass_pending_n = 0
local backpass_armed = false
local BACKPASS_COALESCE_MS = 120
-- cap distinct logins queued in one coalesce window: the ws has no incoming rate
-- limit, so a hostile server could otherwise flood many broadcast/invalidate
-- frames in 120ms and grow this set (and the drain's O(channels×snapshot) work)
-- unbounded. a legit batch touches few distinct senders, so 256 is generous headroom.
local BACKPASS_PENDING_MAX = 256
function M.backpass(login)
    if not M.started or type(login) ~= "string" or login == "" then return end
    if not caps.later then return run_backpass(login) end
    if backpass_pending[login] == nil then
        if backpass_pending_n >= BACKPASS_PENDING_MAX then return end -- drop overflow
        backpass_pending_n = backpass_pending_n + 1
    end
    backpass_pending[login] = true
    if backpass_armed then return end
    backpass_armed = true
    local ok = pcall(c2.later, function()
        backpass_armed = false
        local todo = backpass_pending
        backpass_pending = {}
        backpass_pending_n = 0
        for lg in pairs(todo) do run_backpass(lg) end
    end, BACKPASS_COALESCE_MS)
    if not ok then -- timer refused: drain immediately so nothing is lost
        backpass_armed = false
        local todo = backpass_pending
        backpass_pending = {}
        backpass_pending_n = 0
        for lg in pairs(todo) do run_backpass(lg) end
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
    relay_sent = {}
    M.started = false
end

function M.stats()
    local n = 0
    for _ in pairs(hooked) do n = n + 1 end
    return n, M.replaced_count
end

return M
