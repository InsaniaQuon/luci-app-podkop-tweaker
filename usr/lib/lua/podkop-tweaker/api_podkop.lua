-- Podkop Tweaker | Podkop config/service/system API handlers
-- Author: InsaniaQuon

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
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()

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
        http.write_json({
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
        })
        return
    end

    local update_available = false
    if info.podkop_latest_version
        and info.podkop_latest_version ~= "unknown"
        and info.podkop_version ~= "unknown" then
        update_available = LIB.version_lt(info.podkop_version, info.podkop_latest_version)
    end

    local stubby_ver = sys.exec("stubby -V 2>/dev/null"):match("Stubby%s+(%S+)") or "not installed"

    http.write_json({
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
    })
end

function M.update_start()
    if not H.verify_csrf() then return end
    local sys = require("luci.sys")
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()

    if not S.backup_config() then
        http.write_json({ error = "Cannot create backup before update" })
        return
    end

    sys.exec("pkill -f 'ttyd.*7682' 2>/dev/null")

    local host = http.getenv("SERVER_NAME") or "127.0.0.1"
    if not host:match("^[%w%.%-]+:%d+$") and not host:match("^[%w%.%-]+$") then
        host = http.getenv("SERVER_NAME") or "127.0.0.1"
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

    http.write_json({ success = true, url = "http://" .. host .. ":" .. port })
end

function M.read_config()
    local http = require("luci.http")
    http.prepare_content("text/plain")
    H.no_cache()
    local fd = io.open("/etc/config/podkop", "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.write("")
    end
end

function M.save_config()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    local content = http.formvalue("content") or ""
    local ok, err = LIB.validate_uci_config(content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    ok, err = save_and_restart(content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    http.write_json({ success = true, restarting = true })
end

function M.export_config()
    local http = require("luci.http")
    local nixio = require("nixio")
    local config_path = "/etc/config/podkop"
    if not nixio.fs.stat(config_path) then
        http.status(404, "Config not found")
        return
    end
    http.prepare_content("application/octet-stream")
    H.no_cache()
    http.header("Content-Disposition", 'attachment; filename="podkop-config-export.conf"')
    local fd = io.open(config_path, "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.status(500, "Cannot read config")
    end
end

function M.download_backup()
    local http = require("luci.http")
    local nixio = require("nixio")
    local backup_path = "/etc/config/podkop.auto-backup"
    if not nixio.fs.stat(backup_path) then
        http.prepare_content("application/json")
        http.write_json({ error = "Backup file not found" })
        return
    end
    http.prepare_content("application/octet-stream")
    H.no_cache()
    http.header("Content-Disposition", 'attachment; filename="podkop-auto-backup.conf"')
    local fd = io.open(backup_path, "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.status(500, "Cannot read backup")
    end
end

function M.import_config()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    local upload_content = http.formvalue("content") or ""
    if upload_content == "" then
        local fdupload = http.formvalue("file")
        if type(fdupload) == "table" and fdupload.data then
            upload_content = fdupload.data
        elseif type(fdupload) == "string" then
            upload_content = fdupload
        end
    end
    local ok, err = LIB.validate_uci_config(upload_content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    ok, err = save_and_restart(upload_content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    http.write_json({ success = true, restarting = true })
end

function M.service_status()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    local pid = H.get_service_pid("sing-box")
    http.write_json({
        running = (pid ~= nil),
        pid = pid
    })
end

function M.rollback()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
    local ok, err = SRV.restore_backup(SRV.podkop)
    if not ok then
        http.write_json({ error = (err == "not_found") and "Backup file not found" or "Cannot write config" })
        return
    end
    sys.exec(SRV.podkop.restart_cmd)
    http.write_json({ success = true, restarting = true })
end

function M.service_toggle()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
    local action = http.formvalue("action") or ""
    if action ~= "start" and action ~= "stop" then
        http.write_json({ error = "Invalid action" })
        return
    end
    sys.exec("/etc/init.d/podkop " .. action .. " 2>&1")
    local pid = H.get_service_pid("sing-box")
    http.write_json({
        success = true,
        running = (pid ~= nil)
    })
end

function M.autostart()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    local fd = io.open("/etc/rc.d/S99podkop", "r")
    http.write_json({
        enabled = (fd ~= nil)
    })
    if fd then fd:close() end
end

function M.autostart_toggle()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
    local action = http.formvalue("action") or ""
    if action ~= "enable" and action ~= "disable" then
        http.write_json({ error = "Invalid action" })
        return
    end
    sys.exec("/etc/init.d/podkop " .. action .. " 2>&1")
    local fd = io.open("/etc/rc.d/S99podkop", "r")
    http.write_json({
        success = true,
        enabled = (fd ~= nil)
    })
    if fd then fd:close() end
end

return M
