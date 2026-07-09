-- persisted plugin config: local emote block list + flame-marker toggle.
-- kept out of the render/net hot paths as a tiny single-purpose module.
--
-- block is LOCAL-ONLY by design: the plugin connects to heatsync.org
-- anonymously and every server block endpoint requires a bearer token, so a
-- block can't sync to your heatsync account. this matches how heatsync itself
-- models blocks anyway — a viewer-side render preference (the server never
-- filters blocked emotes out of the inventory it ships).
local net = require("net")

local M = {}

local BLOCKS_FILE = "blocks.txt"  -- newline-separated emote names
local FLAME_FILE = "flame.txt"    -- "0" = off, anything else = on
local ARCHIVE_FILE = "archive.txt" -- "0" = relay off (ON by default, opt-out)
local AUTOMC_FILE = "automulti.txt" -- "0" = auto-multichat off (ON by default)
local BADGES_FILE = "badges.txt"   -- "1" = badges on (OFF by default, opt-in)
local LIVE_FILE = "live.txt"       -- "1" = live-status on (OFF by default, opt-in)

-- blocked[name] = true
local blocked = {}
local flame_on = true
local archive_on = true -- default ON (opt-out) — archives public twitch chat
local automc_on = true -- default ON (opt-out) — auto-merges a stream's kick/yt chat when publicly linked
local badges_on = false
local live_on = false -- default OFF (opt-in) — go-live lines for linked kick/yt sources

-- exact toggle read: the whole file must BE the value (whitespace-tolerant),
-- not merely contain it — an unanchored string.match("0") would misfire on any
-- future/partial/corrupt content that happens to include a "0" somewhere.
local function file_is(filename, want)
    local raw = net.read_data(filename)
    return type(raw) == "string" and string.match(raw, "^%s*(.-)%s*$") == want
end

-- ----- load on boot -----
local function load()
    local raw = net.read_data(BLOCKS_FILE)
    if type(raw) == "string" then
        for name in string.gmatch(raw, "[^\r\n]+") do
            local trimmed = string.match(name, "^%s*(.-)%s*$")
            if trimmed ~= "" then blocked[trimmed] = true end
        end
    end
    if file_is(FLAME_FILE, "0") then flame_on = false end
    -- default ON: only an explicit "0" on disk turns these off
    if file_is(ARCHIVE_FILE, "0") then archive_on = false end
    if file_is(AUTOMC_FILE, "0") then automc_on = false end
    -- default OFF (opt-in): only an explicit "1" turns these on
    if file_is(BADGES_FILE, "1") then badges_on = true end
    if file_is(LIVE_FILE, "1") then live_on = true end
end

local function persist_blocks()
    local names = {}
    for name in pairs(blocked) do names[#names + 1] = name end
    table.sort(names)
    net.write_data(BLOCKS_FILE, table.concat(names, "\n"))
end

-- ----- blocks -----
function M.is_blocked(name)
    return blocked[name] == true
end

function M.block(name)
    if type(name) ~= "string" or name == "" then return false end
    if blocked[name] then return false end
    blocked[name] = true
    persist_blocks()
    return true
end

function M.unblock(name)
    if not blocked[name] then return false end
    blocked[name] = nil
    persist_blocks()
    return true
end

function M.blocklist()
    local names = {}
    for name in pairs(blocked) do names[#names + 1] = name end
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

-- ----- archive relay toggle (default ON, opt-out) -----
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

-- ----- badges toggle (default off, opt-in) -----
function M.badges_enabled()
    return badges_on
end

function M.set_badges(on)
    badges_on = on and true or false
    net.write_data(BADGES_FILE, badges_on and "1" or "0")
end

-- ----- live-status toggle (default off, opt-in) -----
function M.live_enabled()
    return live_on
end

function M.set_live(on)
    live_on = on and true or false
    net.write_data(LIVE_FILE, live_on and "1" or "0")
end

load()

return M
