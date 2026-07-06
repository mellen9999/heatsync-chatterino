-- recently-used emotes, learned from your OWN sent messages and persisted to
-- the plugin data dir. surfaces at the top of the /hsemotes menu so the emotes
-- you actually use are one click away — the thing a native emote picker does
-- that raw tab-complete can't.
--
-- we can't observe click-to-insert (chatterino handles InsertText links
-- itself, no callback), so usage is learned the one way the plugin CAN see it:
-- render.do_process scans your own outgoing messages and calls note() for any
-- word that resolves to an inventory emote.
local net = require("net")
local inventory = require("inventory")

local M = {}

local FILE = "recents.txt"
local MAX = 48
local list = {} -- most-recent-first emote names

function M.load()
    local raw = net.read_data(FILE)
    if type(raw) ~= "string" then return end
    for name in string.gmatch(raw, "[^\r\n]+") do
        local t = string.match(name, "^%s*(.-)%s*$")
        if t ~= "" and #list < MAX then list[#list + 1] = t end
    end
end

local function persist()
    net.write_data(FILE, table.concat(list, "\n"))
end

local function bump(name)
    for i, n in ipairs(list) do
        if n == name then table.remove(list, i); break end
    end
    table.insert(list, 1, name)
    while #list > MAX do table.remove(list) end
end

-- scan one of your sent messages; move any inventory emote it used to the
-- front. persists once per message (only if something actually changed).
function M.note(text)
    if type(text) ~= "string" then return end
    local changed = false
    local touched = {}
    for word in string.gmatch(text, "%S+") do
        if not touched[word] and inventory.resolve(word) then
            bump(word)
            touched[word] = true
            changed = true
        end
    end
    if changed then persist() end
end

-- recent names still present in the current inventory (emotes get removed /
-- renamed; a stale recents.txt must never surface a dead name).
function M.names()
    local out = {}
    for _, n in ipairs(list) do
        if inventory.resolve(n) then out[#out + 1] = n end
    end
    return out
end

return M
