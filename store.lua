-- persisted plugin config: local emote block list + flame-marker toggle.
-- kept out of the render/net hot paths as a tiny single-purpose module.
--
-- blocks are LOCAL by name (blocks.txt). when you log in (opt-in, account.lua) the
-- account's blocks — which are keyed by emote HASH — are merged in as an in-memory
-- hash set: an emote whose row carries a blocked hash is hidden in render and
-- tab-complete exactly like a name block. the hash set is never written to disk
-- (it is re-pulled on login and every few minutes); a viewer-side render
-- preference either way — the server never filters blocked emotes out of what
-- it ships.
local net = require("net")

local M = {}

local BLOCKS_FILE = "blocks.txt"  -- "#h <hash> <name>" = exact-emote block; bare "name" = legacy
local FLAME_FILE = "flame.txt"    -- "0" = off, anything else = on
local ARCHIVE_FILE = "archive.txt" -- "0" = channel-signal off (ON by default, opt-out)
local AUTOMC_FILE = "automulti.txt" -- "0" = auto-multichat off (ON by default)
local LIVE_FILE = "live.txt"       -- "1" = live-status on (OFF by default, opt-in)

local SPIKES_FILE = "spikes.txt"   -- "1" = moment spikes on (OFF by default, opt-in)
local PIN_FILE = "pin.txt"         -- "0" = pinned message off (ON by default, opt-out)

-- local blocks key by the exact emote (content hash, same key site/ext/server use):
-- local_hash[hash] = display name. `blocked[name]` is LEGACY only (pre-hash lines in
-- blocks.txt): still honoured until migrated to a hash (store.migrate) or dropped
-- by /hsunblock. file: "name" = legacy line, "#h <hash> <name>" = hash line.
local blocked = {}
local local_hash = {}
-- account blocks: hash_blocked[hash] = true (in memory only, see header)
local hash_blocked = {}
local flame_on = true
local archive_on = true -- default ON (opt-out) — tells heatsync which public
                         -- twitch channels you're watching so it archives them
                         -- itself; no message content ever leaves the plugin
local automc_on = true -- default ON (opt-out) — auto-merges a stream's kick/yt chat when publicly linked
local pin_on = true -- default ON (opt-out) — heatsync's own pinned message, shown to every heatsync viewer
local spikes_on = false -- default OFF (opt-in) — 🔥 lines when a chat you have open spikes
local live_on = false -- default OFF (opt-in) — go-live lines for linked kick/yt sources

-- exact toggle read: the whole file must BE the value (whitespace-tolerant),
-- not merely contain it — an unanchored string.match("0") would misfire on any
-- future/partial/corrupt content that happens to include a "0" somewhere.
local function file_is(filename, want)
    local raw = net.read_data(filename)
    return type(raw) == "string" and string.match(raw, "^%s*(.-)%s*$") == want
end

local function parse_blocks(raw)
    for name in string.gmatch(raw, "[^\r\n]+") do
        local trimmed = string.match(name, "^%s*(.-)%s*$")
        local h, n = string.match(trimmed, "^#h (%S+) (%S+)$")
        if h and net.safe_hash(h) then local_hash[h] = n
        elseif trimmed ~= "" and string.sub(trimmed, 1, 1) ~= "#" then blocked[trimmed] = true end
    end
end

-- ----- load on boot -----
local function load()
    local raw = net.read_data(BLOCKS_FILE)
    if type(raw) == "string" then parse_blocks(raw) end
    if file_is(FLAME_FILE, "0") then flame_on = false end
    -- default ON: only an explicit "0" on disk turns these off
    if file_is(ARCHIVE_FILE, "0") then archive_on = false end
    if file_is(AUTOMC_FILE, "0") then automc_on = false end
    if file_is(PIN_FILE, "0") then pin_on = false end
    -- default OFF (opt-in): only an explicit "1" turns these on
    if file_is(LIVE_FILE, "1") then live_on = true end
    if file_is(SPIKES_FILE, "1") then spikes_on = true end
end

-- re-read blocks.txt (also how tests stage a pre-hash legacy file)
function M.reload_blocks()
    blocked, local_hash = {}, {}
    local raw = net.read_data(BLOCKS_FILE)
    if type(raw) == "string" then parse_blocks(raw) end
end

