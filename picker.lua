-- shared clickable-emote-grid renderer. one chat message whose elements wrap
-- into a grid; every emote is left-click-to-insert (LinkType.InsertText), the
-- same primitive /hsfind and inline rendering use. callers: /hsfind (catalog
-- search) and /hsemotes (your inventory menu).
local caps = require("caps")
local img = require("img")

local M = {}

-- items: array of { name, url, w, h, label? }
--   name  — inserted verbatim (+ a trailing space) on click
--   url/w/h — emote image (w may be nil → scale by height, like the 7tv path)
--   label — tooltip text (defaults to name)
-- header: the leading system-colored line describing the grid.
-- returns true on success, false if the message couldn't be built.
function M.render(ch, header, items)
    return (pcall(function()
        local elems = { { type = "text", text = header, color = "system" } }
        for _, r in ipairs(items) do
            local set = caps.images and r.url and img.for_url(r.url, r.w, r.h) or nil
            local link = { type = c2.LinkType.InsertText, value = r.name .. " " }
            if set then
                elems[#elems + 1] = {
                    type = "scaling-image",
                    images = set,
                    flags = c2.MessageElementFlag.EmoteImage,
                    tooltip = r.label or r.name,
                    link = link,
                }
            else
                -- no image (caps/url missing) → clickable name, still inserts
                elems[#elems + 1] = {
                    type = "text",
                    text = r.name,
                    color = "link",
                    tooltip = r.label or r.name,
                    link = link,
                }
            end
        end
        ch:add_message(c2.Message.new({ elements = elems }))
    end))
end

return M
