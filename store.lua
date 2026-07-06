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
local ARCHIVE_FILE = "archive.txt" -- "1" = relay on (OFF by default, opt-in)
local AUTOMC_FILE = "automulti.txt" -- "1" = auto-multichat on (OFF by default)

-- blocked[name] = true
local blocked = {}
local flame_on = true
local archive_on = false
local automc_on = false

-- ----- load on boot -----
local function load()
    local raw = net.read_data(BLOCKS_FILE)
    if type(raw) == "string" then
        for name in string.gmatch(raw, "[^\r\n]+") do
            local trimmed = string.match(name, "^%s*(.-)%s*$")
            if trimmed ~= "" then blocked[trimmed] = true end
        end
    end
    local flame = net.read_data(FLAME_FILE)
    if type(flame) == "string" and string.match(flame, "0") then
        flame_on = false
    end
    local arch = net.read_data(ARCHIVE_FILE)
    if type(arch) == "string" and string.match(arch, "1") then
        archive_on = true
    end
    local am = net.read_data(AUTOMC_FILE)
    if type(am) == "string" and string.match(am, "1") then
        automc_on = true
    end
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

-- ----- flame toggle -----
function M.flame_enabled()
    return flame_on
end

function M.set_flame(on)
    flame_on = on and true or false
    net.write_data(FLAME_FILE, flame_on and "1" or "0")
end

-- ----- archive relay toggle (default off, opt-in) -----
function M.archive_enabled()
    return archive_on
end

function M.set_archive(on)
    archive_on = on and true or false
    net.write_data(ARCHIVE_FILE, archive_on and "1" or "0")
end

-- ----- auto-multichat toggle (default off) -----
function M.auto_multichat_enabled()
    return automc_on
end

function M.set_auto_multichat(on)
    automc_on = on and true or false
    net.write_data(AUTOMC_FILE, automc_on and "1" or "0")
end

load()

return M
