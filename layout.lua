-- /m/<layout> share-link grammar: parse + build. pure (no c2, no os), mirrors
-- heatsync's server/lib/multichat-layout.ts so a link round-trips both ways.
--   layout := tab ('+' tab)*   tab := pc (',' pc)*   pc := ('t'|'k'|'y') ':' name
local M = {}

M.MAX_TABS = 8
M.MAX_LEN = 400
M.ORIGIN = "https://heatsync.org"

local function name_ok(s) return #s >= 1 and #s <= 30 and string.match(s, "^[a-z0-9_-]+$") ~= nil end
local function yt_ok(s) return #s >= 1 and #s <= 40 and string.match(s, "^[a-z0-9_.-]+$") ~= nil end
local function uc_ok(s) return #s == 24 and string.match(s, "^UC[%w_-]+$") ~= nil end

-- accepts a bare layout, "/m/<layout>", or a full heatsync.org/m/<layout> url
function M.extract(input)
    if type(input) ~= "string" then return "" end
    local s = input:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("[?#].*$", "")
    local tail = string.match(s, "/m/([^/]*)$")
    return tail or s
end

-- total: never errors; junk segments dropped, dupes dropped, capped
-- returns { { twitch=, kick=, youtube= }, ... }
function M.parse(layout)
    local tabs = {}
    if type(layout) ~= "string" or layout == "" or #layout > M.MAX_LEN then return tabs end
    local seen = {}
    local count = 0
    for tab_str in string.gmatch(layout .. "+", "([^+]*)%+") do
        count = count + 1
        if count > M.MAX_TABS then break end
        local tab = {}
        local segs = 0
        for seg in string.gmatch(tab_str .. ",", "([^,]*),") do
            segs = segs + 1
            if segs > 3 then break end
            local code, rest = string.match(seg, "^%s*(.-)%s*:(.*)$")
            if code and code ~= "" then
                code = string.lower(code)
                local exact = (string.gsub(rest, "^%s+", ""))
                exact = (string.gsub(exact, "%s+$", ""))
                exact = (string.gsub(exact, "^@", ""))
                local raw = string.lower(exact)
                if code == "t" and name_ok(raw) then tab.twitch = raw
                elseif code == "k" and name_ok(raw) then tab.kick = raw
                elseif code == "y" then
                    if uc_ok(exact) then tab.youtube = exact
                    elseif yt_ok(raw) then tab.youtube = raw end
                end
            end
        end
        if tab.twitch or tab.kick or tab.youtube then
            local key = (tab.twitch or "") .. "|" .. (tab.kick or "") .. "|" .. (tab.youtube or "")
            if not seen[key] then
                seen[key] = true
                tabs[#tabs + 1] = tab
            end
        end
    end
    return tabs
end

-- canonical order twitch,kick,youtube; tabs joined by '+'
function M.build(tabs)
    local out = {}
    for _, t in ipairs(tabs or {}) do
        local segs = {}
        if t.twitch then segs[#segs + 1] = "t:" .. t.twitch end
        if t.kick then segs[#segs + 1] = "k:" .. t.kick end
        if t.youtube then segs[#segs + 1] = "y:" .. t.youtube end
        if #segs > 0 then out[#out + 1] = table.concat(segs, ",") end
    end
    return table.concat(out, "+")
end

function M.url(tabs)
    local l = M.build(tabs)
    if l == "" then return nil end
    return M.ORIGIN .. "/m/" .. l
end

return M
