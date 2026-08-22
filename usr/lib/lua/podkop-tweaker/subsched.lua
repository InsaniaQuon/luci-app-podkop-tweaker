-- Podkop Tweaker | subscription auto-update scheduling (cron + hotplug)
-- Author: InsaniaQuon

local M = {}

local sys = require("luci.sys")

function M.setup_cron(interval, start_time)
    sys.exec("(crontab -l 2>/dev/null | grep -v pt-auto-update; true) | crontab -")
    if not interval or interval <= 0 or not start_time or start_time == "" then return end

    local hh, mm = start_time:match("^(%d+):(%d+)$")
    if not hh or not mm then return end
    hh, mm = tonumber(hh), tonumber(mm)
    if not hh or hh > 23 or not mm or mm > 59 then return end
    if interval < 1 then interval = 1 end
    if interval > 24 then interval = 24 end

    local hours = {}
    local h = hh
    while h <= 23 do
        table.insert(hours, tostring(h))
        h = h + interval
    end

    local cron_hours = table.concat(hours, ",")
    sys.exec("(crontab -l 2>/dev/null; echo '" .. mm .. " " .. cron_hours .. " * * * /usr/bin/pt-auto-update') | crontab -")
end

function M.setup_hotplug(enabled)
    local hp_path = "/etc/hotplug.d/iface/99-pt-subs"
    if enabled then
        os.execute("mkdir -p /etc/hotplug.d/iface 2>/dev/null")
        local fd = io.open(hp_path, "w")
        if fd then
            fd:write("#!/bin/sh\n")
            fd:write('[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "wan" ] && (sleep 30; /usr/bin/pt-auto-update) >/dev/null 2>&1 &\n')
            fd:close()
            os.execute("chmod +x " .. hp_path .. " 2>/dev/null")
        end
    else
        os.execute("rm -f " .. hp_path .. " 2>/dev/null")
    end
end

function M.create_auto_update_script()
    local script_path = "/usr/bin/pt-auto-update"
    local fd = io.open(script_path, "w")
    if not fd then return false end
    fd:write("#!/bin/sh\n")
    fd:write("lua /usr/lib/lua/pt-auto-update.lua\n")
    fd:close()
    os.execute("chmod +x " .. script_path .. " 2>/dev/null")
    return true
end

return M
