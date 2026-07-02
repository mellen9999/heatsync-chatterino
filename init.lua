-- heatsync chatterino plugin — v0.4.0
--
-- Tab-completes against:
--   1) your heatsync.org emote inventory  (own emotes first, usage-weighted)
--   2) 7TV global catalog, popularity-ranked (TOP_ALL_TIME via server-side
--      heatsync.org/api/emote-search proxy — Redis-cached + single-flight)
--
-- Mirrors the browser extension's ordering per heatsync's tabcomplete spec:
-- own emotes first (by usage_count desc), then 7TV by popularity. Picking
-- a name → it pastes into chat as text. Other heatsync-extension users in
-- the same channel see it rendered as the actual emote image; Chatterino
-- itself shows literal text (the plugin API has no custom emote-image-
-- injection surface).
--
-- Endpoints (public, CORS-open):
--   GET /api/profile/<twitch_login>     → resolve login → numeric user id
--   GET /api/users/<userId>/emotes      → inventory rows
--   GET /api/emote-search?q=<q>&p=7tv   → 7TV results, TOP_ALL_TIME order
--
-- No writes, no auth tokens.

local HEATSYNC_ORIGIN = "https://heatsync.org"
local json = require("chatterino.json")

-- ----- own-inventory state -----
-- emote_map[name] = url
local emote_map = {}
-- Sorted prefix index: [{ name, lower, usage }, ...]
-- Sort: usage desc, then alpha asc — keeps high-use emotes first when
-- multiple match the same prefix.
local emote_index = {}
local refreshing = false
local last_login = nil

-- ----- opportunistic background refresh state -----
-- Chatterino's Lua plugin API (checked docs/wip-plugins.md, 2026-07) has no
-- timer/scheduler of any kind — no c2.later, no tick event, nothing that
-- fires on a clock. CompletionRequested (tab-complete) is the only callback
-- that recurs on its own during normal use, so account-switch detection,
-- the periodic full re-fetch, and the boot retry all piggyback on it via
-- maybe_background_refresh() below. These only run while the user is
-- actively typing — there is no true idle-time polling. /hsrefresh remains
-- the manual escape hatch.
local LOGIN_CHECK_INTERVAL_S = 60
local FULL_REFRESH_INTERVAL_S = 15 * 60
local BOOT_RETRY_BACKOFF_S = 10
local last_login_check_ts = 0
local last_full_refresh_ts = 0
local last_refresh_failed_at = nil -- os.time() of a hop failure before first successful load
local boot_retry_used = false

-- ----- 7TV search cache -----
-- search_cache[lowercase_query] = { ts, names } where ts is os.time() seconds
-- and names is a list in upstream order (popularity desc). Aged out after
-- SEARCH_CACHE_TTL_S.
local search_cache = {}
local search_cache_order = {} -- FIFO queue for eviction
local search_inflight = {}    -- query → true while a fetch is open
local SEARCH_CACHE_TTL_S = 10 * 60
local SEARCH_ERROR_TTL_S = 30 -- short-lived negative cache so a flaky upstream self-heals fast
local SEARCH_CACHE_MAX = 64   -- hard cap; oldest dropped when over
local SEARCH_MIN_CHARS = 2
local SEARCH_MAX_CHARS = 50   -- server validator
local COMPLETION_CAP = 25

local function log_info(msg)
    c2.log(c2.LogLevel.Info, "[heatsync] " .. msg)
end

local function log_warn(msg)
    c2.log(c2.LogLevel.Warning, "[heatsync] " .. msg)
end

