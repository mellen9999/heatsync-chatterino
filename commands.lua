-- user-facing commands. registered once from init.
local M = {}

function M.register(get_login)
    require("cmd_emotes").register(get_login)
    require("cmd_archive").register(get_login)
    require("cmd_multichat").register(get_login)
    require("cmd_system").register(get_login)
end

return M
