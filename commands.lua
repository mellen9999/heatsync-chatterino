-- user-facing commands. registered once from init.
local net = require("net")
local u = require("cmdutil")
local M = {}

function M.register(get_login)
    -- every handler runs under pcall: a lua error in one (a nil ctx.words,
    -- a shape the server changed) used to vanish into chatterino's log while
    -- the split stayed silent. the wrapper is installed only for the
    -- duration of registration, so nothing else that registers a command
    -- inherits it.
    local raw = c2.register_command
    c2.register_command = function(name, fn)
        return raw(name, function(ctx)
            local ok, err = pcall(fn, ctx)
            if not ok then
                net.log_warn(name .. " failed: " .. tostring(err))
                u.sysmsg(ctx, name .. " failed: " .. tostring(err))
            end
        end)
    end
    local ok, err = pcall(function()
        require("cmd_emotes").register()
        require("cmd_archive").register()
        require("cmd_multichat").register()
        require("cmd_system").register(get_login) -- only these commands need the login
    end)
    c2.register_command = raw
    if not ok then error(err, 0) end
end

return M
