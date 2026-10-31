-- pulls your heatsync account's lists into the places the plugin already looks:
--   /api/cli/mutes         → mutes.set_account   (collapse through the community-mute path)
--   /api/cli/emote-blocks  → store.set_hash_blocks (hidden in render + tab-complete, by hash)
--   /api/cli/mention-rules → mention.set_rules   (highlights on merged kick/youtube lines)
--   /api/cli/following     → a small id set for the card's "following"
-- one pull on login/boot, then every ~5 minutes. read-only except the helpers the
-- commands call after a change. everything is shape-checked: a wrong-shaped answer
-- is logged and skipped, never trusted.
local net = require("net")
local account = require("account")
local mutes = require("mutes")
local store = require("store")
local mention = require("mention")

local M = {}

local MUTES_MAX = 2000
local BLOCKS_MAX = 5000
local FOLLOW_TTL_S = 300

M.on_mutes_changed = nil -- fn(): render's back-pass over open channels

local counts = { mutes = 0, blocks = 0, rules = 0, regex_skipped = 0 }
local last_v = nil
local last_sig = nil
local told_scope = false
local following = nil -- { ids = {["123"]=true}, ts = net.now() }
local pulling = false

function M.counts() return counts.mutes, counts.blocks, counts.rules, counts.regex_skipped end

local function scope_hint(status, ebody)
    if status == 403 and not told_scope then
        told_scope = true
        require("cmdutil").notify(account.explain(status, ebody))
    end
end

-- ----- mutes -----
local function apply_mutes(list, v, force)
    local rows = {}
    for i = 1, math.min(#list, MUTES_MAX) do
        local e = list[i]
        if type(e) == "table" and type(e.username) == "string" then
            rows[#rows + 1] = string.lower(e.username) .. "\1" .. tostring(type(e.platform) == "string" and e.platform or "")
                .. "\1" .. tostring(e.expires_at or "")
        end
    end
    table.sort(rows)
    local sig = table.concat(rows, "\n")
    if not force and sig == last_sig and (v == nil or v == last_v) then return false end
    last_v, last_sig = v, sig
    local set = mutes.parse(list, net.wall_ms(), MUTES_MAX)
    mutes.set_account(set or nil)
    counts.mutes = #rows
    if M.on_mutes_changed then pcall(M.on_mutes_changed) end
    return true
end

function M.pull_mutes(force, done)
    account.request("Get", "/mutes", nil, function(data, err, status, ebody)
        local ok = type(data) == "table" and type(data.mutes) == "table"
        if ok then
            local v = data.v
            if type(v) ~= "number" and type(v) ~= "string" then v = nil end
            apply_mutes(data.mutes, v, force)
        else
            scope_hint(status, ebody)
            net.log_warn("account mutes pull failed: " .. tostring(status or err))
        end
        if done then done(ok, status, ebody, err) end
    end)
end

-- a mute/unmute just succeeded: show it now, the pull confirms it
function M.mute_changed()
    M.pull_mutes(true)
end

-- ----- emote blocks -----
function M.pull_blocks(done)
    account.request("Get", "/emote-blocks", nil, function(data, err, status, ebody)
        local ok = type(data) == "table" and type(data.blocked_emotes) == "table"
        if ok then
            local set, n = {}, 0
            for i = 1, math.min(#data.blocked_emotes, BLOCKS_MAX) do
                local row = data.blocked_emotes[i]
                local h = net.safe_hash(type(row) == "table" and row.hash or (type(row) == "string" and row or nil))
                if h then set[h] = true; n = n + 1 end
            end
            store.set_hash_blocks(set)
            counts.blocks = n
        else
            scope_hint(status, ebody)
            net.log_warn("account emote blocks pull failed: " .. tostring(status or err))
        end
        if done then done(ok, status, ebody, err) end
    end)
end

-- ----- mention rules -----
function M.pull_rules(done)
    account.request("Get", "/mention-rules", nil, function(data, err, status, ebody)
        local ok = type(data) == "table" and type(data.rules) == "table"
        if ok then
            counts.rules = mention.set_rules(data.rules)
            local _, skipped = mention.rule_count()
            counts.regex_skipped = skipped
        else
            scope_hint(status, ebody)
            net.log_warn("account mention rules pull failed: " .. tostring(status or err))
        end
        if done then done(ok, status, ebody, err) end
    end)
end

-- ----- following -----
local function follow_id(v)
    if type(v) == "number" and v == v and v > 0 and v < 1e15 then return string.format("%d", math.floor(v)) end
    if type(v) == "string" and string.match(v, "^%d+$") and #v <= 15 then return v end
    return nil
end

local LIST_KEYS = { "following", "follows", "users", "items", "data" }
local ROW_KEYS = { "id", "user_id", "followed_id", "followee_id", "target_id" }

-- GET /following → a set of heatsync user ids, from whichever sensible shape
-- the list comes in (a bare array, or an array under a known key; ids bare or in
-- a row). nil when nothing list-shaped is there.
function M.parse_following(data)
    local list = nil
    if type(data) == "table" then
        if data[1] ~= nil then list = data end
        for _, k in ipairs(LIST_KEYS) do
            if list == nil and type(data[k]) == "table" then list = data[k] end
        end
    end
    if type(list) ~= "table" then return nil end
    local ids = {}
    for i = 1, math.min(#list, 20000) do
        local row = list[i]
        local id = follow_id(row)
        if not id and type(row) == "table" then
            for _, k in ipairs(ROW_KEYS) do
                id = id or follow_id(row[k])
            end
        end
        if id then ids[id] = true end
    end
    return ids
end

-- cb(set | nil, status, ebody): the cached set while fresh, else one GET
function M.get_following(cb)
    if following and (net.now() - following.ts) < FOLLOW_TTL_S then return cb(following.ids) end
    account.request("Get", "/following", nil, function(data, err, status, ebody)
        local ids = M.parse_following(data)
        if ids then following = { ids = ids, ts = net.now() } end
        cb(ids, status, ebody, err)
    end)
end

function M.set_following(id, on)
    id = follow_id(id)
    if not id or not following then return end
    following.ids[id] = on and true or nil
end

-- ----- orchestration -----
function M.pull_all(force)
    if pulling or not account.logged_in() or not account.has_scope("account") then return end
    pulling = true
    -- one after another: three small requests, never a burst
    M.pull_mutes(force, function()
        M.pull_blocks(function()
            M.pull_rules(function() pulling = false end)
        end)
    end)
end

-- the slow beat (init arms it every ~5 min)
function M.tick()
    pcall(account.tick)
    M.pull_all(false)
end

function M.clear()
    mutes.set_account(nil)
    store.set_hash_blocks({})
    mention.set_rules({})
    counts = { mutes = 0, blocks = 0, rules = 0, regex_skipped = 0 }
    last_v, last_sig, following, pulling, told_scope = nil, nil, nil, false, false
    if M.on_mutes_changed then pcall(M.on_mutes_changed) end
end

function M.summary()
    if not account.logged_in() then return nil end
    return tostring(counts.mutes) .. " mutes · " .. tostring(counts.blocks) .. " emote blocks · " ..
        tostring(counts.rules) .. " mention rules" ..
        (counts.regex_skipped > 0 and (" (" .. tostring(counts.regex_skipped) .. " regex skipped)") or "")
end

account.on_login(function() told_scope = false; M.pull_all(true) end)
account.on_logout(M.clear)

return M
