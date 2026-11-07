-- mention highlights on merged kick/youtube lines (on by default, /hsmentions).
-- chatterino highlights a native twitch mention itself, but a merged [K]/[Y] line
-- is plugin-built, so it never gets the look. mirrors the extension's isMention
-- (multichat/mentions.js): the signed-in twitch login as a case-insensitive whole
-- word (an @ before it is just punctuation), never your own lines, and a kick
-- reply aimed at you. what's NOT reachable: the extension also pings on your
-- kick/youtube alias names and on server-side mention rules, both of which need
-- a heatsync login — the plugin socket is anonymous — and chatterino's account
-- api exposes the login only, no display name (case-insensitive match covers it).
--
-- the look is the brand for-you row: solid dim red (brand.mention.bg) plus the
-- Highlighted flag. the zebra-stripe twin (brand.mention.stripe) needs the row's
-- parity, which the plugin api can't see, so every row uses bg. a customised
-- native highlight colour stays native-only (settings aren't exposed).
local caps = require("caps")
local store = require("store")
local brand = require("brand")
local senders = require("senders")

local M = {}

M.COLOR = brand.mention.bg
local LOGIN_MAX = 25

-- word chars match the extension's regex \b: letters, digits, underscore
local function is_word_byte(b)
    return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
end

-- does `text` mention `login` as a whole word? both lowercased here. pure.
function M.matches(text, login)
    if type(text) ~= "string" or type(login) ~= "string" then return false end
    if login == "" or #login > LOGIN_MAX or not string.match(login, "^[a-z0-9_]+$") then return false end
    if #text < #login then return false end
    local hay = string.lower(text)
    local from = 1
    while true do
        local s, e = string.find(hay, login, from, true)
        if not s then return false end
        if not is_word_byte(string.byte(hay, s - 1)) and not is_word_byte(string.byte(hay, e + 1)) then
            return true
        end
        from = s + 1
    end
end

function M.enabled()
    return store.mentions_enabled() and caps.highlight
end

-- ----- account mention rules (account_sync.lua feeds these) -----
local RULES_MAX = 100
local PATTERN_MAX = 200
local PLATFORMS = { twitch = true, kick = true, youtube = true }
local rules = {}
local skipped = 0 -- regex rules we can't run here

-- GET /api/cli/mention-rules → compiled rules. returns the count kept.
function M.set_rules(list)
    local out, skip = {}, 0
    if type(list) == "table" then
        for i = 1, math.min(#list, RULES_MAX) do
            local r = list[i]
            if type(r) == "table" and r.enabled ~= false and r.dormant ~= true
                and type(r.pattern) == "string" and r.pattern ~= "" and #r.pattern <= PATTERN_MAX
                and not string.find(r.pattern, "%c") then
                local kind = r.rule_type
                if kind == "word" or kind == "phrase" then
                    local cs = r.case_sensitive == true
                    local rule = { kind = kind, cs = cs, pattern = cs and r.pattern or string.lower(r.pattern) }
                    if type(r.channels) == "table" and #r.channels > 0 then
                        rule.channels = {}
                        for j = 1, math.min(#r.channels, 50) do
                            local c = r.channels[j]
                            if type(c) == "string" and #c <= 60 then rule.channels[string.lower(c)] = true end
                        end
                    end
                    if type(r.platforms) == "table" and #r.platforms > 0 then
                        rule.platforms = {}
                        for j = 1, math.min(#r.platforms, 3) do
                            local p = r.platforms[j]
                            if type(p) == "string" and PLATFORMS[p] then rule.platforms[p] = true end
                        end
                    end
                    out[#out + 1] = rule
                elseif kind == "regex" then
                    skip = skip + 1
                end
            end
        end
    end
    rules, skipped = out, skip
    return #out
end

function M.rule_count() return #rules, skipped end

-- whole-word containment, every occurrence (the server's matchesWord): the chars
-- either side must be non-word, with the string's ends counting as non-word
local function word_hit(hay, needle)
    local from = 1
    while true do
        local s, e = string.find(hay, needle, from, true)
        if not s then return false end
        if not is_word_byte(string.byte(hay, s - 1)) and not is_word_byte(string.byte(hay, e + 1)) then
            return true
        end
        from = s + 1
    end
end

-- does any account rule match this merged line? `platform` is "kick" | "youtube",
-- `channels` a list of lowercase names the line is "in" (the source's channel and
-- the twitch tab it landed in): a rule with a channel list needs one to match.
function M.rules_hit(text, platform, channels)
    if #rules == 0 or type(text) ~= "string" or text == "" then return false end
    local lower = nil
    for _, r in ipairs(rules) do
        local ok = true
        if r.platforms and not r.platforms[platform] then ok = false end
        if ok and r.channels then
            ok = false
            for _, c in ipairs(channels or {}) do
                if r.channels[c] then ok = true; break end
            end
        end
        if ok then
            local hay = text
            if not r.cs then
                lower = lower or string.lower(text)
                hay = lower
            end
            if r.kind == "phrase" then
                if string.find(hay, r.pattern, 1, true) then return true end
            elseif word_hit(hay, r.pattern) then
                return true
            end
        end
    end
    return false
end

-- {flags, color} to build into a merged line aimed at you, or nil. `sender` is the
-- chatter's login/name (your own lines never ping you); `reply_user` a kick reply's
-- target; `platform` + `channels` scope your account's mention rules.
function M.fields(text, sender, reply_user, platform, channels)
    if not M.enabled() then return nil end
    local me = senders.own_login
    local has_me = type(me) == "string" and me ~= ""
    if has_me and type(sender) == "string" and string.lower(sender) == me then return nil end
    local hit = false
    if has_me then
        hit = M.matches(text, me)
        if not hit and type(reply_user) == "string" and string.lower(reply_user) == me then hit = true end
    end
    if not hit then hit = M.rules_hit(text, platform, channels) end
    if not hit then return nil end
    local flags = c2.MessageFlag.Highlighted
    local extra = c2.MessageFlag.ShowInMentions
    if type(extra) == "number" then flags = flags | extra end
    return flags, M.COLOR
end

return M