-- Minimal percent-encoding for URL path/query segments. The charset
-- regexes upstream (Twitch login pattern, is_sane_search_query) are the
-- first gate; this is defense-in-depth so a stray character can never
-- corrupt the request URL or get misread server-side.
local function percent_encode(s)
    return (string.gsub(tostring(s), "[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Reads the current account defensively. Chatterino's API can throw (or
-- the selected account can be invalid mid-session, e.g. removed in
-- settings), so every access in the chain is pcall-guarded here once
-- instead of ad-hoc at each call site. Returns the login string, or nil if
-- there's no valid, signed-in, non-anon account.
local function current_login_safe()
    local ok_acc, acc = pcall(c2.current_account)
    if not ok_acc or not acc then return nil end
    local ok_valid, valid = pcall(function() return acc:is_valid() end)
    if not ok_valid or not valid then return nil end
    local ok_anon, anon = pcall(function() return acc:is_anon() end)
    if not ok_anon or anon then return nil end
    local ok_login, login = pcall(function() return acc:login() end)
    if not ok_login or type(login) ~= "string" or login == "" then return nil end
    return login
end

local function safe_json_parse(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, parsed = pcall(json.parse, raw)
    if not ok then return nil end
    return parsed
end

-- Sort/rebuild the prefix index from rows captured during a refresh.
-- entries is a list of { name, usage } (usage is 0 if API omitted it).
local function rebuild_index(entries)
    emote_index = {}
    for _, e in ipairs(entries) do
        table.insert(emote_index, {
            name = e.name,
            lower = string.lower(e.name),
            usage = e.usage or 0,
        })
    end
    table.sort(emote_index, function(a, b)
        if a.usage ~= b.usage then return a.usage > b.usage end
        return a.lower < b.lower
    end)
end

-- ----- 7TV cache hygiene -----

local function cache_evict_if_full()
    while #search_cache_order > SEARCH_CACHE_MAX do
        local oldest = table.remove(search_cache_order, 1)
        if oldest then search_cache[oldest] = nil end
    end
end

-- is_error entries (failed upstream fetch) use a short TTL so a flaky
-- 7TV/proxy hiccup doesn't negative-cache a query for the full 10 minutes.
local function cache_put(q, names, is_error)
    if search_cache[q] == nil then
        table.insert(search_cache_order, q)
    end
    search_cache[q] = { ts = os.time(), names = names or {}, is_error = is_error or false }
    cache_evict_if_full()
end

local function cache_get_fresh(q)
    local hit = search_cache[q]
    if not hit then return nil end
    local ttl = hit.is_error and SEARCH_ERROR_TTL_S or SEARCH_CACHE_TTL_S
    if (os.time() - hit.ts) > ttl then return nil end
    return hit
end

-- ----- refresh inventory -----

-- Accept multiple possible field names for forward-compat with any small
-- API renames (e.g. `name` instead of `custom_name`). The first non-empty
-- string wins.
local function pick_first_str(obj, ...)
    for i = 1, select("#", ...) do
        local k = select(i, ...)
        local v = obj[k]
        if type(v) == "string" and v ~= "" then return v end
    end
    return nil
end

-- Inventory id can be a number (live users) or a string (shadow users with
-- "u_<login>" prefix). The /api/users/:id endpoint only accepts numeric ids,
-- so we bail loudly on shadow users — they have no inventory to fetch yet.
local function is_real_numeric_id(uid)
    if type(uid) == "number" then return uid > 0 end
    if type(uid) == "string" and string.match(uid, "^%d+$") then return true end
    return false
end

local function refresh_inventory(login)
    if not login or login == "" then
        log_warn("no account login; skipping refresh")
        return
    end
    if refreshing then
        log_info("refresh already in-flight")
        return
    end
    refreshing = true
    log_info("refreshing inventory for " .. login)

    -- Explicit two-hop tracking: `refreshing` must stay true for the whole
    -- profile→emotes chain, not just hop 1. hop2_started flips true only
    -- once emotes_req is actually constructed and executing; profile_req's
    -- finally (below) uses it to tell "hop 2 is in flight, let its own
    -- finally reset `refreshing`" apart from "hop 2 never happened, reset
    -- now" (profile error / shadow user / missing id).
    local hop2_started = false

    -- A transport-level failure before the very first successful load is
    -- what the boot retry (see maybe_background_refresh) backs off and
    -- retries once; a "no inventory yet" business response is not a
    -- failure worth retrying, so that path does not set this.
    local function note_possible_boot_failure()
        if not boot_retry_used and next(emote_map) == nil then
            last_refresh_failed_at = os.time()
        end
    end

    local profile_url = HEATSYNC_ORIGIN .. "/api/profile/" .. percent_encode(login)
    local profile_req = c2.HTTPRequest.create(c2.HTTPMethod.Get, profile_url)
    profile_req:set_timeout(10000)
    profile_req:set_header("Accept", "application/json")
    profile_req:on_error(function(res)
        log_warn("profile fetch failed: " .. tostring(res:error()))
        note_possible_boot_failure()
    end)
    profile_req:on_success(function(res)
        local data = safe_json_parse(res:data())
        local uid = data and data.profile and data.profile.id
        if not is_real_numeric_id(uid) then
            log_warn("no heatsync inventory yet for " .. login ..
                     " (profile id missing or shadow). sign in at heatsync.org once.")
            return
        end

        local emotes_url = HEATSYNC_ORIGIN .. "/api/users/" .. tostring(uid) .. "/emotes"
        local emotes_req = c2.HTTPRequest.create(c2.HTTPMethod.Get, emotes_url)
        emotes_req:set_timeout(10000)
        emotes_req:set_header("Accept", "application/json")
        emotes_req:on_error(function(res2)
            log_warn("emote fetch failed: " .. tostring(res2:error()))
            note_possible_boot_failure()
        end)
        emotes_req:on_success(function(res2)
            local payload = safe_json_parse(res2:data())
            local rows = payload and (payload.emotes or payload.data or payload.items)
            if type(rows) ~= "table" then
                log_warn("emote response has no recognizable list field")
                return
            end
            local new_map = {}
            local entries = {}
            local count = 0
            for _, e in ipairs(rows) do
                local name = pick_first_str(e, "custom_name", "name", "code")
                local url = pick_first_str(e, "url", "src")
                if name and url then
                    new_map[name] = url
                    local usage = tonumber(e.usage_count or e.uses or 0) or 0
                    table.insert(entries, { name = name, usage = usage })
                    count = count + 1
                end
            end
            emote_map = new_map
            rebuild_index(entries)
            log_info("loaded " .. tostring(count) .. " emotes for " .. login)
        end)
        emotes_req:finally(function() refreshing = false end)
        hop2_started = true
        emotes_req:execute()
    end)
    -- Belt + suspenders: clear refreshing once the FIRST hop terminates
    -- if we never made it to the second. The inner `finally` above handles
    -- the typical happy / sad paths; this catches profile-side hangs that
    -- never reach the emotes_req construction. Gated on hop2_started (set
    -- synchronously right before emotes_req:execute()) rather than the
    -- always-true `refreshing` flag — checking `refreshing` here was dead
    -- code that reset it the instant hop 1 finished, even while hop 2 was
    -- still in flight, letting overlapping refreshes stomp on each other.
    profile_req:finally(function()
        if not hop2_started then
            refreshing = false
        end
    end)
    profile_req:execute()
end

-- ----- opportunistic background refresh -----

-- See the state block near the top of the file: Chatterino's Lua plugin
-- API has no timer, so this piggybacks on CompletionRequested (the plugin's
-- only self-recurring callback) to approximate account-switch detection, a
-- periodic full re-fetch, and a one-shot boot retry.
local function maybe_background_refresh()
    -- One-shot boot retry: cheap to check, unthrottled, fires at most once
    -- per session (boot_retry_used latches after).
    if last_refresh_failed_at and not boot_retry_used
        and (os.time() - last_refresh_failed_at) >= BOOT_RETRY_BACKOFF_S then
        boot_retry_used = true
        last_refresh_failed_at = nil
        if last_login then
            log_info("retrying boot inventory fetch after backoff")
            refresh_inventory(last_login)
        end
    end

    -- Account-switch + periodic full refresh, throttled so we're not
    -- pcall'ing current_account() on every keystroke.
    local now = os.time()
    if (now - last_login_check_ts) < LOGIN_CHECK_INTERVAL_S then return end
    last_login_check_ts = now

    local login = current_login_safe()
    if not login then return end
    if login ~= last_login then
        log_info("account switched to " .. login .. "; refreshing inventory")
        last_login = login
        last_full_refresh_ts = now
        refresh_inventory(login)
        return
    end
    if (now - last_full_refresh_ts) >= FULL_REFRESH_INTERVAL_S then
        last_full_refresh_ts = now
        refresh_inventory(login)
    end
end

-- ----- 7TV search -----

local function kick_off_7tv_search(q)
    if search_inflight[q] then return end
    if cache_get_fresh(q) then return end

    search_inflight[q] = true
    local url = HEATSYNC_ORIGIN .. "/api/emote-search?q=" .. percent_encode(q) .. "&p=7tv"
    local req = c2.HTTPRequest.create(c2.HTTPMethod.Get, url)
    req:set_timeout(8000)
    req:set_header("Accept", "application/json")
    req:on_error(function(res)
        cache_put(q, {}, true) -- short-TTL negative cache to dampen retries on flaky upstream
        log_warn("7tv search failed for '" .. q .. "': " .. tostring(res:error()))
    end)
    req:on_success(function(res)
        local payload = safe_json_parse(res:data())
        local items = payload and payload.results and payload.results["7tv"]
        local names = {}
        local seen = {}
        if type(items) == "table" then
            for _, e in ipairs(items) do
                local name = pick_first_str(e, "name", "code")
                if name and not seen[name] then
                    table.insert(names, name)
                    seen[name] = true
                end
            end
        end
        cache_put(q, names)
    end)
    req:finally(function() search_inflight[q] = nil end)
    req:execute()
end

-- ----- completion hook -----

local function strip_leading_colon(query)
    if string.sub(query, 1, 1) == ":" then
        return string.sub(query, 2)
    end
    return query
end

local function is_sane_search_query(q)
    return string.match(q, "^[a-z0-9_%-:%.]+$") ~= nil
end

c2.register_callback(
    c2.EventType.CompletionRequested,
    function(event)
        -- Best-effort; must never take down completions if something in
        -- here throws.
        local ok_bg, err_bg = pcall(maybe_background_refresh)
        if not ok_bg then
            log_warn("background refresh check failed: " .. tostring(err_bg))
        end

        local query = event.query or ""
        if query == "" then
            return { hide_others = false, values = {} }
        end
        local raw = strip_leading_colon(query)
        local q = string.lower(raw)
        local qlen = string.len(q)
        if qlen < 1 then
            return { hide_others = false, values = {} }
        end
        if qlen > SEARCH_MAX_CHARS then
            q = string.sub(q, 1, SEARCH_MAX_CHARS)
            qlen = SEARCH_MAX_CHARS
        end

        local values = {}
        local seen = {}

        -- 1) Own inventory, prefix-matched. emote_index is pre-sorted
        --    usage-desc then alpha-asc, so we walk it in order.
        for _, item in ipairs(emote_index) do
            if string.sub(item.lower, 1, qlen) == q then
                if not seen[item.name] then
                    table.insert(values, item.name)
                    seen[item.name] = true
                end
                if #values >= COMPLETION_CAP then break end
            end
        end

        -- 2) 7TV — append in upstream popularity order. Cache-first; kick
        --    off a fresh fetch in the background so the next keystroke can
        --    include results.
        if #values < COMPLETION_CAP and qlen >= SEARCH_MIN_CHARS and is_sane_search_query(q) then
            kick_off_7tv_search(q)
            local hit = cache_get_fresh(q)
            if hit and type(hit.names) == "table" then
                for _, name in ipairs(hit.names) do
                    if #values >= COMPLETION_CAP then break end
                    if not seen[name] then
                        table.insert(values, name)
                        seen[name] = true
                    end
                end
            end
        end

        return { hide_others = false, values = values }
    end
)

