-- Podkop Tweaker | v4.5.0 | 03.09.2026 | system_info: 24h podkop-update snapshot + argon theme fields; check_updates composer
-- Hybrid exceptions kept as-is: read_config, export_config, download_backup (transport endpoints)

local H = require("podkop-tweaker.http")
local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")
local S = require("pt-subs-lib")
local UPD = require("podkop-tweaker.api_update")
local THEME = require("podkop-tweaker.theme")

local M = {}
M.CONFIG_MAX_SIZE = LIB.UCI_MAX_SIZE

local PODKOP_INSTALL_URL = "https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh"
local PODKOP_CHECK_CACHE = "/tmp/pt_podkop_check.json"
local CHECK_CACHE_TTL = 86400

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

local function parse_podkop_info(raw)
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
    return info
end

-- 24h snapshot of the podkop "latest/available" decision (versions stay live).
local function podkop_update_snapshot(info, force)
    if not force then
        local fd = io.open(PODKOP_CHECK_CACHE, "r")
        if fd then
            local raw = fd:read("*a")
            fd:close()
            local cache = S.json_parse(raw)
            if cache and cache.cached_at
                and (os.time() - cache.cached_at) < CHECK_CACHE_TTL then
                return cache
            end
        end
    end
    local entry = nil
    if info and info.podkop_version
        and info.podkop_latest_version and info.podkop_latest_version ~= "unknown" then
        entry = {
            current_version = info.podkop_version,
            latest_version = info.podkop_latest_version,
            update_available = LIB.version_lt(info.podkop_version, info.podkop_latest_version),
            cached_at = os.time()
        }
        local str = S.json_stringify(entry)
        if str then
            local wfd = io.open(PODKOP_CHECK_CACHE, "w")
            if wfd then
                wfd:write(str)
                wfd:close()
            end
        end
    end
    return entry
end

-- Theme latest via the 24h cache; refreshes the cache (network) when missing/expired.
local function theme_latest_auto()
    local info = THEME.check(false)
    if info and not info.error then
        return info.latest_version
    end
    return nil
end

function M.system_info()
    local sys = require("luci.sys")

    local raw = sys.exec("podkop get_system_info 2>/dev/null")
    local info = parse_podkop_info(raw)

    -- theme detect once; no installed theme -> no network check at all
    local argon_ver = THEME.installed_version()
    local argon_latest = argon_ver and theme_latest_auto() or nil
    local tweaker = UPD.cached_update() or {}

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
            tweaker_latest = tweaker.latest_version,
            tweaker_download_url = tweaker.download_url,
            argon_theme_version = argon_ver,
            argon_theme_latest = argon_latest,
            error = "Failed to get system info from podkop"
        }
    end

    local snapshot = podkop_update_snapshot(info, false) or {}

    local stubby_ver = sys.exec("stubby -V 2>/dev/null"):match("Stubby%s+(%S+)") or "not installed"

    return {
        podkop_version = info.podkop_version or "unknown",
        podkop_latest_version = snapshot.latest_version or info.podkop_latest_version or "unknown",
        luci_app_version = info.luci_app_version or "unknown",
        stubby_version = stubby_ver,
        sing_box_version = info.sing_box_version or "unknown",
        openwrt_version = info.openwrt_version or "unknown",
        device_model = info.device_model or "unknown",
        update_available = snapshot.update_available or false,
        tweaker_version = UPD.get_version(),
        tweaker_latest = tweaker.latest_version,
        tweaker_download_url = tweaker.download_url,
        argon_theme_version = argon_ver,
        argon_theme_latest = argon_latest
    }
end

-- Force re-check of all three update sources (System Info "Check for updates" button).
function M.check_updates()
    local sys = require("luci.sys")

    -- podkop: refresh the snapshot from a live get_system_info call
    local info = parse_podkop_info(sys.exec("podkop get_system_info 2>/dev/null"))
    local podkop = podkop_update_snapshot(info, true)
    if not podkop then
        podkop = { error = "Failed to get podkop info" }
    end

    -- tweaker: drop the cache to bypass the rate-limit gate, then check
    local tweaker = UPD.check_update_force()

    -- theme: force-check writes a fresh 24h cache entry
    local theme = THEME.check(true)

    return { podkop = podkop, tweaker = tweaker, theme = theme }
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
