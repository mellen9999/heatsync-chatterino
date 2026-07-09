-- own heatsync.org emote inventory: fetch, prefix index, live-refresh hooks.
--
-- endpoints (public, no auth):
--   GET /api/profile/<twitch_login>  → resolve login → numeric user id
--   GET /api/users/<userId>/emotes   → inventory rows (usage_count, width/height)
local net = require("net")

local M = {
    login = nil,          -- twitch login the current map belongs to
    -- map[name] = { url, w, h, zw } — w/h are source pixel dims when known
    map = {},
    -- sorted prefix index: [{ name, lower, usage }] usage desc, then alpha
    index = {},
    on_change = nil,      -- fn() called after the map is rebuilt
}

local refreshing = false
local refresh_queued = false
local last_refresh_ts = 0
local REFRESH_MIN_GAP_S = 1

-- boot-retry state, consumed by init's login loop (and the t0 completion
-- piggyback): a transport failure before the first successful load is worth
-- one retry; a "no inventory yet" business response is not.
M.boot_failed_at = nil
M.boot_retry_used = false

local function rebuild_index(entries)
    M.index = {}
    for _, e in ipairs(entries) do
        table.insert(M.index, {
            name = e.name,
            lower = string.lower(e.name),
            usage = e.usage or 0,
        })
    end
    table.sort(M.index, function(a, b)
        if a.usage ~= b.usage then return a.usage > b.usage end
        return a.lower < b.lower
    end)
end

-- inventory id can be a number (live users) or a string (shadow users with
-- "u_<login>" prefix). /api/users/:id only accepts numeric ids, so shadow
-- users bail loudly — they have no inventory to fetch yet.
local function is_real_numeric_id(uid)
    if type(uid) == "number" then return uid > 0 end
    if type(uid) == "string" and string.match(uid, "^%d+$") then return true end
    return false
end

local function note_possible_boot_failure()
    if not M.boot_retry_used and next(M.map) == nil then
        M.boot_failed_at = net.now()
    end
end

-- a real inventory is hundreds of emotes; cap the rows we'll build a map + sort
-- from so a buggy/compromised response can't blow memory or freeze the sort.
local MAX_INVENTORY_ROWS = 5000

local function apply_rows(rows, login)
    local new_map = {}
    local entries = {}
    local count = 0
    for i, e in ipairs(rows) do
        -- cap on the RAW index, not the valid count: a flood of malformed rows
        -- (e.g. [1,1,1,...] that all fail parse) would otherwise never advance
        -- `count` and iterate the whole array, stalling this boot-critical path.
        if i > MAX_INVENTORY_ROWS then
            net.log_warn("inventory response exceeded " .. MAX_INVENTORY_ROWS .. " rows; truncated")
            break
        end
        local rec = net.parse_emote_row(e)
        if rec then
            new_map[rec.name] = { url = rec.url, w = rec.w, h = rec.h, zw = rec.zw }
            table.insert(entries, {
                name = rec.name,
                usage = tonumber(type(e) == "table" and (e.usage_count or e.uses) or 0) or 0,
            })
            count = count + 1
        end
    end
    M.map = new_map
    rebuild_index(entries)
    net.log_info("loaded " .. tostring(count) .. " emotes for " .. login)
    if M.on_change then pcall(M.on_change) end
end

function M.refresh(login)
    if not login or login == "" then
        net.log_warn("no account login; skipping refresh")
        return
    end
    -- set M.login FIRST: on an account switch while a previous refresh is
    -- still in flight, the early return below must not leave M.login pointing
    -- at the old account (its done() would refetch the wrong inventory). the
    -- in-flight callbacks close over their own `login` param, so this is safe.
    M.login = login
    if refreshing then
        refresh_queued = true
        return
    end
    refreshing = true
    last_refresh_ts = net.now()
    net.log_info("refreshing inventory for " .. login)

    local function done()
        refreshing = false
        if refresh_queued then
            refresh_queued = false
            -- coalesced ws deltas that arrived mid-flight: go again
            M.refresh(M.login)
        end
    end

    local profile_url = net.ORIGIN .. "/api/profile/" .. net.percent_encode(login)
    net.get_json(profile_url, 10000, function(data, err)
        if not data then
            net.log_warn("profile fetch failed: " .. tostring(err))
            note_possible_boot_failure()
            done()
            return
        end
        -- guard the shape: a non-table profile (e.g. a "not found" placeholder)
        -- must degrade, not throw in the boot-critical refresh path
        local prof = type(data.profile) == "table" and data.profile or nil
        local uid = prof and prof.id
        if not is_real_numeric_id(uid) then
            net.log_warn("no heatsync inventory yet for " .. login ..
                " (profile id missing or shadow). sign in at heatsync.org once.")
            done()
            return
        end
        local emotes_url = net.ORIGIN .. "/api/users/" .. tostring(uid) .. "/emotes"
        net.get_json(emotes_url, 10000, function(payload, err2)
            if not payload then
                net.log_warn("emote fetch failed: " .. tostring(err2))
                note_possible_boot_failure()
                done()
                return
            end
            local rows = payload.emotes or payload.data or payload.items
            if type(rows) ~= "table" then
                net.log_warn("emote response has no recognizable list field")
                done()
                return
            end
            apply_rows(rows, login)
            done()
        end)
    end)
end

-- ws delta events (emote:added / emote:removed / emotes:refresh) all funnel
-- here: one debounced full re-fetch keeps every path consistent (renames,
-- undo, set swaps) instead of maintaining three mutation codepaths.
function M.refresh_soon()
    if not M.login then return end
    if refreshing then
        refresh_queued = true
        return
    end
    if net.now() - last_refresh_ts < REFRESH_MIN_GAP_S then
        refresh_queued = true
        -- picked up by the in-flight done() or the next timer tick
        return
    end
    M.refresh(M.login)
end

-- called by init's timer loop to drain a queued refresh that arrived inside
-- the min-gap window with nothing in flight to chain off
function M.drain_queued()
    if refresh_queued and not refreshing and M.login then
        refresh_queued = false
        M.refresh(M.login)
    end
end

function M.resolve(name)
    return M.map[name]
end

function M.count()
    local n = 0
    for _ in pairs(M.map) do n = n + 1 end
    return n
end

-- prefix-match into values (respecting seen + cap). index is pre-sorted
-- usage desc then alpha, so results come out in that order.
function M.match_prefix(q, qlen, values, seen, cap)
    for _, item in ipairs(M.index) do
        -- find(...,1,true) is a plain-text anchored match — no per-entry substring
        -- allocation like string.sub did, on every keystroke over the whole index.
        if string.find(item.lower, q, 1, true) == 1 then
            if not seen[item.name] then
                table.insert(values, item.name)
                seen[item.name] = true
            end
            if #values >= cap then return end
        end
    end
end

return M
