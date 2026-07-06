-- feature detection. the plugin api has no version number (docs are
-- literally wip-plugins.md), so every capability is probed individually and
-- the plugin degrades instead of erroring on older builds.
--
-- tiers:
--   t2  nightly 2026+  — message hooks + images + windows → full rendering
--   t1  stable 2.5.5   — timers + websocket → live-synced tab-complete + commands
--   t0  older          — completion-piggyback refresh only (v0.4.0 behavior)
local M = {
    later = false,
    websocket = false,
    images = false,
    windows = false,
    msg_hooks = nil, -- lazily confirmed on first real channel object
    tier = 0,
}

local function probe(fn)
    local ok, v = pcall(fn)
    return ok and v == true
end

function M.detect()
    M.later = type(c2.later) == "function"
    M.websocket = probe(function()
        return type(c2.WebSocket) ~= "nil" and type(c2.WebSocket.new) == "function"
    end)
    M.images = probe(function()
        return type(c2.Image) ~= "nil" and type(c2.Image.from_url) == "function"
            and type(c2.ImageSet) ~= "nil" and type(c2.ImageSet.new) == "function"
    end)
    M.windows = probe(function()
        return c2.windows ~= nil
    end)

    if M.later and M.websocket and M.images and M.windows then
        M.tier = 2
    elseif M.later and M.websocket then
        M.tier = 1
    else
        M.tier = 0
    end
end

-- message hooks ship in the same builds as images/windows but are probed on
-- the first real channel anyway — if absent, rendering silently drops to t1.
function M.confirm_msg_hooks(ch)
    if M.msg_hooks ~= nil then return M.msg_hooks end
    M.msg_hooks = probe(function()
        return type(ch.on_message_appended) == "function"
    end)
    if not M.msg_hooks and M.tier == 2 then
        M.tier = 1
    end
    return M.msg_hooks
end

function M.name()
    return "t" .. tostring(M.tier)
end

return M