local function persist_blocks()
    local names = {}
    for name in pairs(blocked) do names[#names + 1] = name end
    for h, n in pairs(local_hash) do names[#names + 1] = "#h " .. h .. " " .. n end
    table.sort(names)
    net.write_data(BLOCKS_FILE, table.concat(names, "\n"))
end

-- ----- blocks -----
-- `hash` (optional): the emote row's content hash — an account block hides it
-- whatever name it goes by.
function M.is_blocked(name, hash)
    if blocked[name] == true then return true end
    return hash ~= nil and (hash_blocked[hash] == true or local_hash[hash] ~= nil)
end

-- local hash blocks (the exact emote). read-only set for the completion hot path.
function M.local_hash_set() return local_hash end
function M.is_local_hash(h) return h ~= nil and local_hash[h] ~= nil end

function M.block_hash(hash, name)
    if not net.safe_hash(hash) or type(name) ~= "string" or not string.match(name, "^%S+$") then return false end
    if local_hash[hash] then return false end
    local_hash[hash] = name
    blocked[name] = nil -- a legacy by-name entry for it is superseded
    persist_blocks()
    return true
end

function M.unblock_hash(hash)
    if not local_hash[hash] then return false end
    local_hash[hash] = nil
    persist_blocks()
    return true
end

-- legacy name entries: move each to a hash when `resolve(name)` can say which
-- exact emote it was (nil = unknown/ambiguous → stays honoured by name). returns
-- how many moved.
function M.migrate(resolve)
    local moved = 0
    for name in pairs(blocked) do
        local ok, h = pcall(resolve, name)
        if ok and net.safe_hash(h) then
            local_hash[h] = name
            blocked[name] = nil
            moved = moved + 1
        end
    end
    if moved > 0 then persist_blocks() end
    return moved
end

function M.is_legacy_blocked(name) return blocked[name] == true end

-- replace the account-block hash set (login / periodic sync / logout = empty)
function M.set_hash_blocks(set)
    local out = {}
    if type(set) == "table" then
        for h in pairs(set) do
            if type(h) == "string" then out[h] = true end
        end
    end
    hash_blocked = out
end

function M.add_hash_block(h) if type(h) == "string" then hash_blocked[h] = true end end
function M.remove_hash_block(h) if type(h) == "string" then hash_blocked[h] = nil end end
function M.is_hash_blocked(h) return h ~= nil and hash_blocked[h] == true end

-- read-only view for the completion hot path (iterate/index, never mutate)
function M.hash_blocked_set() return hash_blocked end

-- drops a legacy by-name entry (the only name-keyed removal left)
function M.unblock(name)
    if not blocked[name] then return false end
    blocked[name] = nil
    persist_blocks()
    return true
end

function M.blocklist()
    local names = {}
    for name in pairs(blocked) do names[#names + 1] = name end
    for h, n in pairs(local_hash) do names[#names + 1] = n .. " (" .. string.sub(h, 1, 8) .. ")" end
    table.sort(names)
    return names
end

-- read-only view of the blocked set for the completion HOT PATH — no array
-- alloc + no table.sort per keystroke (which blocklist() does). callers iterate
-- with pairs() for membership and must NOT mutate the returned table.
function M.blocked_set()
    return blocked
end

-- ----- flame toggle -----
function M.flame_enabled()
    return flame_on
end

function M.set_flame(on)
    flame_on = on and true or false
    net.write_data(FLAME_FILE, flame_on and "1" or "0")
end

-- ----- archive channel-signal toggle (default ON, opt-out) -----
function M.archive_enabled()
    return archive_on
end

function M.set_archive(on)
    archive_on = on and true or false
    net.write_data(ARCHIVE_FILE, archive_on and "1" or "0")
end

-- ----- auto-multichat toggle (default ON, opt-out) -----
function M.auto_multichat_enabled()
    return automc_on
end

function M.set_auto_multichat(on)
    automc_on = on and true or false
    net.write_data(AUTOMC_FILE, automc_on and "1" or "0")
end

-- ----- live-status toggle (default off, opt-in) -----
function M.live_enabled()
    return live_on
end

function M.set_live(on)
    live_on = on and true or false
    net.write_data(LIVE_FILE, live_on and "1" or "0")
end

-- ----- pinned-message toggle (default ON, opt-out) -----
function M.pin_enabled()
    return pin_on
end

function M.set_pin(on)
    pin_on = on and true or false
    net.write_data(PIN_FILE, pin_on and "1" or "0")
end

-- ----- moment-spike toggle (default off, opt-in) -----
function M.spikes_enabled()
    return spikes_on
end

function M.set_spikes(on)
    spikes_on = on and true or false
    net.write_data(SPIKES_FILE, spikes_on and "1" or "0")
end

load()

-- ----- on-by-default flags (opt-out) -----
-- same on-disk contract as the toggles above (only an explicit "0" turns one
-- off), as a factory because these four are identical: heat bars, sub-flair
-- badges, heatsync name colors, and kick/youtube history backfill.
local function flag(file)
    local on = not file_is(file, "0")
    return function() return on end, function(v)
        on = v and true or false
        net.write_data(file, on and "1" or "0")
    end
end
M.heat_enabled, M.set_heat = flag("heat.txt")
M.flair_enabled, M.set_flair = flag("flair-badges.txt")
M.colors_enabled, M.set_colors = flag("namecolors.txt")
M.backfill_enabled, M.set_backfill = flag("backfill.txt")
M.mentions_enabled, M.set_mentions = flag("mentions.txt")

-- ----- opt-in flags (off by default) -----
-- the mirror of flag(): only an explicit "1" on disk turns one on. inline
-- images are opt-in because every new image url costs heatsync a moderation
-- scan, and they're other people's images landing in your chat.
local function optin(file)
    local on = file_is(file, "1")
    return function() return on end, function(v)
        on = v and true or false
        net.write_data(file, on and "1" or "0")
    end
end
M.images_enabled, M.set_images = optin("images.txt")
M.mutes_enabled, M.set_mutes = optin("mutes.txt")
M.previews_enabled, M.set_previews = optin("previews.txt")

return M
