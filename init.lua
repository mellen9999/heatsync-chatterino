-- heatsync chatterino plugin
--
-- Tab-completes against:
--   1) your heatsync.org emote inventory  (own emotes first)
--   2) 7TV global catalog, popularity-ranked (TOP_ALL_TIME via server-side
--      heatsync.org/api/emote-search proxy — Redis-cached + single-flight)
--
-- Mirrors the browser extension's ordering per heatsync's tabcomplete spec:
-- own emotes first, then 7TV by popularity. Picking a name → it pastes into
-- chat as text. Other heatsync-extension users in the same channel see it
-- rendered as the actual emote image; Chatterino itself shows literal text
-- (the plugin API has no custom emote-image-injection surface).
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
-- emote_name (string) → emote_url (string)
local emote_map = {}
-- sorted lowercase names for prefix completion: [{ name = "PogChamp", lower = "pogchamp" }, ...]
local emote_names_lower = {}
local refreshing = false
local last_login = nil

-- ----- 7TV search cache -----
-- search_cache[lowercase_query] = { ts = ms_since_epoch, names = {string,...} }
-- Names are kept in upstream order (popularity desc). Lifetime ~10min — server
-- cache is 1hr so this is just to avoid re-firing same-query within a session.
local search_cache = {}
local search_inflight = {} -- query → true while fetch is open
local SEARCH_CACHE_TTL_MS = 10 * 60 * 1000
local SEARCH_MIN_CHARS = 2 -- don't fire 7TV search until 2+ chars
local COMPLETION_CAP = 25
local OWN_RESERVED = 10 -- always reserve at least this many slots for own emotes when both surfaces have hits

local function log_info(msg)
    c2.log(c2.LogLevel.Info, "[heatsync] " .. msg)
end

local function log_warn(msg)
    c2.log(c2.LogLevel.Warning, "[heatsync] " .. msg)
end

local function rebuild_index()
    emote_names_lower = {}
    for name, _ in pairs(emote_map) do
        table.insert(emote_names_lower, { name = name, lower = string.lower(name) })
    end
    table.sort(emote_names_lower, function(a, b)
        return a.lower < b.lower
    end)
end

