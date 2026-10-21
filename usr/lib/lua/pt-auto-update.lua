local M = require("pt-subs-lib")

local SUBS_FILE = "/etc/config/podkop-tweaker-subs.json"
local LOG_FILE = "/etc/config/pt-update.log"
local LOG_MAX = 25

local result = M.update_all_subscriptions(SUBS_FILE, LOG_FILE, LOG_MAX, "auto")
M.finish_subscription_update(result)

if result.success ~= true then
    local message = (result.error or "Subscription update failed") ..
        (result.error_details and ("\n" .. result.error_details) or "")
    if result.applied then message = message .. "\nSubscription changes are already on disk." end
    if result.unknown then message = message .. "\nSubscription operation outcome is uncertain." end
    if result.restart_required then message = message .. "\nPodkop restart remains required." end
    error(message, 0)
end

return result
