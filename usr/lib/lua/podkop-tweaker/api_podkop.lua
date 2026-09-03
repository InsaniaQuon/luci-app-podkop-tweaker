-- Podkop Tweaker | v4.4.0 | 30.08.2026 | transport endpoints via http.lua helpers, service ops via services.lua factories
-- Hybrid exceptions kept as-is: read_config, export_config, download_backup (transport endpoints)

local H = require("podkop-tweaker.http")
local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")
local S = require("pt-subs-lib")
local UPD = require("podkop-tweaker.api_update")

local M = {}

local PODKOP_INSTALL_URL = "https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh"

local function save_and_restart(content)
    local sys = require("luci.sys")

    if not S.backup_config() then
        return false, "Cannot create backup"
    end

    local ok, err = SRV.write_file_atomic(SRV.podkop.config, content)
    if not ok then
        return false, err
    end

    sys.exec("/etc/init.d/podkop restart 2>&1")
    return true
end

function M.system_info()
    local sys = require("luci.sys")

    local raw = sys.exec("podkop get_system_info 2>/dev/null")

    local info
    pcall(function() info = luci.json and luci.json.parse and luci.json.parse(raw) end)
    if not info then
        pcall(function()
            local json = require("luci.jsonc")
            info = json.parse(raw)
        end)
    end
    if not info then
        pcall(function()
            local json = require("cjson")
            info = json.decode(raw)
        end)
    end

    if not info or not info.podkop_version then
        return {
            podkop_version = "unknown",
            podkop_latest_version = "unknown",
            luci_app_version = "unknown",
            sing_box_version = "unknown",
            openwrt_version = "unknown",
            device_model = "unknown",
            update_available = false,
            tweaker_version = UPD.get_version(),
            tweaker_latest = nil,
            error = "Failed to get system info from podkop"
        }
    end

    local update_available = false
    if info.podkop_latest_version
        and info.podkop_latest_version ~= "unknown"
        and info.podkop_version ~= "unknown" then
        update_available = LIB.version_lt(info.podkop_version, info.podkop_latest_version)
    end

    local stubby_ver = sys.exec("stubby -V 2>/dev/null"):match("Stubby%s+(%S+)") or "not installed"

    return {
        podkop_version = info.podkop_version or "unknown",
        podkop_latest_version = info.podkop_latest_version or "unknown",
        luci_app_version = info.luci_app_version or "unknown",
        stubby_version = stubby_ver,
        sing_box_version = info.sing_box_version or "unknown",
        openwrt_version = info.openwrt_version or "unknown",
        device_model = info.device_model or "unknown",
        update_available = update_available,
        tweaker_version = UPD.get_version(),
        tweaker_latest = UPD.cached_latest()
    }
end

function M.update_start()
    local sys = require("luci.sys")

    if not S.backup_config() then
        return { error = "Cannot create backup before update" }
    end

    sys.exec("pkill -f 'ttyd.*7682' 2>/dev/null")

    local host = require("luci.http").getenv("SERVER_NAME") or "127.0.0.1"
    if not host:match("^[%w%.%-]+:%d+$") and not host:match("^[%w%.%-]+$") then
        host = require("luci.http").getenv("SERVER_NAME") or "127.0.0.1"
    end
    local port = "7682"

    local wrapper_orig = io.open("/etc/init.d/podkop.orig", "r")
    local wrapper_active = wrapper_orig ~= nil
    if wrapper_orig then wrapper_orig:close() end

    local cmd = "ttyd -p " .. port .. " sh -c 'wget -O /tmp/podkop-install.sh " .. PODKOP_INSTALL_URL .. " && sh /tmp/podkop-install.sh"
    if wrapper_active then
        cmd = cmd .. " && rm -f /etc/init.d/podkop.orig && /etc/init.d/podkop-fragment enable"
    end
    cmd = cmd .. "' >/dev/null 2>&1 &"
    sys.exec(cmd)

    return { success = true, url = "http://" .. host .. ":" .. port }
end

function M.read_config()
    H.send_text_file("/etc/config/podkop")
end

function M.save_config(content)
    local ok, err = LIB.validate_uci_config(content)
    if not ok then
        return { error = err }
    end
    ok, err = save_and_restart(content)
    if not ok then
        return { error = err }
    end
    return { success = true, restarting = true }
end

function M.export_config()
    H.send_download("/etc/config/podkop", "podkop-config-export.conf", "Config not found")
end

function M.download_backup()
    H.send_download("/etc/config/podkop.auto-backup", "podkop-auto-backup.conf", "Backup file not found")
end

function M.import_config(upload_content, upload_file)
    if upload_content == "" then
        if type(upload_file) == "table" and upload_file.data then
            upload_content = upload_file.data
        elseif type(upload_file) == "string" then
            upload_content = upload_file
        end
    end
    local ok, err = LIB.validate_uci_config(upload_content)
    if not ok then
        return { error = err }
    end
    ok, err = save_and_restart(upload_content)
    if not ok then
        return { error = err }
    end
    return { success = true, restarting = true }
end

function M.service_status()
    return SRV.service_status(SRV.ops.podkop)
end

function M.rollback()
    return SRV.rollback(SRV.ops.podkop)
end

function M.service_toggle(action)
    return SRV.service_toggle(SRV.ops.podkop, action)
end

function M.autostart()
    local fd = io.open("/etc/rc.d/S99podkop", "r")
    local resp = {
        enabled = (fd ~= nil)
    }
    if fd then fd:close() end
    return resp
end

function M.autostart_toggle(action)
    if action ~= "enable" and action ~= "disable" then
        return { error = "Invalid action" }
    end
    require("luci.sys").exec("/etc/init.d/podkop " .. action .. " 2>&1")
    local fd = io.open("/etc/rc.d/S99podkop", "r")
    local resp = {
        success = true,
        enabled = (fd ~= nil)
    }
    if fd then fd:close() end
    return resp
end

return M
