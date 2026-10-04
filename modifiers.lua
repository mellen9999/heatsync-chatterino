-- emote modifier tokens ("w!", "h!", "ffzX", "c!#ff8700", chains like "w!h!ffzX").
-- on heatsync.org and in the extension a token placed after an emote attaches to
-- it (wide, flipped, tinted...). the plugin cannot transform images, so render.lua
-- consumes the token and names the effects in the emote's tooltip instead.
--
-- TOKENS mirrors HS_MOD_TOKENS in the site's client/utils/hs-modifiers.js (the
-- harness diffs the two when the site checkout is reachable). classify() mirrors
-- hsModClassify without the prefix-completion mode, which is an input feature.
-- pure: no c2 calls.
local M = {}

M.TOKENS = {
    ["w!"] = "wide", ["h!"] = "flipH", ["v!"] = "flipV", ["z!"] = "zeroWidth",
    ["c!"] = "cursed", ["l!"] = "rotateL", ["r!"] = "rotateR", ["p!"] = "party",
    ["s!"] = "shake", ["x!"] = "flipH", ["y!"] = "flipV",
    ffzX = "flipH", ffzY = "flipV", ffzW = "wide", ffzWide = "wide", ffzTall = "tall",
    ffzCursed = "cursed", ffzHyper = "hyper", ffzRainbow = "rainbow", ffzBounce = "bounce",
    ffzJam = "jam", ffzSlide = "slide", ffzArrive = "arrive", ffzLeave = "leave", ffzSpin = "spin",
}

-- longest token first so "ffzWide" wins over "ffzW"
local KEYS = {}
for k in pairs(M.TOKENS) do KEYS[#KEYS + 1] = k end
table.sort(KEYS, function(a, b)
    if #a ~= #b then return #a > #b end
    return a < b
end)

local MAX_WORD = 200 -- a modifier chain is short; skip the peel loop on anything long

-- hex colour → hue degrees 0-359, rounded (same maths as hsModHexToHue)
local function hex_to_hue(hex)
    if #hex == 3 then hex = hex:gsub(".", "%0%0") end
    local r = tonumber(hex:sub(1, 2), 16) / 255
    local g = tonumber(hex:sub(3, 4), 16) / 255
    local b = tonumber(hex:sub(5, 6), 16) / 255
    local max, min = math.max(r, g, b), math.min(r, g, b)
    local d = max - min
    local h = 0
    if d ~= 0 then
        if max == r then h = ((g - b) / d) % 6
        elseif max == g then h = (b - r) / d + 2
        else h = (r - g) / d + 4 end
        h = h * 60
        if h < 0 then h = h + 360 end
    end
    h = math.floor(h + 0.5)
    return h % 360
end

-- "c!#ff8700" / "c!ff8700" / "c!#f80" at the start of s → matched text, hex
local function peel_color(s)
    if s:sub(1, 2) ~= "c!" then return nil end
    local body = s:sub(3)
    local off = body:sub(1, 1) == "#" and 1 or 0
    local six = body:match("^%x%x%x%x%x%x", off + 1)
    if six then return s:sub(1, 2 + off + 6), six end
    local three = body:match("^%x%x%x", off + 1)
    if three then return s:sub(1, 2 + off + 3), three end
    return nil
end

-- word → nil | { mods = {canonical names}, hue = 0-359|nil, words = {matched tokens} }
-- exact token, c!#hex, or a chain peeled left to right; anything else is not a modifier
function M.classify(word)
    if type(word) ~= "string" or word == "" or #word > MAX_WORD then return nil end
    local exact = M.TOKENS[word]
    if exact then return { mods = { exact }, hue = nil, words = { word } } end
    local mods, words, hue = {}, {}, nil
    local rem = word
    while #rem > 0 do
        local matched, hex = peel_color(rem)
        if matched then
            hue = hex_to_hue(hex)
            words[#words + 1] = matched
            rem = rem:sub(#matched + 1)
        else
            local hit = nil
            for _, k in ipairs(KEYS) do
                if rem:sub(1, #k) == k then hit = k; break end
            end
            if not hit then return nil end
            mods[#mods + 1] = M.TOKENS[hit]
            words[#words + 1] = hit
            rem = rem:sub(#hit + 1)
        end
    end
    if #mods == 0 and hue == nil then return nil end
    return { mods = mods, hue = hue, words = words }
end

-- tooltip suffix for a list of classified results' effects, e.g. " · wide · flipH · tint #ff8700"
function M.describe(mods, tint)
    local out = {}
    for _, m in ipairs(mods) do
        out[#out + 1] = m == "zeroWidth" and " · zero-width (drawn inline here)" or (" · " .. m)
    end
    if tint then out[#out + 1] = " · tint " .. tint end
    return table.concat(out)
end

-- the hex text of a "c!#ff8700" token, with the leading "#" normalised
function M.tint_text(token)
    local hex = token:sub(3)
    if hex:sub(1, 1) ~= "#" then hex = "#" .. hex end
    return hex
end

return M
