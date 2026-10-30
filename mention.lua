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
-- the look is chatterino's own default self-mention highlight (a translucent
-- red-brown, #7f7f3f49 ARGB) plus the Highlighted flag, so the line sits in the
-- same row style as a native mention. it can't read the user's custom highlight
-- color — the plugin api doesn't expose settings — so a customised color stays
-- native-only.
local caps = require("caps")
local store = require("store")
local senders = require("senders")

local M = {}

M.COLOR = "#7f7f3f49"
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

-- {flags, color} to build into a merged line aimed at you, or nil. `sender` is the
-- chatter's login/name (your own lines never ping you); `reply_user` a kick reply's
-- target.
function M.fields(text, sender, reply_user)
    if not M.enabled() then return nil end
    local me = senders.own_login
    if type(me) ~= "string" or me == "" then return nil end
    if type(sender) == "string" and string.lower(sender) == me then return nil end
    local hit = M.matches(text, me)
    if not hit and type(reply_user) == "string" and string.lower(reply_user) == me then hit = true end
    if not hit then return nil end
    local flags = c2.MessageFlag.Highlighted
    local extra = c2.MessageFlag.ShowInMentions
    if type(extra) == "number" then flags = flags | extra end
    return flags, M.COLOR
end

return M
