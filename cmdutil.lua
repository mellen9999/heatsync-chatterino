-- shared helpers for the /hs* command modules.
local M = {}

function M.sysmsg(ctx, text)
    pcall(function() ctx.channel:add_system_message("[heatsync] " .. text) end)
end

-- a clickable line: chatterino system messages can't carry links, so this
-- builds a minimal message with a link element instead. works on 2.5.5+.
function M.linkmsg(ctx, text, url)
    local ok = pcall(function()
        ctx.channel:add_message(c2.Message.new({
            elements = {
                { type = "text", text = "[heatsync]", color = "system" },
                {
                    type = "text",
                    text = text,
                    color = "link",
                    tooltip = url,
                    link = { type = c2.LinkType.Url, value = url },
                },
            },
        }))
    end)
    if not ok then
        -- pre-2.5.5 fallback: plain system line with the raw url
        M.sysmsg(ctx, text .. " → " .. url)
    end
end

-- lua patterns lack {m,n}; check length separately
function M.is_valid_name(s)
    return type(s) == "string" and s ~= "" and #s <= 25
        and string.match(s, "^[a-zA-Z0-9_]+$") ~= nil
end

-- arg parse for /hshot: any recognized platform token sets a filter, any
-- positive integer sets the page. order-free, so `/hshot kick 2` and
-- `/hshot 2 kick` both work. (/hsmoments parses its own args — it has a leading
-- hours value, so its number handling differs and can't share this.)
M.PLAT_ALIAS = { twitch = "twitch", kick = "kick", youtube = "youtube", yt = "youtube" }
function M.parse_plat_page(words, start)
    local plat, page, bad = nil, 1, nil
    for i = start, #words do
        local w = words[i]
        if type(w) == "string" and w ~= "" then
            local n = tonumber(w)
            if n and n >= 1 and math.floor(n) == n then
                page = math.floor(n)
            elseif M.PLAT_ALIAS[string.lower(w)] then
                plat = M.PLAT_ALIAS[string.lower(w)]
            else
                bad = bad or w -- first unrecognized token → a hint, not silence
            end
        end
    end
    return plat, page, bad
end

function M.join_args(words)
    local parts = {}
    for i = 2, #words do parts[#parts + 1] = words[i] end
    return table.concat(parts, " ")
end

function M.preview(s, n)
    s = tostring(s or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if utf8 and utf8.len then
        local len = utf8.len(s)
        if len and len > n then
            local cut = utf8.offset(s, n + 1)
            if cut then return s:sub(1, cut - 1) .. "…" end
        end
        return s
    end
    if #s > n then return s:sub(1, n - 1) .. "…" end
    return s
end

return M