local function safe_json_parse(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, parsed = pcall(json.parse, raw)
    if not ok then return nil end
    return parsed
end

-- chatterino doesn't expose os.time-ms; fall back to seconds * 1000.
local function now_ms()
    return os.time() * 1000
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

    local profile_url = HEATSYNC_ORIGIN .. "/api/profile/" .. login
    local profile_req = c2.HTTPRequest.create(c2.HTTPMethod.Get, profile_url)
    profile_req:set_timeout(10000)
    profile_req:set_header("Accept", "application/json")
    profile_req:on_error(function(res)
        refreshing = false
        log_warn("profile fetch failed: " .. tostring(res:error()))
    end)
    profile_req:on_success(function(res)
        local body = res:data()
        local data = safe_json_parse(body)
        local uid = data and data.profile and data.profile.id
        if not uid then
            refreshing = false
            log_warn("profile response missing id for " .. login)
            return
        end

        local emotes_url = HEATSYNC_ORIGIN .. "/api/users/" .. tostring(uid) .. "/emotes"
        local emotes_req = c2.HTTPRequest.create(c2.HTTPMethod.Get, emotes_url)
        emotes_req:set_timeout(10000)
        emotes_req:set_header("Accept", "application/json")
        emotes_req:on_error(function(res2)
            refreshing = false
            log_warn("emote fetch failed: " .. tostring(res2:error()))
        end)
        emotes_req:on_success(function(res2)
            local payload = safe_json_parse(res2:data())
            local rows = payload and payload.emotes
            if type(rows) ~= "table" then
                refreshing = false
                log_warn("emote response has no emotes array")
                return
            end
            local new_map = {}
            local count = 0
            for _, e in ipairs(rows) do
                local name = e.custom_name
                local url = e.url
                if type(name) == "string" and name ~= ""
                   and type(url) == "string" and url ~= "" then
                    new_map[name] = url
                    count = count + 1
                end
            end
            emote_map = new_map
            rebuild_index()
            refreshing = false
            log_info("loaded " .. tostring(count) .. " emotes for " .. login)
        end)
        emotes_req:execute()
    end)
    profile_req:execute()
end

-- ----- 7TV search -----

-- Kick off a non-blocking 7TV search for `q` (already lowercase + sanitized).
-- Result populates search_cache so the NEXT keystroke's completion includes it.
-- Returns immediately; safe to call repeatedly — guarded by search_inflight.
local function kick_off_7tv_search(q)
    if search_inflight[q] then return end
    -- Don't re-fire if the cache is fresh enough.
    local hit = search_cache[q]
    if hit and (now_ms() - hit.ts) < SEARCH_CACHE_TTL_MS then return end

    search_inflight[q] = true
    local url = HEATSYNC_ORIGIN .. "/api/emote-search?q=" .. q .. "&p=7tv"
    local req = c2.HTTPRequest.create(c2.HTTPMethod.Get, url)
    req:set_timeout(8000)
    req:set_header("Accept", "application/json")
    req:on_error(function(res)
        search_inflight[q] = nil
        -- Negative cache so we don't keep retrying a failing query.
        search_cache[q] = { ts = now_ms(), names = {} }
        log_warn("7tv search failed for '" .. q .. "': " .. tostring(res:error()))
    end)
    req:on_success(function(res)
        search_inflight[q] = nil
        local payload = safe_json_parse(res:data())
        local items = payload and payload.results and payload.results["7tv"]
        local names = {}
        local seen = {}
        if type(items) == "table" then
            for _, e in ipairs(items) do
                local name = e.name
                if type(name) == "string" and name ~= "" and not seen[name] then
                    table.insert(names, name)
                    seen[name] = true
                end
            end
        end
        search_cache[q] = { ts = now_ms(), names = names }
    end)
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
    -- Mirror the server's accepted character set so we don't fire requests
    -- that will 400. (server: /^[a-z0-9_\-:.]+$/i)
    return string.match(q, "^[a-z0-9_%-:%.]+$") ~= nil
end

c2.register_callback(
    c2.EventType.CompletionRequested,
    function(event)
        local query = event.query or ""
        if query == "" then
            return { hide_others = false, values = {} }
        end
        local raw = strip_leading_colon(query)
        local q = string.lower(raw)
        if string.len(q) < 1 then
            return { hide_others = false, values = {} }
        end

        -- 1) Own inventory — prefix-matched, alpha (stable for now; matches
        --    how the ext renders the own block).
        local values = {}
        local seen = {}
        local own_added = 0
        for _, item in ipairs(emote_names_lower) do
            if string.sub(item.lower, 1, string.len(q)) == q then
                if not seen[item.name] then
                    table.insert(values, item.name)
                    seen[item.name] = true
                    own_added = own_added + 1
                end
                if #values >= COMPLETION_CAP then break end
            end
        end

        -- 2) 7TV — append in upstream popularity order, dedup against own.
        --    Cache-first; kick off a fresh fetch in the background so the next
        --    keystroke can include results.
        if #values < COMPLETION_CAP and string.len(q) >= SEARCH_MIN_CHARS and is_sane_search_query(q) then
            kick_off_7tv_search(q)
            local hit = search_cache[q]
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

        -- hide_others=false so chatterino's own twitch + 7tv-from-bttv-channel
        -- (if user has another plugin / native) suggestions still surface.
        return { hide_others = false, values = values }
    end
)

-- ----- commands -----

c2.register_command("/hsrefresh", function(ctx)
    local acc = c2.current_account()
    if not acc or not acc:is_valid() or acc:is_anon() then
        ctx.channel:add_system_message("[heatsync] no signed-in twitch account; can't refresh")
        return
    end
    local login = acc:login()
    last_login = login
    refresh_inventory(login)
    ctx.channel:add_system_message("[heatsync] refreshing inventory for " .. login .. "…")
end)

c2.register_command("/hsemotes", function(ctx)
    local own_count = 0
    for _ in pairs(emote_map) do own_count = own_count + 1 end
    local cached_queries = 0
    for _ in pairs(search_cache) do cached_queries = cached_queries + 1 end
    if own_count == 0 then
        ctx.channel:add_system_message("[heatsync] inventory not loaded — try /hsrefresh")
        return
    end
    ctx.channel:add_system_message(
        "[heatsync] " .. tostring(own_count) .. " inventory emotes · " ..
        tostring(cached_queries) .. " 7tv search queries cached"
    )
end)

-- ----- boot -----
do
    local ok, acc = pcall(c2.current_account)
    if ok and acc and acc:is_valid() and not acc:is_anon() then
        last_login = acc:login()
        refresh_inventory(last_login)
    else
        log_warn("no signed-in twitch account at boot; user can run /hsrefresh later")
    end
end
