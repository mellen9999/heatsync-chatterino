-- brand notice rows: a solid-fill system line (olive stream events, teal
-- announcements) — label keeps its colour, body white. palette is brand.lua
-- (generated, never hand-edited). falls back to a plain system line if the row
-- can't be built, so a missing api degrades, never errors.
local net = require("net")
local brand = require("brand")

local M = {}

-- ch: channel · fill: brand.fills key · label/label_color: leading tag · body: rest
function M.add(ch, fill, label, label_color, body, link)
    local text = label .. " " .. body
    local ok = pcall(function()
        local f = c2.MessageFlag
        local bodyel = { type = "text", text = body, color = brand.palette.white }
        if link then
            bodyel.link = { type = c2.LinkType.Url, value = link }
            bodyel.tooltip = link
        end
        ch:add_message(net.new_message({
            flags = f and ((f.System or 0) | (f.Highlighted or 0)) or nil,
            highlight_color = brand.fills[fill],
            message_text = text, search_text = text,
            elements = { { type = "text", text = label, color = label_color }, bodyel },
        }))
    end)
    if not ok then pcall(function() ch:add_system_message("[heatsync] " .. text) end) end
end

return M
