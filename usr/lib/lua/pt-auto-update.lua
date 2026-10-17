local M = require("pt-subs-lib")
local SRV = require("podkop-tweaker.services")

local SUBS_FILE = "/etc/config/podkop-tweaker-subs.json"
local LOG_FILE = "/etc/config/pt-update.log"
local LOG_MAX = 25

local result = M.update_all_subscriptions(SUBS_FILE, LOG_FILE, LOG_MAX, "auto")

if result.success ~= true then
    local message = (result.error or "Subscription update failed") ..
        (result.error_details and ("\n" .. result.error_details) or "")
    if result.applied then message = message .. "\nSubscription changes are already on disk." end
    if result.unknown then message = message .. "\nResource lock release is unverified." end
    if result.restart_required then message = message .. "\nPodkop restart remains required." end
    error(message, 0)
end

if result.need_restart then
    local observed
    local restart, lock_err = SRV.with_lock("podkop", function()
        observed = SRV.restart_service("podkop")
        return observed
    end)
    if not restart then
        restart = observed or {}
        restart.success = false
        restart.error = restart.error or (restart.restarting and "Podkop restart requested, but lock release failed" or "Podkop restart lock failed")
        restart.details = (restart.details and (restart.details .. "\n") or "") .. tostring(lock_err)
    end
    if restart.success ~= true then
        local message = restart.error or "Podkop restart failed"
        if restart.details then message = message .. "\n" .. restart.details end
        message = message .. "\nSubscription changes are already on disk."
        local logged, log_err = M.append_log(LOG_FILE, LOG_MAX,
            os.date("%H:%M %d.%m.%Y") .. "|auto|updated=" .. result.updated .. "|unchanged=" .. result.unchanged
            .. "|failed=" .. math.max(1, result.failed) .. "\n  service:\n    podkop: failed (" .. M.clean_log_field(message) .. ")")
        if not logged then message = message .. "\nCannot write failure log: " .. tostring(log_err) end
        error(message, 0)
    end
    for key, value in pairs(restart) do result[key] = value end
end

return result
