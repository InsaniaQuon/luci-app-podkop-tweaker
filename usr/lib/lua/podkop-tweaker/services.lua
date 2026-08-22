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

function M.backup_current(ops)
    local data = M.read_file(ops.config)
    if not data then return true end
    local bfd = io.open(ops.backup, "w")
    if not bfd then return false end
    bfd:write(data)
    bfd:close()
    return true
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

return M
