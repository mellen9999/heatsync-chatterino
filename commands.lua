-- user-facing commands. registered once from init.
local M = {}

function M.register(get_login)
    require("cmd_emotes").register()
    require("cmd_archive").register()
    require("cmd_multichat").register()
    require("cmd_system").register(get_login) -- only these commands need the login
end

return M
