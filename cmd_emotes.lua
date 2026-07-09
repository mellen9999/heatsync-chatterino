-- emote commands: your inventory, search, browsing others, local blocks.
local net = require("net")
local inventory = require("inventory")
local seventv = require("seventv")
local picker = require("picker")
local recents = require("recents")
local store = require("store")
local u = require("cmdutil")

local M = {}

function M.register()
    -- your emote menu: a clickable grid of YOUR inventory, recents-first then
    -- usage-ordered, paginated. `/hsemotes` page 1 · `/hsemotes 2` next page ·
    -- `/hsemotes <query>` filter to matching names. click any emote to insert.
    local HSEMOTES_PER_PAGE = 50
    c2.register_command("/hsemotes", function(ctx)
        local own = inventory.count()
        if own == 0 then
            u.sysmsg(ctx, "inventory not loaded — sign in at heatsync.org once, then /hsrefresh")
            return
        end
        local arg = ctx.words[2]
        local page, query = 1, nil
        if arg and arg ~= "" then
            local p = tonumber(arg)
            if p and p >= 1 and math.floor(p) == p then page = p else query = string.lower(arg) end
        end

        -- ordered name list
        local names, seen = {}, {}
        if query then
            for _, item in ipairs(inventory.index) do
                if string.find(item.lower, query, 1, true) and not seen[item.name] then
                    names[#names + 1] = item.name; seen[item.name] = true
                end
            end
            if #names == 0 then u.sysmsg(ctx, "no inventory emotes matching '" .. arg .. "'"); return end
        else
            for _, n in ipairs(recents.names()) do
                if not seen[n] then names[#names + 1] = n; seen[n] = true end
            end
            for _, item in ipairs(inventory.index) do
                if not seen[item.name] then names[#names + 1] = item.name; seen[item.name] = true end
            end
        end

        local total = #names
        local pages, from, to
        pages, page, from, to = u.paginate(total, page, HSEMOTES_PER_PAGE)

        local recent_set = {}
        for _, n in ipairs(recents.names()) do recent_set[n] = true end
        local items = {}
        for i = from, to do
            local n = names[i]
            local e = inventory.resolve(n)
            if e then
                items[#items + 1] = { name = n, url = e.url, w = e.w, h = e.h, hs = true,
                    label = n .. (recent_set[n] and " · recent" or " · heatsync") }
            end
        end

        local header
        if query then
            header = "[heatsync] " .. total .. " of your emotes matching '" .. arg .. "' — click to insert:"
        else
            local nav = pages > 1 and (" · page " .. page .. "/" .. pages ..
                " · /hsemotes " .. (page < pages and page + 1 or 1) .. " for more") or ""
            header = "[heatsync] your emotes (" .. own .. ")" .. nav ..
                " · /hsemotes <query> to filter — click to insert:"
        end
        if not picker.render(ctx.channel, header, items) then u.sysmsg(ctx, "emote menu render failed") end
    end)

    -- visual emote picker: searches your inventory + 7tv/bttv/ffz, shows the
    -- matches as clickable images — clicking inserts the name into your input.
    local FIND_CAP = 40
    c2.register_command("/hsfind", function(ctx)
        local q = ctx.words[2]
        if not q or string.len(q) < 2 then
            u.sysmsg(ctx, "usage: /hsfind <query> — searches your inventory + 7tv/bttv/ffz; click an emote to insert it")
            return
        end
        local ch = ctx.channel
        local results = {} -- { name, url, w, h, source }
        local seen = {}
        local ql = string.lower(q)
        -- own inventory (prefix + substring)
        for name, e in pairs(inventory.map) do
            if not seen[name] and string.find(string.lower(name), ql, 1, true) then
                results[#results + 1] = { name = name, url = e.url, w = e.w, h = e.h, source = "hs" }
                seen[name] = true
            end
        end
        -- search with the lowercased query — search_all's sanity gate requires
        -- lowercase, and the server matches case-insensitively (returns proper-
        -- case names). passing raw `q` silently returned 0 for any capital.
        seventv.search_all(ql, function(list)
            for _, e in ipairs(list) do
                if #results >= FIND_CAP then break end
                if not seen[e.name] then
                    local url, h = seventv.resolve_render(e.name)
                    results[#results + 1] = { name = e.name, url = url, h = h, source = e.provider }
                    seen[e.name] = true
                end
            end
            if #results == 0 then
                pcall(function() ch:add_system_message("[heatsync] no emotes found for '" .. q .. "'") end)
                return
            end
            local items = {}
            for _, r in ipairs(results) do
                items[#items + 1] = { name = r.name, url = r.url, w = r.w, h = r.h,
                    hs = r.source == "hs", label = r.name .. " · " .. r.source }
            end
            if not picker.render(ch, "[heatsync] " .. #results ..
                " emotes for '" .. q .. "' — click to insert:", items) then
                u.sysmsg(ctx, "picker render failed")
            end
        end)
    end)

    -- browse anyone's heatsync inventory (whois, for emotes): resolve the login
    -- to its heatsync id, fetch that user's emote set, show it as a click-to-
    -- insert grid. uses the same public endpoints the sender-emote path already
    -- reads (see senders.lua) — nothing private, and it never feeds the render
    -- path (privacy invariant: only the SENDER's own inventory renders inline).
    local INV_PER_PAGE = 50
    c2.register_command("/hsinv", function(ctx)
        local user = ctx.words[2]
        if not u.is_valid_name(user) then
            u.sysmsg(ctx, "usage: /hsinv <user> [page] — shows a user's heatsync emotes; click to insert")
            return
        end
        local page = tonumber(ctx.words[3])
        if not (page and page >= 1 and math.floor(page) == page) then page = 1 else page = math.floor(page) end
        local luser = string.lower(user)
        net.get_json(net.ORIGIN .. "/api/profile/" .. net.percent_encode(luser), 8000, function(payload, err)
            local p = type(payload) == "table" and type(payload.profile) == "table" and payload.profile or nil
            local uid = p and p.id
            local ok_id = (type(uid) == "number" and uid > 0)
                or (type(uid) == "string" and string.match(uid, "^%d+$") ~= nil)
            if not p or not ok_id then
                u.sysmsg(ctx, "no heatsync profile for '" .. user .. "'" .. (err and (" (" .. tostring(err) .. ")") or ""))
                return
            end
            local who = tostring(p.display_name or p.username or luser)
            net.get_json(net.ORIGIN .. "/api/users/" .. tostring(uid) .. "/emotes", 10000, function(pl, err2)
                local rows = pl and (pl.emotes or pl.data or pl.items)
                if type(rows) ~= "table" then
                    u.sysmsg(ctx, "couldn't load " .. who .. "'s emotes" .. (err2 and (" (" .. tostring(err2) .. ")") or ""))
                    return
                end
                local items = {}
                for _, e in ipairs(rows) do
                    local rec = net.parse_emote_row(e)
                    if rec then
                        items[#items + 1] = { name = rec.name, url = rec.url, w = rec.w, h = rec.h,
                            hs = true, label = rec.name .. " · " .. who }
                    end
                end
                if #items == 0 then
                    u.sysmsg(ctx, who .. " has no heatsync emotes")
                    return
                end
                -- paginate like /hsemotes so a 200-emote inventory doesn't dump
                -- one oversized message
                local total = #items
                local pages, from, to
                pages, page, from, to = u.paginate(total, page, INV_PER_PAGE)
                local slice = {}
                for i = from, to do slice[#slice + 1] = items[i] end
                local nav = pages > 1 and (" · page " .. page .. "/" .. pages ..
                    " · /hsinv " .. luser .. " " .. (page < pages and page + 1 or 1) .. " for more") or ""
                local header = "[heatsync] " .. who .. "'s emotes (" .. total .. ")" .. nav .. " — click to insert:"
                if not picker.render(ctx.channel, header, slice) then u.sysmsg(ctx, "inventory render failed") end
            end)
        end)
    end)

    -- local emote block: hides an emote from rendering + tab-complete. LOCAL
    -- ONLY — the plugin is anonymous so it can't sync a block to your heatsync
    -- account; use the website/extension for an account-wide block.
    c2.register_command("/hsblock", function(ctx)
        local name = ctx.words[2]
        if not name or name == "" then
            u.sysmsg(ctx, "usage: /hsblock <emote name> — hides it locally in chatterino")
            return
        end
        if store.block(name) then
            u.sysmsg(ctx, "blocked '" .. name .. "' locally (won't render or tab-complete) · /hsunblock " .. name .. " to undo")
        else
            u.sysmsg(ctx, "'" .. name .. "' already blocked")
        end
    end)

    c2.register_command("/hsunblock", function(ctx)
        local name = ctx.words[2]
        if not name or name == "" then
            u.sysmsg(ctx, "usage: /hsunblock <emote name> — removes a local block")
            return
        end
        if store.unblock(name) then
            u.sysmsg(ctx, "unblocked '" .. name .. "'")
        else
            u.sysmsg(ctx, "'" .. name .. "' wasn't blocked")
        end
    end)

    c2.register_command("/hsblocklist", function(ctx)
        local names = store.blocklist()
        if #names == 0 then
            u.sysmsg(ctx, "no locally-blocked emotes")
            return
        end
        u.sysmsg(ctx, #names .. " blocked: " .. table.concat(names, " "))
    end)
end

return M
