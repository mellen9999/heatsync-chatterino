-- which exact emote is a block aimed at? blocks key by the emote's content hash
-- (the key site, extension and server share), never by name. a right-click knows
-- the owner's login; a typed name must resolve to ONE emote or we block nothing.
local inventory = require("inventory")
local senders = require("senders")
local store = require("store")

local M = {}

-- returns hash, or nil + "unknown" | "ambiguous"
function M.resolve(name, login)
    if type(name) ~= "string" then return nil, "unknown" end
    if type(login) == "string" then
        local h = senders.find_hash(name, login)
        if h then return h end
        local row = login == inventory.login and inventory.map and inventory.map[name]
        if row and row.hash then return row.hash end
    end
    local set, n, only = senders.hashes_for(name), 0, nil
    local own = inventory.map and inventory.map[name]
    if own and own.hash then set[own.hash] = true end
    for h in pairs(set) do n = n + 1; only = h end
    if n == 1 then return only end
    return nil, n == 0 and "unknown" or "ambiguous"
end

-- legacy by-name blocks → hashes wherever the name is unambiguous right now
function M.migrate()
    return store.migrate(function(name) return (M.resolve(name)) end)
end

return M
