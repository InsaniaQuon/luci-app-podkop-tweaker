-- Podkop Tweaker | service config file operations (io only, no luci dependencies)
-- Author: InsaniaQuon

local M = {}
local LIB = require("podkop-tweaker.lib")

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
M.SINGBOX_MAX_SIZE = 2097152

M.ops = {
    podkop  = { svc = M.podkop,  init = "podkop",   pid = "sing-box" },
    stubby  = { svc = M.stubby,  init = "stubby",   pid = "stubby"   },
    singbox = { svc = M.singbox, init = "sing-box", pid = "sing-box" }
}

M.SUBS_FILE = "/etc/config/podkop-tweaker-subs.json"
M.UPDATE_LOG_FILE = "/etc/config/pt-update.log"
M.UPDATE_LOG_MAX = 25

function M.singbox_content_check(content, empty_msg)
    if type(content) ~= "string" then return false, "Configuration must be text" end
    if content == "" then return false, empty_msg end
    if #content > M.SINGBOX_MAX_SIZE then return false, "Config too large (max 2MB)" end
    if content:find("\0", 1, true) then return false, "Invalid content: contains null bytes" end
    return true
end

function M.read_stream(fd, limit)
    local chunks, size = {}, 0
    while true do
        local chunk, err = fd:read(math.min(8192, limit - size + 1))
        if not chunk then
            if err then return nil, "Cannot read: " .. tostring(err) end
            break
        end
        if chunk == "" then break end
        size = size + #chunk
        if size > limit then return nil, "Content exceeds size limit" end
        chunks[#chunks + 1] = chunk
    end
    return table.concat(chunks)
end

function M.read_file(path, limit)
    local fd, err = io.open(path, "rb")
    if not fd then return nil, err end
    local content, read_err = M.read_stream(fd, limit or 8388608)
    local closed, close_err = fd:close()
    if not content then return nil, read_err end
    if not closed then return nil, "Cannot close file: " .. tostring(close_err) end
    return content
end

function M.write_file_checked(path, content, mode)
    if type(content) ~= "string" then return false, "Content must be text or binary bytes" end
    local fd = io.open(path, "wb")
    if not fd then return false, "Cannot write temporary file" end
    -- Private staging (e.g. root crontab) must be private before any bytes land.
    if mode and (type(mode) ~= "string" or not mode:match("^[0-7][0-7][0-7]$") or
        not LIB.exit_ok(os.execute("chmod " .. mode .. " " .. LIB.shell_escape(path) .. " 2>/dev/null"))) then
        fd:close()
        os.remove(path)
        return false, "Cannot set file permissions"
    end
    local written, write_err = fd:write(content)
    local closed, close_err = fd:close()
    if not written or not closed then
        os.remove(path)
        return false, "Cannot write file: " .. tostring(write_err or close_err or "unknown error")
    end
    return true
end

function M.write_file_atomic(path, content, options)
    options = options or {}
    local tmp = path .. (options.suffix or ".tmp-write")
    local written, write_err = M.write_file_checked(tmp, content, options.mode)
    if not written then return false, write_err end
    if options.executable and not LIB.exit_ok(os.execute("chmod 755 " .. LIB.shell_escape(tmp) .. " 2>/dev/null")) then
        os.remove(tmp)
        return false, "Cannot set executable permissions"
    end
    local ok, err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return false, "Cannot apply: " .. (err or "unknown error")
    end
    return true
end

local function backup_to(src_path, dst_path, required)
    local probe, open_err, errno = io.open(src_path, "rb")
    if not probe then
        if errno == 2 and not required then return true end
        return false, open_err or "Cannot read backup source"
    end
    local data, read_err = M.read_stream(probe, 8388608)
    local closed = probe:close()
    if not data or not closed then
        return false, read_err or "Cannot read backup source"
    end
    return M.write_file_atomic(dst_path, data, { suffix = ".tmp" })
end

M.backup_to = backup_to

function M.backup_current(ops)
    return backup_to(ops.config, ops.backup)
end

function M.restore_backup(ops)
    local fd = io.open(ops.backup, "rb")
    if not fd then return false, "not_found" end
    local data = M.read_stream(fd, 8388608)
    local closed = fd:close()
    if not data or not closed then return false, "read_failed" end
    if not M.write_file_atomic(ops.config, data) then return false, "write_failed" end
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
    local written, write_err = M.write_file_checked(tmp_path, content)
    if not written then return false, write_err end
    local check = sys.exec("sing-box check -c " .. tmp_path .. " 2>&1")
    if check and check ~= "" then
        os.remove(tmp_path)
        return false, check_err_msg or "sing-box check failed", check
    end
    if not backup_to(M.SINGBOX_CONFIG, M.SINGBOX_BACKUP) then
        os.remove(tmp_path)
        return false, "Cannot create backup"
    end
    if not os.rename(tmp_path, M.SINGBOX_CONFIG) then
        os.remove(tmp_path)
        return false, "Cannot apply config"
    end
    return true
end

return M
