-- heatsync chatterino plugin
--
-- Mirrors the browser extension's tab-completion against your heatsync.org
-- emote inventory. Type ":pog" → suggests "PogChamp" if it's in your
-- inventory; pasting it into chat means any other heatsync-extension user
-- sees it rendered. Chatterino itself shows the literal name (no local
-- image render — emote image injection is outside the plugin API surface).
--
-- Endpoints (public, CORS-open):
--   GET /api/profile/<twitch_login>        → resolves login → numeric user id
--   GET /api/users/<userId>/emotes         → returns inventory rows
--
-- The inventory is refreshed once per account on plugin load + on /hsrefresh.
-- No write actions, no auth — read-only.

local HEATSYNC_ORIGIN = "https://heatsync.org"

local json = require("chatterino.json")

-- emote_name (string) → emote_url (string)
local emote_map = {}
-- sorted lowercase names for prefix completion
local emote_names_lower = {}
local refreshing = false
local last_login = nil

local function log_info(msg)
    c2.log(c2.LogLevel.Info, "[heatsync] " .. msg)
end

local function log_warn(msg)
    c2.log(c2.LogLevel.Warning, "[heatsync] " .. msg)
end

-- Rebuild the sorted lowercase index from emote_map. Called whenever
-- emote_map is overwritten by a refresh.
local function rebuild_index()
    emote_names_lower = {}
    for name, _ in pairs(emote_map) do
        table.insert(emote_names_lower, { name = name, lower = string.lower(name) })
    end
    table.sort(emote_names_lower, function(a, b)
        return a.lower < b.lower
    end)
end

-- Best-effort JSON parse via Chatterino's bundled chatterino.json module.
-- Throws on malformed input → we pcall it.
local function safe_json_parse(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, parsed = pcall(json.parse, raw)
    if not ok then return nil end
    return parsed
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

    -- 1) resolve login → numeric user id via /api/profile/<login>
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

        -- 2) fetch inventory via /api/users/<id>/emotes
        local emotes_url = HEATSYNC_ORIGIN .. "/api/users/" .. tostring(uid) .. "/emotes"
        local emotes_req = c2.HTTPRequest.create(c2.HTTPMethod.Get, emotes_url)
        emotes_req:set_timeout(10000)
        emotes_req:set_header("Accept", "application/json")
        emotes_req:on_error(function(res2)
            refreshing = false
            log_warn("emote fetch failed: " .. tostring(res2:error()))
        end)
        emotes_req:on_success(function(res2)
            local emote_body = res2:data()
            local payload = safe_json_parse(emote_body)
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

-- ----- completion hook -----

local function strip_leading_colon(query)
    if string.sub(query, 1, 1) == ":" then
        return string.sub(query, 2), true
    end
    return query, false
end

c2.register_callback(
    c2.EventType.CompletionRequested,
    function(event)
        local query = event.query or ""
        if query == "" then
            return { hide_others = false, values = {} }
        end
        -- Strip leading ":" so both ":pog" and "pog" work; users in BTTV-style
        -- input habit will type plain prefix.
        local raw, had_colon = strip_leading_colon(query)
        local q = string.lower(raw)
        if string.len(q) < 1 then
            return { hide_others = false, values = {} }
        end
        local values = {}
        local cap = 25 -- chatterino's completion list stays readable around this
        for _, item in ipairs(emote_names_lower) do
            if string.sub(item.lower, 1, string.len(q)) == q then
                table.insert(values, item.name)
                if #values >= cap then break end
            end
        end
        -- hide_others=false lets twitch + 7tv suggestions still appear; we
        -- additively contribute our inventory.
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
    local count = 0
    for _ in pairs(emote_map) do count = count + 1 end
    if count == 0 then
        ctx.channel:add_system_message("[heatsync] inventory not loaded — try /hsrefresh")
        return
    end
    ctx.channel:add_system_message("[heatsync] " .. tostring(count) .. " emotes in inventory. tab-complete by name.")
end)

-- ----- boot -----
-- Resolve current account on load + kick off a refresh.
do
    local ok, acc = pcall(c2.current_account)
    if ok and acc and acc:is_valid() and not acc:is_anon() then
        last_login = acc:login()
        refresh_inventory(last_login)
    else
        log_warn("no signed-in twitch account at boot; user can run /hsrefresh later")
    end
end
