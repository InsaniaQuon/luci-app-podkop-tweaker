-- Podkop Tweaker | service config file operations (io only, no luci dependencies)
-- Author: InsaniaQuon

local M = {}

M.podkop = {
    config = "/etc/config/podkop",
    backup = "/etc/config/podkop.auto-backup",
    restart_cmd = "/etc/init.d/podkop restart 2>&1"
}

M.stubby = {
    config = "/etc/config/stubby",
    backup = "/etc/config/stubby.auto-backup",
    restart_cmd = "/etc/init.d/stubby restart 2>&1"
}

M.singbox = {
    config = "/etc/sing-box/config.json",
    backup = "/etc/sing-box/config.json.auto-backup",
    restart_cmd = "/etc/init.d/sing-box restart 2>&1"
}

M.SINGBOX_CONFIG = M.singbox.config
M.SINGBOX_BACKUP = M.singbox.backup

M.ops = {
    podkop  = { svc = M.podkop,  init = "podkop",   pid = "sing-box" },
    stubby  = { svc = M.stubby,  init = "stubby",   pid = "stubby"   },
    singbox = { svc = M.singbox, init = "sing-box", pid = "sing-box" }
}

M.SUBS_FILE = "/etc/config/podkop-tweaker-subs.json"
M.UPDATE_LOG_FILE = "/etc/config/pt-update.log"
M.UPDATE_LOG_MAX = 25

function M.singbox_content_check(content, empty_msg)
    if content == "" then return false, empty_msg end
    if #content > 2097152 then return false, "Config too large (max 2MB)" end
    if content:find("\0", 1, true) then return false, "Invalid content: contains null bytes" end
    return true
end

function M.read_file(path)
    local fd = io.open(path, "r")
    if not fd then return nil end
    local content = fd:read("*a")
    fd:close()
    return content
end

function M.write_file_atomic(path, content)
    local tmp = path .. ".tmp-write"
    local tmpfd = io.open(tmp, "w")
    if not tmpfd then
        return false, "Cannot write temporary file"
    end
    tmpfd:write(content)
    tmpfd:close()
    local ok, err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return false, "Cannot apply: " .. (err or "unknown error")
    end
    return true
end

local function backup_to(src_path, dst_path)
    local data = M.read_file(src_path)
    if not data then return true end
    local tmp = dst_path .. ".tmp"
    local bfd = io.open(tmp, "w")
    if not bfd then return false end
    bfd:write(data)
    bfd:close()
    if not os.rename(tmp, dst_path) then
        os.remove(tmp)
        return false
    end
    return true
end

M.backup_to = backup_to

function M.backup_current(ops)
    return backup_to(ops.config, ops.backup)
end

function M.restore_backup(ops)
    local fd = io.open(ops.backup, "r")
    if not fd then return false, "not_found" end
    local data = fd:read("*a")
    fd:close()
    local wfd = io.open(ops.config, "w")
    if not wfd then return false, "write_failed" end
    wfd:write(data)
    wfd:close()
    return true
end

-- Shared service ops (status / toggle / rollback) for podkop, stubby, singbox
function M.service_status(ops)
    local H = require("podkop-tweaker.http")
    local pid = H.get_service_pid(ops.pid)
    return {
        running = (pid ~= nil),
        pid = pid
    }
end

function M.service_toggle(ops, action)
    if action ~= "start" and action ~= "stop" then
        return { error = "Invalid action" }
    end
    local sys = require("luci.sys")
    sys.exec("/etc/init.d/" .. ops.init .. " " .. action .. " 2>&1")
    local H = require("podkop-tweaker.http")
    local pid = H.get_service_pid(ops.pid)
    return {
        success = true,
        running = (pid ~= nil)
    }
end

function M.rollback(ops)
    local ok, err = M.restore_backup(ops.svc)
    if not ok then
        return { error = (err == "not_found") and "Backup file not found" or "Cannot write config" }
    end
    require("luci.sys").exec(ops.svc.restart_cmd)
    return { success = true, restarting = true }
end

-- Shared sing-box write flow: tmp-write -> sing-box check -> backup orig -> rename.
-- Returns ok, err, details. Error texts must stay 1:1 with the pre-helper endpoints.
function M.singbox_apply_checked(content, tmp_suffix, check_err_msg)
    local sys = require("luci.sys")
    local tmp_path = M.SINGBOX_CONFIG .. tmp_suffix
    local tmpfd = io.open(tmp_path, "w")
    if not tmpfd then
        return false, "Cannot write temporary file"
    end
    tmpfd:write(content)
    tmpfd:close()
    local check = sys.exec("sing-box check -c " .. tmp_path .. " 2>&1")
    if check and check ~= "" then
        os.remove(tmp_path)
        return false, check_err_msg or "sing-box check failed", check
    end
    local orig = M.read_file(M.SINGBOX_CONFIG)
    if orig then
        local bfd = io.open(M.SINGBOX_BACKUP, "w")
        if bfd then
            bfd:write(orig)
            bfd:close()
        end
    end
    if not os.rename(tmp_path, M.SINGBOX_CONFIG) then
        os.remove(tmp_path)
        return false, "Cannot apply config"
    end
    return true
end

return M
