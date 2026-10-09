local M = require("pt-subs-lib")

local SUBS_FILE = "/etc/config/podkop-tweaker-subs.json"
local LOG_FILE = "/etc/config/pt-update.log"
local LOG_MAX = 25

local result = M.update_all_subscriptions(SUBS_FILE, LOG_FILE, LOG_MAX, "auto")

if result.need_restart then
    os.execute(require("podkop-tweaker.services").background_command("/etc/init.d/podkop restart"))
end
