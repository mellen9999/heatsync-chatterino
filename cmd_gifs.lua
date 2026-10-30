-- /hsgif <query> [page] — heatsync's gif library as a click-to-insert grid.
-- a click drops the gif's url into your input (the way the extension's gif tab
-- does), so sending it is your call. the search itself is gifs.lua; the tiles are
-- the library's still frames, loaded through heatsync's image proxy (/api/img) —
-- the same one inline images use, so the gif host never sees your ip. nothing is
-- fetched until you run the command, so there's no toggle to switch on.
local net = require("net")
local gifs = require("gifs")
local images = require("images")
local picker = require("picker")
local u = require("cmdutil")

local M = {}

local PER_PAGE = 12  -- each new tile is a proxy fetch + scan: a page is small on purpose
local MAX_PAGE = math.floor(gifs.LIMIT_MAX / PER_PAGE) -- the server has no offset: page N asks for N*12
-- the library's stills are fixed-height renditions (giphy's 200_s.gif is 200px
-- high); the proxy re-encodes without resizing, and a plugin can't read an image's
-- size once loaded, so tiles are scaled from that assumed height to TILE_H. a
-- source with another height lands proportionally bigger or smaller, never huge.
local ASSUMED_H = 200
local TILE_H = 72

-- parse "<query words> [page]": a trailing positive integer after a query is the
-- page; a lone number is a page of the top gifs. returns query, page.
function M.parse_args(words)
    local parts = {}
    for i = 2, #words do
        if type(words[i]) == "string" and words[i] ~= "" then parts[#parts + 1] = words[i] end
    end
    local page = 1
    local last = parts[#parts]
    local n = last and string.match(last, "^%d+$") and tonumber(last) or nil
    if n and n >= 1 and n <= 1000 then
        page = n
        parts[#parts] = nil
    end
    return table.concat(parts, " "), page
end

local function items_for(slice)
    local items = {}
    for _, g in ipairs(slice) do
        local label = g.label ~= "" and g.label or "gif"
        items[#items + 1] = {
            name = g.url, -- what a click inserts (picker appends the space)
            url = images.proxy_url(g.preview),
            h = ASSUMED_H,
            target_h = TILE_H,
            text = "[" .. u.preview(label, 24) .. "]", -- no-image builds show the caption
            label = label .. " · click to insert",
        }
    end
    return items
end

function M.register()
    c2.register_command("/hsgif", function(ctx)
        local q, page = M.parse_args(ctx.words)
        if #q > gifs.QUERY_MAX then q = string.sub(q, 1, gifs.QUERY_MAX) end
        if page > MAX_PAGE then page = MAX_PAGE end
        gifs.search(q, page * PER_PAGE, function(res, err, status)
            if not res then
                if status == 429 then
                    u.sysmsg(ctx, "gif search is rate limited — try again in a few seconds")
                else
                    u.sysmsg(ctx, "gif search failed" .. (err and (" (" .. tostring(err) .. ")") or ""))
                end
                return
            end
            local total = #res.gifs
            if total == 0 then
                if res.state ~= "ready" then
                    u.sysmsg(ctx, "the gif library is still filling up — try again later")
                else
                    u.sysmsg(ctx, "no gifs for '" .. (q ~= "" and q or "top") .. "'")
                end
                return
            end
            local pages
            pages, page = u.paginate(total, page, PER_PAGE)
            local from = (page - 1) * PER_PAGE + 1
            local slice = {}
            for i = from, math.min(total, from + PER_PAGE - 1) do slice[#slice + 1] = res.gifs[i] end
            local more = (page < MAX_PAGE and total >= page * PER_PAGE)
                and (" · /hsgif " .. (q ~= "" and (q .. " ") or "") .. (page + 1) .. " for more") or ""
            local header = "[heatsync] gifs" .. (q ~= "" and (" · " .. (net.safe_text(q, 64) or q)) or " · top") ..
                (page > 1 and (" · page " .. page) or "") .. more .. " — click to insert:"
            if not picker.render(ctx.channel, header, items_for(slice)) then
                u.sysmsg(ctx, "gif grid render failed")
            end
        end)
    end)
end

return M