-- ----- commands -----

c2.register_command("/hsrefresh", function(ctx)
    local login = current_login_safe()
    if not login then
        ctx.channel:add_system_message("[heatsync] no signed-in twitch account; can't refresh")
        return
    end
    last_login = login
    last_full_refresh_ts = os.time()
    local ok, err = pcall(refresh_inventory, login)
    if not ok then
        log_warn("manual refresh failed: " .. tostring(err))
        ctx.channel:add_system_message("[heatsync] refresh failed, see log")
        return
    end
    ctx.channel:add_system_message("[heatsync] refreshing inventory for " .. login .. "…")
end)

c2.register_command("/hsemotes", function(ctx)
    local own_count = 0
    for _ in pairs(emote_map) do own_count = own_count + 1 end
    local cached_queries = #search_cache_order
    if own_count == 0 then
        ctx.channel:add_system_message("[heatsync] inventory not loaded — try /hsrefresh")
        return
    end
    ctx.channel:add_system_message(
        "[heatsync] " .. tostring(own_count) .. " inventory emotes · " ..
        tostring(cached_queries) .. " 7tv search queries cached (cap " ..
        tostring(SEARCH_CACHE_MAX) .. ")"
    )
end)

c2.register_command("/hsclear", function(ctx)
    search_cache = {}
    search_cache_order = {}
    search_inflight = {}
    ctx.channel:add_system_message("[heatsync] 7tv search cache cleared")
end)

-- ----- boot -----
do
    local login = current_login_safe()
    if login then
        last_login = login
        last_full_refresh_ts = os.time()
        local ok, err = pcall(refresh_inventory, login)
        if not ok then
            log_warn("boot refresh failed: " .. tostring(err))
        end
    else
        log_warn("no signed-in twitch account at boot; user can run /hsrefresh later")
    end
end
